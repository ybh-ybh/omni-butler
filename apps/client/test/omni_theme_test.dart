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

  test('浅色主题使用统一飞书蓝与中性画布', () {
    // 浅色应用主题。
    final ThemeData theme = AppTheme.build(brightness: Brightness.light);
    // 浅色扩展语义色。
    final OmniColors colors = theme.extension<OmniColors>()!;

    expect(theme.colorScheme.primary, const Color(0xFF3370FF));
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

    expect(theme.colorScheme.primary, const Color(0xFF4C88FF));
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
