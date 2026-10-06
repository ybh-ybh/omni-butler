import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 验证统一品牌主题的关键 Token 与组件轮廓。
void main() {
  // 每一款配色都覆盖明暗模式，经典蓝仍由原有精确色值测试保护。
  for (final AppThemePalette palette in AppThemePalette.values) {
    // 独立验证浅色和深色配色。
    for (final Brightness brightness in Brightness.values) {
      test('${palette.label} ${brightness.name} 保留业务语义与可读色对', () {
        // 当前配色对应的应用主题。
        final ThemeData theme = AppTheme.build(
          brightness: brightness,
          palette: palette,
        );
        // 原有业务颜色作为兼容性参照。
        final OmniColors original = AppTheme.build(brightness: brightness)
            .extension<OmniColors>()!;
        // 当前配色的扩展语义色。
        final OmniColors colors = theme.extension<OmniColors>()!;
        expect(colors.success, original.success);
        expect(colors.warning, original.warning);
        expect(colors.danger, original.danger);
        expect(colors.info, original.info);
        expect(colors.todo, original.todo);
        expect(colors.event, original.event);
        expect(colors.item, original.item);
        expect(colors.time, original.time);
        expect(colors.member, original.member);
        expect(theme.colorScheme.onError, Colors.white);
        expect(
          _contrast(theme.colorScheme.onError, theme.colorScheme.error),
          greaterThanOrEqualTo(4.6),
          reason: '${palette.label} ${brightness.name} 的危险填色应承载白字',
        );
        expect(
          _contrast(theme.colorScheme.onPrimary, theme.colorScheme.primary),
          greaterThanOrEqualTo(4.6),
          reason: '${palette.label} ${brightness.name} 的实色主按钮应承载前景文字',
        );
        // 原生 FilledButton 兜底与 Omni 主按钮遵循相同的可读状态规则。
        final ButtonStyle filledStyle = theme.filledButtonTheme.style!;
        // 悬停、焦点和按下组合均不能降低文字对比度。
        for (final Set<WidgetState> states in <Set<WidgetState>>[
          <WidgetState>{},
          <WidgetState>{WidgetState.hovered},
          <WidgetState>{WidgetState.focused},
          <WidgetState>{WidgetState.pressed},
          <WidgetState>{WidgetState.hovered, WidgetState.focused},
          <WidgetState>{WidgetState.hovered, WidgetState.pressed},
          <WidgetState>{WidgetState.focused, WidgetState.pressed},
        ]) {
          expect(
            _contrast(
              filledStyle.foregroundColor!.resolve(states)!,
              filledStyle.backgroundColor!.resolve(states)!,
            ),
            greaterThanOrEqualTo(4.6),
            reason: '${palette.label} ${brightness.name} FilledButton $states',
          );
          expect(filledStyle.overlayColor!.resolve(states), Colors.transparent);
        }
        if (palette == AppThemePalette.classicBlue) return;
        expect(colors.canvas, isNot(original.canvas));
        expect(colors.paper, isNot(original.paper));
        // 实际文字、按钮、选中态与渐变两端均满足普通文字对比度。
        final List<(Color, Color)> pairs = <(Color, Color)>[
          (colors.ink, colors.canvas),
          (colors.ink, colors.paper),
          (colors.muted, colors.paper),
          (colors.brand, colors.paper),
          (colors.accentInk, colors.brand),
          (colors.accentInk, colors.brandStrong),
          (colors.brandStrong, colors.brandSoft),
          (colors.heroInk, colors.heroStart),
          (colors.heroInk, colors.heroEnd),
        ];
        // 每一对实际使用的前景色与背景色。
        for (final (Color foreground, Color background) in pairs) {
          expect(
            _contrast(foreground, background),
            greaterThanOrEqualTo(4.5),
            reason: '${palette.label}: $foreground / $background',
          );
        }
      });
    }
  }

  test('复选框错误态使用可读红色且禁用态优先', () {
    // 每套配色的错误状态都必须满足同一状态契约。
    for (final AppThemePalette palette in AppThemePalette.values) {
      // 明暗模式共享状态优先级。
      for (final Brightness brightness in Brightness.values) {
        // 当前主题及复选框的状态解析器。
        final ThemeData theme = AppTheme.build(
          brightness: brightness,
          palette: palette,
        );
        // 禁用和普通态沿用扩展语义色。
        final OmniColors colors = theme.extension<OmniColors>()!;
        // 当前主题的复选框样式。
        final CheckboxThemeData checkbox = theme.checkboxTheme;
        // 同时覆盖未选中与选中两种错误展示。
        for (final bool selected in <bool>[false, true]) {
          // 交互状态不能覆盖错误语义。
          final Set<WidgetState> errorStates = <WidgetState>{
            WidgetState.error,
            WidgetState.hovered,
            WidgetState.focused,
            WidgetState.pressed,
            if (selected) WidgetState.selected,
          };
          expect(
            (checkbox.side! as WidgetStateBorderSide)
                .resolve(errorStates)!
                .color,
            theme.colorScheme.error,
          );
          expect(
            checkbox.fillColor!.resolve(errorStates),
            selected ? theme.colorScheme.error : Colors.transparent,
          );
          expect(checkbox.checkColor!.resolve(errorStates), Colors.white);
          if (selected) {
            expect(
              _contrast(
                checkbox.checkColor!.resolve(errorStates)!,
                checkbox.fillColor!.resolve(errorStates)!,
              ),
              greaterThanOrEqualTo(4.6),
            );
          }
          // 禁用后错误和悬停等状态都不能保留可操作的强调色。
          final Set<WidgetState> disabledStates = <WidgetState>{
            ...errorStates,
            WidgetState.disabled,
          };
          expect(
            (checkbox.side! as WidgetStateBorderSide)
                .resolve(disabledStates)!
                .color,
            selected
                ? Colors.transparent
                : colors.muted.withValues(alpha: 0.45),
          );
          expect(checkbox.fillColor!.resolve(disabledStates), colors.mist);
          expect(
            checkbox.checkColor!.resolve(disabledStates),
            colors.muted.withValues(alpha: 0.45),
          );
        }
        expect(
          checkbox.fillColor!.resolve(<WidgetState>{WidgetState.selected}),
          colors.brand,
        );
        expect(
          checkbox.checkColor!.resolve(<WidgetState>{WidgetState.selected}),
          colors.accentInk,
        );
      }
    }
  });

  test('Windows 主题明确使用微软雅黑 UI', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // Windows 浅色应用主题。
    final ThemeData theme = AppTheme.build(brightness: Brightness.light);

    expect(theme.textTheme.bodyMedium?.fontFamily, 'Microsoft YaHei UI');
    expect(
      theme.textTheme.bodyMedium?.fontFamilyFallback,
      contains('Microsoft YaHei'),
    );
  });

  test('组件局部样式与正文使用同一平台字体和中文回退', () {
    // 覆盖真实支持的桌面和触控平台。
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.android,
    ]) {
      // 保存外层测试平台，保证异常时也恢复。
      final TargetPlatform? previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = platform;
      try {
        // 当前平台的统一主题。
        final ThemeData theme = AppTheme.build(brightness: Brightness.light);
        // 平台默认字体。
        final String family = platform == TargetPlatform.windows
            ? 'Microsoft YaHei UI'
            : 'Roboto';
        // 会覆盖 DefaultTextStyle 的组件局部样式必须保留系统字体。
        final List<TextStyle?> styles = <TextStyle?>[
          theme.textTheme.bodyMedium,
          theme.inputDecorationTheme.labelStyle,
          theme.inputDecorationTheme.hintStyle,
          theme.inputDecorationTheme.helperStyle,
          theme.inputDecorationTheme.errorStyle,
          theme.filledButtonTheme.style?.textStyle?.resolve(<WidgetState>{}),
          theme.outlinedButtonTheme.style?.textStyle?.resolve(<WidgetState>{}),
          theme.textButtonTheme.style?.textStyle?.resolve(<WidgetState>{}),
          theme.chipTheme.labelStyle,
          theme.chipTheme.secondaryLabelStyle,
          theme.listTileTheme.titleTextStyle,
          theme.listTileTheme.subtitleTextStyle,
          theme.segmentedButtonTheme.style?.textStyle?.resolve(<WidgetState>{}),
          theme.sliderTheme.valueIndicatorTextStyle,
          theme.dialogTheme.titleTextStyle,
          theme.dialogTheme.contentTextStyle,
          theme.popupMenuTheme.textStyle,
          theme.popupMenuTheme.labelTextStyle?.resolve(<WidgetState>{}),
          theme.navigationRailTheme.selectedLabelTextStyle,
          theme.navigationRailTheme.unselectedLabelTextStyle,
          theme.navigationBarTheme.labelTextStyle?.resolve(<WidgetState>{}),
          theme.searchBarTheme.textStyle?.resolve(<WidgetState>{}),
          theme.searchBarTheme.hintStyle?.resolve(<WidgetState>{}),
          theme.snackBarTheme.contentTextStyle,
          theme.tooltipTheme.textStyle,
        ];
        // 每种组件都验证字体族与中文回退。
        for (final TextStyle? style in styles) {
          expect(style?.fontFamily, family);
          expect(style?.fontFamilyFallback, contains('Microsoft YaHei'));
        }
      } finally {
        debugDefaultTargetPlatformOverride = previous;
      }
    }
  });

  test('浅色主题保留经典蓝与中性画布', () {
    // 浅色应用主题。
    final ThemeData theme = AppTheme.build(brightness: Brightness.light);
    // 浅色扩展语义色。
    final OmniColors colors = theme.extension<OmniColors>()!;

    expect(colors.brand, const Color(0xFF3370FF));
    expect(theme.scaffoldBackgroundColor, const Color(0xFFF5F6F7));
    expect(colors.paper, const Color(0xFFFFFFFF));
    expect(colors.ink, const Color(0xFF1F2329));
    expect(colors.line, const Color(0xFFDEE0E3));
  });

  test('深色主题保持同一品牌语义', () {
    // 深色应用主题。
    final ThemeData theme = AppTheme.build(brightness: Brightness.dark);
    // 深色扩展语义色。
    final OmniColors colors = theme.extension<OmniColors>()!;

    expect(colors.brand, const Color(0xFF4C88FF));
    expect(theme.scaffoldBackgroundColor, const Color(0xFF17181A));
    expect(colors.brandSoft, const Color(0xFF20345D));
    expect(colors.paper, const Color(0xFF242529));
  });

  test('面板与控件采用统一小圆角', () {
    // 浅色应用主题。
    final ThemeData theme = AppTheme.build(brightness: Brightness.light);
    // 面板轮廓。
    final RoundedRectangleBorder panelShape =
        theme.cardTheme.shape! as RoundedRectangleBorder;
    // 面板左上圆角。
    final Radius panelRadius = panelShape.borderRadius.resolve(null).topLeft;
    // 输入框默认轮廓。
    final OutlineInputBorder inputBorder =
        theme.inputDecorationTheme.border! as OutlineInputBorder;
    // 输入框左上圆角。
    final Radius inputRadius = inputBorder.borderRadius.topLeft;

    expect(panelRadius.x, OmniRadius.panel);
    expect(inputRadius.x, OmniRadius.control);
    expect(OmniRadius.tiny, 4);
    expect(OmniRadius.control, 8);
    expect(OmniRadius.panel, 12);
    expect(OmniRadius.dialog, 16);
  });

  test('组合控件与进度条继承统一语义色', () {
    // 统一主题。
    final ThemeData theme = AppTheme.build(brightness: Brightness.light);
    // 当前主题语义色。
    final OmniColors colors = theme.extension<OmniColors>()!;
    expect(theme.sliderTheme.activeTrackColor, colors.brand);
    expect(theme.sliderTheme.inactiveTrackColor, colors.mist);
    expect(theme.progressIndicatorTheme.color, colors.brand);
    expect(theme.chipTheme.selectedColor, colors.brandSoft);
    expect(
      theme.segmentedButtonTheme.style?.backgroundColor?.resolve(<WidgetState>{
        WidgetState.selected,
      }),
      colors.brandSoft,
    );
  });

  testWidgets('减少动态效果聚合两项系统偏好', (WidgetTester tester) async {
    // 当前计算后的动画时长。
    Duration? effectiveDuration;
    // 两种独立系统偏好均应停止位移过渡。
    for (final MediaQueryData media in <MediaQueryData>[
      const MediaQueryData(disableAnimations: true),
      const MediaQueryData(accessibleNavigation: true),
      const MediaQueryData(),
    ]) {
      await tester.pumpWidget(
        MediaQuery(
          data: media,
          child: Builder(
            builder: (BuildContext context) {
              effectiveDuration = OmniMotion.duration(
                context,
                OmniMotion.panel,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(
        effectiveDuration,
        media.disableAnimations || media.accessibleNavigation
            ? Duration.zero
            : OmniMotion.panel,
      );
    }
  });

  test('默认滚动条使用细长样式', () {
    // 浅色应用主题。
    final ThemeData theme = AppTheme.build(brightness: Brightness.light);
    // 默认状态下的滚动条宽度。
    final double? thickness = theme.scrollbarTheme.thickness?.resolve(
      const <WidgetState>{},
    );

    expect(thickness, 4);
    expect(theme.scrollbarTheme.radius, const Radius.circular(999));
    expect(theme.scrollbarTheme.minThumbLength, 48);
    expect(theme.scrollbarTheme.trackVisibility?.resolve({}), isFalse);
  });

  test('输入框使用白底并仅在禁用时显示次级灰底', () {
    // 浅色应用主题。
    final ThemeData theme = AppTheme.build(brightness: Brightness.light);
    // 浅色扩展语义色。
    final OmniColors colors = theme.extension<OmniColors>()!;
    // 默认输入框填充色。
    final Color enabledFill = WidgetStateProperty.resolveAs(
      theme.inputDecorationTheme.fillColor!,
      const <WidgetState>{},
    );
    // 禁用输入框填充色。
    final Color disabledFill = WidgetStateProperty.resolveAs(
      theme.inputDecorationTheme.fillColor!,
      const <WidgetState>{WidgetState.disabled},
    );

    expect(enabledFill, const Color(0xFFFFFFFF));
    expect(disabledFill, const Color(0xFFF5F6F7));
    expect(
      theme.inputDecorationTheme.hoverColor,
      colors.brand.withValues(alpha: 0.03),
    );
  });
}

/// 根据相对亮度计算前景和背景的对比度。
double _contrast(Color foreground, Color background) {
  // 前景色的线性亮度。
  final double foregroundLuminance = foreground.computeLuminance();
  // 背景色的线性亮度。
  final double backgroundLuminance = background.computeLuminance();
  return foregroundLuminance > backgroundLuminance
      ? (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05)
      : (backgroundLuminance + 0.05) / (foregroundLuminance + 0.05);
}
