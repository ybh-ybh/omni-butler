import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_attachments.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:uuid/uuid.dart';

/// 页面会话控制器，服务器拥有执行事实，本机只保存显示与恢复身份。
class AssistantChatController extends ChangeNotifier {
  /// 固定的服务器仓储；断开后为空，仅显示缓存。
  final AssistantRepository? repository;

  /// 独立缓存。
  final AssistantCache cache;

  /// 固定服务器与 owner 作用域。
  final String? scope;

  /// 上传本机已提交业务数据的检查点。
  final Future<void> Function() catchUp;

  /// 本机时区名称，不能作为模型自行提供的授权参数。
  final String? timeZone;

  /// 可注入显示时钟，测试不依赖真实等待或服务器时间偏差。
  final DateTime Function() now;

  /// 当前会话列表。
  List<Map<String, dynamic>> conversations = <Map<String, dynamic>>[];

  /// 最近打开过的会话缓存，断开服务器后只读。
  Map<String, dynamic> _histories = <String, dynamic>{};

  /// 当前显示消息。
  List<Map<String, dynamic>> messages = <Map<String, dynamic>>[];

  /// 每条回答的业务保存回执独立于模型任务，按固定数据源缓存。
  Map<String, dynamic> _savedNotes = <String, dynamic>{};

  /// 未核实结果的消息身份在重启后仍可显式重放同一个保存请求。
  final Set<String> _pendingNoteSaves = <String>{};

  /// 保存中的按钮只锁定对应回答，不改变聊天输入或任务计时。
  final Set<String> _savingNotes = <String>{};

  /// 公开的逐消息错误，避免将保存笔记错误混入模型执行状态。
  final Map<String, String> _noteErrors = <String, String>{};

  /// 仅供当前视图展示的发送快照，私有路径不进入消息缓存或请求。
  Map<String, dynamic>? _outgoingMessage;

  /// 发送期间把正文和附件移到消息区，底层草稿仍保留以便失败恢复。
  bool get hideComposerDraft =>
      _outgoingMessage?['_localOutgoing'] == true && (busy || pending != null);

  /// 服务端按原消息身份接管发送快照，不重复展示同一次提交。
  List<Map<String, dynamic>> get displayMessages => <Map<String, dynamic>>[
    ...messages,
    if (_outgoingMessage != null &&
        !messages.any(
          (message) =>
              message['clientMessageId'] ==
              _outgoingMessage!['clientMessageId'],
        ))
      _outgoingMessage!,
  ];

  /// 当前会话身份。
  String? conversationId;

  /// 当前任务快照。
  Map<String, dynamic>? run;

  /// 等待确认的真实预演。
  Map<String, dynamic>? plan;

  /// 结果卡定位的编辑草稿，引用不能作为操作授权。
  Map<String, dynamic>? draftReference;

  /// 未发出的输入草稿。
  String draft = '';

  /// 未明确完成提交的原始消息身份。
  Map<String, dynamic>? pending;

  /// 附件与正文共享当前会话和恢复身份，实际文件独立保存。
  late final AssistantAttachments attachments;

  /// 服务端已完整保存的消息，重放流片段不能再次追加。
  final Set<String> _completedMessages = <String>{};

  /// 当前任务事件游标。
  int cursor = 0;

  /// 当前操作错误。
  String? error;

  /// 页面正在执行按钮操作。
  bool busy = false;

  /// 语音输入期间冻结附件和其他发送入口，语音回写草稿仍允许。
  bool composerLocked = false;

  /// 切换聊天前完成语音取消与旧草稿落盘。
  Future<void> Function()? beforeConversationChange;

  /// 发送专属状态，重命名、置顶等操作不会启动提交计时。
  bool _submitting = false;

  /// 提交结果尚未返回时记录停止意图，获得真实运行身份后立即停止。
  bool _stopRequested = false;

  /// 提交开始时的视图代次，切换会话后不能串到旧回答。
  int? _submissionGeneration;

  /// 当前计时基线所属的运行；提交阶段尚无服务器身份。
  String? _elapsedRunId;

  /// 当前视图收到的服务器用时或提交用时基线。
  int? _elapsedBaseMs;

  /// 只对提交中、排队和运行中的状态外推显示时长。
  DateTime? _elapsedStartedAt;

  /// 定时器累计值兼容挂起后的补发节拍及 Flutter 测试虚拟时间。
  int _elapsedTickMs = 0;

  /// 每秒只触发界面重绘，不落盘缓存或发送请求。
  Timer? _elapsedTicker;

  /// 首次加载状态。
  bool loading = true;

  /// 当前是否只能查看缓存。
  bool offline = false;

  /// 原始 SSE 订阅。
  StreamSubscription<AssistantEvent>? _subscription;

  /// 当前 HTTP 流取消令牌。
  CancelToken? _streamToken;

  /// 最终用时事件已到达，但完整消息仍需从服务器核实。
  bool _settlementRefreshPending = false;

  /// 断流后的受控重连定时器。
  Timer? _reconnect;

  /// 流式与草稿缓存合并写入，避免每个token都重写全部历史。
  Timer? _cacheWrite;

  /// 每次切换会话推进的请求代次。
  int _viewGeneration = 0;

  /// 控制器销毁标志。
  bool _disposed = false;

  /// 有序缓存写入链。
  Future<void> _writes = Future<void>.value();

  /// 创建固定数据源的控制器。
  AssistantChatController({
    required this.repository,
    required this.cache,
    required this.scope,
    required this.catchUp,
    this.timeZone,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    attachments = AssistantAttachments(
      repository: repository,
      scope: scope,
      ensureConversation: _ensureAttachmentConversation,
      frozen: () => pending != null || busy || offline || composerLocked,
      persist: _persist,
      changed: () {
        if (_disposed) return;
        _saveForDisplay();
        notifyListeners();
      },
    );
  }

  /// 新聊天附件先留本机，首次发送前不为上传创建空会话。
  Future<String?> _ensureAttachmentConversation() async => conversationId;

  /// 只有固定仓储仍有效时允许发出请求。
  bool get connected => repository?.isCurrent == true && scope != null;

  /// 仅当前视图的真实发送准备或提交阶段显示即时计时。
  bool get submitting =>
      !_disposed &&
      connected &&
      _submitting &&
      _submissionGeneration == _viewGeneration;

  /// 返回当前发送或运行的显示用时，暂停和终态以服务器结算值为准。
  int? get liveElapsedMs {
    if (_disposed) return null;
    if (!submitting && run == null) return null;
    if (!submitting && _elapsedRunId != run?['id']) {
      return (((run?['status'] == 'queued' || run?['status'] == 'running')
                      ? (run?['liveElapsedMs'])
                      : null)
                  as num? ??
              run?['elapsedMs'] as num?)
          ?.toInt();
    }
    // 断开认证后只能展示最后确认的基线，不继续制造运行时间。
    final int clockExtra = connected && _elapsedStartedAt != null
        ? now().difference(_elapsedStartedAt!).inMilliseconds
        : 0;
    // 使用两种显示时钟的较大值，系统时钟回拨也不能造成倒计时。
    final int extra = connected && _elapsedStartedAt != null
        ? (clockExtra > _elapsedTickMs ? clockExtra : _elapsedTickMs)
        : 0;
    return _elapsedBaseMs == null
        ? null
        : _elapsedBaseMs! + (extra < 0 ? 0 : extra);
  }

  /// 重新锚定当前运行；服务器完成值允许纠正本机显示估计。
  void _syncElapsed({int? submissionElapsedMs}) {
    // 当前运行是否仍在自动处理，等待用户时不计入后续等待时间。
    final bool processing =
        run?['status'] == 'queued' || run?['status'] == 'running';
    // 只读缓存冻结最后一个实时快照，离线不继续增加估计用时。
    final bool ticking = connected && processing;
    // 同一运行更新不让显示值因快照传输延迟倒退。
    final int? previous = _elapsedRunId == run?['id'] ? liveElapsedMs : null;
    // 新服务端包含进行段用时，旧服务端仍可从累计值继续显示。
    final int? server =
        (((processing ? (run?['liveElapsedMs']) : null) as num?) ??
                (run?['elapsedMs'] as num?))
            ?.toInt();
    _elapsedRunId = run?['id'] as String?;
    _elapsedBaseMs = run == null ? null : (server ?? 0);
    if (ticking) {
      for (final int? candidate in <int?>[previous, submissionElapsedMs]) {
        if (candidate != null && candidate > _elapsedBaseMs!) {
          _elapsedBaseMs = candidate;
        }
      }
    }
    _elapsedStartedAt = ticking ? now() : null;
    _updateElapsedTicker();
  }

  /// 用单一定时器重绘当前计时，取消订阅或缓存写入不影响显示节奏。
  void _updateElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
    _elapsedTickMs = 0;
    if (_disposed || !connected || _elapsedStartedAt == null) return;
    // 固定创建计时器的视图代次，旧页面回调不能更新新会话。
    final int generation = _viewGeneration;
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!_current(generation)) {
        _elapsedTicker?.cancel();
        _elapsedTicker = null;
        return;
      }
      _elapsedTickMs = timer.tick * 1000;
      notifyListeners();
    });
  }

  /// 切换视图和销毁时清除提交计时，保留服务器任务本身。
  void _resetElapsed() {
    _outgoingMessage = null;
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
    _elapsedRunId = null;
    _elapsedBaseMs = null;
    _elapsedStartedAt = null;
    _elapsedTickMs = 0;
    _submitting = false;
    _stopRequested = false;
    _submissionGeneration = null;
  }

  /// 任务是否仍由后端处理或等待卡片。
  bool get active =>
      run != null && !assistantTerminalStates.contains(run!['status']);

  /// 生成或排队时输入区主操作显示停止，等待用户输入时仍允许发送。
  bool get processing =>
      submitting || <String>{'queued', 'running'}.contains(run?['status']);

  /// 运行期间允许停止，提交中先保存停止意图再等待真实身份。
  bool get canStop =>
      !_disposed &&
      connected &&
      !offline &&
      !_stopRequested &&
      (submitting ||
          !busy && <String>{'queued', 'running'}.contains(run?['status']));

  /// 已确认停止且没有新草稿时，允许明确发出继续消息。
  bool get canContinue =>
      !_disposed &&
      connected &&
      !offline &&
      !busy &&
      !processing &&
      run?['status'] == 'cancelled' &&
      pending == null &&
      draft.trim().isEmpty &&
      !attachments.hasDrafts &&
      !attachments.transferring;

  /// 只展示当前在线运行的安全重试提示，不写成历史执行事实。
  String? get recoveryReason {
    // 原因由服务器公开投影，不展示供应商异常原文。
    final Object? reason = assistantMap(run?['recovery'])['reason'];
    return connected &&
            !offline &&
            run?['status'] == 'running' &&
            reason is String &&
            reason.trim().isNotEmpty
        ? reason
        : null;
  }

  /// 正文结束后仍需接收最终计时，等待用户确认时继续监听远端变化。
  bool get _needsEvents =>
      active || run?['timingPending'] == true || _settlementRefreshPending;

  /// 判断异步结果仍属于当前视图。
  bool _current(int generation) =>
      !_disposed && connected && generation == _viewGeneration;

  /// 先恢复只读快照，再向同一服务器查询真实状态。
  Future<void> initialize() async {
    try {
      // 数据源缓存整体包含游标和消息。
      final Map<String, dynamic> snapshot = await cache.readScope(scope);
      if (_disposed) return;
      conversations = assistantItems(snapshot['conversations']);
      _histories = assistantMap(snapshot['histories']);
      messages = assistantItems(snapshot['messages']);
      _savedNotes = assistantMap(snapshot['savedNotes']);
      _pendingNoteSaves.addAll(
        (snapshot['pendingNoteSaves'] as List? ?? const <Object>[])
            .whereType<String>(),
      );
      for (final String id in _pendingNoteSaves) {
        _noteErrors[id] = '保存结果尚未确认，请重试核实';
      }
      conversationId = snapshot['conversationId'] as String?;
      draft = snapshot['draft'] as String? ?? '';
      draftReference = snapshot['draftReference'] is Map
          ? assistantMap(snapshot['draftReference'])
          : null;
      pending = snapshot['pending'] is Map
          ? assistantMap(snapshot['pending'])
          : null;
      attachments.restore(snapshot['attachments']);
      run = snapshot['run'] is Map ? assistantMap(snapshot['run']) : null;
      _syncElapsed();
      cursor = (snapshot['cursor'] as num?)?.toInt() ?? 0;
      offline = true;
      if (connected) {
        await refresh();
        await attachments.initialize();
      }
    } catch (failure) {
      error = _message(failure);
    } finally {
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// 提取用户可读异常，避免泄露网络请求头。
  String _message(Object failure) =>
      failure is ApiFailure ? failure.message : '助手暂时不可用，请稍后重试';

  /// 切换会话前保留可读历史，不把缓存内容当执行授权。
  void _rememberHistory() {
    _histories[conversationId ?? '__new__'] = <String, dynamic>{
      'messages': messages
          .map(
            (Map<String, dynamic> message) =>
                Map<String, dynamic>.from(message),
          )
          .toList(),
      'run': run,
      'cursor': cursor,
      'draft': draft,
      'draftReference': draftReference,
      'attachments': attachments.snapshot,
    };
  }

  /// 固定快照后顺序写入，快速事件不能逆序落盘。
  Future<void> _persist() {
    _cacheWrite?.cancel();
    if (scope == null || _disposed) return Future<void>.value();
    _rememberHistory();
    // 深拷贝在 cache.save 编码前固定消息内容。
    final Map<String, dynamic> snapshot = <String, dynamic>{
      'histories': Map<String, dynamic>.from(_histories),
      'conversations': conversations
          .map((Map<String, dynamic> item) => Map<String, dynamic>.from(item))
          .toList(),
      'messages': messages
          .map((Map<String, dynamic> item) => Map<String, dynamic>.from(item))
          .toList(),
      'conversationId': conversationId,
      'draft': draft,
      'attachments': attachments.snapshot,
      'draftReference': draftReference == null
          ? null
          : Map<String, dynamic>.from(draftReference!),
      'pending': pending == null ? null : Map<String, dynamic>.from(pending!),
      'run': run == null ? null : Map<String, dynamic>.from(run!),
      'cursor': cursor,
      'savedNotes': Map<String, dynamic>.from(_savedNotes),
      'pendingNoteSaves': _pendingNoteSaves.toList(),
    };
    _writes = _writes
        .catchError((Object _) {})
        .then((_) => cache.save(scope!, snapshot));
    return _writes;
  }

  /// 非授权性缓存错误只提示，不形成未处理异步异常。
  void _saveForDisplay() {
    _cacheWrite?.cancel();
    _cacheWrite = Timer(const Duration(milliseconds: 120), () {
      unawaited(
        _persist().catchError((Object failure) {
          if (!_disposed) {
            error = '本机助手缓存未能保存；请保持页面并核实服务器任务';
            notifyListeners();
          }
        }),
      );
    });
  }

  /// 草稿输入不触发远程调用。
  void setDraft(
    String value, {
    Map<String, dynamic>? reference,
    bool clearReference = false,
  }) {
    if (pending != null) return;
    draft = value;
    if (reference != null) {
      draftReference = <String, dynamic>{
        'id': reference['id'],
        'module': reference['module'],
        'label': reference['label'],
      };
    }
    if (clearReference || value.trim().isEmpty) draftReference = null;
    _saveForDisplay();
    if (!_disposed) notifyListeners();
  }

  /// 去掉编辑定位后保持用户已输入文字。
  void clearDraftReference() => setDraft(draft, clearReference: true);

  /// 隐藏窗口或退出前等待最新草稿真正写入缓存。
  Future<void> flushDraft() => _persist();

  /// 结束本页订阅，任务仍在后端运行。
  void _closeEvents() {
    _reconnect?.cancel();
    _streamToken?.cancel('页面不再订阅');
    unawaited(_subscription?.cancel());
    _subscription = null;
    _streamToken = null;
  }

  /// 依照服务端游标读取完整历史，重复游标明确失败而非无限循环。
  Future<Map<String, dynamic>> _readPages(String path) async {
    // 第一页同时携带当前任务信息。
    final Map<String, dynamic> first = await repository!.request('GET', path);
    // 列表分页内容使用真实身份合并。
    final List<Map<String, dynamic>> items = assistantItems(first['items']);
    // 已处理的分页身份，防止异常服务器循环。
    final Set<String> seen = <String>{};
    // 下页游标从服务端响应取得。
    String? next = first['nextCursor'] as String?;
    while (next != null && next.isNotEmpty) {
      if (!seen.add(next)) throw const ApiFailure('助手历史分页异常，请刷新后重试');
      // 游标作为URL参数，不拼成SQL或模型输入。
      final Map<String, dynamic> page = await repository!.request(
        'GET',
        '$path?cursor=${Uri.encodeQueryComponent(next)}',
      );
      if (path.endsWith('/messages')) {
        items.insertAll(0, assistantItems(page['items']));
      } else {
        items.addAll(assistantItems(page['items']));
      }
      next = page['nextCursor'] as String?;
    }
    return <String, dynamic>{...first, 'items': items};
  }

  /// 搜索结果独立返回，不能覆盖侧栏、当前消息或运行订阅。
  Future<Map<String, dynamic>> searchConversations(
    String query, {
    String? cursor,
  }) async {
    if (_disposed) throw const ApiFailure('聊天页面已关闭，请重新搜索');
    // 与服务端保持一致的查询长度，不悄悄截断用户输入。
    final String normalized = query.trim();
    if (normalized.length > 200) {
      throw const ApiFailure('搜索内容不能超过200个字符');
    }
    if (!connected) return _searchCachedConversations(normalized, cursor);
    try {
      // 参数编码后交给服务器执行字面子串匹配。
      final String parameters = <String>[
        'query=${Uri.encodeQueryComponent(normalized)}',
        if (cursor != null && cursor.isNotEmpty)
          'cursor=${Uri.encodeQueryComponent(cursor)}',
      ].join('&');
      // 只读取当前页，由弹窗负责分页、去重与过期请求丢弃。
      final Map<String, dynamic> response = await repository!.request(
        'GET',
        '/conversations?$parameters',
      );
      if (!connected || _disposed) {
        throw const ApiFailure('连接已改变，请重新搜索');
      }
      return <String, dynamic>{...response, 'cachedOnly': false};
    } catch (_) {
      if (!connected || _disposed) rethrow;
      return _searchCachedConversations(normalized, cursor);
    }
  }

  /// 离线仅检索本作用域已缓存的用户和助手正文，卡片不参与匹配。
  Map<String, dynamic> _searchCachedConversations(
    String query,
    String? cursor,
  ) {
    // 统一大小写，中文及百分号等字符保持字面含义。
    final String needle = query.toLowerCase();
    // 使用会话身份去重，不读取其他账号或服务器的缓存。
    final Map<String, Map<String, dynamic>> matches =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> conversation in conversations) {
      // 当前会话可能含尚未触发缓存落盘的最新正文。
      final String? id = conversation['id'] as String?;
      if (id == null || matches.containsKey(id)) continue;
      // 历史只包含此前打开过的会话，未缓存正文不补造搜索结果。
      final List<Map<String, dynamic>> cachedMessages = id == conversationId
          ? messages
          : assistantItems(assistantMap(_histories[id])['messages']);
      if (needle.isEmpty ||
          (conversation['title'] as String? ?? '').toLowerCase().contains(
            needle,
          ) ||
          cachedMessages.any(
            (Map<String, dynamic> message) =>
                (message['role'] == 'user' || message['role'] == 'assistant') &&
                (message['content'] as String? ?? '').toLowerCase().contains(
                  needle,
                ),
          )) {
        matches[id] = Map<String, dynamic>.from(conversation);
      }
    }
    // 离线按最近更新时间排序，身份作为相同时间的稳定次序。
    final List<Map<String, dynamic>> items = matches.values.toList()
      ..sort((Map<String, dynamic> left, Map<String, dynamic> right) {
        // ISO 时间戳与服务器返回格式一致，可直接比较。
        final int byTime = (right['updatedAt'] as String? ?? '').compareTo(
          left['updatedAt'] as String? ?? '',
        );
        return byTime != 0
            ? byTime
            : (right['id'] as String).compareTo(left['id'] as String);
      });
    // 在线断流后的游标若不在本机缓存中，应明确结束而非返回重复首页。
    final int index = cursor == null
        ? -1
        : items.indexWhere((Map<String, dynamic> item) => item['id'] == cursor);
    if (cursor != null && index < 0) {
      return <String, dynamic>{
        'items': <Map<String, dynamic>>[],
        'nextCursor': null,
        'cachedOnly': true,
      };
    }
    // 与在线接口相同，每页最多一百个真实会话。
    final List<Map<String, dynamic>> page = items
        .skip(index + 1)
        .take(100)
        .toList();
    return <String, dynamic>{
      'items': page,
      'nextCursor': index + 1 + page.length < items.length
          ? page.last['id']
          : null,
      'cachedOnly': true,
    };
  }

  /// 会话元数据变更只刷新列表，不切换当前聊天或重开事件流。
  Future<void> _refreshConversationList() async {
    // 服务器返回完整分页列表，包含跨设备置顶状态。
    final Map<String, dynamic> response = await _readPages('/conversations');
    if (!connected || _disposed) return;
    conversations = assistantItems(response['items']);
    await _persist();
  }

  /// 从服务器重新获取会话和任务，不重新提交消息。
  Future<void> refresh() async {
    if (!connected) return;
    // 当前页面请求代次。
    final int generation = _viewGeneration;
    try {
      // 服务器会话列表。
      final Map<String, dynamic> response = await _readPages('/conversations');
      if (!_current(generation)) return;
      conversations = assistantItems(response['items']);
      offline = false;
      error = null;
      if (conversationId != null) await _loadMessages(generation);
      await _persist();
    } catch (failure) {
      if (!_current(generation)) return;
      error = _message(failure);
      offline = true;
      if (_needsEvents) _scheduleReconnect(generation);
    }
    if (!_disposed) notifyListeners();
  }

  /// 执行步骤按服务端稳定身份合并，迟到快照不能让已结束步骤重新运行。
  List<Map<String, dynamic>> _executionSteps(
    Object? previous,
    Object? incoming,
  ) {
    // 同一回答可能跨重试关联多个运行，但每个步骤只显示一次。
    final Map<String, Map<String, dynamic>> byId =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> step in <Map<String, dynamic>>[
      ...assistantItems(previous),
      ...assistantItems(incoming),
    ]) {
      // 缺少真实身份的旧字段不合成可展开执行记录。
      final String? id = step['id'] as String?;
      if (id == null || id.isEmpty) continue;
      // 结束时间是服务端步骤已完成的事实，旧运行中快照不能覆盖它。
      final Map<String, dynamic>? saved = byId[id];
      byId[id] = saved?['finishedAt'] != null && step['finishedAt'] == null
          ? <String, dynamic>{...step, ...saved!}
          : <String, dynamic>{...?saved, ...step};
    }
    return byId.values.toList();
  }

  /// 消息更新保留已知执行链，只关联真实回答身份匹配的运行。
  Map<String, dynamic> _messageWithExecution(
    Map<String, dynamic> message,
    Map<String, dynamic>? previous, {
    Map<String, dynamic>? current,
  }) {
    // 查询和 SSE 都可提供更新的运行快照。
    final Map<String, dynamic>? source = current ?? run;
    // 正文完成帧可能先于最后一帧运行信息，按身份补全已有步骤。
    final List<Map<String, dynamic>> steps = _executionSteps(
      _executionSteps(previous?['executionSteps'], message['executionSteps']),
      source?['answerMessageId'] == message['id']
          ? (source?['executionSteps'])
          : null,
    );
    return <String, dynamic>{
      ...message,
      if (steps.isNotEmpty) 'executionSteps': steps,
    };
  }

  /// 服务端运行变更同步显示时钟和执行步骤，不把提交阶段归到旧回答。
  void _acceptRun(Map<String, dynamic>? next, {int? submissionElapsedMs}) {
    // 同一运行的步骤只补充或前进，不因兼容旧接口而被清空。
    final List<Map<String, dynamic>> steps = _executionSteps(
      run?['id'] == next?['id'] ? (run?['executionSteps']) : null,
      next?['executionSteps'],
    );
    run = next == null
        ? null
        : <String, dynamic>{
            ...next,
            if (steps.isNotEmpty) 'executionSteps': steps,
          };
    if (!submitting) _syncElapsed(submissionElapsedMs: submissionElapsedMs);
    messages = messages
        .map(
          (Map<String, dynamic> message) =>
              _messageWithExecution(message, message),
        )
        .toList();
  }

  /// 真实结果卡片保留服务端版本，正文只拼接同一运行已经读取的流片段。
  Map<String, dynamic> _unfinishedMessage(
    Map<String, dynamic> message,
    Map<String, dynamic>? local,
  ) {
    // 占位尚未收到首段时不能被当作可继续追加的正文。
    final bool hasPartial =
        local?['_streaming'] == true && local?['_awaitingDelta'] != true;
    return <String, dynamic>{
      ..._messageWithExecution(message, local),
      'content': hasPartial ? local!['content'] : message['content'],
      '_streaming': true,
      '_awaitingDelta': !hasPartial,
    };
  }

  /// 查询任务事实后才恢复本会话的流。
  Future<void> _loadMessages(int generation) async {
    // 全部消息包含当前真实任务。
    final Map<String, dynamic> response = await _readPages(
      '/conversations/${Uri.encodeComponent(conversationId!)}/messages',
    );
    if (!_current(generation)) return;
    // 最终正文与终态同时保存，运行中的回答行仍可能只是业务回执占位。
    final Map<String, dynamic>? current = response['activeRun'] is Map
        ? assistantMap(response['activeRun'])
        : null;
    // 重试可以沿用回答身份，但不同运行不能拼接旧的流式正文。
    final bool sameRun = run?['id'] == current?['id'];
    // 只有正在执行的回答允许继续接收正文，等待确认或输入的消息已定稿。
    final String? unfinishedId =
        current?['status'] == 'running' || current?['status'] == 'queued'
        ? (current?['answerMessageId'] as String?)
        : null;
    // 同一运行的本机正文与事件游标一起保留，服务器占位不能覆盖已读片段。
    final Map<String, Map<String, dynamic>> local =
        <String, Map<String, dynamic>>{
          if (sameRun)
            for (final Map<String, dynamic> message in messages)
              message['id'] as String: message,
        };
    // 已经收到完成事件时，迟到的运行中查询快照不能把回答降回占位状态。
    final bool completedLocally =
        unfinishedId != null &&
        sameRun &&
        _completedMessages.contains(unfinishedId);
    // 只有实际收到过 delta 的缓存才能安全沿用断点，否则必须重放全部正文。
    final bool hasPartial =
        local[unfinishedId]?['_streaming'] == true &&
        local[unfinishedId]?['_awaitingDelta'] != true;
    if (!sameRun ||
        (unfinishedId != null && !completedLocally && !hasPartial)) {
      cursor = 0;
    }
    messages = assistantItems(response['items'])
        .map((Map<String, dynamic> message) {
          if (message['id'] != unfinishedId) {
            return _messageWithExecution(
              message,
              local[message['id']],
              current: current,
            );
          }
          if (completedLocally) return local[unfinishedId] ?? message;
          return _unfinishedMessage(message, local[unfinishedId]);
        })
        .toList();
    _completedMessages.clear();
    // 持久消息已可见后释放临时快照，后续分页不再重建旧发送消息。
    if (!submitting &&
        pending == null &&
        _outgoingMessage != null &&
        messages.any(
          (message) =>
              message['clientMessageId'] ==
              _outgoingMessage!['clientMessageId'],
        )) {
      _outgoingMessage = null;
    }
    _completedMessages.addAll(
      messages
          .where(
            (Map<String, dynamic> message) => message['_streaming'] != true,
          )
          .map((Map<String, dynamic> message) => message['id'] as String),
    );
    // 纯只读回答在结束前还没有服务端消息行，也必须保留已读取的正文。
    final Set<String> loadedIds = messages
        .map((Map<String, dynamic> message) => message['id'] as String)
        .toSet();
    messages.addAll(
      local.values.where(
        (Map<String, dynamic> message) =>
            !loadedIds.contains(message['id']) &&
            (message['_streaming'] == true ||
                (completedLocally && message['id'] == unfinishedId)),
      ),
    );
    if (completedLocally && local.containsKey(unfinishedId)) {
      _completedMessages.add(unfinishedId);
    }
    _acceptRun(current);
    _settlementRefreshPending = false;
    plan = current?['plan'] is Map ? assistantMap(current!['plan']) : null;
    if (_needsEvents) {
      _listen(generation);
    } else {
      _closeEvents();
    }
  }

  /// 选择会话后不自动提交缓存中的旧消息。
  Future<void> select(String id) async {
    if (attachments.transferring) {
      error = '请等待附件上传完成后切换聊天';
      notifyListeners();
      return;
    }
    if (pending != null && pending!['conversationId'] != id) {
      error = '上一条消息结果尚未核实，请先恢复发送';
      notifyListeners();
      return;
    }
    await beforeConversationChange?.call();
    if (_disposed) return;
    _rememberHistory();
    _closeEvents();
    _viewGeneration++;
    _resetElapsed();
    _settlementRefreshPending = false;
    conversationId = id;
    // 先显示此前打开过的只读缓存，再查询最新服务器事实。
    final Map<String, dynamic> saved = assistantMap(_histories[id]);
    messages = assistantItems(saved['messages']);
    draft = saved['draft'] as String? ?? '';
    attachments.restore(saved['attachments']);
    draftReference = saved['draftReference'] is Map
        ? assistantMap(saved['draftReference'])
        : null;
    run = saved['run'] is Map ? assistantMap(saved['run']) : null;
    _syncElapsed();
    plan = null;
    cursor = (saved['cursor'] as num?)?.toInt() ?? 0;
    error = !connected && messages.isEmpty ? '此会话尚无本机缓存，请连接原服务器后查看' : null;
    notifyListeners();
    await refresh();
  }

  /// 新聊天只切换到本地草稿，第一条消息发送时才建立服务端会话。
  Future<void> create() => _operate(() async {
    if (attachments.transferring) throw const ApiFailure('请等待附件上传完成');
    if (pending != null) throw const ApiFailure('请先核实上一条消息的提交结果');
    await beforeConversationChange?.call();
    if (_disposed || conversationId == null) return;
    _rememberHistory();
    _closeEvents();
    _viewGeneration++;
    _resetElapsed();
    _settlementRefreshPending = false;
    conversationId = null;
    // 未发送草稿可在切换历史后恢复，永远不出现在会话列表。
    final Map<String, dynamic> saved = assistantMap(_histories['__new__']);
    messages = <Map<String, dynamic>>[];
    _completedMessages.clear();
    draft = saved['draft'] as String? ?? '';
    draftReference = saved['draftReference'] is Map
        ? assistantMap(saved['draftReference'])
        : null;
    attachments.restore(saved['attachments']);
    run = null;
    plan = null;
    cursor = 0;
    await _persist();
  });

  /// 重命名指定会话，省略身份时保持现有当前会话调用兼容。
  Future<void> rename(String title, {String? id}) => _operate(() async {
    // 在首次异步等待前固定目标，避免切换会话时误改另一个标题。
    final String? targetId = id ?? conversationId;
    if (targetId == null) return;
    await repository!.request(
      'PATCH',
      '/conversations/${Uri.encodeComponent(targetId)}',
      data: <String, String>{'title': title.trim()},
    );
    if (!connected || _disposed) return;
    await _refreshConversationList();
  });

  /// 持久化指定会话的置顶状态，活动时间由服务器保持不变。
  Future<void> setPinned(String id, bool pinned) => _operate(() async {
    // 使用服务器已经保存的回执，避免后续列表读取失败掩盖成功的置顶操作。
    final Map<String, dynamic> updated = await repository!.request(
      'PATCH',
      '/conversations/${Uri.encodeComponent(id)}',
      data: <String, bool>{'isPinned': pinned},
    );
    if (!connected || _disposed) return;
    if (updated['id'] != id || updated['isPinned'] != pinned) {
      throw const ApiFailure('服务器未能确认置顶状态，请刷新后重试');
    }
    conversations = conversations
        .map(
          (Map<String, dynamic> conversation) => conversation['id'] == id
              ? <String, dynamic>{...conversation, ...updated}
              : conversation,
        )
        .toList();
    await _persist();
  });

  /// 删除聊天后只清除显示，不删除服务器业务操作凭据。
  Future<void> delete({String? id}) => _operate(() async {
    if (attachments.transferring) throw const ApiFailure('请等待附件上传完成');
    // 在请求前固定点击目标，非当前会话不会关闭当前订阅。
    final String? targetId = id ?? conversationId;
    if (targetId == null) return;
    if (pending?['conversationId'] == targetId) {
      throw const ApiFailure('请先核实此会话上一条消息的提交结果');
    }
    if (conversationId == targetId) await beforeConversationChange?.call();
    if (_disposed) return;
    await repository!.request(
      'DELETE',
      '/conversations/${Uri.encodeComponent(targetId)}',
    );
    if (!connected || _disposed) return;
    if (conversationId != targetId) {
      await attachments.releaseFiles(
        assistantMap(_histories[targetId])['attachments'],
      );
    }
    _histories.remove(targetId);
    conversations.removeWhere(
      (Map<String, dynamic> item) => item['id'] == targetId,
    );
    if (conversationId == targetId) {
      _closeEvents();
      _viewGeneration++;
      _resetElapsed();
      _settlementRefreshPending = false;
      conversationId = null;
      messages = <Map<String, dynamic>>[];
      _completedMessages.clear();
      run = null;
      plan = null;
      draft = '';
      await attachments.clearAccepted();
      draftReference = null;
      cursor = 0;
    }
    await _persist();
    await _refreshConversationList();
  });

  /// 明确提交一条消息；未知响应保留原请求身份供显式重试。
  Future<void> send({Map<String, dynamic>? selection}) => _operate(() async {
    if (composerLocked) throw const ApiFailure('请先结束语音输入并等待转写完成');
    if (draft.trim().isEmpty && pending == null && !attachments.hasDrafts) {
      return;
    }
    if (pending == null && attachments.hasDrafts) {
      // 发送前向服务器读取当前模型能力，不能绕过界面门禁。
      final Map<String, dynamic> settings = await repository!.request(
        'GET',
        '/settings',
      );
      // 附件需要全部解析就绪且匹配当前模型能力。
      final String? reason = attachments.blockReason(settings);
      if (reason != null) throw ApiFailure(reason);
    }
    // 原身份重放可能已经提交，停止意图必须保留到实际运行得到核实。
    final bool replaying = pending != null;
    _stopRequested = pending?['stopRequested'] == true;
    // 发送准备属于当前视图，在同步检查和 POST 返回前就能显示计时。
    final int generation = _viewGeneration;
    _submitting = true;
    _submissionGeneration = generation;
    // 在任何异步上传之前固定可见消息和幂等身份，计时与消息同帧出现。
    final String clientMessageId =
        pending?['clientMessageId'] as String? ?? const Uuid().v4();
    _outgoingMessage = <String, dynamic>{
      'id': 'outgoing-$clientMessageId',
      'clientMessageId': clientMessageId,
      'role': 'user',
      'content':
          pending?['content'] ??
          (draft.trim().isEmpty ? '请概括附件内容' : draft.trim()),
      'createdAt': now().toIso8601String(),
      '_localOutgoing': true,
      'attachments': attachments.snapshot,
    };
    _elapsedRunId = null;
    _elapsedBaseMs = 0;
    _elapsedStartedAt = now();
    _updateElapsedTicker();
    notifyListeners();
    try {
      await catchUp();
      if (!_current(generation)) return;
      if (_stopRequested && !replaying) return;
      if (conversationId == null) {
        // 第一次发送需要先创建真实会话。
        final Map<String, dynamic> conversation = await repository!.request(
          'POST',
          '/conversations',
          data: <String, String>{'title': '新对话'},
        );
        if (!_current(generation)) return;
        conversationId = conversation['id'] as String;
        _histories.remove('__new__');
        await _persist();
      }
      if (_stopRequested && !replaying) return;
      if (pending == null && attachments.hasDrafts) {
        await attachments.prepareForSend(conversationId!);
        if (!_current(generation)) return;
        // 扫描PDF的视觉需求只有解析后才明确，发送模型请求前重新检查。
        final Map<String, dynamic> settings = await repository!.request(
          'GET',
          '/settings',
        );
        final String? reason = attachments.blockReason(settings);
        if (reason != null) throw ApiFailure(reason);
      }
      if (_stopRequested && !replaying) return;
      pending ??= <String, dynamic>{
        'clientMessageId': clientMessageId,
        'content': draft.trim().isEmpty ? '请概括附件内容' : draft.trim(),
        if (attachments.hasDrafts) 'attachmentIds': attachments.ids,
        'conversationId': conversationId,
        'timeZone': ?timeZone,
        'selection': ?selection,
        if (selection == null && draftReference != null)
          'reference': <String, dynamic>{
            'id': draftReference!['id'],
            'module': draftReference!['module'],
          },
      };
      await _persist();
      if (_stopRequested && !replaying) {
        // 此次POST尚未发出，可解除本机冻结并保留原草稿。
        pending = null;
        await _persist();
        return;
      }
      // 永远使用原会话与消息身份重试。
      Map<String, dynamic> result = await _submitPending(generation);
      if (!_current(generation)) return;
      if (_stopRequested || pending?['stopRequested'] == true) {
        // 消息已被服务器接受后才有停止目标；响应未知时仍保留原消息身份。
        result = await repository!.request(
          'POST',
          '/runs/${Uri.encodeComponent(result['id'] as String)}/stop',
        );
        if (!_current(generation)) return;
      }
      // 已显示的提交等待时间平滑交给当前运行，最终用时仍由服务端结算。
      final int? submissionElapsed = liveElapsedMs;
      _submitting = false;
      _submissionGeneration = null;
      _acceptRun(result, submissionElapsedMs: submissionElapsed);
      plan = result['plan'] is Map ? assistantMap(result['plan']) : null;
      pending = null;
      draft = '';
      // 已接受的附件改用鉴权接口加载，清理草稿文件不会留下失效路径。
      _outgoingMessage = <String, dynamic>{
        ..._outgoingMessage!,
        '_localOutgoing': false,
        'attachments': attachments.snapshot
            .map(
              (item) => <String, dynamic>{
                for (final entry in item.entries)
                  if (entry.key != 'localPath') entry.key: entry.value,
              },
            )
            .toList(),
      };
      await attachments.clearAccepted();
      draftReference = null;
      cursor = 0;
      await _persist();
      await refresh();
    } finally {
      if (_submissionGeneration == generation) {
        // 明确失败或出站前停止时恢复草稿；未知结果保留原身份和消息快照。
        if (pending == null) _outgoingMessage = null;
        _submitting = false;
        _submissionGeneration = null;
        if (_current(generation)) _syncElapsed();
      }
    }
  });

  /// 只有服务端明确拒绝接受的输入才解除冻结，未知结果始终保留原身份。
  Future<Map<String, dynamic>> _submitPending(int generation) async {
    try {
      return await repository!.request(
        'POST',
        '/conversations/${Uri.encodeComponent(pending!['conversationId'] as String)}/messages',
        data: <String, dynamic>{
          'clientMessageId': pending!['clientMessageId'],
          'content': pending!['content'],
          if (pending!['attachmentIds'] != null)
            'attachmentIds': pending!['attachmentIds'],
          if (pending!['timeZone'] != null) 'timeZone': pending!['timeZone'],
          if (pending!['selection'] != null) 'selection': pending!['selection'],
          if (pending!['reference'] != null) 'reference': pending!['reference'],
        },
      );
    } on AssistantApiFailure catch (failure) {
      // 只信任固定业务错误码，泛化代理 400 不足以证明服务器没有接受消息。
      final bool rejected =
          failure.statusCode == 413 ||
          (<int>{400, 422}.contains(failure.statusCode) &&
              (<String>{
                    'ASSISTANT_INPUT_INVALID',
                    'AI_IMAGE_INPUT_UNSUPPORTED',
                  }.contains(failure.code) ||
                  failure.code?.startsWith('ATTACHMENT_') == true));
      if (rejected && _current(generation)) {
        pending = null;
        await _persist();
      }
      rethrow;
    }
  }

  /// 按固定预览版本确认或取消；提交前先等待本机业务修改上传。
  Future<void> decide(String decision) => _operate(() async {
    // 点击时固定卡片，等待同步期间的改变不能替换授权。
    final Map<String, dynamic> fixed = Map<String, dynamic>.from(plan!);
    if (decision == 'confirm') await catchUp();
    await repository!.request(
      'POST',
      '/plans/${Uri.encodeComponent(fixed['id'] as String)}/decision',
      data: <String, dynamic>{
        'version': fixed['version'],
        'previewHash': fixed['previewHash'],
        'decision': decision,
      },
    );
    await refresh();
  });

  /// 停止只影响未完成操作，不宣称撤销已保存数据。
  Future<void> stop() async {
    if (submitting) {
      if (_stopRequested) return;
      _stopRequested = true;
      if (pending != null) {
        pending!['stopRequested'] = true;
        await _persist();
      }
      if (!_disposed) notifyListeners();
      return;
    }
    await _runCommand('stop');
  }

  /// 取消的任务不复活旧写入批准；用可见新消息在同一聊天继续。
  Future<void> continueConversation() async {
    if (!canContinue) return;
    setDraft('继续');
    await send();
  }

  /// 显式重试保留原任务业务回执。
  Future<void> retry() => _runCommand('retry');

  /// 当前设备明确接管已有任务。
  Future<void> takeover() => _runCommand('takeover');

  /// 撤销仅限服务器声明可以补偿的单条新增。
  Future<void> undo({String? runId}) => _runCommand('undo', runId: runId);

  /// 运行控制统一查询最新事实。
  Future<void> _runCommand(String command, {String? runId}) =>
      _operate(() async {
        // 卡片回调不能在重绘前误用后来生成的新任务身份。
        final String target = runId ?? run!['id'] as String;
        if (runId != null && (run?['id'] != runId || run?['canUndo'] != true)) {
          throw const ApiFailure('任务状态已更新，请重新核对执行结果');
        }
        await repository!.request(
          'POST',
          '/runs/${Uri.encodeComponent(target)}/$command',
        );
        await refresh();
      });

  /// 服务器历史和本机成功回执共同恢复只保存一次的展示事实。
  Map<String, dynamic>? savedNote(String messageId) {
    // 当前历史消息可能由另一设备保存过。
    final Map<String, dynamic>? message = messages
        .where((item) => item['id'] == messageId)
        .firstOrNull;
    // 缓存只作显示提示，写入去重始终由服务器回执保证。
    final Map<String, dynamic> result = assistantMap(
      message?['savedNote'] ?? _savedNotes[messageId],
    );
    return result['noteId'] is String && result['savedAt'] is String
        ? result
        : null;
  }

  /// 对应消息正在等待业务接口响应。
  bool savingNote(String messageId) => _savingNotes.contains(messageId);

  /// 已保存的服务器事实优先于之前的暂时错误。
  String? noteSaveError(String messageId) =>
      savedNote(messageId) == null ? _noteErrors[messageId] : null;

  /// 按消息身份直接保存正文，不修改草稿、pending或任何模型运行。
  Future<void> saveNote(String messageId) async {
    if (_disposed ||
        !connected ||
        offline ||
        savingNote(messageId) ||
        savedNote(messageId) != null) {
      return;
    }
    // 临时流式片段和用户消息不能当作服务器持久回答保存。
    final Map<String, dynamic>? message = messages
        .where((item) => item['id'] == messageId)
        .firstOrNull;
    if (message == null ||
        message['role'] != 'assistant' ||
        message['_streaming'] == true) {
      return;
    }
    // 与正式笔记领域接口保持相同的字符串长度口径，不截断正文。
    final String content = message['content'] as String? ?? '';
    if (content.trim().isEmpty || content.length > 20000) {
      _noteErrors[messageId] = content.trim().isEmpty
          ? '回答正文为空，无法保存为笔记'
          : '笔记正文不能超过 20,000 字符，请缩短内容后保存';
      notifyListeners();
      return;
    }
    // 固定视图代次，切换会话或来源后不接收迟到结果。
    final int generation = _viewGeneration;
    _savingNotes.add(messageId);
    _pendingNoteSaves.add(messageId);
    _noteErrors.remove(messageId);
    notifyListeners();
    try {
      await _persist();
      if (!_current(generation)) return;
      // 稳定消息身份就是重放身份；正文与记录时间只由服务器决定。
      final Map<String, dynamic> result = await repository!.request(
        'POST',
        '/messages/${Uri.encodeComponent(messageId)}/note',
      );
      if (!_current(generation)) return;
      if (result['noteId'] is! String ||
          (result['noteId'] as String).isEmpty ||
          result['savedAt'] is! String ||
          DateTime.tryParse(result['savedAt'] as String) == null) {
        throw const ApiFailure('保存响应未能核实');
      }
      _savedNotes[messageId] = <String, dynamic>{
        'noteId': result['noteId'],
        'savedAt': result['savedAt'],
      };
      _pendingNoteSaves.remove(messageId);
      _noteErrors.remove(messageId);
      _saveForDisplay();
    } catch (failure) {
      if (!_current(generation)) return;
      // 明确拒绝没有新建笔记；网络和不完整响应须重放原消息核实。
      if (failure is AssistantApiFailure &&
          <int>{
            400,
            401,
            403,
            404,
            405,
            409,
            422,
          }.contains(failure.statusCode)) {
        _pendingNoteSaves.remove(messageId);
        _noteErrors[messageId] =
            failure.statusCode == 405 ||
                failure.message.startsWith('Cannot POST ')
            ? '当前服务器尚不支持直接保存笔记，请更新服务器后重试'
            : failure.message;
      } else {
        _noteErrors[messageId] = '保存结果尚未确认，请重试核实';
      }
      _saveForDisplay();
    } finally {
      _savingNotes.remove(messageId);
      if (!_disposed && connected) notifyListeners();
    }
  }

  /// 包装按钮操作；异步响应必须仍属于原服务器。
  Future<void> _operate(Future<void> Function() action) async {
    if (busy || !connected) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (failure) {
      if (!_disposed && connected) error = _message(failure);
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// 最终用时到达后仅读取消息，不重放流或用运行总时长替代回答聚合。
  Future<void> _refreshSettledMessages(int generation, String runId) async {
    // 固定当前回答，重试或继续确认后不能应用前一轮的异步结果。
    final Object? answerId = run?['answerMessageId'];
    // 固定当前会话，防止请求完成时切换了展示目标。
    final String? targetId = conversationId;
    if (targetId == null) return;
    _settlementRefreshPending = true;
    try {
      // 服务端消息包含跨重试聚合后的最终用时。
      final Map<String, dynamic> response = await _readPages(
        '/conversations/${Uri.encodeComponent(targetId)}/messages',
      );
      if (!_current(generation) ||
          run?['id'] != runId ||
          run?['answerMessageId'] != answerId) {
        return;
      }
      // 同一流可能继续输出新消息，查询快照不能删掉后来抵达的正文。
      final Map<String, Map<String, dynamic>> byId =
          <String, Map<String, dynamic>>{
            for (final Map<String, dynamic> message in messages)
              message['id'] as String: message,
          };
      // 历史等待事件可能在确认后重放，以查询快照识别仍在生成的回答。
      final Map<String, dynamic> current = assistantMap(response['activeRun']);
      // 结算读取不能把同一运行的保存回执占位误标为最终正文。
      final String? unfinishedId =
          current['id'] == runId &&
              (current['status'] == 'running' || current['status'] == 'queued')
          ? (current['answerMessageId'] as String?)
          : null;
      for (final Map<String, dynamic> message in assistantItems(
        response['items'],
      )) {
        if (message['id'] == unfinishedId) {
          if (!_completedMessages.contains(unfinishedId)) {
            byId[unfinishedId!] = _unfinishedMessage(
              message,
              byId[unfinishedId],
            );
          }
          continue;
        }
        byId[message['id'] as String] = _messageWithExecution(
          message,
          byId[message['id']],
          current: current,
        );
        _completedMessages.add(message['id'] as String);
      }
      messages = byId.values.toList();
      _settlementRefreshPending = false;
      if (!_needsEvents) _closeEvents();
      _saveForDisplay();
      notifyListeners();
    } catch (failure) {
      if (!_current(generation) || run?['id'] != runId) return;
      error = '回答已收到，正在恢复最终用时';
      _scheduleReconnect(generation);
      notifyListeners();
    }
  }

  /// 按持久游标订阅事件，重复轮询不会重复拼接。
  void _listen(int generation) {
    _closeEvents();
    if (!_current(generation) || run == null) return;
    // 此次事件流固定的运行身份。
    final String runId = run!['id'] as String;
    // 断开认证会话时同步取消底层请求。
    final CancelToken token = repository!.auth.createSessionStreamToken(
      repository!.generation,
    );
    _streamToken = token;
    _subscription = repository!
        .events(runId, cursor, token)
        .listen(
          (AssistantEvent event) {
            if (!_current(generation) ||
                token.isCancelled ||
                event.runId != runId ||
                event.seq <= cursor) {
              return;
            }
            cursor = event.seq;
            if (event.type == 'message.delta') {
              // 同一消息只追加当前序号的完整文本片段。
              final String id = event.data['messageId'] as String? ?? '';
              if (_completedMessages.contains(id)) {
                _saveForDisplay();
                return;
              }
              // 查找当前流式消息。
              final int index = messages.indexWhere(
                (Map<String, dynamic> message) => message['id'] == id,
              );
              if (index < 0) {
                messages.add(<String, dynamic>{
                  'id': id,
                  'role': 'assistant',
                  '_streaming': true,
                  'content': event.data['text'] ?? '',
                  'cards': <Object>[],
                });
              } else {
                messages[index] = <String, dynamic>{
                  ...messages[index],
                  'content':
                      '${messages[index]['_awaitingDelta'] == true ? '' : messages[index]['content'] ?? ''}${event.data['text'] ?? ''}',
                  '_streaming': true,
                  '_awaitingDelta': false,
                };
              }
            } else if (event.type == 'message.completed') {
              // 完整消息覆盖临时片段。
              final Map<String, dynamic> completed = assistantMap(
                event.data['message'],
              );
              // 完整正文到达时保留该回答已经展示的执行链。
              final Map<String, dynamic>? previous = messages
                  .where(
                    (Map<String, dynamic> item) =>
                        item['id'] == completed['id'],
                  )
                  .firstOrNull;
              // 步骤绑定稳定回答身份，不能借用上一条任务的步骤。
              final Map<String, dynamic> message = _messageWithExecution(
                completed,
                previous,
              );
              messages.removeWhere(
                (Map<String, dynamic> item) => item['id'] == message['id'],
              );
              _completedMessages.add(message['id'] as String);
              messages.add(message);
            } else if (event.type == 'run.updated') {
              _acceptRun(assistantMap(event.data['run']));
              plan = run?['plan'] is Map ? assistantMap(run!['plan']) : plan;
            } else if (event.type == 'plan.ready') {
              plan = assistantMap(event.data['plan']);
            } else if (event.type == 'error') {
              error = event.data['message'] as String? ?? '助手执行失败';
            }
            messages = messages
                .map(
                  (Map<String, dynamic> message) =>
                      _messageWithExecution(message, message),
                )
                .toList();
            _saveForDisplay();
            notifyListeners();
            if (event.type == 'run.updated' &&
                run?['timingPending'] != true &&
                run?['status'] != 'running' &&
                run?['status'] != 'queued') {
              unawaited(_refreshSettledMessages(generation, runId));
            }
          },
          onError: (Object failure) {
            if (_current(generation) && !token.isCancelled) {
              error = '连接中断，正在恢复；服务器任务仍会继续';
              notifyListeners();
              _scheduleReconnect(generation);
            }
          },
          onDone: () {
            if (_current(generation) && _needsEvents && !token.isCancelled) {
              _scheduleReconnect(generation);
            }
          },
        );
  }

  /// 断流后查询同一任务，禁止因超时重新创建任务。
  void _scheduleReconnect(int generation) {
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 3), () {
      if (_current(generation)) unawaited(refresh());
    });
  }

  /// 页面退出释放事件；已经持久化的任务继续由后端处理。
  @override
  void dispose() {
    _cacheWrite?.cancel();
    unawaited(_persist().catchError((Object _) {}));
    _disposed = true;
    attachments.dispose();
    _resetElapsed();
    _closeEvents();
    super.dispose();
  }
}
