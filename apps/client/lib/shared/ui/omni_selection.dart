import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

import 'omni_press_feedback.dart';

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
    if (Theme.of(context).platform == TargetPlatform.windows) {
      // 整个热区只有外层 InkWell 负责鼠标、键盘和读屏操作。
      final VoidCallback? toggle = onChanged == null
          ? null
          : () {
              onChanged!(
                value == false
                    ? true
                    : value == true
                    ? (tristate ? null : false)
                    : false,
              );
            };
      return Semantics(
        checked: value ?? false,
        mixed: tristate ? value == null : null,
        enabled: onChanged != null,
        label: semanticLabel,
        child: Material(
          color: Colors.transparent,
          child: OmniInkWell(
            onTap: toggle,
            focusNode: focusNode,
            autofocus: autofocus,
            canRequestFocus: onChanged != null,
            customBorder: const CircleBorder(),
            child: IgnorePointer(
              child: ExcludeFocus(
                child: ExcludeSemantics(
                  child: Checkbox(
                    value: value,
                    onChanged: onChanged,
                    tristate: tristate,
                    isError: isError,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
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
    if (Theme.of(context).platform == TargetPlatform.windows) {
      return _WindowsRadioRow<T>(configuration: this);
    }
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

/// Windows 单选行保留 RadioGroup 注册，圆圈与标题只有一个手势宿主。
class _WindowsRadioRow<T> extends StatefulWidget {
  /// 原公共控件的全部语义和布局设置。
  final OmniRadioListTile<T> configuration;

  /// 创建由原生单选组管理的 Windows 行。
  const _WindowsRadioRow({required this.configuration});

  /// 创建单选组客户端与焦点状态。
  @override
  State<_WindowsRadioRow<T>> createState() => _WindowsRadioRowState<T>();
}

/// 使用公开 RadioClient 保留组方向键、循环选择和 Tab 遍历。
class _WindowsRadioRowState<T> extends State<_WindowsRadioRow<T>>
    with RadioClient<T> {
  /// 调用方没有提供焦点时由当前行管理。
  FocusNode? _ownedFocus;

  /// 当前反馈引用，仅用于组方向键选中的视觉脉冲。
  OmniPressController? _feedback;

  /// 上一帧是否被组选择。
  bool? _previousSelected;

  /// 当前行的公共配置。
  OmniRadioListTile<T> get _configuration => widget.configuration;

  /// 单选组用于识别当前行的值。
  @override
  T get radioValue => _configuration.value;

  /// 是否允许取消当前选择。
  @override
  bool get tristate => _configuration.toggleable;

  /// 禁用行不参与组方向键导航。
  @override
  bool get enabled => (_configuration.enabled ?? true) && registry != null;

  /// 组导航和行操作共享一个焦点。
  @override
  FocusNode get focusNode =>
      _configuration.focusNode ?? (_ownedFocus ??= FocusNode());

  /// 注册到最近的原生单选组并响应组选择变化。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    registry = RadioGroup.maybeOf<T>(context);
    _syncSelection();
  }

  /// 外部更换值或焦点节点时同步组注册。
  @override
  void didUpdateWidget(_WindowsRadioRow<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSelection();
  }

  /// 方向键由 RadioGroup 选择目标，视觉不重复提交选择。
  void _syncSelection() {
    // 当前组选择是否指向本行。
    final bool selected = registry?.groupValue == radioValue;
    if (_previousSelected == false && selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && focusNode.hasFocus) _feedback?.activate();
      });
    }
    _previousSelected = selected;
  }

  /// 鼠标与读屏沿用原生单选组的取消与选择规则。
  void _select() {
    if (!enabled) return;
    // 已选择且不可取消时保留现值。
    final bool selected = registry?.groupValue == radioValue;
    if (selected && !tristate) return;
    registry!.onChanged(selected ? null : radioValue);
  }

  /// 只观察空格按下与释放，事件继续交给 RadioGroup，不重复提交选择。
  KeyEventResult _observeSpace(FocusNode node, KeyEvent event) {
    if (enabled &&
        focusNode.hasFocus &&
        event.logicalKey == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        _feedback?.setPressed(true);
      } else if (event is KeyUpEvent) {
        _feedback?.setPressed(false);
        _feedback?.activate();
      }
    }
    return KeyEventResult.ignored;
  }

  /// 仅缩放圆圈、文字和说明，背景与热区由外层 InkWell 保持。
  @override
  Widget build(BuildContext context) {
    // 单选语义使用组真实值。
    final bool selected = registry?.groupValue == radioValue;
    return OmniPressBinding(
      enabled: enabled,
      builder: (context, feedback) {
        _feedback = feedback;
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _observeSpace,
          child: Semantics(
            checked: selected,
            inMutuallyExclusiveGroup: true,
            enabled: enabled,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                statesController: feedback.statesController,
                onTap: enabled
                    ? () {
                        feedback.activate();
                        _select();
                      }
                    : null,
                onTapCancel: feedback.cancel,
                focusNode: focusNode,
                autofocus: _configuration.autofocus,
                canRequestFocus: enabled,
                borderRadius: BorderRadius.circular(OmniRadius.control),
                child: OmniPressContent(
                  controller: feedback,
                  child: ListTile(
                    enabled: enabled,
                    isThreeLine: _configuration.isThreeLine,
                    title: _configuration.title,
                    subtitle: _configuration.subtitle,
                    contentPadding:
                        _configuration.contentPadding ??
                        const EdgeInsets.symmetric(
                          horizontal: OmniSpacing.sm,
                          vertical: OmniSpacing.xxs,
                        ),
                    leading: IgnorePointer(
                      child: ExcludeFocus(
                        child: ExcludeSemantics(
                          child: RadioGroup<bool>(
                            groupValue: selected,
                            onChanged: (_) {},
                            child: Radio<bool>(
                              value: true,
                              enabled: enabled,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 退出时注销组客户端并只释放自己拥有的焦点。
  @override
  void dispose() {
    registry = null;
    _ownedFocus?.dispose();
    super.dispose();
  }
}
