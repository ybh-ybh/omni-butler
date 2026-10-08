import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/events/presentation/events_page.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_page.dart';
import 'package:omni_butler/features/management/presentation/management_mobile_scaffold.dart';
import 'package:omni_butler/features/management/presentation/management_navigation.dart';
import 'package:omni_butler/features/memberships/presentation/memberships_page.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
export 'package:omni_butler/features/management/presentation/management_navigation.dart';

/// Android 紧凑管理的下划线导航及保活分页。
class AndroidManagementShell extends ConsumerStatefulWidget {
  /// 当前路由目标。
  final ManagementSection selectedSection;

  /// 保持原路由构造接口，业务页按稳定分区身份构建。
  final Widget child;

  /// 创建管理宿主。
  const AndroidManagementShell({
    required this.selectedSection,
    required this.child,
    super.key,
  });

  /// 创建分页与路由协调状态。
  @override
  ConsumerState<AndroidManagementShell> createState() =>
      _AndroidManagementShellState();
}

/// 分区切换不销毁搜索、筛选、列表和业务展开状态。
class _AndroidManagementShellState
    extends ConsumerState<AndroidManagementShell> {
  /// 独立分页，首尾不接力一级导航。
  late final PageController _pages;

  /// 当前稳定选中的业务身份。
  late ManagementSection _selected;

  /// 上次可见分区顺序。
  List<ManagementSection> _sections = <ManagementSection>[];

  /// 等待布局后对齐的索引。
  int? _pendingIndex;

  /// 合并同一帧中的重复对齐请求。
  bool _alignmentScheduled = false;

  /// 统计展开时暂停横滑。
  bool _expanded = false;

  /// 主动关闭旧统计的代次。
  int _collapseEpoch = 0;

  /// 当前顶层路由。
  GoRouter? _router;

  /// 主路由是否位于管理。
  bool _routeActive = true;

  /// 以实际进入路由确定首次分区。
  @override
  void initState() {
    super.initState();
    _sections = enabledManagementSections(ref.read(featurePreferenceProvider));
    _selected =
        resolveManagementSection(
          ref.read(featurePreferenceProvider),
          widget.selectedSection,
        ) ??
        widget.selectedSection;
    _pages = PageController(
      initialPage: math.max(0, _sections.indexOf(_selected)),
    );
    _remember();
  }

  /// 监听顶层路由，即使保活页未销毁也关闭统计。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 当前路由实例。
    final GoRouter? router = GoRouter.maybeOf(context);
    if (_router == router) return;
    _router?.routeInformationProvider.removeListener(_routeChanged);
    _router = router;
    _router?.routeInformationProvider.addListener(_routeChanged);
    _routeActive = _isManagementRoute;
  }

  /// 判断主路由是否仍在管理三分区。
  bool get _isManagementRoute {
    // 当前顶层地址。
    final String? path = _router?.routeInformationProvider.value.uri.path;
    return path == null ||
        ManagementSection.values.any(
          (ManagementSection section) => section.route == path,
        );
  }

  /// 一级导航离开时关闭统计，返回仅恢复列表状态。
  void _routeChanged() {
    // 最新一级可见性。
    final bool active = _isManagementRoute;
    if (!mounted || active == _routeActive) return;
    setState(() {
      _routeActive = active;
      _expanded = false;
      _collapseEpoch++;
    });
    if (!active && _pages.hasClients && _pages.position.hasPixels) {
      _pages.jumpTo(_pages.offset);
    }
    _alignAfterLayout();
  }

  /// 外部直达路由同步分页，内部横滑已同步时不重复跳转。
  @override
  void didUpdateWidget(covariant AndroidManagementShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedSection != widget.selectedSection &&
        _selected != widget.selectedSection) {
      _selected = widget.selectedSection;
      _expanded = false;
      _collapseEpoch++;
      _alignAfterLayout();
      _remember();
    }
  }

  /// 帧后记忆分区，避免构建中更新 Provider。
  void _remember() {
    // 本帧稳定身份。
    final ManagementSection section = _selected;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _selected == section) {
        ref.read(managementSectionProvider.notifier).select(section);
      }
    });
  }

  /// 重排和外部路由更新后对齐真实视口。
  void _alignAfterLayout() {
    _pendingIndex = math.max(0, _sections.indexOf(_selected));
    _scheduleAlignment();
  }

  /// 零宽隐藏视口保留请求，在恢复布局后继续对齐。
  void _scheduleAlignment() {
    if (_alignmentScheduled) return;
    _alignmentScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _alignmentScheduled = false;
      if (!mounted ||
          _pendingIndex == null ||
          !_pages.hasClients ||
          !_pages.position.hasViewportDimension ||
          _pages.position.viewportDimension <= 0) {
        return;
      }
      _pages.jumpToPage(_pendingIndex!);
      setState(() => _pendingIndex = null);
    });
  }

  /// 标签点击先收起统计，再移动目标页面。
  void _select(int index) {
    if (!_pages.hasClients || index < 0 || index >= _sections.length) return;
    setState(() {
      _expanded = false;
      _collapseEpoch++;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    if (OmniMotion.reduce(context)) {
      _pages.jumpToPage(index);
    } else {
      unawaited(
        _pages.animateToPage(
          index,
          duration: OmniMotion.panel,
          curve: OmniMotion.standardCurve,
        ),
      );
    }
  }

  /// 中点变更同步原路由并保留唯一页面身份。
  void _pageChanged(int index) {
    if (_pendingIndex != null || index < 0 || index >= _sections.length) return;
    // 新的绝对分区身份。
    final ManagementSection section = _sections[index];
    if (_selected == section) return;
    setState(() {
      _selected = section;
      _expanded = false;
      _collapseEpoch++;
    });
    ref.read(managementSectionProvider.notifier).select(section);
    if (_routeActive &&
        _router?.routeInformationProvider.value.uri.path != section.route) {
      _router?.go(section.route);
    }
  }

  /// 只有可见业务页可锁定横滑。
  void _expansionChanged(ManagementSection section, bool expanded) {
    if (!mounted ||
        section != _selected ||
        !_routeActive ||
        _expanded == expanded) {
      return;
    }
    setState(() => _expanded = expanded);
  }

  /// 消费非分页区域横滑，避免接力一级导航。
  void _consumeHorizontal(DragStartDetails details) {}

  /// 根据稳定分区构建真实业务页。
  Widget _buildSection(ManagementSection section) => switch (section) {
    ManagementSection.events => const EventsPage(embeddedInManagement: true),
    ManagementSection.memberships => const MembershipsPage(
      embeddedInManagement: true,
    ),
    ManagementSection.inventory => const InventoryPage(
      embeddedInManagement: true,
    ),
  };

  /// 释放路由监听和分页控制器。
  @override
  void dispose() {
    _router?.routeInformationProvider.removeListener(_routeChanged);
    _pages.dispose();
    super.dispose();
  }

  /// 构建连续实底和固定文字导航。
  @override
  Widget build(BuildContext context) {
    // 一级分支恢复后重试隐藏期间尚未完成的分页对齐。
    final bool ticking = TickerMode.valuesOf(context).enabled;
    if (_pendingIndex != null && ticking) _scheduleAlignment();
    // 当前可用分区顺序。
    final List<ManagementSection> sections = enabledManagementSections(
      ref.watch(featurePreferenceProvider),
    );
    if (!listEquals(_sections, sections)) {
      _sections = sections;
      if (!sections.contains(_selected) && sections.isNotEmpty) {
        _selected = sections.first;
      }
      _expanded = false;
      _collapseEpoch++;
      _alignAfterLayout();
      _remember();
    }
    if (sections.isEmpty) return const SizedBox.shrink();
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 标签高度随系统字号增长。
    final double tabHeight = math.max(
      OmniSize.touch,
      MediaQuery.textScalerOf(context).scale(16) * 1.4 + OmniSpacing.md,
    );
    return GestureDetector(
      // 此层只拦截横滑，读屏翻页交由内部真实分页控件提供。
      excludeFromSemantics: true,
      onHorizontalDragStart: _consumeHorizontal,
      child: ColoredBox(
        color: colors.paper,
        child: Column(
          key: const ValueKey<String>('android-management-shell'),
          children: <Widget>[
            if (sections.length > 1)
              SizedBox(
                height: tabHeight,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // 每项平分视口宽度。
                    final double width = constraints.maxWidth / sections.length;
                    return AnimatedBuilder(
                      animation: _pages,
                      builder: (BuildContext context, Widget? child) {
                        // 下划线跟随连续页码。
                        final double index =
                            (_pendingIndex?.toDouble() ??
                                    (_pages.hasClients &&
                                            _pages.position.hasContentDimensions
                                        ? _pages.page
                                        : null) ??
                                    sections.indexOf(_selected).toDouble())
                                .clamp(0, sections.length - 1);
                        return Material(
                          color: colors.paper,
                          child: Stack(
                            fit: StackFit.expand,
                            key: const ValueKey<String>(
                              'management-section-control',
                            ),
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  for (
                                    int position = 0;
                                    position < sections.length;
                                    position++
                                  )
                                    Expanded(
                                      child: Semantics(
                                        button: true,
                                        selected:
                                            sections[position] == _selected,
                                        child: InkWell(
                                          key: ValueKey<String>(
                                            'management-section-${sections[position].name}',
                                          ),
                                          onTap: () => _select(position),
                                          child: Center(
                                            child: Text(
                                              switch (sections[position]) {
                                                ManagementSection.events =>
                                                  '事件',
                                                ManagementSection.memberships =>
                                                  '会员',
                                                ManagementSection.inventory =>
                                                  '物品',
                                              },
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleSmall
                                                  ?.copyWith(
                                                    color:
                                                        sections[position] ==
                                                            _selected
                                                        ? colors.brand
                                                        : colors.muted,
                                                    fontWeight:
                                                        sections[position] ==
                                                            _selected
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Divider(height: 1, color: colors.line),
                              ),
                              Positioned(
                                left:
                                    width * (index + 0.5) - OmniSpacing.xl / 2,
                                bottom: 0,
                                width: OmniSpacing.xl,
                                height: 2,
                                child: ColoredBox(
                                  key: const ValueKey<String>(
                                    'management-section-indicator',
                                  ),
                                  color: colors.brand,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            Expanded(
              child: PageView.builder(
                key: const ValueKey<String>('android-management-swipe-surface'),
                controller: _pages,
                itemCount: sections.length,
                physics: _expanded
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                onPageChanged: _pageChanged,
                findChildIndexCallback: (Key key) =>
                    key is ValueKey<ManagementSection> &&
                        sections.contains(key.value)
                    ? sections.indexOf(key.value)
                    : null,
                itemBuilder: (BuildContext context, int index) {
                  // 当前子树的稳定分区。
                  final ManagementSection section = sections[index];
                  return _ManagementKeepAlive(
                    key: ValueKey<ManagementSection>(section),
                    child: ManagementMobileScope(
                      active: _routeActive && _selected == section,
                      collapseEpoch: _collapseEpoch,
                      onExpansionChanged: (bool value) =>
                          _expansionChanged(section, value),
                      child: _buildSection(section),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 已访问分区持续保活。
class _ManagementKeepAlive extends StatefulWidget {
  /// 对应的业务内容。
  final Widget child;

  /// 创建稳定分区。
  const _ManagementKeepAlive({required this.child, super.key});

  /// 创建保活状态。
  @override
  State<_ManagementKeepAlive> createState() => _ManagementKeepAliveState();
}

/// 搜索和滚动不因分区切换丢失。
class _ManagementKeepAliveState extends State<_ManagementKeepAlive>
    with AutomaticKeepAliveClientMixin {
  /// 保留访问过的页面。
  @override
  bool get wantKeepAlive => true;

  /// 返回同一业务子树。
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
