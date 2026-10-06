import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 统一三态复选框，继续使用 Flutter 的键盘与读屏交互。
class OmniCheckbox extends StatelessWidget {
  /// 当前选中状态，三态模式允许空值。
  final bool? value;

  /// 状态变化回调，为空时禁用。
  final ValueChanged<bool?>? onChanged;

  /// 是否允许未确定状态。
  final bool tristate;

  /// 无障碍操作名称。
  final String? semanticLabel;

  /// 键盘焦点节点。
  final FocusNode? focusNode;

  /// 是否自动聚焦。
  final bool autofocus;

  /// 是否显示校验错误。
  final bool isError;

  /// 创建统一复选框。
  const OmniCheckbox({
    required this.value,
    required this.onChanged,
    this.tristate = false,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
    this.isError = false,
    super.key,
  });

  /// 构建由应用主题统一形状和状态颜色的复选框。
  @override
  Widget build(BuildContext context) {
    return Checkbox(
      value: value,
      onChanged: onChanged,
      tristate: tristate,
      semanticLabel: semanticLabel,
      focusNode: focusNode,
      autofocus: autofocus,
      isError: isError,
      visualDensity: OmniDensity.isTouch(context)
          ? VisualDensity.standard
          : null,
      materialTapTargetSize: OmniDensity.isTouch(context)
          ? MaterialTapTargetSize.padded
          : MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// 由父级 RadioGroup 管理选择与方向键行为的统一单选行。
class OmniRadioListTile<T> extends StatelessWidget {
  /// 该选项代表的值。
  final T value;

  /// 选项标题。
  final Widget? title;

  /// 选项解释。
  final Widget? subtitle;

  /// 是否允许选择。
  final bool? enabled;

  /// 是否显示为三行内容。
  final bool isThreeLine;

  /// 是否在已经选中时允许取消。
  final bool toggleable;

  /// 可选行内边距。
  final EdgeInsetsGeometry? contentPadding;

  /// 键盘焦点节点。
  final FocusNode? focusNode;

  /// 是否自动聚焦。
  final bool autofocus;

  /// 创建统一单选行。
  const OmniRadioListTile({
    required this.value,
    this.title,
    this.subtitle,
    this.enabled,
    this.isThreeLine = false,
    this.toggleable = false,
    this.contentPadding,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  /// 构建继承同一组方向键和语义能力的单选行。
  @override
  Widget build(BuildContext context) {
    return RadioListTile<T>(
      value: value,
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      isThreeLine: isThreeLine,
      toggleable: toggleable,
      contentPadding:
          contentPadding ??
          const EdgeInsets.symmetric(
            horizontal: OmniSpacing.sm,
            vertical: OmniSpacing.xxs,
          ),
      focusNode: focusNode,
      autofocus: autofocus,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(OmniRadius.control)),
      ),
    );
  }
}
