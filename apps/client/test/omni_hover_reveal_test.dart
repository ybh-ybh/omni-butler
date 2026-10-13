import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证共享图标规范覆盖普通按钮、菜单入口及反向渐隐。
void main() {
  testWidgets('Windows六套明暗图标与菜单共享28dp背景及36dp热区', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // 同一指针逐个验证普通图标和菜单按钮。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    for (final AppThemePalette palette in AppThemePalette.values) {
      for (final Brightness brightness in Brightness.values) {
        // 当前配色的按钮反馈与正文颜色。
        final ThemeData theme = AppTheme.build(
          brightness: brightness,
          palette: palette,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OmniIconButton(
                      key: const ValueKey('ordinary'),
                      tooltip: '普通操作',
                      icon: const Icon(Icons.menu),
                      onPressed: () {},
                    ),
                    OmniPopupMenuButton<String>(
                      key: const ValueKey('popup'),
                      tooltip: '菜单操作',
                      itemBuilder: (_) => [
                        OmniPopupMenuItem(
                          value: 'edit',
                          label: '编辑',
                          icon: Icons.edit,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        // 本轮普通图标和菜单入口必须同大、无额外内边距且字形居中。
        final OmniColors colors = theme.extension<OmniColors>()!;
        for (final String key in ['ordinary', 'popup']) {
          // 每个图标的可见背景及字形由真实布局测量。
          final Finder button = find.byKey(ValueKey(key));
          // Icon的RenderBox可能是整个按钮，RichText才是字形绘制范围。
          final Finder glyph = find.descendant(
            of: button,
            matching: find.byType(RichText),
          );
          expect(
            tester.getSize(button),
            const Size.square(OmniSize.iconButton),
          );
          expect(tester.getCenter(glyph), tester.getCenter(button));
          expect(
            (tester.widget<RichText>(glyph).text as TextSpan).style!.color,
            colors.muted,
          );
          await mouse.moveTo(tester.getCenter(button));
          await tester.pumpAndSettle();
          expect(
            (tester.widget<RichText>(glyph).text as TextSpan).style!.color,
            colors.ink,
          );
          // 两类按钮的实际状态样式沿用同一种悬停背景。
          final IconButton native = tester.widget<IconButton>(
            find.descendant(of: button, matching: find.byType(IconButton)),
          );
          expect(
            native.style!.padding!.resolve({WidgetState.hovered}),
            EdgeInsets.zero,
          );
          expect(
            native.style!.fixedSize!.resolve({WidgetState.hovered}),
            const Size.square(OmniSize.iconButton),
          );
          // 检查真实绘制轮廓，缩小背景不能改变图标或热区中心。
          final OutlinedBorder shape = native.style!.shape!.resolve({
            WidgetState.hovered,
          })!;
          expect(
            shape.getOuterPath(const Rect.fromLTWH(0, 0, 36, 36)).getBounds(),
            const Rect.fromLTWH(4, 4, 28, 28),
          );
          expect(
            shape
                .scale(0.5)
                .getOuterPath(const Rect.fromLTWH(0, 0, 36, 36))
                .getBounds(),
            const Rect.fromLTWH(4, 4, 28, 28),
          );
          // 小嵌入按钮不继续内缩，以免裁切18dp字形。
          expect(
            shape.getOuterPath(const Rect.fromLTWH(0, 0, 20, 20)).getBounds(),
            const Rect.fromLTWH(0, 0, 20, 20),
          );
          // 原生按钮主题与共享菜单沿用同一背景轮廓。
          expect(
            theme.iconButtonTheme.style!.shape!
                .resolve({WidgetState.hovered})!
                .getOuterPath(const Rect.fromLTWH(0, 0, 36, 36))
                .getBounds(),
            const Rect.fromLTWH(4, 4, 28, 28),
          );
          await mouse.moveTo(Offset.zero);
          await tester.pumpAndSettle();
        }
      }
    }
    await mouse.removePointer();
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('渐隐共享120ms且中途反向连续，隐藏立即停用命中及焦点', (tester) async {
    // 外部可见目标模拟快速进出按钮所属区域。
    final ValueNotifier<bool> visible = ValueNotifier(false);
    // 统计隐藏阶段是否误触。
    int taps = 0;
    // 用于验证隐藏时不会被程序请求焦点。
    final FocusNode focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, value, _) => OmniHoverReveal(
                visible: value,
                child: OmniIconButton(
                  tooltip: '渐隐入口',
                  focusNode: focus,
                  icon: const Icon(Icons.menu),
                  onPressed: () => taps++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 保存初始布局位置，渐隐不能使相邻控件跳动。
    final Rect bounds = tester.getRect(find.byType(OmniHoverReveal));
    expect(find.byTooltip('渐隐入口').hitTestable(), findsNothing);
    visible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    // 读取实际绘制的透明度，不能仅断言目标值。
    final FadeTransition fade = tester.widget<FadeTransition>(
      find.descendant(
        of: find.byType(OmniHoverReveal),
        matching: find.byType(FadeTransition),
      ),
    );
    final double halfway = fade.opacity.value;
    expect(halfway, allOf(greaterThan(0), lessThan(1)));
    visible.value = false;
    await tester.pump();
    expect(fade.opacity.value, closeTo(halfway, 0.001));
    expect(find.byTooltip('渐隐入口').hitTestable(), findsNothing);
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    await tester.tapAt(bounds.center);
    expect(taps, 0);
    visible.value = true;
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('渐隐入口'));
    expect(taps, 1);
    expect(tester.getRect(find.byType(OmniHoverReveal)), bounds);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).duration,
      OmniMotion.fast,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    visible.dispose();
    focus.dispose();
  });

  testWidgets('减少动画时显隐即时切换而Android保持48dp热区', (tester) async {
    // 可见目标用于验证零时长切换。
    final ValueNotifier<bool> visible = ValueNotifier(false);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.android),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(
              child: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, value, _) => OmniHoverReveal(
                  visible: value,
                  child: OmniIconButton(
                    tooltip: '手机操作',
                    icon: const Icon(Icons.menu),
                    onPressed: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).duration,
      Duration.zero,
    );
    visible.value = true;
    await tester.pumpAndSettle();
    expect(find.byTooltip('手机操作').hitTestable(), findsOneWidget);
    expect(
      tester.getSize(find.byType(IconButton)).height,
      greaterThanOrEqualTo(OmniSize.touch),
    );
    visible.value = false;
    await tester.pumpAndSettle();
    expect(find.byTooltip('手机操作').hitTestable(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    visible.dispose();
  });
}
