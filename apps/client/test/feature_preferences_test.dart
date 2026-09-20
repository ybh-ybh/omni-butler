import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/features/settings/presentation/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证功能开关的持久化、设置界面与导航联动。
void main() {
  test('功能偏好默认开启并持久化关闭状态', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );

    expect(
      container
          .read(featurePreferenceProvider)
          .isEnabled(AppFeature.memberships),
      isTrue,
    );

    await container
        .read(featurePreferenceProvider.notifier)
        .setFeatureEnabled(AppFeature.memberships, false);

    expect(
      container
          .read(featurePreferenceProvider)
          .isEnabled(AppFeature.memberships),
      isFalse,
    );
    expect(preferences.getBool('features.memberships.enabled'), isFalse);
    container.dispose();
  });

  testWidgets('Windows 设置页展示左侧一级分类并可关闭功能', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byKey(const ValueKey<String>('settings-category-features')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('settings-category-storage')),
      findsOneWidget,
    );
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('始终开启'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('feature-toggle-memberships')),
    );
    await tester.pumpAndSettle();

    expect(
      container
          .read(featurePreferenceProvider)
          .isEnabled(AppFeature.memberships),
      isFalse,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('关闭会员管理后导航隐藏且直接访问返回首页', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'features.memberships.enabled': false,
    });
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 20, 10, 30)),
      ],
    );

    // 应用路由器。
    final router = container.read(appRouterProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.build(brightness: Brightness.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byKey(const ValueKey<String>('navigation-/memberships')),
      findsNothing,
    );

    router.go('/memberships');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.routeInformationProvider.value.uri.path, '/home');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
