import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 带连续轨道与滑块动画的通用分段选择控件。
class OmniSlidingSegmentedControl<T> extends StatelessWidget {
  /// 按展示顺序排列的选项。
  final List<T> options;

  /// 当前选中的选项。
  final T selected;

  /// 控件总宽度。
  final double width;

  /// 控件总高度。
  final double height;

  /// 是否嵌入由上层提供外框的组合控件。
  final bool embedded;

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
    final bool disableAnimation =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.of(context).accessibleNavigation;
    // 滑块动画时长。
    final Duration animationDuration = disableAnimation
        ? Duration.zero
        : OmniMotion.normal;
    // 当前滑块在连续轨道中的对齐位置。
    final double indicatorAlignment = options.length == 1
        ? 0
        : -1 + (2 * selectedIndex / (options.length - 1));

    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: embedded ? Colors.transparent : scheme.surface,
        borderRadius: BorderRadius.circular(
          embedded ? OmniRadius.control : OmniRadius.dialog,
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
          Row(
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
                      return Semantics(
                        button: true,
                        selected: isSelected,
                        label: labelBuilder(option),
                        child: InkWell(
                          key: itemKeyBuilder?.call(option),
                          borderRadius: BorderRadius.circular(
                            OmniRadius.control,
                          ),
                          onTap: () => onChanged(option),
                          child: Center(child: item),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
