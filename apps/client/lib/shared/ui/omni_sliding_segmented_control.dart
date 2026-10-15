import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

import 'omni_press_feedback.dart';

/// 带连续轨道与滑块动画的通用分段选择控件。
class OmniSlidingSegmentedControl<T> extends StatelessWidget {
  /// 按展示顺序排列的选项。
  final List<T> options;

  /// 当前选中的选项。
  final T selected;

  /// 横滑过程中用于直接定位滑块的连续选项索引。
  final double? indicatorIndex;

  /// 控件总宽度。
  final double width;

  /// 控件总高度。
  final double height;

  /// 是否嵌入由上层提供外框的组合控件。
  final bool embedded;

  /// 可选的入口光标；未指定时保留控件原有平台行为。
  final MouseCursor? mouseCursor;

  /// 可选的未选中项悬停底色，指定后选中项不叠加悬停底色。
  final Color? unselectedHoverColor;

  /// 选项标签构建回调。
  final String Function(T option) labelBuilder;

  /// 可选的自定义选项内容构建回调。
  final Widget Function(BuildContext context, T option, bool selected)?
  itemBuilder;

  /// 可选的选项键构建回调。
  final Key? Function(T option)? itemKeyBuilder;

  /// 选项变更回调。
  final ValueChanged<T> onChanged;

  /// 创建带滑块动画的分段选择控件。
  const OmniSlidingSegmentedControl({
    required this.options,
    required this.selected,
    required this.width,
    required this.labelBuilder,
    required this.onChanged,
    this.height = 36,
    this.embedded = false,
    this.mouseCursor,
    this.unselectedHoverColor,
    this.indicatorIndex,
    this.itemBuilder,
    this.itemKeyBuilder,
    super.key,
  }) : assert(options.length > 0);

  /// 构建连续轨道、选中滑块与可点击标签。
  @override
  Widget build(BuildContext context) {
    // 当前主题色。
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 当前选中项在轨道中的位置。
    final int selectedIndex = options.indexOf(selected);
    assert(selectedIndex >= 0);
    // 当前系统是否要求减少动态效果。
    final bool disableAnimation = OmniMotion.reduce(context);
    // 横滑跟手时直接使用连续索引，静态切换时使用当前选中项。
    final double resolvedIndicatorIndex = (indicatorIndex ?? selectedIndex)
        .clamp(0, options.length - 1)
        .toDouble();
    // 滑块动画时长。
    final Duration animationDuration =
        disableAnimation || indicatorIndex != null
        ? Duration.zero
        : OmniMotion.normal;
    // 当前滑块在连续轨道中的对齐位置。
    final double indicatorAlignment = options.length == 1
        ? 0
        : -1 + (2 * resolvedIndicatorIndex / (options.length - 1));

    return Container(
      width: width,
      height: height < OmniDensity.controlHeight(context)
          ? OmniDensity.controlHeight(context)
          : height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: embedded ? Colors.transparent : scheme.surface,
        borderRadius: BorderRadius.circular(
          embedded ? OmniRadius.control : OmniRadius.panel,
        ),
        border: embedded ? null : Border.all(color: scheme.outline),
      ),
      child: Stack(
        children: <Widget>[
          AnimatedAlign(
            duration: animationDuration,
            curve: OmniMotion.standardCurve,
            alignment: Alignment(indicatorAlignment, 0),
            child: FractionallySizedBox(
              widthFactor: 1 / options.length,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                ),
              ),
            ),
          ),
          Builder(
            builder: (context) {
              // 选项保留既有热区，自定义悬停层独立于Ink状态。
              final Widget optionsRow = Row(
                children: <Widget>[
                  for (final T option in options)
                    Expanded(
                      child: Builder(
                        builder: (BuildContext context) {
                          // 当前选项是否已经选中。
                          final bool isSelected = option == selected;
                          // 当前选项的可见内容。
                          final Widget item =
                              itemBuilder?.call(context, option, isSelected) ??
                              Text(
                                labelBuilder(option),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      color: isSelected
                                          ? scheme.onPrimaryContainer
                                          : scheme.onSurfaceVariant,
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                              );
                          // 稳定保留原有语义、键盘焦点与唯一点击识别器。
                          final Widget button = Semantics(
                            button: true,
                            selected: isSelected,
                            label: labelBuilder(option),
                            child: OmniInkWell(
                              key: itemKeyBuilder?.call(option),
                              mouseCursor: mouseCursor,
                              hoverColor: unselectedHoverColor == null
                                  ? null
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(
                                OmniRadius.control,
                              ),
                              onTap: () => onChanged(option),
                              child: Center(child: item),
                            ),
                          );
                          return unselectedHoverColor == null
                              ? button
                              : _OmniSegmentHoverSurface(
                                  selected: isSelected,
                                  color: unselectedHoverColor!,
                                  child: button,
                                );
                        },
                      ),
                    ),
                ],
              );
              return optionsRow;
            },
          ),
        ],
      ),
    );
  }
}

/// 自定义悬停背景不依赖InkHighlight创建时固定的alpha，切换选中时不会变黑。
class _OmniSegmentHoverSurface extends StatefulWidget {
  /// 创建不改变按钮热区及焦点身份的背景层。
  const _OmniSegmentHoverSurface({
    required this.selected,
    required this.color,
    required this.child,
  });

  /// 选中项始终让出滑块自身的表面。
  final bool selected;

  /// 未选中项的悬停底色，退场保留其RGB。
  final Color color;

  /// 原有按钮及内容按压反馈。
  final Widget child;

  /// 创建仅属于当前选项的指针状态。
  @override
  State<_OmniSegmentHoverSurface> createState() =>
      _OmniSegmentHoverSurfaceState();
}

/// 只淡入淡出背景，按钮内容和命中区域不随悬停改变。
class _OmniSegmentHoverSurfaceState extends State<_OmniSegmentHoverSurface> {
  /// 指针是否仍停留在当前选项上。
  bool _hovered = false;

  /// 构建位于轨道上方且不消费手势的背景。
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedContainer(
              duration: OmniMotion.duration(context, OmniMotion.fast),
              curve: OmniMotion.standardCurve,
              decoration: BoxDecoration(
                color: _hovered && !widget.selected
                    ? widget.color
                    : widget.color.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(OmniRadius.control),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    ),
  );
}
