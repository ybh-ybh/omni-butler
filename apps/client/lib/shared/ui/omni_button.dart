import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// Omni Butler 按钮视觉类型。
enum OmniButtonVariant {
  /// 品牌色主要操作。
  primary,

  /// 页面主要操作，与 primary 共用外观并采用较大桌面尺寸。
  pagePrimary,

  /// 中性描边次要操作。
  secondary,

  /// 无边框文字操作。
  text,

  /// 危险操作。
  danger,
}

/// 统一承载语义、密度和交互状态的按钮。
class OmniButton extends StatelessWidget {
  /// 按钮文字。
  final String label;

  /// 点击回调。
  final VoidCallback? onPressed;

  /// 按钮视觉类型。
  final OmniButtonVariant variant;

  /// 可选前置图标。
  final IconData? icon;

  /// 是否显示加载状态并阻止重复提交。
  final bool loading;

  /// 是否使用大尺寸。
  final bool large;

  /// 创建统一按钮。
  const OmniButton({
    required this.label,
    required this.onPressed,
    this.variant = OmniButtonVariant.primary,
    this.icon,
    this.loading = false,
    this.large = false,
    super.key,
  });

  /// 构建按钮内容与交互状态。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 实色填色单独保障文字对比度，保留业务品牌语义色。
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 加载时保持标签可读，但不再接受重复操作。
    final VoidCallback? effectiveOnPressed = loading ? null : onPressed;
    // 页面主操作仅通过尺寸强调，与其他主操作共享外观。
    final double height = OmniDensity.controlHeight(
      context,
      large: large || variant == OmniButtonVariant.pagePrimary,
    );
    // 实色操作使用相应语义颜色。
    final bool filled =
        variant == OmniButtonVariant.primary ||
        variant == OmniButtonVariant.pagePrimary ||
        variant == OmniButtonVariant.danger;
    // 危险按钮与品牌按钮共用状态规则。
    final Color fill = variant == OmniButtonVariant.danger
        ? scheme.error
        : scheme.primary;
    // 主操作的文字与图标颜色。
    final Color foreground = variant == OmniButtonVariant.danger
        ? scheme.onError
        : scheme.onPrimary;
    // 浅色文字加深背景，深色文字提亮背景，交互反馈不会降低对比度。
    final Color stateTint =
        foreground.computeLuminance() > fill.computeLuminance()
        ? Colors.black
        : Colors.white;
    // 各按钮共享密度、键盘焦点、即时按下反馈和减少动效规则。
    final ButtonStyle style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size(0, height)),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      animationDuration: OmniMotion.duration(context, OmniMotion.fast),
      textStyle: WidgetStatePropertyAll<TextStyle?>(
        Theme.of(context).textTheme.labelLarge
            ?.copyWith(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
      ),
      side: WidgetStateProperty.resolveWith<BorderSide>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.focused)) {
          return BorderSide(color: colors.ink.withValues(alpha: 0.7), width: 2);
        }
        return BorderSide(
          color: variant == OmniButtonVariant.secondary
              ? colors.line
              : Colors.transparent,
          width: 1,
        );
      }),
      backgroundColor: filled
          ? WidgetStateProperty.resolveWith<Color>((Set<WidgetState> states) {
              if (states.contains(WidgetState.disabled) && !loading) {
                return colors.mist;
              }
              if (states.contains(WidgetState.pressed)) {
                return Color.alphaBlend(
                  stateTint.withValues(alpha: 0.14),
                  fill,
                );
              }
              if (states.contains(WidgetState.hovered)) {
                return Color.alphaBlend(
                  stateTint.withValues(alpha: 0.06),
                  fill,
                );
              }
              return fill;
            })
          : WidgetStateProperty.resolveWith<Color>((Set<WidgetState> states) {
              if (variant == OmniButtonVariant.secondary) {
                if (states.contains(WidgetState.pressed)) return colors.mist;
                if (states.contains(WidgetState.hovered)) {
                  return Color.alphaBlend(
                    colors.ink.withValues(alpha: 0.04),
                    colors.paper,
                  );
                }
                return colors.paper;
              }
              if (states.contains(WidgetState.pressed)) return colors.brandSoft;
              if (states.contains(WidgetState.hovered)) {
                return colors.brand.withValues(alpha: 0.06);
              }
              return Colors.transparent;
            }),
      foregroundColor: filled
          ? WidgetStateProperty.resolveWith<Color>((Set<WidgetState> states) {
              return states.contains(WidgetState.disabled) && !loading
                  ? colors.muted
                  : foreground;
            })
          : loading
          ? WidgetStatePropertyAll<Color>(colors.ink)
          : null,
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    );
    // 内容保留原操作名称，加载状态不会改变按钮语义。
    final Widget content = _ButtonContent(
      label: label,
      icon: icon,
      loading: loading,
    );
    // 按钮使用 Flutter 的焦点、键盘、语义与点击取消能力。
    final Widget button = switch (variant) {
      OmniButtonVariant.primary ||
      OmniButtonVariant.pagePrimary ||
      OmniButtonVariant.danger => FilledButton(
        onPressed: effectiveOnPressed,
        style: style,
        child: content,
      ),
      OmniButtonVariant.secondary => OutlinedButton(
        onPressed: effectiveOnPressed,
        style: style,
        child: content,
      ),
      OmniButtonVariant.text => TextButton(
        onPressed: effectiveOnPressed,
        style: style,
        child: content,
      ),
    };
    return Semantics(
      liveRegion: loading,
      value: loading ? '正在处理' : null,
      child: button,
    );
  }
}

/// 统一按钮内部内容。
class _ButtonContent extends StatelessWidget {
  /// 按钮文字。
  final String label;

  /// 可选图标。
  final IconData? icon;

  /// 是否加载中。
  final bool loading;

  /// 创建按钮内部内容。
  const _ButtonContent({
    required this.label,
    required this.icon,
    required this.loading,
  });

  /// 构建统一图标、加载状态与文字。
  @override
  Widget build(BuildContext context) {
    if (icon == null && !loading) return Text(label);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (loading)
          SizedBox.square(
            dimension: OmniSize.icon,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: DefaultTextStyle.of(context).style.color,
              value: OmniMotion.reduce(context) ? 0.75 : null,
            ),
          )
        else
          Icon(icon, size: OmniSize.icon),
        const SizedBox(width: OmniSpacing.xs),
        Flexible(child: Text(label)),
      ],
    );
  }
}
