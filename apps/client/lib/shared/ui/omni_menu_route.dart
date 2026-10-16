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

/// 菜单行与同一路由内二级面板之间的轻量桥接，不依赖具体菜单项类型。
class OmniMenuScope<T> extends InheritedWidget {
  /// 管理面板、焦点和锚点的当前路由宿主。
  final _OmniMenuHostState<T> _host;

  /// 当前条目是否位于二级面板中。
  final bool isSubmenu;

  /// 当前展开行的稳定身份，用于刷新箭头与展开语义。
  final Object? _expandedOwner;

  /// 仅由路由创建，调用方通过当前菜单行上下文访问。
  const OmniMenuScope._(
    this._host,
    this._expandedOwner, {
    required this.isSubmenu,
    required super.child,
  });

  /// 获取当前 Windows 菜单作用域，原生平台菜单返回空值。
  static OmniMenuScope<T>? maybeOf<T>(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OmniMenuScope<T>>();

  /// 判断当前父项是否正在展示它的二级面板。
  bool isExpanded(Object owner) => _expandedOwner == owner;

  /// 在同一路由内展开面板，键盘激活时才转交首项焦点。
  void openSubmenu({
    required Object owner,
    required RenderBox anchor,
    required FocusNode parentFocus,
    required List<PopupMenuEntry<T>> items,
    required bool focusFirst,
  }) {
    if (isSubmenu) return;
    _host._openSubmenu(
      owner: owner,
      anchor: anchor,
      parentFocus: parentFocus,
      items: items,
      focusFirst: focusFirst,
    );
  }

  /// 父菜单切换至另一行时收起二级面板，跨面板空隙不触发关闭。
  void enteredItem(Object owner) {
    if (!isSubmenu && _expandedOwner != null && _expandedOwner != owner) {
      _host._closeSubmenu();
    }
  }

  /// 键盘进入二级菜单时同步两块面板的输入方式。
  void useKeyboard() => _host._useKeyboard();

  /// 只有父项展开状态变化时才更新条目。
  @override
  bool updateShouldNotify(OmniMenuScope<T> oldWidget) =>
      _expandedOwner != oldWidget._expandedOwner ||
      isSubmenu != oldWidget.isSubmenu;
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
  // 移动端可按需复用完整面板淡入缩放，默认入口仍沿用原生过渡。
  bool wholePanelTransition = false,
}) {
  assert(items.isNotEmpty);
  assert((position == null) != (positionBuilder == null));
  if (Theme.of(context).platform != TargetPlatform.windows &&
      !wholePanelTransition) {
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
          return themes.wrap(
            _OmniMenuHost<T>(
              route: this,
              animation: animation,
              position: anchor,
              padding: media.padding,
            ),
          );
        },
      ),
    );
  }
}

/// 同一路由内正在显示或退场的二级面板快照。
class _OmniSubmenu<T> {
  /// 保留父条目身份，重复悬停时不重启动画。
  final Object owner;

  /// 仅缓存渲染对象，窗口变化时不再访问可能失效的元素。
  final RenderBox anchor;

  /// 用于计算父行相对主面板的位置。
  final RenderBox mainPanel;

  /// 键盘返回时恢复的真实父项焦点。
  final FocusNode parentFocus;

  /// 本次展开期间保持身份稳定的子项。
  final List<PopupMenuEntry<T>> items;

  /// 初次挂载是否应将焦点交给子项。
  final bool focusFirst;

  /// 记录展开面板所需的最小状态。
  const _OmniSubmenu({
    required this.owner,
    required this.anchor,
    required this.mainPanel,
    required this.parentFocus,
    required this.items,
    required this.focusFirst,
  });
}

/// 保留单一路由返回值和遮罩，只在布局层增加第二块面板。
class _OmniMenuHost<T> extends StatefulWidget {
  /// 当前菜单路由和全部原始配置。
  final _OmniPopupMenuRoute<T> route;

  /// 路由原有进入和退出进度。
  final Animation<double> animation;

  /// 主菜单触发器在当前窗口中的位置。
  final RelativeRect position;

  /// 当前窗口安全区域。
  final EdgeInsets padding;

  /// 创建两个面板共享的路由宿主。
  const _OmniMenuHost({
    required this.route,
    required this.animation,
    required this.position,
    required this.padding,
  });

  /// 创建本路由的面板状态。
  @override
  State<_OmniMenuHost<T>> createState() => _OmniMenuHostState<T>();
}

/// 管理二级菜单展开、返回焦点与两块面板共享的输入方式。
class _OmniMenuHostState<T> extends State<_OmniMenuHost<T>>
    with SingleTickerProviderStateMixin {
  /// 主面板的稳定位置与焦点状态。
  final GlobalKey<_OmniMenuPanelState<T>> _mainKey = GlobalKey();

  /// 子面板的稳定状态，重复点击可将焦点交给已有首项。
  final GlobalKey<_OmniMenuPanelState<T>> _submenuKey = GlobalKey();

  /// 二级面板独立展开，不重启已经可见的主菜单动画。
  late final AnimationController _submenuAnimation;

  /// 保留正在进入或退出的二级菜单内容。
  _OmniSubmenu<T>? _submenu;

  /// 区分可操作的面板和仅保留退场画面的面板。
  bool _submenuOpen = false;

  /// 每次展开或关闭都作废旧的延迟焦点请求，避免快速反向时抢回焦点。
  int _submenuFocusRevision = 0;

  /// 鼠标与键盘在两个面板间共用最近输入方式。
  bool _keyboardNavigation =
      HardwareKeyboard.instance.logicalKeysPressed.isNotEmpty;

  /// 初始化二级面板动画，并在退场结束后卸载其语义子树。
  @override
  void initState() {
    super.initState();
    _submenuAnimation = AnimationController(
      vsync: this,
      duration: widget.route.reducedMotion
          ? Duration.zero
          : OmniMotion.windowsMenuEnter,
      reverseDuration: widget.route.reducedMotion
          ? Duration.zero
          : OmniMotion.windowsMenuExit,
    )..addStatusListener(_submenuStatusChanged);
  }

  /// 只移除已完成退场的面板，快速反向展开继续使用当前动画进度。
  void _submenuStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !_submenuOpen && mounted) {
      setState(() => _submenu = null);
    }
  }

  /// 菜单关闭后释放独立动画。
  @override
  void dispose() {
    _submenuAnimation.dispose();
    super.dispose();
  }

  /// 展开有效父行的子菜单，重复打开不会重新布局或重置其动画。
  void _openSubmenu({
    required Object owner,
    required RenderBox anchor,
    required FocusNode parentFocus,
    required List<PopupMenuEntry<T>> items,
    required bool focusFirst,
  }) {
    if (!widget.route.isCurrent || !anchor.attached || items.isEmpty) return;
    // 仅当前这次打开操作可以在下一帧转交焦点。
    final int focusRevision = ++_submenuFocusRevision;
    if (_submenu?.owner == owner) {
      if (!_submenuOpen) {
        setState(() => _submenuOpen = true);
        _submenuAnimation.forward();
      }
      if (focusFirst) {
        // 退场中的 ExcludeFocus 必须先重建为可聚焦，再寻找真实子项。
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          if (mounted &&
              widget.route.isCurrent &&
              _submenuOpen &&
              _submenu?.owner == owner &&
              _submenuFocusRevision == focusRevision) {
            _submenuKey.currentState?._focusEntry();
          }
        });
      }
      return;
    }
    // 主面板仍在当前路由中，读取后缓存其渲染对象供布局阶段使用。
    final RenderObject? mainPanel = _mainKey
        .currentState
        ?._contentKey
        .currentContext
        ?.findRenderObject();
    if (mainPanel is! RenderBox || !mainPanel.attached) return;
    setState(() {
      _submenu = _OmniSubmenu<T>(
        owner: owner,
        anchor: anchor,
        mainPanel: mainPanel,
        parentFocus: parentFocus,
        items: items,
        focusFirst: focusFirst,
      );
      _submenuOpen = true;
    });
    _submenuAnimation.forward(from: 0);
  }

  /// 关闭子菜单但保留主菜单；键盘返回时恢复父项焦点。
  void _closeSubmenu({bool restoreFocus = false}) {
    if (!_submenuOpen) return;
    _submenuFocusRevision += 1;
    // 退场可能立即结束，先保留父项节点。
    final FocusNode? parentFocus = _submenu?.parentFocus;
    setState(() => _submenuOpen = false);
    if (restoreFocus && parentFocus?.context != null) {
      parentFocus!.requestFocus();
    }
    _submenuAnimation.reverse();
  }

  /// 两级 Escape 先返回父菜单，再让路由恢复打开前的焦点。
  void _dismiss() {
    _useKeyboard();
    if (_submenuOpen) {
      _closeSubmenu(restoreFocus: true);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// 窗口变化或父行卸载后，在布局结束时安全清理失效的子面板。
  void _invalidAnchor() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _submenuOpen && !(_submenu?.anchor.attached ?? false)) {
        _closeSubmenu(restoreFocus: true);
      }
    });
  }

  /// 鼠标重新移动后，两块面板只突出悬停与展开父项。
  void _usePointer() {
    if (_keyboardNavigation) setState(() => _keyboardNavigation = false);
  }

  /// 键盘操作同步显示两块面板的真实焦点。
  void _useKeyboard() {
    if (!_keyboardNavigation) setState(() => _keyboardNavigation = true);
  }

  /// 构建同一遮罩内的两块面板，面板之间的空隙不会触发关闭。
  @override
  Widget build(BuildContext context) {
    // 本次构建保留的子面板快照。
    final _OmniSubmenu<T>? submenu = _submenu;
    return OmniMenuNavigation(
      keyboard: _keyboardNavigation,
      child: MouseRegion(
        hitTestBehavior: HitTestBehavior.deferToChild,
        onHover: (_) => _usePointer(),
        child: CustomMultiChildLayout(
          delegate: _OmniMenuPanelsLayout<T>(
            position: widget.position,
            padding: widget.padding,
            textDirection: Directionality.of(context),
            submenu: submenu,
            onInvalidAnchor: _invalidAnchor,
          ),
          children: <Widget>[
            LayoutId(
              id: false,
              child: OmniMenuScope<T>._(
                this,
                _submenuOpen ? submenu?.owner : null,
                isSubmenu: false,
                child: _OmniMenuPanel<T>(
                  key: _mainKey,
                  route: widget.route,
                  items: widget.route.items,
                  initialValue: widget.route.initialValue,
                  animation: widget.animation,
                  onDismiss: _dismiss,
                  onKeyboard: _useKeyboard,
                  alignment: widget.position.left <= widget.position.right
                      ? Alignment.topLeft
                      : Alignment.topRight,
                ),
              ),
            ),
            if (submenu != null)
              LayoutId(
                id: true,
                child: OmniMenuScope<T>._(
                  this,
                  null,
                  isSubmenu: true,
                  child: FadeTransition(
                    opacity: widget.animation,
                    child: _OmniMenuPanel<T>(
                      key: _submenuKey,
                      route: widget.route,
                      items: submenu.items,
                      animation: _submenuAnimation,
                      alignment: Alignment.topLeft,
                      submenu: true,
                      focusOnOpen: submenu.focusFirst,
                      onDismiss: _dismiss,
                      onKeyboard: _useKeyboard,
                      onBack: () {
                        _useKeyboard();
                        _closeSubmenu(restoreFocus: true);
                      },
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 先固定主面板，再以父行实测位置将二级面板翻转或钳制在窗口内。
class _OmniMenuPanelsLayout<T> extends MultiChildLayoutDelegate {
  /// 主菜单锚点。
  final RelativeRect position;

  /// 窗口安全区域。
  final EdgeInsets padding;

  /// 主菜单锚点居中时使用的文字方向。
  final TextDirection textDirection;

  /// 可选子面板及其有效锚点快照。
  final _OmniSubmenu<T>? submenu;

  /// 锚点失效时通知宿主在布局结束后收起子菜单。
  final VoidCallback onInvalidAnchor;

  /// 创建与动画绘制进度无关的菜单布局。
  _OmniMenuPanelsLayout({
    required this.position,
    required this.padding,
    required this.textDirection,
    required this.submenu,
    required this.onInvalidAnchor,
  });

  /// 实测菜单尺寸并定位，空间不足时允许面板重叠但不越过窗口。
  @override
  void performLayout(Size size) {
    // 主菜单继续采用原有安全边距与锚点规则。
    final _OmniMenuLayout mainLayout = _OmniMenuLayout(
      position: position,
      padding: padding,
      textDirection: textDirection,
    );
    // 两块面板都受到当前窗口实际尺寸约束。
    final BoxConstraints constraints = mainLayout.getConstraintsForChild(
      BoxConstraints.tight(size),
    );
    // 主菜单最终布局尺寸。
    final Size mainSize = layoutChild(false, constraints);
    // 主菜单在本轮窗口布局中的位置。
    final Offset mainPosition = mainLayout.getPositionForChild(size, mainSize);
    positionChild(false, mainPosition);
    if (!hasChild(true)) return;
    // 子菜单的实际尺寸可能受字体缩放或窄窗口约束。
    final Size childSize = layoutChild(true, constraints);
    // 子菜单配置由是否存在对应布局孩子保证。
    final _OmniSubmenu<T> active = submenu!;
    // 安全边界与现有主菜单保持一致。
    final Rect safe = Rect.fromLTRB(
      padding.left + OmniSpacing.xs,
      padding.top + OmniSpacing.xs,
      size.width - padding.right - OmniSpacing.xs,
      size.height - padding.bottom - OmniSpacing.xs,
    );
    // 父行失效时不读取其坐标，退场画面暂时沿主菜单顶部定位。
    final bool valid = active.anchor.attached && active.mainPanel.attached;
    // 父行相对于主面板的偏移不受主面板窗口位置改变影响。
    final Offset rowOffset = valid
        ? active.anchor.localToGlobal(Offset.zero, ancestor: active.mainPanel)
        : Offset.zero;
    if (!valid) onInvalidAnchor();
    // 默认向右展开，右侧空间不足时先尝试左侧。
    final double right = mainPosition.dx + mainSize.width + OmniSpacing.xxs;
    // 完整子面板不能超出窗口安全范围。
    final double targetX = right + childSize.width <= safe.right
        ? right
        : mainPosition.dx - OmniSpacing.xxs - childSize.width;
    positionChild(
      true,
      Offset(
        targetX.clamp(
          safe.left,
          (safe.right - childSize.width).clamp(safe.left, double.infinity),
        ),
        (mainPosition.dy + rowOffset.dy).clamp(
          safe.top,
          (safe.bottom - childSize.height).clamp(safe.top, double.infinity),
        ),
      ),
    );
  }

  /// 每次父锚点或子面板配置变化时重新测量两个面板。
  @override
  bool shouldRelayout(_OmniMenuPanelsLayout<T> oldDelegate) => true;
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

  /// 当前面板独立拥有的菜单项。
  final List<PopupMenuEntry<T>> items;

  /// 仅主菜单需要的初始选中值。
  final T? initialValue;

  /// 二级面板保留独立语义和测试定位，不创建第二个路由语义。
  final bool submenu;

  /// 鼠标展开子菜单时保留父项焦点。
  final bool focusOnOpen;

  /// Escape 按层级返回或关闭整组菜单。
  final VoidCallback onDismiss;

  /// 键盘输入统一更新整组菜单的高亮模式。
  final VoidCallback onKeyboard;

  /// 子菜单的左方向键回到父项。
  final VoidCallback? onBack;

  /// 路由提供的完整生命周期进度。
  final Animation<double> animation;

  /// 轻缩放固定在菜单展开侧的上角。
  final Alignment alignment;

  /// 创建不随进度重新布局的菜单面板。
  const _OmniMenuPanel({
    required this.route,
    required this.items,
    required this.animation,
    required this.alignment,
    required this.onDismiss,
    required this.onKeyboard,
    this.initialValue,
    this.submenu = false,
    this.focusOnOpen = true,
    this.onBack,
    super.key,
  });

  /// 创建可释放的动画与条目焦点状态。
  @override
  State<_OmniMenuPanel<T>> createState() => _OmniMenuPanelState<T>();
}

/// 保留每个原始条目，并在关闭动画中禁止再次执行操作。
class _OmniMenuPanelState<T> extends State<_OmniMenuPanel<T>> {
  /// 布局锚点位于缩放变换内部，测量父行时不读取动画祖先的尺寸。
  final GlobalKey _contentKey = GlobalKey();

  /// 整个面板共享同一进入和退出曲线。
  late final CurvedAnimation _progress;

  /// 仅用于寻找各条目已有可操作后代，不增加额外焦点停靠点。
  late List<FocusNode> _entryFocus;

  /// 每块面板独立循环焦点，避免 Tab 或方向键跨入另一块面板。
  final FocusScopeNode _panelFocus = FocusScopeNode(
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );

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
      widget.items.length,
      (int index) => FocusNode(skipTraversal: true, canRequestFocus: false),
    );
    if (widget.focusOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback(
        (Duration _) => _focusEntry(),
      );
    }
  }

  /// 切换到另一父项的子菜单时重建包裹节点，不复用旧条目的焦点映射。
  @override
  void didUpdateWidget(_OmniMenuPanel<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items) {
      for (final FocusNode node in _entryFocus) {
        node.dispose();
      }
      _entryFocus = List<FocusNode>.generate(
        widget.items.length,
        (int index) => FocusNode(skipTraversal: true, canRequestFocus: false),
      );
      if (widget.focusOnOpen) {
        WidgetsBinding.instance.addPostFrameCallback(
          (Duration _) => _focusEntry(),
        );
      }
    }
  }

  /// 优先聚焦选中项，否则聚焦首个可操作条目，跳过禁用行。
  void _focusEntry() {
    if (!mounted || !widget.route.isCurrent || !widget.route.requestFocus) {
      return;
    }
    // 当前值对应的菜单行。
    final int selected = widget.initialValue == null
        ? -1
        : widget.items.indexWhere(
            (PopupMenuEntry<T> item) => item.represents(widget.initialValue),
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
    _panelFocus.dispose();
    super.dispose();
  }

  /// 以原有焦点策略在可用菜单行之间移动。
  void _moveFocus(bool forward) {
    widget.onKeyboard();
    if (forward) {
      _panelFocus.nextFocus();
    } else {
      _panelFocus.previousFocus();
    }
  }

  /// 键盘开始导航后让当前焦点重新可见。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) widget.onKeyboard();
    return KeyEventResult.ignored;
  }

  /// 构建固定尺寸面板、独立条目与只影响绘制的过渡。
  @override
  Widget build(BuildContext context) {
    // 当前主题菜单语义色。
    final OmniColors colors = OmniColors.of(context);
    // 所有条目保留原组件身份，不由路由拆解或重建。
    final Widget panel = Listener(
      key: _contentKey,
      behavior: HitTestBehavior.opaque,
      child: FocusScope(
        node: _panelFocus,
        onKeyEvent: _handleKey,
        child: Material(
          key: ValueKey<String>(
            widget.submenu
                ? 'omni-windows-submenu-surface'
                : 'omni-windows-menu-surface',
          ),
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
                container: true,
                scopesRoute: !widget.submenu,
                namesRoute: !widget.submenu,
                explicitChildNodes: true,
                label: widget.route.semanticLabel,
                child: FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: CallbackShortcuts(
                    bindings: <ShortcutActivator, VoidCallback>{
                      const SingleActivator(LogicalKeyboardKey.escape):
                          widget.onDismiss,
                      if (widget.onBack != null)
                        const SingleActivator(LogicalKeyboardKey.arrowLeft):
                            widget.onBack!,
                      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
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
                            index < widget.items.length;
                            index += 1
                          )
                            Focus(
                              focusNode: _entryFocus[index],
                              child: widget.items[index],
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
    );
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        widget.animation,
        widget.route.animation!,
      ]),
      child: panel,
      builder: (BuildContext context, Widget? child) {
        // 路由开始退出后不再接受指针、键盘或辅助功能操作。
        final bool closing =
            widget.animation.status == AnimationStatus.reverse ||
            widget.animation.status == AnimationStatus.dismissed ||
            widget.route.animation!.status == AnimationStatus.reverse ||
            widget.route.animation!.status == AnimationStatus.dismissed;
        return IgnorePointer(
          ignoring: closing,
          child: ExcludeFocus(
            excluding: closing,
            child: ExcludeSemantics(
              excluding: closing,
              child: FadeTransition(
                opacity: _progress,
                child: ScaleTransition(
                  key: ValueKey<String>(
                    widget.submenu
                        ? 'omni-windows-submenu-scale'
                        : 'omni-windows-menu-scale',
                  ),
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
