import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 在根导航器打开由顶部横线控制高度的底部模态面板。
Future<T?> showOmniExpandableBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    _OmniExpandableBottomSheetRoute<T>(context: context, builder: builder),
  );
}

/// 区分遮罩关闭和系统返回，键盘打开时点遮罩仍可丢弃草稿。
class _OmniExpandableBottomSheetRoute<T> extends ModalBottomSheetRoute<T> {
  /// 由当前面板提供动态提交保护，避免遮罩绕过保存锁定。
  VoidCallback? onBarrierDismiss;

  /// 保留 Flutter 原生底部路由、安全区域、主题传递与进出动画。
  _OmniExpandableBottomSheetRoute({
    required BuildContext context,
    required super.builder,
  }) : super(
         capturedThemes: InheritedTheme.capture(
           from: context,
           to: Navigator.of(context, rootNavigator: true).context,
         ),
         useSafeArea: true,
         isScrollControlled: true,
         enableDrag: false,
         showDragHandle: false,
         backgroundColor: Colors.transparent,
         modalBarrierColor: Theme.of(context)
             .bottomSheetTheme
             .modalBarrierColor,
         barrierLabel: MaterialLocalizations.of(context)
             .modalBarrierDismissLabel,
         constraints: const BoxConstraints(),
         sheetAnimationStyle: OmniMotion.reduce(context)
             ? AnimationStyle.noAnimation
             : const AnimationStyle(
                 duration: OmniMotion.panel,
                 reverseDuration: OmniMotion.normal,
               ),
       );

  /// 遮罩始终经当前面板检查关闭权限，不把点击误作键盘返回。
  @override
  Widget buildModalBarrier() => AnimatedModalBarrier(
    color: animation!.drive(
      ColorTween(
        begin: barrierColor.withValues(alpha: 0),
        end: barrierColor,
      ).chain(CurveTween(curve: barrierCurve)),
    ),
    dismissible: barrierDismissible,
    semanticsLabel: barrierLabel,
    onDismiss: () => onBarrierDismiss?.call(),
  );
}

/// 固定顶部操作、独立正文滚动的半屏/全屏面板。
class OmniExpandableBottomSheetScaffold extends StatefulWidget {
  /// 左侧取消操作。
  final Widget leading;

  /// 右侧主要操作。
  final Widget trailing;

  /// 按稳定的展开状态构建正文，业务自行持有输入状态。
  final Widget Function(BuildContext context, bool expanded) bodyBuilder;

  /// 提交期间禁止关闭及改变高度。
  final bool canClose;

  /// 无障碍朗读使用的面板名称。
  final String semanticsLabel;

  /// 创建可展开底部面板。
  const OmniExpandableBottomSheetScaffold({
    required this.leading,
    required this.trailing,
    required this.bodyBuilder,
    required this.semanticsLabel,
    this.canClose = true,
    super.key,
  });

  /// 创建高度、手势及滚动状态。
  @override
  State<OmniExpandableBottomSheetScaffold> createState() =>
      _OmniExpandableBottomSheetScaffoldState();
}

/// 独立管理面板高度，避免正文滚动与输入手势改变展开状态。
class _OmniExpandableBottomSheetScaffoldState
    extends State<OmniExpandableBottomSheetScaffold>
    with SingleTickerProviderStateMixin {
  /// 初始及收起时的高度比例。
  static const double _collapsedExtent = 0.5;

  /// 沿用应用分页的原生弹簧与设备像素容差。
  static const PageScrollPhysics _physics = PageScrollPhysics();

  /// 连续高度动画，可被下一次拖拽即时接管。
  late final AnimationController _extent;

  /// 正文滚动位置与面板高度独立。
  final ScrollController _scrollController = ScrollController();

  /// 只有吸附完成才更新字段可见状态。
  bool _expanded = false;

  /// 每次接管递增，忽略被取消的旧吸附回调。
  int _motionGeneration = 0;

  /// 布局后得到的安全可用高度，用于归一化手指位移。
  double _availableHeight = 1;

  /// 当前手势是否仍可控制面板。
  bool _dragging = false;

  /// 初始化连续高度控制器。
  @override
  void initState() {
    super.initState();
    _extent = AnimationController.unbounded(
      vsync: this,
      value: _collapsedExtent,
    )..addListener(_onExtentChanged);
  }

  /// 注册遮罩关闭入口，当前表单仍负责保存与取消。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 当前弹窗使用的原生模态路由。
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route is _OmniExpandableBottomSheetRoute<Object?>) {
      route.onBarrierDismiss = _dismissFromBarrier;
    }
  }

  /// 点击遮罩直接关闭，提交时保持锁定。
  void _dismissFromBarrier() {
    if (widget.canClose) Navigator.of(context).pop();
  }

  /// 提交锁定时中断正在进行的手势与吸附。
  @override
  void didUpdateWidget(OmniExpandableBottomSheetScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.canClose && oldWidget.canClose) {
      _dragging = false;
      _stopMotion();
    }
  }

  /// 释放动画和正文滚动资源。
  @override
  void dispose() {
    _motionGeneration += 1;
    _extent.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 每帧重建高度，始终保留业务正文的稳定身份。
  void _onExtentChanged() => setState(() {});

  /// 中断旧吸附，下一段动作从当前显示位置继续。
  void _stopMotion() {
    _motionGeneration += 1;
    _extent.stop();
  }

  /// 横线拖动开始时接管当前动画位置。
  void _onDragStart(DragStartDetails details) {
    if (!widget.canClose) return;
    _stopMotion();
    _extent.value = _extent.value.clamp(_collapsedExtent, 1);
    _dragging = true;
  }

  /// 跟随手指调整高度，并限制在半屏和全屏之间。
  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging || !widget.canClose) return;
    _extent.value = (_extent.value - details.delta.dy / _availableHeight).clamp(
      _collapsedExtent,
      1,
    );
  }

  /// 按离手方向和中点选择落点，保留真实离手速度。
  void _onDragEnd(DragEndDetails details) {
    if (!_dragging || !widget.canClose) return;
    _dragging = false;
    // 将手指向上的速度转换为高度增加速度。
    final double velocity = -(details.primaryVelocity ?? 0);
    // 原生物理使用的安全视口和设备像素比。
    final FixedScrollMetrics metrics = _metrics;
    // 足以表达离手方向的设备像素速度容差。
    final double velocityTolerance = _physics.toleranceFor(metrics).velocity;
    // 无明显速度时，以半屏和全屏的中点选择最近落点。
    final bool expand = velocity.abs() > velocityTolerance
        ? velocity > 0
        : _extent.value >= (_collapsedExtent + 1) / 2;
    unawaited(_settle(expand: expand, velocity: velocity));
  }

  /// 系统取消手势时，恢复最近的稳定高度。
  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    unawaited(_settle(expand: _extent.value >= (_collapsedExtent + 1) / 2));
  }

  /// 点击横线或读屏操作也可展开和收起。
  void _toggle() {
    if (!widget.canClose) return;
    unawaited(_settle(expand: !_expanded));
  }

  /// 为垂直弹簧构建与项目分页一致的原生物理参数。
  FixedScrollMetrics get _metrics => FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: _availableHeight,
    pixels: _extent.value * _availableHeight,
    viewportDimension: _availableHeight,
    axisDirection: AxisDirection.down,
    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
  );

  /// 从当前高度开始弹簧吸附，旧动画完成不能覆盖新手势。
  Future<void> _settle({required bool expand, double velocity = 0}) async {
    _stopMotion();
    // 这次吸附对应的有效代次。
    final int generation = _motionGeneration;
    // 全屏和半屏仅有两个稳定落点。
    final double target = expand ? 1 : _collapsedExtent;
    if (!expand) FocusManager.instance.primaryFocus?.unfocus();
    if (!OmniMotion.reduce(context) && _extent.value != target) {
      // 将原生像素容差转换为安全视口比例。
      final Tolerance tolerance = _physics.toleranceFor(_metrics);
      try {
        await _extent
            .animateWith(
              ScrollSpringSimulation(
                _physics.spring,
                _extent.value,
                target,
                velocity / _availableHeight,
                tolerance: Tolerance(
                  distance: tolerance.distance / _availableHeight,
                  velocity: tolerance.velocity / _availableHeight,
                ),
              ),
            )
            .orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted || generation != _motionGeneration) return;
    _extent.value = target;
    setState(() => _expanded = expand);
    if (!expand && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  /// 构建固定操作栏及由横线控制的安全高度。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 键盘和底部系统栏分别避让，不改变字段展开状态。
    final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    // 键盘关闭时为系统手势栏保留实底安全区域。
    final double safeBottom = keyboardInset > 0
        ? 0
        : MediaQuery.paddingOf(context).bottom;
    return PopScope<Object?>(
      canPop: widget.canClose && keyboardInset == 0,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && widget.canClose && keyboardInset > 0) {
          FocusManager.instance.primaryFocus?.unfocus();
        }
      },
      child: FocusTraversalGroup(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            _availableHeight =
                (constraints.maxHeight - keyboardInset - safeBottom).clamp(
                  1,
                  double.infinity,
                );
            // 键盘占用大部分横屏时，仍为正文保留一行输入及滚动留白。
            final double minimumHeight =
                (OmniSize.touch * (keyboardInset > 0 ? 3 : 2) +
                        OmniSpacing.md +
                        (keyboardInset > 0 ? OmniSpacing.lg : OmniSize.control))
                    .clamp(0, _availableHeight);
            return Padding(
              padding: EdgeInsets.only(bottom: keyboardInset),
              child: SizedBox(
                height:
                    (_availableHeight *
                            _extent.value.clamp(_collapsedExtent, 1))
                        .clamp(minimumHeight, _availableHeight) +
                    safeBottom,
                width: constraints.maxWidth,
                child: Material(
                  key: const ValueKey<String>('omni-expandable-sheet-surface'),
                  color: colors.paper,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(OmniRadius.dialog),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: safeBottom),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Semantics(
                          button: true,
                          label:
                              '${_expanded ? '收起' : '展开'}${widget.semanticsLabel}',
                          onTap: widget.canClose ? _toggle : null,
                          excludeSemantics: true,
                          child: GestureDetector(
                            dragStartBehavior: DragStartBehavior.down,
                            onVerticalDragStart: widget.canClose
                                ? _onDragStart
                                : null,
                            onVerticalDragUpdate: widget.canClose
                                ? _onDragUpdate
                                : null,
                            onVerticalDragEnd: widget.canClose
                                ? _onDragEnd
                                : null,
                            onVerticalDragCancel: widget.canClose
                                ? _onDragCancel
                                : null,
                            child: InkWell(
                              key: const ValueKey<String>(
                                'omni-expandable-sheet-handle',
                              ),
                              onTap: widget.canClose ? _toggle : null,
                              child: SizedBox(
                                height: OmniSize.touch,
                                child: Center(
                                  child: Container(
                                    width: OmniSpacing.xxl,
                                    height: OmniSpacing.xxs,
                                    decoration: BoxDecoration(
                                      color: colors.muted,
                                      borderRadius: BorderRadius.circular(
                                        OmniRadius.pill,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: OmniSpacing.md,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: <Widget>[widget.leading, widget.trailing],
                          ),
                        ),
                        const SizedBox(height: OmniSpacing.md),
                        Expanded(
                          child: SingleChildScrollView(
                            key: const ValueKey<String>(
                              'omni-expandable-sheet-body',
                            ),
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(
                              OmniSpacing.md,
                              0,
                              OmniSpacing.md,
                              OmniSpacing.lg,
                            ),
                            child: widget.bodyBuilder(context, _expanded),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
