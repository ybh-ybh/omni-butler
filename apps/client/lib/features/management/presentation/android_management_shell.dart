import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/events/presentation/events_page.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_page.dart';
import 'package:omni_butler/features/management/presentation/management_navigation.dart';
import 'package:omni_butler/features/memberships/presentation/memberships_page.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/layout/primary_navigation_swipe.dart';
import 'package:omni_butler/shared/ui/omni_sliding_segmented_control.dart';

export 'package:omni_butler/features/management/presentation/management_navigation.dart';

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
  /// 管理内容横滑时顶部导航滑块的连续页偏移。
  double? _swipePageOffset;

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

  /// 为横滑预载指定管理分区的真实业务页面。
  Widget _buildSectionPage(ManagementSection section) {
    return switch (section) {
      ManagementSection.events => const EventsPage(embeddedInManagement: true),
      ManagementSection.memberships => const MembershipsPage(
        embeddedInManagement: true,
      ),
      ManagementSection.inventory => const InventoryPage(
        embeddedInManagement: true,
      ),
    };
  }

  /// 同步管理内容横滑进度到固定顶部导航。
  void _updateSwipePageOffset(double? offset) {
    if (_swipePageOffset == offset || !mounted) {
      return;
    }
    setState(() => _swipePageOffset = offset);
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
    // 当前管理分区在可见顺序中的位置。
    final int currentIndex = sections.indexOf(effectiveSection);
    // 当前分区前一页。
    final ManagementSection? previousSection = currentIndex > 0
        ? sections[currentIndex - 1]
        : null;
    // 当前分区后一页。
    final ManagementSection? nextSection =
        currentIndex >= 0 && currentIndex + 1 < sections.length
        ? sections[currentIndex + 1]
        : null;
    return Column(
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
                indicatorIndex: _swipePageOffset == null
                    ? null
                    : currentIndex + _swipePageOffset!,
                width: constraints.maxWidth,
                height: OmniSize.touch,
                labelBuilder: (ManagementSection section) => section.label,
                itemKeyBuilder: (ManagementSection section) =>
                    ValueKey<String>('management-section-${section.name}'),
                onChanged: (ManagementSection section) {
                  ref.read(managementSectionProvider.notifier).select(section);
                  context.go(section.route);
                },
              );
            },
          ),
        ),
        Expanded(
          child: NestedPageSwipeSurface(
            surfaceKey: const ValueKey<String>(
              'android-management-swipe-surface',
            ),
            previousChild: previousSection == null
                ? null
                : _buildSectionPage(previousSection),
            nextChild: nextSection == null
                ? null
                : _buildSectionPage(nextSection),
            onPageChanged: _moveToAdjacentSection,
            onPageOffsetChanged: _updateSwipePageOffset,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
