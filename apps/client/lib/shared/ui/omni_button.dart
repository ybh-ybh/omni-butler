import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// Omni Butler 按钮视觉类型。
enum OmniButtonVariant {
  /// 蓝色主要操作。
  primary,

  /// 浅蓝底与实蓝图标块组成的页面主操作。
  pagePrimary,

  /// 白底描边次要操作。
  secondary,

  /// 无边框文字操作。
  text,

  /// 红色危险操作。
  danger,
}

/// 统一承载飞书式状态与尺寸的按钮。
class OmniButton extends StatelessWidget {
  /// 按钮文字。
  final String label;

  /// 点击回调。
  final VoidCallback? onPressed;

  /// 按钮视觉类型。
  final OmniButtonVariant variant;

  /// 可选前置图标。
  final IconData? icon;

  /// 是否显示加载状态。
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
    // 当前按钮是否可用。
    final VoidCallback? effectiveOnPressed = loading ? null : onPressed;
    // 当前视口是否为移动端。
    final bool compact = OmniBreakpoint.isCompact(
      MediaQuery.sizeOf(context).width,
    );
    // 当前按钮目标高度。
    final double height = compact
        ? OmniSize.touch
        : variant == OmniButtonVariant.pagePrimary
        ? OmniSize.pageAction
        : large
        ? OmniSize.controlLarge
        : OmniSize.control;
    // 当前页面主操作是否处于不可用状态。
    final bool pagePrimaryDisabled = onPressed == null && !loading;
    // 当前按钮内容。
    final Widget content = _ButtonContent(
      label: label,
      icon: icon,
      loading: loading,
      color: variant == OmniButtonVariant.danger ? colors.accentInk : null,
      tiledIcon: variant == OmniButtonVariant.pagePrimary,
      disabled: pagePrimaryDisabled,
    );
    // 当前按钮尺寸覆盖。
    final ButtonStyle sizeStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size(0, height)),
    );

    return switch (variant) {
      OmniButtonVariant.primary => FilledButton(
        onPressed: effectiveOnPressed,
        style: sizeStyle,
        child: content,
      ),
      OmniButtonVariant.pagePrimary => FilledButton(
        onPressed: effectiveOnPressed,
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll<Size>(Size(0, height)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.only(left: 6, right: 14),
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((
            Set<WidgetState> states,
          ) {
            if (states.contains(WidgetState.disabled) && !loading) {
              return colors.mist;
            }
            if (states.contains(WidgetState.pressed)) {
              return Color.alphaBlend(
                colors.brand.withValues(alpha: 0.18),
                colors.brandSoft,
              );
            }
            if (states.contains(WidgetState.hovered)) {
              return Color.alphaBlend(
                colors.brand.withValues(alpha: 0.09),
                colors.brandSoft,
              );
            }
            return colors.brandSoft;
          }),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>((
            Set<WidgetState> states,
          ) {
            if (states.contains(WidgetState.disabled) && !loading) {
              return colors.muted;
            }
            return colors.brandStrong;
          }),
          side: WidgetStateProperty.resolveWith<BorderSide?>((
            Set<WidgetState> states,
          ) {
            if (states.contains(WidgetState.focused)) {
              return BorderSide(
                color: colors.brand.withValues(alpha: 0.30),
                width: 2,
              );
            }
            return const BorderSide(color: Colors.transparent, width: 2);
          }),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(OmniRadius.panel),
            ),
          ),
          elevation: const WidgetStatePropertyAll<double>(0),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          animationDuration: OmniMotion.fast,
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
          ),
        ),
        child: content,
      ),
      OmniButtonVariant.secondary => OutlinedButton(
        onPressed: effectiveOnPressed,
        style: sizeStyle,
        child: content,
      ),
      OmniButtonVariant.text => TextButton(
        onPressed: effectiveOnPressed,
        style: sizeStyle,
        child: content,
      ),
      OmniButtonVariant.danger => FilledButton(
        onPressed: effectiveOnPressed,
        style: FilledButton.styleFrom(
          minimumSize: Size(0, height),
          backgroundColor: colors.danger,
          foregroundColor: colors.accentInk,
          disabledBackgroundColor: colors.mist,
          disabledForegroundColor: colors.muted,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(OmniRadius.control),
          ),
        ),
        child: content,
      ),
    };
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

  /// 可选内容颜色。
  final Color? color;

  /// 是否使用页面主操作图标块。
  final bool tiledIcon;

  /// 页面主操作是否处于不可用状态。
  final bool disabled;

  /// 创建按钮内部内容。
  const _ButtonContent({
    required this.label,
    required this.icon,
    required this.loading,
    required this.color,
    required this.tiledIcon,
    required this.disabled,
  });

  /// 构建图标、加载状态与文字。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 加载或业务图标。
    final Widget? leading = _buildLeading(context, colors);

    if (leading == null) {
      return Text(label);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        leading,
        const SizedBox(width: OmniSpacing.xs),
        Text(label),
      ],
    );
  }

  /// 构建普通图标或页面主操作图标块。
  Widget? _buildLeading(BuildContext context, OmniColors colors) {
    if (icon == null && !loading) {
      return null;
    }
    if (tiledIcon) {
      // 页面主操作图标块背景色。
      final Color tileColor = disabled ? colors.line : colors.brand;
      // 页面主操作图标颜色。
      final Color tileIconColor = disabled ? colors.muted : colors.accentInk;
      return Container(
        key: const ValueKey<String>('omni-page-primary-icon'),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: tileColor,
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
        alignment: Alignment.center,
        child: loading
            ? SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: tileIconColor,
                ),
              )
            : Icon(icon, size: 16, color: tileIconColor),
      );
    }
    if (loading) {
      return SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: color ?? IconTheme.of(context).color,
        ),
      );
    }
    return Icon(icon, size: OmniSize.icon, color: color);
  }
}
