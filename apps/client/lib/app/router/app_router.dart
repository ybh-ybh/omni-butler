import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/features/events/presentation/events_page.dart';
import 'package:omni_butler/features/home/presentation/home_page.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_page.dart';
import 'package:omni_butler/features/memberships/presentation/memberships_page.dart';
import 'package:omni_butler/features/settings/presentation/settings_page.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_page.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/presentation/todos_page.dart';
import 'package:omni_butler/shared/layout/responsive_shell.dart';

/// 应用路由器提供者。
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((Ref ref) {
  return GoRouter(
    initialLocation: '/home',
    routes: <RouteBase>[
      ShellRoute(
        builder: (context, state, child) {
          return ResponsiveShell(location: state.uri.path, child: child);
        },
        routes: <RouteBase>[
          GoRoute(
            path: '/home',
            builder: (context, state) =>
                _PrimaryRouteSurface(child: const HomePage()),
          ),
          GoRoute(
            path: '/todos',
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
          GoRoute(
            path: '/events',
            builder: (context, state) =>
                _PrimaryRouteSurface(child: const EventsPage()),
          ),
          GoRoute(
            path: '/inventory',
            builder: (context, state) =>
                _PrimaryRouteSurface(child: const InventoryPage()),
          ),
          GoRoute(
            path: '/timeline',
            builder: (context, state) =>
                _PrimaryRouteSurface(child: const TimelinePage()),
          ),
          GoRoute(
            path: '/memberships',
            builder: (context, state) =>
                _PrimaryRouteSurface(child: const MembershipsPage()),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) =>
                _PrimaryRouteSurface(child: const SettingsPage()),
          ),
        ],
      ),
    ],
  );
});

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
