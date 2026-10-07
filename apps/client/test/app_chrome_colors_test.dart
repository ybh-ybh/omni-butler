import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_chrome_colors.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';

/// 验证窗口与导航染色、文字可读性及其他平台的外观隔离。
void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  // 每款主题同时覆盖浅色和深色，保护切换后的真实导航配色。
  for (final AppThemePalette palette in AppThemePalette.values) {
    // 明暗模式与背景深浅并不总是一致。
    for (final Brightness brightness in Brightness.values) {
      test('Windows ${palette.label} ${brightness.name} 染色且文字可读', () {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        // Windows 当前配色下的完整主题。
        final ThemeData theme = AppTheme.build(
          brightness: brightness,
          palette: palette,
        );
        // 业务表面色保持原有定义。
        final OmniColors colors = theme.extension<OmniColors>()!;
        // 实际由标题栏与导航共同读取的专用颜色。
        final OmniChromeColors chrome = theme.extension<OmniChromeColors>()!;
        expect(
          chrome.background,
          palette == AppThemePalette.classicBlue
              ? colors.paper
              : palette.previewColorFor(brightness),
        );
        expect(
          _contrast(chrome.foreground, chrome.background),
          greaterThan(4.5),
        );
        expect(_contrast(chrome.muted, chrome.background), greaterThan(4.5));
        if (palette == AppThemePalette.classicBlue) {
          // 经典选中态保留既有品牌色，本轮不顺带调整其历史对比度。
          expect(chrome.selectedBackground, colors.brandSoft);
          expect(chrome.selectedForeground, colors.brand);
        } else {
          expect(
            _contrast(chrome.selectedForeground, chrome.selectedBackground),
            greaterThan(4.5),
          );
          expect(chrome.selectedBackground, isNot(chrome.background));
        }

        // 平台切换不能改变业务面板，染色只发生在独立扩展中。
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        // 同款配色在 Android 上的业务主题作为隔离参照。
        final ThemeData otherPlatformTheme = AppTheme.build(
          brightness: brightness,
          palette: palette,
        );
        expect(theme.cardTheme.color, otherPlatformTheme.cardTheme.color);
        expect(
          theme.scaffoldBackgroundColor,
          otherPlatformTheme.scaffoldBackgroundColor,
        );
        expect(theme.colorScheme, otherPlatformTheme.colorScheme);
      });
    }
  }

  test('非 Windows 平台保持全部既有导航颜色', () {
    // 所有非 Windows 平台都不启用本次桌面标题栏染色。
    for (final TargetPlatform platform in TargetPlatform.values) {
      if (platform == TargetPlatform.windows) continue;
      debugDefaultTargetPlatformOverride = platform;
      // 每款配色的兼容色组保持与原有表面色一致。
      for (final AppThemePalette palette in AppThemePalette.values) {
        // 同时保护非 Windows 的浅色和深色模式。
        for (final Brightness brightness in Brightness.values) {
          // 当前平台与配色的应用主题。
          final ThemeData theme = AppTheme.build(
            brightness: brightness,
            palette: palette,
          );
          // 既有业务语义色作为导航兼容参照。
          final OmniColors colors = theme.extension<OmniColors>()!;
          // 此平台应继续沿用既有颜色的导航扩展。
          final OmniChromeColors chrome = theme.extension<OmniChromeColors>()!;
          expect(chrome.background, colors.paper);
          expect(chrome.foreground, colors.ink);
          expect(chrome.muted, colors.muted);
          expect(chrome.selectedBackground, colors.brandSoft);
          expect(chrome.selectedForeground, colors.brand);
          expect(chrome.border, colors.line);
        }
      }
    }
  });
}

/// 计算实际使用的文字和背景之间的亮度对比。
double _contrast(Color foreground, Color background) {
  // 文字的相对亮度。
  final double foregroundLuminance = foreground.computeLuminance();
  // 背景的相对亮度。
  final double backgroundLuminance = background.computeLuminance();
  return foregroundLuminance > backgroundLuminance
      ? (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05)
      : (backgroundLuminance + 0.05) / (foregroundLuminance + 0.05);
}
