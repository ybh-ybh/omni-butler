import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_page.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_settings_section.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_memories_page.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/assistant/data/assistant_chat_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_cards.dart';

/// 无平台存储、无外网的认证边界。
class _Auth implements AuthRepository {
  /// 可主动推进的会话代次。
  int generation = 1;

  /// 当前代次。
  @override
  int get sessionGeneration => generation;

  /// 创建流取消令牌供内存仓储使用。
  @override
  CancelToken createSessionStreamToken(int generation) => CancelToken();

  /// 其他能力不允许隐式调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 记录真实控制器的所有接口调用，不用 mock 页面交互。
class _Repository extends AssistantRepository {
  /// 请求顺序及固定负载。
  final List<({String method, String path, Object? data})> calls =
      <({String method, String path, Object? data})>[];

  /// 每次流订阅使用的新控制器。
  final List<StreamController<AssistantEvent>> streams =
      <StreamController<AssistantEvent>>[];

  /// SSE 断点请求记录。
  final List<int> cursors = <int>[];

  /// 模拟接收消息后网络断开。
  bool loseMessageResponse = false;

  /// 分页与特殊接口的受控响应。
  final Map<String, Map<String, dynamic>> responses =
      <String, Map<String, dynamic>>{};

  /// 当前服务器任务快照。
  Map<String, dynamic>? serverRun;

  /// 已完整保存的服务端消息。
  List<Map<String, dynamic>> serverMessages = <Map<String, dynamic>>[];

  /// 创建受控接口。
  _Repository(super.auth);

  /// 回应当前最小真实协议，不调用供应商。
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
      serverRun = <String, dynamic>{...?serverRun, 'status': 'cancelled'};
      return serverRun!;
    }
    if (responses.containsKey(path)) return responses[path]!;
    if (path == '/conversations' && method == 'GET') {
      return <String, dynamic>{
        'items': <Object>[
          <String, String>{'id': 'conversation', 'title': '测试对话'},
        ],
      };
    }
    if (path == '/conversations' && method == 'POST') {
      return <String, String>{'id': 'conversation', 'title': '测试对话'};
    }
    if (path.endsWith('/messages') && method == 'GET') {
      return <String, dynamic>{'items': serverMessages, 'activeRun': serverRun};
    }
    if (path.endsWith('/messages') && method == 'POST') {
      if (loseMessageResponse) throw const ApiFailure('响应中断');
      serverRun = <String, dynamic>{
        'id': 'run',
        'conversationId': 'conversation',
        'taskId': 'task',
        'status': 'running',
      };
      return serverRun!;
    }
    return <String, dynamic>{};
  }

  /// 保留断点并提供真正异步的内存事件流。
  @override
  Stream<AssistantEvent> events(String runId, int after, CancelToken token) {
    cursors.add(after);
    // 每次重连使用独立数据源，确保旧流迟到不会污染。
    final StreamController<AssistantEvent> stream =
        StreamController<AssistantEvent>();
    streams.add(stream);
    return stream.stream;
  }
}

/// 固定设备会话，不使用安全存储。
class _AuthController extends AuthController {
  /// 返回合成的设备身份。
  @override
  Future<SyncSession?> build() async => const SyncSession(
    identity: SyncIdentity(id: 'owner'),
    apiBaseUrl: 'https://example.com/api',
    isOffline: false,
  );
}

/// 补充信息集成测试的同步边界。
class _ClarificationSync implements OmniSyncRuntime {
  /// 模拟已完成的上传检查点，不连接实际同步服务。
  @override
  Future<void> catchUp({Duration timeout = const Duration(minutes: 3)}) async {}

  /// 其他同步行为不属于补充信息的测试范围。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 等待事件及缓存事务落盘。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 60));

/// 完整事件的统一测试构造器。
AssistantEvent _event(int seq, String text) => AssistantEvent(
  seq: seq,
  type: 'message.delta',
  runId: 'run',
  data: <String, dynamic>{'messageId': 'answer', 'text': text},
);

/// 助手的幂等、恢复和只读卡片关键路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
    setUpAll(() async {
      // 合成预览使用真实中文字体，避免Ahem方框掩盖布局问题。
      final ByteData font = ByteData.sublistView(
        await File(
          Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
        ).readAsBytes(),
      );
      for (final String family in <String>[
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'Roboto',
        'Noto Sans CJK SC',
        'Ahem',
      ]) {
        // 注册主题可能使用的字体族。
        final FontLoader loader = FontLoader(family)
          ..addFont(Future<ByteData>.value(font));
        await loader.load();
      }
      // 原生图标字体沿用已安装Flutter SDK。
      final ByteData icons = ByteData.sublistView(
        await File(
          Platform.environment['OMNI_UI_ICONS'] ?? 'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes(),
      );
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future<ByteData>.value(icons))).load();
    });
  }

  test('SSE 跨 UTF8 字节和 CRLF 分片，只接收完整事件帧', () async {
    // 故意在中文 UTF8 编码中截断网络块。
    final List<int> bytes = utf8.encode(
      'id: 8\r\ndata: {"seq":8,"type":"message.delta","runId":"run","data":{"messageId":"answer","text":"你好"}}\r\n\r\n: ping\n\ndata: {"seq":9',
    );
    // 真实转换器必须保留字符和完整帧。
    final List<AssistantEvent> events = await decodeAssistantEvents(
      Stream<List<int>>.fromIterable(<List<int>>[
        bytes.sublist(0, 104),
        bytes.sublist(104, 105),
        bytes.sublist(105),
      ]),
    ).toList();
    expect(events.length, 1);
    expect(events.single.seq, 8);
    expect(events.single.data['text'], '你好');
  });

  test('独立缓存以完整服务器和owner隔离，消息与游标共同恢复', () async {
    // 内存 SQLite 不会访问真实用户数据库。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(cache.close);
    // 同域不同前缀也不能读取另一数据源。
    final String first = AssistantCache.scopeFor(
      'https://example.com/a',
      'one',
    );
    // 第二个来源独立保存草稿。
    final String second = AssistantCache.scopeFor(
      'https://example.com/b',
      'one',
    );
    await cache.save(first, <String, dynamic>{
      'messages': <String>['第一条'],
      'cursor': 7,
      'draft': '草稿A',
    });
    await cache.save(second, <String, dynamic>{
      'messages': <String>['第二条'],
      'cursor': 3,
      'draft': '草稿B',
    });
    expect((await cache.readScope(first))['cursor'], 7);
    expect((await cache.readScope(first))['draft'], '草稿A');
    expect((await cache.readScope(second))['draft'], '草稿B');
    expect(
      await cache.readScope(
        AssistantCache.scopeFor('https://example.com/a', 'two'),
      ),
      isEmpty,
    );
  });

  test('未知消息响应显式恢复沿用原clientMessageId，不重复创建会话', () async {
    // 控制器使用真实独立缓存。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 第一次响应丢失。
    final _Repository repository = _Repository(_Auth())
      ..loseMessageResponse = true;
    // 同一作用域保持提交身份。
    final AssistantChatController controller = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'scope',
      catchUp: () async {},
    );
    addTearDown(() async {
      controller.dispose();
      await _settle();
      await cache.close();
    });
    await controller.initialize();
    controller.setDraft('帮我新增一条时间记录');
    await controller.send();
    expect(controller.pending, isNotNull);
    expect(controller.draft, '帮我新增一条时间记录');
    // 第一次发出的稳定请求身份。
    final Object? firstPayload = repository.calls
        .where(
          (call) => call.method == 'POST' && call.path.endsWith('/messages'),
        )
        .single
        .data;
    repository.loseMessageResponse = false;
    await controller.send();
    expect(controller.pending, isNull);
    expect(
      repository.calls
          .where(
            (call) => call.method == 'POST' && call.path == '/conversations',
          )
          .length,
      1,
    );
    expect(
      repository.calls
          .where(
            (call) => call.method == 'POST' && call.path.endsWith('/messages'),
          )
          .last
          .data,
      firstPayload,
    );
  });

  test('写前检查点失败时不提交任何聊天任务', () async {
    // 上传未完成时不能让服务器按旧业务快照修改。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 内存接口不会真的联网。
    final _Repository repository = _Repository(_Auth());
    // 注入真实失败语义。
    final AssistantChatController controller = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'scope',
      catchUp: () async {
        throw const ApiFailure('同步尚未完成');
      },
    );
    addTearDown(() async {
      controller.dispose();
      await _settle();
      await cache.close();
    });
    await controller.initialize();
    controller.setDraft('新增笔记');
    await controller.send();
    expect(repository.calls.where((call) => call.method == 'POST'), isEmpty);
    expect(controller.error, '同步尚未完成');
  });

  test('事件重复去重，重启保留流式消息与游标，迟到换服事件被拒绝', () async {
    // 缓存跨控制器重建保持不变。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 可变会话用于模拟换服。
    final _Auth auth = _Auth();
    // 当前运行在服务器尚未完成。
    final _Repository repository = _Repository(auth)
      ..serverRun = <String, dynamic>{'id': 'run', 'status': 'running'};
    await cache.save('scope', <String, dynamic>{
      'conversationId': 'conversation',
    });
    // 第一控制器接受两个唯一事件。
    final AssistantChatController first = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'scope',
      catchUp: () async {},
    );
    await first.initialize();
    expect(first.error, isNull);
    expect(first.conversationId, "conversation");
    expect(
      repository.calls.map((call) => call.path),
      contains("/conversations/conversation/messages"),
    );
    repository.streams.last.add(_event(1, '你'));
    repository.streams.last.add(_event(1, '你'));
    repository.streams.last.add(_event(2, '好'));
    await _settle();
    expect(first.messages.single['content'], '你好');
    expect(first.cursor, 2);
    first.dispose();
    await _settle();
    // 重启后从相同事件游标接续，不能丢掉已显示前半句。
    final AssistantChatController second = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'scope',
      catchUp: () async {},
    );
    addTearDown(() async {
      second.dispose();
      await _settle();
      await cache.close();
    });
    await second.initialize();
    expect(repository.cursors.last, 2);
    expect(second.messages.single['content'], '你好');
    repository.streams.last.add(_event(3, '！'));
    await _settle();
    expect(second.messages.single['content'], '你好！');
    auth.generation++;
    repository.streams.last.add(_event(4, '旧服务器'));
    await _settle();
    expect(second.messages.single['content'], '你好！');
  });

  test('完整服务端消息阻止旧delta重放；确认绑定按钮点击时计划版本', () async {
    // 完整消息来自后端数据库。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 同一任务仍有后续事件。
    final _Repository repository = _Repository(_Auth())
      ..serverRun = <String, dynamic>{'id': 'run', 'status': 'running'}
      ..serverMessages = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'answer',
          'content': '已完成',
          'role': 'assistant',
        },
      ];
    await cache.save('scope', <String, dynamic>{
      'conversationId': 'conversation',
    });
    // 同步等待期间另一个刷新不能偷偷改变已确认计划。
    late AssistantChatController controller;
    controller = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'scope',
      catchUp: () async {
        controller.plan = <String, dynamic>{
          'id': 'new',
          'version': 2,
          'previewHash': 'new',
        };
      },
    );
    addTearDown(() async {
      controller.dispose();
      await _settle();
      await cache.close();
    });
    await controller.initialize();
    expect(controller.error, isNull);
    repository.streams.last.add(_event(1, '已完成'));
    await _settle();
    expect(controller.messages.single['content'], '已完成');
    controller.plan = <String, dynamic>{
      'id': 'task',
      'version': 1,
      'previewHash': 'original',
    };
    await controller.decide('confirm');
    expect(
      repository.calls
          .where((call) => call.path == '/plans/task/decision')
          .single
          .data,
      <String, dynamic>{
        'version': 1,
        'previewHash': 'original',
        'decision': 'confirm',
      },
    );
  });

  test('消息分页按时间顺序恢复全部历史，离线切换只读取本源缓存', () async {
    // 全部行为只使用内存缓存。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 最新一页在前，before游标读出较早消息。
    final _Repository repository = _Repository(_Auth());
    repository.responses['/conversations/conversation/messages'] =
        <String, dynamic>{
          'items': <Object>[
            <String, String>{'id': 'new', 'content': '最近', 'role': 'assistant'},
          ],
          'activeRun': null,
          'nextCursor': 'older',
        };
    repository.responses['/conversations/conversation/messages?cursor=older'] =
        <String, dynamic>{
          'items': <Object>[
            <String, String>{'id': 'old', 'content': '较早', 'role': 'user'},
          ],
          'nextCursor': null,
        };
    await cache.save('scope', <String, dynamic>{
      'conversationId': 'conversation',
      'histories': <String, dynamic>{
        'other': <String, dynamic>{
          'messages': <Object>[
            <String, String>{
              'id': 'cached',
              'content': '另一会话缓存',
              'role': 'assistant',
            },
          ],
        },
      },
    });
    // 加载真实分页后按升序显示。
    final AssistantChatController online = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'scope',
      catchUp: () async {},
    );
    await online.initialize();
    expect(online.messages.map((message) => message['content']), <String>[
      '较早',
      '最近',
    ]);
    online.dispose();
    await _settle();
    // 断开后只展示本机缓存，不发远程请求或恢复计划。
    final AssistantChatController offline = AssistantChatController(
      repository: null,
      cache: cache,
      scope: null,
      catchUp: () async {},
    );
    await offline.initialize();
    await offline.select('other');
    expect(offline.messages.single['content'], '另一会话缓存');
    expect(offline.connected, isFalse);
    expect(offline.plan, isNull);
    offline.dispose();
    await _settle();
    await cache.close();
  });

  test('结果编辑引用与澄清selection分开，草稿重启保留定位且恢复复用身份', () async {
    // 同一服务器的编辑草稿可恢复，但引用不会自动提交。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 模拟请求发出但响应不确定。
    final _Repository repository = _Repository(_Auth())
      ..loseMessageResponse = true;
    await cache.save('scope', <String, dynamic>{
      'conversationId': 'conversation',
    });
    // 第一次输入来自真实结果卡引用，页面始终显示label。
    final AssistantChatController first = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'scope',
      catchUp: () async {},
    );
    await first.initialize();
    first.setDraft(
      '把这条记录改为已完成',
      reference: <String, dynamic>{
        'id': 'record',
        'module': 'todos',
        'label': '整理面试题',
        'record': <String, String>{'title': '不应作为授权'},
      },
    );
    first.dispose();
    await _settle();
    // 重启仅恢复输入，不能自动执行。
    final AssistantChatController second = AssistantChatController(
      repository: repository,
      cache: cache,
      scope: 'scope',
      catchUp: () async {},
    );
    await second.initialize();
    expect(second.draftReference, <String, dynamic>{
      'id': 'record',
      'module': 'todos',
      'label': '整理面试题',
    });
    expect(repository.calls.where((call) => call.method == 'POST'), isEmpty);
    await second.send();
    // 传给API的是精确引用，不能混作仅waitingInput可用的selection。
    final Map<String, dynamic> payload =
        repository.calls
                .where(
                  (call) =>
                      call.method == 'POST' && call.path.endsWith('/messages'),
                )
                .single
                .data
            as Map<String, dynamic>;
    expect(payload['reference'], <String, String>{
      'id': 'record',
      'module': 'todos',
    });
    expect(payload.containsKey('selection'), isFalse);
    repository.loseMessageResponse = false;
    await second.send();
    expect(
      repository.calls
          .where(
            (call) => call.method == 'POST' && call.path.endsWith('/messages'),
          )
          .last
          .data,
      payload,
    );
    expect(second.draftReference, isNull);
    second.dispose();
    await _settle();
    await cache.close();
  });

  testWidgets('批量卡片窄屏大字号完整展示目标与按钮，缓存卡禁止确认', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 旧缓存上的卡片不能恢复执行授权。
    bool confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.dark),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AssistantPlanCard(
              plan: <String, dynamic>{
                'targetCount': 2,
                'preview': <String, dynamic>{
                  'changes': <Object>[
                    <String, dynamic>{
                      'newRecord': true,
                      'label': '学习记录',
                      'after': <String, dynamic>{
                        'activity': '源哥面试复盘',
                        'category': '学习',
                      },
                    },
                  ],
                },
              },
              enabled: false,
              onDecision: (String value) {
                confirmed = true;
              },
              onEdit: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('确认修改 2 个对象'), findsOneWidget);
    expect(find.textContaining('源哥面试复盘'), findsOneWidget);
    expect(find.textContaining('分类：学习'), findsOneWidget);
    await tester.ensureVisible(find.text('确认执行'));
    await tester.tap(find.text('确认执行'), warnIfMissed: false);
    await tester.pump();
    expect(confirmed, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 助手窄屏双倍字号加载/设置引导/输入正常，无真实服务', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 平台目录由内存数据库替换。
      final AssistantCache cache = AssistantCache.forTesting(
        NativeDatabase.memory(),
      );
      // 仓储仅使用合成服务器状态。
      final _Repository repository = _Repository(_Auth());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(_AuthController.new),
            assistantRepositoryProvider.overrideWithValue(repository),
            assistantCacheProvider.overrideWithValue(cache),
            assistantSettingsProvider.overrideWith(
              (Ref ref) async => <String, dynamic>{'enabled': false},
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light)
                .copyWith(platform: platform),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(body: SafeArea(child: AssistantPage())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(platform == TargetPlatform.windows ? '新聊天' : '知序助手'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('assistant-input')),
        findsOneWidget,
      );
      expect(find.text('AI 设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await cache.close();
    });
  }

  testWidgets('Android图片加文字未开启多模态时引导设置，返回后草稿仍在', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 测试只保存合成缓存，不读取用户身份或真实模型。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    // 共用当前配置，正常能力检查不隐式调用测试接口。
    final _Repository repository = _Repository(_Auth());
    repository.responses['/settings'] = <String, dynamic>{
      'enabled': true,
      'profileId': 'image-profile',
      'profiles': <Object>[
        <String, dynamic>{
          'id': 'image-profile',
          'name': '当前模型',
          'model': '示例模型',
          'hasApiKey': true,
          'capabilities': <String, dynamic>{'imageInput': 'unknown'},
        },
      ],
    };
    repository.responses['/attachments/capabilities'] = <String, dynamic>{
      'enabled': true,
    };
    repository.responses['/test'] = <String, dynamic>{'message': '图片能力测试通过'};
    await cache.save(
      AssistantCache.scopeFor('https://example.com/api', 'owner'),
      <String, dynamic>{
        'conversationId': 'conversation',
        'attachments': <Object>[
          <String, dynamic>{
            'id': 'image',
            'name': '截图.png',
            'kind': 'image',
            'status': 'ready',
            'uploaded': true,
            'requiresVision': true,
            'size': 100,
          },
        ],
      },
    );
    // 使用真实路由验证错误恢复入口可到达助手设置。
    final GoRouter router = GoRouter(
      initialLocation: '/assistant',
      routes: <RouteBase>[
        GoRoute(
          path: '/assistant',
          builder: (context, state) => const Scaffold(body: AssistantPage()),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(
            body: SingleChildScrollView(child: AssistantSettingsSection()),
          ),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      router.dispose();
      await cache.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(_AuthController.new),
          assistantRepositoryProvider.overrideWithValue(repository),
          assistantCacheProvider.overrideWithValue(cache),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.build(brightness: Brightness.light)
              .copyWith(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      '这张图片是什么？',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('assistant-send-button')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-send-button')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('未开启多模态'), findsOneWidget);
    expect(repository.calls.where((call) => call.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.widgetWithText(OmniButton, 'AI 设置'));
    await tester.tap(find.widgetWithText(OmniButton, 'AI 设置'));
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/settings?section=ai',
    );
    expect(find.text('应用内助手'), findsOneWidget);
    expect(find.text('助手使用的模型'), findsNothing);
    expect(find.text('测试图片能力'), findsNothing);
    expect(repository.calls.where((call) => call.path == '/test'), isEmpty);
    router.go('/assistant');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OmniTextField>(
            find.byKey(const ValueKey<String>('assistant-input')),
          )
          .controller!
          .text,
      '这张图片是什么？',
    );
    expect(find.text('截图.png'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 两端都用真正聊天页面验证思考与工具属于同一默认折叠执行链。
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 思考与工具共同折叠、独立展开且流式更新不混入答案', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = platform == TargetPlatform.android
          ? const Size(320, 900)
          : const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 本地缓存与网络均使用隔离的合成数据。
      final AssistantCache cache = AssistantCache.forTesting(
        NativeDatabase.memory(),
      );
      // 正式控制器通过真实run.updated路径合并思考快照。
      final _Repository repository = _Repository(_Auth());
      // 同一模型步骤在流式更新中保持稳定身份。
      final List<Map<String, dynamic>> steps = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'run:model:1',
          'kind': 'model',
          'label': '分析任务',
          'status': 'running',
          'reasoning': <String, dynamic>{'text': '先核对重要紧急任务。'},
        },
        <String, dynamic>{
          'id': 'run:tool:1',
          'kind': 'tool',
          'label': '查询待办',
          'status': 'succeeded',
          'tool': <String, dynamic>{
            'name': 'list_todos',
            'arguments': <String, dynamic>{'priorityQuadrant': 3},
          },
        },
      ];
      repository.responses['/settings'] = <String, dynamic>{'enabled': true};
      repository.serverRun = <String, dynamic>{
        'id': 'run',
        'status': 'running',
        'answerMessageId': 'answer',
        'executionSteps': steps,
      };
      repository.serverMessages = <Map<String, dynamic>>[
        if (platform == TargetPlatform.windows)
          <String, dynamic>{
            'id': 'user',
            'role': 'user',
            'content': '请查询任务',
            'cards': <Object>[],
          },
        if (platform != TargetPlatform.windows)
          <String, dynamic>{
            'id': 'answer',
            'role': 'assistant',
            'content': '这是最终回答。',
            'executionSteps': steps,
            'cards': <Object>[],
          },
      ];
      await cache.save(
        AssistantCache.scopeFor('https://example.com/api', 'owner'),
        <String, dynamic>{'conversationId': 'conversation'},
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await cache.close();
        for (final StreamController<AssistantEvent> stream
            in repository.streams) {
          await stream.close();
        }
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(_AuthController.new),
            assistantRepositoryProvider.overrideWithValue(repository),
            assistantCacheProvider.overrideWithValue(cache),
          ],
          child: MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light)
                .copyWith(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(
                  platform == TargetPlatform.android ? 2 : 1,
                ),
              ),
              child: RepaintBoundary(
                key: const ValueKey<String>('thinking-chat-preview'),
                child: child!,
              ),
            ),
            home: const Scaffold(body: AssistantPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('先核对重要紧急任务。'), findsNothing);
      expect(
        find.byKey(
          const ValueKey<String>('assistant-reasoning-toggle-run:model:1'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('assistant-execution-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.text('查询待办'), findsOneWidget);
      expect(find.text('先核对重要紧急任务。'), findsNothing);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('assistant-reasoning-toggle-run:model:1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('先核对重要紧急任务。'), findsOneWidget);
      // 新累计快照替换旧副本，重复SSE序号不得重复拼接。
      final AssistantEvent event = AssistantEvent(
        seq: 1,
        type: 'run.updated',
        runId: 'run',
        data: <String, dynamic>{
          'run': <String, dynamic>{
            ...repository.serverRun!,
            'executionSteps': <Map<String, dynamic>>[
              <String, dynamic>{
                ...steps.first,
                'reasoning': <String, dynamic>{'text': '先核对重要紧急任务。再按日期整理。'},
              },
              steps.last,
            ],
          },
        },
      );
      repository.streams.last.add(event);
      repository.streams.last.add(event);
      if (platform == TargetPlatform.windows) {
        repository.streams.last.add(
          AssistantEvent(
            seq: 2,
            type: 'message.delta',
            runId: 'run',
            data: <String, dynamic>{'messageId': 'answer', 'text': '这是最终回答。'},
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('先核对重要紧急任务。再按日期整理。'), findsOneWidget);
      expect(find.text('这是最终回答。'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('assistant-tool-toggle-run:tool:1')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('assistant-tool-toggle-run:tool:1')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('"priorityQuadrant": 3'), findsOneWidget);
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        // 显式中文预览来自真实页面，数据为合成内容。
        final RenderRepaintBoundary boundary = tester.renderObject(
          find.byKey(const ValueKey<String>('thinking-chat-preview')),
        );
        await tester.runAsync(() async {
          // 编码完成后及时释放截图像素。
          final ui.Image image = await boundary.toImage();
          try {
            // 本地PNG用于人工检查折叠内容和窄屏布局。
            final ByteData bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await Directory('build/assistant_previews').create(recursive: true);
            await File(
              'build/assistant_previews/thinking_chat_${platform.name}.png',
            ).writeAsBytes(
              bytes.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
            );
          } finally {
            image.dispose();
          }
        });
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android窄屏双倍字号的主按钮切换停止、开始和发送', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 真实页面只替换服务器，停止回执仍由控制器刷新核实。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    final _Repository repository = _Repository(_Auth())
      ..serverRun = <String, dynamic>{'id': 'run', 'status': 'running'};
    await cache.save(
      AssistantCache.scopeFor('https://example.com/api', 'owner'),
      <String, dynamic>{'conversationId': 'conversation'},
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await cache.close();
      for (final StreamController<AssistantEvent> stream
          in repository.streams) {
        await stream.close();
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(_AuthController.new),
          assistantRepositoryProvider.overrideWithValue(repository),
          assistantCacheProvider.overrideWithValue(cache),
          assistantSettingsProvider.overrideWith(
            (Ref ref) async => <String, dynamic>{'enabled': true},
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light)
              .copyWith(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(body: AssistantPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('停止'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-stop-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('停止'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('assistant-continue-button')),
      findsOneWidget,
    );
    expect(find.text('开始'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      '新的问题',
    );
    await tester.pump();
    expect(find.text('发送'), findsOneWidget);
    expect(find.text('开始'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey<String>('assistant-input')),
      '',
    );
    await tester.pump();
    expect(find.text('开始'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android键盘与双倍字号下失败反馈可滚动，输入和重试不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 当前会话已有失败任务，长错误文本不能挤走输入框。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    final _Repository repository = _Repository(_Auth())
      ..serverRun = <String, dynamic>{
        'id': 'run',
        'status': 'failed',
        'errorMessage': List<String>.filled(16, '网络请求未能完成，请核实执行结果。').join(),
      };
    await cache.save(
      AssistantCache.scopeFor('https://example.com/api', 'owner'),
      <String, dynamic>{'conversationId': 'conversation'},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(_AuthController.new),
          assistantRepositoryProvider.overrideWithValue(repository),
          assistantCacheProvider.overrideWithValue(cache),
          assistantSettingsProvider.overrideWith(
            (Ref ref) async => <String, dynamic>{'enabled': true},
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light)
              .copyWith(platform: TargetPlatform.android),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 300),
            ),
            child: child!,
          ),
          home: const Scaffold(body: AssistantPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('assistant-input')),
      findsOneWidget,
    );
    expect(find.text('重试任务'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await cache.close();
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 真实助手页面展示合成业务结果与批量确认', (
      WidgetTester tester,
    ) async {
      // 仅合成业务事实，不连接真实服务器或模型。
      final Size size = platform == TargetPlatform.windows
          ? const Size(1280, 900)
          : const Size(390, 844);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 用内存缓存恢复会话身份。
      final AssistantCache cache = AssistantCache.forTesting(
        NativeDatabase.memory(),
      );
      // 真实卡片协议中的两条准备变化。
      final Map<String, dynamic> plan = <String, dynamic>{
        'id': 'task',
        'version': 1,
        'previewHash': List<String>.filled(64, 'a').join(),
        'targetCount': 2,
        'preview': <String, dynamic>{
          'changes': <Object>[
            <String, dynamic>{
              'label': '阅读 LangGraph 文档',
              'newRecord': true,
              'before': null,
              'after': <String, dynamic>{
                'title': '阅读 LangGraph 文档',
                'scheduledDate': '2026-10-24',
              },
            },
            <String, dynamic>{
              'label': '练习面试题',
              'newRecord': true,
              'before': null,
              'after': <String, dynamic>{
                'title': '练习面试题',
                'scheduledDate': '2026-10-24',
              },
            },
          ],
        },
      };
      // 接口只返回固定数据。
      final _Repository repository = _Repository(_Auth())
        ..serverRun = <String, dynamic>{
          'id': 'run',
          'status': 'waitingConfirmation',
          'plan': plan,
        }
        ..serverMessages = <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'user',
            'role': 'user',
            'content': '明天帮我安排阅读文档和练习面试题两个待办。',
            'cards': <Object>[],
          },
          <String, dynamic>{
            'id': 'answer',
            'role': 'assistant',
            'content': '我准备好了 2 条待办。请核对下面的清单，确认后会一起保存。',
            'cards': <Object>[],
          },
        ];
      await cache.save(
        AssistantCache.scopeFor('https://example.com/api', 'owner'),
        <String, dynamic>{'conversationId': 'conversation'},
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(_AuthController.new),
            assistantRepositoryProvider.overrideWithValue(repository),
            assistantCacheProvider.overrideWithValue(cache),
            assistantSettingsProvider.overrideWith(
              (Ref ref) async => <String, dynamic>{'enabled': true},
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light)
                .copyWith(platform: platform),
            home: const RepaintBoundary(
              key: ValueKey<String>('assistant-preview'),
              child: Scaffold(body: SafeArea(child: AssistantPage())),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认修改 2 个对象'), findsOneWidget);
      expect(find.textContaining('阅读 LangGraph 文档'), findsWidgets);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        await tester.runAsync(() async {
          // 仅在显式请求预览时把合成界面保存到忽略的build目录。
          final RenderRepaintBoundary boundary = tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey<String>('assistant-preview')),
              );
          // 捕获原生Flutter渲染，不使用浏览器替代界面。
          final ui.Image image = await boundary.toImage();
          // 无损预览字节。
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/assistant_previews').create(recursive: true);
          await File('build/assistant_previews/${platform.name}.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await cache.close();
    });
  }

  testWidgets('他端计划先接管，本机修改草稿立即禁用旧确认且不自动提交', (WidgetTester tester) async {
    // 两端共用的真实计划版本。
    final Map<String, dynamic> plan = <String, dynamic>{
      'id': 'task',
      'version': 1,
      'previewHash': List<String>.filled(64, 'a').join(),
      'targetCount': 2,
      'preview': <String, dynamic>{'changes': <Object>[]},
    };
    // 内存缓存只提供会话身份。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    final _Repository repository = _Repository(_Auth())
      ..serverRun = <String, dynamic>{
        'id': 'run',
        'status': 'waitingConfirmation',
        'requiresTakeover': true,
        'plan': plan,
      };
    await cache.save(
      AssistantCache.scopeFor('https://example.com/api', 'owner'),
      <String, dynamic>{'conversationId': 'conversation'},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(_AuthController.new),
          assistantRepositoryProvider.overrideWithValue(repository),
          assistantCacheProvider.overrideWithValue(cache),
          assistantSettingsProvider.overrideWith(
            (Ref ref) async => <String, dynamic>{'enabled': true},
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: const Scaffold(body: AssistantPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<AssistantPlanCard>(find.byType(AssistantPlanCard)).enabled,
      isFalse,
    );
    expect(find.text('在此设备接管'), findsOneWidget);
    await tester.tap(find.text('在此设备接管'));
    await tester.pumpAndSettle();
    expect(
      repository.calls
          .where(
            (call) =>
                call.path == '/runs/run/takeover' && call.method == 'POST',
          )
          .length,
      1,
    );
    // 后端事件明确当前设备已拥有任务，才允许处理卡片。
    repository.streams.last.add(
      AssistantEvent(
        seq: 1,
        type: 'run.updated',
        runId: 'run',
        data: <String, dynamic>{
          'run': <String, dynamic>{
            'id': 'run',
            'status': 'waitingConfirmation',
            'requiresTakeover': false,
            'plan': plan,
          },
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('在此设备接管'), findsNothing);
    expect(
      tester.widget<AssistantPlanCard>(find.byType(AssistantPlanCard)).enabled,
      isTrue,
    );
    await tester.ensureVisible(find.text('修改方案'));
    await tester.tap(find.text('修改方案'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AssistantPlanCard>(find.byType(AssistantPlanCard)).enabled,
      isFalse,
    );
    expect(
      tester
          .widget<OmniTextField>(
            find.byKey(const ValueKey<String>('assistant-input')),
          )
          .controller!
          .text,
      '修改方案：',
    );
    expect(
      repository.calls.where((call) => call.path.endsWith('/decision')),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await cache.close();
  });

  testWidgets('会话重命名保存后退出动画不复用已释放输入控制器', (WidgetTester tester) async {
    // 通过真实页面和弹窗验证控制器的卸载边界。
    final AssistantCache cache = AssistantCache.forTesting(
      NativeDatabase.memory(),
    );
    final _Repository repository = _Repository(_Auth());
    await cache.save(
      AssistantCache.scopeFor('https://example.com/api', 'owner'),
      <String, dynamic>{'conversationId': 'conversation'},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(_AuthController.new),
          assistantRepositoryProvider.overrideWithValue(repository),
          assistantCacheProvider.overrideWithValue(cache),
          assistantSettingsProvider.overrideWith(
            (Ref ref) async => <String, dynamic>{'enabled': true},
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: const Scaffold(body: AssistantPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('重命名对话'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is OmniTextField && widget.decoration.labelText == '会话名称',
      ),
      '面试复盘',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
      repository.calls
          .where(
            (call) =>
                call.method == 'PATCH' &&
                call.path == '/conversations/conversation',
          )
          .single
          .data,
      <String, String>{'title': '面试复盘'},
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await cache.close();
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 助手开关直接保存，不弹出开启确认', (
      WidgetTester tester,
    ) async {
      // 当前接口捕获真实开关发出的完整版本化设置。
      final _Repository repository = _Repository(_Auth());
      // 设置行由服务器快照控制，点击不乐观伪造成功。
      final Map<String, dynamic> settings = <String, dynamic>{
        'revision': 3,
        'enabled': false,
        'profileId': 'profile',
        'memoryReadEnabled': true,
        'memoryWriteEnabled': true,
        'timeZone': 'Asia/Shanghai',
        'profiles': <Object>[
          <String, dynamic>{
            'id': 'profile',
            'name': '测试模型',
            'model': 'test',
            'hasApiKey': true,
          },
        ],
      };
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            assistantRepositoryProvider.overrideWithValue(repository),
            assistantSettingsProvider.overrideWith((Ref ref) async => settings),
          ],
          child: MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light)
                .copyWith(platform: platform),
            home: const Scaffold(
              body: SingleChildScrollView(child: AssistantSettingsSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('assistant-enabled-switch')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OmniDialogScaffold), findsNothing);
      expect(find.text('暂不开启'), findsNothing);
      expect(
        repository.calls.where((call) => call.method == 'PUT').single.data,
        <String, dynamic>{
          'revision': 3,
          'enabled': true,
          'profileId': 'profile',
          'memoryReadEnabled': true,
          'memoryWriteEnabled': true,
          'timeZone': 'Asia/Shanghai',
        },
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('助手设置不再显示重复模型选择和能力测试入口', (WidgetTester tester) async {
    // 读取正式provider，能力声明与连接测试输出保持独立。
    final _Repository repository = _Repository(_Auth());
    // 旧测试支持图片，但新开关关闭时仍展示未开启。
    final Map<String, dynamic> profile = <String, dynamic>{
      'id': 'profile',
      'name': '测试模型',
      'model': 'test',
      'hasApiKey': true,
      'multimodal': false,
      'capabilities': <String, dynamic>{'imageInput': 'supported'},
    };
    repository.responses['/settings'] = <String, dynamic>{
      'enabled': true,
      'profileId': 'profile',
      'profiles': <Object>[profile],
    };
    for (final bool enabled in <bool>[false, true]) {
      profile['multimodal'] = enabled;
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey<bool>(enabled),
          overrides: [
            authControllerProvider.overrideWith(_AuthController.new),
            assistantRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light),
            home: const Scaffold(
              body: SingleChildScrollView(child: AssistantSettingsSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('助手使用的模型'), findsNothing);
      expect(find.textContaining('多模态：'), findsNothing);
      expect(find.text('测试助手能力'), findsNothing);
      expect(find.text('打开助手'), findsNothing);
      expect(find.text('测试图片能力'), findsNothing);
      expect(repository.calls.where((call) => call.path == '/test'), isEmpty);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('助手设置仅保留启用和记忆分区，管理入口归入记忆区域', (WidgetTester tester) async {
    // 完整配置用于验证模型存在时也不会重复展示模型区域。
    final Map<String, dynamic> settings = <String, dynamic>{
      'revision': 1,
      'enabled': true,
      'profileId': 'profile',
      'memoryReadEnabled': true,
      'memoryWriteEnabled': true,
      'profiles': <Object>[
        <String, dynamic>{
          'id': 'profile',
          'name': '测试模型',
          'model': 'test',
          'hasApiKey': true,
          'multimodal': true,
        },
      ],
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          assistantSettingsProvider.overrideWith((Ref ref) async => settings),
        ],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: const Scaffold(
            body: SingleChildScrollView(child: AssistantSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 两个区域必须保持从启用到记忆的阅读顺序。
    final Finder header = find.byKey(
      const ValueKey<String>('assistant-settings-header'),
    );
    // 记忆权限及管理入口区域。
    final Finder memory = find.byKey(
      const ValueKey<String>('assistant-memory-section'),
    );
    expect(tester.getRect(header).bottom, lessThan(tester.getRect(memory).top));
    expect(
      find.byKey(const ValueKey<String>('assistant-model-section')),
      findsNothing,
    );
    expect(find.text('助手使用的模型'), findsNothing);
    expect(find.text('测试助手能力'), findsNothing);
    expect(find.text('打开助手'), findsNothing);
    expect(
      find.descendant(of: memory, matching: find.text('管理记忆')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('助手设置仅保留启用与记忆控制，双倍字号不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          assistantSettingsProvider.overrideWith(
            (Ref ref) async => <String, dynamic>{
              'revision': 1,
              'enabled': true,
              'profileId': 'profile',
              'profiles': <Object>[
                <String, dynamic>{
                  'id': 'profile',
                  'name': '测试模型',
                  'model': 'test',
                  'hasApiKey': true,
                  'multimodal': false,
                },
              ],
              'memoryReadEnabled': true,
              'memoryWriteEnabled': true,
            },
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.dark),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: AssistantSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('应用内助手'), findsOneWidget);
    expect(find.text('助手使用的模型'), findsNothing);
    expect(find.text('测试助手能力'), findsNothing);
    expect(find.text('打开助手'), findsNothing);
    expect(find.text('管理记忆'), findsOneWidget);
    expect(find.textContaining('多模态：'), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('assistant-memory-write-switch')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 执行结果原地编辑、卡头撤销及直接保存笔记不发送AI消息', (tester) async {
      tester.view.physicalSize = const Size(1200, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 合成持久聊天与真实页面，隔离本地业务数据库。
      final AssistantCache cache = AssistantCache.forTesting(
        NativeDatabase.memory(),
      );
      // 正常结束的任务不会阻止用户编辑结果。
      final _Repository repository = _Repository(_Auth())
        ..serverRun = <String, dynamic>{
          'id': 'run',
          'taskId': 'task',
          'status': 'succeeded',
          'answerMessageId': 'answer',
          'canUndo': true,
        };
      // 初始领域快照不包含无关内部字段。
      final Map<String, dynamic> record = <String, dynamic>{
        'id': 'todo-id',
        'title': '完成个人网站开发',
        'taskType': 'normal',
        'scheduledDate': '2026-10-25',
        'priorityQuadrant': 2,
        'completed': false,
        'updatedAt': '2026-10-25T01:00:00Z',
        'deletedAt': null,
      };
      repository.serverMessages = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'answer',
          'role': 'assistant',
          'content': '已新增待办。',
          'createdAt': '2026-10-25T09:30:00',
          'cards': <Object>[
            <String, dynamic>{
              'type': 'result',
              'entityRefs': <Object>[
                <String, dynamic>{
                  'module': 'todos',
                  'id': 'todo-id',
                  'operation': 'create',
                  'record': record,
                },
              ],
            },
          ],
        },
      ];
      repository.responses['/settings'] = <String, dynamic>{'enabled': true};
      repository.responses['/messages/answer/note'] = <String, dynamic>{
        'noteId': 'saved-note',
        'savedAt': '2026-10-25T02:00:00Z',
      };
      repository.responses['/entities/todos/todo-id'] = <String, dynamic>{
        'module': 'todos',
        'id': 'todo-id',
        'record': record,
        'editVersion': 'initial-version',
      };
      await cache.save(
        AssistantCache.scopeFor('https://example.com/api', 'owner'),
        <String, dynamic>{'conversationId': 'conversation'},
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await cache.close();
        for (final StreamController<AssistantEvent> stream
            in repository.streams) {
          await stream.close();
        }
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(_AuthController.new),
            assistantRepositoryProvider.overrideWithValue(repository),
            assistantCacheProvider.overrideWithValue(cache),
            syncRuntimeProvider.overrideWithValue(_ClarificationSync()),
          ],
          child: MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light)
                .copyWith(platform: platform),
            home: const Scaffold(body: AssistantPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('执行结果 • 新增待办 • 完成个人网站开发'), findsOneWidget);
      expect(find.text('任务名称'), findsNothing);
      expect(find.text('已完成'), findsNothing);
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        // 中文预览使用真实消息行，覆盖卡头撤销与保存/时间的最终位置。
        final Finder toolbar = find.byKey(
          const ValueKey<String>('assistant-save-note-answer'),
        );
        // 鼠标只用于展示Windows的悬停入口，手机入口原本常驻。
        final TestGesture mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: const Offset(10, 10));
        await mouse.moveTo(tester.getCenter(toolbar));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          // 选取页面最近的真实重绘边界，不重新构造界面。
          final RenderRepaintBoundary boundary = tester
              .renderObject<RenderRepaintBoundary>(
                find
                    .ancestor(
                      of: find.byType(AssistantPage),
                      matching: find.byType(RepaintBoundary),
                    )
                    .first,
              );
          // 合成业务资料用于视觉验收，不包含真实用户数据。
          final ui.Image preview = await boundary.toImage();
          // 无损PNG便于核对字体与控件几何。
          final ByteData? bytes = await preview.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory('build/assistant_previews').create(recursive: true);
          await File(
            'build/assistant_previews/answer_actions_${platform.name}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          preview.dispose();
        });
        await mouse.removePointer();
      }
      // 撤销入口始终属于该回答的折叠结果标题，不展开表单。
      final Finder undo = find.byKey(
        const ValueKey<String>('assistant-result-undo-todo-id'),
      );
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(
        repository.calls.where((call) => call.path == '/runs/run/undo'),
        hasLength(1),
      );
      expect(find.text('任务名称'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('assistant-result-toggle-todo-id')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(OmniButton, '编辑'));
      await tester.tap(find.widgetWithText(OmniButton, '编辑'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('result-input-title')),
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('result-input-title')),
        '网站完成第一版',
      );
      await tester.pumpAndSettle();
      repository.responses['/entities/todos/todo-id'] = <String, dynamic>{
        'module': 'todos',
        'id': 'todo-id',
        'editVersion': 'saved-version',
        'record': <String, dynamic>{
          ...record,
          'title': '网站完成第一版',
          'updatedAt': '2026-10-25T01:01:00Z',
        },
      };
      await tester.ensureVisible(find.widgetWithText(OmniButton, '保存'));
      await tester.tap(find.widgetWithText(OmniButton, '保存'));
      await tester.pumpAndSettle();
      // 修改走固定实体接口，不再将人工编辑转成新的模型请求。
      final List<({String method, String path, Object? data})> writes =
          repository.calls.where((call) => call.method == 'PATCH').toList();
      expect(writes, hasLength(1));
      expect((writes.single.data as Map)['changes'], <String, dynamic>{
        'title': '网站完成第一版',
      });
      expect(
        repository.calls.where(
          (call) => call.method == 'POST' && call.path.endsWith('/messages'),
        ),
        isEmpty,
      );
      expect(find.text('执行结果 • 新增待办 • 网站完成第一版'), findsOneWidget);
      expect(find.text('已保存'), findsOneWidget);
      // 保存笔记只调用业务接口；现有输入草稿不会变成AI指令。
      await tester.enterText(
        find.byKey(const ValueKey<String>('assistant-input')),
        '保留原来的草稿',
      );
      await tester.pumpAndSettle();
      // 桌面通过真实鼠标悬停后点击，手机入口常驻。
      final TestGesture? saveMouse = platform == TargetPlatform.windows
          ? await tester.createGesture(kind: ui.PointerDeviceKind.mouse)
          : null;
      if (saveMouse != null) {
        // 鼠标进入整条回答后工具栏才显示。
        await saveMouse.addPointer(location: const Offset(10, 10));
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('assistant-save-note-answer')),
        );
        await saveMouse.moveTo(
          tester.getCenter(
            find.byKey(const ValueKey<String>('assistant-save-note-answer')),
          ),
        );
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('assistant-save-note-answer')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('assistant-save-note-answer')),
      );
      await tester.pumpAndSettle();
      await saveMouse?.removePointer();
      expect(
        repository.calls.where((call) => call.path == '/messages/answer/note'),
        hasLength(1),
      );
      expect(
        repository.calls.where(
          (call) => call.method == 'POST' && call.path.endsWith('/messages'),
        ),
        isEmpty,
      );
      expect(
        tester
            .widget<OmniTextField>(
              find.byKey(const ValueKey<String>('assistant-input')),
            )
            .controller!
            .text,
        '保留原来的草稿',
      );
      expect(find.text('已保存'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('结果values展示正文及分类名，输入元数据不渲染为结果卡', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                AssistantMessageCard(
                  card: <String, dynamic>{
                    'type': 'userInput',
                    'selection': <String, String>{'id': 'internal'},
                  },
                  enabled: true,
                  onChoice: (String content, Map<String, dynamic> selection) {},
                ),
                AssistantMessageCard(
                  card: <String, dynamic>{
                    'type': 'result',
                    'result': <String, dynamic>{
                      'values': <Object>[
                        <String, dynamic>{
                          'note': <String, dynamic>{
                            'body': '本周学习回顾',
                            'tags': '["97a3aa0d-4ed1-51af-9e46-a5ac1b682dc4"]',
                            'tagNames': <String>['学习'],
                          },
                        },
                      ],
                    },
                  },
                  enabled: true,
                  onChoice: (String content, Map<String, dynamic> selection) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('执行结果 • 已保存笔记'), findsOneWidget);
    expect(find.textContaining('本周学习回顾'), findsOneWidget);
    expect(find.text('学习'), findsNothing);
    await tester.tap(find.textContaining('执行结果 • 已保存笔记'));
    await tester.pumpAndSettle();
    expect(find.text('学习'), findsOneWidget);
    expect(find.textContaining('97a3aa0d'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 空候选澄清卡可填写并继续，旧卡片不重复提问', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = platform == TargetPlatform.windows
          ? const Size(1200, 900)
          : const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 合成待澄清任务与内存缓存，不读取真实聊天。
      final AssistantCache cache = AssistantCache.forTesting(
        NativeDatabase.memory(),
      );
      // Windows覆盖缺省choices，Android覆盖空数组的旧协议。
      final _Repository repository = _Repository(_Auth())
        ..serverRun = <String, dynamic>{
          'id': 'run',
          'taskId': 'task',
          'status': 'waitingInput',
          'answerMessageId': 'question',
        }
        ..serverMessages = <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'old',
            'role': 'assistant',
            'content': '之前的问题',
            'cards': <Object>[
              <String, dynamic>{'type': 'choice'},
            ],
          },
          <String, dynamic>{
            'id': 'question',
            'role': 'assistant',
            'content': '完成个人网站开发，计划哪天开始？',
            'cards': <Object>[
              <String, dynamic>{
                'type': 'choice',
                'question': '计划哪天开始？',
                if (platform == TargetPlatform.android) 'choices': <Object>[],
              },
            ],
          },
        ];
      repository.responses['/settings'] = <String, dynamic>{'enabled': true};
      await cache.save(
        AssistantCache.scopeFor('https://example.com/api', 'owner'),
        <String, dynamic>{'conversationId': 'conversation'},
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await cache.close();
        for (final StreamController<AssistantEvent> stream
            in repository.streams) {
          await stream.close();
        }
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(_AuthController.new),
            assistantRepositoryProvider.overrideWithValue(repository),
            assistantCacheProvider.overrideWithValue(cache),
            syncRuntimeProvider.overrideWithValue(_ClarificationSync()),
          ],
          child: MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light)
                .copyWith(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(
                  platform == TargetPlatform.android ? 2 : 1,
                ),
              ),
              child: RepaintBoundary(
                key: const ValueKey<String>('clarification-preview'),
                child: child!,
              ),
            ),
            home: const Scaffold(body: AssistantPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('请选择对象'), findsNothing);
      expect(find.text('补充信息'), findsOneWidget);
      // 只有当前问题可编辑，且空白不能发出请求。
      final Finder input = find.byKey(
        const ValueKey<String>('assistant-clarification-input'),
      );
      expect(input, findsOneWidget);
      expect(
        tester
            .widget<OmniButton>(find.widgetWithText(OmniButton, '继续'))
            .onPressed,
        isNull,
      );
      await tester.enterText(input, '   ');
      await tester.pump();
      expect(
        tester
            .widget<OmniButton>(find.widgetWithText(OmniButton, '继续'))
            .onPressed,
        isNull,
      );
      await tester.enterText(input, ' 明天开始，不设置截止日期 ');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(OmniButton, '继续'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        await tester.runAsync(() async {
          // 真实Flutter渲染供宽屏及双倍字号检查。
          final RenderRepaintBoundary boundary = tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey<String>('clarification-preview')),
              );
          // 当前界面的像素快照。
          final ui.Image image = await boundary.toImage();
          // 无损输出到忽略目录。
          final ByteData? bytes = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory('build/assistant_previews').create(recursive: true);
          await File(
            'build/assistant_previews/${platform.name}_clarification.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.widgetWithText(OmniButton, '继续'));
      await tester.pumpAndSettle();
      // 实际页面通过控制器发出普通消息，不产生伪造的对象selection。
      final List<Object?> sent = repository.calls
          .where(
            (call) => call.method == 'POST' && call.path.endsWith('/messages'),
          )
          .map((call) => call.data)
          .toList();
      expect(sent, hasLength(1));
      expect(sent.single, containsPair('content', '明天开始，不设置截止日期'));
      expect(sent.single, isNot(contains('selection')));
      expect(find.text('请选择对象'), findsNothing);
      expect(input, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('真实对象候选仍通过精确身份选择，禁用卡片不允许提交', (WidgetTester tester) async {
    // 捕获用户选择的真实引用。
    Map<String, dynamic>? selected;
    // 模拟页面切换只读或正在提交状态。
    bool enabled = true;
    // 重建同一卡片，不引入额外业务调用。
    Widget card() => MaterialApp(
      theme: AppTheme.build(brightness: Brightness.light),
      home: Scaffold(
        body: AssistantMessageCard(
          card: <String, dynamic>{
            'type': 'choice',
            'choices': <Object>[
              <String, dynamic>{
                'id': 'real-id',
                'module': 'todos',
                'label': '网站开发',
              },
            ],
          },
          enabled: enabled,
          onChoice: (content, selection) => selected = selection,
          onClarification: (_) => fail('对象选择不可作为普通补充消息发送'),
        ),
      ),
    );
    await tester.pumpWidget(card());
    expect(find.text('请选择对象'), findsOneWidget);
    await tester.tap(find.text('网站开发'));
    expect(selected, <String, dynamic>{'id': 'real-id', 'module': 'todos'});
    enabled = false;
    await tester.pumpWidget(card());
    expect(
      tester
          .widget<OmniButton>(find.widgetWithText(OmniButton, '网站开发'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('旧来源卡使用中性名称，不把检索结果宣称为保存成功', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: AssistantMessageCard(
            card: <String, dynamic>{
              'type': 'references',
              'entityRefs': <Object>[
                <String, dynamic>{
                  'module': 'time',
                  'id': 'record',
                  'label': '学习记录',
                },
              ],
            },
            enabled: true,
            onChoice: (String content, Map<String, dynamic> selection) {},
          ),
        ),
      ),
    );
    expect(find.text('相关记录'), findsOneWidget);
    expect(find.textContaining('部分来源'), findsNothing);
    expect(find.textContaining('服务器已保存'), findsNothing);
    expect(find.text('查看学习记录'), findsNothing);
    await tester.tap(find.text('相关记录'));
    await tester.pumpAndSettle();
    expect(find.text('查看学习记录'), findsOneWidget);
    await tester.tap(find.text('相关记录'));
    await tester.pumpAndSettle();
    expect(find.text('查看学习记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    for (final String scenario in <String>['six', 'limited', 'legacy']) {
      testWidgets('${platform.name} $scenario 来源卡窄屏大字号只展示真实截断提示', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // 卡片和来源均为合成数据，旧字段不能被解释为新的截断事实。
        final Map<String, dynamic> card = <String, dynamic>{
          'type': 'references',
          if (scenario != 'legacy')
            'referencesTruncated': scenario == 'limited',
          if (scenario == 'legacy') ...<String, dynamic>{
            'referenceLimited': true,
            'message': '部分来源记录；完整数据覆盖与截止时刻见回答。',
          },
          'entityRefs': <Object>[
            for (
              int index = 0;
              index < (scenario == 'limited' ? 21 : 6);
              index++
            )
              <String, dynamic>{
                'module': 'todos',
                'id': 'record-$index',
                'label': '重要任务${index + 1}',
              },
          ],
        };
        // 预览截取真实布局，平台主题和两倍字号同样参与溢出检查。
        final GlobalKey preview = GlobalKey();
        // 每个场景从卡片顶部开始，不恢复其他场景的滚动位置。
        final ScrollController scroll = ScrollController(
          keepScrollOffset: false,
        );
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness: Brightness.light)
                .copyWith(platform: platform),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 900),
                textScaler: TextScaler.linear(2),
              ),
              child: RepaintBoundary(
                key: preview,
                child: Scaffold(
                  body: SingleChildScrollView(
                    controller: scroll,
                    child: AssistantMessageCard(
                      card: card,
                      enabled: true,
                      onChoice: (
                        String content,
                        Map<String, dynamic> selection,
                      ) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 可滚动长列表的预览固定顶部，保证标题和截断说明可同时核对。
        scroll.jumpTo(0);
        await tester.pump();
        expect(find.text('相关记录'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('相关记录')).dy,
          greaterThanOrEqualTo(0),
        );
        expect(find.textContaining('部分来源'), findsNothing);
        expect(find.textContaining('服务器已保存'), findsNothing);
        expect(find.text('仅展示前 20 条相关记录'), findsNothing);
        expect(find.text('查看重要任务6'), findsNothing);
        await tester.tap(find.text('相关记录'));
        await tester.pumpAndSettle();
        expect(
          find.text('仅展示前 20 条相关记录'),
          scenario == 'limited' ? findsOneWidget : findsNothing,
        );
        expect(find.text('查看重要任务6'), findsOneWidget);
        expect(find.text('查看重要任务21'), findsNothing);
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
          await tester.runAsync(() async {
            // 输出到忽略的构建目录，供人工查看中文字体及窄屏换行。
            final Directory directory = Directory('build/assistant_previews');
            await directory.create(recursive: true);
            // 渲染边界与实际测试页面一致，避免另外重建一份预览。
            final RenderRepaintBoundary boundary =
                preview.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            // 图片只在本地保存，不触发外部服务。
            final ui.Image image = await boundary.toImage(pixelRatio: 1);
            try {
              // PNG 编码保持中文渲染的原始像素。
              final ByteData bytes = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await File(
                '${directory.path}/reference_${platform.name}_$scenario.png',
              ).writeAsBytes(bytes.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('相关记录重建保留展开状态，另一条消息默认收起，缓存也能展开', (WidgetTester tester) async {
    // 可变父级模拟流式正文和运行状态引发的重建。
    Widget card(String messageId, {bool enabled = false}) => MaterialApp(
      theme: AppTheme.build(brightness: Brightness.light),
      home: Scaffold(
        body: AssistantMessageCard(
          key: ValueKey<String>(messageId),
          card: const <String, dynamic>{
            'type': 'references',
            'entityRefs': <Object>[
              <String, dynamic>{
                'id': 'record',
                'module': 'todos',
                'label': '来源任务',
              },
            ],
          },
          enabled: enabled,
          onChoice: (String content, Map<String, dynamic> selection) {},
        ),
      ),
    );
    await tester.pumpWidget(card('answer-a'));
    expect(find.text('查看来源任务'), findsNothing);
    await tester.tap(find.text('相关记录'));
    await tester.pumpAndSettle();
    expect(find.text('查看来源任务'), findsOneWidget);
    await tester.pumpWidget(card('answer-a', enabled: true));
    expect(find.text('查看来源任务'), findsOneWidget);
    await tester.pumpWidget(card('answer-b'));
    expect(find.text('查看来源任务'), findsNothing);
    // 折叠按钮可通过键盘操作，折叠内容没有隐藏焦点。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('查看来源任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('记忆停用提交完整内容和原修订，保留分类与有效期', (WidgetTester tester) async {
    // 记忆操作直接作用于合成后端接口。
    final _Repository repository = _Repository(_Auth());
    repository.responses['/memories'] = <String, dynamic>{
      'items': <Object>[
        <String, dynamic>{
          'id': 'memory',
          'content': '偏好简洁回答',
          'category': 'preference',
          'enabled': true,
          'expiresAt': '2027-01-01T00:00:00Z',
          'revision': 3,
        },
      ],
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [assistantRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: const AssistantMemoriesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 触发真实控件回调，校验冻结的写入契约。
    final OmniSwitch toggle = tester.widget<OmniSwitch>(
      find.byType(OmniSwitch),
    );
    toggle.onChanged!(false);
    await tester.pumpAndSettle();
    expect(
      repository.calls.where((call) => call.method == 'PATCH').single.data,
      <String, dynamic>{
        'revision': 3,
        'content': '偏好简洁回答',
        'category': 'preference',
        'expiresAt': '2027-01-01T00:00:00Z',
        'enabled': false,
      },
    );
    expect(tester.takeException(), isNull);
  });

  for (final bool chooseExpiry in <bool>[true, false]) {
    testWidgets(
      '记忆有效期${chooseExpiry ? '按本机当天结束转UTC' : '长期提交null'}，界面不要求输入协议时间',
      (WidgetTester tester) async {
        // 仅使用固定的内存接口，不写真实长期记忆。
        final _Repository repository = _Repository(_Auth());
        repository.responses['/memories'] = <String, dynamic>{
          'items': <Object>[],
        };
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              assistantRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              theme: AppTheme.build(brightness: Brightness.light),
              home: const AssistantMemoriesPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('新增记忆'));
        await tester.pumpAndSettle();
        expect(find.textContaining('ISO'), findsNothing);
        await tester.enterText(
          find.byWidgetPredicate(
            (Widget widget) =>
                widget is OmniTextField &&
                widget.decoration.labelText == '需要记住的内容',
          ),
          '只记住需要的偏好',
        );
        if (chooseExpiry) {
          // 调用统一日期组件的真实选择回调，日期按本机时区解释。
          final OmniDatePickerButton picker = tester
              .widget<OmniDatePickerButton>(find.byType(OmniDatePickerButton));
          picker.onChanged!(DateTime(2027, 1, 31));
          await tester.pumpAndSettle();
          expect(find.text('2027-01-31'), findsOneWidget);
        }
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        // 最终API契约携带精确UTC或明确长期空值。
        final Map<String, dynamic> payload =
            repository.calls
                    .where(
                      (call) =>
                          call.method == 'POST' && call.path == '/memories',
                    )
                    .single
                    .data
                as Map<String, dynamic>;
        expect(
          payload['expiresAt'],
          chooseExpiry
              ? DateTime(2027, 1, 31, 23, 59, 59, 999).toUtc().toIso8601String()
              : null,
        );
        expect(payload['content'], '只记住需要的偏好');
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('分类UUID不能被展示成分类名称，未知原始对象使用可读标签', () {
    expect(
      assistantDisplayValue('2026-10-23T20:00:00+08:00'),
      '2026-10-23 20:00:00+08:00',
    );
    expect(
      assistantDisplayValue('97a3aa0d-4ed1-51af-9e46-a5ac1b682dc4'),
      '已关联记录',
    );
    expect(
      assistantDisplayValue(<String, String>{'id': 'internal', 'name': '学习'}),
      '学习',
    );
  });
}
