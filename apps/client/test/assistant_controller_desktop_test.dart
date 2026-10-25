import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/assistant/data/assistant_chat_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';

/// 使用内存认证代次，测试绝不触碰真实服务器或安全存储。
class _DesktopAuth implements AuthRepository {
  /// 可模拟连接切换的固定代次。
  int generation = 1;

  /// 返回当前连接代次。
  @override
  int get sessionGeneration => generation;

  /// 为每条事件流创建独立取消令牌。
  @override
  CancelToken createSessionStreamToken(int generation) => CancelToken();

  /// 其他认证方法不应在此数据测试中调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 以真实控制器验证接口契约、流取消及服务器最终快照。
class _DesktopRepository extends AssistantRepository {
  /// 固定接口请求记录，便于验证目标身份和搜索参数。
  final List<({String method, String path, Object? data})> calls =
      <({String method, String path, Object? data})>[];

  /// 每次订阅使用独立异步事件流。
  final List<StreamController<AssistantEvent>> streams =
      <StreamController<AssistantEvent>>[];

  /// 保留真实取消令牌以验证非当前会话操作没有中断当前流。
  final List<CancelToken> tokens = <CancelToken>[];

  /// 订阅恢复使用的事件序号。
  final List<int> cursors = <int>[];

  /// 服务端会话列表，调用者可在测试中构造多页。
  List<Map<String, dynamic>> conversations = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'current',
      'title': '当前聊天',
      'isPinned': false,
      'updatedAt': '2026-10-23T09:00:00Z',
    },
    <String, dynamic>{
      'id': 'other',
      'title': '其他聊天',
      'isPinned': false,
      'updatedAt': '2026-10-22T09:00:00Z',
    },
  ];

  /// 服务端已持久化消息。
  List<Map<String, dynamic>> messages = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'answer',
      'role': 'assistant',
      'content': '回复正文',
      'elapsedMs': null,
    },
  ];

  /// 最新运行始终可查询，包括终态结算窗口。
  Map<String, dynamic>? run = <String, dynamic>{
    'id': 'run',
    'status': 'running',
    'answerMessageId': 'answer',
    'elapsedMs': 0,
    'timingPending': false,
  };

  /// 搜索网络异常只允许使用当前本机缓存。
  bool searchFails = false;

  /// 列表重读失败不能覆盖已经收到的置顶成功回执。
  bool conversationReadsFail = false;

  /// 模拟旧服务端未保存置顶字段，客户端不得假装成功。
  bool ignoresPinUpdate = false;

  /// 特定搜索分页的合成响应。
  final Map<String, Map<String, dynamic>> searchResponses =
      <String, Map<String, dynamic>>{};

  /// 可控制搜索结束顺序，测试认证代次变更。
  Completer<Map<String, dynamic>>? delayedSearch;

  /// 控制最终用时读取失败的次数。
  int messageFailures = 0;

  /// 单次消息查询可以晚于事件完成，复现旧 HTTP 快照迟到。
  Completer<Map<String, dynamic>>? delayedMessages;

  /// 精确通知测试查询已进入等待，不依靠固定延时制造竞态。
  Completer<void>? messageReadStarted;

  /// 控制发送接口返回时间，覆盖服务器尚未分配任务身份的阶段。
  Completer<Map<String, dynamic>>? delayedSend;

  /// 明确标记消息 POST 已经开始，不用长等待猜测请求顺序。
  Completer<void>? sendStarted;

  /// 创建当前连接内存接口。
  _DesktopRepository(super.auth);

  /// 返回合成服务端事实，保留目标写入语义。
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    calls.add((method: method, path: path, data: data));
    if (method == 'POST' &&
        path.startsWith('/runs/') &&
        path.endsWith('/stop')) {
      run = <String, dynamic>{...?run, 'status': 'cancelled'};
      return run!;
    }
    if (path.startsWith('/conversations?')) {
      if (searchFails) throw const ApiFailure('网络不可用');
      if (delayedSearch != null) return delayedSearch!.future;
      return searchResponses[path] ??
          <String, dynamic>{'items': conversations, 'nextCursor': null};
    }
    if (path == '/conversations') {
      if (method == 'POST') {
        conversations.add(<String, dynamic>{
          'id': 'first-message-chat',
          'title': '新对话',
        });
        return <String, dynamic>{'id': 'first-message-chat'};
      }
      if (conversationReadsFail) throw const ApiFailure('列表暂时不可读');
      return <String, dynamic>{'items': conversations, 'nextCursor': null};
    }
    if (path.endsWith('/messages') && method == 'POST') {
      sendStarted?.complete();
      if (delayedSend != null) {
        run = await delayedSend!.future;
        return run!;
      }
      return run ?? <String, dynamic>{};
    }
    if (path.endsWith('/messages')) {
      if (delayedMessages != null) {
        // 只阻塞本次读取，后续刷新仍返回当前服务器事实。
        final Completer<Map<String, dynamic>> waiting = delayedMessages!;
        delayedMessages = null;
        messageReadStarted?.complete();
        return waiting.future;
      }
      if (messageFailures > 0) {
        messageFailures--;
        throw const ApiFailure('用时读取暂时断开');
      }
      return <String, dynamic>{'items': messages, 'activeRun': run};
    }
    // URL中的目标必须绑定点击会话，不能依赖当前选中项。
    final String id = Uri.decodeComponent(path.split('/').last);
    if (method == 'DELETE') {
      conversations = conversations
          .where((Map<String, dynamic> item) => item['id'] != id)
          .toList();
      return <String, dynamic>{'ok': true};
    }
    if (method == 'PATCH') {
      // 合成服务端保持置顶前活动时间的行为。
      final Map<String, dynamic> update = assistantMap(data);
      if (ignoresPinUpdate) update.remove('isPinned');
      conversations = conversations
          .map(
            (Map<String, dynamic> item) =>
                item['id'] == id ? <String, dynamic>{...item, ...update} : item,
          )
          .toList();
      return conversations.firstWhere(
        (Map<String, dynamic> item) => item['id'] == id,
      );
    }
    return <String, dynamic>{};
  }

  /// 不同流实例使测试能发现无意义的重订阅。
  @override
  Stream<AssistantEvent> events(String runId, int after, CancelToken token) {
    // 每次流建立记录断点以及取消状态。
    final StreamController<AssistantEvent> stream =
        StreamController<AssistantEvent>();
    streams.add(stream);
    tokens.add(token);
    cursors.add(after);
    return stream.stream;
  }
}

/// 构造会话、SQLite缓存及可处置的真实控制器。
class _Fixture {
  /// 可手动推进的显示时间，测试无需真实等待数秒。
  DateTime currentTime = DateTime.utc(2026, 10, 23, 9);

  /// 同步检查点可独立挂起，验证点击发送立即开始计时。
  Completer<void>? delayedCatchUp;

  /// 允许恢复测试提前释放数据库，统一清理不会重复关闭。
  bool _closed = false;

  /// 数据测试使用隔离的内存缓存。
  final AssistantCache cache = AssistantCache.forTesting(
    NativeDatabase.memory(),
  );

  /// 当前认证代次。
  final _DesktopAuth auth = _DesktopAuth();

  /// 合成服务器。
  late final _DesktopRepository repository = _DesktopRepository(auth);

  /// 待测真实控制器。
  late final AssistantChatController controller = AssistantChatController(
    repository: repository,
    cache: cache,
    scope: 'desktop-test',
    catchUp: () async {
      if (delayedCatchUp != null) await delayedCatchUp!.future;
    },
    now: () => currentTime,
  );

  /// 恢复当前聊天后注册安全清理。
  Future<void> initialize({Map<String, dynamic>? snapshot}) async {
    await cache.save('desktop-test', <String, dynamic>{
      'conversationId': 'current',
      'histories': <String, dynamic>{
        'other': <String, dynamic>{
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'other-message',
              'role': 'user',
              'content': '包含 中文%_ 与MiXeD搜索',
              'cards': <Object>[],
            },
          ],
          'draft': '其他草稿',
        },
      },
      ...?snapshot,
    });
    await controller.initialize();
    addTearDown(close);
  }

  /// 先关闭旧作用域再构造恢复控制器，避免同名缓存同时打开。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    controller.dispose();
    await _settle();
    await cache.close();
    for (final StreamController<AssistantEvent> stream in repository.streams) {
      await stream.close();
    }
  }
}

/// 等待事件和缓存微任务，避免用长延时掩盖重订阅错误。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

/// 创建包含完整运行视图的最终计时事件。
AssistantEvent _runEvent(int seq, Map<String, dynamic> run) => AssistantEvent(
  seq: seq,
  type: 'run.updated',
  runId: 'run',
  data: <String, dynamic>{'run': Map<String, dynamic>.from(run)},
);

/// Windows工作区需要的数据契约及跨状态恢复测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('消息POST尚未返回也能停止，收到真实身份后只停止一次，空草稿可继续', () async {
    // 等到POST发出再点击停止，不能把本机忙状态当成无法停止。
    final _Fixture fixture = _Fixture();
    fixture.repository.run!['status'] = 'succeeded';
    await fixture.initialize();
    fixture.repository.delayedSend = Completer<Map<String, dynamic>>();
    fixture.repository.sendStarted = Completer<void>();
    fixture.controller.setDraft('查询待办');
    final Future<void> sending = fixture.controller.send();
    await fixture.repository.sendStarted!.future;
    expect(fixture.controller.canStop, isTrue);
    await fixture.controller.stop();
    await fixture.controller.stop();
    expect(fixture.controller.pending!['stopRequested'], isTrue);
    fixture.repository.delayedSend!.complete(<String, dynamic>{
      'id': 'accepted-run',
      'status': 'running',
    });
    await sending;
    expect(
      fixture.repository.calls.where(
        (call) => call.path == '/runs/accepted-run/stop',
      ),
      hasLength(1),
    );
    expect(fixture.controller.canContinue, isTrue);
    fixture.repository.delayedSend = null;
    fixture.repository.sendStarted = null;
    fixture.repository.run = <String, dynamic>{
      'id': 'continued-run',
      'status': 'succeeded',
    };
    await fixture.controller.continueConversation();
    expect(
      fixture.repository.calls
          .where(
            (call) => call.method == 'POST' && call.path.endsWith('/messages'),
          )
          .last
          .data,
      containsPair('content', '继续'),
    );
    expect(fixture.controller.draft, isEmpty);
  });

  test('停止意图跨未知消息响应保留，显式恢复仍用原身份并立即停止', () async {
    // 付费任务可能已被接收，不能因用户点击停止而替换消息身份。
    final _Fixture fixture = _Fixture();
    fixture.repository.run!['status'] = 'succeeded';
    await fixture.initialize();
    fixture.repository.delayedSend = Completer<Map<String, dynamic>>();
    fixture.repository.sendStarted = Completer<void>();
    fixture.controller.setDraft('查询本周记录');
    final Future<void> sending = fixture.controller.send();
    await fixture.repository.sendStarted!.future;
    await fixture.controller.stop();
    fixture.repository.delayedSend!.completeError(const ApiFailure('消息结果未知'));
    await sending;
    final Map<String, dynamic> original = Map<String, dynamic>.from(
      fixture.controller.pending!,
    );
    expect(original['stopRequested'], isTrue);
    expect(fixture.controller.canContinue, isFalse);
    fixture.repository.delayedSend = null;
    fixture.repository.sendStarted = null;
    fixture.repository.run = <String, dynamic>{
      'id': 'accepted-run',
      'status': 'running',
    };
    await fixture.controller.send();
    final List<Object?> bodies = fixture.repository.calls
        .where(
          (call) => call.method == 'POST' && call.path.endsWith('/messages'),
        )
        .map((call) => call.data)
        .toList();
    expect(bodies, hasLength(2));
    expect(bodies[0], bodies[1]);
    expect(
      fixture.repository.calls.where(
        (call) => call.path == '/runs/accepted-run/stop',
      ),
      hasLength(1),
    );
    expect(fixture.controller.canContinue, isTrue);
  });

  test('发送准备尚未出站时停止，保留草稿且不创建或发送消息', () async {
    // 同步检查可以真实挂起，停止不必等运行身份才能生效。
    final _Fixture fixture = _Fixture();
    fixture.repository.run = null;
    await fixture.initialize(
      snapshot: <String, dynamic>{'conversationId': null},
    );
    fixture.delayedCatchUp = Completer<void>();
    fixture.controller.setDraft('尚未发出的问题');
    final Future<void> sending = fixture.controller.send();
    await _settle();
    await fixture.controller.stop();
    fixture.delayedCatchUp!.complete();
    await sending;
    expect(fixture.controller.draft, '尚未发出的问题');
    expect(fixture.controller.pending, isNull);
    expect(
      fixture.repository.calls.where((call) => call.method == 'POST'),
      isEmpty,
    );
  });

  test('新聊天只打开本地草稿，首条非空发送才建会话，后续发送复用身份', () async {
    // 真实控制器从已有聊天切出，旧草稿与订阅均需要保留正确归属。
    final _Fixture fixture = _Fixture();
    fixture.repository.run!['status'] = 'succeeded';
    await fixture.initialize();
    fixture.controller.setDraft('原聊天草稿');
    await fixture.controller.create();
    expect(fixture.controller.conversationId, isNull);
    expect(fixture.controller.messages, isEmpty);
    expect(fixture.controller.run, isNull);
    expect(
      fixture.repository.calls.where((call) => call.method == 'POST'),
      isEmpty,
    );
    await fixture.controller.send();
    expect(
      fixture.repository.calls.where((call) => call.method == 'POST'),
      isEmpty,
    );
    fixture.controller.setDraft('新聊天未发送内容');
    await fixture.controller.select('other');
    await fixture.controller.create();
    expect(fixture.controller.draft, '新聊天未发送内容');
    expect(
      fixture.repository.calls.where((call) => call.method == 'POST'),
      isEmpty,
    );
    await fixture.controller.send();
    expect(fixture.controller.conversationId, 'first-message-chat');
    fixture.controller.setDraft('第二条');
    await fixture.controller.send();
    expect(
      fixture.repository.calls.where(
        (call) => call.method == 'POST' && call.path == '/conversations',
      ),
      hasLength(1),
    );
    expect(
      fixture.repository.calls.where(
        (call) =>
            call.method == 'POST' &&
            call.path == '/conversations/first-message-chat/messages',
      ),
      hasLength(2),
    );
    await fixture.controller.select('current');
    expect(fixture.controller.draft, '原聊天草稿');
  });

  test('发送从同步检查前计时，POST挂起继续增长并交给新运行', () async {
    // 上一条回答的最终用时不能被新提交的零秒替换。
    final _Fixture fixture = _Fixture();
    fixture.repository.run!['status'] = 'succeeded';
    fixture.repository.run!['elapsedMs'] = 9000;
    await fixture.initialize();
    fixture.controller.setDraft('发送新问题');
    expect(fixture.controller.submitting, isFalse);
    expect(fixture.controller.liveElapsedMs, 9000);
    fixture.delayedCatchUp = Completer<void>();
    fixture.repository.delayedSend = Completer<Map<String, dynamic>>();
    fixture.repository.sendStarted = Completer<void>();
    // 调用本身就启动显示，尚未等待同步或网络请求。
    final Future<void> sending = fixture.controller.send();
    expect(fixture.controller.submitting, isTrue);
    expect(fixture.controller.liveElapsedMs, 0);
    fixture.currentTime = fixture.currentTime.add(const Duration(seconds: 2));
    expect(fixture.controller.liveElapsedMs, 2000);
    expect(fixture.controller.run?['id'], 'run');
    fixture.delayedCatchUp!.complete();
    await fixture.repository.sendStarted!.future.timeout(
      const Duration(seconds: 2),
    );
    fixture.currentTime = fixture.currentTime.add(const Duration(seconds: 3));
    expect(fixture.controller.submitting, isTrue);
    expect(fixture.controller.liveElapsedMs, 5000);
    fixture.repository.delayedSend!.complete(<String, dynamic>{
      'id': 'new-run',
      'status': 'queued',
      'answerMessageId': 'new-answer',
      'elapsedMs': 0,
      'liveElapsedMs': 100,
      'executionSteps': <Object>[
        <String, dynamic>{
          'id': 'new-step',
          'kind': 'model',
          'label': '正在理解请求',
          'status': 'running',
        },
      ],
    });
    await sending;
    expect(fixture.controller.submitting, isFalse);
    expect(fixture.controller.run?['id'], 'new-run');
    expect(fixture.controller.liveElapsedMs, 5000);
    expect(fixture.controller.messages.single['executionSteps'], isNull);
    expect(fixture.controller.messages.single['id'], 'answer');
  });

  test('等待用户时停表，重新运行后继续，完成时使用服务器最终用时', () async {
    // 实时快照包含当前执行段，等待时间不计入后续运行。
    final _Fixture fixture = _Fixture();
    fixture.repository.run!['liveElapsedMs'] = 1200;
    await fixture.initialize();
    expect(fixture.controller.liveElapsedMs, 1200);
    fixture.currentTime = fixture.currentTime.add(const Duration(seconds: 3));
    expect(fixture.controller.liveElapsedMs, 4200);
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'status': 'waitingConfirmation',
      'elapsedMs': 2000,
    };
    fixture.repository.streams.last.add(_runEvent(1, fixture.repository.run!));
    await _settle();
    fixture.currentTime = fixture.currentTime.add(const Duration(seconds: 20));
    expect(fixture.controller.liveElapsedMs, 2000);
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'status': 'running',
      'liveElapsedMs': 2300,
    };
    fixture.repository.streams.last.add(_runEvent(2, fixture.repository.run!));
    await _settle();
    fixture.currentTime = fixture.currentTime.add(const Duration(seconds: 1));
    expect(fixture.controller.liveElapsedMs, 3300);
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'status': 'succeeded',
      'elapsedMs': 3100,
    };
    fixture.repository.messages.single['elapsedMs'] = 3100;
    fixture.repository.streams.last.add(_runEvent(3, fixture.repository.run!));
    await _settle();
    fixture.currentTime = fixture.currentTime.add(const Duration(minutes: 1));
    expect(fixture.controller.liveElapsedMs, 3100);
    expect(fixture.controller.messages.single['elapsedMs'], 3100);
  });

  test('断流期间仍显示用时，刷新承接服务端基线，切会话不沿用旧计时', () async {
    // 断开 SSE 不代表服务器停止执行，显示时钟仍在当前运行上继续。
    final _Fixture fixture = _Fixture();
    fixture.repository.run!['liveElapsedMs'] = 1500;
    await fixture.initialize();
    fixture.repository.streams.last.addError(const ApiFailure('测试断流'));
    await _settle();
    fixture.currentTime = fixture.currentTime.add(const Duration(seconds: 4));
    expect(fixture.controller.liveElapsedMs, 5500);
    fixture.repository.run!['liveElapsedMs'] = 6000;
    await fixture.controller.refresh();
    expect(fixture.controller.liveElapsedMs, 6000);
    fixture.repository.run = null;
    fixture.repository.messages = <Map<String, dynamic>>[];
    await fixture.controller.select('other');
    fixture.currentTime = fixture.currentTime.add(const Duration(seconds: 20));
    expect(fixture.controller.submitting, isFalse);
    expect(fixture.controller.liveElapsedMs, isNull);
  });

  test('离线恢复冻结最近实时快照，等待与失败停止状态不继续计时', () async {
    // 断开设备后只展示已缓存用时，不能将进行段退回零秒或继续外推。
    final _Fixture offline = _Fixture();
    offline.repository.run!['liveElapsedMs'] = 4800;
    offline.auth.generation++;
    await offline.initialize(
      snapshot: <String, dynamic>{'run': offline.repository.run},
    );
    offline.currentTime = offline.currentTime.add(const Duration(minutes: 1));
    expect(offline.controller.liveElapsedMs, 4800);
    expect(offline.controller.submitting, isFalse);
    expect(offline.repository.streams, isEmpty);
    await offline.close();
    for (final String status in <String>[
      'waitingInput',
      'failed',
      'cancelled',
    ]) {
      // 暂停和终态即使附带较大的旧实时值，也只显示已结算用时。
      final _Fixture stopped = _Fixture();
      stopped.repository.run = <String, dynamic>{
        ...stopped.repository.run!,
        'status': status,
        'elapsedMs': 2100,
        'liveElapsedMs': 9999,
      };
      await stopped.initialize();
      stopped.currentTime = stopped.currentTime.add(const Duration(minutes: 1));
      expect(stopped.controller.liveElapsedMs, 2100, reason: status);
      expect(stopped.controller.submitting, isFalse);
      await stopped.close();
    }
  });

  test('同步准备失败后停止提交计时，置顶与草稿不会启动提交状态', () async {
    // 服务器尚未接受任务时，失败不能留下永远增长的提交计时。
    final _Fixture fixture = _Fixture();
    fixture.repository.run = null;
    await fixture.initialize();
    fixture.controller.setDraft('准备发送');
    await fixture.controller.setPinned('other', true);
    expect(fixture.controller.submitting, isFalse);
    expect(fixture.controller.liveElapsedMs, isNull);
    fixture.delayedCatchUp = Completer<void>();
    // 保持操作在同步检查阶段，随后模拟可读失败。
    final Future<void> sending = fixture.controller.send();
    expect(fixture.controller.submitting, isTrue);
    fixture.delayedCatchUp!.completeError(const ApiFailure('同步失败'));
    await sending;
    fixture.currentTime = fixture.currentTime.add(const Duration(seconds: 10));
    expect(fixture.controller.submitting, isFalse);
    expect(fixture.controller.liveElapsedMs, isNull);
    expect(
      fixture.repository.calls.where((call) => call.method == 'POST'),
      isEmpty,
    );
  });

  test('执行链在完成帧与旧查询间按身份保留，恢复缓存后不重复步骤', () async {
    // 已结束的模型步骤与运行中的工具步骤均来自真实服务器事件。
    final _Fixture fixture = _Fixture();
    fixture.repository.run!['executionSteps'] = <Object>[
      <String, dynamic>{
        'id': 'model',
        'kind': 'model',
        'label': '理解请求',
        'status': 'running',
      },
    ];
    await fixture.initialize();
    fixture.repository.run!['executionSteps'] = <Object>[
      <String, dynamic>{
        'id': 'model',
        'kind': 'model',
        'label': '理解请求',
        'status': 'succeeded',
        'finishedAt': '2026-10-23T09:00:01Z',
      },
      <String, dynamic>{
        'id': 'tool',
        'kind': 'tool',
        'label': '查询笔记',
        'status': 'running',
      },
    ];
    fixture.repository.streams.last.add(_runEvent(1, fixture.repository.run!));
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 2,
        type: 'message.completed',
        runId: 'run',
        data: <String, dynamic>{
          'message': <String, dynamic>{
            'id': 'answer',
            'role': 'assistant',
            'content': '完整回答',
            'cards': <Object>[],
          },
        },
      ),
    );
    await _settle();
    expect(
      assistantItems(fixture.controller.messages.single['executionSteps']),
      hasLength(2),
    );
    fixture.repository.run = <String, dynamic>{
      'id': 'run',
      'status': 'succeeded',
      'answerMessageId': 'answer',
      'elapsedMs': 2200,
    };
    fixture.repository.messages = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'answer', 'role': 'assistant', 'content': '完整回答'},
    ];
    await fixture.controller.refresh();
    // 缓存只保存去重后的显示事实，缺字段旧快照不能删除执行链。
    final Map<String, dynamic> saved = await fixture.cache.readScope(
      'desktop-test',
    );
    expect(
      assistantItems(fixture.controller.messages.single['executionSteps']),
      hasLength(2),
    );
    expect(
      assistantItems(fixture.controller.messages.single['executionSteps'])
          .first['status'],
      'succeeded',
    );
    await fixture.close();
    // 新控制器使用同样的空字段旧接口，仍可从缓存恢复已有链路。
    final _Fixture restored = _Fixture();
    restored.repository.run = fixture.repository.run;
    restored.repository.messages = fixture.repository.messages;
    await restored.initialize(snapshot: saved);
    expect(
      assistantItems(restored.controller.messages.single['executionSteps']),
      hasLength(2),
    );
    expect(restored.controller.liveElapsedMs, 2200);
  });

  test('指定非当前会话置顶、重命名、删除保持草稿与当前事件订阅', () async {
    // 三种元数据操作均必须针对显式身份。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.controller.setDraft('当前草稿');
    await fixture.controller.setPinned('other', true);
    expect(fixture.controller.conversations.last['isPinned'], isTrue);
    expect(
      fixture.controller.conversations.last['updatedAt'],
      '2026-10-22T09:00:00Z',
    );
    await fixture.controller.rename(' 重命名其他聊天 ', id: 'other');
    expect(fixture.controller.conversations.last['title'], '重命名其他聊天');
    await fixture.controller.delete(id: 'other');
    expect(fixture.controller.conversationId, 'current');
    expect(fixture.controller.draft, '当前草稿');
    expect(fixture.controller.messages.single['content'], '回复正文');
    expect(fixture.repository.streams.length, 1);
    expect(fixture.repository.tokens.single.isCancelled, isFalse);
    expect(
      fixture.repository.calls
          .where((call) => call.method != 'GET')
          .map((call) => call.path),
      everyElement('/conversations/other'),
    );
    expect(
      assistantMap(
        (await fixture.cache.readScope('desktop-test'))['histories'],
      ),
      isNot(contains('other')),
    );
  });

  test('置顶和取消置顶立即使用保存回执，不依赖额外列表请求', () async {
    // 写入已经成功后，列表网络故障不能让操作看起来没有生效。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.conversationReadsFail = true;
    // 固定操作前列表读取次数，检测多余请求而非只检查最终状态。
    final int listReads = fixture.repository.calls
        .where((call) => call.path == '/conversations')
        .length;
    await fixture.controller.setPinned('other', true);
    expect(fixture.controller.error, isNull);
    expect(fixture.controller.conversations.last['isPinned'], isTrue);
    expect(
      assistantItems(
        (await fixture.cache.readScope('desktop-test'))['conversations'],
      ).last['isPinned'],
      isTrue,
    );
    await fixture.controller.setPinned('other', false);
    expect(fixture.controller.error, isNull);
    expect(fixture.controller.conversations.last['isPinned'], isFalse);
    expect(
      fixture.repository.calls
          .where((call) => call.path == '/conversations')
          .length,
      listReads,
    );
    expect(fixture.repository.tokens.single.isCancelled, isFalse);
    expect(fixture.controller.conversationId, 'current');
  });

  test('服务端回执未确认置顶字段时明确报错并保持原列表状态', () async {
    // 旧接口忽略字段不能在本机伪造成跨设备持久化成功。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.ignoresPinUpdate = true;
    await fixture.controller.setPinned('other', true);
    expect(fixture.controller.error, contains('未能确认置顶状态'));
    expect(fixture.controller.conversations.last['isPinned'], isFalse);
    expect(fixture.controller.busy, isFalse);
    expect(fixture.repository.tokens.single.isCancelled, isFalse);
  });

  test('保存回执占位在首个片段替换，断流刷新保留卡片和完整增量', () async {
    // 写入结果先保存，模型正文稍后才开始流式到达。
    final _Fixture fixture = _Fixture();
    fixture.repository.messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'answer',
        'role': 'assistant',
        'content': '服务器已保存，正在整理回答。',
        'cards': <Object>[
          <String, dynamic>{'type': 'result', 'syncStatus': 'serverSaved'},
        ],
      },
    ];
    await fixture.initialize();
    expect(fixture.controller.messages.single['content'], contains('服务器已保存'));
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 1,
        type: 'message.delta',
        runId: 'run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '你'},
      ),
    );
    await _settle();
    expect(fixture.controller.messages.single['content'], '你');
    expect(
      assistantItems(fixture.controller.messages.single['cards'])
          .single['type'],
      'result',
    );
    await fixture.controller.refresh();
    expect(fixture.repository.cursors.last, 1);
    expect(fixture.controller.messages.single['content'], '你');
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 1,
        type: 'message.delta',
        runId: 'run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '你'},
      ),
    );
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 2,
        type: 'message.delta',
        runId: 'run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '好'},
      ),
    );
    await _settle();
    expect(fixture.controller.messages.single['content'], '你好');
    await fixture.controller.refresh();
    // 缓存中的正文必须与当前游标同时保存，重启才能从下一段继续。
    final Map<String, dynamic> saved = await fixture.cache.readScope(
      'desktop-test',
    );
    expect(assistantItems(saved['messages']).single['content'], '你好');
    expect(saved['cursor'], 2);
    expect(fixture.repository.cursors.last, 2);
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 3,
        type: 'message.completed',
        runId: 'run',
        data: <String, dynamic>{
          'message': <String, dynamic>{
            'id': 'answer',
            'role': 'assistant',
            'content': '你好！',
            'cards': <Object>[
              <String, dynamic>{'type': 'result', 'syncStatus': 'serverSaved'},
            ],
          },
        },
      ),
    );
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 4,
        type: 'message.delta',
        runId: 'run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '重复正文'},
      ),
    );
    await _settle();
    expect(fixture.controller.messages.single['content'], '你好！');
    expect(fixture.controller.messages.single['_streaming'], isNot(isTrue));
  });

  test('旧缓存只有占位和较高游标时重新回放正文，不遗漏恢复前的片段', () async {
    // 旧客户端可能跳过了占位消息的 delta，但仍推进过事件游标。
    final _Fixture fixture = _Fixture();
    fixture.repository.messages.single['content'] = '服务器已保存，正在整理回答。';
    await fixture.initialize(
      snapshot: <String, dynamic>{
        'run': fixture.repository.run,
        'messages': fixture.repository.messages,
        'cursor': 8,
      },
    );
    expect(fixture.repository.cursors.single, 0);
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 4,
        type: 'message.delta',
        runId: 'run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '恢复首段'},
      ),
    );
    await _settle();
    expect(fixture.controller.messages.single['content'], '恢复首段');
    expect(fixture.controller.cursor, 4);
  });

  test('重试沿用回答身份时舍弃旧运行片段，新回答从首段开始', () async {
    // 业务回执沿用相同回答身份，重试的模型正文仍属于新的运行。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 7,
        type: 'message.delta',
        runId: 'run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '旧回答片段'},
      ),
    );
    await _settle();
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'id': 'retry-run',
      'status': 'queued',
    };
    await fixture.controller.refresh();
    expect(fixture.repository.cursors.last, 0);
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 1,
        type: 'message.delta',
        runId: 'retry-run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '新回答'},
      ),
    );
    await _settle();
    expect(fixture.controller.messages.single['content'], '新回答');
    expect(fixture.controller.cursor, 1);
  });

  test('重放历史等待事件后的结算查询不会把仍在生成的占位标为完成', () async {
    // 批量确认后沿用原运行，游标回放仍会先读到旧的等待确认事件。
    final _Fixture fixture = _Fixture();
    fixture.repository.messages.single['content'] = '服务器已保存，正在整理回答。';
    fixture.repository.messages.single['cards'] = <Object>[
      <String, dynamic>{'type': 'result', 'syncStatus': 'serverSaved'},
    ];
    await fixture.initialize();
    fixture.repository.streams.single.add(
      _runEvent(1, <String, dynamic>{
        ...fixture.repository.run!,
        'status': 'waitingConfirmation',
        'timingPending': false,
      }),
    );
    await _settle();
    // 查询返回的 activeRun 仍是 running，占位必须继续接收后面的正文。
    expect(fixture.controller.messages.single['_streaming'], isTrue);
    expect(fixture.repository.streams.length, 1);
    fixture.repository.streams.single.add(
      const AssistantEvent(
        seq: 2,
        type: 'message.delta',
        runId: 'run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '确认后的真实回答'},
      ),
    );
    await _settle();
    expect(fixture.controller.messages.single['content'], '确认后的真实回答');
    expect(
      assistantItems(fixture.controller.messages.single['cards'])
          .single['type'],
      'result',
    );
    expect(fixture.repository.streams.length, 1);
    expect(fixture.repository.tokens.single.isCancelled, isFalse);
    expect(fixture.controller.cursor, 2);
  });

  test('完成事件先于无消息的旧查询返回时保留完整正文并拒绝后续重复片段', () async {
    // 纯只读回答在完成前没有持久消息行，旧查询因此可能返回空列表。
    final _Fixture fixture = _Fixture();
    fixture.repository.messages = <Map<String, dynamic>>[];
    await fixture.initialize();
    // 由测试明确释放旧快照，保证完成事件先到达控制器。
    final Completer<Map<String, dynamic>> delayed =
        Completer<Map<String, dynamic>>();
    fixture.repository.delayedMessages = delayed;
    fixture.repository.messageReadStarted = Completer<void>();
    // 保持原事件流继续接收，以复现真实查询与 SSE 同时在途。
    final Future<void> refresh = fixture.controller.refresh();
    await fixture.repository.messageReadStarted!.future.timeout(
      const Duration(seconds: 2),
    );
    fixture.repository.streams.single.add(
      const AssistantEvent(
        seq: 1,
        type: 'message.completed',
        runId: 'run',
        data: <String, dynamic>{
          'message': <String, dynamic>{
            'id': 'answer',
            'role': 'assistant',
            'content': '完整回答已经收到',
            'cards': <Object>[],
          },
        },
      ),
    );
    await _settle();
    expect(fixture.controller.messages.single['content'], '完整回答已经收到');
    delayed.complete(<String, dynamic>{
      'items': <Object>[],
      'activeRun': <String, dynamic>{...fixture.repository.run!},
    });
    await refresh;
    expect(fixture.controller.messages.single['content'], '完整回答已经收到');
    expect(fixture.repository.cursors.last, 1);
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 2,
        type: 'message.delta',
        runId: 'run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '迟到重复正文'},
      ),
    );
    await _settle();
    expect(fixture.controller.messages.single['content'], '完整回答已经收到');
    expect(fixture.controller.messages.single['_streaming'], isNot(isTrue));
  });

  test('等待用户输入的持久问句仍按完整消息处理', () async {
    // 已定稿问句不能因为同属当前回答身份而追加旧流重放文本。
    final _Fixture fixture = _Fixture();
    fixture.repository.run!['status'] = 'waitingInput';
    fixture.repository.messages.single['content'] = '请补充保存位置';
    await fixture.initialize();
    fixture.repository.streams.last.add(
      const AssistantEvent(
        seq: 1,
        type: 'message.delta',
        runId: 'run',
        data: <String, dynamic>{'messageId': 'answer', 'text': '无效追加'},
      ),
    );
    await _settle();
    expect(fixture.controller.messages.single['content'], '请补充保存位置');
    expect(fixture.controller.messages.single['_streaming'], isNot(isTrue));
  });

  test('删除当前会话清理本机历史、草稿、游标并取消旧流', () async {
    // 当前删除必须避免下次启动复活已删除聊天。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.controller.setDraft('不能复活的草稿');
    await fixture.controller.delete();
    expect(fixture.controller.conversationId, isNull);
    expect(fixture.controller.messages, isEmpty);
    expect(fixture.controller.draft, isEmpty);
    expect(fixture.controller.cursor, 0);
    expect(fixture.repository.tokens.single.isCancelled, isTrue);
    // 读取已落盘快照验证数据，而不只检查页面显示。
    final Map<String, dynamic> saved = await fixture.cache.readScope(
      'desktop-test',
    );
    expect(saved['conversationId'], isNull);
    expect(assistantMap(saved['histories']), isNot(contains('current')));
  });

  test('待核实提交身份阻止删除对应会话', () async {
    // 未知提交需要保持原始身份供显式恢复。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.controller.pending = <String, dynamic>{
      'conversationId': 'current',
      'clientMessageId': 'stable-request',
    };
    await fixture.controller.delete();
    expect(fixture.controller.error, contains('先核实'));
    expect(fixture.controller.pending?['clientMessageId'], 'stable-request');
    expect(
      fixture.repository.calls.where((call) => call.method == 'DELETE'),
      isEmpty,
    );
  });

  test('在线搜索参数编码、分页和空查询不覆盖当前视图', () async {
    // 搜索内容包含SQL通配符和URL保留字符。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.controller.setDraft('搜索时保留');
    await fixture.controller.searchConversations(' 中文%_ &/# ');
    // 参数通过URI编码，并且侧栏和消息不随结果变化。
    final Uri first = Uri.parse(fixture.repository.calls.last.path);
    expect(first.queryParameters['query'], '中文%_ &/#');
    fixture
            .repository
            .searchResponses['/conversations?query=&cursor=page-two'] =
        <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'second-page', 'title': '搜索下一页'},
          ],
          'nextCursor': 'page-three',
        };
    // 分页结果完全独立于已加载的会话列表。
    final Map<String, dynamic> page = await fixture.controller
        .searchConversations('', cursor: 'page-two');
    expect(assistantItems(page['items']).single['id'], 'second-page');
    expect(page['nextCursor'], 'page-three');
    expect(page['cachedOnly'], isFalse);
    expect(fixture.controller.conversations.length, 2);
    expect(fixture.controller.conversationId, 'current');
    expect(fixture.controller.draft, '搜索时保留');
    expect(fixture.repository.streams.length, 1);
  });

  test('搜索失败只检索本机标题及允许角色正文，并按会话去重', () async {
    // 缓存搜索不会读取卡片、工具消息或其他作用域。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.searchFails = true;
    fixture.controller.messages = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'tool', 'role': 'tool', 'content': '隐藏关键字'},
      <String, dynamic>{
        'id': 'answer',
        'role': 'assistant',
        'content': '普通正文',
        'cards': <Object>[
          <String, String>{'text': '隐藏关键字'},
        ],
      },
    ];
    // 大小写和中文标点匹配与服务器相同。
    final Map<String, dynamic> mixed = await fixture.controller
        .searchConversations('mixed');
    expect(mixed['cachedOnly'], isTrue);
    expect(assistantItems(mixed['items']).single['id'], 'other');
    expect(
      assistantItems(
        (await fixture.controller.searchConversations('中文%_'))['items'],
      ).single['id'],
      'other',
    );
    expect(
      assistantItems(
        (await fixture.controller.searchConversations('隐藏关键字'))['items'],
      ),
      isEmpty,
    );
    fixture.controller.conversations.add(
      Map<String, dynamic>.from(fixture.controller.conversations.last),
    );
    expect(
      assistantItems(
        (await fixture.controller.searchConversations('聊天'))['items'],
      ).length,
      2,
    );
  });

  test('离线搜索超过一页使用稳定游标，未知在线游标不重复首页', () async {
    // 一百零一个缓存会话可完整分页，日期相同按身份降序。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.searchFails = true;
    fixture.controller.conversations = List<Map<String, dynamic>>.generate(
      101,
      (int index) => <String, dynamic>{
        'id': 'id-${index.toString().padLeft(3, '0')}',
        'title': '聊天$index',
        'updatedAt': '2026-10-23T09:00:00Z',
      },
    );
    // 首页给出真实会话身份，不使用只在当前进程有效的索引。
    final Map<String, dynamic> first = await fixture.controller
        .searchConversations('');
    expect(assistantItems(first['items']).length, 100);
    expect(first['nextCursor'], 'id-001');
    // 下一页返回最后一条且明确结束。
    final Map<String, dynamic> second = await fixture.controller
        .searchConversations('', cursor: first['nextCursor'] as String);
    expect(assistantItems(second['items']).single['id'], 'id-000');
    expect(second['nextCursor'], isNull);
    expect(
      assistantItems(
        (await fixture.controller.searchConversations(
          '',
          cursor: 'unknown',
        ))['items'],
      ),
      isEmpty,
    );
  });

  test('查询长度校验及换服后迟到结果不会返回旧服务器搜索', () async {
    // 超长查询在发请求前给出明确错误。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    await expectLater(
      fixture.controller.searchConversations('字' * 201),
      throwsA(isA<ApiFailure>()),
    );
    fixture.repository.delayedSearch = Completer<Map<String, dynamic>>();
    // 等待期间切换认证来源，晚到响应不能进入新视图。
    final Future<Map<String, dynamic>> search = fixture.controller
        .searchConversations('旧结果');
    fixture.auth.generation++;
    fixture.repository.delayedSearch!.complete(<String, dynamic>{
      'items': <Object>[],
    });
    await expectLater(search, throwsA(isA<ApiFailure>()));
  });

  test('plan.ready 不关闭流，等待确认最终事件刷新消息用时且不重订阅', () async {
    // 预览卡先到达，计时稍后由finally提交。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.streams.single.add(
      const AssistantEvent(
        seq: 1,
        type: 'plan.ready',
        runId: 'run',
        data: <String, dynamic>{
          'plan': <String, dynamic>{'id': 'plan'},
        },
      ),
    );
    await _settle();
    expect(fixture.controller.plan?['id'], 'plan');
    expect(fixture.repository.tokens.single.isCancelled, isFalse);
    expect(fixture.repository.streams.length, 1);
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'status': 'waitingConfirmation',
      'elapsedMs': 1240,
      'timingPending': false,
    };
    fixture.repository.messages.single['elapsedMs'] = 1240;
    fixture.repository.streams.single.add(
      _runEvent(2, fixture.repository.run!),
    );
    fixture.repository.streams.single.add(
      _runEvent(2, fixture.repository.run!),
    );
    await _settle();
    expect(fixture.controller.messages.single['elapsedMs'], 1240);
    expect(fixture.controller.run?['elapsedMs'], 1240);
    expect(fixture.repository.streams.length, 1);
    expect(fixture.repository.tokens.single.isCancelled, isFalse);
  });

  test('终态尚未结算保持原流，最终回答聚合用时不按事件累加', () async {
    // 回答聚合包含先前重试，不能直接拿当前run.elapsedMs替代。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'status': 'succeeded',
      'elapsedMs': 300,
      'timingPending': true,
    };
    fixture.repository.streams.single.add(
      _runEvent(1, fixture.repository.run!),
    );
    await _settle();
    expect(fixture.repository.tokens.single.isCancelled, isFalse);
    expect(fixture.controller.messages.single['elapsedMs'], isNull);
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'elapsedMs': 900,
      'timingPending': false,
    };
    fixture.repository.messages.single['elapsedMs'] = 1500;
    fixture.repository.streams.single.add(
      _runEvent(2, fixture.repository.run!),
    );
    await _settle();
    expect(fixture.controller.messages.single['elapsedMs'], 1500);
    expect(fixture.controller.run?['elapsedMs'], 900);
    expect(fixture.repository.tokens.single.isCancelled, isTrue);
    expect(fixture.repository.streams.length, 1);
  });

  test('需要补充输入的结算事件同样更新回答用时', () async {
    // 澄清等待不是终态，但已经生成的回答必须显示实际处理用时。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'status': 'waitingInput',
      'timingPending': false,
      'elapsedMs': 2200,
    };
    fixture.repository.messages.single['elapsedMs'] = 2200;
    fixture.repository.streams.single.add(
      _runEvent(1, fixture.repository.run!),
    );
    await _settle();
    expect(fixture.controller.messages.single['elapsedMs'], 2200);
    expect(fixture.repository.streams.length, 1);
  });

  test('终态计时待结算断流后恢复最终消息，不重新提交任务', () async {
    // 服务器先结束正文，网络在最终用时事件前断开。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'status': 'succeeded',
      'timingPending': true,
    };
    fixture.repository.streams.single.add(
      _runEvent(1, fixture.repository.run!),
    );
    await _settle();
    await fixture.repository.streams.single.close();
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'timingPending': false,
      'elapsedMs': 3200,
    };
    fixture.repository.messages.single['elapsedMs'] = 3200;
    await Future<void>.delayed(const Duration(milliseconds: 3150));
    expect(fixture.controller.messages.single['elapsedMs'], 3200);
    expect(
      fixture.repository.calls.where((call) => call.method == 'POST'),
      isEmpty,
    );
    expect(fixture.repository.streams.length, 1);
  });

  test('最终计时消息读取失败后继续恢复，成功后关闭终态订阅', () async {
    // 最终事件可以先于一次临时断网到达，正文和计时仍需完整核实。
    final _Fixture fixture = _Fixture();
    await fixture.initialize();
    fixture.repository.run = <String, dynamic>{
      ...fixture.repository.run!,
      'status': 'succeeded',
      'timingPending': false,
      'elapsedMs': 4700,
    };
    fixture.repository.messages = <Map<String, dynamic>>[
      <String, dynamic>{
        ...fixture.repository.messages.single,
        'elapsedMs': 4700,
      },
    ];
    fixture.repository.messageFailures = 1;
    fixture.repository.streams.single.add(
      _runEvent(1, fixture.repository.run!),
    );
    await _settle();
    expect(fixture.controller.error, contains('正在恢复最终用时'));
    expect(fixture.repository.tokens.single.isCancelled, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 3150));
    expect(fixture.controller.error, isNull);
    expect(fixture.controller.messages.single['elapsedMs'], 4700);
    expect(fixture.repository.tokens.single.isCancelled, isTrue);
    expect(
      fixture.repository.calls.where((call) => call.method == 'POST'),
      isEmpty,
    );
  });
}
