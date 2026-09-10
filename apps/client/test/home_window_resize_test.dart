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

/// 验证 Windows 窗口实时缩放时的自适应与渐进隐藏规则。
void main() {
  testWidgets('Windows 首页缩放时主区域伸缩且次要组件不重排', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 显式管理的测试依赖容器。
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
    await tester.pumpAndSettle();

    // 宽窗口下待办主区域宽度。
    final double wideTodoWidth = tester
        .getSize(find.byKey(const ValueKey<String>('home-todo-card')))
        .width;
    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsOneWidget,
    );

    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();

    // 窄窗口下待办主区域宽度。
    final double narrowTodoWidth = tester
        .getSize(find.byKey(const ValueKey<String>('home-todo-card')))
        .width;
    expect(narrowTodoWidth, greaterThan(wideTodoWidth));
    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('compact-navigation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('medium-navigation')),
      findsOneWidget,
    );

    tester.view.physicalSize = const Size(1024, 500);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('home-quote-card')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('home-day-ruler')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-todo-card')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
