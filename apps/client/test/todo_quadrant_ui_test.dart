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
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证待办四象限在首页、完整页面与编辑器中保持一致。
void main() {
  testWidgets('首页每个象限最多展示三条任务', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 首页固定自然日。
    final DateTime today = DateTime(2026, 9, 6);

    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      for (int index = 1; index <= 4; index += 1) {
        await repository.save(
          TodoDraft(
            title: '${quadrant.label}任务$index',
            scheduledDate: today,
            priorityQuadrant: quadrant,
          ),
        );
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(find.text('${quadrant.label}任务1'), findsOneWidget);
      expect(find.text('${quadrant.label}任务2'), findsOneWidget);
      expect(find.text('${quadrant.label}任务3'), findsOneWidget);
      expect(find.text('${quadrant.label}任务4'), findsNothing);
    }
    expect(find.text('还有 1 项'), findsNWidgets(4));
    // 浅色主题下的紧急且重要象限容器。
    final Container lightQuadrant = tester.widget<Container>(
      find.byKey(const ValueKey<String>('home-todo-quadrant-3')),
    );
    // 象限容器的浅色主题装饰。
    final BoxDecoration lightDecoration =
        lightQuadrant.decoration! as BoxDecoration;
    expect(lightDecoration.color, const Color(0xFFFFFFFF));

    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('首页完成任务播放反馈动画并在模块内提供撤销', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 首页固定自然日。
    final DateTime today = DateTime(2026, 9, 6);
    await repository.save(
      TodoDraft(
        title: '动画任务',
        scheduledDate: today,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // 当前任务文本。
    final Finder taskText = find.text('动画任务');
    // 当前任务行。
    final Finder taskRow = find.widgetWithText(InkWell, '动画任务');
    await tester.tap(taskText);
    await tester.pump();

    expect(taskText, findsOneWidget);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.descendant(
              of: taskRow,
              matching: find.byKey(
                const ValueKey<String>('home-todo-check-mark'),
              ),
            ),
          )
          .opacity,
      1,
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(taskText, findsOneWidget);

    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 190));
    await tester.pump(const Duration(milliseconds: 230));
    await tester.pump();

    // 首页今日待办面板。
    final Finder todoPanel = find.byKey(
      const ValueKey<String>('home-todo-card'),
    );
    // 今日待办面板内部的撤销横幅。
    final Finder undoBanner = find.descendant(
      of: todoPanel,
      matching: find.byKey(const ValueKey<String>('home-todo-undo-banner')),
    );
    expect(taskText, findsNothing);
    expect(undoBanner, findsOneWidget);
    expect(
      find.descendant(of: undoBanner, matching: find.text('已完成“动画任务”')),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(
      find.descendant(of: undoBanner, matching: find.text('撤销')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(taskText, findsOneWidget);
    expect(undoBanner, findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办展示四象限且编辑器使用相同分类', (WidgetTester tester) async {
    // 桌面测试视口。
    const Size viewport = Size(1440, 900);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
        ],
        child: const OmniButlerApp(),
      ),
    );
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(find.text(quadrant.label), findsOneWidget);
      expect(find.text(quadrant.actionLabel), findsOneWidget);
    }

    await tester.tap(find.text('新增待办'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('优先象限'), findsOneWidget);
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(find.text(quadrant.label), findsNWidgets(2));
    }

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
