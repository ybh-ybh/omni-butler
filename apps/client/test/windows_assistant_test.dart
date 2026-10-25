import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
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
import 'package:omni_butler/core/attachments/windows_clipboard_images.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_page.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_cards.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_markdown.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_image_preview.dart';
import 'package:omni_butler/shared/layout/responsive_shell.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:powersync/powersync.dart' hide Table;
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
  /// 附件能力默认关闭，既有纯文本 golden 保持原样。
  bool attachmentsEnabled = false;

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

  /// 延迟模型保存，用于核对整个在途过程的输入区状态。
  Completer<void>? delayedSettingsSave;

  /// 延迟保存后的设置读取，覆盖后台刷新阶段。
  Completer<void>? delayedSettingsRead;

  /// 可控制搜索响应顺序。
  final Map<String, Completer<Map<String, dynamic>>> delayedSearches = {};

  /// 分页测试按请求顺序返回真实接口形状。
  final Map<String, List<Map<String, dynamic>>> searchPages = {};

  /// 可切换结算状态的运行快照。
  Map<String, dynamic>? activeRun;

  /// 可替换用户正文以验证短气泡和长消息换行。
  String userContent = '帮我整理最近的想法，找出值得继续推进的事情。';

  /// 本条历史用户消息的附件夹具。
  List<Map<String, dynamic>> userAttachments = <Map<String, dynamic>>[];

  /// 真实图片字节用于证明缩略图已解码，而非只有图片图标。
  Uint8List? imageBytes;

  /// 图片只走当前认证仓储，测试不访问外部网络。
  @override
  Future<Uint8List> attachmentBytes(String id) async =>
      imageBytes ?? (throw const ApiFailure('合成附件不可用'));

  /// 可替换助手 Markdown 与来源卡，验证真实消息布局。
  String answerContent =
      '最近的记录主要围绕学习、项目与生活安排。\n\n可以先完成本周的阅读计划，再集中整理项目中尚未解决的问题。';

  /// 引用属于本条回答，折叠不能影响其他类型的卡片。
  List<Map<String, dynamic>> answerCards = <Map<String, dynamic>>[];

  /// 历史回答保留服务端公开的执行步骤。
  List<Map<String, dynamic>> executionSteps = [];

  /// 可选真实消息时间；旧缓存缺失时间时不允许视图补造。
  String? userCreatedAt;

  /// 挂起发送响应以验证消息提交前的即时秒表。
  Completer<Map<String, dynamic>>? delayedSend;

  /// 继续消息接收后进入新的服务端运行，用于验证主按钮再次切回停止。
  Map<String, dynamic>? nextSentRun;

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
    if (path == '/attachments/capabilities') {
      return <String, dynamic>{
        'enabled': attachmentsEnabled,
        'maxFiles': 5,
        'maxFileBytes': 20971520,
        'maxTotalBytes': 52428800,
        'extensions': <String>['png', 'txt', 'pdf'],
      };
    }
    // 请求参数用 URI 解析，确保查询与游标能共存。
    final Uri uri = Uri.parse(path);
    if (method == 'POST' &&
        uri.path.startsWith('/runs/') &&
        uri.path.endsWith('/stop')) {
      activeRun = <String, dynamic>{...?(activeRun), 'status': 'cancelled'};
      return activeRun!;
    }
    if (uri.path == '/settings') {
      if (method == 'PUT') {
        await delayedSettingsSave?.future;
        if (failSettings) throw const ApiFailure('模型设置保存失败，请重试');
        settings = {
          ...settings,
          ...data as Map<String, dynamic>,
          'revision': 8,
        };
      } else {
        await delayedSettingsRead?.future;
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
      if (method == 'POST') {
        if (nextSentRun != null) {
          activeRun = nextSentRun;
          return activeRun!;
        }
        return delayedSend?.future ??
            Future.value({'id': 'run', 'status': 'succeeded'});
      }
      return {
        'items': [
          {
            'id': 'user-1',
            'role': 'user',
            'content': userContent,
            'attachments': userAttachments,
            if (userCreatedAt != null) 'createdAt': userCreatedAt,
            'cards': <Object>[],
          },
          {
            'id': 'answer-1',
            'role': 'assistant',
            'content': answerContent,
            'elapsedMs': 46000,
            'executionSteps': executionSteps,
            'cards': answerCards,
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
  EdgeInsets safePadding = EdgeInsets.zero,
  _DesktopRepository? repository,
  List<Map<String, dynamic>> draftAttachments = const <Map<String, dynamic>>[],
  WindowsClipboardImages? clipboard,
}) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('desktop_drop'),
        (MethodCall call) async =>
            call.method == 'initializeView' ? true : null,
      );
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
    {'conversationId': 'conversation-1', 'attachments': draftAttachments},
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        authControllerProvider.overrideWith(_DesktopIdentity.new),
        assistantRepositoryProvider.overrideWithValue(fixed),
        assistantCacheProvider.overrideWithValue(cache),
        if (clipboard != null)
          windowsClipboardImagesProvider.overrideWithValue(clipboard),
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
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: safePadding,
          ),
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

/// 验证键盘路由时绝不读取真实系统剪贴板。
class _TextOnlyClipboard extends WindowsClipboardImages {
  /// 记录是否错误进入图片读取。
  int reads = 0;

  /// 当前剪贴板只有文本，交给 Flutter 原有粘贴动作。
  @override
  bool get hasImage => false;

  /// 图片读取不应在文本粘贴场景触发。
  @override
  Future<Uint8List?> readPng() async {
    reads++;
    return null;
  }
}

/// 读取真实渲染背景像素，防止墨水被不透明侧栏遮住而属性断言仍通过。
Future<Color> _surfacePixel(WidgetTester tester, Offset point) async {
  // 截图覆盖整个导航器，传入坐标先转换到截图局部空间。
  final RenderRepaintBoundary boundary = tester.renderObject(
    _key('windows-assistant-frame'),
  );
  // 避开文字与圆角的目标背景点。
  final Offset local = boundary.globalToLocal(point);
  return (await tester.runAsync(() async {
    // 使用原始像素尺寸避免缩放干扰颜色。
    final ui.Image image = await boundary.toImage();
    try {
      // RGBA 每个通道固定占一字节。
      final ByteData bytes = (await image.toByteData())!;
      // 目标点在像素缓冲中的偏移。
      final int offset =
          (local.dy.floor() * image.width + local.dx.floor()) * 4;
      return Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  }))!;
}

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
    expect(composer.center.dx, closeTo((sidebar.right + 1440) / 2, 1));
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

  testWidgets('Windows 回答渲染真实表格且相关记录默认折叠、点击展开', (WidgetTester tester) async {
    // 与截图一致的 Markdown 表格和六条真实形状引用。
    final _DesktopRepository repository = _DesktopRepository()
      ..answerContent = '按“重要且紧急”筛选，**6 条未完成任务**。\n\n## 未完成任务\n\n|任务|计划日期|进度|\n|---|---|---|\n|飞书学习|2026-10-05|未开始|\n|学习源码|2026-10-07|4/12 步|\n|准备简历|2026-10-07|未开始|\n|学习 Agent|2026-10-09|未开始|\n|填写简历|2026-10-09|未开始|\n|管理技能|2026-10-12|未开始|'
      ..answerCards = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'references',
          'referencesTruncated': false,
          'entityRefs': <Object>[
            for (int index = 0; index < 6; index++)
              <String, dynamic>{
                'id': 'record-$index',
                'module': 'todos',
                'label': '任务${index + 1}',
              },
          ],
        },
      ];
    await _pumpDesktop(tester, repository: repository);
    expect(find.byType(AssistantMarkdown), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('学习源码', findRichText: true), findsOneWidget);
    expect(find.text('查看任务1'), findsNothing);
    expect(find.text('相关记录'), findsOneWidget);
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'markdown_collapsed');
    }
    await tester.ensureVisible(find.text('相关记录'));
    await tester.tap(find.text('相关记录'));
    await tester.pumpAndSettle();
    expect(find.text('查看任务6'), findsOneWidget);
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'markdown_expanded');
    }
    await tester.tap(find.text('相关记录'));
    await tester.pumpAndSettle();
    expect(find.text('查看任务1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('超宽窗口中的对话和输入框以聊天工作区为中心', (WidgetTester tester) async {
    await _pumpDesktop(tester, size: const Size(1920, 1080));
    // 侧栏右侧到窗口右边缘才是对话的可用工作区。
    final Rect sidebar = tester.getRect(_key('assistant-windows-sidebar'));
    // 输入框与正文共享最大宽度和中心线。
    final Rect composer = tester.getRect(_key('assistant-windows-composer'));
    // 助手正文允许左对齐，但整条内容列必须居中。
    final Rect answer = tester.getRect(_key('assistant-answer-answer-1'));
    expect(composer.width, 880);
    expect(composer.center.dx, closeTo((sidebar.right + 1920) / 2, 1));
    expect(answer.center.dx, closeTo(composer.center.dx, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户短消息按文字收缩且正文和输入区使用紧凑字号', (WidgetTester tester) async {
    // 两个汉字不应占满整条最大宽度。
    final _DesktopRepository repository = _DesktopRepository()
      ..userContent = '你好';
    await _pumpDesktop(tester, repository: repository);
    // 实际灰色气泡边界。
    final Rect bubble = tester.getRect(_key('assistant-user-message-user-1'));
    // 输入框界定右侧对齐线。
    final Rect composer = tester.getRect(_key('assistant-windows-composer'));
    // 可选择正文的尺寸同时验证左右内边距。
    final Finder text = find.descendant(
      of: _key('assistant-user-message-user-1'),
      matching: find.byType(SelectableText),
    );
    expect(bubble.width, lessThan(120));
    expect(bubble.width, closeTo(tester.getSize(text).width + 24, 1));
    expect(bubble.height, closeTo(tester.getSize(text).height + 16, 1));
    expect(bubble.right, closeTo(composer.right, 1));
    expect(tester.widget<SelectableText>(text).textSpan?.style?.fontSize, 14);
    expect(
      tester.widget<OmniTextField>(_key('assistant-input')).style?.fontSize,
      14,
    );
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'short_message');
    }
    await tester.enterText(_key('assistant-input'), '继续聊天');
    expect(find.text('继续聊天'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户消息整行悬停显示时间及复制，离开隐藏且布局不跳动', (WidgetTester tester) async {
    // 复制应保留原始Markdown和换行，不混入时间、角色或工具元数据。
    const String content = '**你好**\n第二行';
    final _DesktopRepository repository = _DesktopRepository()
      ..userContent = content
      ..userCreatedAt = '2026-10-24T13:36:00';
    // 剪贴板写入留在测试通道，不修改用户真实剪贴板。
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _pumpDesktop(tester, repository: repository);
    // 完整消息行包含气泡左侧空白，不能把热区缩成气泡宽度。
    final Rect row = tester.getRect(_key('assistant-user-row-user-1'));
    final Rect bubble = tester.getRect(_key('assistant-user-message-user-1'));
    final Rect answer = tester.getRect(_key('assistant-answer-answer-1'));
    expect(row.width, tester.getSize(_key('assistant-windows-composer')).width);
    expect(
      tester
          .widget<AnimatedOpacity>(_key('assistant-message-actions-user-1'))
          .opacity,
      0,
    );
    expect(_key('assistant-copy-message-user-1').hitTestable(), findsNothing);
    // 光标位于该行的左边空白处，实际远离右侧消息气泡。
    final Offset blank = Offset(row.left + 4, bubble.center.dy);
    expect(blank.dx, lessThan(bubble.left));
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(800, 500));
    await mouse.moveTo(blank);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedOpacity>(_key('assistant-message-actions-user-1'))
          .opacity,
      1,
    );
    expect(find.text('13:36'), findsOneWidget);
    expect(find.byTooltip('2026-10-24 13:36:00'), findsOneWidget);
    expect(tester.getRect(_key('assistant-user-message-user-1')), bubble);
    expect(tester.getRect(_key('assistant-answer-answer-1')), answer);
    expect(
      tester.getRect(_key('assistant-copy-message-user-1')).right,
      closeTo(bubble.right, 1),
    );
    expect(
      tester.getRect(_key('assistant-copy-message-user-1')).top,
      greaterThan(bubble.bottom),
    );
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'user_message_hover');
    }
    await mouse.moveTo(const Offset(800, 500));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedOpacity>(_key('assistant-message-actions-user-1'))
          .opacity,
      0,
    );
    expect(tester.getRect(_key('assistant-answer-answer-1')), answer);
    await mouse.moveTo(blank);
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(_key('assistant-copy-message-user-1')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedOpacity>(_key('assistant-message-actions-user-1'))
          .opacity,
      1,
    );
    await tester.tap(_key('assistant-copy-message-user-1'));
    await tester.pumpAndSettle();
    expect(copied, content);
    expect(find.byTooltip('已复制'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final String? createdAt in <String?>[null, 'invalid-date']) {
    testWidgets('旧消息时间缺失或无效时不补造日期 $createdAt', (WidgetTester tester) async {
      // 不依赖服务器列表或当前时间补出一条不存在的发送事实。
      await _pumpDesktop(
        tester,
        repository: _DesktopRepository()..userCreatedAt = createdAt,
      );
      // 键盘焦点进入行时也能发现复制操作。
      Focus.of(tester.element(_key('assistant-user-message-user-1')))
          .requestFocus();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AnimatedOpacity>(_key('assistant-message-actions-user-1'))
            .opacity,
        1,
      );
      expect(_key('assistant-message-date-user-1'), findsNothing);
      expect(_key('assistant-copy-message-user-1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('用户消息工具栏在320宽双倍字号与深色下保持可访问', (WidgetTester tester) async {
    // 窄屏中日期和复制仍占预留位置，不侵入消息气泡。
    await _pumpDesktop(
      tester,
      size: const Size(320, 900),
      textScale: 2,
      brightness: Brightness.dark,
      repository: _DesktopRepository()
        ..userContent = '你好'
        ..userCreatedAt = '2026-10-24T13:36:00',
    );
    // 页面初始跟随最新回答，先把较早的用户行滚回可见区域。
    await tester.ensureVisible(_key('assistant-user-row-user-1'));
    await tester.pumpAndSettle();
    final Rect bubble = tester.getRect(_key('assistant-user-message-user-1'));
    final Rect answer = tester.getRect(_key('assistant-answer-answer-1'));
    final Rect row = tester.getRect(_key('assistant-user-row-user-1'));
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(10, 500));
    await mouse.moveTo(Offset(row.left + 3, bubble.center.dy));
    await tester.pumpAndSettle();
    expect(_key('assistant-copy-message-user-1').hitTestable(), findsOneWidget);
    expect(
      tester.getRect(_key('assistant-copy-message-user-1')).right,
      lessThanOrEqualTo(row.right),
    );
    expect(
      tester.getRect(_key('assistant-copy-message-user-1')).top,
      greaterThanOrEqualTo(bubble.bottom),
    );
    expect(tester.getRect(_key('assistant-answer-answer-1')), answer);
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'user_message_hover_narrow');
    }
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户长消息在最大宽度内换行且保持右对齐', (WidgetTester tester) async {
    // 长段落确保实际触发换行，而不是仅比较约束属性。
    final _DesktopRepository repository = _DesktopRepository()
      ..userContent = List<String>.filled(12, '这是一条需要自动换行的长消息。').join();
    await _pumpDesktop(tester, repository: repository);
    // 长消息的真实布局边界。
    final Rect bubble = tester.getRect(_key('assistant-user-message-user-1'));
    // 最大宽度由可读正文列决定。
    final Rect composer = tester.getRect(_key('assistant-windows-composer'));
    expect(bubble.width, lessThanOrEqualTo(composer.width * .72 + 1));
    expect(bubble.width, greaterThan(composer.width * .6));
    expect(bubble.height, greaterThan(14 * 1.7 * 2 + 16));
    expect(bubble.right, closeTo(composer.right, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('新聊天点击仅显示空白输入，反复点击不新增服务器聊天', (WidgetTester tester) async {
    // 真正点击侧栏入口，验证按钮没有绕过控制器的延迟创建语义。
    final _DesktopRepository repository = await _pumpDesktop(tester);
    await tester.tap(_key('assistant-new-chat'));
    await tester.pumpAndSettle();
    expect(_key('assistant-user-message-user-1'), findsNothing);
    expect(_key('assistant-input'), findsOneWidget);
    await tester.tap(_key('assistant-new-chat'));
    await tester.pumpAndSettle();
    expect(
      repository.calls.where(
        (call) =>
            call.method == 'POST' &&
            Uri.parse(call.path).path == '/conversations',
      ),
      isEmpty,
    );
    expect(
      repository.conversations.where((item) => item['id'] == 'new-chat'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  for (final Brightness brightness in Brightness.values) {
    testWidgets('聊天选中和悬停背景像素一致 ${brightness.name}', (
      WidgetTester tester,
    ) async {
      // 真实页面与鼠标事件覆盖透明墨水叠加，不能只比较配置中的颜色。
      final _DesktopRepository repository = await _pumpDesktop(
        tester,
        brightness: brightness,
      );
      // 标题与操作图标之间的空白位置用于采样同一背景像素。
      final Rect row = tester.getRect(
        _key('assistant-conversation-conversation-2'),
      );
      final Offset sample = Offset(row.right - 76, row.center.dy);
      // 未选中时的背景必须与悬停状态不同。
      final Color idle = await _surfacePixel(tester, sample);
      // 同一指针依次悬停、点击、离开，覆盖选中后再次悬停的叠色。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(800, 400));
      await mouse.moveTo(sample);
      await tester.pumpAndSettle();
      final Color hovered = await _surfacePixel(tester, sample);
      expect(hovered, isNot(idle));
      await tester.tapAt(sample);
      await tester.pumpAndSettle();
      expect(
        repository.calls.any(
          (call) => call.path == '/conversations/conversation-2/messages',
        ),
        isTrue,
      );
      expect(await _surfacePixel(tester, sample), hovered);
      await mouse.moveTo(const Offset(800, 400));
      await tester.pumpAndSettle();
      expect(await _surfacePixel(tester, sample), hovered);
      await mouse.moveTo(sample);
      await tester.pumpAndSettle();
      expect(await _surfacePixel(tester, sample), hovered);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('新聊天与历史行等高等字号且鼠标悬停实际显示灰底', (WidgetTester tester) async {
    await _pumpDesktop(tester);
    // 取会话表面而非含行间距的外层 Padding。
    final Finder rowSurface = find
        .descendant(
          of: _key('assistant-conversation-conversation-2'),
          matching: find.byType(Material),
        )
        .first;
    // 新聊天的墨水热区与历史表面共用紧凑尺寸。
    final Rect newChat = tester.getRect(_key('assistant-new-chat'));
    expect(newChat.height, 34);
    expect(tester.getSize(rowSurface).height, newChat.height);
    expect(tester.widget<Text>(find.text('新聊天')).style!.fontSize, 14);
    expect(tester.widget<Text>(find.text('本周回顾')).style!.fontSize, 14);
    // 文本右侧的空白背景不受字形或按压缩放干扰。
    final Offset sample = Offset(newChat.right - 24, newChat.center.dy);
    // 悬停前的实际背景色。
    final Color before = await _surfacePixel(tester, sample);
    // 使用真正鼠标事件触发 InkWell 墨水。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(800, 400));
    await mouse.moveTo(newChat.center);
    await tester.pumpAndSettle();
    // 当前主题下与会话悬停一致的灰色表面。
    final AssistantWindowsPalette palette = AssistantWindowsPalette.of(
      tester.element(_key('assistant-new-chat')),
    );
    expect(
      (await _surfacePixel(tester, sample)).toARGB32(),
      palette.soft.toARGB32(),
    );
    expect(await _surfacePixel(tester, sample), isNot(before));
    expect(tester.getRect(_key('assistant-new-chat')), newChat);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(await _surfacePixel(tester, sample), before);
    expect(tester.takeException(), isNull);
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
    expect(
      tester.getRect(_key('assistant-conversation-conversation-2')).top,
      lessThan(rowBefore.top),
    );
    await mouse.moveTo(
      tester.getCenter(_key('assistant-conversation-conversation-2')),
    );
    await tester.pumpAndSettle();
    await tester.tap(_key('assistant-pin-conversation-2'));
    await tester.pumpAndSettle();
    expect(
      repository.conversations.firstWhere(
        (item) => item['id'] == 'conversation-2',
      )['isPinned'],
      isFalse,
    );
    expect(
      tester.getRect(_key('assistant-conversation-conversation-2')).top,
      rowBefore.top,
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
    // 必须检查整个面板，标题在上方不能证明菜单未盖住入口。
    final Rect menu = tester.getRect(_key('assistant-model-menu'));
    expect(menu.bottom, closeTo(button.top - 8, 1));
    expect(menu.center.dx, closeTo(button.center.dx, 1));
    expect(tester.getSize(_key('assistant-model-profile-1')).height, 32);
    expect(tester.widget<Text>(find.text('GPT-6 Astra')).style!.fontSize, 14);
    expect(find.byIcon(Icons.bolt), findsNothing);
    // 默认透明、悬停显色必须透传到原生按钮。
    final TextButton modelButton = tester.widget(
      find.descendant(
        of: _key('assistant-model-button'),
        matching: find.byType(TextButton),
      ),
    );
    expect(modelButton.style!.backgroundColor!.resolve({}), Colors.transparent);
    expect(
      modelButton.style!.backgroundColor!.resolve({WidgetState.hovered}),
      isNot(Colors.transparent),
    );
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

  testWidgets('带安全区的窗口中整个模型菜单仍位于入口上方', (WidgetTester tester) async {
    await _pumpDesktop(
      tester,
      safePadding: const EdgeInsets.fromLTRB(12, 36, 12, 16),
    );
    // 对照打开前按钮的全局边界，避免混淆浮层局部坐标。
    final Rect button = tester.getRect(_key('assistant-model-button'));
    await tester.tap(_key('assistant-model-button'));
    await tester.pumpAndSettle();
    // 安全区不得在菜单实际位置上重复叠加。
    final Rect menu = tester.getRect(_key('assistant-model-menu'));
    expect(menu.bottom, closeTo(button.top - 8, 1));
    expect(menu.top, greaterThanOrEqualTo(48));
    expect(menu.right, lessThanOrEqualTo(1440 - 24));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
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

  for (final bool failSave in <bool>[false, true]) {
    testWidgets('模型切换${failSave ? '失败' : '成功'}时不显示进度条且附件入口保持稳定', (
      WidgetTester tester,
    ) async {
      // 附件能力独立于模型；请求延迟只在初次页面加载完成后启用。
      final _DesktopRepository repository = _DesktopRepository()
        ..attachmentsEnabled = true;
      await _pumpDesktop(tester, repository: repository);
      await tester.enterText(_key('assistant-input'), '切换完成后再发送');
      await tester.pump();
      repository
        ..failSettings = failSave
        ..delayedSettingsSave = Completer<void>()
        ..delayedSettingsRead = Completer<void>();
      // 同一个元素、可用状态和位置共同保证入口没有消失或禁用闪动。
      final Element attachment = tester.element(
        _key('assistant-attach-button'),
      );
      // 输入框完整边界用于检查顶部进度条造成的布局跳动。
      final Rect composer = tester.getRect(_key('assistant-windows-composer'));

      // 保存中和刷新中均保留原入口，发送仍由模型切换门禁控制。
      void expectStableComposer() {
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          tester.element(_key('assistant-attach-button')),
          same(attachment),
        );
        expect(
          tester
              .widget<OmniIconButton>(_key('assistant-attach-button'))
              .onPressed,
          isNotNull,
        );
        expect(tester.getRect(_key('assistant-windows-composer')), composer);
      }

      await tester.tap(_key('assistant-model-button'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('GPT-6 Astra').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expectStableComposer();
      expect(
        tester.widget<OmniInkWell>(_key('assistant-send-button')).onTap,
        isNull,
      );
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        await _capture(
          tester,
          'model_switch_${failSave ? 'failure' : 'success'}_saving',
        );
      }
      repository.delayedSettingsSave!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        repository.calls.where(
          (call) => call.method == 'GET' && call.path == '/settings',
        ),
        hasLength(2),
      );
      // 错误提示会占据状态区，但不应改变输入框自身或附件状态。
      expectStableComposer();
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        await _capture(
          tester,
          'model_switch_${failSave ? 'failure' : 'success'}_refreshing',
        );
      }
      expect(
        tester.widget<OmniInkWell>(_key('assistant-send-button')).onTap,
        isNull,
      );
      repository.delayedSettingsRead!.complete();
      await tester.pumpAndSettle();
      expectStableComposer();
      expect(
        tester.widget<OmniInkWell>(_key('assistant-send-button')).onTap,
        isNotNull,
      );
      expect(
        repository.settings['profileId'],
        failSave ? 'profile-1' : 'profile-2',
      );
      expect(tester.takeException(), isNull);
    });
  }

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

  testWidgets('运行尚未结束时正文逐段显示，保留先前片段且没有断流提示', (WidgetTester tester) async {
    // 任务保持运行，测试只投递正文片段，不投递完成事件。
    final _DesktopRepository repository = _DesktopRepository()
      ..activeRun = {
        'id': 'run',
        'status': 'running',
        'answerMessageId': 'stream-answer',
        'timingPending': true,
      }
      ..eventStream = StreamController<AssistantEvent>();
    await _pumpDesktop(tester, repository: repository);
    repository.eventStream!.add(
      const AssistantEvent(
        seq: 1,
        type: 'message.delta',
        runId: 'run',
        data: {'messageId': 'stream-answer', 'text': '第一段中文'},
      ),
    );
    await tester.pump();
    await tester.pump();
    // 读取实际呈现在 Windows 页面的可选择正文。
    final Finder body = find.descendant(
      of: _key('assistant-answer-stream-answer'),
      matching: find.byType(AssistantMarkdown),
    );
    expect(tester.widget<AssistantMarkdown>(body).source, '第一段中文');
    expect(repository.eventStream!.isClosed, isFalse);
    repository.eventStream!.add(
      const AssistantEvent(
        seq: 2,
        type: 'message.delta',
        runId: 'run',
        data: {'messageId': 'stream-answer', 'text': '，第二段'},
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.widget<AssistantMarkdown>(body).source, '第一段中文，第二段');
    expect(repository.activeRun!['status'], 'running');
    expect(find.textContaining('连接中断'), findsNothing);
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

  testWidgets('停止位于输入区，空输入开始继续，有新正文则显示发送', (WidgetTester tester) async {
    // 服务端运行、停止和下一条继续均通过真实聊天控制器处理。
    final _DesktopRepository repository = _DesktopRepository()
      ..eventStream = StreamController<AssistantEvent>.broadcast()
      ..activeRun = <String, dynamic>{
        'id': 'run',
        'answerMessageId': 'answer-1',
        'status': 'running',
        'elapsedMs': 0,
      }
      ..nextSentRun = <String, dynamic>{
        'id': 'continued-run',
        'answerMessageId': 'continued-answer',
        'status': 'running',
        'elapsedMs': 0,
      };
    await _pumpDesktop(tester, repository: repository);
    expect(
      find.descendant(
        of: _key('assistant-windows-composer'),
        matching: _key('assistant-stop-button'),
      ),
      findsOneWidget,
    );
    expect(find.text('停止'), findsNothing);
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'composer_stop');
    }
    await tester.tap(_key('assistant-stop-button'));
    await tester.pumpAndSettle();
    expect(
      repository.calls.where(
        (call) => call.method == 'POST' && call.path == '/runs/run/stop',
      ),
      hasLength(1),
    );
    expect(_key('assistant-continue-button'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    await tester.enterText(_key('assistant-input'), '先回答新的问题');
    await tester.pump();
    expect(_key('assistant-continue-button'), findsNothing);
    expect(_key('assistant-send-button'), findsOneWidget);
    await tester.enterText(_key('assistant-input'), '');
    await tester.pump();
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'composer_continue');
    }
    await tester.tap(_key('assistant-continue-button'));
    await tester.pumpAndSettle();
    expect(
      repository.calls
          .where(
            (call) =>
                call.method == 'POST' &&
                call.path == '/conversations/conversation-1/messages',
          )
          .single
          .data,
      containsPair('content', '继续'),
    );
    expect(
      repository.calls.any((call) => call.path.endsWith('/retry')),
      isFalse,
    );
    expect(_key('assistant-stop-button'), findsOneWidget);
    expect(_key('assistant-continue-button'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('发送后立即显示计时，提交尚未返回时秒数持续增长', (WidgetTester tester) async {
    // 延迟仅作用于合成发送接口，不能把设置保存等busy状态误当成计时。
    final _DesktopRepository repository = _DesktopRepository()
      ..delayedSend = Completer<Map<String, dynamic>>();
    await _pumpDesktop(tester, repository: repository);
    expect(_key('assistant-progress-sending'), findsNothing);
    await tester.enterText(_key('assistant-input'), '帮我查看待办');
    await tester.pump();
    expect(_key('assistant-progress-sending'), findsNothing);
    await tester.tap(_key('assistant-send-button'));
    await tester.pump();
    expect(_key('assistant-progress-sending'), findsOneWidget);
    // 计时开始同帧，输入正文已在消息行显示，输入框不再残留。
    expect(
      tester.widget<OmniTextField>(_key('assistant-input')).controller!.text,
      isEmpty,
    );
    expect(find.text('帮我查看待办', findRichText: true), findsOneWidget);
    expect(
      find.descendant(
        of: _key('assistant-progress-sending'),
        matching: find.text('用时 0秒'),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.descendant(
        of: _key('assistant-progress-sending'),
        matching: find.text('用时 3秒'),
      ),
      findsOneWidget,
    );
    repository.delayedSend!.complete({'id': 'run', 'status': 'succeeded'});
    await tester.pumpAndSettle();
    expect(_key('assistant-progress-sending'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final double width in <double>[1200, 380]) {
    testWidgets('历史附件图片横排文件竖排并在气泡上方，宽度$width', (WidgetTester tester) async {
      // 使用真实已存在的图片素材，检验解码后的像素而非占位图标。
      final _DesktopRepository repository = _DesktopRepository()
        ..imageBytes = await tester.runAsync(
          () => File('assets/icon/app_icon.png').readAsBytes(),
        )
        ..userContent = '请概括附件'
        ..userAttachments = <Map<String, dynamic>>[
          for (final String id in <String>['one', 'two'])
            <String, dynamic>{'id': id, 'kind': 'image', 'name': '$id.png'},
          for (final String id in <String>['doc-one', 'doc-two'])
            <String, dynamic>{
              'id': id,
              'kind': 'document',
              'name': '$id-项目说明与会议纪要.pdf',
            },
        ];
      await _pumpDesktop(
        tester,
        repository: repository,
        size: Size(width, 1000),
        textScale: width < 400 ? 2 : 1,
      );
      // 图像解码在真实事件循环进行，等待完成后再验证布局。
      final Finder thumbnails = find.descendant(
        of: _key('assistant-history-images'),
        matching: find.byType(RawImage),
      );
      for (int attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (tester
                .widgetList<RawImage>(thumbnails)
                .where((image) => image.image != null)
                .length >=
            2) {
          break;
        }
      }
      // 两张图片处于同一水平轨道，窄屏横向滚动而不纵向换行。
      final Rect first = tester.getRect(_key('history-attachment-one'));
      final Rect second = tester.getRect(_key('history-attachment-two'));
      final Rect document = tester.getRect(_key('history-attachment-doc-one'));
      final Rect nextDocument = tester.getRect(
        _key('history-attachment-doc-two'),
      );
      final Rect bubble = tester.getRect(_key('assistant-user-message-user-1'));
      expect(first.top, second.top);
      expect(second.left, greaterThan(first.right));
      expect(document.top, greaterThan(first.bottom));
      expect(nextDocument.top, greaterThan(document.top));
      expect(bubble.top, greaterThanOrEqualTo(nextDocument.bottom));
      expect(
        tester
            .widgetList<RawImage>(thumbnails)
            .where((image) => image.image != null),
        hasLength(2),
      );
      // AI 正文与输入框字号一致，行高比原先更紧凑。
      final AssistantMarkdown answer = tester.widget<AssistantMarkdown>(
        find.byType(AssistantMarkdown),
      );
      final OmniTextField input = tester.widget<OmniTextField>(
        _key('assistant-input'),
      );
      expect(answer.style!.fontSize, input.style!.fontSize);
      expect(answer.style!.height, 1.35);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        await tester.ensureVisible(_key('assistant-history-images'));
        await tester.pumpAndSettle();
        await _capture(tester, 'message_attachments_${width.toInt()}');
      }
      // 从真实消息入口打开原图，预览不能再包含标题栏卡片。
      await tester.ensureVisible(_key('assistant-history-images'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(_key('history-attachment-two'));
      await tester.pumpAndSettle();
      await tester.tap(_key('history-attachment-two'));
      await tester.pumpAndSettle();
      // 原图与缩略图解码尺寸不同，等待原图真实像素就绪再测试点击区域。
      final Finder previewPixels = find.descendant(
        of: _key('assistant-image-preview-image'),
        matching: find.byType(RawImage),
      );
      for (
        int attempt = 0;
        attempt < 30 && tester.widget<RawImage>(previewPixels).image == null;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(tester.widget<RawImage>(previewPixels).image, isNotNull);
      expect(find.byType(AssistantImagePreview), findsOneWidget);
      expect(find.byType(OmniDialogScaffold), findsNothing);
      expect(find.text('two.png'), findsNothing);
      // 关闭操作固定在窗口右上角，图片点击不应被当作空白关闭。
      final Rect closeButton = tester.getRect(
        _key('assistant-image-preview-close'),
      );
      expect(closeButton.right, closeTo(width - 16, 1));
      expect(closeButton.top, closeTo(16, 1));
      expect(closeButton.size, const Size.square(36));
      // 边缘像素也必须随悬停变暗，圆形之外不能染色。
      final Offset rim = closeButton.center + const Offset(15, 0);
      // 圆外角点用于核对遮罩形状。
      final Offset corner = closeButton.topLeft + const Offset(1, 1);
      // 保存悬停前的实际绘制颜色。
      final Color idleRim = await _surfacePixel(tester, rim);
      final Color idleCorner = await _surfacePixel(tester, corner);
      // 使用真实鼠标事件，而非仅断言样式配置。
      final TestGesture hover = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await hover.addPointer(location: Offset.zero);
      await hover.moveTo(closeButton.center);
      await tester.pumpAndSettle();
      expect(await _surfacePixel(tester, rim), isNot(idleRim));
      expect(await _surfacePixel(tester, corner), idleCorner);
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        await _capture(tester, 'image_preview_hover_${width.toInt()}');
      }
      await hover.removePointer();
      await tester.pumpAndSettle();
      // 圆形表面实际裁切按钮，悬停和点击反馈不能溢出圆形边界。
      expect(
        tester
            .widgetList<Material>(
              find.ancestor(
                of: _key('assistant-image-preview-close'),
                matching: find.byType(Material),
              ),
            )
            .any(
              (surface) =>
                  surface.shape is CircleBorder &&
                  surface.clipBehavior == Clip.antiAlias,
            ),
        isTrue,
      );
      await tester.tap(_key('assistant-image-preview-image'));
      await tester.pumpAndSettle();
      expect(find.byType(AssistantImagePreview), findsOneWidget);
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        await _capture(tester, 'image_preview_${width.toInt()}');
      }
      await tester.tap(_key('assistant-image-preview-close'));
      await tester.pumpAndSettle();
      expect(find.byType(AssistantImagePreview), findsNothing);
      // 图片旁的透明留白也应关闭，而不是仅最外圈能点击。
      await tester.tap(_key('history-attachment-two'));
      await tester.pumpAndSettle();
      final Rect imageBounds = tester.getRect(
        _key('assistant-image-preview-image'),
      );
      await tester.tapAt(Offset(imageBounds.left - 8, imageBounds.center.dy));
      await tester.pumpAndSettle();
      expect(find.byType(AssistantImagePreview), findsNothing);
      // 延续现有弹层的 Escape 键关闭行为。
      await tester.tap(_key('history-attachment-two'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AssistantImagePreview), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('带附件发送时输入区清空，确定拒绝后原位恢复正文和附件', (WidgetTester tester) async {
    // 挂起消息回执，观察实际页面中的同帧消息与计时。
    final _DesktopRepository repository = _DesktopRepository()
      ..attachmentsEnabled = true
      ..delayedSend = Completer<Map<String, dynamic>>();
    await _pumpDesktop(
      tester,
      repository: repository,
      draftAttachments: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'moving-document',
          'name': '待发送文件.txt',
          'kind': 'document',
          'status': 'ready',
          'requiresVision': false,
          'size': 100,
        },
      ],
    );
    await tester.enterText(_key('assistant-input'), '请阅读这份附件');
    await tester.tap(_key('assistant-send-button'));
    // SQLite 保存后才发出 POST，有限推进到合成接口进入等待。
    for (
      int attempt = 0;
      attempt < 30 &&
          !repository.calls.any(
            (call) => call.method == 'POST' && call.path.endsWith('/messages'),
          );
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(_key('assistant-progress-sending'), findsOneWidget);
    expect(_key('history-attachment-moving-document'), findsOneWidget);
    expect(_key('assistant-draft-moving-document'), findsNothing);
    expect(
      tester.widget<OmniTextField>(_key('assistant-input')).controller!.text,
      isEmpty,
    );
    expect(find.text('请阅读这份附件', findRichText: true), findsOneWidget);
    repository.delayedSend!.completeError(
      const AssistantApiFailure('附件已过期', 400, code: 'ATTACHMENT_EXPIRED'),
    );
    await tester.pumpAndSettle();
    expect(_key('assistant-progress-sending'), findsNothing);
    expect(_key('history-attachment-moving-document'), findsNothing);
    expect(_key('assistant-draft-moving-document'), findsOneWidget);
    expect(
      tester.widget<OmniTextField>(_key('assistant-input')).controller!.text,
      '请阅读这份附件',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具执行步骤实时更新并且重复事件不会重复显示', (WidgetTester tester) async {
    // 所有步骤均为合成公开元数据，不包含真实工具参数或结果。
    final _DesktopRepository repository = _DesktopRepository()
      ..eventStream = StreamController<AssistantEvent>()
      ..activeRun = {
        'id': 'run',
        'answerMessageId': 'trace-answer',
        'status': 'running',
        'recovery': {'reason': '模型服务暂时不可用，正在安全重试'},
        'elapsedMs': 0,
        'liveElapsedMs': 1500,
        'executionSteps': [
          {
            'id': 'run:tool:query',
            'kind': 'tool',
            'label': '查询待办',
            'status': 'running',
          },
        ],
      };
    await _pumpDesktop(tester, repository: repository);
    expect(find.text('查询待办'), findsNothing);
    expect(find.text('查询待办 · 执行中'), findsOneWidget);
    await tester.tap(_key('assistant-execution-toggle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('查询待办'), findsOneWidget);
    expect(find.text('执行中'), findsOneWidget);
    expect(find.text('模型服务暂时不可用，正在安全重试'), findsOneWidget);
    // 同一身份更新为完成，第二项只规划不能显示成已保存。
    repository.activeRun = {
      ...repository.activeRun!,
      'liveElapsedMs': 2500,
      'recovery': null,
      'executionSteps': [
        {
          'id': 'run:tool:query',
          'kind': 'tool',
          'label': '查询待办',
          'status': 'succeeded',
        },
        {
          'id': 'run:tool:create',
          'kind': 'tool',
          'label': '新增待办',
          'status': 'planned',
        },
        {
          'id': 'run:model:answer',
          'kind': 'model',
          'label': '生成回答',
          'status': 'running',
        },
      ],
    };
    // 两次同序号回放只能应用一次。
    final AssistantEvent event = AssistantEvent(
      seq: 1,
      type: 'run.updated',
      runId: 'run',
      data: {'run': repository.activeRun!},
    );
    repository.eventStream!.add(event);
    repository.eventStream!.add(event);
    await tester.pump();
    await tester.pump();
    expect(find.text('查询待办'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('已规划'), findsOneWidget);
    expect(find.text('模型服务暂时不可用，正在安全重试'), findsNothing);
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'execution_running');
    }
    // 用户主动收起后，首个正文出现不能擅自恢复展开。
    await tester.tap(_key('assistant-execution-toggle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('查询待办'), findsNothing);
    repository.eventStream!.add(
      const AssistantEvent(
        seq: 2,
        type: 'message.delta',
        runId: 'run',
        data: {'messageId': 'trace-answer', 'text': '找到以下待办。'},
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('查询待办'), findsNothing);
    await tester.tap(_key('assistant-execution-toggle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('查询待办'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('assistant-answer-trace-answer'),
        matching: find.text('查询待办'),
      ),
      findsOneWidget,
    );
    // 消息终态先到时，旧run内同一步的running不能覆盖已完成事实。
    repository.eventStream!.add(
      AssistantEvent(
        seq: 3,
        type: 'message.completed',
        runId: 'run',
        data: {
          'message': {
            'id': 'trace-answer',
            'role': 'assistant',
            'content': '找到以下待办。',
            'cards': <Object>[],
            'executionSteps': [
              {
                'id': 'run:model:answer',
                'kind': 'model',
                'label': '生成回答',
                'status': 'succeeded',
                'finishedAt': '2026-10-23T15:00:00Z',
              },
            ],
          },
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: _key('assistant-execution-step-run:model:answer'),
        matching: find.text('已完成'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('执行链默认单行收起，工具参数独立展开，用时悬停黑字且背景不变', (WidgetTester tester) async {
    // 同一函数的两次调用必须按不同身份分别展开。
    final _DesktopRepository repository = _DesktopRepository()
      ..executionSteps = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'detail:first',
          'kind': 'tool',
          'label': '查询待办',
          'detail': '已读取22条，进度步骤已摘要',
          'status': 'succeeded',
          'tool': <String, dynamic>{
            'name': 'search_todos',
            'arguments': <String, dynamic>{'query': '紧急重要', 'limit': 10},
          },
        },
        <String, dynamic>{
          'id': 'detail:second',
          'kind': 'tool',
          'label': '查询待办',
          'status': 'succeeded',
          'tool': <String, dynamic>{
            'name': 'search_todos',
            'arguments': <String, dynamic>{'query': '其他任务'},
          },
        },
      ];
    await _pumpDesktop(tester, repository: repository);
    expect(_key('assistant-execution-step-detail:first'), findsNothing);
    expect(find.text('查询待办 · 已完成'), findsOneWidget);
    // 采样标题右侧空白，真实鼠标事件不能在整行绘制灰底。
    final Rect bounds = tester.getRect(_key('assistant-execution-toggle'));
    final Offset sample = Offset(bounds.right - 4, bounds.center.dy);
    final Color before = await _surfacePixel(tester, sample);
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(600, 30));
    await mouse.moveTo(tester.getCenter(find.text('用时 46秒')));
    await tester.pumpAndSettle();
    expect(
      DefaultTextStyle.of(tester.element(find.text('用时 46秒'))).style.color,
      Colors.black,
    );
    expect(await _surfacePixel(tester, sample), before);
    await tester.tap(_key('assistant-execution-toggle'));
    await tester.pumpAndSettle();
    expect(_key('assistant-tool-arguments-detail:first'), findsNothing);
    // 摘要紧接工具名，箭头位于状态文字左边，而不是末尾。
    final Rect toolLabel = tester.getRect(
      _key('assistant-step-label-detail:first'),
    );
    // 事实摘要与名称同一行，不能增加第二行高度。
    final Rect toolDetail = tester.getRect(
      _key('assistant-step-detail-detail:first'),
    );
    // 状态与展开操作各自保留可见位置。
    final Rect toolArrow = tester.getRect(
      _key('assistant-step-arrow-detail:first'),
    );
    // 真实完成状态在右侧单独定位，不能被摘要挤走。
    final Rect toolStatus = tester.getRect(
      _key('assistant-step-status-detail:first'),
    );
    expect(toolDetail.left, greaterThan(toolLabel.right));
    expect(toolDetail.center.dy, closeTo(toolLabel.center.dy, 1));
    expect(toolArrow.right, lessThan(toolStatus.left));
    await tester.tap(_key('assistant-tool-toggle-detail:first'));
    await tester.pumpAndSettle();
    expect(find.text('search_todos'), findsOneWidget);
    expect(find.textContaining('紧急重要'), findsOneWidget);
    expect(_key('assistant-tool-arguments-detail:second'), findsNothing);
    // 总链路收起再打开，单个调用的选择仍然保留。
    await tester.tap(_key('assistant-execution-toggle'));
    await tester.pumpAndSettle();
    await tester.tap(_key('assistant-execution-toggle'));
    await tester.pumpAndSettle();
    expect(_key('assistant-tool-arguments-detail:first'), findsOneWidget);
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'tool_arguments');
    }
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史执行链可展开收起，失败步骤和长标签在窄窗口正确显示', (WidgetTester tester) async {
    // 固定终态便于验证暂停后的耗时和折叠内容。
    final _DesktopRepository repository = _DesktopRepository()
      ..executionSteps = [
        {
          'id': 'history:query',
          'kind': 'tool',
          'label': '查询紧急且重要的待办以及对应分类详情',
          'status': 'succeeded',
        },
        {
          'id': 'history:save',
          'kind': 'commit',
          'label': '保存待办',
          'status': 'failed',
        },
      ];
    await _pumpDesktop(
      tester,
      repository: repository,
      size: const Size(640, 900),
      textScale: 1.5,
    );
    expect(find.text('保存待办'), findsNothing);
    await tester.tap(_key('assistant-execution-toggle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('保存待办'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('用时 46秒'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'execution');
    }
    await tester.tap(_key('assistant-execution-toggle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('保存待办'), findsNothing);
  });

  testWidgets('320宽双倍字号展开执行链时长标签及摘要省略且状态不溢出', (WidgetTester tester) async {
    // 最窄窗口也使用真实页面、文本缩放和完整执行行。
    final _DesktopRepository repository = _DesktopRepository()
      ..userContent = '你好'
      ..executionSteps = [
        {
          'id': 'narrow:query',
          'kind': 'tool',
          'label': '查询紧急且重要的待办以及对应分类详情',
          'detail': '已读取22条，进度步骤已摘要，仍有后续记录，更多查询范围尚未核实',
          'status': 'succeeded',
          'tool': <String, dynamic>{
            'name': 'search_todos',
            'arguments': <String, dynamic>{
              'query': '紧急且重要的任务以及对应分类详情',
              'limit': 20,
            },
          },
        },
      ];
    await _pumpDesktop(
      tester,
      repository: repository,
      size: const Size(320, 900),
      textScale: 2,
    );
    await tester.ensureVisible(_key('assistant-execution-toggle'));
    await tester.pumpAndSettle();
    await tester.tap(_key('assistant-execution-toggle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('查询紧急且重要的待办以及对应分类详情'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    // 文本保留原文以供提示查看，实际渲染限制为单行并显示省略号。
    final Text detail = tester.widget<Text>(
      _key('assistant-step-detail-narrow:query'),
    );
    // 实际排版确认触发省略，不能只检查配置而未发生约束。
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      _key('assistant-step-detail-narrow:query'),
    );
    expect(detail.maxLines, 1);
    expect(detail.overflow, TextOverflow.ellipsis);
    expect(paragraph.didExceedMaxLines, isTrue);
    expect(
      tester.getRect(_key('assistant-step-arrow-narrow:query')).right,
      lessThan(tester.getRect(_key('assistant-step-status-narrow:query')).left),
    );
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'tool_status_narrow');
    }
    await tester.tap(_key('assistant-tool-toggle-narrow:query'));
    await tester.pumpAndSettle();
    expect(_key('assistant-tool-arguments-narrow:query'), findsOneWidget);
    expect(find.textContaining('"limit": 20'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 验证多种窗口和字号组合，折叠布局仍保留必要入口。
  testWidgets('320宽双倍字号的真实输入区保留附件与发送操作，附件独立发送', (WidgetTester tester) async {
    // 文件来自恢复缓存，测试不打开系统选择器。
    final _DesktopRepository repository = _DesktopRepository()
      ..attachmentsEnabled = true;
    await _pumpDesktop(
      tester,
      repository: repository,
      size: const Size(320, 900),
      textScale: 2,
      draftAttachments: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'attachment-document',
          'name': '项目会议记录和后续安排.txt',
          'kind': 'document',
          'status': 'ready',
          'requiresVision': false,
          'size': 100,
        },
      ],
    );
    expect(find.text('项目会议记录和后续安排.txt'), findsOneWidget);
    expect(_key('assistant-attach-button'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'attachments');
    }
    await tester.ensureVisible(_key('assistant-send-button'));
    await tester.tap(_key('assistant-send-button'));
    await tester.pumpAndSettle();
    // 文件独立发送时原始身份和默认请求必须明确进入 API。
    final Map<String, dynamic> body =
        repository.calls
                .lastWhere(
                  (call) =>
                      call.method == 'POST' && call.path.endsWith('/messages'),
                )
                .data
            as Map<String, dynamic>;
    expect(body['content'], '请概括附件内容');
    expect(body['attachmentIds'], <String>['attachment-document']);
    expect(find.text('项目会议记录和后续安排.txt'), findsOneWidget);
    expect(_key('assistant-draft-attachment-document'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // 图片已就绪与模型能否读图是两件事，按钮不能静默吞掉发送操作。
  for (final String capability in <String>['unknown', 'supported']) {
    testWidgets('历史图片能力为$capability时仍需多模态开关，开启后原图加文字可发送', (
      WidgetTester tester,
    ) async {
      // 不根据模型名称推断能力，使用服务器实际投影形状。
      final _DesktopRepository repository = _DesktopRepository()
        ..attachmentsEnabled = true;
      // 历史探测结果不能替代配置的多模态开关。
      final Map<String, dynamic> profile = <String, dynamic>{
        'id': 'profile-1',
        'name': '当前配置',
        'model': 'GLM-5.2',
        'hasApiKey': true,
        'multimodal': false,
        'capabilities': <String, dynamic>{'imageInput': capability},
      };
      repository.settings['profiles'] = <Object>[profile];
      await _pumpDesktop(
        tester,
        repository: repository,
        size: capability == 'supported'
            ? const Size(320, 900)
            : const Size(1440, 900),
        textScale: capability == 'supported' ? 2 : 1,
        draftAttachments: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'image-with-text',
            'name': '截图.png',
            'kind': 'image',
            'status': 'ready',
            'uploaded': true,
            'requiresVision': true,
            'size': 2048,
          },
        ],
      );
      await tester.enterText(_key('assistant-input'), '这张图片是什么？');
      await tester.pumpAndSettle();
      // 未发送时继续保持用户要求的简洁输入区。
      expect(find.textContaining('未开启多模态'), findsNothing);
      expect(
        tester.widget<OmniInkWell>(_key('assistant-send-button')).onTap,
        isNotNull,
      );
      if (capability == 'unknown') {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(_key('assistant-send-button'));
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('未开启多模态'), findsOneWidget);
      expect(find.textContaining('未开启多模态').hitTestable(), findsOneWidget);
      expect(find.text('AI 设置').hitTestable(), findsOneWidget);
      expect(
        tester.widget<OmniTextField>(_key('assistant-input')).controller!.text,
        '这张图片是什么？',
      );
      expect(_key('assistant-draft-image-with-text'), findsOneWidget);
      // 失败校验不能创建聊天、提交消息或隐式调用付费能力探测。
      expect(repository.calls.where((call) => call.method == 'POST'), isEmpty);
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        await _capture(tester, 'image_send_$capability');
      }
      profile['multimodal'] = true;
      await tester.tap(_key('assistant-send-button'));
      await tester.pumpAndSettle();
      // 控制器读取新能力后，仍用原文字和原附件身份提交。
      final Map<String, dynamic> body =
          repository.calls
                  .singleWhere(
                    (call) =>
                        call.method == 'POST' &&
                        call.path.endsWith('/messages'),
                  )
                  .data!
              as Map<String, dynamic>;
      expect(body['content'], '这张图片是什么？');
      expect(body['attachmentIds'], <String>['image-with-text']);
      expect(_key('assistant-draft-image-with-text'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Windows附件预览悬停及聊天投放遮罩符合工作区边界', (WidgetTester tester) async {
    await _pumpDesktop(
      tester,
      repository: _DesktopRepository()..attachmentsEnabled = true,
      draftAttachments: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'preview-image',
          'name': '界面截图.png',
          'kind': 'image',
          'status': 'ready',
          'requiresVision': false,
          'size': 2048,
          'localPath': File('assets/icon/app_icon.png').absolute.path,
        },
        <String, dynamic>{
          'id': 'preview-document',
          'name': '叶梧浩-Agent应用开发简历.pdf',
          'kind': 'document',
          'status': 'ready',
          'requiresVision': false,
          'size': 128000,
        },
      ],
    );
    // 文件读取与图像解码跨多个事件轮次，必须等到真正有像素后再核对预览。
    final Finder thumbnail = find.descendant(
      of: _key('assistant-draft-image-preview-image'),
      matching: find.byType(RawImage),
    );
    for (
      int attempt = 0;
      attempt < 30 && tester.widget<RawImage>(thumbnail).image == null;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(thumbnail).image, isNotNull);
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'draft_previews');
    }
    // 操作仅在当前卡片悬停时出现，右侧文档不跟随变暗。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(1000, 200));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(_key('assistant-draft-hover-preview-image')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedOpacity>(_key('assistant-draft-mask-preview-image'))
          .opacity,
      1,
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            _key('assistant-draft-mask-preview-document'),
          )
          .opacity,
      0,
    );
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'draft_preview_hover');
    }
    // 投放提示仅覆盖对话区域，保留左侧导航与聊天历史。
    final DropTarget target = tester.widget<DropTarget>(
      _key('assistant-file-drop-target'),
    );
    target.onDragEntered!(
      DropEventDetails(
        localPosition: const Offset(200, 200),
        globalPosition: const Offset(800, 200),
      ),
    );
    await tester.pumpAndSettle();
    expect(_key('assistant-file-drop-overlay'), findsOneWidget);
    expect(
      tester.getRect(_key('assistant-file-drop-overlay')).left,
      greaterThan(280),
    );
    if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
      await _capture(tester, 'file_drop_overlay');
    }
    target.onDragExited!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pumpAndSettle();
    expect(_key('assistant-file-drop-overlay'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 附件启用时普通 CtrlV 仍粘贴文字', (WidgetTester tester) async {
    // 模拟纯文本剪贴板，不读取真实用户数据。
    final _TextOnlyClipboard clipboard = _TextOnlyClipboard();
    await _pumpDesktop(
      tester,
      repository: _DesktopRepository()..attachmentsEnabled = true,
      clipboard: clipboard,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': '粘贴的文字'};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.tap(_key('assistant-input'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(clipboard.reads, 0);
    expect(
      tester.widget<OmniTextField>(_key('assistant-input')).controller!.text,
      '粘贴的文字',
    );
  });

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
        // 高字号与长列表只能向上滚动展开，完整菜单不能覆盖模型入口。
        final Rect menu = tester.getRect(_key('assistant-model-menu'));
        expect(
          menu.bottom,
          lessThanOrEqualTo(
            tester.getRect(_key('assistant-model-button')).top - 8,
          ),
        );
        expect(menu.top, greaterThanOrEqualTo(12));
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
