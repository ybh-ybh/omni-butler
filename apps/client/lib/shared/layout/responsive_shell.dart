import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/app_chrome_colors.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/management/presentation/android_management_shell.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
import 'package:omni_butler/shared/layout/primary_navigation_swipe.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/notes/presentation/note_search_focus.dart';
import 'package:omni_butler/shared/search/global_search_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:powersync/powersync.dart' show SyncStatus;

/// 应用导航目的地。
class _AppDestination {
  /// 路由路径。
  final String path;

  /// 导航名称。
  final String label;

  /// 导航图标。
  final IconData icon;

  /// 选中态图标。
  final IconData selectedIcon;

  /// 任一开启即显示入口的业务功能集合。
  final List<AppFeature> features;

  /// 可以命中该入口选中态的额外路由。
  final List<String> selectionPaths;

  /// 是否为管理聚合入口。
  final bool managementGroup;

  /// 对应的一级有状态导航分支。
  final PrimaryNavigationDestination? primaryDestination;

  /// 创建应用导航目的地。
  const _AppDestination({
    required this.path,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.features = const <AppFeature>[],
    this.selectionPaths = const <String>[],
    this.managementGroup = false,
    this.primaryDestination,
  });
}

/// 桌面端全部导航目的地。
const List<_AppDestination> _desktopDestinations = <_AppDestination>[
  _AppDestination(
    path: '/home',
    label: '首页',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
  ),
  _AppDestination(
    path: '/todos',
    label: '待办',
    icon: Icons.check_box_outlined,
    selectedIcon: Icons.check_box_rounded,
    features: <AppFeature>[AppFeature.todos],
  ),
  _AppDestination(
    path: '/timeline',
    label: '时间',
    icon: Icons.access_time_outlined,
    selectedIcon: Icons.access_time_filled,
    features: <AppFeature>[AppFeature.timeline],
  ),
  _AppDestination(
    path: '/notes',
    label: '笔记',
    icon: Icons.edit_note_outlined,
    selectedIcon: Icons.edit_note_rounded,
    features: <AppFeature>[AppFeature.notes],
    primaryDestination: PrimaryNavigationDestination.notes,
  ),
  _AppDestination(
    path: '/assistant',
    label: '助手',
    icon: Icons.auto_awesome_outlined,
    selectedIcon: Icons.auto_awesome,
  ),
  _AppDestination(
    path: '/inventory',
    label: '管理',
    icon: Icons.dashboard_customize_outlined,
    selectedIcon: Icons.dashboard_customize_rounded,
    features: <AppFeature>[
      AppFeature.events,
      AppFeature.inventory,
      AppFeature.memberships,
    ],
    selectionPaths: <String>['/events', '/inventory', '/memberships'],
    managementGroup: true,
  ),
];

/// 侧栏底部设置入口。
const _AppDestination _settingsDestination = _AppDestination(
  path: '/settings',
  label: '设置',
  icon: Icons.settings_outlined,
  selectedIcon: Icons.settings_rounded,
);

/// 紧凑布局导航目的地。
const List<_AppDestination> _compactDestinations = <_AppDestination>[
  _AppDestination(
    path: '/home',
    label: '首页',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
  ),
  _AppDestination(
    path: '/todos',
    label: '待办',
    icon: Icons.check_box_outlined,
    selectedIcon: Icons.check_box_rounded,
    features: <AppFeature>[AppFeature.todos],
  ),
  _AppDestination(
    path: '/timeline',
    label: '时间',
    icon: Icons.access_time_outlined,
    selectedIcon: Icons.access_time_filled,
    features: <AppFeature>[AppFeature.timeline],
  ),
  _AppDestination(
    path: '/notes',
    label: '笔记',
    icon: Icons.edit_note_outlined,
    selectedIcon: Icons.edit_note_rounded,
    features: <AppFeature>[AppFeature.notes],
    primaryDestination: PrimaryNavigationDestination.notes,
  ),
  _AppDestination(
    path: '/inventory',
    label: '物品',
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2_rounded,
    features: <AppFeature>[AppFeature.inventory],
  ),
  _AppDestination(
    path: '/settings',
    label: '更多',
    icon: Icons.apps_outlined,
    selectedIcon: Icons.apps_rounded,
  ),
];

/// Android 紧凑布局的五个底部导航目的地。
const List<_AppDestination> _androidCompactDestinations = <_AppDestination>[
  _AppDestination(
    path: '/home',
    label: '首页',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
    primaryDestination: PrimaryNavigationDestination.home,
  ),
  _AppDestination(
    path: '/todos',
    label: '待办',
    icon: Icons.check_box_outlined,
    selectedIcon: Icons.check_box_rounded,
    features: <AppFeature>[AppFeature.todos],
    primaryDestination: PrimaryNavigationDestination.todos,
  ),
  _AppDestination(
    path: '/timeline',
    label: '时间',
    icon: Icons.access_time_outlined,
    selectedIcon: Icons.access_time_filled,
    features: <AppFeature>[AppFeature.timeline],
    primaryDestination: PrimaryNavigationDestination.timeline,
  ),
  _AppDestination(
    path: '/notes',
    label: '笔记',
    icon: Icons.edit_note_outlined,
    selectedIcon: Icons.edit_note_rounded,
    features: <AppFeature>[AppFeature.notes],
    primaryDestination: PrimaryNavigationDestination.notes,
  ),
  _AppDestination(
    path: '/inventory',
    label: '管理',
    icon: Icons.dashboard_customize_outlined,
    selectedIcon: Icons.dashboard_customize_rounded,
    features: <AppFeature>[
      AppFeature.inventory,
      AppFeature.events,
      AppFeature.memberships,
    ],
    selectionPaths: <String>['/inventory', '/events', '/memberships'],
    managementGroup: true,
    primaryDestination: PrimaryNavigationDestination.management,
  ),
  _AppDestination(
    path: '/settings',
    label: '设置',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
    primaryDestination: PrimaryNavigationDestination.more,
  ),
];

/// 新增待办快捷键意图。
class _CreateTodoIntent extends Intent {
  /// 创建新增待办意图。
  const _CreateTodoIntent();
}

/// 搜索快捷键意图。
class _SearchIntent extends Intent {
  /// 创建搜索意图。
  const _SearchIntent();
}

/// 响应式应用壳层。
class ResponsiveShell extends ConsumerWidget {
  /// 当前路由路径。
  final String location;

  /// 当前页面或五分支有状态导航壳层内容。
  final Widget child;

  /// 当前五分支有状态导航壳层；独立布局测试可以不提供。
  final StatefulNavigationShell? navigationShell;

  /// 与有状态分支容器共享的一级导航协调器；静态布局可以不提供。
  final PrimaryNavigationCoordinator? primaryNavigationCoordinator;

  /// 创建响应式应用壳层。
  const ResponsiveShell({
    required this.location,
    required this.child,
    this.navigationShell,
    this.primaryNavigationCoordinator,
    super.key,
  });

  /// 构建三档响应式导航布局。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前设备功能偏好。
    final FeaturePreference featurePreference = ref.watch(
      featurePreferenceProvider,
    );
    // 当前管理页记住的分区。
    final ManagementSection managementSection = ref.watch(
      managementSectionProvider,
    );
    // 当前是否运行在 Android 平台。
    final bool androidPlatform =
        Theme.of(context).platform == TargetPlatform.android;
    // 当前可见的桌面导航项。
    final List<_AppDestination> desktopDestinations = _desktopDestinations
        .where(
          (_AppDestination destination) =>
              destination.features.isEmpty ||
              destination.features.any(featurePreference.isEnabled),
        )
        .toList(growable: false);
    // 当前平台应使用的紧凑导航源列表。
    final List<_AppDestination> compactSource = androidPlatform
        ? _androidCompactDestinations
        : _compactDestinations;
    // 当前可见的紧凑导航项。
    final List<_AppDestination> compactDestinations = compactSource
        .where(
          (_AppDestination destination) =>
              destination.features.isEmpty ||
              destination.features.any(featurePreference.isEnabled),
        )
        .toList(growable: false);

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyN): _CreateTodoIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _SearchIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CreateTodoIntent: CallbackAction<_CreateTodoIntent>(
            onInvoke: (_CreateTodoIntent intent) {
              if (featurePreference.isEnabled(AppFeature.todos)) {
                TodoEditorDialog.show(context);
              }
              return null;
            },
          ),
          _SearchIntent: CallbackAction<_SearchIntent>(
            onInvoke: (_SearchIntent intent) {
              if (Theme.of(context).platform == TargetPlatform.windows &&
                  location == '/notes') {
                ref.read(noteSearchFocusProvider).requestFocus();
              } else {
                _showSearch(context);
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 当前是否为紧凑布局。
              final bool isCompact = OmniBreakpoint.isCompact(
                constraints.maxWidth,
              );
              // 当前是否运行在桌面端。
              final bool isDesktopPlatform = OmniBreakpoint.isDesktopPlatform(
                Theme.of(context).platform,
              );
              // Windows 始终使用图标轨，不随页面或窗口宽度展开。
              final bool windowsPlatform =
                  Theme.of(context).platform == TargetPlatform.windows;
              // 安卓笔记的根覆盖层自行避让键盘，底层导航保持原尺寸。
              final bool androidNotes =
                  Theme.of(context).platform == TargetPlatform.android &&
                  location == '/notes';
              // Windows仅首页显示全局顶栏，其余页面不保留顶栏占位。
              final bool showTopBar = windowsPlatform
                  ? location == '/home'
                  : !androidNotes;
              // 当前是否为展开布局。
              final bool isExpanded = OmniBreakpoint.isExpanded(
                constraints.maxWidth,
              );

              if (isCompact && !isDesktopPlatform) {
                return Scaffold(
                  resizeToAvoidBottomInset: !androidNotes,
                  backgroundColor: colors.canvas,
                  body: SafeArea(child: child),
                  bottomNavigationBar: _CompactNavigation(
                    location: location,
                    destinations: compactDestinations,
                    onSelected: (_AppDestination destination) =>
                        _selectDestination(
                          context,
                          ref,
                          destination,
                          featurePreference,
                          managementSection,
                          navigationShell,
                        ),
                  ),
                );
              }

              return Scaffold(
                resizeToAvoidBottomInset: !androidNotes,
                backgroundColor: colors.canvas,
                body: Row(
                  children: <Widget>[
                    if (isExpanded && !windowsPlatform)
                      _ExpandedSidebar(
                        location: location,
                        destinations: desktopDestinations,
                        onSelected: (_AppDestination destination) =>
                            _selectDestination(
                              context,
                              ref,
                              destination,
                              featurePreference,
                              managementSection,
                              navigationShell,
                            ),
                      )
                    else
                      _MediumNavigation(
                        location: location,
                        destinations: desktopDestinations,
                        onSelected: (_AppDestination destination) =>
                            _selectDestination(
                              context,
                              ref,
                              destination,
                              featurePreference,
                              managementSection,
                              navigationShell,
                            ),
                      ),
                    Expanded(
                      child: Column(
                        children: <Widget>[
                          if (showTopBar) const _TopBar(),
                          Expanded(child: child),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 显示全局搜索。
  void _showSearch(BuildContext context) {
    GlobalSearchDialog.show(context);
  }

  /// 打开普通导航路由或记住的可用管理分区。
  void _selectDestination(
    BuildContext context,
    WidgetRef ref,
    _AppDestination destination,
    FeaturePreference preference,
    ManagementSection preferredSection,
    StatefulNavigationShell? navigationShell,
  ) {
    if (destination.path == '/notes') {
      // 主动导航清除旧搜索定位；安卓保留原草稿，其他平台维持原进入行为。
      if (location == '/notes' &&
          Theme.of(context).platform != TargetPlatform.android) {
        ref.read(noteEditorProvider).enter();
      }
      context.go('/notes');
      return;
    }
    // 当前导航项对应的一级分支。
    final PrimaryNavigationDestination? primaryDestination =
        destination.primaryDestination;
    if (primaryNavigationCoordinator?.isAttached == true &&
        primaryDestination != null) {
      primaryNavigationCoordinator?.navigateTo(primaryDestination);
      return;
    }
    if (!destination.managementGroup) {
      if (primaryDestination == null) {
        context.go(destination.path);
        return;
      }
      if (navigationShell == null) {
        context.go(destination.path);
        return;
      }
      navigationShell.goBranch(primaryDestination.index);
      return;
    }
    // 根据功能开关解析后的实际管理分区。
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
}

/// 展开桌面侧栏。
class _ExpandedSidebar extends ConsumerWidget {
  /// 当前路由路径。
  final String location;

  /// 当前可见的业务导航项。
  final List<_AppDestination> destinations;

  /// 选择回调。
  final ValueChanged<_AppDestination> onSelected;

  /// 创建展开桌面侧栏。
  const _ExpandedSidebar({
    required this.location,
    required this.destinations,
    required this.onSelected,
  });

  /// 构建带品牌标识的侧栏。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 侧栏与原生标题栏共用背景和边界色。
    final OmniChromeColors chrome = OmniChromeColors.of(context);
    // 当前侧栏需要展示的同步阶段。
    final _SidebarSyncPhase? syncPhase = _sidebarSyncPhase(ref);

    return Container(
      key: const ValueKey<String>('expanded-sidebar'),
      width: OmniSize.sidebar,
      decoration: BoxDecoration(
        color: chrome.background,
        border: Border(right: BorderSide(color: chrome.border)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _BrandMark(),
              const SizedBox(height: 28),
              for (final _AppDestination destination in destinations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _SidebarDestination(
                    destination: destination,
                    selected: _isDestinationSelected(destination, location),
                    onTap: () => onSelected(destination),
                  ),
                ),
              const Spacer(),
              if (syncPhase != null) ...<Widget>[
                _SyncStatusCard(colors: colors, phase: syncPhase),
                const SizedBox(height: 4),
              ],
              _SidebarDestination(
                destination: _settingsDestination,
                selected: _isSelected(_settingsDestination.path, location),
                onTap: () => onSelected(_settingsDestination),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Windows 常驻图标轨，其他平台在中等宽度使用。
class _MediumNavigation extends ConsumerWidget {
  /// 当前路由路径。
  final String location;

  /// 当前可见的业务导航项。
  final List<_AppDestination> destinations;

  /// 选择回调。
  final ValueChanged<_AppDestination> onSelected;

  /// 创建折叠导航轨。
  const _MediumNavigation({
    required this.location,
    required this.destinations,
    required this.onSelected,
  });

  /// 构建飞书式紧凑导航轨。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 与 Windows 标题栏共用的导航配色。
    final OmniChromeColors chrome = OmniChromeColors.of(context);
    // 只调整Windows导航提示，其他平台沿用现有样式。
    final bool isWindows = Theme.of(context).platform == TargetPlatform.windows;
    // Windows 图标轨保留实时同步状态，其他平台沿用既有展示范围。
    final _SidebarSyncPhase? syncPhase = isWindows
        ? _sidebarSyncPhase(ref)
        : null;

    // 导航布局与提示样式分开，避免放大点击热区或影响页面内提示。
    final Widget navigation = Container(
      key: const ValueKey<String>('medium-navigation'),
      width: OmniSize.navigationRail,
      decoration: BoxDecoration(
        color: chrome.background,
        border: Border(right: BorderSide(color: chrome.border)),
      ),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            const SizedBox(height: OmniSpacing.sm),
            const _CompactBrandMark(),
            const SizedBox(height: OmniSpacing.lg),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey<String>('rail-navigation-scroll'),
                primary: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final _AppDestination destination in destinations)
                      Padding(
                        padding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
                        child: _RailDestination(
                          destination: destination,
                          selected: _isDestinationSelected(
                            destination,
                            location,
                          ),
                          onTap: () => onSelected(destination),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (syncPhase != null)
              Padding(
                padding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
                child: _SyncStatusCard(
                  colors: OmniColors.of(context),
                  phase: syncPhase,
                  iconOnly: true,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
              child: _RailDestination(
                destination: _settingsDestination,
                selected: _isSelected(_settingsDestination.path, location),
                onTap: () => onSelected(_settingsDestination),
              ),
            ),
          ],
        ),
      ),
    );
    if (!isWindows) return navigation;
    return TooltipTheme(
      data: TooltipTheme.of(context).copyWith(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        textStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
          color: OmniColors.of(context).canvas,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.5,
        ),
        decoration: BoxDecoration(
          color: OmniColors.of(context).ink,
          borderRadius: BorderRadius.circular(OmniRadius.control),
        ),
      ),
      child: navigation,
    );
  }
}

/// 将Windows导航墨迹限制在图标周围，保留完整的点击热区。
class _RailInkShape extends RoundedRectangleBorder {
  /// 与其他桌面图标按钮使用相同的圆角。
  const _RailInkShape()
    : super(
        borderRadius: const BorderRadius.all(
          Radius.circular(OmniRadius.control),
        ),
      );

  /// 仅缩小墨迹的绘制轮廓，不参与布局或命中测试。
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    // 悬停墨迹与选中背景共享32dp尺寸，小热区不向外扩张。
    final double extent = math.min(OmniSize.control, rect.shortestSide);
    return super.getOuterPath(
      Rect.fromCenter(center: rect.center, width: extent, height: extent),
      textDirection: textDirection,
    );
  }
}

/// 紧凑导航轨单项。
class _RailDestination extends StatelessWidget {
  /// 导航目的地。
  final _AppDestination destination;

  /// 是否选中。
  final bool selected;

  /// 点击回调。
  final VoidCallback onTap;

  /// 创建紧凑导航轨单项。
  const _RailDestination({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  /// 构建仅含图标和选中反馈的导航项。
  @override
  Widget build(BuildContext context) {
    // 导航色独立于业务面板，确保深色主题底上的图标可读。
    final OmniChromeColors chrome = OmniChromeColors.of(context);
    return Tooltip(
      message: destination.label,
      positionDelegate: Theme.of(context).platform == TargetPlatform.windows
          ? _rightNavigationTooltip
          : null,
      constraints: Theme.of(context).platform == TargetPlatform.windows
          ? _navigationTooltipConstraints(context)
          : null,
      child: Material(
        key: ValueKey<String>('navigation-${destination.path}'),
        color: Colors.transparent,
        child: OmniPressBinding(
          builder: (BuildContext context, OmniPressFeedback feedback) =>
              InkWell(
                statesController: feedback.statesController,
                onTap: () {
                  feedback.activate();
                  onTap();
                },
                borderRadius: BorderRadius.circular(OmniRadius.control),
                customBorder:
                    Theme.of(context).platform == TargetPlatform.windows
                    ? const _RailInkShape()
                    : null,
                child: SizedBox(
                  width: 56,
                  height: 48,
                  child: Center(
                    child: Container(
                      width: OmniSize.control,
                      height: OmniSize.control,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? chrome.selectedBackground
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(OmniRadius.control),
                      ),
                      child: OmniPressContent(
                        controller: feedback,
                        child: Icon(
                          selected
                              ? destination.selectedIcon
                              : destination.icon,
                          size: OmniSize.navigationIcon,
                          color: selected
                              ? chrome.selectedForeground
                              : chrome.muted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        ),
      ),
    );
  }
}

/// 紧凑底部导航。
class _CompactNavigation extends StatelessWidget {
  /// 当前路由路径。
  final String location;

  /// 当前可见的业务导航项。
  final List<_AppDestination> destinations;

  /// 选择回调。
  final ValueChanged<_AppDestination> onSelected;

  /// 创建紧凑底部导航。
  const _CompactNavigation({
    required this.location,
    required this.destinations,
    required this.onSelected,
  });

  /// 构建飞书式五入口底部导航。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return SafeArea(
      top: false,
      child: Container(
        key: const ValueKey<String>('compact-navigation'),
        height: 60,
        decoration: BoxDecoration(
          color: colors.paper,
          border: Border(top: BorderSide(color: colors.line)),
        ),
        child: Row(
          children: <Widget>[
            for (final _AppDestination destination in destinations)
              Expanded(
                child: _CompactDestination(
                  destination: destination,
                  selected: _isDestinationSelected(destination, location),
                  onTap: () => onSelected(destination),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 移动端底栏单项。
class _CompactDestination extends StatelessWidget {
  /// 导航目的地。
  final _AppDestination destination;

  /// 是否选中。
  final bool selected;

  /// 点击回调。
  final VoidCallback onTap;

  /// 创建移动端底栏单项。
  const _CompactDestination({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  /// 构建移动端图标与文字。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Material(
      key: ValueKey<String>('navigation-${destination.path}'),
      color: Colors.transparent,
      child: OmniInkWell(
        onTap: onTap,
        child: Semantics(
          selected: selected,
          label: destination.label,
          button: true,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                size: OmniSize.navigationIcon,
                color: selected ? colors.brand : colors.muted,
              ),
              const SizedBox(height: OmniSpacing.xxs),
              Text(
                destination.label,
                style: TextStyle(
                  color: selected ? colors.brand : colors.muted,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面页面顶栏。
class _TopBar extends ConsumerWidget {
  /// 创建桌面页面顶栏。
  const _TopBar();

  /// 构建全局搜索和外观模式入口。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前主题偏好。
    final ThemePreference preference = ref.watch(themeControllerProvider);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 当前是否展示搜索入口。
        final bool showSearch = constraints.maxWidth >= 300;
        return Container(
          height: OmniSize.topBar,
          padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
          decoration: BoxDecoration(
            color: colors.paper,
            border: Border(
              bottom: BorderSide(color: colors.line.withValues(alpha: 0.72)),
            ),
          ),
          child: Row(
            children: <Widget>[
              if (showSearch)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: _SearchTrigger(
                        onTap: () =>
                            Actions.invoke(context, const _SearchIntent()),
                      ),
                    ),
                  ),
                )
              else
                const Spacer(),
              OmniPopupMenuButton<ThemeMode>(
                tooltip: '外观模式',
                onSelected: (ThemeMode mode) {
                  ref.read(themeControllerProvider.notifier).setThemeMode(mode);
                },
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<ThemeMode>>[
                      OmniPopupMenuItem<ThemeMode>(
                        value: ThemeMode.system,
                        label: '跟随系统',
                        icon: Icons.brightness_auto_outlined,
                      ),
                      OmniPopupMenuItem<ThemeMode>(
                        value: ThemeMode.light,
                        label: '浅色',
                        icon: Icons.light_mode_outlined,
                      ),
                      OmniPopupMenuItem<ThemeMode>(
                        value: ThemeMode.dark,
                        label: '深色',
                        icon: Icons.dark_mode_outlined,
                      ),
                    ],
                icon: Icon(_themeIcon(preference.mode)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 顶栏全局搜索触发器。
class _SearchTrigger extends StatelessWidget {
  /// 点击回调。
  final VoidCallback onTap;

  /// 创建全局搜索触发器。
  const _SearchTrigger({required this.onTap});

  /// 构建带快捷键提示的搜索入口。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Material(
      color: colors.paperSubtle,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadius.control),
        side: BorderSide(color: colors.line),
      ),
      child: OmniInkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(OmniRadius.control),
        child: SizedBox(
          height: OmniSize.control,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.search_rounded,
                  size: OmniSize.icon,
                  color: colors.muted,
                ),
                const SizedBox(width: OmniSpacing.xs),
                Expanded(
                  child: Text(
                    '搜索待办、事件、物品和会员',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: colors.paper,
                    borderRadius: BorderRadius.circular(OmniRadius.tiny),
                    border: Border.all(color: colors.line),
                  ),
                  child: Text(
                    'Ctrl+F',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 品牌标识。
class _BrandMark extends StatelessWidget {
  /// 创建品牌标识。
  const _BrandMark();

  /// 构建品牌标识。
  @override
  Widget build(BuildContext context) {
    // 品牌文字使用导航前景色，兼容浅色页面中的深色侧栏。
    final OmniChromeColors chrome = OmniChromeColors.of(context);
    return Row(
      children: <Widget>[
        const _CompactBrandMark(),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Omni Butler',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: chrome.foreground),
              ),
              Text(
                '知序',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: chrome.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 紧凑品牌图形。
class _CompactBrandMark extends StatelessWidget {
  /// 创建紧凑品牌图形。
  const _CompactBrandMark();

  /// 显示由正式 SVG 导出的克莱因蓝小管家，保持各导航宽度的品牌一致。
  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icon/app_icon.png',
      width: 32,
      height: 32,
      filterQuality: FilterQuality.medium,
      semanticLabel: '知序应用图标',
    );
  }
}

/// 侧栏单个导航项。
class _SidebarDestination extends StatelessWidget {
  /// 导航目的地。
  final _AppDestination destination;

  /// 是否选中。
  final bool selected;

  /// 点击回调。
  final VoidCallback onTap;

  /// 创建侧栏导航项。
  const _SidebarDestination({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  /// 构建侧栏导航项。
  @override
  Widget build(BuildContext context) {
    // 根据导航实际背景选择前景及选中态，避免只按页面明暗取色。
    final OmniChromeColors chrome = OmniChromeColors.of(context);

    return Material(
      key: ValueKey<String>('navigation-${destination.path}'),
      color: selected ? chrome.selectedBackground : Colors.transparent,
      borderRadius: BorderRadius.circular(OmniRadius.control),
      child: OmniInkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(OmniRadius.control),
        child: SizedBox(
          height: 40,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 12),
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                size: OmniSize.navigationIcon,
                color: selected ? chrome.selectedForeground : chrome.muted,
              ),
              const SizedBox(width: 12),
              Text(
                destination.label,
                style: TextStyle(
                  color: selected
                      ? chrome.selectedForeground
                      : chrome.foreground,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 侧栏共用的同步展示阶段。
enum _SidebarSyncPhase {
  /// 正在建立同步连接。
  connecting,

  /// 正在交换或等待上传数据。
  syncing,

  /// 当前数据已经同步完成。
  completed,

  /// 当前设备离线。
  offline,

  /// 同步链路出现异常。
  error,
}

/// 读取同一组同步事实，折叠与展开导航不另行判断完成状态。
_SidebarSyncPhase? _sidebarSyncPhase(WidgetRef ref) {
  if (!ref.watch(syncPreferenceProvider)) return null;
  return _resolveSidebarSyncPhase(
    sessionState: ref.watch(authControllerProvider),
    syncController: ref.watch(syncControllerProvider),
    syncStatusState: ref.watch(syncStatusProvider),
    queueCountState: ref.watch(syncUploadQueueCountProvider),
  );
}

/// 根据同步链路状态解析侧栏的展示阶段。
_SidebarSyncPhase _resolveSidebarSyncPhase({
  required AsyncValue<SyncSession?> sessionState,
  required AsyncValue<void> syncController,
  required AsyncValue<SyncStatus?> syncStatusState,
  required AsyncValue<int> queueCountState,
}) {
  // 当前已恢复的设备同步会话。
  final SyncSession? session = sessionState.value;
  // 当前 PowerSync 实时状态。
  final SyncStatus? status = syncStatusState.value;
  // 当前本机待上传操作数量。
  final int queuedOperations = queueCountState.value ?? 0;
  if (sessionState.hasError ||
      syncController.hasError ||
      syncStatusState.hasError ||
      queueCountState.hasError ||
      status?.anyError != null) {
    return _SidebarSyncPhase.error;
  }
  if (session?.isOffline == true) {
    return _SidebarSyncPhase.offline;
  }
  if (sessionState.isLoading ||
      syncController.isLoading ||
      session == null ||
      status == null ||
      status.connecting) {
    return _SidebarSyncPhase.connecting;
  }
  if (!status.connected) {
    return status.hasSynced == true
        ? _SidebarSyncPhase.offline
        : _SidebarSyncPhase.connecting;
  }
  if (status.uploading ||
      status.downloading ||
      queuedOperations > 0 ||
      status.hasSynced != true) {
    return _SidebarSyncPhase.syncing;
  }
  return _SidebarSyncPhase.completed;
}

/// 实时同步状态，Windows 只显示图标并以悬停说明详情。
class _SyncStatusCard extends StatelessWidget {
  /// 当前主题语义色。
  final OmniColors colors;

  /// 当前同步展示阶段。
  final _SidebarSyncPhase phase;

  /// 是否使用折叠图标轨的呈现。
  final bool iconOnly;

  /// 创建实时同步状态卡。
  const _SyncStatusCard({
    required this.colors,
    required this.phase,
    this.iconOnly = false,
  });

  /// 构建同步阶段图标和说明。
  @override
  Widget build(BuildContext context) {
    // 当前同步阶段标题。
    final String label = switch (phase) {
      _SidebarSyncPhase.connecting => '连接中',
      _SidebarSyncPhase.syncing => '正在同步',
      _SidebarSyncPhase.completed => '同步完成',
      _SidebarSyncPhase.offline => '离线',
      _SidebarSyncPhase.error => '同步异常',
    };
    // 当前同步阶段补充说明。
    final String description = switch (phase) {
      _SidebarSyncPhase.connecting => '正在连接同步服务器',
      _SidebarSyncPhase.syncing => '本机数据正在同步到服务器',
      _SidebarSyncPhase.completed => '本机数据已同步至服务器',
      _SidebarSyncPhase.offline => '联网后将自动继续同步',
      _SidebarSyncPhase.error => '请前往设置查看详情',
    };
    // 当前同步阶段图标。
    final IconData icon = switch (phase) {
      _SidebarSyncPhase.connecting => Icons.cloud_queue_outlined,
      _SidebarSyncPhase.syncing => Icons.cloud_sync_outlined,
      _SidebarSyncPhase.completed => Icons.cloud_done_outlined,
      _SidebarSyncPhase.offline => Icons.cloud_off_outlined,
      _SidebarSyncPhase.error => Icons.cloud_off_outlined,
    };
    // 当前同步阶段语义色。
    final Color tone = switch (phase) {
      _SidebarSyncPhase.completed => colors.success,
      _SidebarSyncPhase.offline => colors.muted,
      _SidebarSyncPhase.error => colors.danger,
      _SidebarSyncPhase.connecting || _SidebarSyncPhase.syncing => colors.brand,
    };
    if (iconOnly) {
      return Tooltip(
        message: '$label\n$description',
        positionDelegate: _rightNavigationTooltip,
        constraints: _navigationTooltipConstraints(context),
        child: SizedBox(
          key: const ValueKey<String>('sidebar-sync-status'),
          width: 56,
          height: 48,
          child: Center(child: Icon(icon, size: 18, color: tone)),
        ),
      );
    }
    return Container(
      key: const ValueKey<String>('sidebar-sync-status'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.paperSubtle,
        borderRadius: BorderRadius.circular(OmniRadius.panel),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: Theme.of(context).textTheme.labelMedium),
                Text(description, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 导航图标背景与提示之间保留的外间距。
const double _navigationTooltipGap = 5;

/// 提示按导航右侧的剩余空间换行，不挤回图标上方。
BoxConstraints _navigationTooltipConstraints(BuildContext context) =>
    BoxConstraints(
      minHeight: OmniSize.control,
      maxWidth: math.max(
        1,
        MediaQuery.sizeOf(context).width -
            OmniSize.navigationRail / 2 -
            OmniSize.control / 2 -
            _navigationTooltipGap * 2,
      ),
    );

/// 使用原生 Tooltip 的定位回调，在图标右侧垂直居中并避让窗口边缘。
Offset _rightNavigationTooltip(TooltipPositionContext context) {
  // 外间距从可见的图标背景计算，而不是更宽的点击热区。
  const double gap = _navigationTooltipGap;
  // Tooltip 坐标相对当前 Overlay，而非业务页面的局部坐标。
  final double left =
      context.target.dx +
      math.min(OmniSize.control, context.targetSize.width) / 2 +
      gap;
  // 靠近顶部或底部时夹在可用窗口范围内。
  final double top = context.target.dy - context.tooltipSize.height / 2;
  return Offset(
    left
        .clamp(
          gap,
          math.max(
            gap,
            context.overlaySize.width - context.tooltipSize.width - gap,
          ),
        )
        .toDouble(),
    top
        .clamp(
          gap,
          math.max(
            gap,
            context.overlaySize.height - context.tooltipSize.height - gap,
          ),
        )
        .toDouble(),
  );
}

/// 判断路由是否选中。
bool _isSelected(String path, String location) {
  return location == path || location.startsWith('$path/');
}

/// 判断当前路由是否命中普通入口或聚合入口。
bool _isDestinationSelected(_AppDestination destination, String location) {
  // 该导航入口的全部选中态路由。
  final List<String> paths = destination.selectionPaths.isEmpty
      ? <String>[destination.path]
      : destination.selectionPaths;
  return paths.any((String path) => _isSelected(path, location));
}

/// 返回明暗模式图标。
IconData _themeIcon(ThemeMode mode) {
  return switch (mode) {
    ThemeMode.system => Icons.brightness_auto_rounded,
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
  };
}
