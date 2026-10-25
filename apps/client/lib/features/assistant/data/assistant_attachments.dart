import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 选择器和剪贴板的统一输入，进入草稿前复制到应用私有目录。
class AssistantPickedFile {
  /// 脱离设备路径的显示名称。
  final String name;

  /// 系统选择器提供的临时路径。
  final String? sourcePath;

  /// 剪贴板或没有文件路径的平台返回的内容。
  final Uint8List? bytes;

  /// 创建候选文件；大小以实际复制内容为准。
  const AssistantPickedFile({required this.name, this.sourcePath, this.bytes});
}

/// 独立附件草稿状态，不参与业务图片同步和主数据库。
class AssistantAttachments {
  /// 固定认证仓储。
  final AssistantRepository? repository;

  /// 服务器和 owner 的缓存作用域。
  final String? scope;

  /// 仅获取已发送过消息的聊天身份，空白草稿不创建服务端会话。
  final Future<String?> Function() ensureConversation;

  /// 状态变动由聊天控制器统一缓存并刷新界面。
  final void Function() changed;

  /// 发出上传前等待恢复身份落盘。
  final Future<void> Function() persist;

  /// 私有目录入口可由隔离测试替换。
  final Future<Directory> Function() directoryProvider;

  /// 正文与附件共享提交冻结状态。
  final bool Function() frozen;

  /// 服务端明确公布的限制；缺失或旧 API 都不显示入口。
  Map<String, dynamic> capabilities = <String, dynamic>{};

  /// 当前会话中有序的附件草稿。
  List<Map<String, dynamic>> drafts = <Map<String, dynamic>>[];

  /// 文件选择或复制过程需要禁止重复添加。
  bool adding = false;

  /// 当前附件错误，不覆盖聊天任务的错误。
  String? error;

  /// 已发出的文件传输身份，防止移除与上传完成竞争。
  final Set<String> _transfers = <String>{};

  /// 当前草稿代次，切换聊天时旧结果不能回写。
  int _epoch = 0;

  /// 控制器退出后禁止更新状态。
  bool _disposed = false;

  /// 解析轮询定时器；同一时刻仅有一轮请求。
  Timer? _poll;

  /// 避免手动恢复与定时器同时读取解析状态。
  bool _polling = false;

  /// 创建同源附件管理器。
  AssistantAttachments({
    required this.repository,
    required this.scope,
    required this.ensureConversation,
    required this.changed,
    required this.persist,
    required this.frozen,
    Future<Directory> Function()? directoryProvider,
  }) : directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  /// 必须得到服务器明确支持才能添加附件。
  bool get enabled => capabilities['enabled'] == true;

  /// 当前来源仍有效且没有消息结果待核实。
  bool get editable => !_disposed && repository?.isCurrent == true && !frozen();

  /// 上传传输期间禁止切换聊天或删除正在传输的卡片。
  bool get transferring => adding || _transfers.isNotEmpty;

  /// 至少有一个附件时允许发送默认概括请求。
  bool get hasDrafts => drafts.isNotEmpty;

  /// 选择器或剪贴板返回前可核对仍是原草稿。
  int get draftToken => _epoch;

  /// 每次序列化深拷贝，上传进度不能污染已排队的缓存快照。
  List<Map<String, dynamic>> get snapshot =>
      assistantItems(jsonDecode(jsonEncode(drafts)));

  /// 冻结给消息的有序身份，不包含本机路径。
  List<String> get ids => drafts.map((item) => item['id'] as String).toList();

  /// 判断本卡片是否可执行移除或重试。
  bool canEdit(String id) => editable && !adding && !_transfers.contains(id);

  /// 从同一数据源恢复草稿；未确认上传需要显式重试原上传身份。
  void restore(Object? value) {
    _epoch++;
    _poll?.cancel();
    drafts = assistantItems(value)
        .map((item) => <String, dynamic>{...item})
        .toList();
    for (final Map<String, dynamic> item in drafts) {
      if (item['status'] == 'uploading') {
        item['status'] = 'failed';
        item['localError'] = '上传未完成，请重试';
      }
    }
    error = null;
    _schedulePoll();
  }

  /// 旧 API 或关闭的附件能力不影响已有纯文本聊天。
  Future<void> initialize() async {
    if (repository?.isCurrent != true) return;
    try {
      capabilities = await repository!.request(
        'GET',
        '/attachments/capabilities',
      );
    } catch (_) {
      capabilities = <String, dynamic>{};
    }
    if (!_disposed && repository?.isCurrent == true) {
      changed();
      _schedulePoll();
    }
  }

  /// 两端按钮只拦截传输状态；模型校验留到显式发送时说明原因。
  String? blockReason(
    Map<String, dynamic>? settings, {
    bool includeVision = true,
  }) {
    if (drafts.isEmpty) return null;
    if (transferring ||
        drafts.any(
          (item) => item['status'] != 'ready' && item['status'] != 'local',
        )) {
      return '请等待全部附件就绪；失败的附件可重试或移除';
    }
    return includeVision ? imageInputBlockReason(settings) : null;
  }

  /// 图片输入只由模型配置的多模态开关放行，旧探测结果不能替代声明。
  String? imageInputBlockReason(Map<String, dynamic>? settings) {
    if (!drafts.any((item) => item['requiresVision'] == true)) return null;
    // 使用服务器当前选定配置，缺失字段按未开启处理。
    final Map<String, dynamic>? profile = assistantItems(settings?['profiles'])
        .where((item) => item['id'] == settings?['profileId'])
        .firstOrNull;
    return profile?['multimodal'] == true
        ? null
        : '当前模型未开启多模态，请在 AI 设置中编辑模型配置并开启。';
  }

  /// 有界复制所有候选，再以原上传身份逐个上传，不将临时路径写进请求。
  Future<void> add(List<AssistantPickedFile> files) async {
    if (!enabled || !editable || adding || files.isEmpty) return;
    // 整批身份在异步操作前固定。
    final int epoch = _epoch;
    adding = true;
    error = null;
    changed();
    // 批次复制失败时撤销尚未进入草稿的本机文件。
    final List<Map<String, dynamic>> prepared = <Map<String, dynamic>>[];
    try {
      // API 限制不明时采用首版保守上限。
      final int maxFiles = (capabilities['maxFiles'] as num?)?.toInt() ?? 5;
      // 单文件实际大小上限。
      final int maxBytes =
          (capabilities['maxFileBytes'] as num?)?.toInt() ?? 20 * 1024 * 1024;
      // 当前消息总量上限。
      final int maxTotal =
          (capabilities['maxTotalBytes'] as num?)?.toInt() ?? 50 * 1024 * 1024;
      // 文件类型由服务端能力列表约束，不能信任系统选择器过滤。
      final Set<String> extensions =
          (capabilities['extensions'] as List? ?? const <String>[])
              .cast<String>()
              .toSet();
      if (drafts.length + files.length > maxFiles) {
        throw ApiFailure('每条消息最多添加 $maxFiles 个附件');
      }
      // 与 source/owner 对应的私有目录，文件名使用应用生成的 UUID。
      final Directory directory = await _directory();
      // 已有文件的实际上传大小。
      int total = drafts.fold(
        0,
        (sum, item) => sum + ((item['size'] as num?)?.toInt() ?? 0),
      );
      for (final AssistantPickedFile picked in files) {
        // 展示文件名剥离两种平台分隔符及控制字符。
        final String name = picked.name
            .split(RegExp(r'[/\\]'))
            .last
            .replaceAll(RegExp(r'[\x00-\x1f]'), '');
        // 后缀仅用于初筛，服务端仍验证文件内容。
        final String extension = path
            .extension(name)
            .replaceFirst('.', '')
            .toLowerCase();
        if (!extensions.contains(extension)) {
          throw const ApiFailure('请选择支持的图片、PDF、TXT、Markdown、DOCX 或 XLSX 文件');
        }
        // 读取前检查文件长度，避免大文件进入内存。
        final int size =
            picked.bytes?.length ?? await File(picked.sourcePath!).length();
        if (size <= 0 || size > maxBytes) {
          throw ApiFailure('附件“$name”为空或超过 ${(maxBytes / 1048576).floor()} MB');
        }
        total += size;
        if (total > maxTotal) {
          throw ApiFailure('每条消息附件总大小不能超过 ${(maxTotal / 1048576).floor()} MB');
        }
        // 上传重放始终使用同一 UUID。
        final String id = const Uuid().v4();
        // 私有副本路径不携带用户文件名。
        final File target = File(path.join(directory.path, '$id.$extension'));
        // 有界流式复制防止检查后源文件增长。
        final IOSink sink = target.openWrite();
        // 实际复制字节数。
        int copied = 0;
        try {
          await for (final List<int> chunk
              in picked.bytes != null
                  ? Stream<List<int>>.value(picked.bytes!)
                  : File(picked.sourcePath!).openRead()) {
            copied += chunk.length;
            if (copied > size) throw const ApiFailure('文件在读取时发生变化，请重新选择');
            sink.add(chunk);
          }
          await sink.flush();
        } catch (_) {
          await sink.close();
          if (await target.exists()) await target.delete();
          rethrow;
        }
        await sink.close();
        if (copied != size) {
          await target.delete();
          throw const ApiFailure('文件在读取时发生变化，请重新选择');
        }
        prepared.add(<String, dynamic>{
          'id': id,
          'name': name,
          'size': size,
          'localPath': target.path,
          'status': 'uploading',
          'kind': <String>{'png', 'jpg', 'jpeg', 'webp'}.contains(extension)
              ? 'image'
              : 'document',
          'requiresVision': <String>{
            'png',
            'jpg',
            'jpeg',
            'webp',
          }.contains(extension),
        });
      }
      if (!_current(epoch)) return;
      // 空白聊天只保留私有副本，首次发送才上传。
      final String? conversationId = await ensureConversation();
      if (!_current(epoch)) return;
      for (final Map<String, dynamic> item in prepared) {
        if (conversationId != null) {
          item['conversationId'] = conversationId;
        } else {
          item['status'] = 'local';
        }
      }
      drafts = <Map<String, dynamic>>[...drafts, ...prepared];
      changed();
      await persist();
      if (conversationId != null) {
        for (final Map<String, dynamic> item in prepared) {
          await _upload(item, epoch);
        }
      }
    } catch (failure) {
      if (_current(epoch)) {
        error = _message(failure);
        for (final Map<String, dynamic> item in prepared) {
          if (drafts.contains(item) && item['status'] == 'uploading') {
            item['status'] = 'failed';
            item['localError'] = error;
          }
        }
      }
    } finally {
      // 没有进入当前或旧会话草稿的复制件才可清理。
      for (final Map<String, dynamic> item in prepared) {
        if (!drafts.contains(item)) await _removeLocal(item);
      }
      adding = false;
      if (!_disposed) changed();
      _schedulePoll();
    }
  }

  /// 首次发送才绑定会话并上传本地草稿，全部解析完成后才提交消息。
  Future<void> prepareForSend(String conversationId) async {
    // 当前草稿代次与等待截止时间覆盖上传、解析全过程。
    final int epoch = _epoch;
    final DateTime deadline = DateTime.now().add(const Duration(minutes: 3));
    for (final Map<String, dynamic> item in drafts) {
      if (!_current(epoch)) throw const ApiFailure('聊天已切换，请重新发送');
      if (item['status'] != 'local') continue;
      item['conversationId'] = conversationId;
      await _upload(item, epoch);
    }
    while (_current(epoch) &&
        drafts.any((item) => item['status'] == 'processing')) {
      if (DateTime.now().isAfter(deadline)) {
        throw const ApiFailure('附件仍在处理，请就绪后重新发送');
      }
      await pollNow();
      if (drafts.any((item) => item['status'] == 'processing')) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    if (!_current(epoch)) throw const ApiFailure('聊天已切换，请重新发送');
    await persist();
  }

  /// 上传响应丢失后仍以相同 UUID 和相同私有副本恢复。
  Future<void> _upload(Map<String, dynamic> item, int epoch) async {
    if (!_current(epoch)) return;
    // 对应卡片的稳定身份。
    final String id = item['id'] as String;
    _transfers.add(id);
    item['status'] = 'uploading';
    item.remove('localError');
    changed();
    try {
      await persist();
      // 恢复缓存不能把当前来源私有目录之外的文件送往服务器。
      final String localPath = await _uploadPath(item);
      if (!_current(epoch)) return;
      // 后端幂等上传回执。
      final Map<String, dynamic> result = await repository!.uploadAttachment(
        item['conversationId'] as String,
        id,
        localPath,
        item['name'] as String,
      );
      if (_current(epoch)) {
        _applyMetadata(item, result);
        item['uploaded'] = true;
      }
    } catch (failure) {
      if (_current(epoch)) {
        item['status'] = 'failed';
        item['localError'] = _message(failure);
      }
    } finally {
      _transfers.remove(id);
      if (_current(epoch)) changed();
    }
  }

  /// 重试解析失败，或按原上传身份核实传输结果。
  Future<void> retry(String id) async {
    if (!canEdit(id)) return;
    // 不允许拿历史附件身份作为可修改草稿。
    final Map<String, dynamic>? item = drafts
        .where((item) => item['id'] == id)
        .firstOrNull;
    if (item == null) return;
    if (item['expired'] == true) {
      error = '附件已过期，请移除后重新选择文件';
      changed();
      return;
    }
    // 当前草稿代次。
    final int epoch = _epoch;
    if (item['uploaded'] != true ||
        <String>{
          'ATTACHMENT_UPLOAD_INTERRUPTED',
          'ATTACHMENT_STORAGE_UNAVAILABLE',
        }.contains(item['errorCode'])) {
      await _upload(item, epoch);
    } else {
      _transfers.add(id);
      changed();
      try {
        // 重试只重新解析同一份对象，不调用付费模型。
        final Map<String, dynamic> result = await repository!.request(
          'POST',
          '/attachments/${Uri.encodeComponent(id)}/retry',
        );
        if (_current(epoch)) {
          _applyMetadata(item, result);
          item.remove('localError');
        }
      } catch (failure) {
        if (_current(epoch)) item['localError'] = _message(failure);
      } finally {
        _transfers.remove(id);
        if (_current(epoch)) changed();
      }
    }
    _schedulePoll();
  }

  /// 服务器确认移除后才删除私有副本，失败时保留恢复所需身份。
  Future<void> remove(String id) async {
    if (!canEdit(id)) return;
    // 只读取本会话草稿中的目标。
    final Map<String, dynamic>? item = drafts
        .where((item) => item['id'] == id)
        .firstOrNull;
    if (item == null) return;
    // 当前操作归属代次。
    final int epoch = _epoch;
    _transfers.add(id);
    changed();
    try {
      if (item['conversationId'] != null || item['uploaded'] == true) {
        await repository!.request(
          'DELETE',
          '/attachments/${Uri.encodeComponent(id)}',
        );
      }
      if (!_current(epoch)) return;
      drafts.remove(item);
      await _removeLocal(item);
    } catch (failure) {
      if (_current(epoch)) error = _message(failure);
    } finally {
      _transfers.remove(id);
      if (_current(epoch)) changed();
    }
  }

  /// 消息成功接收后解除本机草稿引用；服务端消息继续保留附件。
  Future<void> clearAccepted() async {
    // 清理仅针对已经确认提交的当前草稿副本。
    final List<Map<String, dynamic>> accepted = drafts;
    restore(null);
    for (final Map<String, dynamic> item in accepted) {
      await _removeLocal(item);
    }
  }

  /// 删除非当前聊天后，只回收其同源私有副本。
  Future<void> releaseFiles(Object? value) async {
    for (final Map<String, dynamic> item in assistantItems(value)) {
      await _removeLocal(item);
    }
  }

  /// 获取与当前来源独立的目录，避免换服混用旧附件。
  Future<Directory> _directory() async {
    // 目录使用完整作用域摘要，避免将服务器和 owner 写成路径。
    final String source = sha256.convert(utf8.encode(scope ?? '')).toString();
    // 系统私有数据根目录。
    final Directory root = await directoryProvider();
    return Directory(
      path.join(root.path, 'omni_butler', 'assistant_attachments', source),
    ).create(recursive: true);
  }

  /// 协议回执只更新公开元数据，不能覆写上传身份或本机路径。
  void _applyMetadata(Map<String, dynamic> item, Map<String, dynamic> result) {
    for (final String field in const <String>[
      'name',
      'mimeType',
      'size',
      'status',
      'kind',
      'requiresVision',
      'errorCode',
    ]) {
      if (result.containsKey(field)) item[field] = result[field];
    }
    if (!result.containsKey('errorCode')) item.remove('errorCode');
  }

  /// 上传只读取当前来源的私有副本，符号链接也不能绕过目录边界。
  Future<String> _uploadPath(Map<String, dynamic> item) async {
    // 缓存可能缺少路径或包含旧来源的绝对路径。
    final String? localPath = item['localPath'] as String?;
    // 当前服务器与 owner 专属目录。
    final Directory directory = await _directory();
    if (localPath == null ||
        !path.isAbsolute(localPath) ||
        !path.isWithin(directory.absolute.path, localPath)) {
      throw const ApiFailure('附件本地副本无效，请移除后重新选择');
    }
    // 实际文件位置必须继续留在同一私有目录。
    final String resolvedPath = await File(localPath).resolveSymbolicLinks();
    // 目录本身可能经过系统路径映射。
    final String resolvedDirectory = await directory.resolveSymbolicLinks();
    if (!path.isWithin(resolvedDirectory, resolvedPath)) {
      throw const ApiFailure('附件本地副本无效，请移除后重新选择');
    }
    return localPath;
  }

  /// 缓存中路径必须仍位于本数据源私有目录，才允许删除。
  Future<void> _removeLocal(Map<String, dynamic> item) async {
    try {
      // 本机文件路径不属于协议对象，只有应用私有副本可删除。
      final String? localPath = item['localPath'] as String?;
      if (localPath == null) return;
      // 解析当前来源目录后复核绝对路径范围。
      final Directory directory = await _directory();
      if (!path.isWithin(
        directory.absolute.path,
        File(localPath).absolute.path,
      )) {
        return;
      }
      // 删除失败只遗留缓存，不应把成功消息改成失败。
      final File file = File(localPath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 轮询仅恢复解析状态，不触发消息或模型执行。
  void _schedulePoll() {
    _poll?.cancel();
    if (_disposed ||
        repository?.isCurrent != true ||
        !drafts.any(
          (item) =>
              item['status'] == 'processing' ||
              (item['status'] == 'uploading' && item['uploaded'] == true),
        )) {
      return;
    }
    _poll = Timer(const Duration(seconds: 2), () => unawaited(pollNow()));
  }

  /// 单轮查询可用于重连恢复和确定性测试。
  Future<void> pollNow() async {
    if (_polling) return;
    _polling = true;
    _poll?.cancel();
    // 异步读取固定在当前草稿代次。
    final int epoch = _epoch;
    for (final Map<String, dynamic> item in List<Map<String, dynamic>>.from(
      drafts,
    )) {
      if (!_current(epoch)) break;
      if (item['status'] != 'processing' &&
          !(item['status'] == 'uploading' && item['uploaded'] == true)) {
        continue;
      }
      try {
        // 读取稳定附件身份对应的最新解析回执。
        final Map<String, dynamic> result = await repository!.request(
          'GET',
          '/attachments/${Uri.encodeComponent(item['id'] as String)}',
        );
        if (_current(epoch) && drafts.contains(item)) {
          _applyMetadata(item, result);
          item.remove('localError');
          changed();
        }
      } catch (failure) {
        if (_current(epoch)) {
          if (failure is AssistantApiFailure && failure.statusCode == 404) {
            item['status'] = 'failed';
            item['expired'] = true;
            item['localError'] = '附件已过期或被删除，请移除后重新选择';
          } else {
            item['localError'] = '解析状态暂不可用，恢复连接后继续查询';
          }
          changed();
        }
      }
    }
    _polling = false;
    _schedulePoll();
  }

  /// 严格阻止旧服务器或旧会话的异步结果回写。
  bool _current(int epoch) =>
      !_disposed && repository?.isCurrent == true && epoch == _epoch;

  /// 只公开受控用户消息。
  String _message(Object failure) =>
      failure is ApiFailure ? failure.message : '附件处理未完成，请重试或重新选择文件';

  /// 页面退出后停止解析轮询。
  void dispose() {
    _disposed = true;
    _epoch++;
    _poll?.cancel();
  }
}
