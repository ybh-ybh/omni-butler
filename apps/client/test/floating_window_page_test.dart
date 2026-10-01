import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/floating/presentation/floating_window_page.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证悬浮窗的核心待办和时间操作入口。
void main() {
  test('待办象限默认一行且最多展示五行', () {
    expect(calculateFloatingTodoViewportHeight(0), 32);
    expect(calculateFloatingTodoViewportHeight(1), 32);
    expect(calculateFloatingTodoViewportHeight(3), 96);
    expect(calculateFloatingTodoViewportHeight(8), 160);
  });

  test('增加的窗口高度只在存在内部滚动的象限之间分配', () {
    expect(
      calculateFloatingTodoViewportHeights(
        taskRowCounts: <int>[12, 8, 1],
        additionalHeight: 300,
      ),
      <double>[364, 256, 32],
    );
  });

  testWidgets('悬浮窗增高后有内部滚动的象限同步增高', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(294, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 当前测试自然日。
    final DateTime today = DateTime(2026, 9, 24);
    for (int index = 0; index < 12; index += 1) {
      await repository.save(
        TodoDraft(title: '可扩展任务 $index', scheduledDate: today),
      );
    }
    // 测试用 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(today.add(const Duration(hours: 9))),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: FloatingWindowPage(
            onClose: () async {},
            onOpenRoute: (String location) async {},
            onDragStart: () {},
            onDragUpdate: () {},
            onDragEnd: () async {},
            onResizeStart: () {},
            onResizeUpdate: () {},
            onResizeEnd: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 默认高度下仍按五行限制象限视口。
    final Finder viewport = find.byKey(
      const ValueKey<String>('floating-todo-viewport-2'),
    );
    expect(tester.getSize(viewport).height, 160);
    // 溢出象限中的滚动条。
    final Scrollbar quadrantScrollbar = tester.widget<Scrollbar>(
      find.descendant(of: viewport, matching: find.byType(Scrollbar)),
    );
    // 溢出象限中的任务列表。
    final ListView quadrantList = tester.widget<ListView>(
      find.descendant(of: viewport, matching: find.byType(ListView)),
    );
    expect(quadrantScrollbar.controller, same(quadrantList.controller));
    expect(quadrantScrollbar.controller!.hasClients, true);
    await tester.drag(viewport, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(quadrantScrollbar.controller!.offset, greaterThan(0));
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(294, 700);
    await tester.pumpAndSettle();

    // 先为下方时间状态保留完整空间，再扩展仍有隐藏任务的象限。
    expect(tester.getSize(viewport).height, greaterThan(160));
    expect(tester.getSize(viewport).height, lessThan(360));
    // 悬浮窗整窗内容滚动位置。
    final Finder contentScrollable = find
        .descendant(
          of: find.byKey(
            const ValueKey<String>('floating-window-content-scroll'),
          ),
          matching: find.byType(Scrollable),
        )
        .first;
    // 增高后的整窗内容已经完整容纳时间状态，无需外层继续滚动。
    expect(
      tester.state<ScrollableState>(contentScrollable).position.maxScrollExtent,
      0,
    );
    expect(
      find.byKey(const ValueKey<String>('floating-time-status')),
      findsOneWidget,
    );
  });

  testWidgets('远端同步表更新后悬浮窗重新读取业务数据', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(294, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 模拟 PowerSync 下行事务的表更新流。
    final StreamController<Set<String>> tableUpdates =
        StreamController<Set<String>>.broadcast();
    addTearDown(tableUpdates.close);
    // 当前模拟同步到本机的进行中时间记录。
    List<TimeEntryRecord> synchronizedRecords = <TimeEntryRecord>[];
    // 测试用 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 24, 9, 30)),
        ongoingTimeEntriesProvider.overrideWith(
          (Ref ref) => Stream<List<TimeEntryRecord>>.value(synchronizedRecords),
        ),
        syncTableUpdatesProvider.overrideWith((Ref ref) => tableUpdates.stream),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: FloatingWindowPage(
            onClose: () async {},
            onOpenRoute: (String location) async {},
            onDragStart: () {},
            onDragUpdate: () {},
            onDragEnd: () async {},
            onResizeStart: () {},
            onResizeUpdate: () {},
            onResizeEnd: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('多端同步进行中记录'), findsNothing);
    // 默认最小尺寸下的悬浮窗内容区域。
    final Finder contentScrollable = find.descendant(
      of: find.byKey(const ValueKey<String>('floating-window-content-scroll')),
      matching: find.byType(Scrollable),
    );
    // 默认最小尺寸下的内容滚动位置。
    final ScrollPosition contentScrollPosition = tester
        .state<ScrollableState>(contentScrollable)
        .position;
    // 空数据状态应在增高后的默认窗口中完整显示，无需额外滚动。
    expect(contentScrollPosition.maxScrollExtent, 0);

    // 模拟远端事务直接下发到本地数据库的跨日期活动待办。
    final DateTime synchronizedAt = DateTime(2026, 9, 24, 9, 35);
    await database
        .into(database.todoItems)
        .insert(
          TodoItemsCompanion.insert(
            id: 'remote-todo',
            title: '多端同步待办',
            scheduledDate: DateTime(2026, 9, 19),
            priorityQuadrant: const Value<int>(3),
            syncState: const Value<String>('synced'),
            createdAt: synchronizedAt,
            updatedAt: synchronizedAt,
          ),
        );
    // 远端事务完成后数据库已经包含的新时间记录。
    synchronizedRecords = <TimeEntryRecord>[
      TimeEntryRecord(
        id: 'remote-time-entry',
        entryDate: DateTime(2026, 9, 24),
        startMinute: 540,
        endMinute: 540,
        startedAt: DateTime(2026, 9, 24, 9),
        activity: '多端同步进行中记录',
        syncState: 'synced',
        createdAt: DateTime(2026, 9, 24, 9),
        updatedAt: DateTime(2026, 9, 24, 9),
      ),
    ];
    tableUpdates.add(<String>{'todo_items', 'time_entries'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('多端同步待办'), findsOneWidget);
    expect(find.text('多端同步进行中记录'), findsOneWidget);
  });

  testWidgets('悬浮窗父任务标题右侧显示未完成子任务数量', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(294, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    // 当前测试自然日。
    final DateTime today = DateTime(2026, 9, 24);
    await repository.save(TodoDraft(title: '带子任务的父任务', scheduledDate: today));
    // 新增后的父任务记录。
    final TodoRecord root = await database
        .select(database.todoItems)
        .getSingle();
    await repository.save(
      TodoDraft(title: '未完成子任务', parentId: root.id, scheduledDate: today),
    );
    await repository.save(
      TodoDraft(title: '已完成子任务', parentId: root.id, scheduledDate: today),
    );
    // 父任务下的两个子任务。
    final List<TodoRecord> children = await (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.parentId.equals(root.id))).get();
    // 需要预先完成的子任务记录。
    final TodoRecord completedChild = children.singleWhere(
      (TodoRecord child) => child.title == '已完成子任务',
    );
    await repository.setCompleted(completedChild.id, true);
    // 测试用 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(today.add(const Duration(hours: 9))),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: FloatingWindowPage(
            onClose: () async {},
            onOpenRoute: (String location) async {},
            onDragStart: () {},
            onDragUpdate: () {},
            onDragEnd: () async {},
            onResizeStart: () {},
            onResizeUpdate: () {},
            onResizeEnd: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 父任务标题后的未完成子任务数量标签。
    final Finder pendingCount = find.byKey(
      ValueKey<String>('floating-todo-pending-count-${root.id}'),
    );
    expect(find.text('带子任务的父任务'), findsOneWidget);
    expect(pendingCount, findsOneWidget);
    expect(
      find.descendant(of: pendingCount, matching: find.text('1')),
      findsOneWidget,
    );
    expect(find.text('未完成子任务'), findsOneWidget);
    expect(find.text('已完成子任务'), findsNothing);
    // 父任务批量展开状态按钮。
    final Finder toggleAll = find.byKey(
      const ValueKey<String>('floating-todo-toggle-all'),
    );
    expect(toggleAll, findsOneWidget);
    expect(find.byTooltip('收起全部子任务'), findsOneWidget);

    await tester.tap(toggleAll);
    await tester.pump();
    expect(find.text('未完成子任务'), findsNothing);
    expect(find.byTooltip('展开全部子任务'), findsOneWidget);

    await tester.tap(toggleAll);
    await tester.pump();
    expect(find.text('未完成子任务'), findsOneWidget);
    expect(find.byTooltip('收起全部子任务'), findsOneWidget);

    // 逐个折叠到全部折叠时，批量按钮也应切换成展开全部。
    await tester.tap(
      find.byKey(ValueKey<String>('floating-todo-expand-${root.id}')),
    );
    await tester.pump();
    expect(find.text('未完成子任务'), findsNothing);
    expect(find.byTooltip('展开全部子任务'), findsOneWidget);
  });

  testWidgets('悬浮窗可直接新增待办、补记和开始时间记录', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(294, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试用设备偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 测试用 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 24, 9, 30)),
      ],
    );
    addTearDown(container.dispose);
    // 用户请求跳转到主窗口的目标路由。
    String? openedRoute;
    // 左下角尺寸调整开始次数。
    int resizeStartCount = 0;
    // 左下角尺寸调整更新次数。
    int resizeUpdateCount = 0;
    // 左下角尺寸调整结束次数。
    int resizeEndCount = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: FloatingWindowPage(
            onClose: () async {},
            onOpenRoute: (String location) async => openedRoute = location,
            onDragStart: () {},
            onDragUpdate: () {},
            onDragEnd: () async {},
            onResizeStart: () => resizeStartCount += 1,
            onResizeUpdate: () => resizeUpdateCount += 1,
            onResizeEnd: () async {
              resizeEndCount += 1;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('今日待办'), findsOneWidget);
    expect(find.text('重要·紧急'), findsOneWidget);
    expect(find.text('重要·不紧急'), findsOneWidget);
    expect(find.text('紧急·不重要'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('floating-todo-create')),
      findsOneWidget,
    );
    expect(find.text('新增'), findsNothing);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    // 标题栏中位于关闭按钮左侧的每日待办入口。
    final Finder openTodosButton = find.byKey(
      const ValueKey<String>('floating-window-open-todos'),
    );
    // 标题栏关闭按钮。
    final Finder closeButton = find.byKey(
      const ValueKey<String>('floating-window-close-button'),
    );
    expect(openTodosButton, findsOneWidget);
    expect(closeButton, findsOneWidget);
    expect(
      tester.getCenter(openTodosButton).dx,
      lessThan(tester.getCenter(closeButton).dx),
    );
    await tester.tap(openTodosButton);
    await tester.pump();
    expect(openedRoute, '/todos');
    // 待办标题栏中的批量按钮位于新增按钮左侧。
    final Finder toggleAllButton = find.byKey(
      const ValueKey<String>('floating-todo-toggle-all'),
    );
    // 待办新增按钮。
    final Finder createButton = find.byKey(
      const ValueKey<String>('floating-todo-create'),
    );
    expect(toggleAllButton, findsOneWidget);
    expect(
      tester.getCenter(toggleAllButton).dx,
      lessThan(tester.getCenter(createButton).dx),
    );
    // 悬浮窗左下角尺寸调整手柄。
    final Finder resizeHandle = find.byKey(
      const ValueKey<String>('floating-window-resize-handle'),
    );
    expect(resizeHandle, findsOneWidget);
    expect(tester.getSize(resizeHandle), const Size.square(28));
    await tester.drag(resizeHandle, const Offset(-24, 36));
    await tester.pump();
    expect(resizeStartCount, 1);
    expect(resizeUpdateCount, greaterThan(0));
    expect(resizeEndCount, 1);
    // 新增入口中的加号旋转动画。
    final Finder createIconRotation = find.descendant(
      of: find.byKey(const ValueKey<String>('floating-todo-create')),
      matching: find.byType(AnimatedRotation),
    );
    expect(tester.widget<AnimatedRotation>(createIconRotation).turns, 0);
    expect(
      tester.getSize(
        find.byKey(const ValueKey<String>('floating-todo-create')),
      ),
      const Size.square(32),
    );
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('floating-todo-viewport-3')),
          )
          .height,
      floatingTodoRowHeight,
    );

    await tester.ensureVisible(find.text('时间状态'));
    await tester.pumpAndSettle();
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('补记'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-time-start')),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-time-backfill')),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('floating-time-start')))
          .height,
      30,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-create')),
    );
    await tester.pump();
    expect(tester.widget<AnimatedRotation>(createIconRotation).turns, 0.125);
    expect(find.text('新增今日待办'), findsNothing);
    expect(find.byTooltip('取消'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('floating-todo-title-field')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-todo-inline-cancel')),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-todo-inline-save')),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-create')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedRotation>(createIconRotation).turns, 0);
    expect(
      find.byKey(const ValueKey<String>('floating-todo-title-field')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-create')),
    );
    await tester.pumpAndSettle();
    // 使用悬浮窗专属的紧凑半透明输入样式。
    final InputDecorator titleDecorator = tester.widget<InputDecorator>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('floating-todo-title-field')),
        matching: find.byType(InputDecorator),
      ),
    );
    expect(titleDecorator.decoration.labelText, isNull);
    expect(titleDecorator.decoration.filled, isTrue);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('floating-todo-title-field')),
          )
          .height,
      lessThan(44),
    );
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('floating-todo-priority-field')),
          )
          .height,
      lessThan(44),
    );
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('floating-todo-title-field')),
      '悬浮窗新增待办',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-inline-save')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 内联保存后的待办记录。
    final List<TodoRecord> todos = await database
        .select(database.todoItems)
        .get();
    expect(todos.map((TodoRecord todo) => todo.title), contains('悬浮窗新增待办'));

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('floating-time-backfill')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-time-backfill')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('floating-backfill-composer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('floating-time-activity-field')),
      '整理资料',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-time-inline-save')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 内联补记后的已完成记录。
    final List<TimeEntryRecord> backfilledRecords = await database
        .select(database.timeEntries)
        .get();
    expect(backfilledRecords, hasLength(1));
    expect(backfilledRecords.single.endedAt, isNotNull);

    await tester.tap(find.byKey(const ValueKey<String>('floating-time-start')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('floating-start-composer')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-time-inline-save')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 开始记录后新增的进行中记录。
    final List<TimeEntryRecord> allTimeRecords = await database
        .select(database.timeEntries)
        .get();
    expect(allTimeRecords, hasLength(2));
    expect(
      allTimeRecords.where((TimeEntryRecord record) => record.endedAt == null),
      hasLength(1),
    );

    expect(
      find.byKey(const ValueKey<String>('floating-todo-view-all')),
      findsNothing,
    );
  });
}
