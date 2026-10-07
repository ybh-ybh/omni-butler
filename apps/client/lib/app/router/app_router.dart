import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/events/presentation/events_page.dart';
import 'package:omni_butler/features/home/presentation/home_page.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_page.dart';
import 'package:omni_butler/features/management/presentation/android_management_shell.dart';
import 'package:omni_butler/features/memberships/presentation/memberships_page.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/features/settings/presentation/settings_page.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_page.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/presentation/todos_page.dart';
import 'package:omni_butler/shared/layout/primary_navigation_swipe.dart';
import 'package:omni_butler/shared/layout/responsive_shell.dart';

/// 应用路由器提供者。
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((Ref ref) {
  // Android 需要预载真实相邻页面以支持首次跟手横滑。
  final bool preloadPrimaryBranches =
      defaultTargetPlatform == TargetPlatform.android;
  // 路由创建时的功能开关，用于选择管理分支的有效预载页面。
  final FeaturePreference preference = ref.read(featurePreferenceProvider);
  // 管理分支预载时使用的首个有效路由，避免默认物品功能关闭时跳回首页。
  final String initialManagementLocation =
      resolveManagementSection(
        preference,
        ManagementSection.inventory,
      )?.route ??
      '/inventory';
  // 在有状态分支容器与应用底栏之间共享的导航协调器。
  final PrimaryNavigationCoordinator primaryNavigationCoordinator =
      PrimaryNavigationCoordinator();
  return GoRouter(
    initialLocation: '/home',
    routes: <RouteBase>[
      StatefulShellRoute(
        builder: (context, state, navigationShell) {
          return ResponsiveShell(
            location: state.uri.path,
            navigationShell: navigationShell,
            primaryNavigationCoordinator: primaryNavigationCoordinator,
            child: navigationShell,
          );
        },
        navigatorContainerBuilder: (context, navigationShell, children) {
          return PrimaryNavigationBranchContainer(
            navigationShell: navigationShell,
            coordinator: primaryNavigationCoordinator,
            children: children,
          );
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            preload: preloadPrimaryBranches,
            routes: <RouteBase>[
              GoRoute(
                path: '/home',
                builder: (context, state) =>
                    _PrimaryRouteSurface(child: const HomePage()),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: preloadPrimaryBranches,
            routes: <RouteBase>[
              GoRoute(
                path: '/todos',
                redirect: (context, state) =>
                    _redirectDisabledFeature(ref, AppFeature.todos),
                builder: (context, state) {
                  // 路由中可选的象限存储值。
                  final int? quadrantValue = int.tryParse(
                    state.uri.queryParameters['quadrant'] ?? '',
                  );
                  // 仅接受四象限定义内的路由值。
                  final TodoPriorityQuadrant? initialPriorityQuadrant =
                      quadrantValue != null &&
                          quadrantValue >= 0 &&
                          quadrantValue <= 3
                      ? TodoPriorityQuadrant.fromValue(quadrantValue)
                      : null;
                  return _PrimaryRouteSurface(
                    child: TodosPage(
                      initialPriorityQuadrant: initialPriorityQuadrant,
                    ),
                  );
                },
              ),
            ],
          ),
          StatefulShellBranch(
            preload: preloadPrimaryBranches,
            routes: <RouteBase>[
              GoRoute(
                path: '/timeline',
                redirect: (context, state) =>
                    _redirectDisabledFeature(ref, AppFeature.timeline),
                builder: (context, state) =>
                    _PrimaryRouteSurface(child: const TimelinePage()),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: preloadPrimaryBranches,
            initialLocation: initialManagementLocation,
            routes: <RouteBase>[
              GoRoute(
                path: '/events',
                redirect: (context, state) =>
                    _redirectDisabledFeature(ref, AppFeature.events),
                pageBuilder: (context, state) => _buildManagementRoutePage(
                  context,
                  state,
                  ManagementSection.events,
                ),
              ),
              GoRoute(
                path: '/inventory',
                redirect: (context, state) =>
                    _redirectDisabledFeature(ref, AppFeature.inventory),
                pageBuilder: (context, state) => _buildManagementRoutePage(
                  context,
                  state,
                  ManagementSection.inventory,
                ),
              ),
              GoRoute(
                path: '/memberships',
                redirect: (context, state) =>
                    _redirectDisabledFeature(ref, AppFeature.memberships),
                pageBuilder: (context, state) => _buildManagementRoutePage(
                  context,
                  state,
                  ManagementSection.memberships,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: preloadPrimaryBranches,
            routes: <RouteBase>[
              GoRoute(
                path: '/settings',
                builder: (context, state) =>
                    _PrimaryRouteSurface(child: const SettingsPage()),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

/// Windows 管理分区直接切换，紧凑 Android 复用页面身份以保留在途横滑。
Page<void> _buildManagementRoutePage(
  BuildContext context,
  GoRouterState state,
  ManagementSection section,
) {
  // 只有 Android 紧凑布局共享分页壳层，其他平台保留各路由页面身份。
  final bool embedded = _usesAndroidManagementLayout(context);
  // 管理分区的真实业务页面。
  final Widget content = switch (section) {
    ManagementSection.events => EventsPage(embeddedInManagement: embedded),
    ManagementSection.inventory => InventoryPage(
      embeddedInManagement: embedded,
    ),
    ManagementSection.memberships => MembershipsPage(
      embeddedInManagement: embedded,
    ),
  };
  // 各平台共用完整页面表面，保留 Android 管理分页壳层。
  final Widget surface = _PrimaryRouteSurface(
    child: embedded
        ? AndroidManagementShell(selectedSection: section, child: content)
        : content,
  );
  if (Theme.of(context).platform == TargetPlatform.windows) {
    return NoTransitionPage<void>(
      key: state.pageKey,
      name: state.name ?? state.path,
      arguments: <String, String>{
        ...state.pathParameters,
        ...state.uri.queryParameters,
      },
      restorationId: state.pageKey.value,
      child: surface,
    );
  }
  return MaterialPage<void>(
    key: embedded
        ? const ValueKey<String>('android-management-page')
        : state.pageKey,
    name: state.name ?? state.path,
    arguments: <String, String>{
      ...state.pathParameters,
      ...state.uri.queryParameters,
    },
    restorationId: embedded ? 'android-management-page' : state.pageKey.value,
    child: surface,
  );
}

/// 判断当前是否为使用底部导航的 Android 紧凑布局。
bool _usesAndroidManagementLayout(BuildContext context) {
  return Theme.of(context).platform == TargetPlatform.android &&
      OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
}

/// 已关闭的业务功能统一返回首页。
String? _redirectDisabledFeature(Ref ref, AppFeature feature) {
  // 当前设备功能偏好。
  final FeaturePreference preference = ref.read(featurePreferenceProvider);
  return preference.isEnabled(feature) ? null : '/home';
}

/// 一级页面的完整命中表面。
class _PrimaryRouteSurface extends StatelessWidget {
  /// 当前一级页面内容。
  final Widget child;

  /// 创建覆盖整个路由视口的页面表面。
  const _PrimaryRouteSurface({required this.child});

  /// 构建可接住透明留白点击的页面背景。
  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: child,
    );
  }
}
