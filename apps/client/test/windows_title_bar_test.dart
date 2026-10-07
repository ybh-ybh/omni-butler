import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_chrome_colors.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/features/floating/presentation/windows_title_bar.dart';

/// 使用浅色模式也需要白字的远山色，覆盖按实际背景选择前景的场景。
final OmniChromeColors _colors = OmniChromeColors.fromBackground(
  const Color(0xFF4872AD),
);

/// 验证独立标题栏的布局、窗口操作和交互反馈。
void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('没有 MaterialApp 和 Overlay 时可显示主题色与窗口语义', (
    WidgetTester tester,
  ) async {
    // 本次测试使用的无障碍树句柄。
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pumpTitleBar(tester);

    // 标题栏实际绘制的 Material 背景。
    final Material material = tester.widget<Material>(
      find.byKey(const ValueKey<String>('windows-title-bar')),
    );
    expect(material.color, _colors.background);
    expect(tester.getSize(find.byType(WindowsTitleBar)), const Size(600, 28));
    // 标题经过 DefaultTextStyle 合成后的真实文字样式。
    final RichText title = tester.widget<RichText>(
      find.descendant(
        of: find.text('Omni Butler'),
        matching: find.byType(RichText),
      ),
    );
    expect(title.text.style?.color, _colors.foreground);
    expect(title.text.style?.fontSize, 12);
    expect(find.bySemanticsLabel('最小化'), findsOneWidget);
    expect(find.bySemanticsLabel('最大化'), findsOneWidget);
    expect(find.bySemanticsLabel('关闭'), findsOneWidget);
    // 原生按钮命中区依赖固定的三个等宽区域。
    for (final String action in <String>['minimize', 'maximize', 'close']) {
      expect(
        tester.getSize(
          find.byKey(ValueKey<String>('windows-title-bar-$action')),
        ),
        const Size(46, 28),
      );
    }
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('按钮调用窗口操作并根据最大化状态切换还原入口', (WidgetTester tester) async {
    // 记录实际用户点击触发的窗口动作。
    final List<String> actions = <String>[];
    await _pumpTitleBar(
      tester,
      onMinimize: () => actions.add('minimize'),
      onToggleMaximize: () => actions.add('maximize'),
      onClose: () => actions.add('close'),
    );
    expect(find.byIcon(Icons.crop_square), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('windows-title-bar-minimize')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('windows-title-bar-maximize')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('windows-title-bar-close')),
    );
    expect(actions, <String>['minimize', 'maximize', 'close']);

    await _pumpTitleBar(
      tester,
      maximized: true,
      onToggleMaximize: () => actions.add('restore'),
    );
    expect(find.byIcon(Icons.filter_none), findsOneWidget);
    expect(find.byIcon(Icons.crop_square), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('windows-title-bar-maximize')),
    );
    expect(actions.last, 'restore');
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭按钮悬停为红底白字且不需要 Tooltip 覆盖层', (WidgetTester tester) async {
    await _pumpTitleBar(tester);
    // 用真实鼠标事件验证标题栏外部无需提供 Overlay。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey<String>('windows-title-bar-close')),
      ),
    );
    await tester.pumpAndSettle();
    // 关闭按钮的实际绘制底色。
    final Material closeMaterial = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('windows-title-bar-close')),
        matching: find.byType(Material),
      ),
    );
    expect(closeMaterial.color, ThemeData().colorScheme.error);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.close)).color,
      ThemeData().colorScheme.onError,
    );
    expect(find.byType(Tooltip), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // 每种配色都经过实际鼠标事件与焦点事件，防止只有颜色计算正确。
  for (final AppThemePalette palette in AppThemePalette.values) {
    // 浅色页面中也可能出现深色标题栏，因此分别覆盖两种明暗模式。
    for (final Brightness brightness in Brightness.values) {
      testWidgets('${palette.label} ${brightness.name} 窗口按钮悬停与焦点清晰可读', (
        WidgetTester tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        // 当前 Windows 主题与真实标题栏配色。
        final ThemeData theme = AppTheme.build(
          brightness: brightness,
          palette: palette,
        );
        // 标题栏及导航共享的配色扩展。
        final OmniChromeColors colors = theme.extension<OmniChromeColors>()!;
        await _pumpTitleBar(tester, theme: theme, colors: colors);
        // 按钮通过真实鼠标进入和离开事件切换悬停状态。
        final TestGesture mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(10, 50));

        // 普通按钮与关闭按钮均覆盖鼠标和键盘焦点反馈。
        for (final String action in <String>['minimize', 'maximize', 'close']) {
          // 当前待操作按钮的完整区域。
          final Finder button = find.byKey(
            ValueKey<String>('windows-title-bar-$action'),
          );
          await mouse.moveTo(tester.getCenter(button));
          await tester.pumpAndSettle();
          _expectReadableFeedback(
            tester,
            button: button,
            theme: theme,
            colors: colors,
            isClose: action == 'close',
          );
          // 鼠标离开后再单独验证焦点，不能用悬停掩盖焦点样式缺失。
          await mouse.moveTo(const Offset(10, 50));
          await tester.pumpAndSettle();
          // 图标的祖先 Focus 正是 InkWell 使用的真实焦点节点。
          final FocusNode focus = Focus.of(
            tester.element(
              find.descendant(of: button, matching: find.byType(Icon)),
            ),
          );
          focus.requestFocus();
          await tester.pumpAndSettle();
          expect(focus.hasFocus, isTrue);
          _expectReadableFeedback(
            tester,
            button: button,
            theme: theme,
            colors: colors,
            isClose: action == 'close',
          );
          focus.unfocus();
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}

/// 验证实际呈现的底色足够明显，图标及按压状态仍然可读。
void _expectReadableFeedback(
  WidgetTester tester, {
  required Finder button,
  required ThemeData theme,
  required OmniChromeColors colors,
  required bool isClose,
}) {
  // 控制按钮实际使用的背景材质。
  final Material material = tester.widget<Material>(
    find.descendant(of: button, matching: find.byType(Material)),
  );
  // 窗口操作图标的实际前景色。
  final Icon icon = tester.widget<Icon>(
    find.descendant(of: button, matching: find.byType(Icon)),
  );
  if (isClose) {
    expect(material.color, theme.colorScheme.error);
    expect(icon.color, theme.colorScheme.onError);
  } else {
    // 普通状态的底色必须明显区别于标题栏，防止再次出现近乎无反馈。
    expect(_contrast(material.color!, colors.background), greaterThan(1.2));
    expect(icon.color, colors.foreground);
  }
  expect(_contrast(icon.color!, material.color!), greaterThanOrEqualTo(4.5));
  // 按压使用真实 InkWell 叠层，不能削弱关闭按钮红底上的浅色图标。
  final InkWell ink = tester.widget<InkWell>(
    find.descendant(of: button, matching: find.byType(InkWell)),
  );
  expect(
    _contrast(
      icon.color!,
      Color.alphaBlend(ink.highlightColor!, material.color!),
    ),
    greaterThanOrEqualTo(4.5),
  );
}

/// 根据相对亮度计算两种实际颜色之间的对比度。
double _contrast(Color foreground, Color background) {
  // 图标或待比较颜色的亮度。
  final double foregroundLuminance = foreground.computeLuminance();
  // 按钮或标题栏背景的亮度。
  final double backgroundLuminance = background.computeLuminance();
  return foregroundLuminance > backgroundLuminance
      ? (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05)
      : (backgroundLuminance + 0.05) / (foregroundLuminance + 0.05);
}

/// 仅提供窗口宿主承诺的 Theme、Directionality 和 MediaQuery。
Future<void> _pumpTitleBar(
  WidgetTester tester, {
  bool maximized = false,
  ThemeData? theme,
  OmniChromeColors? colors,
  VoidCallback onMinimize = _ignoreAction,
  VoidCallback onToggleMaximize = _ignoreAction,
  VoidCallback onClose = _ignoreAction,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: Size(600, 100)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: theme ?? ThemeData(),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 600,
              child: WindowsTitleBar(
                colors: colors ?? _colors,
                maximized: maximized,
                onMinimize: onMinimize,
                onToggleMaximize: onToggleMaximize,
                onClose: onClose,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 非当前测试关注的窗口操作保持空实现。
void _ignoreAction() {}
