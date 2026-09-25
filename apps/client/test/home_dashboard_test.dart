import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_priority_quadrant_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证首页重点区间、功能联动和时间状态真实数据。
void main() {
  testWidgets('首页与每日待办共享跨日期任务及用户排序', (WidgetTester tester) async {
    // 测试当天。
    final DateTime now = DateTime(2026, 9, 25, 14);
    // 两个页面共用的数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 两个页面实际使用的业务仓储。
    final TodoRepository repository = TodoRepository(database);
    // 分别创建昨天、今天及明天的未完成任务。
    for (final int offset in <int>[-1, 0, 1]) {
      await repository.save(
        TodoDraft(
          title: '跨日期任务$offset',
          scheduledDate: now.add(Duration(days: offset)),
          priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
          dueAt: now.add(Duration(days: -offset)),
        ),
      );
    }
    // 待排序任务，用户排序刻意不同于截止时间顺序。
    final List<TodoRecord> records = await database
        .select(database.todoItems)
        .get();
    await repository.reorderRoots(
      TodoPriorityQuadrant.urgentImportant,
      <String>[
        for (final int offset in <int>[-1, 1, 0])
          records
              .singleWhere((TodoRecord row) => row.title == '跨日期任务$offset')
              .id,
      ],
    );
    // 使用完整应用路由验证两页数据。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: await _preferences(<String, Object>{}),
      now: now,
    );
    // 逐页比较相同任务的可见性及顺序。
    for (final String route in <String>['/home', '/todos']) {
      container.read(appRouterProvider).go(route);
      await tester.pumpAndSettle();
      for (final int offset in <int>[-1, 0, 1]) {
        expect(find.text('跨日期任务$offset'), findsOneWidget);
      }
      expect(
        tester.getTopLeft(find.text('跨日期任务-1')).dy,
        lessThan(tester.getTopLeft(find.text('跨日期任务1')).dy),
      );
      expect(
        tester.getTopLeft(find.text('跨日期任务1')).dy,
        lessThan(tester.getTopLeft(find.text('跨日期任务0')).dy),
      );
    }
    await _disposeApp(tester, database, container);
  });

  testWidgets('首页勾选后立即切换每日待办仍提交完成并响应重新打开', (WidgetTester tester) async {
    // 测试当天。
    final DateTime now = DateTime(2026, 9, 25, 14);
    // 两个页面共用的数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 页面使用真实仓储，不替换数据流。
    final TodoRepository repository = TodoRepository(database);
    await repository.save(
      TodoDraft(
        title: '切页完成任务',
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 待操作任务的稳定身份。
    final TodoRecord record = await database
        .select(database.todoItems)
        .getSingle();
    // 完整应用及路由容器。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: await _preferences(<String, Object>{}),
      now: now,
    );
    await tester.tap(
      find.byKey(ValueKey<String>('home-todo-checkbox-action-${record.id}')),
    );
    container.read(appRouterProvider).go('/todos');
    await tester.pump();
    // 路由销毁后动画不再请求帧，显式推进延迟而非只等待页面稳定。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    // 动画中的页面销毁不能取消持久化。
    final TodoRecord completed = await database
        .select(database.todoItems)
        .getSingle();
    expect(completed.isCompleted, isTrue);
    expect(find.text('切页完成任务'), findsNothing);
    await repository.setCompleted(record.id, false);
    await tester.pumpAndSettle();
    expect(find.text('切页完成任务'), findsOneWidget);
    container.read(appRouterProvider).go('/home');
    await tester.pumpAndSettle();
    expect(find.text('切页完成任务'), findsOneWidget);
    await _disposeApp(tester, database, container);
  });

  testWidgets('首页只展示三个重点待办区间', (WidgetTester tester) async {
    // 测试当前时间。
    final DateTime now = DateTime(2026, 9, 21, 14, 20);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用待办仓储。
    final TodoRepository repository = TodoRepository(database);
    for (final (String, TodoPriorityQuadrant) item
        in <(String, TodoPriorityQuadrant)>[
          ('立即提交', TodoPriorityQuadrant.urgentImportant),
          ('规划学习', TodoPriorityQuadrant.importantNotUrgent),
          ('快速回复', TodoPriorityQuadrant.urgentNotImportant),
          ('以后整理', TodoPriorityQuadrant.neitherUrgentNorImportant),
        ]) {
      await repository.save(
        TodoDraft(
          title: item.$1,
          scheduledDate: DateUtils.dateOnly(now),
          priorityQuadrant: item.$2,
          dueAt: item.$1 == '立即提交' ? DateTime(2026, 9, 21, 16) : null,
        ),
      );
    }
    // 用作子任务父级的根待办。
    final TodoRecord parent = (await database.select(database.todoItems).get())
        .firstWhere((TodoRecord item) => item.title == '立即提交');
    await repository.save(
      TodoDraft(
        title: '首页直属子任务',
        parentId: parent.id,
        scheduledDate: DateUtils.dateOnly(now),
        dueAt: DateTime(2026, 9, 21, 17, 30),
      ),
    );
    // 测试用设备偏好。
    final SharedPreferences preferences = await _preferences(
      <String, Object>{},
    );

    // 显式管理的测试依赖容器。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: preferences,
      now: now,
    );

    expect(
      find.byKey(const ValueKey<String>('home-todo-quadrant-3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-todo-quadrant-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-todo-quadrant-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-todo-quadrant-0')),
      findsNothing,
    );
    expect(find.text('以后整理'), findsNothing);
    expect(find.text('首页直属子任务'), findsOneWidget);
    expect(find.text('立即处理'), findsNothing);
    expect(find.text('安排时间'), findsNothing);
    expect(find.text('快速处理'), findsNothing);
    expect(find.text('3 项重点'), findsNothing);
    expect(find.text('查看全部'), findsNothing);
    expect(find.text('新增待办'), findsNothing);
    expect(find.text('新增'), findsOneWidget);
    expect(find.text('16:00'), findsOneWidget);
    expect(find.text('17:30'), findsOneWidget);
    for (final TodoPriorityQuadrant quadrant in <TodoPriorityQuadrant>[
      TodoPriorityQuadrant.urgentImportant,
      TodoPriorityQuadrant.importantNotUrgent,
      TodoPriorityQuadrant.urgentNotImportant,
    ]) {
      // 当前象限标签。
      final Finder quadrantLabel = find.text(quadrant.label);
      // 当前主题中的象限语义色。
      final Color quadrantColor = quadrant.color(
        OmniColors.of(tester.element(quadrantLabel)),
      );
      expect(tester.widget<Text>(quadrantLabel).style?.color, quadrantColor);
      // 当前象限顶部的彩色分隔线。
      final Divider quadrantDivider = tester.widget<Divider>(
        find
            .descendant(
              of: find.byKey(
                ValueKey<String>('home-todo-quadrant-${quadrant.value}'),
              ),
              matching: find.byType(Divider),
            )
            .first,
      );
      expect(quadrantDivider.color, quadrantColor);
    }
    // 首页新增按钮尺寸。
    final Size createButtonSize = tester.getSize(
      find.byKey(const ValueKey<String>('home-todo-create-button')),
    );
    expect(createButtonSize.height, 30);
    // 首页父任务的子任务展开按钮。
    final Finder childToggle = find.byKey(
      ValueKey<String>('home-todo-tree-toggle-${parent.id}'),
    );
    expect(childToggle, findsOneWidget);
    // 父任务勾选框、标题、截止时间与展开按钮的水平位置。
    final double checkboxLeft = tester
        .getTopLeft(
          find.byKey(ValueKey<String>('home-todo-checkbox-${parent.id}')),
        )
        .dx;
    final double titleLeft = tester.getTopLeft(find.text('立即提交')).dx;
    final double dueLeft = tester
        .getTopLeft(find.byKey(ValueKey<String>('home-todo-due-${parent.id}')))
        .dx;
    final double toggleLeft = tester.getTopLeft(childToggle).dx;
    expect(checkboxLeft, lessThan(titleLeft));
    expect(titleLeft, lessThan(dueLeft));
    expect(dueLeft, lessThan(toggleLeft));
    await tester.tap(childToggle);
    await tester.pumpAndSettle();
    expect(find.text('首页直属子任务'), findsNothing);
    await tester.tap(childToggle);
    await tester.pumpAndSettle();
    expect(find.text('首页直属子任务'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('home-todo-create-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('新增待办'), findsOneWidget);

    await _disposeApp(tester, database, container);
  });

  testWidgets('功能开关隐藏对应卡片并保留今日刻度', (WidgetTester tester) async {
    // 测试当前时间。
    final DateTime now = DateTime(2026, 9, 21, 14, 20);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 关闭所有业务功能的设备偏好。
    final SharedPreferences preferences = await _preferences(<String, Object>{
      'features.todos.enabled': false,
      'features.timeline.enabled': false,
      'features.events.enabled': false,
      'features.inventory.enabled': false,
      'features.memberships.enabled': false,
    });

    // 显式管理的测试依赖容器。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: preferences,
      now: now,
    );

    expect(
      find.byKey(const ValueKey<String>('home-day-ruler')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('home-todo-card')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('home-time-status-card')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsNothing,
    );

    await _disposeApp(tester, database, container);
  });

  testWidgets('今日脉络只展示事件与会员，不受物品功能影响', (WidgetTester tester) async {
    // 测试当前时间。
    final DateTime now = DateTime(2026, 9, 21, 14, 20);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 默认开启全部功能的设备偏好。
    final SharedPreferences preferences = await _preferences(
      <String, Object>{},
    );

    // 显式管理的测试依赖容器。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: preferences,
      now: now,
    );

    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-context-events')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-context-inventory')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-context-memberships')),
      findsOneWidget,
    );
    // 空周期事件分区中的展开按钮。
    final Finder emptyEventToggle = find.descendant(
      of: find.byKey(const ValueKey<String>('home-context-events')),
      matching: find.byType(IconButton),
    );
    expect(emptyEventToggle, findsOneWidget);

    await tester.tap(emptyEventToggle);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsOneWidget,
    );

    await _disposeApp(tester, database, container);
  });

  testWidgets('仅开启物品功能时今日脉络整卡隐藏', (WidgetTester tester) async {
    // 测试当前时间。
    final DateTime now = DateTime(2026, 9, 21, 14, 20);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 仅保留物品管理功能。
    final SharedPreferences preferences = await _preferences(<String, Object>{
      'features.events.enabled': false,
      'features.memberships.enabled': false,
      'features.inventory.enabled': true,
    });

    // 显式管理的测试依赖容器。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: preferences,
      now: now,
    );

    expect(
      find.byKey(const ValueKey<String>('home-context-card')),
      findsNothing,
    );

    await _disposeApp(tester, database, container);
  });

  testWidgets('临近事件与会员到期提醒以父子树默认展开并可收起', (WidgetTester tester) async {
    // 测试当前时间。
    final DateTime now = DateTime(2026, 9, 21, 14, 20);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用事件仓储。
    final EventRepository eventRepository = EventRepository(database);
    await eventRepository.save(
      EventDraft(
        name: '更换空气滤芯',
        intervalValue: 10,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: DateTime(2026, 9, 15, 9),
        reminderEnabled: true,
        reminderDaysBefore: 7,
      ),
    );
    // 测试用会员仓储。
    final MembershipRepository membershipRepository = MembershipRepository(
      database,
    );
    await membershipRepository.save(
      MembershipDraft(
        name: '设计工具会员',
        priceCents: 9600,
        purchaseDate: DateTime(2026, 8, 25),
        expirationDate: DateTime(2026, 9, 25),
        isPermanent: false,
        autoRenew: false,
      ),
    );
    // 测试用设备偏好。
    final SharedPreferences preferences = await _preferences(
      <String, Object>{},
    );

    // 显式管理的测试依赖容器。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: preferences,
      now: now,
    );

    expect(find.text('更换空气滤芯'), findsOneWidget);
    expect(find.text('设计工具会员'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('context-tree-branch-周期事件-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('context-tree-branch-会员提醒-0')),
      findsOneWidget,
    );
    expect(find.textContaining('即将到期'), findsWidgets);
    // 会员父项标题右边缘。
    final double membershipTitleRight = tester
        .getTopRight(find.text('会员提醒'))
        .dx;
    // 会员子项数量标签左边缘。
    final double membershipCountLeft = tester
        .getTopLeft(
          find.byKey(const ValueKey<String>('home-context-count-会员提醒')),
        )
        .dx;
    expect(
      membershipCountLeft - membershipTitleRight,
      closeTo(OmniSpacing.xs, 0.1),
    );
    // 今日脉络父项悬停背景的圆角。
    final InkWell contextParentInkWell = tester.widget<InkWell>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('home-context-memberships')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(
      contextParentInkWell.borderRadius,
      BorderRadius.circular(OmniRadius.control),
    );
    // 今日脉络子项悬停背景的圆角。
    final InkWell contextChildInkWell = tester.widget<InkWell>(
      find
          .ancestor(of: find.text('设计工具会员'), matching: find.byType(InkWell))
          .first,
    );
    expect(
      contextChildInkWell.borderRadius,
      BorderRadius.circular(OmniRadius.control),
    );

    await tester.tap(find.text('周期事件'));
    await tester.pumpAndSettle();
    expect(find.text('更换空气滤芯'), findsNothing);
    expect(find.text('设计工具会员'), findsOneWidget);

    await tester.tap(find.text('会员提醒'));
    await tester.pumpAndSettle();
    expect(find.text('设计工具会员'), findsNothing);

    await tester.tap(find.text('周期事件'));
    await tester.tap(find.text('会员提醒'));
    await tester.pumpAndSettle();
    expect(find.text('更换空气滤芯'), findsOneWidget);
    expect(find.text('设计工具会员'), findsOneWidget);
    // 展开后同一行三张卡片仍保持底边齐平。
    final double expandedContextHeight = tester
        .getSize(find.byKey(const ValueKey<String>('home-context-card')))
        .height;
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('home-todo-card')))
          .height,
      closeTo(expandedContextHeight, 0.1),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('home-time-status-card')))
          .height,
      closeTo(expandedContextHeight, 0.1),
    );

    await _disposeApp(tester, database, container);
  });

  testWidgets('空首页可以通过管理面板重新添加卡片', (WidgetTester tester) async {
    // 测试当前时间。
    final DateTime now = DateTime(2026, 9, 21, 14, 20);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 清空首页卡片的设备偏好。
    final SharedPreferences preferences = await _preferences(<String, Object>{
      'home.cards.order': <String>[],
    });

    // 显式管理的测试依赖容器。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: preferences,
      now: now,
    );

    expect(
      find.byKey(const ValueKey<String>('home-dashboard-empty')),
      findsOneWidget,
    );
    await tester.tap(find.text('添加卡片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('管理卡片'), findsWidgets);

    await tester.tap(find.byTooltip('添加每日名言'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('home-quote-card')),
      findsOneWidget,
    );

    await _disposeApp(tester, database, container);
  });

  testWidgets('时间状态展示跨天、已完成和进行中记录', (WidgetTester tester) async {
    // 测试当前时间。
    final DateTime now = DateTime(2026, 9, 21, 14, 20);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用时间记录仓储。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    await repository.save(
      TimeEntryDraft(
        startedAt: DateTime(2026, 9, 20, 23, 30),
        endedAt: DateTime(2026, 9, 21, 7),
        activity: '睡眠',
        category: '休息',
      ),
    );
    await repository.save(
      TimeEntryDraft(
        startedAt: DateTime(2026, 9, 21, 9),
        endedAt: DateTime(2026, 9, 21, 10, 30),
        activity: '项目开发',
        category: '工作',
      ),
    );
    await repository.save(
      TimeEntryDraft(
        startedAt: DateTime(2026, 9, 21, 13),
        activity: '需求整理',
        category: '工作',
      ),
    );
    // 用于验证记录行圆角和左右留白的进行中记录。
    final TimeEntryRecord ongoingRecord =
        (await database.select(database.timeEntries).get()).firstWhere(
          (TimeEntryRecord record) => record.activity == '需求整理',
        );
    // 测试用设备偏好。
    final SharedPreferences preferences = await _preferences(
      <String, Object>{},
    );

    // 显式管理的测试依赖容器。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: preferences,
      now: now,
    );

    expect(find.text('需求整理'), findsOneWidget);
    expect(find.text('项目开发'), findsOneWidget);
    expect(find.text('睡眠'), findsOneWidget);
    expect(find.textContaining('进行中'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('今日记录.*主要用于|今日记录.*工作|今日记录')),
      findsOneWidget,
    );
    // 时间状态中的进行中记录行。
    final Finder timeEntryRow = find.byKey(
      ValueKey<String>('home-time-entry-${ongoingRecord.id}'),
    );
    // 时间记录行的悬停交互区域。
    final InkWell timeEntryInkWell = tester.widget<InkWell>(
      find.descendant(of: timeEntryRow, matching: find.byType(InkWell)),
    );
    expect(
      timeEntryInkWell.borderRadius,
      BorderRadius.circular(OmniRadius.control),
    );
    // 时间记录行、左侧色点和右侧时长的位置。
    final Rect timeEntryRect = tester.getRect(timeEntryRow);
    final Rect leadingRect = tester.getRect(
      find.byKey(
        ValueKey<String>('home-time-entry-leading-${ongoingRecord.id}'),
      ),
    );
    final Rect trailingRect = tester.getRect(
      find.byKey(
        ValueKey<String>('home-time-entry-trailing-${ongoingRecord.id}'),
      ),
    );
    expect(leadingRect.left - timeEntryRect.left, closeTo(OmniSpacing.sm, 0.1));
    expect(
      timeEntryRect.right - trailingRect.right,
      closeTo(OmniSpacing.sm, 0.1),
    );

    await _disposeApp(tester, database, container);
  });

  testWidgets('时间状态开始与补记在首页原地打开弹窗', (WidgetTester tester) async {
    // 测试当前时间。
    final DateTime now = DateTime(2026, 9, 21, 14, 20);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用设备偏好。
    final SharedPreferences preferences = await _preferences(
      <String, Object>{},
    );

    // 显式管理的测试依赖容器。
    final ProviderContainer container = await _pumpApp(
      tester,
      database: database,
      preferences: preferences,
      now: now,
    );

    expect(find.byTooltip('打开时间管理'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('home-time-start-button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsOneWidget,
    );
    expect(find.text('开始记录'), findsWidgets);
    expect(find.text('结束时间'), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('home-time-backfill-button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsOneWidget,
    );
    expect(find.text('补记一段时间'), findsOneWidget);
    expect(find.text('开始日期'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('time-range-slider')),
      findsOneWidget,
    );

    await _disposeApp(tester, database, container);
  });
}

/// 创建带指定初始值的测试偏好存储。
Future<SharedPreferences> _preferences(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

/// 在桌面视口加载带测试依赖的完整应用。
Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  required AppDatabase database,
  required SharedPreferences preferences,
  required DateTime now,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  // 显式管理的测试依赖容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(now),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OmniButlerApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return container;
}

/// 卸载测试应用并释放数据库与视口覆盖。
Future<void> _disposeApp(
  WidgetTester tester,
  AppDatabase database,
  ProviderContainer container,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  container.dispose();
  await tester.pump(const Duration(milliseconds: 100));
  await database.close();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  debugDefaultTargetPlatformOverride = null;
}
