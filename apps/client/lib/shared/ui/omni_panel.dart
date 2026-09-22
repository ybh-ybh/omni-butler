import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 统一的飞书式内容面板。
class OmniPanel extends StatelessWidget {
  /// 面板内容。
  final Widget child;

  /// 面板内边距。
  final EdgeInsetsGeometry padding;

  /// 可选外边距。
  final EdgeInsetsGeometry? margin;

  /// 可选点击回调。
  final VoidCallback? onTap;

  /// 是否裁剪面板内容。
  final Clip clipBehavior;

  /// 创建统一内容面板。
  const OmniPanel({
    required this.child,
    this.padding = const EdgeInsets.all(OmniSpacing.md),
    this.margin,
    this.onTap,
    this.clipBehavior = Clip.antiAlias,
    super.key,
  });

  /// 构建带边框和悬浮反馈的面板。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 面板主体。
    final Widget panel = Material(
      color: colors.paper,
      clipBehavior: clipBehavior,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadius.panel),
        side: BorderSide(color: colors.line),
      ),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.ink.withValues(alpha: 0.04),
        child: Padding(padding: padding, child: child),
      ),
    );

    if (margin == null) {
      return panel;
    }
    return Padding(padding: margin!, child: panel);
  }
}

/// 统一的连续列表面板。
class OmniListPanel extends StatelessWidget {
  /// 列表行。
  final List<Widget> children;

  /// 创建连续列表面板。
  const OmniListPanel({required this.children, super.key});

  /// 构建自动插入分隔线的连续列表。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 含分隔线的列表内容。
    final List<Widget> separated = <Widget>[];
    for (int index = 0; index < children.length; index += 1) {
      if (index > 0) {
        separated.add(Divider(color: colors.line));
      }
      separated.add(children[index]);
    }
    return OmniPanel(
      padding: EdgeInsets.zero,
      child: Column(mainAxisSize: MainAxisSize.min, children: separated),
    );
  }
}

/// 统一的紧凑列表行。
class OmniListRow extends StatelessWidget {
  /// 可选前置区域。
  final Widget? leading;

  /// 主标题。
  final Widget title;

  /// 可选辅助内容。
  final Widget? subtitle;

  /// 可选尾部操作。
  final Widget? trailing;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 行内边距。
  final EdgeInsetsGeometry padding;

  /// 前置区域与主内容之间的间距。
  final double leadingGap;

  /// 可选的行背景与水波纹圆角。
  final BorderRadius? borderRadius;

  /// 创建紧凑列表行。
  const OmniListRow({
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(
      horizontal: OmniSpacing.md,
      vertical: OmniSpacing.sm,
    ),
    this.leadingGap = OmniSpacing.sm,
    this.borderRadius,
    super.key,
  });

  /// 构建支持悬浮和键盘焦点的列表行。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 行内容。
    final Widget content = Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            SizedBox(width: leadingGap),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w400),
                  child: title,
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: OmniSpacing.xxs),
                  DefaultTextStyle.merge(
                    style: Theme.of(context).textTheme.bodySmall,
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: OmniSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: borderRadius == null ? Clip.none : Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        hoverColor: colors.ink.withValues(alpha: 0.06),
        focusColor: colors.brand.withValues(alpha: 0.12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OmniSize.touch),
          child: content,
        ),
      ),
    );
  }
}
