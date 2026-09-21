import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 验证统一品牌主题的关键 Token 与组件轮廓。
void main() {
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
