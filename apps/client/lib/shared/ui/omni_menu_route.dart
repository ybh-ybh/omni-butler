import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 共享菜单最近一次输入方式，避免鼠标悬停与旧键盘焦点同时着色。
class OmniMenuNavigation extends InheritedWidget {
  /// 当前是否正在通过键盘操作菜单。
  final bool keyboard;

  /// 将输入方式传递给原有条目，不改变它们的公共返回值接口。
  const OmniMenuNavigation({
    required this.keyboard,
    required super.child,
    super.key,
  });

  /// 菜单外独立使用的条目仍遵循框架原有焦点可见策略。
  static bool keyboardOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<OmniMenuNavigation>()
          ?.keyboard ??
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  /// 输入方式切换时更新各行焦点背景。
  @override
  bool updateShouldNotify(OmniMenuNavigation oldWidget) =>
      keyboard != oldWidget.keyboard;
}

/// 显示应用内操作菜单，Windows 使用完整面板过渡，其他平台沿用原生菜单。
Future<T?> showOmniMenu<T>({
  required BuildContext context,
  RelativeRect? position,
  PopupMenuPositionBuilder? positionBuilder,
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  BoxConstraints? constraints,
  EdgeInsetsGeometry? menuPadding,
  bool useRootNavigator = false,
  bool? requestFocus,
}) {
  assert(items.isNotEmpty);
  assert((position == null) != (positionBuilder == null));
  if (Theme.of(context).platform != TargetPlatform.windows) {
    return showMenu<T>(
      context: context,
      position: position,
      positionBuilder: positionBuilder,
      items: items,
      initialValue: initialValue,
      constraints: constraints,
      menuPadding: menuPadding,
      useRootNavigator: useRootNavigator,
      requestFocus: requestFocus,
      popUpAnimationStyle: OmniMotion.reduce(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: OmniMotion.fast,
              reverseDuration: OmniMotion.fast,
              curve: OmniMotion.standardCurve,
              reverseCurve: Curves.easeInCubic,
            ),
    );
  }
  // 菜单始终属于触发它的应用窗口。
  final NavigatorState navigator = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  );
  return navigator.push<T>(
    _OmniPopupMenuRoute<T>(
      position: position,
      positionBuilder: positionBuilder,
      items: items,
      initialValue: initialValue,
      constraints: constraints,
      menuPadding: menuPadding ?? const EdgeInsets.all(OmniSpacing.xxs),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      reducedMotion: OmniMotion.reduce(context),
      barrierLabel: MaterialLocalizations.of(context).menuDismissLabel,
      semanticLabel: MaterialLocalizations.of(context).popupMenuLabel,
      requestFocus: requestFocus,
    ),
  );
}

/// 保留菜单返回值、外部关闭和焦点循环，同时只动画完整面板。
class _OmniPopupMenuRoute<T> extends PopupRoute<T> {
  /// 固定上下文菜单位置。
  final RelativeRect? position;

  /// 窗口布局变化时重新计算按钮菜单位置。
  final PopupMenuPositionBuilder? positionBuilder;

  /// 原始菜单条目，保留自定义内容及 Navigator 返回行为。
  final List<PopupMenuEntry<T>> items;

  /// 打开后优先展示和聚焦的选中值。
  final T? initialValue;

  /// 调用方要求的菜单尺寸。
  final BoxConstraints? constraints;

  /// 菜单内容与面板边缘的距离。
  final EdgeInsetsGeometry menuPadding;

  /// 从触发位置捕获的局部主题。
  final CapturedThemes themes;

  /// 系统减少动画偏好。
  final bool reducedMotion;

  /// 辅助功能识别的菜单名称。
  final String semanticLabel;

  /// 点击透明遮罩时的辅助功能说明。
  @override
  final String barrierLabel;

  /// 创建仅由应用 Navigator 承载的菜单。
  _OmniPopupMenuRoute({
    required this.position,
    required this.positionBuilder,
    required this.items,
    required this.initialValue,
    required this.constraints,
    required this.menuPadding,
    required this.themes,
    required this.reducedMotion,
    required this.barrierLabel,
    required this.semanticLabel,
    super.requestFocus,
  }) : super(traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop);

  /// 打开菜单时使用完整面板的轻缩放与淡入。
  @override
  Duration get transitionDuration =>
      reducedMotion ? Duration.zero : OmniMotion.windowsMenuEnter;

  /// 关闭时保留面板直到淡出完成。
  @override
  Duration get reverseTransitionDuration =>
      reducedMotion ? Duration.zero : OmniMotion.windowsMenuExit;

  /// 点击菜单外关闭，但不改变底层页面配色。
  @override
  bool get barrierDismissible => true;

  /// 操作菜单不使用模态暗色遮罩。
  @override
  Color? get barrierColor => null;

  /// 根据最终面板尺寸定位，动画不会改变布局边界。
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // 原窗口安全边距参与定位，面板内部不重复添加。
    final MediaQueryData media = MediaQuery.of(context);
    return MediaQuery.removePadding(
      context: context,
      removeLeft: true,
      removeTop: true,
      removeRight: true,
      removeBottom: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints viewportConstraints) {
          // 当前窗口内的锚点坐标。
          final RelativeRect anchor =
              positionBuilder?.call(context, viewportConstraints) ?? position!;
          return CustomSingleChildLayout(
            delegate: _OmniMenuLayout(
              position: anchor,
              padding: media.padding,
              textDirection: Directionality.of(context),
            ),
            child: themes.wrap(
              _OmniMenuPanel<T>(
                route: this,
                animation: animation,
                alignment: anchor.left <= anchor.right
                    ? Alignment.topLeft
                    : Alignment.topRight,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 将最终尺寸的面板限制在当前应用窗口安全区域内。
class _OmniMenuLayout extends SingleChildLayoutDelegate {
  /// 触发器或指针相对于窗口覆盖层的位置。
  final RelativeRect position;

  /// 当前窗口系统安全边距。
  final EdgeInsets padding;

  /// 锚点居中时决定菜单的展开方向。
  final TextDirection textDirection;

  /// 创建不会随动画进度改变的布局代理。
  _OmniMenuLayout({
    required this.position,
    required this.padding,
    required this.textDirection,
  });

  /// 预留面板与窗口边缘之间的间距。
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest)
          .deflate(padding + const EdgeInsets.all(OmniSpacing.xs));

  /// 优先贴合锚点，在窗口边缘将完整面板移回可见范围。
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // 横向优先向空间更大的一侧展开。
    final bool growRight =
        position.left < position.right ||
        (position.left == position.right && textDirection == TextDirection.ltr);
    // 未裁正的目标横坐标。
    final double targetX = growRight
        ? position.left
        : size.width - position.right - childSize.width;
    // 完整菜单可处于的最小横坐标。
    final double left = padding.left + OmniSpacing.xs;
    // 完整菜单可处于的最小纵坐标。
    final double top = padding.top + OmniSpacing.xs;
    return Offset(
      targetX.clamp(
        left,
        (size.width - padding.right - OmniSpacing.xs - childSize.width).clamp(
          left,
          double.infinity,
        ),
      ),
      position.top.clamp(
        top,
        (size.height - padding.bottom - OmniSpacing.xs - childSize.height)
            .clamp(top, double.infinity),
      ),
    );
  }

  /// 只有锚点、安全区域或阅读方向变化时重新定位。
  @override
  bool shouldRelayout(_OmniMenuLayout oldDelegate) =>
      position != oldDelegate.position ||
      padding != oldDelegate.padding ||
      textDirection != oldDelegate.textDirection;
}

/// 统一的菜单面板及其键盘和完整面板动画。
class _OmniMenuPanel<T> extends StatefulWidget {
  /// 当前应用内菜单路由。
  final _OmniPopupMenuRoute<T> route;

  /// 路由提供的完整生命周期进度。
  final Animation<double> animation;

  /// 轻缩放固定在菜单展开侧的上角。
  final Alignment alignment;

  /// 创建不随进度重新布局的菜单面板。
  const _OmniMenuPanel({
    required this.route,
    required this.animation,
    required this.alignment,
  });

  /// 创建可释放的动画与条目焦点状态。
  @override
  State<_OmniMenuPanel<T>> createState() => _OmniMenuPanelState<T>();
}

/// 保留每个原始条目，并在关闭动画中禁止再次执行操作。
class _OmniMenuPanelState<T> extends State<_OmniMenuPanel<T>> {
  /// 整个面板共享同一进入和退出曲线。
  late final CurvedAnimation _progress;

  /// 仅用于寻找各条目已有可操作后代，不增加额外焦点停靠点。
  late final List<FocusNode> _entryFocus;

  /// 菜单键或键盘激活打开时立即展示焦点，鼠标打开时保持普通背景。
  bool _keyboardNavigation =
      HardwareKeyboard.instance.logicalKeysPressed.isNotEmpty;

  /// 初始化面板曲线，并在首帧后交接键盘焦点。
  @override
  void initState() {
    super.initState();
    _progress = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _entryFocus = List<FocusNode>.generate(
      widget.route.items.length,
      (int index) => FocusNode(skipTraversal: true, canRequestFocus: false),
    );
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _focusEntry());
  }

  /// 优先聚焦选中项，否则聚焦首个可操作条目，跳过禁用行。
  void _focusEntry() {
    if (!mounted || !widget.route.isCurrent || !widget.route.requestFocus) {
      return;
    }
    // 当前值对应的菜单行。
    final int selected = widget.route.initialValue == null
        ? -1
        : widget.route.items.indexWhere(
            (PopupMenuEntry<T> item) =>
                item.represents(widget.route.initialValue),
          );
    // 首选当前值，找不到可用焦点时继续寻找其他行。
    final Iterable<FocusNode> entries = <FocusNode>[
      if (selected >= 0) _entryFocus[selected],
      ..._entryFocus,
    ];
    for (final FocusNode entry in entries) {
      for (final FocusNode descendant in entry.descendants) {
        if (descendant.canRequestFocus && !descendant.skipTraversal) {
          descendant.requestFocus();
          if (descendant.context != null) {
            Scrollable.ensureVisible(descendant.context!);
          }
          return;
        }
      }
    }
  }

  /// 释放焦点容器和曲线，业务子树不留下延迟动作。
  @override
  void dispose() {
    _progress.dispose();
    for (final FocusNode node in _entryFocus) {
      node.dispose();
    }
    super.dispose();
  }

  /// 关闭菜单并让 Navigator 恢复此前路由的焦点。
  void _dismiss() => Navigator.of(context).maybePop();

  /// 以原有焦点策略在可用菜单行之间移动。
  void _moveFocus(bool forward) {
    if (!_keyboardNavigation) setState(() => _keyboardNavigation = true);
    if (forward) {
      FocusScope.of(context).nextFocus();
    } else {
      FocusScope.of(context).previousFocus();
    }
  }

  /// 鼠标重新移动后只展示指针所在菜单项的悬停。
  void _usePointer() {
    if (_keyboardNavigation) setState(() => _keyboardNavigation = false);
  }

  /// 键盘开始导航后让当前焦点重新可见。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && !_keyboardNavigation) {
      setState(() => _keyboardNavigation = true);
    }
    return KeyEventResult.ignored;
  }

  /// 构建固定尺寸面板、独立条目与只影响绘制的过渡。
  @override
  Widget build(BuildContext context) {
    // 当前主题菜单语义色。
    final OmniColors colors = OmniColors.of(context);
    // 所有条目保留原组件身份，不由路由拆解或重建。
    final Widget panel = OmniMenuNavigation(
      keyboard: _keyboardNavigation,
      child: MouseRegion(
        onHover: (_) => _usePointer(),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _handleKey,
          child: Material(
            key: const ValueKey<String>('omni-windows-menu-surface'),
            color: colors.paper,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.black.withValues(
              alpha: OmniMenuMetrics.shadowOpacity,
            ),
            elevation: OmniMenuMetrics.elevation,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(OmniRadius.panel),
              side: BorderSide(color: colors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints:
                  widget.route.constraints ??
                  const BoxConstraints(
                    minWidth: OmniMenuMetrics.minWidth,
                    maxWidth: OmniMenuMetrics.maxWidth,
                  ),
              child: IntrinsicWidth(
                child: Semantics(
                  role: SemanticsRole.menu,
                  scopesRoute: true,
                  namesRoute: true,
                  explicitChildNodes: true,
                  label: widget.route.semanticLabel,
                  child: FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(),
                    child: CallbackShortcuts(
                      bindings: <ShortcutActivator, VoidCallback>{
                        const SingleActivator(LogicalKeyboardKey.escape):
                            _dismiss,
                        const SingleActivator(
                          LogicalKeyboardKey.arrowDown,
                        ): () =>
                            _moveFocus(true),
                        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                            _moveFocus(false),
                      },
                      child: SingleChildScrollView(
                        padding: widget.route.menuPadding,
                        child: ListBody(
                          children: <Widget>[
                            for (
                              int index = 0;
                              index < widget.route.items.length;
                              index += 1
                            )
                              Focus(
                                focusNode: _entryFocus[index],
                                child: widget.route.items[index],
                              ),
                          ],
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
    return AnimatedBuilder(
      animation: widget.animation,
      child: panel,
      builder: (BuildContext context, Widget? child) {
        // 路由开始退出后不再接受指针、键盘或辅助功能操作。
        final bool closing =
            widget.animation.status == AnimationStatus.reverse ||
            widget.animation.status == AnimationStatus.dismissed;
        return IgnorePointer(
          ignoring: closing,
          child: ExcludeFocus(
            excluding: closing,
            child: ExcludeSemantics(
              excluding: closing,
              child: FadeTransition(
                opacity: _progress,
                child: ScaleTransition(
                  key: const ValueKey<String>('omni-windows-menu-scale'),
                  scale: Tween<double>(
                    begin: OmniMotion.windowsMenuScale,
                    end: 1,
                  ).animate(_progress),
                  alignment: widget.alignment,
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
