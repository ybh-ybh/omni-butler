import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 需要覆盖的全部一级页面路由。
const List<String> _primaryRoutes = <String>[
  '/home',
  '/todos',
  '/events',
  '/inventory',
  '/timeline',
  '/memberships',
  '/settings',
];

/// 验证统一飞书式页面在关键视口下没有布局异常。
void main() {
  testWidgets('Android 七个一级页面在 390px 视口无布局异常', (WidgetTester tester) async {
    await _verifyRoutesAtSize(
      tester,
      const Size(390, 844),
      TargetPlatform.android,
    );
  });

  testWidgets('Windows 七个一级页面在 1024px 视口无布局异常', (WidgetTester tester) async {
    await _verifyRoutesAtSize(
      tester,
      const Size(1024, 768),
      TargetPlatform.windows,
    );
  });

  testWidgets('Windows 窄窗口保持桌面骨架并隐藏次要区域', (WidgetTester tester) async {
    await _verifyRoutesAtSize(
      tester,
      const Size(640, 760),
      TargetPlatform.windows,
    );
  });
}

/// 在指定视口依次打开全部一级页面并检查框架异常。
Future<void> _verifyRoutesAtSize(
  WidgetTester tester,
  Size viewport,
  TargetPlatform platform,
) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': 'light',
  });
  // 测试用主题偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 测试用内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 显式管理的测试依赖容器，便于先释放页面订阅再关闭数据库。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 9, 5, 10, 30)),
    ],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OmniButlerApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));

  if (platform == TargetPlatform.windows) {
    expect(
      find.byKey(const ValueKey<String>('compact-navigation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('medium-navigation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-todo-card')),
      findsOneWidget,
    );
  }

  for (final String route in _primaryRoutes) {
    container.read(appRouterProvider).go(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.takeException(),
      isNull,
      reason: '$route 在 ${viewport.width}×${viewport.height} 视口发生异常',
    );
  }

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  container.dispose();
  await tester.pump(const Duration(milliseconds: 100));
  await database.close();
  debugDefaultTargetPlatformOverride = null;
}
