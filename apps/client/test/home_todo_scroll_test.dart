import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证真实首页中待办的默认折叠、固定标题与独立滚动行为。
void main() {
  // 分别覆盖桌面正常高度、矮窗口与手机独立模块滚动。
  for (final (TargetPlatform, Size) scenario in <(TargetPlatform, Size)>[
    (TargetPlatform.windows, const Size(1440, 900)),
    (TargetPlatform.windows, const Size(1440, 440)),
    (TargetPlatform.android, const Size(412, 915)),
  ]) {
    testWidgets('首页全部象限任务可滚动到末项并完成 ${scenario.$1} ${scenario.$2}', (
      WidgetTester tester,
    ) async {
      // 使用真实数据库和仓储检验数量限制、滚动与完成行为。
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      // 页面订阅的生产待办仓储。
      final TodoRepository repository = TodoRepository(database);
      // 首页已有的三个重点象限。
      const List<TodoPriorityQuadrant> quadrants = <TodoPriorityQuadrant>[
        TodoPriorityQuadrant.urgentImportant,
        TodoPriorityQuadrant.importantNotUrgent,
        TodoPriorityQuadrant.urgentNotImportant,
      ];
      // 每个象限都超过原来的三条限制。
      for (final TodoPriorityQuadrant quadrant in quadrants) {
        // 根任务在本象限内的顺序。
        for (int index = 1; index <= 12; index++) {
          await repository.save(
            TodoDraft(
              title: '${quadrant.label}完整任务 $index',
              scheduledDate: DateTime(2026, 10, 6),
              priorityQuadrant: quadrant,
            ),
          );
        }
      }
      await _pumpHome(
        tester,
        database: database,
        size: scenario.$2,
        platform: scenario.$1,
        useDefaultCards: true,
      );
      if (scenario.$1 == TargetPlatform.android) {
        // 默认首页首模块为刻度，待办内容通过标签进入。
        await tester.tap(
          find.byKey(const ValueKey<String>('home-mobile-tab-todos')),
        );
        await tester.pumpAndSettle();
      }
      // 三个象限均保留全部十二条任务，并沿用仓储排序。
      for (final TodoPriorityQuadrant quadrant in quadrants) {
        // 当前逐项检查的任务顺序。
        for (int index = 1; index <= 12; index++) {
          expect(find.text('${quadrant.label}完整任务 $index'), findsOneWidget);
        }
        expect(
          tester.getTopLeft(find.text('${quadrant.label}完整任务 4')).dy,
          lessThan(tester.getTopLeft(find.text('${quadrant.label}完整任务 12')).dy),
        );
      }
      expect(find.textContaining('还有'), findsNothing);
      // 完成最后一个象限末项，确认超出旧限制的任务仍可操作。
      final TodoRecord last = (await database.select(database.todoItems).get())
          .singleWhere((TodoRecord row) => row.title == '紧急·不重要完整任务 12');
      // 最末项的生产完成入口。
      final Finder checkbox = find.byKey(
        ValueKey<String>('home-todo-checkbox-action-${last.id}'),
      );
      await tester.ensureVisible(checkbox);
      await tester.pumpAndSettle();
      expect(checkbox.hitTestable(), findsOneWidget);
      await tester.tap(checkbox);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        (await database.select(database.todoItems).get())
            .singleWhere((TodoRecord row) => row.id == last.id)
            .isCompleted,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('真实桌面首页时间卡复用独立滚动作用域并保留全部记录', (WidgetTester tester) async {
    // 在完整首页网格中验证真实仓储数据，不只挂载独立卡片。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 通过生产仓储保存二十条今日记录。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    for (int index = 0; index < 20; index++) {
      await repository.save(
        TimeEntryDraft(
          startedAt: DateTime(2026, 10, 6, 0, index * 30),
          endedAt: DateTime(2026, 10, 6, 0, index * 30 + 20),
          activity: '完整首页时间记录 $index',
          category: '开发',
        ),
      );
    }
    await _pumpHome(tester, database: database, useDefaultCards: true);
    // 卡片内只能有一个滚动条和一个实际连接的控制器。
    final Finder scrollbar = find.descendant(
      of: find.byKey(const ValueKey<String>('home-time-status-card')),
      matching: find.byType(Scrollbar),
    );
    expect(scrollbar, findsOneWidget);
    // 标题与操作按钮的固定位置。
    final Rect headerBefore = tester.getRect(
      find.byKey(const ValueKey<String>('home-time-header')),
    );
    // 实际首页提供的滚动控制器。
    final ScrollController controller = tester
        .widget<Scrollbar>(scrollbar)
        .controller!;
    expect(controller.positions.length, 1);
    expect(controller.position.maxScrollExtent, greaterThan(0));
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('完整首页时间记录 0').hitTestable(), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('home-time-header'))),
      headerBefore,
    );
    expect(find.textContaining('查看全部'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('桌面首页滚动内容时标题与新增固定，窗口缩放后仍可操作', (WidgetTester tester) async {
    // 使用真实仓储生成足量待办，避免仅检查组件属性。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 可交互展开的三个根任务。
    final List<TodoRecord> roots = await _seedTodoTrees(database);
    await _pumpHome(tester, database: database);
    expect(find.text('第1组子任务 1'), findsNothing);
    await _expandTrees(tester, roots);
    await _verifyFixedHeaderScrolling(tester);

    // 模拟窗口缩小并切换到 125% 显示缩放，逻辑尺寸为 1024×720。
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.25;
    await tester.pumpAndSettle();
    await _expandTrees(tester, roots);
    await _verifyFixedHeaderScrolling(tester);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('矮窗口仍为待办固定标题与可滚动内容保留有效空间', (WidgetTester tester) async {
    // 使用默认首页卡片顺序复现上排卡片占据视口的情形。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 子任务内容在展开后足以超过最小滚动区域。
    final List<TodoRecord> roots = await _seedTodoTrees(database);
    await _pumpHome(
      tester,
      database: database,
      size: const Size(1440, 440),
      useDefaultCards: true,
    );
    expect(tester.takeException(), isNull);
    // 固定标题和独立滚动区域不能在矮窗口中得到负高度。
    final Finder card = find.byKey(const ValueKey<String>('home-todo-card'));
    // 待办卡片唯一内部滚动条。
    final Finder scrollbar = find.descendant(
      of: card,
      matching: find.byType(Scrollbar),
    );
    expect(scrollbar, findsOneWidget);
    expect(tester.getSize(card).height, greaterThanOrEqualTo(120));
    expect(tester.getSize(scrollbar).height, greaterThan(0));
    await tester.ensureVisible(
      find.byKey(ValueKey<String>('home-todo-tree-toggle-${roots.first.id}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('home-todo-tree-toggle-${roots.first.id}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('第1组子任务 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(scrollbar).height, greaterThan(0));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('移动端展开较长待办后仅正文滚动且模块导航固定', (WidgetTester tester) async {
    // 移动端也使用真实待办树与完整首页。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 提供至少一个可展开的长任务树。
    final List<TodoRecord> roots = await _seedTodoTrees(database);
    await _pumpHome(
      tester,
      database: database,
      size: const Size(412, 915),
      platform: TargetPlatform.android,
      useDefaultCards: true,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('home-mobile-tab-todos')),
    );
    await tester.pumpAndSettle();
    expect(find.text('第1组子任务 1'), findsNothing);
    await tester.tap(
      find.byKey(ValueKey<String>('home-todo-tree-toggle-${roots.first.id}')),
    );
    await tester.pumpAndSettle();
    // 待办模块内部只使用一个正文滚动容器。
    final Finder card = find.byKey(const ValueKey<String>('home-todo-card'));
    expect(
      find.descendant(of: card, matching: find.byType(Scrollbar)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.byType(Scrollable)),
      findsOneWidget,
    );
    // 模块导航不随任务正文滚动，重复标题已删除。
    expect(
      find.byKey(const ValueKey<String>('home-todo-header')),
      findsNothing,
    );
    final Finder header = find.byKey(
      const ValueKey<String>('home-mobile-tabs'),
    );
    // 仍位于屏幕内的首条子任务。
    final Finder firstChild = find.text('第1组子任务 1');
    // 滚动前固定记录两个元素的位置。
    final double headerBefore = tester.getTopLeft(header).dy;
    // 首条子任务的起始纵坐标。
    final double childBefore = tester.getTopLeft(firstChild).dy;
    await tester.dragFrom(tester.getCenter(firstChild), const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, closeTo(headerBefore, 0.1));
    expect(tester.getTopLeft(firstChild).dy - childBefore, lessThan(-30));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

/// 使用生产仓储创建三个根任务，每个包含十二条未完成子任务。
Future<List<TodoRecord>> _seedTodoTrees(AppDatabase database) async {
  // 所有任务使用固定日期，避免依赖执行机器时间。
  final DateTime now = DateTime(2026, 10, 6, 14);
  // 生产待办仓储。
  final TodoRepository repository = TodoRepository(database);
  // 依次保存的根任务记录。
  final List<TodoRecord> roots = <TodoRecord>[];
  // 每个根任务单独建树以保留真实父子关系。
  for (int rootIndex = 1; rootIndex <= 3; rootIndex += 1) {
    await repository.save(
      TodoDraft(
        title: '第$rootIndex组根任务',
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // 从数据库读取刚新增的根任务身份。
    final TodoRecord root = (await database.select(database.todoItems).get())
        .singleWhere((TodoRecord row) => row.title == '第$rootIndex组根任务');
    roots.add(root);
    // 每条子任务都实际保存，确保数据流和布局共同接受验证。
    for (int childIndex = 1; childIndex <= 12; childIndex += 1) {
      await repository.save(
        TodoDraft(
          title: '第$rootIndex组子任务 $childIndex',
          parentId: root.id,
          scheduledDate: now,
        ),
      );
    }
  }
  return roots;
}

/// 从后向前手动展开任务树，防止前面增长的内容遮挡后面的按钮。
Future<void> _expandTrees(WidgetTester tester, List<TodoRecord> roots) async {
  // 逐项展开尚未展开的任务，也允许缩放后保留已有展开状态。
  for (final TodoRecord root in roots.reversed) {
    if (find
        .byKey(ValueKey<String>('home-todo-tree-children-${root.id}'))
        .evaluate()
        .isNotEmpty) {
      continue;
    }
    // 当前根任务的真实交互按钮。
    final Finder toggle = find.byKey(
      ValueKey<String>('home-todo-tree-toggle-${root.id}'),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }
}

/// 使用鼠标滚轮验证正文移动、固定标题、滚动条边界和新增操作。
Future<void> _verifyFixedHeaderScrolling(WidgetTester tester) async {
  // 待办整卡边界。
  final Finder card = find.byKey(const ValueKey<String>('home-todo-card'));
  // 固定标题区域。
  final Finder header = find.byKey(const ValueKey<String>('home-todo-header'));
  // 固定标题中的新增操作。
  final Finder createButton = find.byKey(
    const ValueKey<String>('home-todo-create-button'),
  );
  // 内容区域保留右侧留白，避免滚动条覆盖任务。
  final Finder content = find.byKey(
    const ValueKey<String>('home-todo-content'),
  );
  // 待办卡内唯一显式滚动条。
  final Finder scrollbar = find.descendant(
    of: card,
    matching: find.byType(Scrollbar),
  );
  expect(scrollbar, findsOneWidget);
  // 鼠标落点位于卡片滚动视口内。
  final Offset scrollPoint = tester.getCenter(scrollbar);
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: scrollPoint,
      scrollDelta: const Offset(0, -5000),
    ),
  );
  await tester.pumpAndSettle();
  // 滚动条的渲染盒覆盖整个卡片宽度，而非缩在内容留白内。
  final Rect cardRect = tester.getRect(card);
  // 滚动视口的真实边界。
  final Rect scrollbarRect = tester.getRect(scrollbar);
  expect(scrollbarRect.right, closeTo(cardRect.right, 0.1));
  expect(
    cardRect.right - tester.getRect(content).right,
    greaterThanOrEqualTo(16),
  );
  // 验证窄边缘滚动条的位置，主轴与内容留白各自独立。
  final ScrollbarThemeData scrollbarTheme = ScrollbarTheme.of(
    tester.element(scrollbar),
  );
  expect(scrollbarTheme.crossAxisMargin, 2);
  // 标题在滚动前的实际位置。
  final Rect headerBefore = tester.getRect(header);
  // 新增按钮在滚动前的实际位置。
  final Rect createBefore = tester.getRect(createButton);
  // 第一项内容的实际位置，即使滚出视口仍可测量。
  final double childBefore = tester.getTopLeft(find.text('第1组子任务 1')).dy;
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: scrollPoint,
      scrollDelta: const Offset(0, 220),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.getRect(header), headerBefore);
  expect(tester.getRect(createButton), createBefore);
  expect(
    tester.getTopLeft(find.text('第1组子任务 1')).dy,
    lessThan(childBefore - 100),
  );
  await tester.tap(createButton);
  await tester.pumpAndSettle();
  expect(find.text('新增待办'), findsOneWidget);
  await tester.tap(find.text('取消'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// 挂载带真实路由、数据库和主题的完整应用。
Future<void> _pumpHome(
  WidgetTester tester, {
  required AppDatabase database,
  Size size = const Size(1440, 900),
  TargetPlatform platform = TargetPlatform.windows,
  bool useDefaultCards = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (!useDefaultCards) 'home.cards.order': <String>['todos', 'todayContext'],
  });
  // 实际设备偏好提供者使用的内存存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 只覆盖外部依赖，所有首页逻辑与待办数据流沿用生产实现。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 10, 6, 14)),
    ],
  );
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    debugDefaultTargetPlatformOverride = null;
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OmniButlerApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}
