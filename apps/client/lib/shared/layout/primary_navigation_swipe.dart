import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/audio/microphone_coordinator.dart';
import 'package:omni_butler/features/management/presentation/management_navigation.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';

/// Stable branch identities shared with desktop navigation.
enum PrimaryNavigationDestination {
  /// 首页分支。
  home,

  /// 每日待办分支。
  todos,

  /// 时间管理分支。
  timeline,

  /// 独立笔记分支。
  notes,

  /// 事件、会员与物品组成的管理分支。
  management,

  /// 更多与设置分支。
  more,

  /// Android assistant branch follows the existing branch identities.
  assistant,
}

/// Returns the enabled destinations available through bottom-tab selection.
List<int> enabledPrimaryBranchIndices(FeaturePreference preference) {
  return <int>[
    PrimaryNavigationDestination.home.index,
    if (preference.isEnabled(AppFeature.notes))
      PrimaryNavigationDestination.notes.index,
    PrimaryNavigationDestination.assistant.index,
  ];
}

/// Coordinates guarded bottom-tab transitions without accepting drag gestures.
abstract interface class PrimaryNavigationController {
  /// Reports a pending exit guard or visual navigation transition.
  bool get isTransitioning;

  /// Requests a primary destination from the bottom navigation bar.
  void navigateToPrimaryDestination(PrimaryNavigationDestination destination);

  /// Restores the actual branch after a route exit rejects navigation.
  void rejectPendingNavigation();
}

/// Connects the route shell and bottom navigation without gesture ownership.
class PrimaryNavigationCoordinator {
  /// The currently mounted navigation controller.
  PrimaryNavigationController? _controller;

  /// Reports whether a branch container can receive a navigation request.
  bool get isAttached => _controller != null;

  /// Prevents an overlay from racing a guarded tab transition.
  bool get isTransitioning => _controller?.isTransitioning ?? false;

  /// Registers the mounted primary branch controller.
  void attach(PrimaryNavigationController controller) {
    _controller = controller;
  }

  /// Removes only the controller owned by the departing container.
  void detach(PrimaryNavigationController controller) {
    if (identical(_controller, controller)) _controller = null;
  }

  /// Forwards an explicit bottom-tab selection.
  void navigateTo(PrimaryNavigationDestination destination) {
    _controller?.navigateToPrimaryDestination(destination);
  }

  /// Reconciles a rejected route exit with the retained visible branch.
  void rejectPendingNavigation() {
    _controller?.rejectPendingNavigation();
  }
}

/// 与统计卡片共用原生分页的目标判定与弹簧落位。
abstract final class OmniPageSwipePhysics {
  /// 统计卡片使用的原生分页物理参数。
  static const PageScrollPhysics _pagePhysics = PageScrollPhysics();

  /// 为原生分页提供当前设备的逻辑像素与停止容差信息。
  static FixedScrollMetrics _metrics(double width, double devicePixelRatio) {
    return FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: width,
      pixels: 0,
      viewportDimension: width,
      axisDirection: AxisDirection.right,
      devicePixelRatio: devicePixelRatio,
    );
  }

  /// 根据页宽、拖动距离与离手方向判断是否吸附到相邻页面。
  static bool shouldCommit({
    required double distance,
    required double velocity,
    required double viewportWidth,
    required int targetDirection,
    double devicePixelRatio = 1,
  }) {
    if (viewportWidth <= 0 || targetDirection == 0) {
      return false;
    }
    // 将手指位移转换为朝相邻页递增的原生页码。
    double page = (-distance * targetDirection / viewportWidth).clamp(0, 1);
    // 原生分页按设备像素比判断速度是否足以影响落点。
    final Tolerance tolerance = _pagePhysics.toleranceFor(
      _metrics(viewportWidth, devicePixelRatio),
    );
    // 与 PageScrollPhysics 一致，离手方向为页码增加或减少半页偏置。
    final double pageVelocity = -velocity * targetDirection;
    if (pageVelocity < -tolerance.velocity) {
      page -= 0.5;
    } else if (pageVelocity > tolerance.velocity) {
      page += 0.5;
    }
    return page.round() > 0;
  }

  /// 沿用原生分页弹簧，并在可见两页的边界停止，防止高速甩动露白。
  static Simulation createSettlingSimulation({
    required double offset,
    required double targetOffset,
    required double velocity,
    required double viewportWidth,
    required int targetDirection,
    required double devicePixelRatio,
  }) {
    return _BoundedPageSwipeSimulation(
      simulation: ScrollSpringSimulation(
        _pagePhysics.spring,
        offset,
        targetOffset,
        // 原生分页已到落点时不再发起惯性运动，避免反向速度把卡片拉回。
        offset == targetOffset ? 0 : velocity,
        tolerance: _pagePhysics.toleranceFor(
          _metrics(viewportWidth, devicePixelRatio),
        ),
      ),
      minOffset: targetDirection < 0 ? 0 : -viewportWidth,
      maxOffset: targetDirection > 0 ? 0 : viewportWidth,
    );
  }
}

/// 限制两张可见卡片的边界，边界以内保持原生弹簧轨迹。
class _BoundedPageSwipeSimulation extends Simulation {
  /// 使用真实离手速度驱动的原生分页弹簧。
  final Simulation simulation;

  /// 当前两页允许的最小位移。
  final double minOffset;

  /// 当前两页允许的最大位移。
  final double maxOffset;

  /// 创建带可见页面边界的分页模拟。
  _BoundedPageSwipeSimulation({
    required this.simulation,
    required this.minOffset,
    required this.maxOffset,
  });

  /// 在页面边缘截断位移，避免目标卡片滑过最终位置。
  @override
  double x(double time) => simulation.x(time).clamp(minOffset, maxOffset);

  /// 返回边界内的实际速度，结束后不再移动。
  @override
  double dx(double time) => isDone(time) ? 0 : simulation.dx(time);

  /// 弹簧收敛或触达页面外边界时结束吸附。
  @override
  bool isDone(double time) {
    // 当前弹簧计算的未截断位置。
    final double offset = simulation.x(time);
    return offset < minOffset || offset > maxOffset || simulation.isDone(time);
  }
}

/// Provides local card paging without handing edge gestures to primary tabs.
class NestedPageSwipeSurface extends StatefulWidget {
  /// 当前启用的内部页面数量。
  final int pageCount;

  /// 按导航顺序构建页面，只有当前及目标页实际挂载。
  final Widget Function(int index) pageBuilder;

  /// 外部业务状态选中的页码。
  final int pageIndex;

  /// 落位或新手势接手主导页时的绝对页码，不依赖父组件重建时机。
  final ValueChanged<int> onPageChanged;

  /// 横滑中的连续页偏移；后一页为正，前一页为负，结束时为空。
  final ValueChanged<double?>? onPageOffsetChanged;

  /// 手势命中表面的测试标识。
  final Key surfaceKey;

  /// Creates a local pager whose first and last pages remain bounded.
  const NestedPageSwipeSurface({
    required this.pageCount,
    required this.pageBuilder,
    required this.pageIndex,
    required this.onPageChanged,
    required this.surfaceKey,
    this.onPageOffsetChanged,
    super.key,
  }) : assert(pageIndex >= 0 && pageIndex < pageCount);

  /// 创建内部卡片分页状态。
  @override
  State<NestedPageSwipeSurface> createState() => _NestedPageSwipeSurfaceState();
}

/// Owns local page dragging and settling without changing primary routes.
class _NestedPageSwipeSurfaceState extends State<NestedPageSwipeSurface>
    with SingleTickerProviderStateMixin {
  /// 卡片拖动时的最大缩小比例。
  static const double _cardScaleDelta = 0.015;

  /// 卡片拖动时的最大圆角。
  static const double _cardRadius = 12;

  /// 内部分页落位动画控制器。
  late final AnimationController _settleController;

  /// 当前手势的页码基准，允许吸附尚未结束时继续到下一页。
  late int _displayedIndex;

  /// 当前页面卡片的横向位移。
  double _dragOffset = 0;

  /// 本次手势累计的原始横向距离。
  double _rawDragDistance = 0;

  /// 当前页面区域的可用宽度。
  double _viewportWidth = 0;

  /// 内部目标页面方向，后一页为 1，前一页为 -1。
  int _targetDirection = 0;

  /// 当前是否正在执行自动落位动画。
  bool _animating = false;

  /// 当前是否已有横滑手势在进行。
  bool _gestureActive = false;

  /// 用于忽略已被新手势打断的旧动画回调。
  int _animationEpoch = 0;

  /// 初始化内部分页落位动画。
  @override
  void initState() {
    super.initState();
    _displayedIndex = widget.pageIndex;
    _settleController = AnimationController.unbounded(vsync: this)
      ..addListener(_updateSettlingOffset);
  }

  /// 同步点击导航或功能开关导致的外部页码变化，取消过期吸附。
  @override
  void didUpdateWidget(covariant NestedPageSwipeSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageCount != widget.pageCount ||
        (oldWidget.pageIndex != widget.pageIndex &&
            _displayedIndex != widget.pageIndex) ||
        _displayedIndex >= widget.pageCount) {
      _animationEpoch += 1;
      _settleController.stop();
      _displayedIndex = widget.pageIndex;
      _dragOffset = 0;
      _rawDragDistance = 0;
      _targetDirection = 0;
      _gestureActive = false;
      _animating = false;
      // 外部切页在构建中发生，帧后再清除父导航偏移，避免构建期间更新祖先。
      final int resetEpoch = _animationEpoch;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted && resetEpoch == _animationEpoch && !_gestureActive) {
          widget.onPageOffsetChanged?.call(null);
        }
      });
    }
  }

  /// 释放内部分页落位动画控制器。
  @override
  void dispose() {
    _settleController
      ..removeListener(_updateSettlingOffset)
      ..dispose();
    super.dispose();
  }

  /// 根据落位动画进度刷新卡片位移。
  void _updateSettlingOffset() {
    if (!mounted) {
      return;
    }
    setState(() {
      _dragOffset = _settleController.value;
    });
    _notifyPageOffset();
  }

  /// 将当前卡片位移转换为导航滑块使用的连续页偏移。
  void _notifyPageOffset() {
    if (_viewportWidth <= 0) {
      widget.onPageOffsetChanged?.call(null);
      return;
    }
    // 向后一页拖动为正值，向前一页拖动为负值。
    final double pageOffset = (-_dragOffset / _viewportWidth).clamp(-1, 1);
    widget.onPageOffsetChanged?.call(pageOffset);
  }

  /// 返回当前是否应关闭非必要动态效果。
  bool get _reduceMotion => OmniMotion.reduce(context);

  /// 返回指定横滑方向上的内部目标页面。
  Widget? _targetChildForDirection(int direction) {
    // 相对当前手势基准的目标页码。
    final int targetIndex = _displayedIndex + direction;
    return targetIndex >= 0 && targetIndex < widget.pageCount
        ? widget.pageBuilder(targetIndex)
        : null;
  }

  /// 开始记录内部页面横向拖动。
  void _startHorizontalDrag(DragStartDetails details) {
    if (_animating) {
      _animationEpoch += 1;
      _settleController.stop();
      _animating = false;
      if (_targetDirection != 0 && _dragOffset.abs() > _viewportWidth / 2) {
        // 以屏幕上占多数的页面接手，同时保持两张卡片的屏幕坐标不变。
        final int direction = _targetDirection;
        _displayedIndex += direction;
        _dragOffset += direction * _viewportWidth;
        _targetDirection = -direction;
        widget.onPageChanged(_displayedIndex);
      }
    }
    setState(() {
      _gestureActive = true;
      // 连续拖动从当前弹簧位置接手，避免吸附中途重新按下时跳回原位。
      _rawDragDistance = _dragOffset;
    });
    _notifyPageOffset();
  }

  /// Updates only an existing neighboring local page, clamping at both ends.
  void _updateHorizontalDrag(DragUpdateDetails details) {
    if (_animating || !_gestureActive || _viewportWidth <= 0) return;
    _rawDragDistance += details.primaryDelta ?? 0;
    // The desired local direction never becomes a primary navigation request.
    final int direction = _rawDragDistance < 0 ? 1 : -1;
    // Inspect the local index without constructing a hidden page on every move.
    final int targetIndex = _displayedIndex + direction;
    // An unavailable neighbor leaves the page stationary at its boundary.
    final bool hasTarget =
        _rawDragDistance != 0 &&
        targetIndex >= 0 &&
        targetIndex < widget.pageCount;
    setState(() {
      _targetDirection = hasTarget ? direction : 0;
      _dragOffset = !hasTarget
          ? 0
          : direction > 0
          ? _rawDragDistance.clamp(-_viewportWidth, 0)
          : _rawDragDistance.clamp(0, _viewportWidth);
    });
    _notifyPageOffset();
  }

  /// 根据离手速度吸附到相邻内部页面或回弹。
  void _finishHorizontalDrag(DragEndDetails details) {
    if (_animating || !_gestureActive) {
      return;
    }
    // 手指离开时的横向速度，向右为正。
    final double velocity = details.primaryVelocity ?? 0;
    _gestureActive = false;
    // 当前手势是否达到原生分页风格的提交条件。
    final bool shouldCommit = OmniPageSwipePhysics.shouldCommit(
      distance: _dragOffset,
      velocity: velocity,
      viewportWidth: _viewportWidth,
      targetDirection: _targetDirection,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    if (shouldCommit && _targetDirection != 0) {
      unawaited(_commitPageChange(velocity));
      return;
    }
    if (_targetDirection == 0) {
      _resetSwipeState();
      return;
    }
    unawaited(_animateBack(velocity: velocity));
  }

  /// Cancels the local drag and restores its current page.
  void _cancelHorizontalDrag() {
    if (_animating || !_gestureActive) {
      return;
    }
    _gestureActive = false;
    unawaited(_animateBack());
  }

  /// 完成内部页面卡片落位并提交选中项。
  Future<void> _commitPageChange(double velocity) async {
    // 动画开始时锁定的目标页面方向。
    final int direction = _targetDirection;
    if (direction == 0) {
      await _animateBack();
      return;
    }
    // 目标页面落位动画是否完整结束。
    final bool completed = await _animateOffsetTo(
      -direction * _viewportWidth,
      velocity: velocity,
    );
    if (!mounted || !completed) {
      return;
    }
    _displayedIndex += direction;
    widget.onPageChanged(_displayedIndex);
    _resetSwipeState();
  }

  /// 将当前卡片平滑恢复到原位。
  Future<void> _animateBack({double velocity = 0}) async {
    // 回弹动画是否完整结束。
    final bool completed = await _animateOffsetTo(0, velocity: velocity);
    if (!mounted || !completed) {
      return;
    }
    _resetSwipeState();
  }

  /// 将当前卡片位移动画到指定位置。
  Future<bool> _animateOffsetTo(
    double targetOffset, {
    double velocity = 0,
  }) async {
    if (!mounted) {
      return false;
    }
    if (_reduceMotion || _dragOffset == targetOffset) {
      setState(() => _dragOffset = targetOffset);
      return true;
    }
    // 本轮动画的唯一序号。
    final int animationEpoch = ++_animationEpoch;
    _animating = true;
    try {
      await _settleController
          .animateWith(
            OmniPageSwipePhysics.createSettlingSimulation(
              offset: _dragOffset,
              targetOffset: targetOffset,
              velocity: velocity,
              viewportWidth: _viewportWidth,
              targetDirection: _targetDirection,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            ),
          )
          .orCancel;
      return animationEpoch == _animationEpoch;
    } on TickerCanceled {
      return false;
    } finally {
      if (animationEpoch == _animationEpoch) {
        _animating = false;
      }
    }
  }

  /// 清理本轮内部横滑状态。
  void _resetSwipeState() {
    if (!mounted) {
      return;
    }
    setState(() {
      _dragOffset = 0;
      _rawDragDistance = 0;
      _targetDirection = 0;
      _gestureActive = false;
      _animating = false;
    });
    widget.onPageOffsetChanged?.call(null);
  }

  /// 构建当前或目标页面的轻量卡片外观。
  Widget _buildVisiblePage({
    required Widget child,
    required bool current,
    required double width,
  }) {
    // 当前拖动动画的归一化进度。
    final double progress = width <= 0
        ? 0
        : (_dragOffset.abs() / width).clamp(0, 1);
    // 当前卡片和目标卡片各自的横向位置。
    final double translation = current
        ? _dragOffset
        : _dragOffset + (_targetDirection * width);
    // 当前卡片随拖动略微缩小，目标卡片同步恢复完整尺寸。
    final double scale = current
        ? 1 - (_cardScaleDelta * progress)
        : 1 - (_cardScaleDelta * (1 - progress));
    // 当前卡片抬起时增加圆角，目标卡片落位时消除圆角。
    final double radius = current
        ? _cardRadius * progress
        : _cardRadius * (1 - progress);
    // 卡片阴影仅在拖动或自动落位期间出现。
    final double elevation = _reduceMotion
        ? 0
        : current
        ? 8 * progress
        : 8 * (1 - progress);
    // 页面身份不随当前/目标角色交换，避免快滑接手时丢失子树状态。
    final int pageIndex = current
        ? _displayedIndex
        : _displayedIndex + _targetDirection;
    return Positioned.fill(
      key: ValueKey<String>('nested-page-swipe-$pageIndex'),
      child: IgnorePointer(
        ignoring: !current || _gestureActive || _animating,
        child: ExcludeSemantics(
          excluding: !current,
          child: TickerMode(
            enabled: true,
            child: Transform.translate(
              key: ValueKey<String>('nested-page-swipe-$pageIndex-translation'),
              offset: Offset(translation, 0),
              child: Transform.scale(
                key: ValueKey<String>('nested-page-swipe-$pageIndex-scale'),
                scale: _reduceMotion ? 1 : scale,
                child: PhysicalModel(
                  key: ValueKey<String>('nested-page-swipe-$pageIndex-card'),
                  color: OmniColors.of(context).canvas,
                  elevation: elevation,
                  shadowColor: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(
                    _reduceMotion ? 0 : radius,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a local gesture surface with bounded card transitions.
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewportWidth = constraints.maxWidth;
        // 当前横滑方向上的真实相邻页面。
        final Widget? targetChild = _targetDirection == 0
            ? null
            : _targetChildForDirection(_targetDirection);
        return GestureDetector(
          key: widget.surfaceKey,
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _startHorizontalDrag,
          onHorizontalDragUpdate: _updateHorizontalDrag,
          onHorizontalDragEnd: _finishHorizontalDrag,
          onHorizontalDragCancel: _cancelHorizontalDrag,
          child: ColoredBox(
            color: OmniColors.of(context).canvas,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (targetChild != null)
                    _buildVisiblePage(
                      child: targetChild,
                      current: false,
                      width: constraints.maxWidth,
                    ),
                  _buildVisiblePage(
                    child: widget.pageBuilder(_displayedIndex),
                    current: true,
                    width: constraints.maxWidth,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Retains branch state while animating explicit Android bottom-tab choices.
class PrimaryNavigationBranchContainer extends ConsumerStatefulWidget {
  /// 当前有状态导航壳层。
  final StatefulNavigationShell navigationShell;

  /// Retained navigators, including secondary destinations.
  final List<Widget> children;

  /// 与底栏共享的一级导航协调器。
  final PrimaryNavigationCoordinator coordinator;

  /// Allows explicit tab navigation only while a primary destination is active.
  final bool primaryNavigationEnabled;

  /// 创建一级分支导航容器。
  const PrimaryNavigationBranchContainer({
    required this.navigationShell,
    required this.children,
    required this.coordinator,
    this.primaryNavigationEnabled = true,
    super.key,
  });

  /// 创建一级分支导航容器状态。
  @override
  ConsumerState<PrimaryNavigationBranchContainer> createState() =>
      _PrimaryNavigationBranchContainerState();
}

/// Animates explicit Android tab selections while retaining inactive branches.
class _PrimaryNavigationBranchContainerState
    extends ConsumerState<PrimaryNavigationBranchContainer>
    with SingleTickerProviderStateMixin
    implements PrimaryNavigationController {
  /// Maximum card scale change during a bottom-tab transition.
  static const double _cardScaleDelta = 0.015;

  /// 卡片拖动时的最大圆角。
  static const double _cardRadius = 12;

  /// 一级页面落位动画控制器。
  late final AnimationController _settleController;

  /// 当前视觉上完整展示的分支索引。
  late int _displayedIndex;

  /// 当前正在进入的目标分支索引。
  int? _targetIndex;

  /// 目标分支相对当前分支的方向，后一页为 1，前一页为 -1。
  int _targetDirection = 0;

  /// 当前页面卡片的横向位移。
  double _dragOffset = 0;

  /// 当前页面区域的可用宽度。
  double _viewportWidth = 0;

  /// 当前是否正在执行自动落位动画。
  bool _animating = false;

  /// 当前容器主动触发且等待路由壳层确认的分支索引。
  int? _ownedNavigationTarget;

  /// Invalidates animation callbacks superseded by newer route changes.
  int _animationEpoch = 0;

  /// Serialize draft saves and voice cancellation before changing branches.
  bool _exitGuardPending = false;

  /// Invalidate pending saves after external navigation or route rejection.
  int _exitGuardEpoch = 0;

  /// 初始化当前分支与落位动画控制器。
  @override
  void initState() {
    super.initState();
    _displayedIndex = widget.navigationShell.currentIndex;
    _settleController = AnimationController.unbounded(vsync: this)
      ..addListener(_updateSettlingOffset);
    widget.coordinator.attach(this);
  }

  /// 响应底栏点击、深链或其他程序化分支变化。
  @override
  void didUpdateWidget(covariant PrimaryNavigationBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.coordinator, widget.coordinator)) {
      oldWidget.coordinator.detach(this);
      widget.coordinator.attach(this);
    }
    // 路由壳层当前选中的真实分支。
    final int routeIndex = widget.navigationShell.currentIndex;
    if (oldWidget.primaryNavigationEnabled != widget.primaryNavigationEnabled) {
      _resetTransition(routeIndex);
      return;
    }
    if (routeIndex == _displayedIndex || routeIndex == _targetIndex) {
      if (_ownedNavigationTarget == routeIndex) {
        _ownedNavigationTarget = null;
      }
      return;
    }
    // 在本轮构建前启动动画，让随后的一次定时 pump 能正确推进落位进度。
    unawaited(_animateExternalBranchChange(routeIndex));
  }

  /// 释放一级页面落位动画控制器。
  @override
  void dispose() {
    _exitGuardEpoch++;
    widget.coordinator.detach(this);
    _settleController
      ..removeListener(_updateSettlingOffset)
      ..dispose();
    super.dispose();
  }

  /// 根据落位动画进度刷新页面卡片位移。
  void _updateSettlingOffset() {
    if (!mounted) {
      return;
    }
    setState(() {
      _dragOffset = _settleController.value;
    });
  }

  /// 返回当前是否应关闭非必要动态效果。
  bool get _reduceMotion => OmniMotion.reduce(context);

  /// 返回当前功能开关下可见的一级分支。
  List<int> get _visibleBranchIndices {
    // 当前设备功能偏好。
    final FeaturePreference preference = ref.read(featurePreferenceProvider);
    return enabledPrimaryBranchIndices(preference);
  }

  /// Reports the complete save-and-animation interval to navigation controls.
  @override
  bool get isTransitioning =>
      _exitGuardPending || _ownedNavigationTarget != null || _animating;

  /// Animates an explicit tab selection after preserving the outgoing draft.
  @override
  void navigateToPrimaryDestination(PrimaryNavigationDestination destination) {
    if (!widget.primaryNavigationEnabled || isTransitioning) return;
    // The stable branch identity is independent of hidden optional tabs.
    final int targetIndex = destination.index;
    if (targetIndex == _displayedIndex ||
        !_visibleBranchIndices.contains(targetIndex)) {
      return;
    }
    unawaited(_animateRequestedBranchChange(targetIndex));
  }

  /// Cancel stale animation callbacks while preserving navigator identities.
  void _resetTransition(int index) {
    _animationEpoch++;
    _exitGuardEpoch++;
    _settleController.stop();
    _exitGuardPending = false;
    _ownedNavigationTarget = null;
    _completeTransition(index);
  }

  /// A rejected router guard must also reject an optimistic visual transition.
  @override
  void rejectPendingNavigation() {
    if (mounted) _resetTransition(widget.navigationShell.currentIndex);
  }

  /// Stop assistant capture and save drafts before committing a branch exit.
  Future<bool> _prepareBranchChange() async {
    if (!widget.primaryNavigationEnabled || _exitGuardPending) return false;
    // Interrupted transitions can temporarily differ from the actual route.
    final bool leavingNotes =
        _displayedIndex == PrimaryNavigationDestination.notes.index ||
        widget.navigationShell.currentIndex ==
            PrimaryNavigationDestination.notes.index;
    // Voice must be invalidated before an animation can leave the route active.
    final bool leavingAssistant =
        _displayedIndex == PrimaryNavigationDestination.assistant.index ||
        widget.navigationShell.currentIndex ==
            PrimaryNavigationDestination.assistant.index;
    if (!leavingNotes && !leavingAssistant) return true;
    // The focused input must stop accepting edits while its save is pending.
    FocusManager.instance.primaryFocus?.unfocus();
    // This request owns the save gate until navigation invalidates its epoch.
    final int epoch = ++_exitGuardEpoch;
    setState(() => _exitGuardPending = true);
    try {
      if (leavingAssistant) {
        await ref.read(voiceInputLifecycleProvider).cancelAll();
      }
      if (leavingNotes) {
        // Reuse the same editor and save semantics as the router's final guard.
        final editor = ref.read(noteEditorProvider);
        await editor.flush();
        if (editor.dirty) return false;
      }
      // Approval belongs only to the still-current guarded transition.
      final bool approved =
          mounted &&
          widget.primaryNavigationEnabled &&
          epoch == _exitGuardEpoch;
      return approved;
    } catch (_) {
      if (mounted && leavingAssistant && epoch == _exitGuardEpoch) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('草稿未能保存，请检查后重试')));
      }
      return false;
    } finally {
      if (mounted && epoch == _exitGuardEpoch) {
        setState(() => _exitGuardPending = false);
      }
    }
  }

  /// Plays the bottom-tab transition before committing the requested branch.
  Future<void> _animateRequestedBranchChange(int targetIndex) async {
    if (!await _prepareBranchChange() || !mounted) return;
    // 当前与目标分支在可见入口中的位置。
    final List<int> visibleIndices = _visibleBranchIndices;
    // 当前视觉分支的位置。
    final int currentPosition = visibleIndices.indexOf(_displayedIndex);
    // 新目标分支的位置。
    final int targetPosition = visibleIndices.indexOf(targetIndex);
    if (currentPosition < 0 || targetPosition < 0) {
      return;
    }
    setState(() {
      _targetIndex = targetIndex;
      _targetDirection = targetPosition > currentPosition ? 1 : -1;
      _dragOffset = 0;
    });
    // 底栏请求的目标页面落位动画是否完整结束。
    final bool completed = await _animateOffsetTo(
      -_targetDirection * _viewportWidth,
    );
    if (!mounted || !completed) {
      return;
    }
    _ownedNavigationTarget = targetIndex;
    _navigateToBranch(targetIndex);
    _completeTransition(targetIndex);
  }

  /// Reconciles external route changes using the existing tab animation.
  Future<void> _animateExternalBranchChange(int targetIndex) async {
    if (_ownedNavigationTarget == targetIndex) {
      _ownedNavigationTarget = null;
      return;
    }
    _exitGuardEpoch++;
    _exitGuardPending = false;
    // 当前与目标分支在可见入口中的位置。
    final List<int> visibleIndices = _visibleBranchIndices;
    // 当前视觉分支的位置。
    final int currentPosition = visibleIndices.indexOf(_displayedIndex);
    // 新目标分支的位置。
    final int targetPosition = visibleIndices.indexOf(targetIndex);
    if (!widget.primaryNavigationEnabled ||
        currentPosition < 0 ||
        targetPosition < 0 ||
        _reduceMotion) {
      _completeTransition(targetIndex);
      return;
    }
    setState(() {
      _targetIndex = targetIndex;
      _targetDirection = targetPosition > currentPosition ? 1 : -1;
      _dragOffset = 0;
    });
    // 外部路由目标页面落位动画是否完整结束。
    final bool completed = await _animateOffsetTo(
      -_targetDirection * _viewportWidth,
    );
    if (!completed) {
      return;
    }
    _completeTransition(targetIndex);
  }

  /// 导航到目标分支，并为管理入口恢复有效的最近分区。
  void _navigateToBranch(int targetIndex) {
    if (targetIndex != PrimaryNavigationDestination.management.index) {
      widget.navigationShell.goBranch(targetIndex);
      return;
    }
    // 当前设备功能偏好。
    final FeaturePreference preference = ref.read(featurePreferenceProvider);
    // 当前记住的管理分区。
    final ManagementSection preferredSection = ref.read(
      managementSectionProvider,
    );
    // 功能开关过滤后的有效管理分区。
    final ManagementSection? resolvedSection = resolveManagementSection(
      preference,
      preferredSection,
    );
    if (resolvedSection == null) {
      return;
    }
    ref.read(managementSectionProvider.notifier).select(resolvedSection);
    context.go(resolvedSection.route);
  }

  /// Animates only explicit tab requests using the existing panel timing.
  Future<bool> _animateOffsetTo(double targetOffset) async {
    if (!mounted) return false;
    if (_reduceMotion || _dragOffset == targetOffset) {
      setState(() => _dragOffset = targetOffset);
      return true;
    }
    // Late animation completion cannot override a newer external route.
    final int animationEpoch = ++_animationEpoch;
    _animating = true;
    try {
      _settleController.value = _dragOffset;
      await _settleController
          .animateTo(
            targetOffset,
            duration: OmniMotion.panel,
            curve: OmniMotion.standardCurve,
          )
          .orCancel;
      return animationEpoch == _animationEpoch;
    } on TickerCanceled {
      return false;
    } finally {
      if (animationEpoch == _animationEpoch) _animating = false;
    }
  }

  /// Clears the completed transition while retaining the target navigator.
  void _completeTransition(int targetIndex) {
    if (!mounted) {
      return;
    }
    setState(() {
      _displayedIndex = targetIndex;
      _targetIndex = null;
      _targetDirection = 0;
      _dragOffset = 0;
      _animating = false;
      if (widget.navigationShell.currentIndex == targetIndex) {
        _ownedNavigationTarget = null;
      }
    });
  }

  /// 构建保留状态但不参与布局、绘制与语义的非活动分支。
  Widget _buildInactiveBranch(int index) {
    return Offstage(
      key: ValueKey<String>('primary-navigation-inactive-$index'),
      offstage: true,
      child: TickerMode(enabled: false, child: widget.children[index]),
    );
  }

  /// 构建当前或目标页面的轻量卡片外观。
  Widget _buildVisibleBranch({
    required int index,
    required bool current,
    required double width,
  }) {
    // 当前拖动动画的归一化进度。
    final double progress = width <= 0
        ? 0
        : (_dragOffset.abs() / width).clamp(0, 1);
    // 当前卡片和目标卡片各自的横向位置。
    final double translation = current
        ? _dragOffset
        : _dragOffset + (_targetDirection * width);
    // 当前卡片随拖动略微缩小，目标卡片同步恢复完整尺寸。
    final double scale = current
        ? 1 - (_cardScaleDelta * progress)
        : 1 - (_cardScaleDelta * (1 - progress));
    // 当前卡片抬起时增加圆角，目标卡片落位时消除圆角。
    final double radius = current
        ? _cardRadius * progress
        : _cardRadius * (1 - progress);
    // 卡片阴影仅在拖动或自动落位期间出现。
    final double elevation = _reduceMotion
        ? 0
        : current
        ? 8 * progress
        : 8 * (1 - progress);
    return Positioned.fill(
      key: ValueKey<String>('primary-navigation-positioned-$index'),
      child: IgnorePointer(
        ignoring: !current || _animating || _exitGuardPending,
        child: ExcludeSemantics(
          excluding: !current,
          child: TickerMode(
            enabled: true,
            child: Transform.translate(
              key: ValueKey<String>('primary-navigation-translation-$index'),
              offset: Offset(translation, 0),
              child: Transform.scale(
                key: ValueKey<String>('primary-navigation-scale-$index'),
                scale: _reduceMotion ? 1 : scale,
                child: PhysicalModel(
                  key: ValueKey<String>('primary-navigation-card-$index'),
                  color: OmniColors.of(context).canvas,
                  elevation: elevation,
                  shadowColor: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(
                    _reduceMotion ? 0 : radius,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: widget.children[index],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 构建不带动效的普通分支容器。
  Widget _buildStaticContainer() {
    return IndexedStack(
      index: widget.navigationShell.currentIndex,
      children: <Widget>[
        for (int index = 0; index < widget.children.length; index += 1)
          Offstage(
            offstage: widget.navigationShell.currentIndex != index,
            child: TickerMode(
              enabled: widget.navigationShell.currentIndex == index,
              child: widget.children[index],
            ),
          ),
      ],
    );
  }

  /// Builds retained Android tab transitions without an outer drag recognizer.
  @override
  Widget build(BuildContext context) {
    // Keep available click destinations synchronized with feature preferences.
    ref.watch(featurePreferenceProvider);
    // 当前是否启用 Android 紧凑导航动效。
    final bool androidCompact =
        Theme.of(context).platform == TargetPlatform.android &&
        OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
    if (!androidCompact) {
      return _buildStaticContainer();
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewportWidth = constraints.maxWidth;
        // 当前正在参与卡片切换的目标分支。
        final int? targetIndex = _targetIndex;
        // 保留全部非活动 Navigator 状态的隐藏分支。
        final List<Widget> inactiveBranches = <Widget>[
          for (int index = 0; index < widget.children.length; index += 1)
            if (index != _displayedIndex && index != targetIndex)
              _buildInactiveBranch(index),
        ];
        return ColoredBox(
          key: const ValueKey<String>('primary-navigation-surface'),
          color: OmniColors.of(context).canvas,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ...inactiveBranches,
                if (targetIndex != null)
                  _buildVisibleBranch(
                    index: targetIndex,
                    current: false,
                    width: constraints.maxWidth,
                  ),
                _buildVisibleBranch(
                  index: _displayedIndex,
                  current: true,
                  width: constraints.maxWidth,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
