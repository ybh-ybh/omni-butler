import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/attachments/image_sync_store.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 图片传输状态，不影响业务数据的正常保存。
class ImageSyncState {
  /// 服务端是否开启图片能力；未探测时为空。
  final bool? enabled;

  /// 当前是否正在传输。
  final bool busy;

  /// 尚未完成的本机操作数量。
  final int pending;

  /// 最近一轮失败数量。
  final int failed;

  /// 本机引用但物理文件缺失的数量。
  final int missing;

  /// 最近一次失败说明。
  final String? error;

  /// 创建只读传输状态。
  const ImageSyncState({
    this.enabled,
    this.busy = false,
    this.pending = 0,
    this.failed = 0,
    this.missing = 0,
    this.error,
  });
}

/// 固定数据库与认证仓储的后台图片传输器。
class ImageSyncService {
  /// 本轮服务绑定的本机数据库。
  final AppDatabase database;

  /// 本轮服务绑定的会话仓储。
  final AuthRepository auth;

  /// 本机文件根目录解析器。
  final Future<Directory> Function() directoryProvider;

  /// 自动重试及远端修改轮询间隔。
  final Duration interval;

  /// 本机协议状态存储。
  late final ImageSyncStore _store = ImageSyncStore(database);

  /// 状态订阅广播器。
  final StreamController<ImageSyncState> _states =
      StreamController<ImageSyncState>.broadcast();

  /// 最近一次状态。
  ImageSyncState _state = const ImageSyncState();

  /// 自动轮询计时器。
  Timer? _timer;

  /// 正在排空的传输轮次。
  Future<void>? _running;

  /// 多处维护/销毁入口共用同一个停止任务。
  Future<void>? _stopping;

  /// 停止标记让在途响应无法修改数据库。
  bool _stopped = false;

  /// 本实例绑定的会话代次。
  final int _generation;

  /// 创建可测试的图片传输器。
  ImageSyncService({
    required this.database,
    required this.auth,
    Future<Directory> Function()? directoryProvider,
    this.interval = const Duration(seconds: 30),
  }) : _generation = auth.sessionGeneration,
       directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  /// 当前传输状态。
  ImageSyncState get state => _state;

  /// 连续传输状态。
  Stream<ImageSyncState> get states => _states.stream;

  /// 启动自动传输；同一个实例只启动一次。
  void start() {
    if (_stopped || _timer != null) return;
    unawaited(runOnce());
    _timer = Timer.periodic(interval, (_) => unawaited(runOnce()));
  }

  /// 停止并排空在途工作，维护流程必须等待它完成。
  Future<void> stop() => _stopping ??= _stop();

  /// 排空网络结果并关闭状态流。
  Future<void> _stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _running;
    await _states.close();
  }

  /// 手动执行单次扫描，并发调用共享同一轮任务。
  Future<void> runOnce() {
    if (_stopped) return Future<void>.value();
    return _running ??= _run().whenComplete(() => _running = null);
  }

  /// 发布状态。
  void _publish(ImageSyncState value) {
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }

  /// 拒绝停止后或已切换会话的异步结果。
  void _check() {
    if (_stopped || _generation != auth.sessionGeneration) {
      throw const ApiFailure('图片同步会话已停止或变更');
    }
  }

  /// 发出绑定代次的 API 请求。
  Future<Response<T>> _request<T>(
    String method,
    String endpoint, {
    Object? data,
    ResponseType? responseType,
    Map<String, dynamic>? query,
  }) {
    _check();
    return auth.authorizedRequestForGeneration<T>(
      _generation,
      method,
      endpoint,
      data: data,
      responseType: responseType,
      queryParameters: query,
      preserveTransportErrors: true,
    );
  }

  /// 探测能力、补传本机图片、应用完整服务端清单。
  Future<void> _run() async {
    // 本轮待传输、失败及缺失数量。
    int pending = 0;
    int failed = 0;
    int missing = 0;
    // 最近一条可展示错误。
    String? lastError;
    try {
      _check();
      // 当前身份只从本机会话读取，避免无凭证探测。
      final SyncSession? session = await auth.loadSession();
      if (session == null) return;
      // 生产同步数据库必须与设备会话属于同一 owner。
      final QueryRow? ownerTable = await database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE name='device_sync_metadata'",
          )
          .getSingleOrNull();
      if (ownerTable != null) {
        // 当前业务数据库来源。
        final QueryRow? owner = await database
            .customSelect(
              "SELECT value FROM device_sync_metadata WHERE id='owner'",
            )
            .getSingleOrNull();
        if (owner?.read<String>('value') != session.identity.id) return;
      }
      _check();
      // 数据源使用 owner 身份，域名或端口变化仍可正常重连。
      final String scope = session.identity.id;
      // 上一次图片服务的数据源。
      final Map<String, dynamic>? previous = await _store.read('scope');
      if (previous != null && previous['value'] != scope) {
        throw const ApiFailure('图片数据源已变更，请通过服务器迁移流程重新连接');
      }
      await _store.write('scope', <String, dynamic>{'value': scope});
      // 服务端能力开关，旧后端 404 等价于关闭。
      Response<Map<String, dynamic>> capabilities;
      try {
        capabilities = await _request<Map<String, dynamic>>(
          'GET',
          '/images/capabilities',
        );
      } on DioException catch (error) {
        if (error.response?.statusCode != 404) rethrow;
        _publish(const ImageSyncState(enabled: false));
        return;
      }
      _check();
      if (capabilities.data?['enabled'] != true) {
        _publish(const ImageSyncState(enabled: false));
        return;
      }
      // 服务端上限与客户端上限取更小值。
      final int maxBytes =
          ((capabilities.data?['maxBytes'] as int?) ?? 20971520).clamp(
            1,
            20971520,
          );
      _publish(const ImageSyncState(enabled: true, busy: true));
      // 最新清单用于下载；本机编辑仍使用编辑时保存的版本。
      final Response<Map<String, dynamic>> manifest =
          await _request<Map<String, dynamic>>('GET', '/images');
      _check();
      // 按业务类型与记录标识索引服务端当前图片。
      final Map<String, Map<String, dynamic>> remote =
          <String, Map<String, dynamic>>{};
      for (final dynamic value
          in (manifest.data?['items'] as List<dynamic>? ?? <dynamic>[])) {
        // 单条远端图片关联。
        final Map<String, dynamic> item = Map<String, dynamic>.from(
          value as Map,
        );
        remote['${item['businessType']}:${item['businessId']}'] = item;
      }
      // 包括回收站中的业务记录，永久删除的记录不会继续上传。
      final List<QueryRow> records = await database
          .customSelect(
            "SELECT 'inventoryImage' AS type,id,image_attachment_id AS attachment_id,image_local_path AS local_path FROM inventory_items "
            "UNION ALL SELECT 'membershipImage',id,image_attachment_id,image_local_path FROM memberships",
          )
          .get();
      for (final QueryRow record in records) {
        _check();
        // 当前业务图片身份。
        final String type = record.read<String>('type');
        final String id = record.read<String>('id');
        final String key = '$type:$id';
        // 兼容仅保存本机路径、尚无附件 ID 的历史业务图片。
        if (remote[key] == null &&
            record.readNullable<String>('attachment_id') == null &&
            record.readNullable<String>('local_path') != null &&
            await _store.read('intent:$key') == null) {
          // 历史原图从应用文件复制为标准附件，不改变服务端优先规则。
          final String oldPath = record.read<String>('local_path');
          if (await File(oldPath).exists()) {
            await AttachmentRepository(
              database,
              directoryProvider: directoryProvider,
            ).attachLocalFile(
              businessType: type == 'inventoryImage'
                  ? AttachmentBusinessType.inventoryImage
                  : AttachmentBusinessType.membershipImage,
              businessId: id,
              sourcePath: oldPath,
            );
          } else {
            missing += 1;
          }
        }
        // 捕获本机操作，整个网络重试保持相同操作标识。
        Map<String, dynamic>? intent = await _store.read('intent:$key');
        if (intent != null &&
            intent['scope'] != null &&
            intent['scope'] != scope) {
          continue;
        }
        // 没有用户操作的旧图片按 onlyIfMissing 补传。
        if (intent == null &&
            remote[key] == null &&
            record.readNullable<String>('attachment_id') != null) {
          intent = <String, dynamic>{
            'operationId': const Uuid().v4(),
            'attachmentId': record.read<String>('attachment_id'),
            'scope': scope,
            'expectedRevision': null,
            'known': false,
          };
          await _store.write('intent:$key', intent);
        }
        try {
          if (intent != null) {
            pending += 1;
            // 本机未见过服务器时，服务器已经存在的图片或清图记录优先。
            if (intent['known'] != true && remote[key] != null) {
              await _ack(key, intent, remote[key]!);
            } else {
              // 服务端确认后的图片状态。
              final Map<String, dynamic> result = await _upload(
                type,
                id,
                intent,
                maxBytes,
              );
              _check();
              remote[key] = result;
              await _ack(key, intent, result);
            }
            pending -= 1;
          }
          // 下载不能覆盖网络期间刚发生的新选择。
          if (await _store.read('intent:$key') == null && remote[key] != null) {
            await _applyRemote(type, id, remote[key]!, maxBytes);
          } else if (remote[key] == null) {
            await _store.write('remote:$key', <String, dynamic>{
              'revision': null,
            });
          }
        } on DioException catch (error) {
          if (error.response?.statusCode == 409 && intent != null) {
            // CAS 冲突后下次清单刷新取服务器版本，保留旧本机文件供恢复。
            await _removeIfCurrent(key, intent);
          }
          failed += 1;
          lastError = '图片传输失败，将自动重试（${error.response?.statusCode ?? '网络不可用'}）';
        } on FileSystemException {
          missing += 1;
          lastError = '部分图片文件在本机缺失，业务数据不受影响';
        } catch (error) {
          _check();
          failed += 1;
          lastError = error.toString();
        }
      }
      _check();
      _publish(
        ImageSyncState(
          enabled: true,
          pending: pending,
          failed: failed,
          missing: missing,
          error: lastError,
        ),
      );
    } catch (error) {
      if (!_stopped) {
        _publish(
          ImageSyncState(
            enabled: _state.enabled,
            pending: pending,
            failed: failed + 1,
            missing: missing,
            error: error is DioException ? '图片服务暂时不可用，将自动重试' : error.toString(),
          ),
        );
      }
    }
  }

  /// 上传或清除一个业务图片，所有重试沿用持久操作 ID。
  Future<Map<String, dynamic>> _upload(
    String type,
    String id,
    Map<String, dynamic> intent,
    int maxBytes,
  ) async {
    // 请求体；清图与上传共用版本校验。
    Object payload;
    if (intent['attachmentId'] == null) {
      payload = <String, dynamic>{
        'operationId': intent['operationId'],
        'expectedRevision': intent['expectedRevision'],
      };
    } else {
      // 待上传附件。
      final Attachment attachment =
          await (database.select(database.attachments)..where(
                (Attachments table) =>
                    table.id.equals(intent['attachmentId'] as String),
              ))
              .getSingle();
      // 本机文件必须存在且不超过服务端上限。
      final File file = File(attachment.localPath ?? '');
      if (!await file.exists()) throw const FileSystemException('本机图片缺失');
      if (await file.length() > maxBytes) {
        throw const ApiFailure('图片超过服务器允许的 20 MB 大小');
      }
      // 文件摘要在传输前验证，避免路径内容已变更。
      final String digest = (await sha256.bind(file.openRead()).first)
          .toString();
      if (digest != attachment.sha256) throw const ApiFailure('本机图片摘要不匹配');
      payload = FormData.fromMap(<String, dynamic>{
        'operationId': intent['operationId'],
        'attachmentId': attachment.id,
        'expectedRevision': intent['expectedRevision'] ?? '',
        'onlyIfMissing': intent['known'] == true ? 'false' : 'true',
        'sha256': digest,
        'file': await MultipartFile.fromFile(
          file.path,
          filename: '${attachment.id}${path.extension(file.path)}',
          contentType: DioMediaType.parse(
            attachment.mimeType ?? _mime(file.path),
          ),
        ),
      });
    }
    // 已认证的原子图片替换响应。
    final Response<Map<String, dynamic>> response =
        await _request<Map<String, dynamic>>(
          intent['attachmentId'] == null ? 'DELETE' : 'PUT',
          '/images/$type/$id',
          data: payload,
        );
    return Map<String, dynamic>.from(response.data!['image'] as Map);
  }

  /// 推断没有显式 MIME 的旧本机图片。
  String _mime(String filename) =>
      switch (path.extension(filename).toLowerCase()) {
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        _ => 'image/png',
      };

  /// 在事务内确认旧操作，不吞掉网络期间新增的本机选择。
  Future<void> _ack(
    String key,
    Map<String, dynamic> intent,
    Map<String, dynamic> remote,
  ) => database.transaction(() async {
    _check();
    // 当前操作可能已被用户的新选择替换。
    final Map<String, dynamic>? current = await _store.read('intent:$key');
    if (current?['operationId'] == intent['operationId']) {
      await _store.remove('intent:$key');
    } else if (current != null &&
        current['expectedRevision'] == intent['expectedRevision']) {
      current['expectedRevision'] = remote['revision'];
      current['known'] = true;
      await _store.write('intent:$key', current);
    }
    await _store.write('remote:$key', remote);
  });

  /// 冲突只移除当前被拒绝的操作。
  Future<void> _removeIfCurrent(String key, Map<String, dynamic> intent) =>
      database.transaction(() async {
        _check();
        if ((await _store.read('intent:$key'))?['operationId'] ==
            intent['operationId']) {
          await _store.remove('intent:$key');
        }
      });

  /// 读取当前业务行，类型只能来自本机固定枚举。
  Future<QueryRow?> _record(String type, String id) => database
      .customSelect(
        'SELECT image_attachment_id AS attachment_id,image_local_path AS local_path FROM ${type == 'inventoryImage' ? 'inventory_items' : 'memberships'} WHERE id=?',
        variables: <Variable<Object>>[Variable<String>(id)],
      )
      .getSingleOrNull();

  /// 更新本机图片关联，不改业务更新时间，因此不会产生业务同步循环。
  Future<void> _link(
    String type,
    String id,
    String? attachmentId,
    String? localPath,
  ) async {
    // 保留旧文件，但附件查询只能返回当前业务引用。
    await (database.update(database.attachments)..where(
          (Attachments table) =>
              table.businessType.equals(type) &
              table.businessId.equals(id) &
              (attachmentId == null
                  ? const Constant<bool>(true)
                  : table.id.equals(attachmentId).not()),
        ))
        .write(
          AttachmentsCompanion(deletedAt: Value<DateTime>(DateTime.now())),
        );
    if (attachmentId != null) {
      await (database.update(
        database.attachments,
      )..where((Attachments table) => table.id.equals(attachmentId))).write(
        const AttachmentsCompanion(
          deletedAt: Value<DateTime?>(null),
          uploadState: Value<String>('synced'),
        ),
      );
    }
    if (type == 'inventoryImage') {
      await (database.update(
        database.inventoryItems,
      )..where((InventoryItems table) => table.id.equals(id))).write(
        InventoryItemsCompanion(
          imageAttachmentId: Value<String?>(attachmentId),
          imageLocalPath: Value<String?>(localPath),
        ),
      );
    } else {
      await (database.update(
        database.memberships,
      )..where((Memberships table) => table.id.equals(id))).write(
        MembershipsCompanion(
          imageAttachmentId: Value<String?>(attachmentId),
          imageLocalPath: Value<String?>(localPath),
        ),
      );
    }
  }

  /// 先保存远端附件身份，再下载到临时文件、验证摘要、原子移动并恢复本机路径。
  Future<void> _applyRemote(
    String type,
    String id,
    Map<String, dynamic> remote,
    int maxBytes,
  ) async {
    // 业务图片状态键。
    final String key = '$type:$id';
    // 服务端附件标识，空表示显式清除。
    final String? attachmentId = remote['attachmentId'] as String?;
    // 当前本机业务引用。
    final QueryRow? record = await _record(type, id);
    if (record == null) return;
    // 复用已经验证过的本机附件文件。
    final Attachment? cached = attachmentId == null
        ? null
        : await (database.select(database.attachments)
                ..where((Attachments table) => table.id.equals(attachmentId)))
              .getSingleOrNull();
    // 当前缓存文件是否仍然存在且对应服务端摘要。
    final bool usable =
        cached?.localPath != null &&
        cached?.sha256 == remote['sha256'] &&
        await File(cached!.localPath!).exists();
    await database.transaction(() async {
      _check();
      if (await _store.read('intent:$key') != null) return;
      await _store.write('remote:$key', remote);
      await _link(type, id, attachmentId, usable ? cached.localPath : null);
    });
    if (attachmentId == null || usable) return;
    // 不可信远端大小必须在网络读取前验证。
    final int size = remote['sizeBytes'] as int;
    if (size < 1 || size > maxBytes) throw const ApiFailure('服务器图片大小超出限制');
    // 下载目录和随机临时文件均位于应用私有目录。
    final Directory root = await directoryProvider();
    final Directory directory = Directory(
      path.join(root.path, 'omni_butler', 'attachments'),
    );
    await directory.create(recursive: true);
    final File temporary = File(
      path.join(directory.path, '${const Uuid().v4()}.part'),
    );
    final File target = File(
      path.join(directory.path, '${const Uuid().v4()}.image'),
    );
    try {
      // 使用流式响应，按字节计数强制限制内存与落盘大小。
      final Response<ResponseBody> response = await _request<ResponseBody>(
        'GET',
        '/images/$type/$id/file',
        query: <String, dynamic>{'revision': remote['revision']},
        responseType: ResponseType.stream,
      );
      // 已下载字节数量。
      int length = 0;
      // 临时文件写入句柄。
      final IOSink sink = temporary.openWrite();
      try {
        await for (final List<int> chunk in response.data!.stream) {
          _check();
          length += chunk.length;
          if (length > maxBytes || length > size) {
            throw const ApiFailure('服务器图片响应超出声明大小');
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (length != size ||
          (await sha256.bind(temporary.openRead()).first).toString() !=
              remote['sha256']) {
        throw const ApiFailure('下载图片校验失败，将自动重试');
      }
      _check();
      await temporary.rename(target.path);
      await database.transaction(() async {
        _check();
        // 下载期间的新图片选择优先于旧响应。
        final QueryRow? current = await _record(type, id);
        if (current == null ||
            current.readNullable<String>('attachment_id') != attachmentId ||
            await _store.read('intent:$key') != null) {
          return;
        }
        // 缓存登记与业务路径一次提交。
        final DateTime now = DateTime.now();
        await database
            .into(database.attachments)
            .insertOnConflictUpdate(
              AttachmentsCompanion.insert(
                id: attachmentId,
                businessType: type,
                businessId: id,
                localPath: Value<String>(target.path),
                sha256: Value<String>(remote['sha256'] as String),
                mimeType: Value<String?>(remote['mimeType'] as String?),
                sizeBytes: Value<int>(size),
                uploadState: const Value<String>('synced'),
                createdAt: now,
                updatedAt: now,
                deletedAt: const Value<DateTime?>(null),
              ),
            );
        await _link(type, id, attachmentId, target.path);
      });
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
