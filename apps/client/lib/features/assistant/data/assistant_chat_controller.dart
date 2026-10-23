import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
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

  /// 当前会话列表。
  List<Map<String, dynamic>> conversations = <Map<String, dynamic>>[];

  /// 最近打开过的会话缓存，断开服务器后只读。
  Map<String, dynamic> _histories = <String, dynamic>{};

  /// 当前显示消息。
  List<Map<String, dynamic>> messages = <Map<String, dynamic>>[];

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

  /// 服务端已完整保存的消息，重放流片段不能再次追加。
  final Set<String> _completedMessages = <String>{};

  /// 当前任务事件游标。
  int cursor = 0;

  /// 当前操作错误。
  String? error;

  /// 页面正在执行按钮操作。
  bool busy = false;

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
  });

  /// 只有固定仓储仍有效时允许发出请求。
  bool get connected => repository?.isCurrent == true && scope != null;

  /// 任务是否仍由后端处理或等待卡片。
  bool get active =>
      run != null && !assistantTerminalStates.contains(run!['status']);

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
      conversationId = snapshot['conversationId'] as String?;
      draft = snapshot['draft'] as String? ?? '';
      draftReference = snapshot['draftReference'] is Map
          ? assistantMap(snapshot['draftReference'])
          : null;
      pending = snapshot['pending'] is Map
          ? assistantMap(snapshot['pending'])
          : null;
      run = snapshot['run'] is Map ? assistantMap(snapshot['run']) : null;
      cursor = (snapshot['cursor'] as num?)?.toInt() ?? 0;
      offline = true;
      if (connected) await refresh();
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
    if (conversationId == null) return;
    _histories[conversationId!] = <String, dynamic>{
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
      'draftReference': draftReference == null
          ? null
          : Map<String, dynamic>.from(draftReference!),
      'pending': pending == null ? null : Map<String, dynamic>.from(pending!),
      'run': run == null ? null : Map<String, dynamic>.from(run!),
      'cursor': cursor,
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

  /// 查询任务事实后才恢复本会话的流。
  Future<void> _loadMessages(int generation) async {
    // 全部消息包含当前真实任务。
    final Map<String, dynamic> response = await _readPages(
      '/conversations/${Uri.encodeComponent(conversationId!)}/messages',
    );
    if (!_current(generation)) return;
    // 尚未完成的本机流文本与游标共同恢复。
    final List<Map<String, dynamic>> streaming = messages
        .where((Map<String, dynamic> message) => message['_streaming'] == true)
        .toList();
    messages = assistantItems(response['items']);
    _completedMessages.clear();
    _completedMessages.addAll(
      messages.map((Map<String, dynamic> message) => message['id'] as String),
    );
    messages.addAll(
      streaming.where(
        (Map<String, dynamic> message) =>
            !_completedMessages.contains(message['id']),
      ),
    );
    // 任务更换时不能复用另一条任务的游标。
    final Map<String, dynamic>? current = response['activeRun'] is Map
        ? assistantMap(response['activeRun'])
        : null;
    if (run?['id'] != current?['id']) cursor = 0;
    run = current;
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
    if (pending != null && pending!['conversationId'] != id) {
      error = '上一条消息结果尚未核实，请先恢复发送';
      notifyListeners();
      return;
    }
    _rememberHistory();
    _closeEvents();
    _viewGeneration++;
    _settlementRefreshPending = false;
    conversationId = id;
    // 先显示此前打开过的只读缓存，再查询最新服务器事实。
    final Map<String, dynamic> saved = assistantMap(_histories[id]);
    messages = assistantItems(saved['messages']);
    draft = saved['draft'] as String? ?? '';
    draftReference = saved['draftReference'] is Map
        ? assistantMap(saved['draftReference'])
        : null;
    run = saved['run'] is Map ? assistantMap(saved['run']) : null;
    plan = null;
    cursor = (saved['cursor'] as num?)?.toInt() ?? 0;
    error = !connected && messages.isEmpty ? '此会话尚无本机缓存，请连接原服务器后查看' : null;
    notifyListeners();
    await refresh();
  }

  /// 新建会话通过真实接口持久化。
  Future<void> create() => _operate(() async {
    if (pending != null) throw const ApiFailure('请先核实上一条消息的提交结果');
    // 后端创建的真实会话。
    final Map<String, dynamic> conversation = await repository!.request(
      'POST',
      '/conversations',
      data: <String, String>{'title': '新对话'},
    );
    if (!connected || _disposed) return;
    await select(conversation['id'] as String);
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
    await repository!.request(
      'PATCH',
      '/conversations/${Uri.encodeComponent(id)}',
      data: <String, bool>{'isPinned': pinned},
    );
    if (!connected || _disposed) return;
    await _refreshConversationList();
  });

  /// 删除聊天后只清除显示，不删除服务器业务操作凭据。
  Future<void> delete({String? id}) => _operate(() async {
    // 在请求前固定点击目标，非当前会话不会关闭当前订阅。
    final String? targetId = id ?? conversationId;
    if (targetId == null) return;
    if (pending?['conversationId'] == targetId) {
      throw const ApiFailure('请先核实此会话上一条消息的提交结果');
    }
    await repository!.request(
      'DELETE',
      '/conversations/${Uri.encodeComponent(targetId)}',
    );
    if (!connected || _disposed) return;
    _histories.remove(targetId);
    conversations.removeWhere(
      (Map<String, dynamic> item) => item['id'] == targetId,
    );
    if (conversationId == targetId) {
      _closeEvents();
      _viewGeneration++;
      _settlementRefreshPending = false;
      conversationId = null;
      messages = <Map<String, dynamic>>[];
      _completedMessages.clear();
      run = null;
      plan = null;
      draft = '';
      draftReference = null;
      cursor = 0;
    }
    await _persist();
    await _refreshConversationList();
  });

  /// 明确提交一条消息；未知响应保留原请求身份供显式重试。
  Future<void> send({Map<String, dynamic>? selection}) => _operate(() async {
    if (draft.trim().isEmpty && pending == null) return;
    await catchUp();
    if (!connected || _disposed) return;
    if (conversationId == null) {
      // 第一次发送需要先创建真实会话。
      final Map<String, dynamic> conversation = await repository!.request(
        'POST',
        '/conversations',
        data: <String, String>{'title': '新对话'},
      );
      conversationId = conversation['id'] as String;
    }
    pending ??= <String, dynamic>{
      'clientMessageId': const Uuid().v4(),
      'content': draft.trim(),
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
    // 永远使用原会话与消息身份重试。
    final Map<String, dynamic> result = await repository!.request(
      'POST',
      '/conversations/${Uri.encodeComponent(pending!['conversationId'] as String)}/messages',
      data: <String, dynamic>{
        'clientMessageId': pending!['clientMessageId'],
        'content': pending!['content'],
        if (pending!['timeZone'] != null) 'timeZone': pending!['timeZone'],
        if (pending!['selection'] != null) 'selection': pending!['selection'],
        if (pending!['reference'] != null) 'reference': pending!['reference'],
      },
    );
    if (!connected || _disposed) return;
    run = result;
    plan = result['plan'] is Map ? assistantMap(result['plan']) : null;
    pending = null;
    draft = '';
    draftReference = null;
    cursor = 0;
    await _persist();
    await refresh();
  });

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
  Future<void> stop() => _runCommand('stop');

  /// 显式重试保留原任务业务回执。
  Future<void> retry() => _runCommand('retry');

  /// 当前设备明确接管已有任务。
  Future<void> takeover() => _runCommand('takeover');

  /// 撤销仅限服务器声明可以补偿的单条新增。
  Future<void> undo() => _runCommand('undo');

  /// 运行控制统一查询最新事实。
  Future<void> _runCommand(String command) => _operate(() async {
    await repository!.request(
      'POST',
      '/runs/${Uri.encodeComponent(run!['id'] as String)}/$command',
    );
    await refresh();
  });

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
      for (final Map<String, dynamic> message in assistantItems(
        response['items'],
      )) {
        byId[message['id'] as String] = message;
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
                      '${messages[index]['content'] ?? ''}${event.data['text'] ?? ''}',
                };
              }
            } else if (event.type == 'message.completed') {
              // 完整消息覆盖临时片段。
              final Map<String, dynamic> message = assistantMap(
                event.data['message'],
              );
              messages.removeWhere(
                (Map<String, dynamic> item) => item['id'] == message['id'],
              );
              _completedMessages.add(message['id'] as String);
              messages.add(message);
            } else if (event.type == 'run.updated') {
              run = assistantMap(event.data['run']);
              plan = run?['plan'] is Map ? assistantMap(run!['plan']) : plan;
            } else if (event.type == 'plan.ready') {
              plan = assistantMap(event.data['plan']);
            } else if (event.type == 'error') {
              error = event.data['message'] as String? ?? '助手执行失败';
            }
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
    _closeEvents();
    super.dispose();
  }
}
