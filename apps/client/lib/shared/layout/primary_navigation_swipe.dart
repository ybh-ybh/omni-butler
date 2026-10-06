import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/management/presentation/management_navigation.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';

/// Android 底部导航对应的五个一级分支。
enum PrimaryNavigationDestination {
  /// 首页分支。
  home,

  /// 每日待办分支。
  todos,

  /// 时间管理分支。
  timeline,

  /// 事件、会员与物品组成的管理分支。
  management,

  /// 更多与设置分支。
  more,
}

/// 返回当前功能开关下可通过底栏和横滑访问的一级分支。
List<int> enabledPrimaryBranchIndices(FeaturePreference preference) {
  return <int>[
    PrimaryNavigationDestination.home.index,
    if (preference.isEnabled(AppFeature.todos))
      PrimaryNavigationDestination.todos.index,
    if (preference.isEnabled(AppFeature.timeline))
      PrimaryNavigationDestination.timeline.index,
    if (preference.isEnabled(AppFeature.events) ||
        preference.isEnabled(AppFeature.memberships) ||
        preference.isEnabled(AppFeature.inventory))
      PrimaryNavigationDestination.management.index,
    PrimaryNavigationDestination.more.index,
  ];
}

/// 子页面在内部横滑边界处使用的一级导航手势控制器。
abstract interface class PrimaryNavigationSwipeController {
  /// 由底部导航请求切换到指定一级分支。
  void navigateToPrimaryDestination(PrimaryNavigationDestination destination);

  /// 开始一级页面横滑。
  void beginPrimarySwipe();

  /// 使用本次手势的累计横向距离更新卡片位置。
  void updatePrimarySwipe(double distance);

  /// 根据离手速度完成切页或回弹。
  void endPrimarySwipe(double velocity);

  /// 取消当前一级页面横滑并回弹。
  void cancelPrimarySwipe();
}

/// 在路由壳层与底部导航之间转发一级页面切换请求。
class PrimaryNavigationCoordinator {
  /// 当前已挂载的卡片导航控制器。
  PrimaryNavigationSwipeController? _controller;

  /// 当前是否已有可接收底栏请求的导航控制器。
  bool get isAttached => _controller != null;

  /// 登记当前已挂载的一级导航控制器。
  void attach(PrimaryNavigationSwipeController controller) {
    _controller = controller;
  }

  /// 仅移除与当前登记值相同的一级导航控制器。
  void detach(PrimaryNavigationSwipeController controller) {
    if (identical(_controller, controller)) {
      _controller = null;
    }
  }

  /// 将底栏选择转发给当前卡片导航控制器。
  void navigateTo(PrimaryNavigationDestination destination) {
    _controller?.navigateToPrimaryDestination(destination);
  }
}

/// 向待办和管理等内部分页提供一级横滑边界接力能力。
class PrimaryNavigationSwipeScope extends InheritedWidget {
  /// 当前一级导航手势控制器。
  final PrimaryNavigationSwipeController controller;

  /// 创建一级导航横滑作用域。
  const PrimaryNavigationSwipeScope({
    required this.controller,
    required super.child,
    super.key,
  });

  /// 返回当前上下文中的一级导航手势控制器。
  static PrimaryNavigationSwipeController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PrimaryNavigationSwipeScope>()
        ?.controller;
  }

  /// 控制器在容器生命周期内保持稳定，无需通知依赖组件重建。
  @override
  bool updateShouldNotify(PrimaryNavigationSwipeScope oldWidget) => false;
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

/// 为待办象限和管理分区提供与一级导航一致的跟手卡片横滑。
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

  /// 创建支持边界接力的内部卡片分页表面。
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

/// 管理内部页面的跟手位移、吸附回弹与一级导航边界接力。
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

  /// 当前横滑是否已经接力给一级导航。
  bool _delegatingToPrimary = false;

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
      _delegatingToPrimary = false;
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
    if (_delegatingToPrimary || _viewportWidth <= 0) {
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
      _delegatingToPrimary = false;
      // 连续拖动从当前弹簧位置接手，避免吸附中途重新按下时跳回原位。
      _rawDragDistance = _dragOffset;
    });
    _notifyPageOffset();
  }

  /// 累计横向拖动并更新内部卡片或一级导航卡片。
  void _updateHorizontalDrag(DragUpdateDetails details) {
    if (_animating || !_gestureActive || _viewportWidth <= 0) {
      return;
    }
    _rawDragDistance += details.primaryDelta ?? 0;
    if (_rawDragDistance == 0) {
      if (_delegatingToPrimary) {
        PrimaryNavigationSwipeScope.maybeOf(context)?.updatePrimarySwipe(0);
      } else {
        setState(() {
          _dragOffset = 0;
          _targetDirection = 0;
        });
        _notifyPageOffset();
      }
      return;
    }
    // 当前拖动指向的页面方向。
    final int direction = _rawDragDistance < 0 ? 1 : -1;
    if (!_delegatingToPrimary && _targetDirection != direction) {
      if (_targetChildForDirection(direction) == null) {
        _targetDirection = 0;
        _dragOffset = 0;
        _delegatingToPrimary = true;
        widget.onPageOffsetChanged?.call(null);
        PrimaryNavigationSwipeScope.maybeOf(context)?.beginPrimarySwipe();
      } else {
        _targetDirection = direction;
      }
    }
    if (_delegatingToPrimary) {
      PrimaryNavigationSwipeScope.maybeOf(context)
          ?.updatePrimarySwipe(_rawDragDistance);
      return;
    }
    setState(() {
      _dragOffset = _targetDirection > 0
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
    if (_delegatingToPrimary) {
      PrimaryNavigationSwipeScope.maybeOf(context)?.endPrimarySwipe(velocity);
      _resetSwipeState();
      return;
    }
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

  /// 取消当前横滑并让内部或一级导航卡片回弹。
  void _cancelHorizontalDrag() {
    if (_animating || !_gestureActive) {
      return;
    }
    _gestureActive = false;
    if (_delegatingToPrimary) {
      PrimaryNavigationSwipeScope.maybeOf(context)?.cancelPrimarySwipe();
      _resetSwipeState();
      return;
    }
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
      _delegatingToPrimary = false;
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

  /// 构建带内部卡片动效和一级导航边界接力的手势表面。
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

/// StatefulShellRoute 的五分支卡片式导航容器。
class PrimaryNavigationBranchContainer extends ConsumerStatefulWidget {
  /// 当前有状态导航壳层。
  final StatefulNavigationShell navigationShell;

  /// 五个分支各自的 Navigator。
  final List<Widget> children;

  /// 与底栏共享的一级导航协调器。
  final PrimaryNavigationCoordinator coordinator;

  /// 创建一级分支导航容器。
  const PrimaryNavigationBranchContainer({
    required this.navigationShell,
    required this.children,
    required this.coordinator,
    super.key,
  });

  /// 创建一级分支导航容器状态。
  @override
  ConsumerState<PrimaryNavigationBranchContainer> createState() =>
      _PrimaryNavigationBranchContainerState();
}

/// 管理 Android 跟手卡片动画与其他平台静态分支布局。
class _PrimaryNavigationBranchContainerState
    extends ConsumerState<PrimaryNavigationBranchContainer>
    with SingleTickerProviderStateMixin
    implements PrimaryNavigationSwipeController {
  /// 卡片拖动时的最大缩小比例。
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

  /// 本次手势接手时的卡片位移，用于连续打断吸附时保持位置。
  double _dragStartOffset = 0;

  /// 当前页面区域的可用宽度。
  double _viewportWidth = 0;

  /// 外层通用横滑累计距离。
  double _outerDragDistance = 0;

  /// 当前是否正在执行自动落位动画。
  bool _animating = false;

  /// 当前是否已有一级横滑手势在进行。
  bool _gestureActive = false;

  /// 当前容器主动触发且等待路由壳层确认的分支索引。
  int? _ownedNavigationTarget;

  /// 用于忽略已被新手势打断的旧动画回调。
  int _animationEpoch = 0;

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

  /// 返回当前视觉分支指定方向上的相邻可见分支。
  int? _adjacentBranch(int direction) {
    // 当前可见一级分支索引。
    final List<int> visibleIndices = _visibleBranchIndices;
    // 当前视觉分支在可见顺序中的位置。
    final int currentPosition = visibleIndices.indexOf(_displayedIndex);
    if (currentPosition < 0) {
      return null;
    }
    // 指定方向上的目标位置。
    final int targetPosition = currentPosition + direction;
    if (targetPosition < 0 || targetPosition >= visibleIndices.length) {
      return null;
    }
    return visibleIndices[targetPosition];
  }

  /// 由底栏请求目标分支，并在动画落位后统一更新路由与选中态。
  @override
  void navigateToPrimaryDestination(PrimaryNavigationDestination destination) {
    if (_animating || _gestureActive) {
      return;
    }
    // 底栏请求进入的分支索引。
    final int targetIndex = destination.index;
    if (targetIndex == _displayedIndex ||
        !_visibleBranchIndices.contains(targetIndex)) {
      return;
    }
    unawaited(_animateRequestedBranchChange(targetIndex));
  }

  /// 开始记录一级页面横滑。
  @override
  void beginPrimarySwipe() {
    if (_animating) {
      _animationEpoch += 1;
      _settleController.stop();
      _animating = false;
      if (_targetIndex != null && _dragOffset.abs() > _viewportWidth / 2) {
        // 交换逻辑基准而非重置画面，让后一次手势可以越过新页面继续前进。
        final int previousIndex = _displayedIndex;
        _displayedIndex = _targetIndex!;
        _targetIndex = previousIndex;
        _dragOffset += _targetDirection * _viewportWidth;
        _targetDirection = -_targetDirection;
        _ownedNavigationTarget = _displayedIndex;
        _navigateToBranch(_displayedIndex);
      }
    }
    setState(() {
      _gestureActive = true;
      // 边界阻尼将可见位移换回原始距离，避免下一帧重复施加阻尼。
      _dragStartOffset = _targetIndex == null
          ? _dragOffset / 0.12
          : _dragOffset;
    });
  }

  /// 使用累计距离更新当前卡片与真实相邻页面。
  @override
  void updatePrimarySwipe(double distance) {
    if (_animating || !_gestureActive || _viewportWidth <= 0) {
      return;
    }
    // 累计距离基于接手位置，吸附期间重新拖动不会重置页面。
    final double cumulativeDistance = _dragStartOffset + distance;
    // 当前拖动指向的可见分支方向。
    final int direction = cumulativeDistance < 0 ? 1 : -1;
    // 当前拖动方向上的相邻一级分支。
    final int? targetIndex = cumulativeDistance == 0
        ? null
        : _targetDirection == direction && _targetIndex != null
        ? _targetIndex
        : _adjacentBranch(direction);
    setState(() {
      _targetIndex = targetIndex;
      _targetDirection = targetIndex == null ? 0 : direction;
      if (targetIndex == null) {
        // 一级导航首尾只提供轻微阻尼，不循环到另一端。
        _dragOffset = (cumulativeDistance * 0.12).clamp(
          -_viewportWidth * 0.08,
          _viewportWidth * 0.08,
        );
      } else if (direction > 0) {
        _dragOffset = cumulativeDistance.clamp(-_viewportWidth, 0);
      } else {
        _dragOffset = cumulativeDistance.clamp(0, _viewportWidth);
      }
    });
  }

  /// 根据离手速度提交一级切页或让卡片回弹。
  @override
  void endPrimarySwipe(double velocity) {
    if (_animating || !_gestureActive) {
      return;
    }
    // 当前是否存在可以进入的真实相邻分支。
    final bool canCommit = _targetIndex != null;
    // 当前手势是否达到原生分页风格的提交条件。
    final bool shouldCommit = OmniPageSwipePhysics.shouldCommit(
      distance: _dragOffset,
      velocity: velocity,
      viewportWidth: _viewportWidth,
      targetDirection: _targetDirection,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    _gestureActive = false;
    if (canCommit && shouldCommit) {
      unawaited(_commitPrimarySwipe(velocity));
      return;
    }
    unawaited(_animateBack(velocity: canCommit ? velocity : 0));
  }

  /// 取消一级页面横滑并让卡片返回原位。
  @override
  void cancelPrimarySwipe() {
    if (_animating || !_gestureActive) {
      return;
    }
    _gestureActive = false;
    unawaited(_animateBack());
  }

  /// 提交当前手势目标并完成两张真实页面卡片的落位。
  Future<void> _commitPrimarySwipe(double velocity) async {
    // 当前手势已经解析出的目标分支。
    final int? targetIndex = _targetIndex;
    if (targetIndex == null || _targetDirection == 0) {
      await _animateBack();
      return;
    }
    // 一级目标页面落位动画是否完整结束。
    final bool completed = await _animateOffsetTo(
      -_targetDirection * _viewportWidth,
      velocity: velocity,
    );
    if (!mounted || !completed) {
      return;
    }
    _ownedNavigationTarget = targetIndex;
    _navigateToBranch(targetIndex);
    _completeTransition(targetIndex);
  }

  /// 为底栏请求播放卡片动画，并在落位后执行真实分支导航。
  Future<void> _animateRequestedBranchChange(int targetIndex) async {
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
      _dragStartOffset = 0;
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

  /// 为底栏点击或程序化跳转播放相同的卡片切换动画。
  Future<void> _animateExternalBranchChange(int targetIndex) async {
    if (_ownedNavigationTarget == targetIndex) {
      _ownedNavigationTarget = null;
      return;
    }
    // 当前与目标分支在可见入口中的位置。
    final List<int> visibleIndices = _visibleBranchIndices;
    // 当前视觉分支的位置。
    final int currentPosition = visibleIndices.indexOf(_displayedIndex);
    // 新目标分支的位置。
    final int targetPosition = visibleIndices.indexOf(targetIndex);
    if (currentPosition < 0 || targetPosition < 0 || _reduceMotion) {
      _completeTransition(targetIndex);
      return;
    }
    setState(() {
      _targetIndex = targetIndex;
      _targetDirection = targetPosition > currentPosition ? 1 : -1;
      _dragOffset = 0;
      _dragStartOffset = 0;
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

  /// 将当前卡片平滑恢复到原位。
  Future<void> _animateBack({double velocity = 0}) async {
    // 一级页面回弹动画是否完整结束。
    final bool completed = await _animateOffsetTo(0, velocity: velocity);
    if (!mounted || !completed) {
      return;
    }
    setState(() {
      _targetIndex = null;
      _targetDirection = 0;
      _dragStartOffset = 0;
    });
  }

  /// 将当前卡片位移动画到指定位置。
  Future<bool> _animateOffsetTo(double targetOffset, {double? velocity}) async {
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
      if (velocity == null) {
        // 底栏点击没有离手速度，保留原有程序化切换时长。
        _settleController.value = _dragOffset;
        await _settleController
            .animateTo(
              targetOffset,
              duration: OmniMotion.panel,
              curve: OmniMotion.standardCurve,
            )
            .orCancel;
      } else {
        // 手势松手直接承接当前位移与速度，不再套用固定时长缓动。
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
      }
      return animationEpoch == _animationEpoch;
    } on TickerCanceled {
      return false;
    } finally {
      if (animationEpoch == _animationEpoch) {
        _animating = false;
      }
    }
  }

  /// 清理切换状态并让目标分支成为完整展示页面。
  void _completeTransition(int targetIndex) {
    if (!mounted) {
      return;
    }
    setState(() {
      _displayedIndex = targetIndex;
      _targetIndex = null;
      _targetDirection = 0;
      _dragOffset = 0;
      _dragStartOffset = 0;
      _gestureActive = false;
      _animating = false;
      _ownedNavigationTarget = null;
    });
  }

  /// 开始外层页面的通用横向拖动。
  void _startOuterDrag(DragStartDetails details) {
    _outerDragDistance = 0;
    beginPrimarySwipe();
  }

  /// 累计外层页面横向拖动并刷新卡片。
  void _updateOuterDrag(DragUpdateDetails details) {
    _outerDragDistance += details.primaryDelta ?? 0;
    updatePrimarySwipe(_outerDragDistance);
  }

  /// 根据外层页面离手速度完成切换。
  void _finishOuterDrag(DragEndDetails details) {
    endPrimarySwipe(details.primaryVelocity ?? 0);
    _outerDragDistance = 0;
  }

  /// 取消外层页面横向拖动。
  void _cancelOuterDrag() {
    cancelPrimarySwipe();
    _outerDragDistance = 0;
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
        ignoring: !current || _gestureActive || _animating,
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

  /// 构建 Android 卡片横滑层或其他平台静态分支层。
  @override
  Widget build(BuildContext context) {
    // 监听功能开关，使可横滑分支与底栏保持一致。
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
        return PrimaryNavigationSwipeScope(
          controller: this,
          child: GestureDetector(
            key: const ValueKey<String>('primary-navigation-swipe-surface'),
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _startOuterDrag,
            onHorizontalDragUpdate: _updateOuterDrag,
            onHorizontalDragEnd: _finishOuterDrag,
            onHorizontalDragCancel: _cancelOuterDrag,
            child: ColoredBox(
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
            ),
          ),
        );
      },
    );
  }
}
