part of 'android_notes_view.dart';

/// 安卓编辑与录音共用一层根导航模糊，底层列表和滚动位置保持挂载。
class _AndroidComposerRoute extends PopupRoute<void> {
  /// 打开时的系统动画偏好也作用于路由生命周期。
  final bool reducedMotion;

  /// 会话控件持有原草稿身份。
  final WidgetBuilder builder;

  /// 所有显式关闭入口交给草稿或录音门禁。
  Future<void> Function()? requestClose;

  /// 创建可跟随系统键盘的独立安卓覆盖层。
  _AndroidComposerRoute({required this.builder, required this.reducedMotion});

  /// 文字与录音统一使用安卓模态进入时长。
  @override
  Duration get transitionDuration =>
      reducedMotion ? Duration.zero : OmniMotion.androidModalEnter;

  /// 关闭沿原路径退出。
  @override
  Duration get reverseTransitionDuration =>
      reducedMotion ? Duration.zero : OmniMotion.androidModalExit;

  /// 遮罩动作由可暂存的会话处理。
  @override
  bool get barrierDismissible => false;

  /// 根界面自己绘制唯一的模糊和主题遮罩。
  @override
  Color? get barrierColor => Colors.transparent;

  /// 读屏提供关闭含义。
  @override
  String? get barrierLabel => '收起笔记';

  /// 背景和面板共享同一动画进度，不叠加第二层模糊。
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => AnimatedBuilder(
    animation: animation,
    child: builder(context),
    builder: (context, child) {
      // 减少动画即时到达目标，不改变保存或录音行为。
      final double progress = OmniMotion.reduce(context)
          ? 1
          : OmniMotion.androidModalCurve.transform(animation.value);
      return Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  unawaited(requestClose?.call() ?? Future<void>.value()),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(
                  sigmaX: progress * 10,
                  sigmaY: progress * 10,
                ),
                child: ColoredBox(
                  color: OmniColors.of(context).canvas
                      .withValues(alpha: progress * .42),
                ),
              ),
            ),
            child!,
          ],
        ),
      );
    },
  );

  /// 面板自身只移动表面，背景已经按相同进度过渡。
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

/// 从根路由当前显示进度移动表面，反向关闭不跳回初始位置。
class _AndroidComposerEntrance extends StatelessWidget {
  /// 已排好位置的面板。
  final Widget child;

  /// 原路径进退所需的实际面板距离。
  final double distance;

  /// 表面过渡不创建新的业务状态。
  const _AndroidComposerEntrance({required this.child, required this.distance});

  /// 保留稳定子树，只有外层位置发生变化。
  @override
  Widget build(BuildContext context) {
    // 当前根导航覆盖层的进入和退出动画。
    final Animation<double> animation =
        ModalRoute.of(context) is _AndroidComposerRoute
        ? ModalRoute.of(context)!.animation!
        : const AlwaysStoppedAnimation(1);
    return OmniModalSlideTransition(
      animation: animation,
      distance: distance,
      child: child,
    );
  }
}

/// 文字面板默认200dp，正文与固定工具栏分离，横条拖动可即时接管吸附。
class _AndroidComposerSurface extends StatefulWidget {
  /// 独立滚动的正文与附件。
  final Widget body;

  /// 固定在键盘上沿的紧凑工具栏。
  final Widget toolbar;

  /// 工具胶囊只占覆盖空间，不压缩正文。
  final Widget? popup;

  /// 下滑关闭先暂存，失败时恢复原高度。
  final Future<void> Function() onClose;

  /// 提交和关闭期间阻止拖动切换。
  final bool enabled;

  /// 创建视频中的轻量输入表面。
  const _AndroidComposerSurface({
    required this.body,
    required this.toolbar,
    required this.onClose,
    this.popup,
    required this.enabled,
  });

  /// 高度动画由表面自己的状态持有。
  @override
  State<_AndroidComposerSurface> createState() =>
      _AndroidComposerSurfaceState();
}

/// 高度使用像素而非屏高比例，键盘打开与关闭时紧凑形态不跳变。
class _AndroidComposerSurfaceState extends State<_AndroidComposerSurface>
    with SingleTickerProviderStateMixin {
  /// 可被拖动随时接管的实际表面高度。
  late final AnimationController _height = AnimationController.unbounded(
    vsync: this,
    value: 200,
  );

  /// 当前安全可用空间，用于限制展开上界。
  double _available = 200;

  /// 释放连续高度动画。
  @override
  void dispose() {
    _height.dispose();
    super.dispose();
  }

  /// 松手时保留速度并吸附，减少动画直接设置落点。
  void _settle(double target, [double velocity = 0]) {
    _height.stop();
    if (OmniMotion.reduce(context)) {
      _height.value = target;
    } else {
      unawaited(
        _height
            .animateWith(
              SpringSimulation(
                const SpringDescription(mass: 1, stiffness: 500, damping: 45),
                _height.value,
                target,
                velocity,
              ),
            )
            .orCancel
            .catchError((Object _) {}),
      );
    }
  }

  /// 下滑请求关闭，保存失败后面板仍停留在可编辑高度。
  Future<void> _dismiss() async {
    await widget.onClose();
    if (mounted) _settle(math.min(200, _available));
  }

  /// 固定底部工具栏，面板内所有高度都从真实键盘占用中扣除。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // 由系统提供的键盘高度，不另外叠加延迟动画。
      final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
      // 无键盘时保留手势安全区。
      final double safeBottom = keyboard > 0
          ? 0
          : MediaQuery.paddingOf(context).bottom;
      _available = math.max(
        0,
        (constraints.maxHeight -
                keyboard -
                safeBottom -
                MediaQuery.paddingOf(context).top) *
            .95,
      );
      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: AnimatedBuilder(
            animation: _height,
            builder: (context, _) {
              // 短屏保留至少一行正文及工具热区，外部约束仍是最终上界。
              final double height = _height.value.clamp(
                math.min(200, _available),
                _available,
              );
              return _AndroidComposerEntrance(
                distance: height + safeBottom + keyboard,
                child: Transform.translate(
                  // 下拉紧凑面板直接跟手位移，避免正文随高度收缩跳动。
                  offset: Offset(
                    0,
                    math.max(0, math.min(200, _available) - _height.value),
                  ),
                  child: Material(
                    key: const ValueKey('android-note-editor'),
                    color: OmniColors.of(context).paper,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(OmniSpacing.xl),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      height: height + safeBottom,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: safeBottom),
                        child: Stack(
                          children: [
                            Column(
                              children: [
                                Semantics(
                                  button: true,
                                  label: '展开或收起笔记',
                                  child: GestureDetector(
                                    key: const ValueKey(
                                      'android-composer-handle',
                                    ),
                                    behavior: HitTestBehavior.opaque,
                                    onTap: widget.enabled
                                        ? () => _settle(
                                            _height.value > 201
                                                ? math.min(200, _available)
                                                : _available,
                                          )
                                        : null,
                                    onVerticalDragStart: widget.enabled
                                        ? (_) => _height.stop()
                                        : null,
                                    onVerticalDragUpdate: widget.enabled
                                        ? (details) => _height.value =
                                              (_height.value - details.delta.dy)
                                                  .clamp(0, _available)
                                        : null,
                                    onVerticalDragEnd: widget.enabled
                                        ? (details) {
                                            if (_height.value <
                                                math.min(200, _available) -
                                                    64) {
                                              unawaited(_dismiss());
                                            } else {
                                              _settle(
                                                (details.primaryVelocity ?? 0) <
                                                            -300 ||
                                                        _height.value >
                                                            (200 + _available) /
                                                                2
                                                    ? _available
                                                    : math.min(200, _available),
                                                -(details.primaryVelocity ?? 0),
                                              );
                                            }
                                          }
                                        : null,
                                    onVerticalDragCancel: widget.enabled
                                        ? () =>
                                              _settle(math.min(200, _available))
                                        : null,
                                    child: SizedBox(
                                      height: OmniSpacing.xl,
                                      width: double.infinity,
                                      child: Center(
                                        child: Container(
                                          width: OmniSize.pageAction,
                                          height: OmniSpacing.xxs,
                                          decoration: BoxDecoration(
                                            color: OmniColors.of(context).line,
                                            borderRadius: BorderRadius.circular(
                                              OmniRadius.pill,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(child: widget.body),
                                widget.toolbar,
                              ],
                            ),
                            Positioned(
                              left: OmniSpacing.md,
                              right: OmniSpacing.md,
                              bottom: OmniSize.touch + OmniSpacing.md,
                              child: AnimatedSwitcher(
                                duration: OmniMotion.duration(
                                  context,
                                  const Duration(milliseconds: 160),
                                ),
                                reverseDuration: OmniMotion.duration(
                                  context,
                                  const Duration(milliseconds: 160),
                                ),
                                child: widget.popup ?? const SizedBox.shrink(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}
