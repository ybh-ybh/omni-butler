import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/omni_icon_button_shape.dart';

/// 使用统一形状、热区和动效的图标操作。
class OmniIconButton extends StatelessWidget {
  /// 操作图标。
  final Widget icon;

  /// 点击回调，为空时禁用。
  final VoidCallback? onPressed;

  /// 操作名称，同时作为悬停提示与无障碍说明。
  final String? tooltip;

  /// 可选图标尺寸。
  final double? iconSize;

  /// 可选业务语义颜色。
  final Color? color;

  /// 可选嵌入式热区限制。
  final BoxConstraints? constraints;

  /// 可选嵌入式内边距。
  final EdgeInsetsGeometry? padding;

  /// 可选布局密度。
  final VisualDensity? visualDensity;

  /// 可选语义状态样式。
  final ButtonStyle? style;

  /// 是否处于选中状态。
  final bool? isSelected;

  /// 选中时的图标。
  final Widget? selectedIcon;

  /// 键盘焦点节点。
  final FocusNode? focusNode;

  /// 是否自动聚焦。
  final bool autofocus;

  /// 受控嵌入式区域的悬停颜色。
  final Color? hoverColor;

  /// 创建统一图标操作。
  const OmniIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize,
    this.color,
    this.constraints,
    this.padding,
    this.visualDensity,
    this.style,
    this.isSelected,
    this.selectedIcon,
    this.focusNode,
    this.autofocus = false,
    this.hoverColor,
    super.key,
  });

  /// 普通图标及菜单入口共享尺寸、内边距和鼠标颜色反馈。
  static ButtonStyle styleOf(BuildContext context, {Color? color}) {
    // 本轮桌面规范不改变Android触控热区。
    final bool windows = Theme.of(context).platform == TargetPlatform.windows;
    // Windows统一方形尺寸，其余平台沿用原有密度。
    final double extent = windows
        ? OmniSize.iconButton
        : OmniDensity.controlHeight(context);
    // 中性图标在悬停或键盘焦点时采用当前主题正文色。
    final OmniColors colors = OmniColors.of(context);
    return ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size.square(extent)),
      maximumSize: windows
          ? WidgetStatePropertyAll<Size>(Size.square(extent))
          : null,
      fixedSize: windows
          ? WidgetStatePropertyAll<Size>(Size.square(extent))
          : null,
      padding: windows
          ? const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.zero)
          : null,
      alignment: Alignment.center,
      iconSize: const WidgetStatePropertyAll<double>(OmniSize.icon),
      visualDensity: windows || OmniDensity.isTouch(context)
          ? VisualDensity.standard
          : null,
      foregroundColor: windows
          ? WidgetStateProperty.resolveWith<Color?>((states) {
              if (states.contains(WidgetState.disabled)) {
                return colors.muted.withValues(alpha: 0.45);
              }
              if (color != null) return color;
              return states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)
                  ? colors.ink
                  : colors.muted;
            })
          : null,
      animationDuration: OmniMotion.duration(context, OmniMotion.fast),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        windows
            ? const OmniIconButtonShape()
            : const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(
                  Radius.circular(OmniRadius.control),
                ),
              ),
      ),
    );
  }

  /// 构建保留原生键盘、焦点与提示能力的按钮。
  @override
  Widget build(BuildContext context) {
    // 统一尺寸和减少动效策略，语义颜色仍由主题决定。
    final ButtonStyle baseStyle = styleOf(
      context,
      color: color,
    ).copyWith(visualDensity: visualDensity);
    // 业务语义样式覆盖默认值，保留特殊表面的颜色和尺寸约定。
    final ButtonStyle semanticStyle = baseStyle.merge(style);
    // 显式嵌入约束必须同时覆盖最小与最大尺寸，避免小热区上出现反向约束。
    final ButtonStyle effectiveStyle = constraints == null
        ? semanticStyle
        : semanticStyle.copyWith(
            minimumSize: WidgetStatePropertyAll<Size>(constraints!.smallest),
            maximumSize: WidgetStatePropertyAll<Size>(constraints!.biggest),
            fixedSize: WidgetStatePropertyAll<Size>(
              constraints!.constrain(
                Size.square(
                  Theme.of(context).platform == TargetPlatform.windows
                      ? OmniSize.iconButton
                      : OmniDensity.controlHeight(context),
                ),
              ),
            ),
          );
    return IconButton(
      icon: icon,
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: iconSize,
      color: color,
      constraints: constraints,
      padding: padding,
      visualDensity: visualDensity,
      style: effectiveStyle,
      isSelected: isSelected,
      selectedIcon: selectedIcon,
      focusNode: focusNode,
      autofocus: autofocus,
      hoverColor: hoverColor,
    );
  }
}
