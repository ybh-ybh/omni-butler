import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// Omni Butler 统一的小尺寸开关。
class OmniSwitch extends StatelessWidget {
  /// 开关当前值。
  final bool value;

  /// 开关值变更回调。
  final ValueChanged<bool>? onChanged;

  /// 创建统一小尺寸开关。
  const OmniSwitch({required this.value, required this.onChanged, super.key});

  /// 构建保留完整点击区域的小尺寸开关。
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: SizedBox(
        width: OmniSize.touch,
        height: OmniSize.controlLarge,
        child: Center(
          child: Transform.scale(
            scale: OmniSize.switchVisualScale,
            child: Switch.adaptive(value: value, onChanged: onChanged),
          ),
        ),
      ),
    );
  }
}

/// 带标题的统一小尺寸开关列表项。
class OmniSwitchListTile extends StatelessWidget {
  /// 开关当前值。
  final bool value;

  /// 开关值变更回调。
  final ValueChanged<bool>? onChanged;

  /// 列表项标题。
  final Widget title;

  /// 列表项内容边距。
  final EdgeInsetsGeometry? contentPadding;

  /// 创建带标题的小尺寸开关列表项。
  const OmniSwitchListTile({
    required this.value,
    required this.onChanged,
    required this.title,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: OmniSpacing.sm,
      vertical: 2,
    ),
    super.key,
  });

  /// 构建整行可点击且语义完整的开关列表项。
  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      child: ListTile(
        contentPadding: contentPadding,
        title: title,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: ExcludeSemantics(
          child: OmniSwitch(value: value, onChanged: onChanged),
        ),
      ),
    );
  }
}
