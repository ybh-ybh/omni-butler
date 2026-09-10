import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 飞书式下拉菜单的统一尺寸。
abstract final class OmniDropdownMetrics {
  /// 独立下拉按钮的默认宽度。
  static const double triggerWidth = 160;

  /// 单个菜单项的紧凑高度。
  static const double itemHeight = 36;

  /// 下拉菜单允许展示的最大高度。
  static const double menuMaxHeight = 320;

  /// 操作菜单的最小宽度。
  static const double actionMenuMinWidth = 160;

  /// 操作菜单的最大宽度。
  static const double actionMenuMaxWidth = 280;
}

/// 飞书式下拉菜单的统一动效。
abstract final class OmniDropdownMotion {
  /// 菜单内容快速淡入时长。
  static const Duration reveal = Duration(milliseconds: 90);
}

/// 统一的独立下拉选择按钮。
class OmniDropdownButton<T> extends StatelessWidget {
  /// 当前选中的值。
  final T? value;

  /// 未选择时的提示内容。
  final Widget? hint;

  /// 可选择的菜单项。
  final List<DropdownMenuItem<T>> items;

  /// 选中值变化回调；为空时禁用控件。
  final ValueChanged<T?>? onChanged;

  /// 控件与菜单的固定宽度。
  final double width;

  /// 独立下拉控件的固定高度。
  final double height;

  /// 控件焦点节点。
  final FocusNode? focusNode;

  /// 是否自动获取焦点。
  final bool autofocus;

  /// 创建独立下拉选择按钮。
  const OmniDropdownButton({
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.width = OmniDropdownMetrics.triggerWidth,
    this.height = OmniSize.control,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  /// 构建固定宽度的飞书式选择控件。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: _OmniDropdownControl<T>(
        value: value,
        hint: hint,
        items: items,
        onChanged: onChanged,
        height: height,
        focusNode: focusNode,
        autofocus: autofocus,
      ),
    );
  }
}

/// 统一的表单下拉选择框。
class OmniDropdownButtonFormField<T> extends FormField<T> {
  /// 创建带输入框外观和表单校验能力的下拉选择框。
  OmniDropdownButtonFormField({
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?>? onChanged,
    super.initialValue,
    Widget? hint,
    InputDecoration decoration = const InputDecoration(),
    FocusNode? focusNode,
    bool autofocus = false,
    super.onSaved,
    super.validator,
    AutovalidateMode? autovalidateMode,
    super.key,
  }) : super(
         autovalidateMode: autovalidateMode ?? AutovalidateMode.disabled,
         builder: (FormFieldState<T> field) {
           // 将表单错误合并到调用方提供的输入框装饰中。
           final InputDecoration effectiveDecoration = decoration.copyWith(
             errorText: field.errorText,
           );
           return _OmniDropdownControl<T>(
             value: field.value,
             hint: hint,
             items: items,
             onChanged: onChanged == null
                 ? null
                 : (T? value) {
                     field.didChange(value);
                     onChanged(value);
                   },
             decoration: effectiveDecoration,
             focusNode: focusNode,
             autofocus: autofocus,
           );
         },
       );
}

/// 统一的操作菜单按钮。
class OmniPopupMenuButton<T> extends StatelessWidget {
  /// 菜单项构建器。
  final PopupMenuItemBuilder<T> itemBuilder;

  /// 当前值，用于标记初始菜单项。
  final T? initialValue;

  /// 菜单打开回调。
  final VoidCallback? onOpened;

  /// 菜单选中回调。
  final PopupMenuItemSelected<T>? onSelected;

  /// 菜单取消回调。
  final PopupMenuCanceled? onCanceled;

  /// 按钮提示文字。
  final String? tooltip;

  /// 自定义按钮图标。
  final Widget? icon;

  /// 自定义按钮内容。
  final Widget? child;

  /// 按钮是否可用。
  final bool enabled;

  /// 自定义菜单尺寸约束；为空时使用默认操作菜单尺寸。
  final BoxConstraints? menuConstraints;

  /// 创建统一操作菜单按钮。
  const OmniPopupMenuButton({
    required this.itemBuilder,
    this.initialValue,
    this.onOpened,
    this.onSelected,
    this.onCanceled,
    this.tooltip,
    this.icon,
    this.child,
    this.enabled = true,
    this.menuConstraints,
    super.key,
  }) : assert(child == null || icon == null, 'child 与 icon 不能同时设置');

  /// 构建从按钮下方展开的紧凑菜单。
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      initialValue: initialValue,
      onOpened: onOpened,
      onSelected: onSelected,
      onCanceled: onCanceled,
      tooltip: tooltip,
      icon:
          icon ?? (child == null ? const Icon(Icons.more_horiz_rounded) : null),
      enabled: enabled,
      position: PopupMenuPosition.under,
      offset: const Offset(0, OmniSpacing.xxs),
      menuPadding: const EdgeInsets.all(OmniSpacing.xxs),
      constraints:
          menuConstraints ??
          const BoxConstraints(
            minWidth: OmniDropdownMetrics.actionMenuMinWidth,
            maxWidth: OmniDropdownMetrics.actionMenuMaxWidth,
          ),
      popUpAnimationStyle: const AnimationStyle(
        duration: OmniMotion.fast,
        reverseDuration: OmniMotion.fast,
        curve: OmniMotion.standardCurve,
        reverseCurve: OmniMotion.standardCurve,
      ),
      itemBuilder: itemBuilder,
      child: child,
    );
  }
}

/// 统一的带图标操作菜单项。
class OmniPopupMenuItem<T> extends PopupMenuItem<T> {
  /// 创建紧凑操作菜单项。
  OmniPopupMenuItem({
    required T value,
    required String label,
    required IconData icon,
    bool danger = false,
    super.enabled = true,
    super.onTap,
    super.key,
  }) : super(
         value: value,
         height: OmniDropdownMetrics.itemHeight,
         padding: EdgeInsets.zero,
         child: _OmniPopupMenuItemContent(
           label: label,
           icon: icon,
           danger: danger,
         ),
       );
}

/// 下拉选择控件的菜单与触发器实现。
class _OmniDropdownControl<T> extends StatefulWidget {
  /// 当前选中的值。
  final T? value;

  /// 未选择时的提示内容。
  final Widget? hint;

  /// 可选择的菜单项。
  final List<DropdownMenuItem<T>> items;

  /// 选中值变化回调。
  final ValueChanged<T?>? onChanged;

  /// 表单模式下的输入框装饰。
  final InputDecoration? decoration;

  /// 独立下拉控件的固定高度。
  final double height;

  /// 控件焦点节点。
  final FocusNode? focusNode;

  /// 是否自动获取焦点。
  final bool autofocus;

  /// 创建下拉选择控件实现。
  const _OmniDropdownControl({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.hint,
    required this.focusNode,
    required this.autofocus,
    this.height = OmniSize.control,
    this.decoration,
  });

  /// 创建控件状态。
  @override
  State<_OmniDropdownControl<T>> createState() =>
      _OmniDropdownControlState<T>();
}

/// 下拉选择控件状态。
class _OmniDropdownControlState<T> extends State<_OmniDropdownControl<T>> {
  /// 下拉菜单控制器。
  final MenuController _menuController = MenuController();

  /// 内部焦点节点。
  FocusNode? _internalFocusNode;

  /// 菜单是否正在展示。
  bool _menuOpen = false;

  /// 触发器是否持有焦点。
  bool _focused = false;

  /// 当前实际使用的焦点节点。
  FocusNode get _effectiveFocusNode =>
      widget.focusNode ?? (_internalFocusNode ??= FocusNode());

  /// 释放内部焦点节点。
  @override
  void dispose() {
    _internalFocusNode?.dispose();
    super.dispose();
  }

  /// 切换下拉菜单开关状态。
  void _toggleMenu() {
    if (_menuController.isOpen) {
      _menuController.close();
      return;
    }
    _menuController.open();
  }

  /// 记录菜单已打开。
  void _handleMenuOpen() {
    if (mounted) {
      setState(() => _menuOpen = true);
    }
  }

  /// 记录菜单已关闭。
  void _handleMenuClose() {
    if (mounted) {
      // 菜单关闭后释放触发器的临时焦点，避免关闭状态残留蓝色边框。
      _effectiveFocusNode.unfocus();
      setState(() => _menuOpen = false);
    }
  }

  /// 记录触发器焦点状态。
  void _handleFocusChange(bool focused) {
    setState(() => _focused = focused);
  }

  /// 返回与当前值匹配的菜单项。
  DropdownMenuItem<T>? _selectedItem() {
    for (final DropdownMenuItem<T> item in widget.items) {
      if (item.value == widget.value) {
        return item;
      }
    }
    return null;
  }

  /// 处理菜单项选择。
  void _selectItem(DropdownMenuItem<T> item) {
    item.onTap?.call();
    widget.onChanged?.call(item.value);
  }

  /// 构建统一菜单样式。
  MenuStyle _menuStyle(OmniColors colors, double menuWidth) {
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll<Color>(colors.paper),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      shadowColor: WidgetStatePropertyAll<Color>(
        Colors.black.withValues(alpha: 0.12),
      ),
      elevation: const WidgetStatePropertyAll<double>(6),
      side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: colors.line)),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.panel),
        ),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.all(OmniSpacing.xxs),
      ),
      minimumSize: WidgetStatePropertyAll<Size>(Size(menuWidth, 0)),
      maximumSize: WidgetStatePropertyAll<Size>(
        Size(menuWidth, OmniDropdownMetrics.menuMaxHeight),
      ),
    );
  }

  /// 构建单个选择菜单项样式。
  ButtonStyle _itemStyle(OmniColors colors, {required bool selected}) {
    return ButtonStyle(
      minimumSize: const WidgetStatePropertyAll<Size>(
        Size(0, OmniDropdownMetrics.itemHeight),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      alignment: AlignmentDirectional.centerStart,
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
      ),
      foregroundColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.disabled)) {
          return colors.muted.withValues(alpha: 0.45);
        }
        return selected ? colors.brandStrong : colors.ink;
      }),
      backgroundColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.pressed)) {
          return selected ? colors.brandSoft : colors.mist;
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return selected ? colors.brandSoft : colors.paperSubtle;
        }
        return selected ? colors.brandSoft : Colors.transparent;
      }),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      textStyle: const WidgetStatePropertyAll<TextStyle>(
        TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
      ),
    );
  }

  /// 构建所有选择菜单项。
  List<Widget> _menuItems(OmniColors colors) {
    // 系统是否要求关闭动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return widget.items
        .map((DropdownMenuItem<T> item) {
          // 当前菜单项是否被选中。
          final bool selected = item.value == widget.value;
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: disableAnimations
                ? Duration.zero
                : OmniDropdownMotion.reveal,
            curve: OmniMotion.standardCurve,
            builder: (BuildContext context, double opacity, Widget? child) {
              return Opacity(opacity: opacity, child: child);
            },
            child: MenuItemButton(
              onPressed: item.enabled && widget.onChanged != null
                  ? () => _selectItem(item)
                  : null,
              leadingIcon: SizedBox.square(
                dimension: 16,
                child: selected
                    ? Icon(Icons.check_rounded, size: 16, color: colors.brand)
                    : null,
              ),
              style: _itemStyle(colors, selected: selected),
              child: DefaultTextStyle.merge(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: item.child,
              ),
            ),
          );
        })
        .toList(growable: false);
  }

  /// 构建触发器中的当前值和箭头。
  Widget _triggerContent(OmniColors colors) {
    // 当前选中的完整菜单项。
    final DropdownMenuItem<T>? selectedItem = _selectedItem();
    // 触发器中展示的值或提示内容。
    final Widget content =
        selectedItem?.child ?? widget.hint ?? const SizedBox();
    // 系统是否要求关闭动画。
    final bool disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Row(
      children: <Widget>[
        Expanded(
          child: DefaultTextStyle.merge(
            style: TextStyle(
              color: selectedItem == null ? colors.muted : colors.ink,
              fontSize: 14,
              fontWeight: FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: content,
          ),
        ),
        const SizedBox(width: OmniSpacing.xs),
        AnimatedRotation(
          turns: _menuOpen ? 0.5 : 0,
          duration: disableAnimations ? Duration.zero : OmniMotion.fast,
          curve: OmniMotion.standardCurve,
          child: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: OmniSize.icon,
            color: widget.onChanged == null
                ? colors.muted.withValues(alpha: 0.45)
                : colors.muted,
          ),
        ),
      ],
    );
  }

  /// 构建独立按钮模式的触发器。
  Widget _standaloneTrigger(OmniColors colors) {
    // 当前是否应展示品牌焦点边框。
    final bool highlighted = _menuOpen || _focused;
    return AnimatedContainer(
      duration: OmniMotion.fast,
      curve: OmniMotion.standardCurve,
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
      decoration: BoxDecoration(
        color: widget.onChanged == null ? colors.paperSubtle : colors.paper,
        borderRadius: BorderRadius.circular(OmniRadius.control),
        border: Border.all(
          color: highlighted ? colors.brand : colors.line,
          width: highlighted ? 1.5 : 1,
        ),
      ),
      child: _triggerContent(colors),
    );
  }

  /// 构建表单模式的触发器。
  Widget _formTrigger(OmniColors colors) {
    // 应用主题默认值后的输入框装饰。
    final InputDecoration effectiveDecoration = widget.decoration!
        .applyDefaults(Theme.of(context).inputDecorationTheme)
        .copyWith(enabled: widget.onChanged != null);
    return InputDecorator(
      decoration: effectiveDecoration,
      isFocused: _menuOpen || _focused,
      isEmpty: _selectedItem() == null,
      child: _triggerContent(colors),
    );
  }

  /// 构建指定宽度的菜单锚点和触发器。
  Widget _buildMenuAnchor(OmniColors colors, double menuWidth) {
    // 当前控件是否使用表单输入框外观。
    final bool formMode = widget.decoration != null;
    return MenuAnchor(
      controller: _menuController,
      childFocusNode: _effectiveFocusNode,
      style: _menuStyle(colors, menuWidth),
      alignmentOffset: const Offset(0, OmniSpacing.xxs),
      crossAxisUnconstrained: false,
      useRootOverlay: true,
      animated: false,
      onOpen: _handleMenuOpen,
      onClose: _handleMenuClose,
      menuChildren: _menuItems(colors),
      builder:
          (BuildContext context, MenuController controller, Widget? child) {
            return Semantics(
              button: true,
              enabled: widget.onChanged != null,
              expanded: _menuOpen,
              child: InkWell(
                focusNode: _effectiveFocusNode,
                autofocus: widget.autofocus,
                onFocusChange: _handleFocusChange,
                onTap: widget.onChanged == null ? null : _toggleMenu,
                borderRadius: BorderRadius.circular(OmniRadius.control),
                hoverColor: colors.paperSubtle,
                focusColor: Colors.transparent,
                highlightColor: Colors.transparent,
                child: formMode
                    ? _formTrigger(colors)
                    : _standaloneTrigger(colors),
              ),
            );
          },
    );
  }

  /// 构建支持鼠标、键盘和焦点反馈的下拉选择控件。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 菜单宽度优先跟随触发器的实际宽度。
        final double menuWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : OmniDropdownMetrics.triggerWidth;
        return _buildMenuAnchor(colors, menuWidth);
      },
    );
  }
}

/// 操作菜单项中的图标与文字。
class _OmniPopupMenuItemContent extends StatelessWidget {
  /// 菜单文字。
  final String label;

  /// 菜单图标。
  final IconData icon;

  /// 是否使用危险操作配色。
  final bool danger;

  /// 创建操作菜单项内容。
  const _OmniPopupMenuItemContent({
    required this.label,
    required this.icon,
    required this.danger,
  });

  /// 构建对齐的图标与文字。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 菜单项前景色。
    final Color foreground = danger ? colors.danger : colors.ink;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 14,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
