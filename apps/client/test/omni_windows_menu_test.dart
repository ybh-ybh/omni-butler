import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_dropdown.dart';
import 'package:omni_butler/shared/ui/omni_menu_route.dart';
import 'package:omni_butler/shared/ui/omni_press_feedback.dart';

/// 测试中稳定定位完整菜单面板。
const ValueKey<String> _surfaceKey = ValueKey<String>(
  'omni-windows-menu-surface',
);

/// 测试中稳定定位面板的绘制缩放。
const ValueKey<String> _scaleKey = ValueKey<String>('omni-windows-menu-scale');

/// 构建正常、危险、禁用三个操作，保证测试使用真实菜单项实现。
List<PopupMenuEntry<String>> _defaultItems(BuildContext context) =>
    <PopupMenuEntry<String>>[
      OmniPopupMenuItem<String>(
        value: 'edit',
        label: '编辑',
        icon: Icons.edit_outlined,
      ),
      OmniPopupMenuItem<String>(
        value: 'delete',
        label: '删除',
        icon: Icons.delete_outline,
        danger: true,
      ),
      OmniPopupMenuItem<String>(
        value: 'disabled',
        label: '不可用',
        icon: Icons.block,
        enabled: false,
      ),
    ];

/// 创建不连接业务数据的 Windows 菜单测试宿主。
Future<void> _pumpMenu(
  WidgetTester tester, {
  ValueChanged<String>? onSelected,
  PopupMenuItemBuilder<String> itemBuilder = _defaultItems,
  String? initialValue,
  Alignment alignment = Alignment.center,
  bool reduceMotion = false,
  TargetPlatform platform = TargetPlatform.windows,
  Brightness brightness = Brightness.light,
  AppThemePalette palette = AppThemePalette.classicBlue,
  double textScale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.build(
      brightness: brightness,
      palette: palette,
    ).copyWith(platform: platform),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: Scaffold(
      body: Align(
        alignment: alignment,
        child: OmniPopupMenuButton<String>(
          initialValue: initialValue,
          tooltip: '操作菜单',
          itemBuilder: itemBuilder,
          onSelected: onSelected,
        ),
      ),
    ),
  ),
);

/// 读取某一菜单行当前动画目标背景，不混入触发器反馈。
Color? _rowColor(WidgetTester tester, String label) {
  // 包含指定标签的真实菜单项。
  final Finder item = find.ancestor(
    of: find.text(label),
    matching: find.byType(OmniPopupMenuItem<String>),
  );
  // 行级背景容器位于按压内容之外。
  final AnimatedContainer background = tester.widget<AnimatedContainer>(
    find.descendant(of: item, matching: find.byType(AnimatedContainer)).first,
  );
  return (background.decoration! as BoxDecoration).color;
}

/// 读取实际绘制的插值颜色，避免只检查 AnimatedContainer 的目标值。
Color _rowPaintColor(WidgetTester tester, String label) {
  // 指定标签所在的菜单行。
  final Finder row = find.ancestor(
    of: find.text(label),
    matching: find.byType(OmniPopupMenuItem<String>),
  );
  // AnimatedContainer 每帧生成的真正背景绘制配置。
  final DecoratedBox background = tester.widget<DecoratedBox>(
    find.descendant(of: row, matching: find.byType(DecoratedBox)).first,
  );
  return (background.decoration as BoxDecoration).color!;
}

/// 退场颜色合成后必须处于原悬停色和面板色之间，不能短暂变暗或变色。
void _expectHoverFade(Color current, Color hover, Color paper) {
  // 真实背景合成后的当前像素色。
  final Color displayed = Color.alphaBlend(current, paper);
  // 完整悬停状态在当前面板上的像素色。
  final Color highlighted = Color.alphaBlend(hover, paper);
  // 逐通道允许一个八位颜色量化误差。
  for (final (double value, double start, double end) channel
      in <(double, double, double)>[
        (displayed.r, highlighted.r, paper.r),
        (displayed.g, highlighted.g, paper.g),
        (displayed.b, highlighted.b, paper.b),
      ]) {
    expect(
      channel.$1,
      inInclusiveRange(
        math.min(channel.$2, channel.$3) - 1 / 255,
        math.max(channel.$2, channel.$3) + 1 / 255,
      ),
    );
  }
}

/// 复现分类颜色按钮的语义包装与三十二像素自定义热区。
Widget _customTriggerChild(String prefix) => Semantics(
  button: true,
  label: '修改颜色',
  child: SizedBox(
    key: ValueKey<String>('$prefix-content'),
    width: 32,
    height: 32,
    child: Center(
      child: SizedBox(
        key: ValueKey<String>('$prefix-circle'),
        width: 18,
        height: 18,
        child: const ColoredBox(color: Colors.blue),
      ),
    ),
  ),
);

/// 在相同前后间距中比较新旧菜单入口的实际布局。
Widget _customTriggerRow(String prefix, Widget trigger) => Row(
  mainAxisSize: MainAxisSize.min,
  children: <Widget>[
    const SizedBox(width: 44),
    trigger,
    const SizedBox(width: 12),
    Text('标签名称', key: ValueKey<String>('$prefix-label')),
  ],
);

/// 验证 Windows 菜单的整体动效、行状态与导航契约。
void main() {
  testWidgets('菜单项右键按住只压缩内容且不选择或关闭菜单', (tester) async {
    // 右键不能改变原有业务返回值。
    String? selection;
    await _pumpMenu(tester, onSelected: (String value) => selection = value);
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pumpAndSettle();
    // 完整菜单背景在右键期间保持固定。
    final Rect original = tester.getRect(find.byKey(_surfaceKey));
    // 指定行拥有唯一的按压内容层。
    final Finder row = find.ancestor(
      of: find.text('编辑'),
      matching: find.byType(OmniPopupMenuItem<String>),
    );
    // 当前实际绘制的内容变换。
    final Finder transform = find
        .descendant(
          of: find.descendant(of: row, matching: find.byType(OmniPressContent)),
          matching: find.byType(Transform),
        )
        .first;
    // 按住右键必须与左键一样显示内容收缩。
    final TestGesture pointer = await tester.startGesture(
      tester.getCenter(find.text('编辑')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 90));
    expect(
      tester.widget<Transform>(transform).transform.storage[0],
      closeTo(0.97, 0.00001),
    );
    expect(tester.getRect(find.byKey(_surfaceKey)), original);
    await pointer.up();
    await tester.pumpAndSettle();
    expect(selection, isNull);
    expect(find.byKey(_surfaceKey), findsOneWidget);
    expect(tester.widget<Transform>(transform).transform.storage[0], 1);
  });

  testWidgets('明暗菜单逐帧切换hover不闪黑且快速往返保持颜色连续', (tester) async {
    // 两种明暗模式都检查真实插值帧。
    for (final Brightness brightness in Brightness.values) {
      await _pumpMenu(tester, brightness: brightness);
      await tester.tap(find.byTooltip('操作菜单'));
      await tester.pumpAndSettle();
      // 当前菜单使用的主题语义色。
      final OmniColors colors = OmniColors.of(tester.element(find.text('编辑')));
      // 与录屏一致，通过真实鼠标反复在相邻行之间移动。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('编辑')));
      await tester.pumpAndSettle();
      // 每次离开行的中间帧都必须位于两端颜色范围内。
      for (int move = 0; move < 6; move += 1) {
        await mouse.moveTo(
          tester.getCenter(find.text(move.isEven ? '删除' : '编辑')),
        );
        await tester.pump();
        // 部分往返故意在动画完成前发生。
        for (int frame = 0; frame < (move.isEven ? 3 : 8); frame += 1) {
          await tester.pump(const Duration(milliseconds: 16));
          _expectHoverFade(
            _rowPaintColor(tester, '编辑'),
            colors.paperSubtle,
            colors.paper,
          );
          _expectHoverFade(
            _rowPaintColor(tester, '删除'),
            colors.danger.withValues(alpha: 0.10),
            colors.paper,
          );
        }
      }
      await mouse.removePointer();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('全部配色明暗大字号长菜单保持边界且初始项可键盘选择', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 逐套主题检查真实长菜单，而非只检查主题配置。
    for (final AppThemePalette palette in AppThemePalette.values) {
      // 明暗均使用相同的窗口和放大文字。
      for (final Brightness brightness in Brightness.values) {
        // 只有键盘确认后才能记录选择。
        String? selection;
        await _pumpMenu(
          tester,
          palette: palette,
          brightness: brightness,
          textScale: 1.6,
          alignment: Alignment.bottomRight,
          initialValue: '25',
          onSelected: (String value) => selection = value,
          itemBuilder: (context) => <PopupMenuEntry<String>>[
            // 足够长的选项用于验证滚动和初始焦点定位。
            for (int index = 0; index < 30; index += 1)
              OmniPopupMenuItem<String>(
                value: '$index',
                label: '操作$index',
                icon: Icons.edit_outlined,
              ),
          ],
        );
        await tester.tap(find.byTooltip('操作菜单'));
        await tester.pumpAndSettle();
        // 面板必须遵循当前主题且完整位于窗口内。
        final Material surface = tester.widget<Material>(
          find.byKey(_surfaceKey),
        );
        // 最终尺寸与命中边界不受文本缩放和滚动影响。
        final Rect bounds = tester.getRect(find.byKey(_surfaceKey));
        expect(
          surface.color,
          OmniColors.of(tester.element(find.byKey(_surfaceKey))).paper,
        );
        expect(bounds.left, greaterThanOrEqualTo(8));
        expect(bounds.top, greaterThanOrEqualTo(8));
        expect(bounds.right, lessThanOrEqualTo(352));
        expect(bounds.bottom, lessThanOrEqualTo(472));
        expect(find.text('操作25').hitTestable(), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selection, '25');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('自定义32像素菜单触发器与原生布局一致', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _customTriggerRow(
                'native',
                PopupMenuButton<String>(
                  key: const ValueKey<String>('native-trigger'),
                  tooltip: '原生颜色菜单',
                  padding: const EdgeInsets.all(OmniSpacing.xs),
                  itemBuilder: _defaultItems,
                  child: _customTriggerChild('native'),
                ),
              ),
              _customTriggerRow(
                'omni',
                OmniPopupMenuButton<String>(
                  key: const ValueKey<String>('omni-trigger'),
                  tooltip: '统一颜色菜单',
                  itemBuilder: _defaultItems,
                  child: _customTriggerChild('omni'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // 原生自定义入口忽略图标按钮最小尺寸，统一入口必须保留同一热区。
    final Rect nativeTrigger = tester.getRect(
      find.byKey(const ValueKey<String>('native-trigger')),
    );
    // 新入口的布局矩形不应随按压绘制缩放扩大或缩小。
    final Rect omniTrigger = tester.getRect(
      find.byKey(const ValueKey<String>('omni-trigger')),
    );
    expect(nativeTrigger.size, const Size.square(32));
    expect(omniTrigger.size, nativeTrigger.size);
    expect(omniTrigger.left, nativeTrigger.left);
    expect(
      tester.getCenter(find.byKey(const ValueKey<String>('omni-circle'))).dx,
      tester.getCenter(find.byKey(const ValueKey<String>('native-circle'))).dx,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<String>('omni-label'))).dx,
      tester.getTopLeft(find.byKey(const ValueKey<String>('native-label'))).dx,
    );
    await tester.tap(find.byTooltip('统一颜色菜单'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('omni-trigger'))),
      omniTrigger,
    );
  });

  testWidgets('完整面板在动画中尺寸固定且条目同时出现', (WidgetTester tester) async {
    await _pumpMenu(tester);
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pump();
    // 面板布局一次即使用最终尺寸。
    final Size openingSize = tester.getSize(find.byKey(_surfaceKey));
    await tester.pump(const Duration(milliseconds: 75));
    // 半程只改变绘制比例，不改变菜单的最终布局尺寸。
    final ScaleTransition transition = tester.widget<ScaleTransition>(
      find.byKey(_scaleKey),
    );
    expect(transition.scale.value, greaterThan(OmniMotion.windowsMenuScale));
    expect(transition.scale.value, lessThan(1));
    expect(tester.getSize(find.byKey(_surfaceKey)), openingSize);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(_surfaceKey),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_surfaceKey)), openingSize);
    expect(
      tester.widget<ScaleTransition>(find.byKey(_scaleKey)).scale.value,
      1,
    );
  });

  testWidgets('退出保留淡出画面但立即停止菜单交互', (WidgetTester tester) async {
    // 一次点击只能提交一次菜单操作。
    int selections = 0;
    await _pumpMenu(tester, onSelected: (_) => selections += 1);
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pumpAndSettle();
    // 保存将要消失条目的位置，退出期间继续点按相同位置。
    final Offset itemPosition = tester.getCenter(find.text('编辑'));
    await tester.tapAt(itemPosition);
    await tester.pump();
    expect(selections, 1);
    expect(find.byKey(_surfaceKey), findsOneWidget);
    // 只检查面板外的交互屏蔽器，不依赖路由内部组件结构。
    final Iterable<IgnorePointer> blockers = tester.widgetList<IgnorePointer>(
      find.ancestor(
        of: find.byKey(_surfaceKey),
        matching: find.byType(IgnorePointer),
      ),
    );
    expect(blockers.any((IgnorePointer blocker) => blocker.ignoring), isTrue);
    await tester.tapAt(itemPosition);
    await tester.pump(const Duration(milliseconds: 60));
    expect(selections, 1);
    expect(
      tester.widget<ScaleTransition>(find.byKey(_scaleKey)).scale.value,
      lessThan(1),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_surfaceKey), findsNothing);
  });

  testWidgets('鼠标只高亮当前行且危险与禁用状态独立', (WidgetTester tester) async {
    // 禁用菜单项不得触发业务回调。
    String? selection;
    await _pumpMenu(tester, onSelected: (String value) => selection = value);
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pumpAndSettle();
    // 当前主题提供普通及危险悬停色。
    final OmniColors colors = OmniColors.of(tester.element(find.text('编辑')));
    // 使用真正的鼠标悬停事件，避免触摸点击模拟 hover。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('编辑')));
    await tester.pumpAndSettle();
    expect(_rowColor(tester, '编辑'), colors.paperSubtle);
    expect(_rowColor(tester, '删除')!.a, 0);
    await mouse.moveTo(tester.getCenter(find.text('删除')));
    await tester.pumpAndSettle();
    expect(_rowColor(tester, '编辑')!.a, 0);
    expect(_rowColor(tester, '删除'), colors.danger.withValues(alpha: 0.10));
    await mouse.moveTo(tester.getCenter(find.text('不可用')));
    await tester.pumpAndSettle();
    expect(_rowColor(tester, '删除')!.a, 0);
    expect(_rowColor(tester, '不可用')!.a, 0);
    await tester.tap(find.text('不可用'));
    await tester.pumpAndSettle();
    expect(selection, isNull);
    expect(find.byKey(_surfaceKey), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('Escape恢复按钮焦点且键盘按初始项选择', (WidgetTester tester) async {
    // 键盘提交返回原有菜单值。
    String? selection;
    await _pumpMenu(
      tester,
      initialValue: 'delete',
      onSelected: (String value) => selection = value,
    );
    // 真实键盘入口先通过 Tab 聚焦，鼠标打开不应主动抢焦点。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(_surfaceKey), findsNothing);
    expect(selection, isNull);
    // 不用鼠标再次定位，直接用已恢复焦点的触发器打开。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(_surfaceKey), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selection, 'delete');
  });

  testWidgets('方向键跳过禁用项且菜单保持窗口边界内', (WidgetTester tester) async {
    // 最终选择用于验证方向键停靠点。
    String? selection;
    await _pumpMenu(
      tester,
      alignment: Alignment.bottomRight,
      onSelected: (String value) => selection = value,
    );
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pumpAndSettle();
    // 完整面板必须留在当前测试窗口的八像素安全边界内。
    final Rect panel = tester.getRect(find.byKey(_surfaceKey));
    expect(panel.left, greaterThanOrEqualTo(8));
    expect(panel.top, greaterThanOrEqualTo(8));
    expect(panel.right, lessThanOrEqualTo(792));
    expect(panel.bottom, lessThanOrEqualTo(592));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_rowColor(tester, '编辑')!.a, 0);
    expect(_rowColor(tester, '删除')!.a, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selection, 'edit');
  });

  testWidgets('自定义多行内容与嵌套颜色操作保留原返回值', (WidgetTester tester) async {
    // 自定义菜单仍通过同一个 Navigator 返回值。
    String? selection;
    await _pumpMenu(
      tester,
      onSelected: (String value) => selection = value,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        const OmniPopupMenuItem<String>.custom(
          value: 'switch',
          height: 68,
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[Text('切换分区'), Text('保留完整说明')],
          ),
        ),
        PopupMenuItem<String>(
          enabled: false,
          child: Builder(
            builder: (BuildContext menuContext) => TextButton(
              onPressed: () => Navigator.of(menuContext).pop('color'),
              child: const Text('选择颜色'),
            ),
          ),
        ),
      ],
    );
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pumpAndSettle();
    expect(find.text('保留完整说明'), findsOneWidget);
    await tester.tap(find.text('切换分区'));
    await tester.pumpAndSettle();
    expect(selection, 'switch');
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择颜色'));
    await tester.pumpAndSettle();
    expect(selection, 'color');
  });

  testWidgets('减少动画直接落位且Android仍使用原生菜单', (WidgetTester tester) async {
    await _pumpMenu(tester, reduceMotion: true);
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pump();
    expect(
      tester.widget<ScaleTransition>(find.byKey(_scaleKey)).scale.value,
      1,
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(_surfaceKey), findsNothing);
    await _pumpMenu(tester, platform: TargetPlatform.android);
    // 主题平台也参与 AnimatedTheme 过渡，完成后才应验证 Android 入口。
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pumpAndSettle();
    expect(find.byKey(_surfaceKey), findsNothing);
    expect(find.text('编辑'), findsOneWidget);
  });

  testWidgets('触发器卸载及窗口变化不访问失效的菜单锚点', (WidgetTester tester) async {
    await _pumpMenu(tester);
    await tester.tap(find.byTooltip('操作菜单'));
    await tester.pumpAndSettle();
    // 平台切换会卸载 Windows 触发器，但菜单路由仍可继续显示与关闭。
    await _pumpMenu(tester, platform: TargetPlatform.android);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 在原锚点离树后再次强制路由布局，覆盖尺寸变化的延迟回调。
    tester.view.physicalSize = const Size(640, 480);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(_surfaceKey), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(_surfaceKey), findsNothing);
  });

  testWidgets('直接上下文入口使用同样菜单并在外部点击后取消', (WidgetTester tester) async {
    // 只记录用户显式选择，外部关闭应返回空值。
    String? selection = '未关闭';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                selection = await showOmniMenu<String>(
                  context: context,
                  position: const RelativeRect.fromLTRB(100, 100, 700, 500),
                  items: _defaultItems(context),
                );
              },
              child: const Text('上下文菜单'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('上下文菜单'));
    await tester.pumpAndSettle();
    expect(find.byKey(_surfaceKey), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(selection, isNull);
  });
}
