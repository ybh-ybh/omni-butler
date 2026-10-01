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
                builder: (context, state) {
                  // 当前是否使用 Android 管理聚合布局。
                  final bool embedded = _usesAndroidManagementLayout(context);
                  return _PrimaryRouteSurface(
                    child: embedded
                        ? const AndroidManagementShell(
                            selectedSection: ManagementSection.events,
                            child: EventsPage(embeddedInManagement: true),
                          )
                        : const EventsPage(),
                  );
                },
              ),
              GoRoute(
                path: '/inventory',
                redirect: (context, state) =>
                    _redirectDisabledFeature(ref, AppFeature.inventory),
                builder: (context, state) {
                  // 当前是否使用 Android 管理聚合布局。
                  final bool embedded = _usesAndroidManagementLayout(context);
                  return _PrimaryRouteSurface(
                    child: embedded
                        ? const AndroidManagementShell(
                            selectedSection: ManagementSection.inventory,
                            child: InventoryPage(embeddedInManagement: true),
                          )
                        : const InventoryPage(),
                  );
                },
              ),
              GoRoute(
                path: '/memberships',
                redirect: (context, state) =>
                    _redirectDisabledFeature(ref, AppFeature.memberships),
                builder: (context, state) {
                  // 当前是否使用 Android 管理聚合布局。
                  final bool embedded = _usesAndroidManagementLayout(context);
                  return _PrimaryRouteSurface(
                    child: embedded
                        ? const AndroidManagementShell(
                            selectedSection: ManagementSection.memberships,
                            child: MembershipsPage(embeddedInManagement: true),
                          )
                        : const MembershipsPage(),
                  );
                },
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
