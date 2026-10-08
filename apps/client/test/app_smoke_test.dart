import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证根应用、数据库和主题切换可以协同启动。
void main() {
  testWidgets('显示首页并使用统一品牌主题', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('今天，慢一点也没关系'), findsNothing);
    expect(find.text('今日刻度'), findsOneWidget);
    expect(find.textContaining('星期'), findsOneWidget);
    expect(find.text('今日待办'), findsOneWidget);
    expect(find.text('海盐'), findsNothing);
    expect(find.text('石墨'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-swipe-surface')),
      findsNothing,
    );

    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    expect(container.read(themeControllerProvider).mode, ThemeMode.system);

    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('紧凑布局只展示五个底部入口', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 紧凑布局窗口尺寸。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    // 仅检查一级导航标签，首页模块也有同名的待办和时间标签。
    for (final (String, String) destination in <(String, String)>[
      ('/home', '首页'),
      ('/todos', '待办'),
      ('/timeline', '时间'),
      ('/inventory', '管理'),
      ('/settings', '设置'),
    ]) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>('navigation-${destination.$1}')),
          matching: find.text(destination.$2),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('更多'), findsNothing);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
