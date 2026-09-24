import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_dropdown.dart';

/// 拆分按钮菜单中的一项次要操作。
class OmniSplitAction<T> {
  /// 选中菜单项后返回的值。
  final T value;

  /// 菜单项文案。
  final String label;

  /// 菜单项图标。
  final IconData icon;

  /// 创建拆分按钮次要操作。
  const OmniSplitAction({
    required this.value,
    required this.label,
    required this.icon,
  });
}

/// 统一的移动端新增拆分按钮。
class OmniSplitActionButton<T> extends StatefulWidget {
  /// 用于生成稳定测试键的业务前缀。
  final String keyPrefix;

  /// 主操作按钮文案。
  final String label;

  /// 主操作的无障碍文案。
  final String primarySemanticsLabel;

  /// 次要操作菜单按钮提示。
  final String menuTooltip;

  /// 主操作点击回调。
  final VoidCallback onPressed;

  /// 次要操作列表。
  final List<OmniSplitAction<T>> actions;

  /// 次要操作选中回调。
  final ValueChanged<T> onSelected;

  /// 创建统一的新增拆分按钮。
  const OmniSplitActionButton({
    required this.keyPrefix,
    required this.label,
    required this.primarySemanticsLabel,
    required this.menuTooltip,
    required this.onPressed,
    required this.actions,
    required this.onSelected,
    super.key,
  }) : assert(actions.length > 0, '拆分按钮至少需要一个次要操作');

  /// 创建并维护菜单展开状态。
  @override
  State<OmniSplitActionButton<T>> createState() =>
      _OmniSplitActionButtonState<T>();
}

/// 统一管理拆分按钮菜单与图标动画。
class _OmniSplitActionButtonState<T> extends State<OmniSplitActionButton<T>> {
  /// 当前次要操作菜单是否展开。
  bool _menuOpen = false;

  /// 构建带分割线的次要操作列表。
  List<Widget> _buildMenuChildren(OmniColors colors) {
    // 最终输出的菜单子组件。
    final List<Widget> children = <Widget>[];
    // 当前次要操作索引。
    for (int index = 0; index < widget.actions.length; index += 1) {
      // 当前次要操作。
      final OmniSplitAction<T> action = widget.actions[index];
      children.add(
        SizedBox(
          height: OmniSize.touch,
          child: OmniPopupMenuItem<T>(
            key: ValueKey<String>('${widget.keyPrefix}-action-$index'),
            value: action.value,
            label: action.label,
            icon: action.icon,
          ),
        ),
      );
      if (index < widget.actions.length - 1) {
        children.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: OmniSpacing.sm,
            endIndent: OmniSpacing.sm,
            color: colors.line,
          ),
        );
      }
    }
    return children;
  }

  /// 在拆分按钮上方显示右对齐的窄菜单。
  Future<void> _showActions(BuildContext context) async {
    if (_menuOpen) {
      return;
    }
    // 完整拆分按钮的实际渲染区域。
    final RenderBox button = context.findRenderObject()! as RenderBox;
    // 根导航浮层用于统一弹出菜单和按钮的坐标。
    final RenderBox overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay!.context.findRenderObject()!
            as RenderBox;
    // 按钮在根浮层中的边界。
    final Rect anchor =
        button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
    // 菜单比整个按钮窄 8px，并与按钮右边缘对齐。
    final double menuWidth = anchor.width - OmniSpacing.xs;
    // 用户是否要求减少动画。
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    setState(() => _menuOpen = true);
    // 用户选中的次要操作；点击外部或返回时为空。
    final T? action = await showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: reduceMotion ? Duration.zero : OmniMotion.normal,
      transitionBuilder: (_, _, _, Widget child) => child,
      pageBuilder:
          (
            BuildContext menuContext,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) {
            // 当前主题的菜单背景和描边色。
            final OmniColors colors = OmniColors.of(menuContext);
            // 展开进度使用统一减速曲线，收起时反向播放。
            final Animation<double> progress = animation.drive(
              CurveTween(curve: OmniMotion.standardCurve),
            );
            // 菜单轻微上移，同时始终保留与按钮之间的间隙。
            final Animation<Offset> slide = Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(progress);
            return Stack(
              children: <Widget>[
                Positioned(
                  right: overlay.size.width - anchor.right,
                  bottom: overlay.size.height - anchor.top + OmniSpacing.xs,
                  width: menuWidth,
                  child: FadeTransition(
                    key: ValueKey<String>('${widget.keyPrefix}-actions-fade'),
                    opacity: progress,
                    child: SizeTransition(
                      key: ValueKey<String>(
                        '${widget.keyPrefix}-actions-expand',
                      ),
                      sizeFactor: progress,
                      alignment: Alignment.bottomRight,
                      child: SlideTransition(
                        position: slide,
                        child: Semantics(
                          role: SemanticsRole.menu,
                          explicitChildNodes: true,
                          child: Material(
                            key: ValueKey<String>(
                              '${widget.keyPrefix}-actions-menu',
                            ),
                            color: colors.paper,
                            elevation: 4,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                OmniRadius.panel,
                              ),
                              side: BorderSide(color: colors.line),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: math.max(
                                  0,
                                  anchor.top -
                                      MediaQuery.paddingOf(menuContext).top -
                                      OmniSpacing.md,
                                ),
                              ),
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.symmetric(
                                  vertical: OmniSpacing.xxs,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: _buildMenuChildren(colors),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
    );
    if (!mounted) {
      return;
    }
    setState(() => _menuOpen = false);
    if (action != null) {
      widget.onSelected(action);
    }
  }

  /// 构建共享容器、主操作与次要操作菜单。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 拆分按钮的统一圆角。
    final BorderRadius borderRadius = BorderRadius.circular(OmniRadius.panel);
    return SizedBox(
      key: ValueKey<String>('${widget.keyPrefix}-create-split'),
      height: OmniSize.touch,
      child: Material(
        color: colors.brandSoft,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              button: true,
              label: widget.primarySemanticsLabel,
              onTap: widget.onPressed,
              child: ExcludeSemantics(
                child: InkWell(
                  key: ValueKey<String>('${widget.keyPrefix}-create'),
                  onTap: widget.onPressed,
                  child: SizedBox(
                    height: OmniSize.touch,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6, right: 14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: colors.brand,
                              borderRadius: BorderRadius.circular(
                                OmniRadius.control,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.add_rounded,
                              size: 16,
                              color: colors.accentInk,
                            ),
                          ),
                          const SizedBox(width: OmniSpacing.xs),
                          Text(
                            widget.label,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: colors.brandStrong,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w400,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 1,
              height: 24,
              child: ColoredBox(color: colors.brand.withValues(alpha: 0.20)),
            ),
            SizedBox.square(
              dimension: OmniSize.touch,
              child: MergeSemantics(
                child: Semantics(
                  label: widget.menuTooltip,
                  child: IconButton(
                    key: ValueKey<String>('${widget.keyPrefix}-more-actions'),
                    tooltip: widget.menuTooltip,
                    onPressed: () => _showActions(context),
                    style: IconButton.styleFrom(
                      shape: const RoundedRectangleBorder(),
                    ),
                    icon: _OmniSplitMenuToggleIcon(
                      keyPrefix: widget.keyPrefix,
                      expanded: _menuOpen,
                      color: colors.brandStrong,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 将三条圆角横线转换为叉号的菜单状态图标。
class _OmniSplitMenuToggleIcon extends StatelessWidget {
  /// 用于生成稳定测试键的业务前缀。
  final String keyPrefix;

  /// 菜单是否展开。
  final bool expanded;

  /// 沿用拆分按钮的图标颜色。
  final Color color;

  /// 创建菜单开关图标。
  const _OmniSplitMenuToggleIcon({
    required this.keyPrefix,
    required this.expanded,
    required this.color,
  });

  /// 构建 500ms 的横线旋转、位移和收缩动画。
  @override
  Widget build(BuildContext context) {
    // 参考样式的 3em 宽度映射到既有图标尺寸。
    const double unit = OmniSize.icon / 3;
    return SizedBox.square(
      key: ValueKey<String>('$keyPrefix-toggle-icon'),
      dimension: OmniSize.icon,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: expanded ? 1 : 0),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 500),
        curve: const Cubic(0.25, 0.1, 0.25, 1),
        builder: (BuildContext context, double progress, Widget? child) {
          return Center(
            child: SizedBox(
              width: OmniSize.icon,
              height: 2.3 * unit,
              child: Stack(
                children: <Widget>[
                  for (int index = 0; index < 3; index += 1)
                    Positioned(
                      top: index * unit,
                      left: 0,
                      child: Transform(
                        key: ValueKey<String>('$keyPrefix-toggle-line-$index'),
                        alignment: index == 2
                            ? Alignment.centerLeft
                            : Alignment.center,
                        transform: index == 2
                            ? Matrix4.diagonal3Values(1 - progress, 1, 1)
                            : (Matrix4.identity()
                                ..rotateZ(
                                  (index == 0 ? 1 : -1) *
                                      math.pi /
                                      4 *
                                      progress,
                                )
                                ..translateByDouble(
                                  (index == 0 ? 0.7 : 0.1) * unit * progress,
                                  (index == 0 ? 0.7 : 0) * unit * progress,
                                  0,
                                  1,
                                )),
                        child: Container(
                          width: OmniSize.icon,
                          height: 0.3 * unit,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(10 * unit),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
