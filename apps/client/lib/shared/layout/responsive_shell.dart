import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/management/presentation/android_management_shell.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/features/todos/presentation/todo_editor_dialog.dart';
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

  /// 是否为 Android 管理聚合入口。
  final bool managementGroup;

  /// 创建应用导航目的地。
  const _AppDestination({
    required this.path,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.features = const <AppFeature>[],
    this.selectionPaths = const <String>[],
    this.managementGroup = false,
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
    label: '每日待办',
    icon: Icons.check_box_outlined,
    selectedIcon: Icons.check_box_rounded,
    features: <AppFeature>[AppFeature.todos],
  ),
  _AppDestination(
    path: '/timeline',
    label: '时间管理',
    icon: Icons.access_time_outlined,
    selectedIcon: Icons.access_time_filled,
    features: <AppFeature>[AppFeature.timeline],
  ),
  _AppDestination(
    path: '/events',
    label: '事件管理',
    icon: Icons.calendar_today_outlined,
    selectedIcon: Icons.calendar_today_rounded,
    features: <AppFeature>[AppFeature.events],
  ),
  _AppDestination(
    path: '/inventory',
    label: '物品管理',
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2_rounded,
    features: <AppFeature>[AppFeature.inventory],
  ),
  _AppDestination(
    path: '/memberships',
    label: '会员管理',
    icon: Icons.credit_card_outlined,
    selectedIcon: Icons.credit_card_rounded,
    features: <AppFeature>[AppFeature.memberships],
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
  ),
  _AppDestination(
    path: '/settings',
    label: '更多',
    icon: Icons.apps_outlined,
    selectedIcon: Icons.apps_rounded,
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

  /// 当前页面内容。
  final Widget child;

  /// 创建响应式应用壳层。
  const ResponsiveShell({
    required this.location,
    required this.child,
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
    // 当前 Android 管理页记住的分区。
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
        SingleActivator(LogicalKeyboardKey.slash): _SearchIntent(),
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
              _showSearch(context);
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
              // 当前是否为展开布局。
              final bool isExpanded = OmniBreakpoint.isExpanded(
                constraints.maxWidth,
              );

              if (isCompact && !isDesktopPlatform) {
                return Scaffold(
                  backgroundColor: colors.canvas,
                  body: SafeArea(child: child),
                  bottomNavigationBar: _CompactNavigation(
                    location: location,
                    destinations: compactDestinations,
                    onSelected: (_AppDestination destination) =>
                        _selectCompactDestination(
                          context,
                          ref,
                          destination,
                          featurePreference,
                          managementSection,
                        ),
                  ),
                );
              }

              return Scaffold(
                backgroundColor: colors.canvas,
                body: Row(
                  children: <Widget>[
                    if (isExpanded)
                      _ExpandedSidebar(
                        location: location,
                        destinations: desktopDestinations,
                        onSelected: (String path) => context.go(path),
                      )
                    else
                      _MediumNavigation(
                        location: location,
                        destinations: desktopDestinations,
                        onSelected: (String path) => context.go(path),
                      ),
                    Expanded(
                      child: Column(
                        children: <Widget>[
                          const _TopBar(),
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

  /// 打开普通底栏路由或记住的 Android 管理分区。
  void _selectCompactDestination(
    BuildContext context,
    WidgetRef ref,
    _AppDestination destination,
    FeaturePreference preference,
    ManagementSection preferredSection,
  ) {
    if (!destination.managementGroup) {
      context.go(destination.path);
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
  final ValueChanged<String> onSelected;

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
    // 用户是否明确开启多端同步。
    final bool syncEnabled = ref.watch(syncPreferenceProvider);
    // 当前侧栏需要展示的同步阶段。
    _SidebarSyncPhase? syncPhase;
    if (syncEnabled) {
      // 当前设备同步会话异步状态。
      final AsyncValue<SyncSession?> sessionState = ref.watch(
        authControllerProvider,
      );
      // 当前同步连接控制器状态。
      final AsyncValue<void> syncController = ref.watch(syncControllerProvider);
      // 当前 PowerSync 实时状态。
      final AsyncValue<SyncStatus?> syncStatusState = ref.watch(
        syncStatusProvider,
      );
      // 当前本机待上传操作数量状态。
      final AsyncValue<int> queueCountState = ref.watch(
        syncUploadQueueCountProvider,
      );
      syncPhase = _resolveSidebarSyncPhase(
        sessionState: sessionState,
        syncController: syncController,
        syncStatusState: syncStatusState,
        queueCountState: queueCountState,
      );
    }

    return Container(
      key: const ValueKey<String>('expanded-sidebar'),
      width: OmniSize.sidebar,
      decoration: BoxDecoration(
        color: colors.paper,
        border: Border(right: BorderSide(color: colors.line)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _BrandMark(colors: colors),
              const SizedBox(height: 28),
              for (final _AppDestination destination in destinations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _SidebarDestination(
                    destination: destination,
                    selected: _isSelected(destination.path, location),
                    onTap: () => onSelected(destination.path),
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
                onTap: () => onSelected(_settingsDestination.path),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 中等宽度导航轨。
class _MediumNavigation extends StatelessWidget {
  /// 当前路由路径。
  final String location;

  /// 当前可见的业务导航项。
  final List<_AppDestination> destinations;

  /// 选择回调。
  final ValueChanged<String> onSelected;

  /// 创建中等宽度导航轨。
  const _MediumNavigation({
    required this.location,
    required this.destinations,
    required this.onSelected,
  });

  /// 构建飞书式紧凑导航轨。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);

    return Container(
      key: const ValueKey<String>('medium-navigation'),
      width: OmniSize.navigationRail,
      decoration: BoxDecoration(
        color: colors.paper,
        border: Border(right: BorderSide(color: colors.line)),
      ),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            const SizedBox(height: OmniSpacing.sm),
            _CompactBrandMark(colors: colors),
            const SizedBox(height: OmniSpacing.lg),
            for (final _AppDestination destination in destinations)
              Padding(
                padding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
                child: _RailDestination(
                  destination: destination,
                  selected: _isSelected(destination.path, location),
                  onTap: () => onSelected(destination.path),
                ),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: OmniSpacing.xxs),
              child: _RailDestination(
                destination: _settingsDestination,
                selected: _isSelected(_settingsDestination.path, location),
                onTap: () => onSelected(_settingsDestination.path),
              ),
            ),
          ],
        ),
      ),
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
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Tooltip(
      message: destination.label,
      child: Material(
        key: ValueKey<String>('navigation-${destination.path}'),
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(OmniRadius.control),
          child: SizedBox(
            width: 56,
            height: 48,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? colors.brandSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                ),
                child: Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: OmniSize.navigationIcon,
                  color: selected ? colors.brand : colors.muted,
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
      child: InkWell(
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
      child: InkWell(
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
                    '/',
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
  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建品牌标识。
  const _BrandMark({required this.colors});

  /// 构建品牌标识。
  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _CompactBrandMark(colors: colors),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Omni Butler',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text('知序', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

/// 紧凑品牌图形。
class _CompactBrandMark extends StatelessWidget {
  /// 当前主题语义色。
  final OmniColors colors;

  /// 创建紧凑品牌图形。
  const _CompactBrandMark({required this.colors});

  /// 构建带刻度的品牌图形。
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: colors.brand,
        borderRadius: BorderRadius.circular(OmniRadius.panel),
      ),
      child: Icon(
        Icons.schedule_rounded,
        color: Theme.of(context).colorScheme.onPrimary,
        size: OmniSize.icon,
      ),
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
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);

    return Material(
      key: ValueKey<String>('navigation-${destination.path}'),
      color: selected ? colors.brandSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(OmniRadius.control),
      child: InkWell(
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
                color: selected ? colors.brand : colors.muted,
              ),
              const SizedBox(width: 12),
              Text(
                destination.label,
                style: TextStyle(
                  color: selected ? colors.brand : colors.ink,
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

/// 展开侧栏中的同步展示阶段。
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

/// 根据同步链路状态解析展开侧栏的展示阶段。
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

/// 展开侧栏中的实时同步状态卡。
class _SyncStatusCard extends StatelessWidget {
  /// 当前主题语义色。
  final OmniColors colors;

  /// 当前同步展示阶段。
  final _SidebarSyncPhase phase;

  /// 创建实时同步状态卡。
  const _SyncStatusCard({required this.colors, required this.phase});

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
