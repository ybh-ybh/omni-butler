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

  /// 特定搜索分页的合成响应。
  final Map<String, Map<String, dynamic>> searchResponses =
      <String, Map<String, dynamic>>{};

  /// 可控制搜索结束顺序，测试认证代次变更。
  Completer<Map<String, dynamic>>? delayedSearch;

  /// 控制最终用时读取失败的次数。
  int messageFailures = 0;

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
    if (path.startsWith('/conversations?')) {
      if (searchFails) throw const ApiFailure('网络不可用');
      if (delayedSearch != null) return delayedSearch!.future;
      return searchResponses[path] ??
          <String, dynamic>{'items': conversations, 'nextCursor': null};
    }
    if (path == '/conversations') {
      return <String, dynamic>{'items': conversations, 'nextCursor': null};
    }
    if (path.endsWith('/messages')) {
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
    catchUp: () async {},
  );

  /// 恢复当前聊天后注册安全清理。
  Future<void> initialize() async {
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
    });
    await controller.initialize();
    addTearDown(() async {
      controller.dispose();
      await _settle();
      await cache.close();
      for (final StreamController<AssistantEvent> stream
          in repository.streams) {
        await stream.close();
      }
    });
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
