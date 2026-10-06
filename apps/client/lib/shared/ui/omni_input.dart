import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 为输入框补全统一装饰，保留校验文案和受控的嵌入式覆盖。
InputDecoration _inputDecoration(
  BuildContext context,
  InputDecoration decoration, {
  required bool multiline,
}) {
  // 当前主题定义的统一边框、填充和焦点样式。
  final InputDecoration effective = decoration.applyDefaults(
    Theme.of(context).inputDecorationTheme,
  );
  return effective.copyWith(
    alignLabelWithHint: effective.alignLabelWithHint ?? multiline,
    errorMaxLines: effective.errorMaxLines ?? 3,
    helperMaxLines: effective.helperMaxLines ?? 3,
    contentPadding:
        decoration.contentPadding ??
        EdgeInsets.symmetric(
          horizontal: OmniSpacing.sm,
          vertical: OmniDensity.isTouch(context)
              ? OmniSpacing.sm
              : OmniSpacing.xs,
        ),
    constraints:
        decoration.constraints ??
        BoxConstraints(minHeight: OmniDensity.controlHeight(context)),
  );
}

/// 统一视觉的普通输入框，保留 Flutter 编辑、输入法和焦点行为。
class OmniTextField extends StatelessWidget {
  /// 输入内容控制器。
  final TextEditingController? controller;

  /// 键盘焦点节点。
  final FocusNode? focusNode;

  /// 字段文案与可选嵌入式装饰。
  final InputDecoration decoration;

  /// 软键盘类型。
  final TextInputType? keyboardType;

  /// 软键盘操作。
  final TextInputAction? textInputAction;

  /// 自动大小写策略。
  final TextCapitalization textCapitalization;

  /// 可选内容文字样式。
  final TextStyle? style;

  /// 内容水平对齐。
  final TextAlign textAlign;

  /// 内容垂直对齐。
  final TextAlignVertical? textAlignVertical;

  /// 是否自动聚焦。
  final bool autofocus;

  /// 是否只读并允许选择文字。
  final bool readOnly;

  /// 是否隐藏敏感输入。
  final bool obscureText;

  /// 是否使用输入法自动纠错。
  final bool autocorrect;

  /// 是否显示输入法建议。
  final bool enableSuggestions;

  /// 最大行数，空值允许自动扩展。
  final int? maxLines;

  /// 最小行数。
  final int? minLines;

  /// 是否填满父容器高度。
  final bool expands;

  /// 允许的最大字符数。
  final int? maxLength;

  /// 字符数限制与输入法组合文字的处理策略。
  final MaxLengthEnforcement? maxLengthEnforcement;

  /// 内容变化回调。
  final ValueChanged<String>? onChanged;

  /// 输入完成回调。
  final VoidCallback? onEditingComplete;

  /// 点击输入框回调。
  final VoidCallback? onTap;

  /// 点击输入区域之外的回调。
  final TapRegionCallback? onTapOutside;

  /// 输入格式过滤规则。
  final List<TextInputFormatter>? inputFormatters;

  /// 是否允许编辑。
  final bool? enabled;

  /// 是否显示输入光标。
  final bool? showCursor;

  /// 是否允许交互式选择文字。
  final bool enableInteractiveSelection;

  /// 系统自动填充提示。
  final Iterable<String>? autofillHints;

  /// 光标滚入可见区域时保留的边距。
  final EdgeInsets scrollPadding;

  /// 输入状态恢复标识。
  final String? restorationId;

  /// 提交输入内容的回调。
  final ValueChanged<String>? onSubmitted;

  /// 创建统一文本输入框。
  const OmniTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.autofocus = false,
    this.readOnly = false,
    this.obscureText = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.maxLength,
    this.maxLengthEnforcement,
    this.onChanged,
    this.onEditingComplete,
    this.onTap,
    this.onTapOutside,
    this.inputFormatters,
    this.enabled,
    this.showCursor,
    this.enableInteractiveSelection = true,
    this.autofillHints,
    this.scrollPadding = const EdgeInsets.all(20),
    this.restorationId,
    this.onSubmitted,
  });

  /// 构建原生编辑能力与共享输入装饰。
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      decoration: _inputDecoration(
        context,
        decoration,
        multiline: maxLines != 1,
      ),
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      style: style,
      textAlign: textAlign,
      textAlignVertical: textAlignVertical,
      autofocus: autofocus,
      readOnly: readOnly,
      obscureText: obscureText,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      maxLines: maxLines,
      minLines: minLines,
      expands: expands,
      maxLength: maxLength,
      maxLengthEnforcement: maxLengthEnforcement,
      onChanged: onChanged,
      onEditingComplete: onEditingComplete,
      onTap: onTap,
      onTapOutside: onTapOutside,
      inputFormatters: inputFormatters,
      enabled: enabled,
      showCursor: showCursor,
      enableInteractiveSelection: enableInteractiveSelection,
      autofillHints: autofillHints,
      scrollPadding: scrollPadding,
      restorationId: restorationId,
      onSubmitted: onSubmitted,
    );
  }
}

/// 统一视觉的表单字段，保存与校验仍由 Flutter Form 管理。
class OmniTextFormField extends StatelessWidget {
  /// 输入内容控制器。
  final TextEditingController? controller;

  /// 键盘焦点节点。
  final FocusNode? focusNode;

  /// 字段文案与可选嵌入式装饰。
  final InputDecoration decoration;

  /// 软键盘类型。
  final TextInputType? keyboardType;

  /// 软键盘操作。
  final TextInputAction? textInputAction;

  /// 自动大小写策略。
  final TextCapitalization textCapitalization;

  /// 可选内容文字样式。
  final TextStyle? style;

  /// 内容水平对齐。
  final TextAlign textAlign;

  /// 内容垂直对齐。
  final TextAlignVertical? textAlignVertical;

  /// 是否自动聚焦。
  final bool autofocus;

  /// 是否只读并允许选择文字。
  final bool readOnly;

  /// 是否隐藏敏感输入。
  final bool obscureText;

  /// 是否使用输入法自动纠错。
  final bool autocorrect;

  /// 是否显示输入法建议。
  final bool enableSuggestions;

  /// 最大行数，空值允许自动扩展。
  final int? maxLines;

  /// 最小行数。
  final int? minLines;

  /// 是否填满父容器高度。
  final bool expands;

  /// 允许的最大字符数。
  final int? maxLength;

  /// 字符数限制与输入法组合文字的处理策略。
  final MaxLengthEnforcement? maxLengthEnforcement;

  /// 内容变化回调。
  final ValueChanged<String>? onChanged;

  /// 输入完成回调。
  final VoidCallback? onEditingComplete;

  /// 点击输入框回调。
  final VoidCallback? onTap;

  /// 点击输入区域之外的回调。
  final TapRegionCallback? onTapOutside;

  /// 输入格式过滤规则。
  final List<TextInputFormatter>? inputFormatters;

  /// 是否允许编辑。
  final bool? enabled;

  /// 是否显示输入光标。
  final bool? showCursor;

  /// 是否允许交互式选择文字。
  final bool enableInteractiveSelection;

  /// 系统自动填充提示。
  final Iterable<String>? autofillHints;

  /// 光标滚入可见区域时保留的边距。
  final EdgeInsets scrollPadding;

  /// 输入状态恢复标识。
  final String? restorationId;

  /// 未提供控制器时的初始内容。
  final String? initialValue;

  /// 由业务模块提供的校验规则。
  final FormFieldValidator<String>? validator;

  /// 表单保存回调。
  final FormFieldSetter<String>? onSaved;

  /// 提交当前字段的回调。
  final ValueChanged<String>? onFieldSubmitted;

  /// 自动校验时机。
  final AutovalidateMode? autovalidateMode;

  /// 可选外部错误文案。
  final String? forceErrorText;

  /// 创建统一表单输入框。
  const OmniTextFormField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.autofocus = false,
    this.readOnly = false,
    this.obscureText = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.maxLength,
    this.maxLengthEnforcement,
    this.onChanged,
    this.onEditingComplete,
    this.onTap,
    this.onTapOutside,
    this.inputFormatters,
    this.enabled,
    this.showCursor,
    this.enableInteractiveSelection = true,
    this.autofillHints,
    this.scrollPadding = const EdgeInsets.all(20),
    this.restorationId,
    this.initialValue,
    this.validator,
    this.onSaved,
    this.onFieldSubmitted,
    this.autovalidateMode,
    this.forceErrorText,
  });

  /// 构建原生编辑能力与共享输入装饰。
  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      decoration: _inputDecoration(
        context,
        decoration,
        multiline: maxLines != 1,
      ),
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      style: style,
      textAlign: textAlign,
      textAlignVertical: textAlignVertical,
      autofocus: autofocus,
      readOnly: readOnly,
      obscureText: obscureText,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      maxLines: maxLines,
      minLines: minLines,
      expands: expands,
      maxLength: maxLength,
      maxLengthEnforcement: maxLengthEnforcement,
      onChanged: onChanged,
      onEditingComplete: onEditingComplete,
      onTap: onTap,
      onTapOutside: onTapOutside,
      inputFormatters: inputFormatters,
      enabled: enabled,
      showCursor: showCursor,
      enableInteractiveSelection: enableInteractiveSelection,
      autofillHints: autofillHints,
      scrollPadding: scrollPadding,
      restorationId: restorationId,
      initialValue: initialValue,
      validator: validator,
      onSaved: onSaved,
      onFieldSubmitted: onFieldSubmitted,
      autovalidateMode: autovalidateMode,
      forceErrorText: forceErrorText,
    );
  }
}
