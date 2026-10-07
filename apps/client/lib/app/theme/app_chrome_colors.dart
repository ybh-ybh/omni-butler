import 'package:flutter/material.dart';

/// 窗口标题栏与桌面导航专用配色，不改变业务面板的表面色。
@immutable
class OmniChromeColors extends ThemeExtension<OmniChromeColors> {
  /// 创建窗口与导航专用色组。
  const OmniChromeColors({
    required this.background,
    required this.foreground,
    required this.muted,
    required this.selectedBackground,
    required this.selectedForeground,
    required this.border,
  });

  /// 从选定背景生成可读文字和克制的选中态。
  factory OmniChromeColors.fromBackground(Color background) {
    // 浅色背景上的主要文字保留应用原有深灰色。
    const Color darkForeground = Color(0xFF1F2329);
    // 按实际背景选择文字；浅色模式中的远山、黛蓝仍需浅字。
    final Color foreground =
        _contrast(Colors.white, background) >
            _contrast(darkForeground, background)
        ? Colors.white
        : darkForeground;
    // 优先减弱次级文字，但远山等余量较小的背景保持完整前景色。
    final Color mutedCandidate = Color.alphaBlend(
      foreground.withValues(alpha: 0.78),
      background,
    );
    // 对量化保留少量余量，避免次级文字跌破普通正文对比度。
    final Color muted = _contrast(mutedCandidate, background) >= 4.6
        ? mutedCandidate
        : foreground;
    // 选中态向远离文字的方向改变背景，保持正文可读。
    final Color selectedTint = foreground == Colors.white
        ? Colors.black.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.60);
    return OmniChromeColors(
      background: background,
      foreground: foreground,
      muted: muted,
      selectedBackground: Color.alphaBlend(selectedTint, background),
      selectedForeground: foreground,
      border: Color.alphaBlend(foreground.withValues(alpha: 0.16), background),
    );
  }

  /// 标题栏与桌面导航共享的背景色。
  final Color background;

  /// 导航正文和原生标题文字颜色。
  final Color foreground;

  /// 导航次级文字与未选中图标颜色。
  final Color muted;

  /// 当前导航项的背景色。
  final Color selectedBackground;

  /// 当前导航项的图标与文字颜色。
  final Color selectedForeground;

  /// 导航区域边界颜色。
  final Color border;

  /// 标题栏普通按钮的中性悬停底色，同时适用于键盘焦点。
  Color get captionHoverBackground {
    // 向文字方向叠加中性颜色，让浅底变灰、深底提亮。
    final Color highlighted = Color.alphaBlend(
      foreground.withValues(alpha: 0.16),
      background,
    );
    if (_contrast(foreground, highlighted) >= 4.5) return highlighted;
    // 中蓝背景提亮会削弱浅字，改为可辨认的加深反馈。
    final Color readableTint =
        foreground.computeLuminance() > background.computeLuminance()
        ? Colors.black
        : Colors.white;
    return Color.alphaBlend(readableTint.withValues(alpha: 0.24), background);
  }

  /// 从当前主题读取窗口与导航专用色组。
  static OmniChromeColors of(BuildContext context) {
    // 当前主题已注册的窗口与导航配色。
    final OmniChromeColors? colors = Theme.of(context)
        .extension<OmniChromeColors>();
    assert(colors != null, 'OmniChromeColors 必须注册到 ThemeData');
    return colors!;
  }

  /// 复制并替换局部窗口或导航颜色。
  @override
  OmniChromeColors copyWith({
    Color? background,
    Color? foreground,
    Color? muted,
    Color? selectedBackground,
    Color? selectedForeground,
    Color? border,
  }) => OmniChromeColors(
    background: background ?? this.background,
    foreground: foreground ?? this.foreground,
    muted: muted ?? this.muted,
    selectedBackground: selectedBackground ?? this.selectedBackground,
    selectedForeground: selectedForeground ?? this.selectedForeground,
    border: border ?? this.border,
  );

  /// 跟随应用主题动画同步插值导航颜色。
  @override
  OmniChromeColors lerp(covariant OmniChromeColors? other, double t) {
    if (other == null) return this;
    return OmniChromeColors(
      background: Color.lerp(background, other.background, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      selectedBackground: Color.lerp(
        selectedBackground,
        other.selectedBackground,
        t,
      )!,
      selectedForeground: Color.lerp(
        selectedForeground,
        other.selectedForeground,
        t,
      )!,
      border: Color.lerp(border, other.border, t)!,
    );
  }

  /// 根据相对亮度计算文字与背景的实际对比度。
  static double _contrast(Color foreground, Color background) {
    // 前景颜色的线性亮度。
    final double foregroundLuminance = foreground.computeLuminance();
    // 背景颜色的线性亮度。
    final double backgroundLuminance = background.computeLuminance();
    return foregroundLuminance > backgroundLuminance
        ? (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05)
        : (backgroundLuminance + 0.05) / (foregroundLuminance + 0.05);
  }
}
