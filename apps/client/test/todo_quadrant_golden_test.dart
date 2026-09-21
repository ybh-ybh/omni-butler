import 'package:drift/drift.dart';
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

/// 生成并校验每日待办四象限的关键视口视觉基线。
void main() {
  testWidgets('每日待办桌面四象限视觉基线', (WidgetTester tester) async {
    await _verifyTodoGolden(
      tester,
      viewport: const Size(1440, 900),
      platform: TargetPlatform.windows,
      goldenPath: 'goldens/todos_quadrants_light_1440x900.png',
    );
  });

  testWidgets('每日待办移动端纵向象限视觉基线', (WidgetTester tester) async {
    await _verifyTodoGolden(
      tester,
      viewport: const Size(390, 844),
      platform: TargetPlatform.android,
      goldenPath: 'goldens/todos_quadrants_light_390x844.png',
    );
  });

  testWidgets('每日待办桌面空白日视觉基线', (WidgetTester tester) async {
    await _verifyTodoGolden(
      tester,
      viewport: const Size(1440, 900),
      platform: TargetPlatform.windows,
      goldenPath: 'goldens/todos_quadrants_empty_light_1440x900.png',
      seedTodos: false,
    );
  });

  testWidgets('每日待办桌面深色四象限视觉基线', (WidgetTester tester) async {
    await _verifyTodoGolden(
      tester,
      viewport: const Size(1440, 900),
      platform: TargetPlatform.windows,
      goldenPath: 'goldens/todos_quadrants_dark_1440x900.png',
      themeMode: 'dark',
    );
  });

  testWidgets('每日待办桌面完成历史视觉基线', (WidgetTester tester) async {
    await _verifyTodoGolden(
      tester,
      viewport: const Size(1440, 900),
      platform: TargetPlatform.windows,
      goldenPath: 'goldens/todos_history_light_1440x900.png',
      showHistory: true,
    );
  });

  testWidgets('每日待办完成浮动消息视觉基线', (WidgetTester tester) async {
    await _verifyTodoGolden(
      tester,
      viewport: const Size(1440, 900),
      platform: TargetPlatform.windows,
      goldenPath: 'goldens/todos_completion_popup_light_1440x900.png',
      showCompletionPopup: true,
    );
  });
}

/// 在指定视口打开每日待办页并比对视觉基线。
Future<void> _verifyTodoGolden(
  WidgetTester tester, {
  required Size viewport,
  required TargetPlatform platform,
  required String goldenPath,
  bool seedTodos = true,
  bool showHistory = false,
  bool showCompletionPopup = false,
  String themeMode = 'light',
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': themeMode,
  });
  // 测试用主题偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 测试用内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 测试用待办仓储。
  final TodoRepository repository = TodoRepository(database);
  // 视觉基线使用的固定自然日。
  final DateTime today = DateTime(2026, 9, 6);
  if (seedTodos) {
    await repository.save(
      TodoDraft(
        title: '提交发布说明',
        description: '核对本轮功能清单与验证结果',
        scheduledDate: today,
        dueAt: DateTime(2026, 9, 6, 9, 30),
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 用于树形视觉基线的紧急主任务。
    final TodoRecord urgentRoot = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.title.equals('提交发布说明'))).getSingle();
    await repository.save(
      TodoDraft(
        title: '核对数据库迁移',
        parentId: urgentRoot.id,
        scheduledDate: today,
      ),
    );
    await repository.save(
      TodoDraft(title: '检查同步字段', parentId: urgentRoot.id, scheduledDate: today),
    );
    // 固定一条已完成子任务，验证进度与完成历史布局。
    final TodoRecord completedChild = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.title.equals('核对数据库迁移'))).getSingle();
    await database.updateTodo(
      completedChild.id,
      TodoItemsCompanion(
        isCompleted: const Value<bool>(true),
        completedAt: Value<DateTime>(DateTime(2026, 9, 6, 8, 30)),
        updatedAt: Value<DateTime>(DateTime(2026, 9, 6, 8, 30)),
      ),
    );
    await repository.save(
      TodoDraft(
        title: '回复合作方邮件',
        scheduledDate: today,
        dueAt: DateTime(2026, 9, 6, 11),
        priorityQuadrant: TodoPriorityQuadrant.urgentNotImportant,
      ),
    );
    await repository.save(
      TodoDraft(
        title: '整理季度学习计划',
        description: '把主题拆成每周可执行的小目标',
        scheduledDate: today,
        priorityQuadrant: TodoPriorityQuadrant.importantNotUrgent,
        repeatRule: TodoRepeatRule.weekly,
      ),
    );
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
  // 根组件下的 Provider 容器。
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(OmniButlerApp)),
  );
  container.read(appRouterProvider).go('/todos');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  if (showHistory) {
    await tester.tap(find.text('完成历史'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
  if (showCompletionPopup) {
    // 用于触发浮动消息的普通主任务。
    final TodoRecord popupTodo = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.title.equals('回复合作方邮件'))).getSingle();
    // 目标任务行内的完成复选框。
    final Finder completionCheckbox = find.descendant(
      of: find.byKey(ValueKey<String>('todo-row-${popupTodo.id}')),
      matching: find.byType(Checkbox),
    );
    await tester.tap(completionCheckbox);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  await expectLater(find.byType(OmniButlerApp), matchesGoldenFile(goldenPath));

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await database.close();
  debugDefaultTargetPlatformOverride = null;
}
