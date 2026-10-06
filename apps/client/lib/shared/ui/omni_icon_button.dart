import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

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

  /// 构建保留原生键盘、焦点与提示能力的按钮。
  @override
  Widget build(BuildContext context) {
    // 当前平台的标准点击热区。
    final double extent = OmniDensity.controlHeight(context);
    // 统一尺寸和减少动效策略，语义颜色仍由主题决定。
    final ButtonStyle baseStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size.square(extent)),
      visualDensity:
          visualDensity ??
          (OmniDensity.isTouch(context) ? VisualDensity.standard : null),
      animationDuration: OmniMotion.duration(context, OmniMotion.fast),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(OmniRadius.control)),
        ),
      ),
    );
    // 业务语义样式覆盖默认值，保留特殊表面的颜色和尺寸约定。
    final ButtonStyle semanticStyle = style?.merge(baseStyle) ?? baseStyle;
    // 显式嵌入约束必须同时覆盖最小与最大尺寸，避免小热区上出现反向约束。
    final ButtonStyle effectiveStyle = constraints == null
        ? semanticStyle
        : semanticStyle.copyWith(
            minimumSize: WidgetStatePropertyAll<Size>(constraints!.smallest),
            maximumSize: WidgetStatePropertyAll<Size>(constraints!.biggest),
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
