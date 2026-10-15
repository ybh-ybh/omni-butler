import 'dart:async';

import 'package:flutter/material.dart';

import 'omni_windows_semantics_boundary.dart';

import 'package:omni_butler/shared/ui/omni_icon_button.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_press_surface.dart';
import 'package:omni_butler/shared/ui/omni_press_feedback.dart';
import 'package:omni_butler/shared/ui/omni_menu_route.dart';

/// 统一下拉菜单的尺寸。
abstract final class OmniDropdownMetrics {
  /// 独立下拉按钮的默认宽度。
  static const double triggerWidth = 160;

  /// 单个菜单项的紧凑高度。
  static const double itemHeight = OmniMenuMetrics.itemHeight;

  /// 下拉菜单允许展示的最大高度。
  static const double menuMaxHeight = 320;

  /// 操作菜单的最小宽度。
  static const double actionMenuMinWidth = OmniMenuMetrics.minWidth;

  /// 操作菜单的最大宽度。
  static const double actionMenuMaxWidth = OmniMenuMetrics.maxWidth;
}

/// 统一下拉菜单的动效。
abstract final class OmniDropdownMotion {
  /// 菜单内容快速淡入时长。
  static const Duration reveal = Duration(milliseconds: 90);
}

/// 下拉菜单当前选项勾选标记的位置。
enum OmniDropdownSelectionIndicatorPosition {
  /// 勾选标记位于菜单项最左侧。
  leading,

  /// 勾选标记位于菜单项最右侧。
  trailing,
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

  /// 当前选项勾选标记的位置。
  final OmniDropdownSelectionIndicatorPosition selectionIndicatorPosition;

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
    this.selectionIndicatorPosition =
        OmniDropdownSelectionIndicatorPosition.leading,
    super.key,
  });

  /// 构建固定宽度的统一选择控件。
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
        selectionIndicatorPosition: selectionIndicatorPosition,
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
    OmniDropdownSelectionIndicatorPosition selectionIndicatorPosition =
        OmniDropdownSelectionIndicatorPosition.leading,
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
             selectionIndicatorPosition: selectionIndicatorPosition,
           );
         },
       );
}

/// 统一的操作菜单按钮。
class OmniPopupMenuButton<T> extends StatelessWidget {
  /// 业务可显式要求手形指针；为空时保留框架的本机默认行为。
  final MouseCursor? mouseCursor;

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

  /// 自定义按钮悬停与点击反馈的圆角。
  final BorderRadius? borderRadius;

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
    this.borderRadius,
    this.mouseCursor,
    super.key,
  }) : assert(child == null || icon == null, 'child 与 icon 不能同时设置');

  /// 构建从按钮下方展开的紧凑菜单。
  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform == TargetPlatform.windows) {
      return OmniWindowsSemanticsBoundary(
        child: _OmniWindowsPopupMenuButton<T>(configuration: this),
      );
    }
    // 菜单提示与其他图标的浮层锚点保持独立。
    final Widget button = PopupMenuButton<T>(
      initialValue: initialValue,
      onOpened: onOpened,
      onSelected: onSelected,
      onCanceled: onCanceled,
      tooltip: tooltip,
      borderRadius: borderRadius,
      padding:
          child == null && Theme.of(context).platform == TargetPlatform.windows
          ? EdgeInsets.zero
          : const EdgeInsets.all(OmniSpacing.xs),
      style: child == null
          ? OmniIconButton.styleOf(context).copyWith(
              mouseCursor: mouseCursor == null
                  ? null
                  : WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.disabled)
                          ? SystemMouseCursors.basic
                          : mouseCursor!,
                    ),
            )
          : null,
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
      popUpAnimationStyle: OmniMotion.reduce(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: OmniMotion.fast,
              reverseDuration: OmniMotion.fast,
              curve: OmniMotion.standardCurve,
              reverseCurve: Curves.easeInCubic,
            ),
      itemBuilder: itemBuilder,
      child: child,
    );
    return OmniWindowsSemanticsBoundary(child: button);
  }
}

/// 为 Windows 菜单保留原触发器接口，并切换到完整面板路由。
class _OmniWindowsPopupMenuButton<T> extends StatefulWidget {
  /// 调用方原有菜单配置。
  final OmniPopupMenuButton<T> configuration;

  /// 创建 Windows 专用的菜单触发器。
  const _OmniWindowsPopupMenuButton({required this.configuration});

  /// 创建菜单防重入与锚点状态。
  @override
  State<_OmniWindowsPopupMenuButton<T>> createState() =>
      _OmniWindowsPopupMenuButtonState<T>();
}

/// 管理 Windows 菜单生命周期，保留关闭后的触发器焦点。
class _OmniWindowsPopupMenuButtonState<T>
    extends State<_OmniWindowsPopupMenuButton<T>> {
  /// 菜单按钮自己的稳定焦点。
  final FocusNode _focusNode = FocusNode();

  /// 防止快速激活创建多个菜单。
  bool _menuOpen = false;

  /// 触发器卸载后供退出动画继续使用的位置。
  RelativeRect? _lastPosition;

  /// 菜单打开前缓存的触发器，布局回调不能读取已停用的 Element。
  RenderBox? _buttonRenderBox;

  /// 与触发器同属一个应用窗口的覆盖层。
  RenderBox? _overlayRenderBox;

  /// 释放菜单按钮焦点。
  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// 仅在有效的按钮激活阶段读取渲染对象，退出布局只使用缓存。
  void _captureAnchor() {
    // 当前仍在树中的触发器渲染对象。
    final RenderObject? button = context.findRenderObject();
    // 菜单使用的当前窗口覆盖层。
    final RenderObject? overlay = Navigator.of(context).overlay?.context
        .findRenderObject();
    _buttonRenderBox = button is RenderBox ? button : null;
    _overlayRenderBox = overlay is RenderBox ? overlay : null;
  }

  /// 根据当前窗口尺寸定位，退出期间不再访问失效的触发器。
  RelativeRect _positionBuilder(
    BuildContext menuContext,
    BoxConstraints constraints,
  ) {
    // 缓存的渲染对象可在 Element 停用后安全判断是否仍然挂载。
    final RenderBox? object = _buttonRenderBox;
    // 当前窗口覆盖层也可能已经开始卸载。
    final RenderBox? overlayObject = _overlayRenderBox;
    if (object != null &&
        object.attached &&
        overlayObject != null &&
        overlayObject.attached) {
      // 菜单与按钮下边缘保持固定间距。
      final Offset offset = Offset(0, object.size.height + OmniSpacing.xxs);
      _lastPosition = RelativeRect.fromRect(
        Rect.fromPoints(
          object.localToGlobal(offset, ancestor: overlayObject),
          object.localToGlobal(
            object.size.bottomRight(Offset.zero) + offset,
            ancestor: overlayObject,
          ),
        ),
        Offset.zero & overlayObject.size,
      );
    }
    return _lastPosition ??
        RelativeRect.fromSize(Rect.zero, constraints.biggest);
  }

  /// 创建菜单并只分派一次选中或取消回调。
  Future<void> _showMenu() async {
    // 当前菜单的完整业务配置。
    final OmniPopupMenuButton<T> configuration = widget.configuration;
    if (!configuration.enabled || _menuOpen) return;
    // 只构建一次条目，保留本次菜单期间的值和子树身份。
    final List<PopupMenuEntry<T>> items = configuration.itemBuilder(context);
    if (items.isEmpty) return;
    _captureAnchor();
    _focusNode.requestFocus();
    setState(() => _menuOpen = true);
    configuration.onOpened?.call();
    // 取消返回空值，与 PopupMenuButton 原有回调约定一致。
    final T? value = await showOmniMenu<T>(
      context: context,
      positionBuilder: _positionBuilder,
      items: items,
      initialValue: configuration.initialValue,
      constraints:
          configuration.menuConstraints ??
          const BoxConstraints(
            minWidth: OmniDropdownMetrics.actionMenuMinWidth,
            maxWidth: OmniDropdownMetrics.actionMenuMaxWidth,
          ),
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    if (value == null) {
      configuration.onCanceled?.call();
    } else {
      configuration.onSelected?.call(value);
    }
  }

  /// 保留图标按钮或自定义触发器的热区、提示及按压反馈。
  @override
  Widget build(BuildContext context) {
    // 当前菜单公开配置。
    final OmniPopupMenuButton<T> configuration = widget.configuration;
    // 未显式指定时沿用系统本地化菜单提示。
    final String tooltip =
        configuration.tooltip ??
        MaterialLocalizations.of(context).showMenuTooltip;
    // 图标菜单复用公共图标按钮，自定义内容保持原有尺寸。
    final Widget trigger = configuration.child == null
        ? OmniIconButton(
            focusNode: _focusNode,
            onPressed: configuration.enabled ? _showMenu : null,
            tooltip: tooltip,
            padding: EdgeInsets.zero,
            style: configuration.mouseCursor == null
                ? null
                : ButtonStyle(
                    mouseCursor: WidgetStateProperty.resolveWith<MouseCursor>(
                      (Set<WidgetState> states) =>
                          states.contains(WidgetState.disabled)
                          ? SystemMouseCursors.basic
                          : configuration.mouseCursor!,
                    ),
                  ),
            icon: configuration.icon ?? const Icon(Icons.more_horiz_rounded),
          )
        : Tooltip(
            message: tooltip,
            child: OmniInkWell(
              focusNode: _focusNode,
              canRequestFocus: configuration.enabled,
              mouseCursor: configuration.mouseCursor,
              borderRadius: configuration.borderRadius,
              onTap: configuration.enabled ? _showMenu : null,
              child: configuration.child,
            ),
          );
    return Semantics(expanded: _menuOpen, child: trigger);
  }
}

/// 将整行长按和读屏长按映射到原有操作菜单，不显示更多按钮。
class OmniContextMenu<T> extends StatefulWidget {
  /// 保留原点击和滚动行为的记录内容。
  final Widget child;

  /// 复用业务原有菜单项。
  final PopupMenuItemBuilder<T> itemBuilder;

  /// 菜单选择后的业务操作。
  final PopupMenuItemSelected<T> onSelected;

  /// 可选菜单宽度，默认沿用操作菜单尺寸。
  final BoxConstraints? menuConstraints;

  /// 创建没有可见触发按钮的操作菜单。
  const OmniContextMenu({
    required this.child,
    required this.itemBuilder,
    required this.onSelected,
    this.menuConstraints,
    super.key,
  });

  /// 创建菜单防重入状态。
  @override
  State<OmniContextMenu<T>> createState() => _OmniContextMenuState<T>();
}

/// 管理指针定位及读屏操作的共用菜单。
class _OmniContextMenuState<T> extends State<OmniContextMenu<T>> {
  /// 避免连续长按重复创建菜单路由。
  bool _menuOpen = false;

  /// 在当前导航覆盖层中按长按位置打开菜单。
  Future<void> _showContextMenu(Offset globalPosition) async {
    if (_menuOpen) return;
    _menuOpen = true;
    try {
      // 与原弹出菜单使用同一导航覆盖层。
      final RenderBox overlay =
          Navigator.of(context).overlay!.context.findRenderObject()!
              as RenderBox;
      // 将屏幕指针位置转换为覆盖层坐标。
      final Offset position = overlay.globalToLocal(globalPosition);
      // 取消时为空，仅选择有效操作后调用业务回调。
      final T? action = await showOmniMenu<T>(
        context: context,
        position: RelativeRect.fromRect(
          position & Size.zero,
          Offset.zero & overlay.size,
        ),
        menuPadding: const EdgeInsets.all(OmniSpacing.xxs),
        constraints:
            widget.menuConstraints ??
            const BoxConstraints(
              minWidth: OmniDropdownMetrics.actionMenuMinWidth,
              maxWidth: OmniDropdownMetrics.actionMenuMaxWidth,
            ),
        items: widget.itemBuilder(context),
      );
      if (mounted && action != null) widget.onSelected(action);
    } finally {
      _menuOpen = false;
    }
  }

  /// 读屏长按以当前记录中心定位，无需最后一次触屏坐标。
  void _showCenteredMenu() {
    // 当前记录的实际几何区域。
    final RenderBox box = context.findRenderObject()! as RenderBox;
    unawaited(
      _showContextMenu(box.localToGlobal(box.size.center(Offset.zero))),
    );
  }

  /// 长按只打开菜单，子控件的正常点按和列表纵滚保持不变。
  @override
  Widget build(BuildContext context) => Semantics(
    onLongPress: _showCenteredMenu,
    child: OmniPressSurface(
      excludeFromSemantics: true,
      onLongPressStart: (LongPressStartDetails details) =>
          unawaited(_showContextMenu(details.globalPosition)),
      child: widget.child,
    ),
  );
}

/// 统一的带图标操作菜单项。
class OmniPopupMenuItem<T> extends PopupMenuItem<T> {
  /// 危险操作使用独立的浅红悬停底色。
  final bool danger;

  /// 创建紧凑操作菜单项。
  OmniPopupMenuItem({
    required T value,
    required String label,
    required IconData? icon,
    this.danger = false,
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
           enabled: enabled,
         ),
       );

  /// 保留多行切换器等自定义内容，同时使用一致的行反馈。
  const OmniPopupMenuItem.custom({
    required T value,
    required Widget child,
    super.height = OmniDropdownMetrics.itemHeight,
    super.padding = EdgeInsets.zero,
    this.danger = false,
    super.enabled = true,
    super.onTap,
    super.key,
  }) : super(value: value, child: child);

  /// Windows 定制菜单行反馈，其他平台仍交给框架原有实现。
  @override
  PopupMenuItemState<T, OmniPopupMenuItem<T>> createState() =>
      _OmniPopupMenuItemState<T>();
}

/// 固定行底色与热区，仅让内部内容随按下缩放。
class _OmniPopupMenuItemState<T>
    extends PopupMenuItemState<T, OmniPopupMenuItem<T>> {
  /// 鼠标转键盘时从当前悬停行继续导航。
  final FocusNode _focusNode = FocusNode();

  /// 当前指针是否位于此菜单行。
  bool _hovered = false;

  /// 当前菜单行是否持有键盘焦点。
  bool _focused = false;

  /// 释放每行独立的焦点状态。
  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// 构建 Windows 行背景，保留原生菜单返回和辅助功能语义。
  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) {
      return super.build(context);
    }
    // 当前主题的中性与危险语义色。
    final OmniColors colors = OmniColors.of(context);
    // 只为可用行显示悬停或键盘焦点背景。
    final bool highlighted =
        widget.enabled &&
        (OmniMenuNavigation.keyboardOf(context) ? _focused : _hovered);
    // 退场保留同一RGB，仅改变透明度，避免与透明黑插值时短暂闪暗。
    final Color background = widget.danger
        ? colors.danger.withValues(
            alpha: highlighted ? OmniMenuMetrics.dangerHoverOpacity : 0,
          )
        : colors.paperSubtle.withValues(alpha: highlighted ? 1 : 0);
    // 不影响调用方字号、字体与自定义内容结构的默认文字样式。
    final TextStyle style = Theme.of(context).textTheme.bodyMedium!.copyWith(
      color: !widget.enabled
          ? colors.muted.withValues(alpha: 0.5)
          : widget.danger
          ? colors.danger
          : colors.ink,
      fontSize: OmniMenuMetrics.fontSize,
      fontWeight: FontWeight.w400,
    );
    return MergeSemantics(
      child: buildSemantics(
        child: AnimatedContainer(
          duration: OmniMotion.duration(context, OmniMotion.windowsMenuHover),
          curve: OmniMotion.standardCurve,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(OmniRadius.control),
          ),
          child: OmniInkWell(
            focusNode: _focusNode,
            onTap: widget.enabled ? handleTap : null,
            // 右键仅提供按压反馈，保留菜单且不执行左键业务动作。
            onSecondaryTap: widget.enabled ? () {} : null,
            onHover: (bool hovered) {
              if (hovered && widget.enabled) _focusNode.requestFocus();
              setState(() => _hovered = hovered);
            },
            onFocusChange: (bool focused) => setState(() => _focused = focused),
            canRequestFocus: widget.enabled,
            mouseCursor: widget.enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            borderRadius: BorderRadius.circular(OmniRadius.control),
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            highlightColor: Colors.transparent,
            splashColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
            child: DefaultTextStyle(
              style: style,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: widget.height),
                child: Padding(
                  padding: widget.padding ?? EdgeInsets.zero,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: buildChild(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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

  /// 当前选项勾选标记的位置。
  final OmniDropdownSelectionIndicatorPosition selectionIndicatorPosition;

  /// 创建下拉选择控件实现。
  const _OmniDropdownControl({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.hint,
    required this.focusNode,
    required this.autofocus,
    required this.selectionIndicatorPosition,
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

  /// 键盘展开时优先聚焦的选中项或首个可用项。
  final FocusNode _entryFocusNode = FocusNode();

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
    _entryFocusNode.dispose();
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
      if (FocusManager.instance.highlightMode ==
          FocusHighlightMode.traditional) {
        _focusMenuEntry();
      }
    }
  }

  /// 等菜单挂载后将键盘焦点交给可操作的菜单项。
  void _focusMenuEntry() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted &&
          _menuController.isOpen &&
          _entryFocusNode.context != null) {
        _entryFocusNode.requestFocus();
      }
    });
  }

  /// 使用方向键打开选择菜单，保留菜单内部原生方向键遍历。
  void _openMenuFromKeyboard() {
    if (widget.onChanged == null) return;
    if (_menuController.isOpen) {
      _focusMenuEntry();
    } else {
      // 首次展开的焦点交接由 onOpen 统一调度，避免同帧重复请求。
      _menuController.open();
    }
  }

  /// 记录菜单已关闭。
  void _handleMenuClose() {
    if (mounted) {
      // 菜单关闭后回到触发器，键盘用户可继续选择或 Tab 到下一个字段。
      _effectiveFocusNode.requestFocus();
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
      minimumSize: WidgetStatePropertyAll<Size>(
        Size(
          0,
          OmniDensity.isTouch(context)
              ? OmniSize.touch
              : OmniDropdownMetrics.itemHeight,
        ),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: OmniDensity.isTouch(context)
          ? VisualDensity.standard
          : VisualDensity.compact,
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
      textStyle: WidgetStatePropertyAll<TextStyle>(
        Theme.of(context).textTheme.bodyMedium!.copyWith(
          fontSize: OmniMenuMetrics.fontSize,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }

  /// 构建所有选择菜单项。
  List<Widget> _menuItems(OmniColors colors) {
    // 系统是否要求关闭动画。
    final bool disableAnimations = OmniMotion.reduce(context);
    // 首选当前已选且可用的项，否则从第一个可用项开始。
    final int selectedIndex = widget.items.indexWhere(
      (DropdownMenuItem<T> item) => item.enabled && item.value == widget.value,
    );
    // 没有可用项时不分配初始菜单焦点。
    final int focusIndex = selectedIndex >= 0
        ? selectedIndex
        : widget.items.indexWhere((DropdownMenuItem<T> item) => item.enabled);
    return widget.items
        .asMap()
        .entries
        .map((MapEntry<int, DropdownMenuItem<T>> entry) {
          // 当前菜单项及其稳定顺序。
          final DropdownMenuItem<T> item = entry.value;
          // 当前菜单项是否被选中。
          final bool selected = item.value == widget.value;
          // 当前菜单项的勾选图标。
          final Widget? selectionIndicator = selected
              ? Icon(Icons.check_rounded, size: 16, color: colors.brand)
              : null;
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: disableAnimations
                ? Duration.zero
                : OmniDropdownMotion.reveal,
            curve: OmniMotion.standardCurve,
            builder: (BuildContext context, double opacity, Widget? child) {
              return Opacity(opacity: opacity, child: child);
            },
            child: OmniPressBinding(
              builder: (BuildContext context, OmniPressFeedback feedback) =>
                  MenuItemButton(
                    statesController: feedback.statesController,
                    focusNode: entry.key == focusIndex ? _entryFocusNode : null,
                    onPressed: item.enabled && widget.onChanged != null
                        ? () {
                            feedback.activate();
                            _selectItem(item);
                          }
                        : null,
                    leadingIcon:
                        widget.selectionIndicatorPosition ==
                            OmniDropdownSelectionIndicatorPosition.leading
                        ? SizedBox.square(
                            dimension: 16,
                            child: selectionIndicator,
                          )
                        : null,
                    trailingIcon:
                        widget.selectionIndicatorPosition ==
                            OmniDropdownSelectionIndicatorPosition.trailing
                        ? SizedBox.square(
                            dimension: 16,
                            child: selectionIndicator,
                          )
                        : null,
                    style: _itemStyle(
                      colors,
                      selected: selected,
                    ).copyWith(foregroundBuilder: feedback.foregroundBuilder),
                    child: DefaultTextStyle.merge(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child: item.child,
                    ),
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
    final bool disableAnimations = OmniMotion.reduce(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: DefaultTextStyle.merge(
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(
              color: selectedItem == null ? colors.muted : colors.ink,
              fontSize: OmniMenuMetrics.fontSize,
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
    final bool highlighted =
        _menuOpen ||
        (_focused &&
            FocusManager.instance.highlightMode ==
                FocusHighlightMode.traditional);
    return AnimatedContainer(
      duration: OmniMotion.duration(context, OmniMotion.fast),
      curve: OmniMotion.standardCurve,
      constraints: BoxConstraints(
        minHeight: widget.height < OmniDensity.controlHeight(context)
            ? OmniDensity.controlHeight(context)
            : widget.height,
      ),
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
      isFocused:
          _menuOpen ||
          (_focused &&
              FocusManager.instance.highlightMode ==
                  FocusHighlightMode.traditional),
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
              child: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.arrowDown):
                      _openMenuFromKeyboard,
                  const SingleActivator(LogicalKeyboardKey.arrowUp):
                      _openMenuFromKeyboard,
                },
                child: OmniInkWell(
                  focusNode: _effectiveFocusNode,
                  autofocus: widget.autofocus,
                  onFocusChange: _handleFocusChange,
                  onTap: widget.onChanged == null ? null : _toggleMenu,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                  hoverColor: colors.paperSubtle,
                  focusColor: Colors.transparent,
                  highlightColor: colors.brandSoft,
                  child: formMode
                      ? _formTrigger(colors)
                      : _standaloneTrigger(colors),
                ),
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

  /// 菜单图标；为空时保留对齐位置但不绘制图形。
  final IconData? icon;

  /// 是否使用危险操作配色。
  final bool danger;

  /// 是否允许操作，用于同步菜单项的禁用颜色。
  final bool enabled;

  /// 创建操作菜单项内容。
  const _OmniPopupMenuItemContent({
    required this.label,
    required this.icon,
    required this.danger,
    required this.enabled,
  });

  /// 构建对齐的图标与文字。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 菜单项前景色。
    final Color foreground = !enabled
        ? colors.muted.withValues(alpha: 0.5)
        : danger
        ? colors.danger
        : colors.ink;
    return Container(
      constraints: BoxConstraints(
        minHeight: OmniDensity.isTouch(context)
            ? OmniSize.touch
            : OmniDropdownMetrics.itemHeight,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.sm,
        vertical: OmniSpacing.xxs,
      ),
      child: Row(
        children: <Widget>[
          if (icon == null)
            const SizedBox.square(dimension: OmniMenuMetrics.iconSize)
          else
            Icon(icon, size: OmniMenuMetrics.iconSize, color: foreground),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                color: foreground,
                fontSize: OmniMenuMetrics.fontSize,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
