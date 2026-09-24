import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/ui/omni_sliding_segmented_control.dart';

/// Android 管理页可切换的业务分区。
enum ManagementSection {
  /// 事件记录。
  events,

  /// 会员管理。
  memberships,

  /// 物品管理。
  inventory,
}

/// 管理分区的展示与导航信息。
extension ManagementSectionPresentation on ManagementSection {
  /// 顶部滑块展示文案。
  String get label => switch (this) {
    ManagementSection.inventory => '物品管理',
    ManagementSection.events => '事件记录',
    ManagementSection.memberships => '会员管理',
  };

  /// 对应的现有业务路由。
  String get route => switch (this) {
    ManagementSection.inventory => '/inventory',
    ManagementSection.events => '/events',
    ManagementSection.memberships => '/memberships',
  };

  /// 对应的功能开关。
  AppFeature get feature => switch (this) {
    ManagementSection.inventory => AppFeature.inventory,
    ManagementSection.events => AppFeature.events,
    ManagementSection.memberships => AppFeature.memberships,
  };
}

/// 管理页会话内最后选中分区控制器。
class ManagementSectionController extends Notifier<ManagementSection> {
  /// 首次进入默认显示物品管理。
  @override
  ManagementSection build() => ManagementSection.inventory;

  /// 记住用户最近选中的管理分区。
  void select(ManagementSection section) {
    if (state == section) {
      return;
    }
    state = section;
  }
}

/// 管理页会话内选中分区。
final NotifierProvider<ManagementSectionController, ManagementSection>
managementSectionProvider =
    NotifierProvider<ManagementSectionController, ManagementSection>(
      ManagementSectionController.new,
    );

/// 返回当前已启用的管理分区。
List<ManagementSection> enabledManagementSections(
  FeaturePreference preference,
) {
  return ManagementSection.values
      .where(
        (ManagementSection section) => preference.isEnabled(section.feature),
      )
      .toList(growable: false);
}

/// 返回可用的首选分区；全部关闭时返回空值。
ManagementSection? resolveManagementSection(
  FeaturePreference preference,
  ManagementSection preferred,
) {
  // 当前已启用的分区列表。
  final List<ManagementSection> sections = enabledManagementSections(
    preference,
  );
  if (sections.isEmpty) {
    return null;
  }
  return sections.contains(preferred) ? preferred : sections.first;
}

/// Android 紧凑布局的管理页顶部切换壳层。
class AndroidManagementShell extends ConsumerStatefulWidget {
  /// 当前路由对应的管理分区。
  final ManagementSection selectedSection;

  /// 当前分区页面。
  final Widget child;

  /// 创建 Android 管理页壳层。
  const AndroidManagementShell({
    required this.selectedSection,
    required this.child,
    super.key,
  });

  /// 创建管理页壳层状态。
  @override
  ConsumerState<AndroidManagementShell> createState() =>
      _AndroidManagementShellState();
}

/// Android 管理页壳层状态。
class _AndroidManagementShellState
    extends ConsumerState<AndroidManagementShell> {
  /// 触发管理分区切换所需的最小横向拖动距离。
  static const double _swipeDistanceThreshold = 48;

  /// 触发管理分区切换所需的最小横向速度。
  static const double _swipeVelocityThreshold = 500;

  /// 本次横向拖动累计距离，向右为正。
  double _horizontalDragDistance = 0;

  /// 初始化时将直达路由记为最近分区。
  @override
  void initState() {
    super.initState();
    _rememberSelectedSection();
  }

  /// 路由复用状态时同步新的目标分区。
  @override
  void didUpdateWidget(covariant AndroidManagementShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedSection != widget.selectedSection) {
      _rememberSelectedSection();
    }
  }

  /// 记住当前路由对应的管理分区。
  void _rememberSelectedSection() {
    // 本次路由进入时的目标分区。
    final ManagementSection targetSection = widget.selectedSection;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || widget.selectedSection != targetSection) {
        return;
      }
      ref.read(managementSectionProvider.notifier).select(targetSection);
    });
  }

  /// 开始记录管理页面横向拖动。
  void _startHorizontalDrag(DragStartDetails details) {
    _horizontalDragDistance = 0;
  }

  /// 累计管理页面横向拖动距离。
  void _updateHorizontalDrag(DragUpdateDetails details) {
    _horizontalDragDistance += details.primaryDelta ?? 0;
  }

  /// 取消本次管理页面横向拖动。
  void _cancelHorizontalDrag() {
    _horizontalDragDistance = 0;
  }

  /// 根据拖动距离和速度完成管理分区切换。
  void _finishHorizontalDrag(DragEndDetails details) {
    // 手指离开时的横向速度，向右为正。
    final double velocity = details.primaryVelocity ?? 0;
    // 是否达到稳定的拖动距离阈值。
    final bool reachedDistance =
        _horizontalDragDistance.abs() >= _swipeDistanceThreshold;
    // 是否达到快速滑动速度阈值。
    final bool reachedVelocity = velocity.abs() >= _swipeVelocityThreshold;
    if (!reachedDistance && !reachedVelocity) {
      _horizontalDragDistance = 0;
      return;
    }
    // 优先使用已达到阈值的拖动距离，快速短扫则使用离手速度。
    final double direction = reachedDistance
        ? _horizontalDragDistance
        : velocity;
    _horizontalDragDistance = 0;
    _moveToAdjacentSection(direction < 0 ? 1 : -1);
  }

  /// 切换到当前分区前后相邻的已启用分区。
  void _moveToAdjacentSection(int offset) {
    // 当前功能启用偏好。
    final FeaturePreference preference = ref.read(featurePreferenceProvider);
    // 当前已启用的管理分区。
    final List<ManagementSection> sections = enabledManagementSections(
      preference,
    );
    // 当前路由对应的有效管理分区。
    final ManagementSection? currentSection = resolveManagementSection(
      preference,
      widget.selectedSection,
    );
    if (currentSection == null || sections.length < 2) {
      return;
    }
    // 当前有效分区在启用列表中的位置。
    final int currentIndex = sections.indexOf(currentSection);
    // 横滑后的目标分区位置。
    final int targetIndex = currentIndex + offset;
    if (targetIndex < 0 || targetIndex >= sections.length) {
      return;
    }
    // 横滑命中的相邻管理分区。
    final ManagementSection targetSection = sections[targetIndex];
    ref.read(managementSectionProvider.notifier).select(targetSection);
    context.go(targetSection.route);
  }

  /// 构建全宽滑块和当前业务页面。
  @override
  Widget build(BuildContext context) {
    // 当前功能启用偏好。
    final FeaturePreference preference = ref.watch(featurePreferenceProvider);
    // 当前可见的管理分区。
    final List<ManagementSection> sections = enabledManagementSections(
      preference,
    );
    // 当前路由关闭后的安全回退分区。
    final ManagementSection? effectiveSection = resolveManagementSection(
      preference,
      widget.selectedSection,
    );
    if (effectiveSection == null) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      key: const ValueKey<String>('android-management-swipe-surface'),
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: sections.length > 1 ? _startHorizontalDrag : null,
      onHorizontalDragUpdate: sections.length > 1
          ? _updateHorizontalDrag
          : null,
      onHorizontalDragEnd: sections.length > 1 ? _finishHorizontalDrag : null,
      onHorizontalDragCancel: sections.length > 1
          ? _cancelHorizontalDrag
          : null,
      child: Column(
        key: const ValueKey<String>('android-management-shell'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpacing.xs,
              OmniSpacing.xs,
              OmniSpacing.xs,
              0,
            ),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return OmniSlidingSegmentedControl<ManagementSection>(
                  key: const ValueKey<String>('management-section-control'),
                  options: sections,
                  selected: effectiveSection,
                  width: constraints.maxWidth,
                  height: OmniSize.touch,
                  labelBuilder: (ManagementSection section) => section.label,
                  itemKeyBuilder: (ManagementSection section) =>
                      ValueKey<String>('management-section-${section.name}'),
                  onChanged: (ManagementSection section) {
                    ref
                        .read(managementSectionProvider.notifier)
                        .select(section);
                    context.go(section.route);
                  },
                );
              },
            ),
          ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}
