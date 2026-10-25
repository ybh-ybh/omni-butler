// ignore_for_file: invalid_use_of_internal_member

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/shared/layout/responsive_shell.dart';
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows生产字体直接取自系统，不向仓库复制字体文件。
final File _windowsTooltipFont = File(
  '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/msyhbd.ttc',
);

/// 仅在具备真实Windows字体时执行字形像素测试，其他环境验证布局契约。
final bool _canCheckNativeTooltipFont =
    Platform.isWindows && _windowsTooltipFont.existsSync();

/// 测试使用的在线设备会话。
const SyncSession _onlineSession = SyncSession(
  identity: SyncIdentity(id: 'responsive-shell-sync-user'),
  apiBaseUrl: 'http://127.0.0.1:3000/omni-butler/api/v1',
  isOffline: false,
);

/// 测试使用的离线设备会话。
const SyncSession _offlineSession = SyncSession(
  identity: SyncIdentity(id: 'responsive-shell-sync-user'),
  apiBaseUrl: 'http://127.0.0.1:3000/omni-butler/api/v1',
  isOffline: true,
);

/// 返回指定设备会话的认证控制器。
class _TestAuthController extends AuthController {
  /// 本次测试使用的设备会话。
  final SyncSession? session;

  /// 创建固定设备会话控制器。
  _TestAuthController(this.session);

  /// 返回固定设备会话。
  @override
  Future<SyncSession?> build() async => session;
}

/// 返回已完成状态的同步控制器。
class _IdleSyncController extends SyncController {
  /// 不执行实际同步连接。
  @override
  Future<void> build() async {}
}

/// 验证桌面壳层同步状态与顶栏入口。
void main() {
  setUpAll(() async {
    if (!_canCheckNativeTooltipFont) return;
    // 测试引擎默认字体不代表Windows中文字体的真实升降部度量。
    final FontLoader loader = FontLoader('Microsoft YaHei UI')
      ..addFont(_windowsTooltipFont.readAsBytes().then(ByteData.sublistView));
    await loader.load();
  });
  testWidgets('Windows全局顶栏仅首页显示，其他页面直接使用顶部空间', (WidgetTester tester) async {
    // 窄窗和宽窗都必须按路由隐藏整条顶栏，而不是仅隐藏搜索文字。
    for (final double width in <double>[640, 1440]) {
      // 覆盖全部业务页以及返回首页，避免切换后遗留空白。
      for (final String location in <String>[
        '/home',
        '/todos',
        '/timeline',
        '/notes',
        '/assistant',
        '/events',
        '/inventory',
        '/memberships',
        '/settings',
        '/home',
      ]) {
        await _pumpShell(
          tester,
          syncEnabled: false,
          width: width,
          location: location,
        );
        // 首页保留搜索与外观切换，其余页面的两个入口都应移除。
        final Matcher presence = location == '/home'
            ? findsOneWidget
            : findsNothing;
        expect(find.text('搜索待办、事件、物品和会员'), presence);
        expect(find.byTooltip('外观模式'), presence);
        // 页面实际边界用于证明隐藏后没有48dp的空白占位。
        final Rect content = tester.getRect(
          find.byKey(const ValueKey<String>('shell-page-content')),
        );
        expect(content.top, location == '/home' ? OmniSize.topBar : 0);
        expect(content.bottom, 900);
        expect(tester.takeException(), isNull);
      }
    }
  });

  // 两种主题都必须真正缩小墨迹，而不是只调整控件配置。
  for (final Brightness brightness in Brightness.values) {
    testWidgets('Windows ${brightness.name} 侧栏悬停背景与选中背景同为 32dp', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, syncEnabled: false, brightness: brightness);
      // 保留完整热区，背景只在其中的小方块内绘制。
      final Rect target = tester.getRect(
        find.byKey(const ValueKey<String>('navigation-/settings')),
      );
      expect(target.size, const Size(56, 48));
      // 从已选中的首页读取真实背景大小，避免两种状态各自维护尺寸。
      final Rect selectedBackground = tester.getRect(
        find
            .descendant(
              of: find.byKey(const ValueKey<String>('navigation-/home')),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(selectedBackground.size, const Size(32, 32));
      // 对比鼠标移入前后的真实像素，定位悬停背景的实际边界。
      final ({ByteData bytes, int width}) before = await _shellPixels(tester);
      // 使用真实鼠标触发悬停，不手动注入组件状态。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(300, 400));
      await mouse.moveTo(target.center);
      await tester.pumpAndSettle();
      // 稳定动画后的画面与原图具有相同的像素尺寸。
      final ({ByteData bytes, int width}) after = await _shellPixels(tester);
      // 只收集导航热区内发生改变的像素，提示浮层不参与比较。
      Rect? changed;
      for (int y = target.top.toInt(); y < target.bottom.toInt(); y++) {
        for (int x = target.left.toInt(); x < target.right.toInt(); x++) {
          // RGBA四通道一起比较，避免忽略半透明墨迹。
          final int offset = (y * before.width + x) * 4;
          if (before.bytes.getUint32(offset) != after.bytes.getUint32(offset)) {
            // 每个像素占据一个逻辑像素的正方形。
            final Rect pixel = Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1);
            changed = changed?.expandToInclude(pixel) ?? pixel;
          }
        }
      }
      expect(changed, isNotNull);
      // 半像素中心会在两侧产生抗锯齿像素，按实际栅格边界比较。
      final Rect background = Rect.fromCenter(
        center: target.center,
        width: selectedBackground.width,
        height: selectedBackground.height,
      );
      expect(
        changed,
        Rect.fromLTRB(
          background.left.floorToDouble(),
          background.top.floorToDouble(),
          background.right.ceilToDouble(),
          background.bottom.ceilToDouble(),
        ),
      );
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
    // 检查真实字形像素而不只检查文字布局框，覆盖普通和双倍字号。
    for (final double scale in <double>[1, 2]) {
      testWidgets(
        'Windows ${brightness.name} $scale 倍字号的tip字形上下居中',
        (WidgetTester tester) async {
          await _pumpShell(
            tester,
            syncEnabled: false,
            brightness: brightness,
            scale: scale,
          );
          // 使用真实鼠标打开管理提示，等待原生浮层完成淡入。
          final TestGesture mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: const Offset(300, 400));
          await mouse.moveTo(
            tester.getCenter(
              find.byKey(const ValueKey<String>('navigation-/inventory')),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpAndSettle();
          // 可见字形而不是包含行高的文字框应与背景垂直中心重合。
          final Finder message = find.text('管理');
          // 文字前景像素的最小边界。
          final Rect ink = await _tooltipInkBounds(tester, message);
          // 字形自身度量与栅格量化允许每倍率一个像素的光学校正余量。
          final Rect bubble = _tooltipBounds(tester, message);
          expect(ink.center.dy, closeTo(bubble.center.dy, scale));
          await mouse.removePointer();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
        skip: !_canCheckNativeTooltipFont,
      );
    }
  }

  testWidgets('短窗口保留同步和设置入口，功能图标可滚动到达', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      width: 640,
      height: 440,
      status: _syncStatus(connected: true, hasSynced: true),
    );
    // 状态与设置固定在窗口内，顶部功能区独立滚动，不挤出底部入口。
    final Finder status = find.byKey(
      const ValueKey<String>('sidebar-sync-status'),
    );
    final Finder settings = find.byKey(
      const ValueKey<String>('navigation-/settings'),
    );
    final Finder management = find.byKey(
      const ValueKey<String>('navigation-/inventory'),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getRect(settings).bottom, lessThanOrEqualTo(440));
    expect(
      tester.getRect(status).bottom,
      lessThanOrEqualTo(tester.getRect(settings).top),
    );
    await tester.ensureVisible(management);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(management).bottom,
      lessThanOrEqualTo(tester.getRect(status).top),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 所有一级页面在窄窗和宽窗均固定为图标轨', (WidgetTester tester) async {
    for (final double width in <double>[640, 1024, 1920]) {
      for (final String location in <String>[
        '/home',
        '/todos',
        '/timeline',
        '/notes',
        '/assistant',
        '/inventory',
        '/settings',
      ]) {
        await _pumpShell(
          tester,
          syncEnabled: false,
          width: width,
          location: location,
        );
        expect(
          find.byKey(const ValueKey<String>('expanded-sidebar')),
          findsNothing,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey<String>('medium-navigation')))
              .width,
          OmniSize.navigationRail,
        );
        expect(find.text('Omni Butler'), findsNothing);
        expect(find.text('首页'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('各功能图标悬停提示位于右侧并居中，移出后消失且不改变键盘焦点', (WidgetTester tester) async {
    await _pumpShell(tester, syncEnabled: false);
    // 使用真实鼠标事件触发原生Tooltip，而非手动令提示可见。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(300, 400));
    // 提示不得抢走原焦点，也不得把路由名称常驻显示。
    final FocusNode? focus = FocusManager.instance.primaryFocus;
    for (final MapEntry<String, String> destination in <String, String>{
      '/home': '首页',
      '/todos': '待办',
      '/timeline': '时间',
      '/notes': '笔记',
      '/assistant': '助手',
      '/inventory': '管理',
      '/settings': '设置',
    }.entries) {
      // 每个入口都保留语义标签，即使尚未悬停也可由读屏识别。
      final Finder target = find.byKey(
        ValueKey<String>('navigation-${destination.key}'),
      );
      expect(find.byTooltip(destination.value), findsOneWidget);
      expect(find.text(destination.value), findsNothing);
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text(destination.value), findsOneWidget);
      // 检查实际浮层边框与文字的几何，而不是只核对主题配置。
      final Finder message = find.text(destination.value);
      // Tooltip文字最近的容器就是绘制圆角背景的浮层。
      final Rect bubble = _tooltipBounds(tester, message);
      // 字号缩小一档，保留半粗字重以保证可读性。
      final Text text = tester.widget<Text>(message);
      expect(text.style!.fontSize, 14);
      expect(text.style!.fontWeight, FontWeight.w600);
      expect(text.style!.leadingDistribution, TextLeadingDistribution.even);
      // 圆角取自真实提示背景，不只核对外层主题。
      final Container background = tester.widget<Container>(
        find.ancestor(of: message, matching: find.byType(Container)).first,
      );
      expect(
        (background.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(12),
      );
      // 浮层相对图标的32dp背景保持5dp，而不是相对整个热区。
      final Rect icon = tester.getRect(target);
      expect(bubble.left - (icon.center.dx + 16), closeTo(5, .01));
      expect(bubble.height, closeTo(33, .5));
      expect(bubble.center.dy, closeTo(icon.center.dy, .5));
      _expectTooltipPadding(tester, message, bubble);
      expect(FocusManager.instance.primaryFocus, same(focus));
      await mouse.moveTo(const Offset(300, 400));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text(destination.value), findsNothing);
    }
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步仅显示状态图标，窄窗大字号悬停后右侧显示完整说明', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      width: 400,
      scale: 2,
      status: _syncStatus(connected: true, hasSynced: true),
    );
    // 普通布局不保留状态标题或说明文字。
    final Finder target = find.byKey(
      const ValueKey<String>('sidebar-sync-status'),
    );
    expect(
      find.descendant(of: target, matching: find.byType(Text)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: target,
        matching: find.byIcon(Icons.cloud_done_outlined),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('本机数据已同步至服务器'), findsNothing);
    // 同步状态与设置入口在同一条图标轨上。
    expect(
      tester.getCenter(target).dx,
      closeTo(
        tester
            .getCenter(
              find.byKey(const ValueKey<String>('navigation-/settings')),
            )
            .dx,
        .01,
      ),
    );
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(300, 400));
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final Finder message = find.text('同步完成\n本机数据已同步至服务器');
    expect(message, findsOneWidget);
    final Rect bubble = _tooltipBounds(tester, message);
    expect(bubble.left - (tester.getCenter(target).dx + 16), closeTo(5, .01));
    expect(bubble.right, lessThanOrEqualTo(400));
    expect(bubble.bottom, lessThanOrEqualTo(900));
    _expectTooltipPadding(tester, message, bubble);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  });

  testWidgets('关闭同步时隐藏侧栏状态且顶栏不再展示本机数据入口', (WidgetTester tester) async {
    await _pumpShell(tester, syncEnabled: false);

    expect(
      find.byKey(const ValueKey<String>('sidebar-sync-status')),
      findsNothing,
    );
    expect(find.text('仅保存在本机'), findsNothing);
    expect(find.byTooltip('个人本机数据'), findsNothing);
    expect(find.byTooltip('外观模式'), findsOneWidget);
    expect(find.text('搜索待办、事件、物品和会员'), findsOneWidget);
    expect(find.text('Ctrl+F'), findsOneWidget);

    tester.view.physicalSize = const Size(640, 760);
    await tester.pumpAndSettle();

    expect(find.byTooltip('个人本机数据'), findsNothing);
    expect(find.byTooltip('外观模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页和隐藏顶栏的页面仍支持Ctrl+F，斜杠键不触发搜索', (WidgetTester tester) async {
    // 去除页面上的入口不应改变已有的全局搜索快捷键。
    for (final String location in <String>['/home', '/todos']) {
      await _pumpShell(tester, syncEnabled: false, location: location);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      expect(find.text('搜索全部内容'), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('搜索全部内容'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('搜索全部内容'), findsNothing);
    }
  });

  testWidgets('连接尚未建立时显示连接中', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      status: _syncStatus(connected: false, connecting: true),
    );

    expect(find.byTooltip('连接中\n正在连接同步服务器'), findsOneWidget);
    expect(find.text('连接中'), findsNothing);
  });

  testWidgets('上传下载、待上传队列和首次同步均显示正在同步', (WidgetTester tester) async {
    // 需要依次验证的同步中状态组合。
    final List<({SyncStatus status, int queueCount})>
    cases = <({SyncStatus status, int queueCount})>[
      (status: _syncStatus(connected: true, uploading: true), queueCount: 0),
      (status: _syncStatus(connected: true, downloading: true), queueCount: 0),
      (status: _syncStatus(connected: true, hasSynced: true), queueCount: 2),
      (status: _syncStatus(connected: true), queueCount: 0),
    ];

    for (final ({SyncStatus status, int queueCount}) testCase in cases) {
      await _pumpShell(
        tester,
        syncEnabled: true,
        status: testCase.status,
        queueCount: testCase.queueCount,
      );
      expect(find.byTooltip('正在同步\n本机数据正在同步到服务器'), findsOneWidget);
      expect(find.text('正在同步'), findsNothing);
    }
  });

  testWidgets('完成完整同步且队列为空时显示同步完成', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      status: _syncStatus(connected: true, hasSynced: true),
    );

    expect(find.byTooltip('同步完成\n本机数据已同步至服务器'), findsOneWidget);
    expect(find.text('同步完成'), findsNothing);
    expect(find.text('本机数据已同步至服务器'), findsNothing);
  });

  testWidgets('离线状态优先于连接状态显示', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      session: _offlineSession,
      status: _syncStatus(connected: false, connecting: true),
    );

    expect(find.byTooltip('离线\n联网后将自动继续同步'), findsOneWidget);
  });

  testWidgets('完成过同步后连接中断显示离线', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      status: _syncStatus(connected: false, hasSynced: true),
    );

    expect(find.byTooltip('离线\n联网后将自动继续同步'), findsOneWidget);
  });

  testWidgets('PowerSync 错误优先显示同步异常', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      session: _offlineSession,
      status: _syncStatus(
        connected: false,
        connecting: true,
        error: StateError('测试同步异常'),
      ),
    );

    expect(find.byTooltip('同步异常\n请前往设置查看详情'), findsOneWidget);
    expect(find.text('请前往设置查看详情'), findsNothing);
  });
}

/// 返回文字对应的提示背景实际边界，包含内边距。
Rect _tooltipBounds(WidgetTester tester, Finder message) => tester.getRect(
  find.ancestor(of: message, matching: find.byType(Container)).first,
);

/// 验证提示文字四周留白，保证放大文字时也不会贴边。
void _expectTooltipPadding(WidgetTester tester, Finder message, Rect bubble) {
  // 文字布局边界与字形内部留白不同，按布局边界测量。
  final Rect text = tester.getRect(message);
  expect(text.left - bubble.left, closeTo(10, .01));
  expect(bubble.right - text.right, closeTo(10, .01));
  expect(text.top - bubble.top, closeTo(6, .01));
  expect(bubble.bottom - text.bottom, closeTo(6, .01));
}

/// 在桌面宽屏中挂载带指定同步状态的响应式壳层。
Future<void> _pumpShell(
  WidgetTester tester, {
  required bool syncEnabled,
  SyncSession? session = _onlineSession,
  SyncStatus? status,
  int queueCount = 0,
  double width = 1440,
  double height = 900,
  double scale = 1,
  String location = '/home',
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': brightness.name,
    'sync.enabled': syncEnabled,
  });
  // 测试使用的设备偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 未显式提供时使用的初始未连接状态。
  final SyncStatus effectiveStatus =
      status ?? _syncStatus(connected: false, connecting: false);

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        authControllerProvider.overrideWith(() => _TestAuthController(session)),
        syncControllerProvider.overrideWith(_IdleSyncController.new),
        syncStatusProvider.overrideWithValue(
          AsyncData<SyncStatus?>(effectiveStatus),
        ),
        syncUploadQueueCountProvider.overrideWithValue(
          AsyncData<int>(queueCount),
        ),
      ],
      child: RepaintBoundary(
        key: const ValueKey<String>('shell-with-tooltip-pixels'),
        child: MaterialApp(
          theme: AppTheme.build(brightness: brightness)
              .copyWith(platform: TargetPlatform.windows),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: const ValueKey<String>('shell-test-pixels'),
            child: ResponsiveShell(
              location: location,
              child: const SizedBox.expand(
                key: ValueKey<String>('shell-page-content'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 读取指定边界的真实合成像素，默认只读取不含提示浮层的壳层。
Future<({ByteData bytes, int width})> _shellPixels(
  WidgetTester tester, {
  String boundaryKey = 'shell-test-pixels',
}) async {
  // 显式绘制边界允许不依赖截图文件比较灰色背景大小。
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(ValueKey<String>(boundaryKey)),
  );
  return (await tester.runAsync(() async {
    // 固定一个逻辑像素对应一个图像像素。
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    try {
      return (
        bytes: (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
        width: image.width,
      );
    } finally {
      image.dispose();
    }
  }))!;
}

/// 在文字框内定位实际字形，避免背景圆角及外围图标影响采样。
Future<Rect> _tooltipInkBounds(WidgetTester tester, Finder message) async {
  // 文字框包含字体行高，只有前景像素属于真正可见的字形。
  final Rect bounds = tester.getRect(message);
  // 使用实际主题前景色识别明暗模式下的文字。
  final int foreground = tester.widget<Text>(message).style!.color!.toARGB32();
  // 外层绘制边界包含原生Tooltip浮层。
  final ({ByteData bytes, int width}) pixels = await _shellPixels(
    tester,
    boundaryKey: 'shell-with-tooltip-pixels',
  );
  // 逐个合并接近前景色的像素，允许文字抗锯齿造成的小量色差。
  Rect? ink;
  for (int y = bounds.top.floor(); y < bounds.bottom.ceil(); y++) {
    // 每一行独立扫描，保留浮层在屏幕上的真实坐标。
    for (int x = bounds.left.floor(); x < bounds.right.ceil(); x++) {
      // 原始图像按RGBA连续存储每个像素。
      final int offset = (y * pixels.width + x) * 4;
      // 前景色越接近，RGB差值之和越小。
      final int distance =
          (pixels.bytes.getUint8(offset) - ((foreground >> 16) & 255)).abs() +
          (pixels.bytes.getUint8(offset + 1) - ((foreground >> 8) & 255))
              .abs() +
          (pixels.bytes.getUint8(offset + 2) - (foreground & 255)).abs();
      if (distance < 24) {
        // 每个采样像素占据一个逻辑像素的面积。
        final Rect pixel = Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1);
        ink = ink?.expandToInclude(pixel) ?? pixel;
      }
    }
  }
  expect(ink, isNotNull, reason: '提示文字必须实际绘制到浮层');
  return ink!;
}

/// 创建可控制关键字段的 PowerSync 状态。
SyncStatus _syncStatus({
  required bool connected,
  bool connecting = false,
  bool uploading = false,
  bool downloading = false,
  bool hasSynced = false,
  Object? error,
}) {
  return SyncStatus(
    connected: connected,
    connecting: connecting,
    lastSyncedAt: hasSynced ? DateTime.utc(2026, 9, 25, 12) : null,
    downloadProgress: null,
    downloading: downloading,
    uploading: uploading,
    downloadError: error,
    uploadError: null,
    priorityStatusEntries: const <SyncPriorityStatus>[],
    streamSubscriptions: null,
    lastAppliedCheckpoint: null,
  );
}
