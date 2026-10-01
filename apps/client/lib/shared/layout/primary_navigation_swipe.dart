import 'dart:async';
import 'dart:ui' show lerpDouble;

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
  /// 触发一级切页所需的最小横向拖动距离。
  static const double _swipeDistanceThreshold = 48;

  /// 触发一级切页所需的最小横向速度。
  static const double _swipeVelocityThreshold = 500;

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

  /// 本次手势累计的原始横向距离。
  double _rawDragDistance = 0;

  /// 自动落位动画的起始横向位移。
  double _animationStartOffset = 0;

  /// 自动落位动画的目标横向位移。
  double _animationEndOffset = 0;

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

  /// 初始化当前分支与落位动画控制器。
  @override
  void initState() {
    super.initState();
    _displayedIndex = widget.navigationShell.currentIndex;
    _settleController = AnimationController(
      vsync: this,
      duration: OmniMotion.panel,
    )..addListener(_updateSettlingOffset);
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
      _dragOffset = lerpDouble(
        _animationStartOffset,
        _animationEndOffset,
        OmniMotion.standardCurve.transform(_settleController.value),
      )!;
    });
  }

  /// 返回当前是否应关闭非必要动态效果。
  bool get _reduceMotion {
    // 当前页面媒体信息。
    final MediaQueryData? media = MediaQuery.maybeOf(context);
    return media?.disableAnimations == true ||
        media?.accessibleNavigation == true;
  }

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
      return;
    }
    _settleController.stop();
    setState(() {
      _gestureActive = true;
      _targetIndex = null;
      _targetDirection = 0;
      _dragOffset = 0;
      _rawDragDistance = 0;
    });
  }

  /// 使用累计距离更新当前卡片与真实相邻页面。
  @override
  void updatePrimarySwipe(double distance) {
    if (_animating || !_gestureActive || _viewportWidth <= 0) {
      return;
    }
    // 当前拖动指向的可见分支方向。
    final int direction = distance < 0 ? 1 : -1;
    // 当前拖动方向上的相邻一级分支。
    final int? targetIndex = distance == 0 ? null : _adjacentBranch(direction);
    setState(() {
      _rawDragDistance = distance;
      _targetIndex = targetIndex;
      _targetDirection = targetIndex == null ? 0 : direction;
      if (targetIndex == null) {
        // 一级导航首尾只提供轻微阻尼，不循环到另一端。
        _dragOffset = (distance * 0.12).clamp(
          -_viewportWidth * 0.08,
          _viewportWidth * 0.08,
        );
      } else if (direction > 0) {
        _dragOffset = distance.clamp(-_viewportWidth, 0);
      } else {
        _dragOffset = distance.clamp(0, _viewportWidth);
      }
    });
  }

  /// 根据离手速度提交一级切页或让卡片回弹。
  @override
  void endPrimarySwipe(double velocity) {
    if (_animating || !_gestureActive) {
      return;
    }
    // 是否达到稳定拖动距离阈值。
    final bool reachedDistance =
        _rawDragDistance.abs() >= _swipeDistanceThreshold;
    // 是否达到快速横扫速度阈值。
    final bool reachedVelocity = velocity.abs() >= _swipeVelocityThreshold;
    // 当前是否存在可以进入的真实相邻分支。
    final bool canCommit = _targetIndex != null;
    _gestureActive = false;
    if (canCommit && (reachedDistance || reachedVelocity)) {
      _commitPrimarySwipe();
      return;
    }
    _animateBack();
  }

  /// 取消一级页面横滑并让卡片返回原位。
  @override
  void cancelPrimarySwipe() {
    if (_animating || !_gestureActive) {
      return;
    }
    _gestureActive = false;
    _animateBack();
  }

  /// 提交当前手势目标并完成两张真实页面卡片的落位。
  Future<void> _commitPrimarySwipe() async {
    // 当前手势已经解析出的目标分支。
    final int? targetIndex = _targetIndex;
    if (targetIndex == null || _targetDirection == 0) {
      await _animateBack();
      return;
    }
    await _animateOffsetTo(-_targetDirection * _viewportWidth);
    if (!mounted) {
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
      _rawDragDistance = 0;
    });
    await _animateOffsetTo(-_targetDirection * _viewportWidth);
    if (!mounted) {
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
      _rawDragDistance = 0;
    });
    await _animateOffsetTo(-_targetDirection * _viewportWidth);
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
  Future<void> _animateBack() async {
    await _animateOffsetTo(0, duration: OmniMotion.normal);
    if (!mounted) {
      return;
    }
    setState(() {
      _targetIndex = null;
      _targetDirection = 0;
      _rawDragDistance = 0;
    });
  }

  /// 将当前卡片位移动画到指定位置。
  Future<void> _animateOffsetTo(
    double targetOffset, {
    Duration duration = OmniMotion.panel,
  }) async {
    if (!mounted) {
      return;
    }
    if (_reduceMotion) {
      setState(() => _dragOffset = targetOffset);
      return;
    }
    _animating = true;
    _animationStartOffset = _dragOffset;
    _animationEndOffset = targetOffset;
    _settleController.duration = duration;
    try {
      await _settleController.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    } finally {
      _animating = false;
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
      _rawDragDistance = 0;
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
