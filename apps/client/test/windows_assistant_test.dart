import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_page.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_cards.dart';
import 'package:omni_butler/shared/layout/responsive_shell.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 测试身份只用于隔离内存接口。
class _DesktopAuth implements AuthRepository {
  /// 固定认证代次。
  @override
  int get sessionGeneration => 1;

  /// 不建立真实网络流。
  @override
  CancelToken createSessionStreamToken(int generation) => CancelToken();

  /// 未使用的认证能力禁止调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 返回没有真实凭据的合成会话。
class _DesktopIdentity extends AuthController {
  /// 固定作用域用于验证缓存和页面组合。
  @override
  Future<SyncSession?> build() async => const SyncSession(
    identity: SyncIdentity(id: 'desktop-test-owner'),
    apiBaseUrl: 'https://assistant.invalid/api',
    isOffline: false,
  );
}

/// 页面发送通过同步检查点，但不接触实际 PowerSync。
class _DesktopRuntime implements OmniSyncRuntime {
  /// 记录同步检查次数。
  int checkpoints = 0;

  /// 模拟已确认上传的检查点。
  @override
  Future<void> catchUp({Duration timeout = const Duration(minutes: 3)}) async {
    checkpoints++;
  }

  /// 其它同步操作不属于此夹具。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 全局导航同步状态不启动后台任务。
class _DesktopIdleSync extends SyncController {
  /// 禁用真实连接初始化。
  @override
  Future<void> build() async {}
}

/// 有状态接口替身保留页面请求，不替换真实页面或控制器。
class _DesktopRepository extends AssistantRepository {
  /// 请求记录用于验证目标身份和完整设置。
  final List<({String method, String path, Object? data})> calls = [];

  /// 合成历史的置顶、标题和删除状态。
  final List<Map<String, dynamic>> conversations = [
    {'id': 'conversation-3', 'title': '英语', 'isPinned': true},
    {'id': 'conversation-2', 'title': '本周回顾', 'isPinned': false},
    {'id': 'conversation-1', 'title': '整理最近的想法', 'isPinned': false},
  ];

  /// 已保存的全局助手设置，不包含真实模型凭据。
  Map<String, dynamic> settings = {
    'revision': 7,
    'enabled': true,
    'profileId': 'profile-1',
    'memoryReadEnabled': true,
    'memoryWriteEnabled': false,
    'timeZone': 'Asia/Shanghai',
    'profiles': [
      {
        'id': 'profile-1',
        'name': '常用模型',
        'model': 'GPT-6.1 Sol',
        'hasApiKey': true,
      },
      {
        'id': 'profile-2',
        'name': '深度分析',
        'model': 'GPT-6 Astra',
        'hasApiKey': true,
      },
      {'id': 'profile-3', 'name': '未配置密钥', 'model': '示例模型', 'hasApiKey': false},
    ],
  };

  /// 模拟设置保存失败。
  bool failSettings = false;

  /// 可控制搜索响应顺序。
  final Map<String, Completer<Map<String, dynamic>>> delayedSearches = {};

  /// 分页测试按请求顺序返回真实接口形状。
  final Map<String, List<Map<String, dynamic>>> searchPages = {};

  /// 可切换结算状态的运行快照。
  Map<String, dynamic>? activeRun;

  /// 只有计时测试需要持续订阅。
  StreamController<AssistantEvent>? eventStream;

  /// 创建测试仓储。
  _DesktopRepository() : super(_DesktopAuth());

  /// 按真实接口形状返回合成数据。
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    calls.add((method: method, path: path, data: data));
    // 请求参数用 URI 解析，确保查询与游标能共存。
    final Uri uri = Uri.parse(path);
    if (uri.path == '/settings') {
      if (method == 'PUT') {
        if (failSettings) throw const ApiFailure('模型设置保存失败，请重试');
        settings = {
          ...settings,
          ...data as Map<String, dynamic>,
          'revision': 8,
        };
      }
      return Map<String, dynamic>.from(settings);
    }
    if (uri.path == '/conversations' && method == 'GET') {
      // 通过消息正文命中会话，标题本身不包含查询词。
      final String query = uri.queryParameters['query'] ?? '';
      if (searchPages[query]?.isNotEmpty == true) {
        return searchPages[query]!.removeAt(0);
      }
      if (delayedSearches.containsKey(query)) {
        return delayedSearches[query]!.future;
      }
      return {
        'items': query.isEmpty
            ? conversations.map(Map<String, dynamic>.from).toList()
            : conversations
                  .where(
                    (item) =>
                        (item['title'] as String).contains(query) ||
                        (query == '阅读' && item['id'] == 'conversation-2'),
                  )
                  .toList(),
        'nextCursor': null,
      };
    }
    if (uri.path == '/conversations' && method == 'POST') {
      // 新建会话不会复用已有身份。
      final Map<String, dynamic> created = {
        'id': 'new-chat',
        'title': '新对话',
        'isPinned': false,
      };
      conversations.add(created);
      return created;
    }
    if (uri.path.endsWith('/messages')) {
      if (method == 'POST') return {'id': 'run', 'status': 'succeeded'};
      return {
        'items': [
          {
            'id': 'user-1',
            'role': 'user',
            'content': '帮我整理最近的想法，找出值得继续推进的事情。',
            'cards': <Object>[],
          },
          {
            'id': 'answer-1',
            'role': 'assistant',
            'content': '最近的记录主要围绕学习、项目与生活安排。\n\n可以先完成本周的阅读计划，再集中整理项目中尚未解决的问题。',
            'elapsedMs': 46000,
            'cards': <Object>[],
          },
        ],
        'activeRun': activeRun,
        'nextCursor': null,
      };
    }
    if (method == 'PATCH') {
      // 元数据变化作用于请求路径中的明确目标。
      final Map<String, dynamic> target = conversations.firstWhere(
        (item) => item['id'] == uri.pathSegments.last,
      );
      target.addAll(data as Map<String, dynamic>);
      return target;
    }
    if (method == 'DELETE') {
      conversations.removeWhere((item) => item['id'] == uri.pathSegments.last);
    }
    return {};
  }

  /// 终态夹具不产生后台流事件。
  @override
  Stream<AssistantEvent> events(String runId, int after, CancelToken token) =>
      eventStream?.stream ?? const Stream.empty();
}

/// 组合真实全局导航与助手页面，测试本身不写用户目录。
Future<_DesktopRepository> _pumpDesktop(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  double textScale = 1,
  Brightness brightness = Brightness.light,
  _DesktopRepository? repository,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  // 平台字体必须在主题创建前选择，随后恢复全局调试变量。
  final ThemeData desktopTheme = AppTheme.build(brightness: brightness);
  debugDefaultTargetPlatformOverride = null;
  SharedPreferences.setMockInitialValues({'sync.enabled': false});
  // 使用内存偏好，避免读取本机主题与认证信息。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 内存 SQLite 缓存验证真正的初始恢复过程。
  final AssistantCache cache = AssistantCache.forTesting(
    NativeDatabase.memory(),
  );
  // 由调用方传入时允许设置失败和乱序响应。
  final _DesktopRepository fixed = repository ?? _DesktopRepository();
  await cache.save(
    AssistantCache.scopeFor(
      'https://assistant.invalid/api',
      'desktop-test-owner',
    ),
    {'conversationId': 'conversation-1'},
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        authControllerProvider.overrideWith(_DesktopIdentity.new),
        assistantRepositoryProvider.overrideWithValue(fixed),
        assistantCacheProvider.overrideWithValue(cache),
        syncControllerProvider.overrideWith(_DesktopIdleSync.new),
        syncRuntimeProvider.overrideWithValue(_DesktopRuntime()),
        syncStatusProvider.overrideWithValue(
          const AsyncData<SyncStatus?>(null),
        ),
        syncUploadQueueCountProvider.overrideWithValue(const AsyncData<int>(0)),
      ],
      child: MaterialApp(
        theme: desktopTheme,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(
            key: const ValueKey('windows-assistant-frame'),
            child: child,
          ),
        ),
        home: const ResponsiveShell(
          location: '/assistant',
          child: AssistantPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => precacheImage(
      const AssetImage('assets/icon/app_icon.png'),
      tester.element(find.byType(ResponsiveShell)),
    ),
  );
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await cache.close();
    await fixed.eventStream?.close();
  });
  return fixed;
}

/// 用稳定控件身份查找交互入口。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 正常测试比较便携 golden，显式预览模式输出中文原生截图。
Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
    await expectLater(
      _key('windows-assistant-frame'),
      matchesGoldenFile('goldens/assistant_windows_$name.png'),
    );
    return;
  }
  // 中文预览恢复真实阴影，避免测试模式将阴影画成粗灰边。
  final bool originalShadows = debugDisableShadows;
  debugDisableShadows = false;

  /// 同时重绘保留图层中的物理形状，使预览阴影使用真实路径。
  void repaint(RenderObject node) {
    node.markNeedsPaint();
    node.visitChildren(repaint);
  }

  repaint(tester.renderObject(_key('windows-assistant-frame')));
  await tester.pump();
  try {
    await tester.runAsync(() async {
      // 包含 Navigator 的绘制边界可以同时捕获模态搜索和菜单。
      final RenderRepaintBoundary boundary = tester.renderObject(
        _key('windows-assistant-frame'),
      );
      // 真实 Flutter 渲染的完整工作区。
      final ui.Image image = await boundary.toImage(pixelRatio: 1);
      try {
        // 无损图片只保存到忽略的构建目录。
        final ByteData? bytes = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await Directory('build/assistant_previews').create(recursive: true);
        await File('build/assistant_previews/windows_$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  } finally {
    debugDisableShadows = originalShadows;
  }
}

/// Windows 工作区的布局、操作和截图验收。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
    setUpAll(() async {
      // 显式预览使用系统中文字体，普通 golden 保持跨平台可重复。
      final ByteData font = ByteData.sublistView(
        await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
      );
      for (final String family in [
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'Roboto',
        'Ahem',
      ]) {
        // 给主题使用的字体族绑定同一份真实字体。
        final FontLoader loader = FontLoader(family)
          ..addFont(Future.value(font));
        await loader.load();
      }
      // 图标字体来自已经安装的 Flutter SDK。
      final ByteData icons = ByteData.sublistView(
        await File(
          'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes(),
      );
      await (FontLoader('MaterialIcons')..addFont(Future.value(icons))).load();
    });
  }

  testWidgets('Windows 工作区保留全局导航并对齐消息和输入列', (WidgetTester tester) async {
    await _pumpDesktop(tester);
    expect(_key('navigation-/assistant'), findsOneWidget);
    expect(find.text('知序'), findsOneWidget);
    expect(find.textContaining('46'), findsWidgets);
    // 使用真实几何验证整体布局，不只检查样式属性。
    final Rect sidebar = tester.getRect(_key('assistant-windows-sidebar'));
    // 输入区界定整列左右边界。
    final Rect composer = tester.getRect(_key('assistant-windows-composer'));
    // 无气泡回答的完整内容边界。
    final Rect answer = tester.getRect(_key('assistant-answer-answer-1'));
    // 用户气泡与输入区右侧对齐。
    final Rect bubble = tester.getRect(_key('assistant-user-message-user-1'));
    expect(sidebar.left, 58);
    expect(sidebar.width, 280);
    expect(composer.width, 880);
    expect(composer.left, greaterThan(sidebar.right));
    expect(composer.right, closeTo(answer.right, 1));
    expect(composer.left, closeTo(answer.left, 1));
    expect(bubble.right, closeTo(composer.right, 1));
    expect(composer.bottom, closeTo(900 - 18, 1));
    // 核对真正承载填色的表面，避免统一按钮样式吞掉圆形覆盖。
    final Material sendSurface = tester.widget(_key('assistant-send-surface'));
    expect(sendSurface.shape, isA<CircleBorder>());
    expect(tester.getSize(_key('assistant-send-surface')), const Size(36, 36));
    expect(
      tester.getCenter(_key('assistant-model-button')).dy,
      closeTo(tester.getCenter(_key('assistant-send-button')).dy, 1),
    );
    expect(tester.takeException(), isNull);
    await _capture(tester, 'chat');
  });

  testWidgets('搜索正文打开正确会话并显示参考弹窗', (WidgetTester tester) async {
    // 捕获服务器请求以核对正文检索参数。
    final _DesktopRepository repository = await _pumpDesktop(tester);
    await tester.tap(_key('assistant-search-button'));
    await tester.pumpAndSettle();
    await _capture(tester, 'search');
    await tester.enterText(_key('assistant-search-input'), '阅读');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(
      repository.calls.any(
        (call) => Uri.parse(call.path).queryParameters['query'] == '阅读',
      ),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_key('assistant-search-input'), findsNothing);
    expect(
      repository.calls.any(
        (call) => call.path == '/conversations/conversation-2/messages',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史悬停置顶及删除准确作用于非当前会话', (WidgetTester tester) async {
    // 非当前会话操作不能改变当前聊天。
    final _DesktopRepository repository = await _pumpDesktop(tester);
    // 悬停前后条目边界不得因操作按钮改变。
    final Rect rowBefore = tester.getRect(
      _key('assistant-conversation-conversation-2'),
    );
    // 鼠标只触发历史项的实际悬停状态。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(800, 400));
    await mouse.moveTo(
      tester.getCenter(_key('assistant-conversation-conversation-2')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(_key('assistant-conversation-conversation-2')),
      rowBefore,
    );
    expect(
      tester.getCenter(_key('assistant-pin-conversation-2')).dy,
      closeTo(tester.getCenter(_key('assistant-delete-conversation-2')).dy, 1),
    );
    await _capture(tester, 'hover');
    await tester.tap(_key('assistant-pin-conversation-2'));
    await tester.pumpAndSettle();
    expect(
      repository.conversations.firstWhere(
        (item) => item['id'] == 'conversation-2',
      )['isPinned'],
      isTrue,
    );
    await mouse.moveTo(
      tester.getCenter(_key('assistant-conversation-conversation-2')),
    );
    await tester.pumpAndSettle();
    await tester.tap(_key('assistant-delete-conversation-2'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OmniButton, '删除'));
    await tester.pumpAndSettle();
    expect(
      repository.calls.any(
        (call) =>
            call.method == 'DELETE' &&
            call.path == '/conversations/conversation-2',
      ),
      isTrue,
    );
    expect(_key('assistant-user-message-user-1'), findsOneWidget);
    expect(
      repository.calls.any(
        (call) => call.path == '/conversations/conversation-2/messages',
      ),
      isFalse,
    );
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索丢弃旧查询迟到响应并支持快捷键选择', (WidgetTester tester) async {
    // 延迟请求验证真实防抖及最新查询边界。
    final _DesktopRepository repository = _DesktopRepository();
    // 较早的查询故意最后完成。
    final Completer<Map<String, dynamic>> oldResponse = Completer();
    // 新查询先完成并保持为最终可见结果。
    final Completer<Map<String, dynamic>> newResponse = Completer();
    repository.delayedSearches['旧查询'] = oldResponse;
    repository.delayedSearches['新查询'] = newResponse;
    await _pumpDesktop(tester, repository: repository);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(_key('assistant-search-input'), findsOneWidget);
    await tester.enterText(_key('assistant-search-input'), '旧查询');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(_key('assistant-search-input'), '新查询');
    await tester.pump(const Duration(milliseconds: 300));
    newResponse.complete({
      'items': [repository.conversations[1]],
      'nextCursor': null,
    });
    await tester.pumpAndSettle();
    oldResponse.complete({
      'items': [repository.conversations[0]],
      'nextCursor': null,
    });
    await tester.pumpAndSettle();
    expect(_key('assistant-search-result-conversation-2'), findsOneWidget);
    expect(_key('assistant-search-result-conversation-3'), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(_key('assistant-search-input'), findsNothing);
    expect(
      repository.calls.any(
        (call) => call.path == '/conversations/conversation-2/messages',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('模型菜单向上展开并完整保存助手全局设置', (WidgetTester tester) async {
    // 模型设置必须保留其它开关和修订号。
    final _DesktopRepository repository = await _pumpDesktop(tester);
    // 菜单必须位于模型入口上方。
    final Rect button = tester.getRect(_key('assistant-model-button'));
    await tester.tap(_key('assistant-model-button'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('选择模型')).bottom, lessThan(button.top));
    await _capture(tester, 'models');
    await tester.tap(find.textContaining('GPT-6 Astra').last);
    await tester.pumpAndSettle();
    expect(repository.calls.singleWhere((call) => call.method == 'PUT').data, {
      'revision': 7,
      'enabled': true,
      'profileId': 'profile-2',
      'memoryReadEnabled': true,
      'memoryWriteEnabled': false,
      'timeZone': 'Asia/Shanghai',
    });
    expect(repository.settings['profileId'], 'profile-2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('模型保存失败保留旧配置并展示可读错误', (WidgetTester tester) async {
    // 写入失败不允许勾选新配置。
    final _DesktopRepository repository = _DesktopRepository()
      ..failSettings = true;
    await _pumpDesktop(tester, repository: repository);
    await tester.tap(_key('assistant-model-button'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('GPT-6 Astra').last);
    await tester.pumpAndSettle();
    expect(repository.settings['profileId'], 'profile-1');
    expect(find.textContaining('模型设置保存失败'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入法组词和 Shift Enter 不发送，普通 Enter 只发送一次', (
    WidgetTester tester,
  ) async {
    // 真正发出的请求数量用于排除错误快捷键处理。
    final _DesktopRepository repository = await _pumpDesktop(tester);
    await tester.tap(_key('assistant-input'));
    await tester.showKeyboard(_key('assistant-input'));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(repository.calls.where((call) => call.method == 'POST'), isEmpty);
    await tester.enterText(_key('assistant-input'), '整理想法');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(repository.calls.where((call) => call.method == 'POST'), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      repository.calls.where(
        (call) => call.method == 'POST' && call.path.endsWith('/messages'),
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('重复搜索游标停止续页后允许从首页重试', (WidgetTester tester) async {
    // 第二页故意返回当前游标，第三次请求代表用户主动重试。
    final _DesktopRepository repository = _DesktopRepository();
    repository.searchPages['分页'] = [
      {
        'items': [repository.conversations[0]],
        'nextCursor': 'page-2',
      },
      {
        'items': [repository.conversations[1]],
        'nextCursor': 'page-2',
      },
      {
        'items': [repository.conversations[2]],
        'nextCursor': null,
      },
    ];
    await _pumpDesktop(tester, repository: repository);
    await tester.tap(_key('assistant-search-button'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('assistant-search-input'), '分页');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('搜索分页异常，请重新搜索。'), findsOneWidget);
    await tester.tap(find.text('重试搜索'));
    await tester.pumpAndSettle();
    expect(_key('assistant-search-result-conversation-1'), findsOneWidget);
    expect(_key('assistant-search-result-conversation-3'), findsNothing);
    // 重试必须去掉无效分页身份，并真正发起第三次请求。
    final List<Uri> searches = repository.calls
        .map((call) => Uri.parse(call.path))
        .where((uri) => uri.queryParameters['query'] == '分页')
        .toList();
    expect(searches, hasLength(3));
    expect(searches.last.queryParameters['cursor'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('模型相同的多个配置通过名称区分', (WidgetTester tester) async {
    // 真实用户可以保存同一模型的多个不同服务配置。
    final _DesktopRepository repository = _DesktopRepository();
    repository.settings['profiles'] = [
      {
        'id': 'profile-1',
        'name': '工作配置',
        'model': 'same-model',
        'hasApiKey': true,
      },
      {
        'id': 'profile-2',
        'name': '个人配置',
        'model': 'same-model',
        'hasApiKey': true,
      },
    ];
    await _pumpDesktop(tester, repository: repository);
    await tester.tap(_key('assistant-model-button'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: _key('assistant-model-profile-1'),
        matching: find.textContaining('工作配置'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _key('assistant-model-profile-2'),
        matching: find.textContaining('个人配置'),
      ),
      findsOneWidget,
    );
    await tester.tap(_key('assistant-model-profile-2'));
    await tester.pumpAndSettle();
    expect(repository.settings['profileId'], 'profile-2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消搜索恢复打开前的编辑焦点', (WidgetTester tester) async {
    await _pumpDesktop(tester);
    await tester.tap(_key('assistant-input'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(_key('assistant-search-input'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      tester.widget<OmniTextField>(_key('assistant-input')).focusNode!.hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('回答待结算时隐藏用时并禁用确认，最终事件恢复二者', (WidgetTester tester) async {
    // 持续事件流重现正文已到达但 finally 尚未完成的时间窗口。
    final _DesktopRepository repository = _DesktopRepository()
      ..eventStream = StreamController<AssistantEvent>();
    repository.activeRun = {
      'id': 'run',
      'status': 'waitingConfirmation',
      'answerMessageId': 'answer-1',
      'timingPending': true,
      'requiresTakeover': false,
      'plan': {
        'id': 'plan',
        'version': 1,
        'previewHash': List<String>.filled(64, 'a').join(),
        'targetCount': 1,
        'preview': {'changes': <Object>[]},
      },
    };
    await _pumpDesktop(tester, repository: repository);
    expect(find.textContaining('用时'), findsNothing);
    expect(_key('assistant-run-actions'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('assistant-answer-answer-1'),
        matching: _key('assistant-run-actions'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<AssistantPlanCard>(find.byType(AssistantPlanCard)).enabled,
      isFalse,
    );
    repository.activeRun = {...repository.activeRun!, 'timingPending': false};
    repository.eventStream!.add(
      AssistantEvent(
        seq: 1,
        type: 'run.updated',
        runId: 'run',
        data: {'run': repository.activeRun!},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('用时'), findsOneWidget);
    expect(
      tester.widget<AssistantPlanCard>(find.byType(AssistantPlanCard)).enabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  // 验证多种窗口和字号组合，折叠布局仍保留必要入口。
  for (final ({Size size, double scale, Brightness brightness}) variant in [
    (size: const Size(1280, 900), scale: 1.0, brightness: Brightness.light),
    (size: const Size(1440, 900), scale: 1.0, brightness: Brightness.dark),
    (size: const Size(640, 480), scale: 2.0, brightness: Brightness.light),
    (size: const Size(320, 640), scale: 2.0, brightness: Brightness.dark),
  ]) {
    testWidgets(
      'Windows ${variant.size} 字号${variant.scale} ${variant.brightness.name} 布局可用',
      (WidgetTester tester) async {
        // 长名称与长列表同时覆盖模型入口省略和菜单滚动。
        final _DesktopRepository repository = _DesktopRepository();
        repository.settings['profiles'] = List<Map<String, dynamic>>.generate(
          24,
          (int index) => {
            'id': 'profile-${index + 1}',
            'name': '配置 ${index + 1}',
            'model': '用于长名称布局验证的已保存模型 ${index + 1}',
            'hasApiKey': true,
          },
        );
        await _pumpDesktop(
          tester,
          size: variant.size,
          textScale: variant.scale,
          brightness: variant.brightness,
          repository: repository,
        );
        expect(_key('assistant-input'), findsOneWidget);
        expect(
          tester.getSize(_key('assistant-send-surface')),
          const Size(36, 36),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(_key('assistant-search-button'));
        await tester.pumpAndSettle();
        expect(_key('assistant-search-input'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(_key('assistant-search-input'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(_key('assistant-model-button'));
        await tester.pumpAndSettle();
        expect(_key('assistant-model-menu'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          _key('assistant-model-profile-24'),
          200,
          scrollable: find.descendant(
            of: _key('assistant-model-menu'),
            matching: find.byType(Scrollable),
          ),
        );
        expect(
          _key('assistant-model-profile-24').hitTestable(),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      },
    );
  }
}
