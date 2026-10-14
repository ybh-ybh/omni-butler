import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 可多选的标签沿用物品筛选气泡的圆角、密度及描边层级。
class OmniTaxonomyChip extends StatelessWidget {
  /// 创建保留原生选择语义的紧凑标签。
  const OmniTaxonomyChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  /// 标签的当前规范名称。
  final String label;

  /// 是否关联当前笔记。
  final bool selected;

  /// 禁用时为空，外观与选中信息继续可见。
  final ValueChanged<bool>? onSelected;

  /// 尺寸沿用物品ChoiceChip，操作色跟随所在笔记主题。
  @override
  Widget build(BuildContext context) {
    // 当前主题的主操作色与中性表面。
    final OmniColors colors = OmniColors.of(context);
    return FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: onSelected,
      mouseCursor: onSelected == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
      backgroundColor: colors.paper,
      selectedColor: colors.brand.withValues(alpha: 0.12),
      side: BorderSide(
        color: selected ? colors.brand.withValues(alpha: 0.42) : colors.line,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadius.control),
      ),
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: selected ? colors.brand : colors.muted,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }
}
