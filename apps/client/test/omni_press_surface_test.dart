import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证实际扩散画面、手势互斥和取消恢复，不以控制器数值替代像素。
void main() {
  // 每个测试独立记录系统长按振动请求，不依赖测试主机的振动硬件。
  final List<MethodCall> haptics = <MethodCall>[];
  setUp(() {
    haptics.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // 仅安卓成功长按振动，减少动画偏好不关闭触觉反馈。
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    for (final bool reduced in <bool>[false, true]) {
      testWidgets('${platform.name}减少动画=$reduced仅成功长按时振动一次', (
        WidgetTester tester,
      ) async {
        // 原点击和长按菜单的独立回调计数。
        int taps = 0;
        int menus = 0;
        // 业务回调执行时已发出的系统触觉请求数量。
        int hapticsAtMenu = 0;
        await _mount(
          tester,
          Center(
            child: _surface(
              onTap: () => taps++,
              onLongPressStart: (_) {
                menus++;
                hapticsAtMenu = haptics.length;
              },
            ),
          ),
          platform: platform,
          disableAnimations: reduced,
        );
        await tester.tap(find.byType(OmniPressSurface));
        await tester.pumpAndSettle();
        expect(taps, 1);
        expect(haptics, isEmpty);
        // 尚未达到长按时取消指针，不得产生菜单或振动。
        final TestGesture cancelled = await tester.startGesture(
          tester.getCenter(find.byType(OmniPressSurface)),
        );
        await tester.pump(const Duration(milliseconds: 80));
        await cancelled.cancel();
        await tester.pumpAndSettle();
        expect(menus, 0);
        expect(haptics, isEmpty);
        // 保留原长按阈值，触发时请求一次系统LONG_PRESS反馈。
        final TestGesture pressed = await tester.startGesture(
          tester.getCenter(find.byType(OmniPressSurface)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(haptics, isEmpty);
        await tester.pump(const Duration(milliseconds: 380));
        expect(menus, 1);
        expect(hapticsAtMenu, platform == TargetPlatform.android ? 1 : 0);
        expect(haptics.length, platform == TargetPlatform.android ? 1 : 0);
        if (platform == TargetPlatform.android) {
          expect(haptics.single.arguments, isNull);
        }
        await pressed.up();
        await tester.pumpAndSettle();
        expect(haptics.length, platform == TargetPlatform.android ? 1 : 0);
        expect(taps, 1);
      });
    }
  }

  testWidgets('偏心按下立即扩散并加深，轻缩小不改变占位，短按释放后恢复', (WidgetTester tester) async {
    // 短按与长按的独立业务计数。
    int taps = 0;
    int menus = 0;
    // 用于采样实际画面的渲染边界。
    final GlobalKey boundary = await _mount(
      tester,
      Center(
        child: _surface(onTap: () => taps++, onLongPressStart: (_) => menus++),
      ),
    );
    // 未缩放条目的原始边界。
    final Rect bounds = tester.getRect(find.byType(OmniPressSurface));
    // 非中心触点以及两处不含文字的采样位置。
    final Offset origin = bounds.topLeft + const Offset(18, 60);
    final Offset near = bounds.topLeft + const Offset(25, 60);
    final Offset far = bounds.topLeft + const Offset(295, 60);
    // 手指持续按住，由真实识别器处理短按候选。
    final TestGesture gesture = await tester.startGesture(origin);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // 扩散初期只能改变触点附近，远端仍为实底白色。
    final List<int> early = await _redPixels(tester, boundary, <Offset>[
      near,
      far,
    ]);
    expect(early[0], lessThan(255));
    expect(early[1], 255);
    expect(_scale(tester), allOf(lessThan(1), greaterThan(0.98)));
    expect(tester.getRect(find.byType(OmniPressSurface)), bounds);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_scale(tester), closeTo(0.98, 0.00001));
    await tester.pump(const Duration(milliseconds: 160));
    // 280ms时远角也被覆盖，触点处比初期更深。
    final List<int> full = await _redPixels(tester, boundary, <Offset>[
      near,
      far,
    ]);
    expect(full[0], lessThan(early[0]));
    expect(full[1], full[0]);
    expect(taps, 0);
    expect(menus, 0);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    // 释放过程中半径不倒放，远端仍有同等灰色且逐渐淡出。
    final List<int> fading = await _redPixels(tester, boundary, <Offset>[
      near,
      far,
    ]);
    expect(fading[1], fading[0]);
    expect(fading[0], greaterThan(full[0]));
    expect(_scale(tester), allOf(greaterThan(0.98), lessThan(1)));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_scale(tester), 1);
    expect(await _redPixels(tester, boundary, <Offset>[near, far]), <int>[
      255,
      255,
    ]);
    expect(taps, 1);
    expect(menus, 0);
  });

  testWidgets('长按弹出真实菜单后主动恢复，取消菜单不触发点击且读屏仍能长按', (WidgetTester tester) async {
    // 独立的行内点击和菜单业务计数。
    int taps = 0;
    int selections = 0;
    // 真实语义树用于验证触屏和读屏共用入口。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _mount(
        tester,
        Center(
          child: OmniContextMenu<String>(
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              OmniPopupMenuItem<String>(
                value: 'edit',
                label: '编辑',
                icon: Icons.edit_outlined,
              ),
            ],
            onSelected: (_) => selections++,
            child: Material(
              color: Colors.white,
              child: InkWell(
                onTap: () => taps++,
                highlightColor: Colors.transparent,
                child: const SizedBox(
                  width: 320,
                  height: 120,
                  child: Text('原记录'),
                ),
              ),
            ),
          ),
        ),
      );
      // 菜单路由出现后手指仍未抬起，源条目必须主动恢复。
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(OmniPressSurface)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 520));
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.text('编辑'), findsOneWidget);
      expect(_scale(tester), 1);
      expect(taps, 0);
      await gesture.up();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(selections, 0);
      // 保留外部Semantics的长按操作，不重复创建条目语义。
      final SemanticsNode node = tester.getSemantics(
        find.byType(OmniContextMenu<String>),
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.longPress),
        isTrue,
      );
      tester
          .element(find.byType(OmniContextMenu<String>))
          .findRenderObject()!
          .owner!
          .semanticsOwner!
          .performAction(node.id, SemanticsAction.longPress);
      await tester.pumpAndSettle();
      expect(find.text('编辑'), findsOneWidget);
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(selections, 1);
      expect(taps, 0);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('灰色沿圆角裁剪，缩放后仍命中原尺寸边缘的子控件', (WidgetTester tester) async {
    // 原尺寸内的实底子控件用于检查变换前后的命中。
    const ValueKey<String> contentKey = ValueKey<String>('original-hit-region');
    // 独立像素边界，检查完整扩散后的圆角。
    final GlobalKey boundary = await _mount(
      tester,
      Center(
        child: OmniPressSurface(
          borderRadius: BorderRadius.circular(8),
          child: const Material(
            key: contentKey,
            color: Colors.white,
            child: SizedBox(width: 320, height: 120),
          ),
        ),
      ),
    );
    // 原始占位和按下后的实际可见轮廓。
    final Rect bounds = tester.getRect(find.byType(OmniPressSurface));
    final Rect visible = Rect.fromCenter(
      center: bounds.center,
      width: bounds.width * 0.98,
      height: bounds.height * 0.98,
    );
    // 持续按住直到灰色完整覆盖。
    final TestGesture gesture = await tester.startGesture(bounds.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      await _redPixels(tester, boundary, <Offset>[
        visible.topLeft + const Offset(1, 1),
        visible.topLeft + const Offset(12, 12),
      ]),
      <int>[255, 240],
    );
    // 原边缘已在可见缩放轮廓之外，但仍可命中原子控件。
    final RenderObject content = tester
        .element(find.byKey(contentKey))
        .findRenderObject()!;
    expect(
      tester
          .hitTestOnBinding(bounds.centerLeft + const Offset(1, 0))
          .path
          .any((entry) => entry.target == content),
      isTrue,
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  // 两个方向分别验证滚动识别器赢得手势后取消条目反馈。
  for (final Axis direction in Axis.values) {
    testWidgets('${direction.name}滚动取消反馈且不触发点击或菜单', (
      WidgetTester tester,
    ) async {
      // 记录可能被误触发的业务回调。
      int actions = 0;
      // 检查手势是否真实改变列表位置。
      final ScrollController scroll = ScrollController();
      await _mount(
        tester,
        Center(
          child: SizedBox(
            width: 320,
            height: 120,
            child: SingleChildScrollView(
              controller: scroll,
              scrollDirection: direction,
              child: Flex(
                direction: direction,
                children: <Widget>[
                  _surface(
                    onTap: () => actions++,
                    onLongPressStart: (_) => actions++,
                  ),
                  SizedBox(
                    width: direction == Axis.horizontal ? 1000 : 320,
                    height: direction == Axis.vertical ? 1000 : 120,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // 真实按下先产生反馈，再由拖动赢得手势。
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(OmniPressSurface)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(_scale(tester), lessThan(1));
      await gesture.moveBy(
        direction == Axis.horizontal
            ? const Offset(-60, 0)
            : const Offset(0, -60),
      );
      await gesture.moveBy(
        direction == Axis.horizontal
            ? const Offset(-20, 0)
            : const Offset(0, -20),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(scroll.offset, greaterThan(0));
      expect(_scale(tester), 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(actions, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
    });
  }

  testWidgets('释放过程中连按接续缩放，第二指不重置触点或重复开菜单', (WidgetTester tester) async {
    // 长按只允许第一次有效指针触发业务。
    int menus = 0;
    // 用实际像素检查第二指没有在远端启动新圆形。
    final GlobalKey boundary = await _mount(
      tester,
      Center(child: _surface(onLongPressStart: (_) => menus++)),
    );
    // 两个触点分别位于条目左右。
    final Rect bounds = tester.getRect(find.byType(OmniPressSurface));
    final Offset left = bounds.topLeft + const Offset(18, 60);
    final Offset right = bounds.topLeft + const Offset(295, 60);
    // 第一指启动唯一的长按候选。
    final TestGesture first = await tester.startGesture(left, pointer: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // 第二指不能让右侧立刻变灰。
    final TestGesture second = await tester.startGesture(right, pointer: 2);
    await tester.pump();
    expect((await _redPixels(tester, boundary, <Offset>[right])).single, 255);
    await second.up();
    await tester.pump(const Duration(milliseconds: 100));
    await first.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // 新按下必须从当前视觉缩放接续，不能跳回原尺寸。
    final double current = _scale(tester);
    final TestGesture next = await tester.startGesture(left, pointer: 3);
    await tester.pump();
    expect(_scale(tester), closeTo(current, 0.00001));
    await tester.pump(const Duration(milliseconds: 120));
    expect(_scale(tester), closeTo(0.98, 0.00001));
    await tester.pump(const Duration(milliseconds: 400));
    expect(menus, 1);
    await next.up();
    await tester.pumpAndSettle();
    expect(_scale(tester), 1);
  });

  testWidgets('长按已开始恢复后提前松手，不重新计算180ms恢复时长', (WidgetTester tester) async {
    // 长按业务无需插入新路由，确保仍能收到原指针抬起事件。
    int menus = 0;
    await _mount(
      tester,
      Center(child: _surface(onLongPressStart: (_) => menus++)),
    );
    // 持续按住直到长按开始恢复。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(OmniPressSurface)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_scale(tester), closeTo(0.98, 0.00001));
    await tester.pump(const Duration(milliseconds: 380));
    await tester.pump();
    expect(menus, 1);
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_scale(tester), 1);
  });

  testWidgets('禁用与卸载清理在途反馈，禁用不触发菜单', (WidgetTester tester) async {
    // 可在按住时切换业务提交状态。
    bool enabled = true;
    // 业务状态修改入口。
    late StateSetter update;
    // 记录错误触发的业务操作。
    int actions = 0;
    await _mount(
      tester,
      StatefulBuilder(
        builder: (_, StateSetter setState) {
          update = setState;
          return Center(
            child: _surface(
              enabled: enabled,
              onLongPressStart: (_) => actions++,
            ),
          );
        },
      ),
    );
    // 先启动在途反馈。
    final TestGesture first = await tester.startGesture(
      tester.getCenter(find.byType(OmniPressSurface)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_scale(tester), lessThan(1));
    update(() => enabled = false);
    await tester.pump();
    expect(_scale(tester), 1);
    await first.up();
    await tester.longPress(find.byType(OmniPressSurface));
    expect(actions, 0);
    expect(haptics, isEmpty);
    update(() => enabled = true);
    await tester.pump();
    // 活跃动画中卸载不能留下Ticker或异步异常。
    final TestGesture second = await tester.startGesture(
      tester.getCenter(find.byType(OmniPressSurface)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpWidget(const SizedBox.shrink());
    await second.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  // 六种配色和明暗模式均使用固定中性灰与同一减少动画契约。
  for (final AppThemePalette palette in AppThemePalette.values) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('${palette.name} ${brightness.name}减少动画仅保留静态灰色', (
        WidgetTester tester,
      ) async {
        // 深色表面为黑色，浅色为白色，方便精确验证灰色混合强度。
        final bool dark = brightness == Brightness.dark;
        final GlobalKey boundary = await _mount(
          tester,
          Center(child: _surface(dark: dark)),
          palette: palette,
          brightness: brightness,
          disableAnimations: true,
        );
        // 静态反馈应立即覆盖远离触点的位置。
        final Rect bounds = tester.getRect(find.byType(OmniPressSurface));
        final Offset far = bounds.topLeft + const Offset(295, 60);
        final TestGesture gesture = await tester.startGesture(
          bounds.topLeft + const Offset(18, 60),
        );
        await tester.pump();
        expect(_scale(tester), 1);
        expect(
          (await _redPixels(tester, boundary, <Offset>[far])).single,
          closeTo(dark ? 23 : 240, 1),
        );
        await gesture.up();
        await tester.pump();
        expect(
          (await _redPixels(tester, boundary, <Offset>[far])).single,
          dark ? 0 : 255,
        );
      });
    }
  }

  testWidgets('辅助服务导航不关闭动画，偏好切换在按住期间立即落位', (WidgetTester tester) async {
    // 动态切换系统减少动画偏好。
    bool reduced = false;
    // 修改MediaQuery的状态入口。
    late StateSetter update;
    await _mount(
      tester,
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          update = setState;
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(accessibleNavigation: true, disableAnimations: reduced),
            child: Center(child: _surface()),
          );
        },
      ),
    );
    // 开启辅助服务仍保留原动画。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(OmniPressSurface)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(_scale(tester), lessThan(1));
    update(() => reduced = true);
    await tester.pump();
    expect(_scale(tester), 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows保留右键和长按业务，不产生安卓扩散和缩放', (WidgetTester tester) async {
    // 记录鼠标右键及长按业务次数。
    int secondary = 0;
    int menus = 0;
    await _mount(
      tester,
      Center(
        child: _surface(
          onSecondaryTapUp: (_) => secondary++,
          onLongPressStart: (_) => menus++,
        ),
      ),
      platform: TargetPlatform.windows,
    );
    await tester.tap(
      find.byType(OmniPressSurface),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    expect(secondary, 1);
    // 桌面原有长按业务仍可调用，只是不应用安卓反馈。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(OmniPressSurface)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 280));
    expect(_scale(tester), 1);
    await tester.pump(const Duration(milliseconds: 240));
    expect(menus, 1);
    await gesture.up();
    await tester.pumpAndSettle();
  });
}

/// 生产共享组件配合真实实底Material，避免假透明内容掩盖绘制错误。
Widget _surface({
  bool enabled = true,
  bool dark = false,
  GestureTapCallback? onTap,
  GestureTapUpCallback? onSecondaryTapUp,
  GestureLongPressStartCallback? onLongPressStart,
}) => OmniPressSurface(
  enabled: enabled,
  borderRadius: BorderRadius.circular(8),
  onTap: onTap,
  onSecondaryTapUp: onSecondaryTapUp,
  onLongPressStart: onLongPressStart,
  child: Material(
    color: dark ? Colors.black : Colors.white,
    child: const SizedBox(width: 320, height: 120),
  ),
);

/// 挂载确定的主题与系统偏好，返回独立像素采样边界。
Future<GlobalKey> _mount(
  WidgetTester tester,
  Widget child, {
  TargetPlatform platform = TargetPlatform.android,
  Brightness brightness = Brightness.light,
  AppThemePalette palette = AppThemePalette.classicBlue,
  bool disableAnimations = false,
}) async {
  // 每个场景独占完整测试画面。
  final GlobalKey boundary = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(
        brightness: brightness,
        palette: palette,
      ).copyWith(platform: platform),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: RepaintBoundary(key: boundary, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return boundary;
}

/// 读取条目当前可见缩放，另用像素验证真实绘制结果。
double _scale(WidgetTester tester) {
  // 共享表面最外层的可见变换。
  final Transform transform = tester.widget<Transform>(
    find
        .descendant(
          of: find.byType(OmniPressSurface),
          matching: find.byType(Transform),
        )
        .first,
  );
  return transform.transform.storage[0];
}

/// 在真实渲染图像上采样红色通道，所有测试表面和扩散层均为中性灰。
Future<List<int>> _redPixels(
  WidgetTester tester,
  GlobalKey key,
  List<Offset> positions,
) async {
  // 画面坐标的独立渲染边界。
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    // 捕获当前帧，不推进假时钟。
    final ui.Image image = await boundary.toImage();
    try {
      // RGBA无损像素用于验证灰色扩散位置和加深程度。
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return positions.map((Offset global) {
        // 将屏幕点投影到截图中的逻辑像素。
        final Offset local = boundary.globalToLocal(global);
        return bytes.getUint8(
          (local.dy.floor() * image.width + local.dx.floor()) * 4,
        );
      }).toList();
    } finally {
      image.dispose();
    }
  }))!;
}
