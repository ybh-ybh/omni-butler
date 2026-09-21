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

  testWidgets('首页完成任务播放反馈动画并提供顶部浮动撤销', (WidgetTester tester) async {
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

    // 窗口顶部的统一撤销浮动消息。
    final Finder undoPopup = find.byKey(
      const ValueKey<String>('omni-message-popup'),
    );
    expect(taskText, findsNothing);
    expect(undoPopup, findsOneWidget);
    expect(
      find.descendant(of: undoPopup, matching: find.text('已完成“动画任务”')),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.descendant(of: undoPopup, matching: find.text('撤销')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(taskText, findsOneWidget);
    expect(undoPopup, findsNothing);

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
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsOneWidget,
    );
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(
        find.byKey(ValueKey<String>('todo-quadrant-card-${quadrant.value}')),
        findsOneWidget,
      );
    }
    expect(find.text('重要'), findsNothing);
    expect(find.text('不重要'), findsNothing);
    expect(find.text('紧\n急'), findsNothing);
    expect(find.text('不\n紧\n急'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('todo-quadrant-heading-3')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsNothing,
    );
    expect(find.text('返回四象限'), findsOneWidget);
    await tester.tap(find.text('返回四象限'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('todo-primary-create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 描述标签。
    final Finder descriptionLabel = find.text('描述（可选）');
    // 优先象限标题。
    final Finder priorityLabel = find.text('优先象限');
    // 默认收起的时间设置。
    final Finder timeSettings = find.byKey(
      const ValueKey<String>('todo-time-settings'),
    );
    expect(find.text('优先象限'), findsOneWidget);
    expect(find.text('备注（可选）'), findsNothing);
    expect(
      tester.getTopLeft(descriptionLabel).dy,
      lessThan(tester.getTopLeft(priorityLabel).dy),
    );
    expect(timeSettings, findsOneWidget);
    expect(find.text('计划日期'), findsNothing);
    expect(find.text('设置截止日期'), findsNothing);
    expect(find.text('设置提醒日期'), findsNothing);
    expect(find.text('重复'), findsNothing);
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(find.text(quadrant.label), findsNWidgets(2));
    }

    await tester.ensureVisible(timeSettings);
    await tester.tap(timeSettings);
    await tester.pumpAndSettle();
    expect(find.text('计划日期'), findsOneWidget);
    expect(find.text('设置截止日期'), findsOneWidget);
    expect(find.text('设置提醒日期'), findsOneWidget);
    expect(find.text('重复'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办完成任务后淡出并提供浮动撤销消息', (WidgetTester tester) async {
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
    // 测试使用的固定自然日。
    final DateTime today = DateTime(2026, 9, 6);
    await repository.save(
      TodoDraft(
        title: '完成反馈任务',
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
    // 根组件下的 Provider 容器。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(OmniButlerApp)),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('完成反馈任务'), findsOneWidget);
    expect(find.text('已保存到本机'), findsNothing);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    // 正在淡出的任务行。
    final Finder fadingRowFinder = find.ancestor(
      of: find.text('完成反馈任务'),
      matching: find.byType(AnimatedOpacity),
    );
    // 正在淡出的任务行动画。
    final AnimatedOpacity fadingRow = tester.widget<AnimatedOpacity>(
      fadingRowFinder,
    );
    expect(fadingRow.opacity, 0);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    expect(find.text('完成反馈任务'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('omni-message-popup')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('omni-message-positioned')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-quadrant-grid')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('撤销'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('完成反馈任务'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('omni-message-popup')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办移动端可从纵向四象限聚焦单个象限', (WidgetTester tester) async {
    // 移动端测试视口。
    const Size viewport = Size(390, 844);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
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

    expect(
      find.byKey(const ValueKey<String>('todo-mobile-filter-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-create')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-primary-create')),
      findsNothing,
    );
    for (final TodoPriorityQuadrant quadrant
        in todoPriorityQuadrantMatrixOrder) {
      expect(
        find.byKey(
          ValueKey<String>('todo-mobile-section-${quadrant.value}-all'),
        ),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-filter-2')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-section-2-focused')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-section-3-all')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办进行中跨计划日期常驻且完成历史按完成日展示', (WidgetTester tester) async {
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
    // 与仓储完成时间一致的当前自然日。
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    await repository.save(
      TodoDraft(
        title: '历史遗留任务',
        scheduledDate: today.subtract(const Duration(days: 5)),
      ),
    );
    await repository.save(
      TodoDraft(
        title: '未来计划任务',
        scheduledDate: today.add(const Duration(days: 5)),
      ),
    );
    await repository.save(
      TodoDraft(
        title: '今天完成任务',
        scheduledDate: today.subtract(const Duration(days: 2)),
      ),
    );
    // 待完成记录。
    final TodoRecord completed = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.title.equals('今天完成任务'))).getSingle();
    await repository.setCompleted(completed.id, true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(today.add(const Duration(hours: 10))),
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

    expect(find.text('历史遗留任务'), findsOneWidget);
    expect(find.text('未来计划任务'), findsOneWidget);
    expect(find.text('今天完成任务'), findsNothing);
    await tester.tap(find.text('完成历史'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('今天完成任务'), findsOneWidget);
    expect(find.text('历史遗留任务'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('每日待办展示子任务进度并可拖动整树跨象限', (WidgetTester tester) async {
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
    // 当前测试自然日。
    final DateTime today = DateTime(2026, 9, 21);
    await repository.save(
      TodoDraft(
        title: '发布主任务',
        scheduledDate: today,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 主任务记录。
    final TodoRecord root = await database
        .select(database.todoItems)
        .getSingle();
    await repository.save(
      TodoDraft(title: '发布子任务', parentId: root.id, scheduledDate: today),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(today.add(const Duration(hours: 10))),
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

    expect(find.text('发布主任务'), findsOneWidget);
    expect(find.text('发布子任务'), findsOneWidget);
    expect(
      find.byKey(ValueKey<String>('todo-tree-progress-${root.id}')),
      findsOneWidget,
    );
    // 主任务拖动手柄。
    final Finder handle = find.byKey(
      ValueKey<String>('todo-drag-handle-${root.id}'),
    );
    // 快速处理象限放置区。
    final Finder target = find.byKey(
      const ValueKey<String>('todo-drop-quadrant-1'),
    );
    // 模拟桌面拖动到目标象限。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(handle),
    );
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 拖动后的主任务。
    final TodoRecord movedRoot = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.id.equals(root.id))).getSingle();
    // 拖动后的子任务。
    final TodoRecord movedChild = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.parentId.equals(root.id))).getSingle();
    expect(
      movedRoot.priorityQuadrant,
      TodoPriorityQuadrant.urgentNotImportant.value,
    );
    expect(
      movedChild.priorityQuadrant,
      TodoPriorityQuadrant.urgentNotImportant.value,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
