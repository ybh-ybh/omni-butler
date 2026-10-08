import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_mobile_dashboard.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证真实待办页面的视口、分页恢复与手势接管。
void main() {
  _todoTest('隐藏待办从零宽恢复后不会继续执行过期标签滚动', (WidgetTester tester) async {
    // 模拟Android引擎在真实尺寸到达前预载隐藏待办。
    await tester.pumpWidget(_startupDashboard(width: 0, visible: false));
    await tester.pump();
    // 尺寸已到达，但底栏尚未进入待办，Ticker仍被关闭。
    await tester.pumpWidget(_startupDashboard(width: 390, visible: false));
    await tester.pump(const Duration(milliseconds: 500));
    // 进入待办后不能恢复零宽时错误的标签动画。
    await tester.pumpWidget(_startupDashboard(width: 390, visible: true));
    await tester.pumpAndSettle();
    // 检查真实标签滚动位置和选中标签可见性。
    final SingleChildScrollView tabs = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey<String>('todo-mobile-tabs-scroll')),
    );
    expect(tabs.controller!.offset, 0);
    expect(
      find
          .byKey(const ValueKey<String>('todo-mobile-quadrant-all'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  _todoTest('分类角标只统计父任务并随完成与重新打开更新', (WidgetTester tester) async {
    // 导航角标合并朗读后仍需保留读屏点击操作。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      // 24个进行中根任务、1个子任务和1条历史记录不能混算。
      final _TodoFixture fixture = await _startTodos(tester);
      // 使用生产仓储触发真实订阅更新。
      final TodoRepository repository = fixture.container.read(
        todoRepositoryProvider,
      );
      expect(_countLabel(tester, 3), '24');
      // 其余三个空分类不生成角标节点。
      for (final int quadrant in <int>[2, 1, 0]) {
        expect(
          find.byKey(ValueKey<String>('todo-mobile-count-$quadrant')),
          findsNothing,
        );
      }
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey<String>('todo-mobile-quadrant-3')),
        ),
        matchesSemantics(
          label: '立即处理，24 个父任务',
          isButton: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      // 角标应自然贴合数字，不能拉满整个导航高度。
      expect(
        tester
            .getSize(find.byKey(const ValueKey<String>('todo-mobile-count-3')))
            .height,
        lessThan(24),
      );
      expect(
        find.byKey(const ValueKey<String>('todo-mobile-count-all')),
        findsNothing,
      );
      await repository.save(
        TodoDraft(
          title: '第二个子任务',
          parentId: fixture.root.id,
          scheduledDate: DateTime(2026, 10, 8),
        ),
      );
      await tester.pumpAndSettle();
      expect(_countLabel(tester, 3), '24');
      // 子任务仅改变父行进度，不增加根数量。
      final TodoRecord child =
          await (fixture.container
                  .read(appDatabaseProvider)
                  .select(fixture.container.read(appDatabaseProvider).todoItems)
                ..where((TodoItems table) => table.title.equals('第二个子任务')))
              .getSingle();
      await repository.setCompleted(child.id, true);
      await tester.pumpAndSettle();
      expect(_countLabel(tester, 3), '24');
      await repository.setCompleted(fixture.root.id, true);
      await tester.pumpAndSettle();
      expect(_countLabel(tester, 3), '23');
      await repository.setCompleted(fixture.root.id, false);
      await tester.pumpAndSettle();
      expect(_countLabel(tester, 3), '24');
      // 空分类新增后显示角标，完成最后一项隐藏，重新打开后恢复。
      await repository.save(
        TodoDraft(
          title: '安排时间唯一父任务',
          scheduledDate: DateTime(2026, 10, 8),
          priorityQuadrant: TodoPriorityQuadrant.importantNotUrgent,
        ),
      );
      await tester.pumpAndSettle();
      expect(_countLabel(tester, 2), '1');
      // 通过真实记录身份验证从非空变为空时的订阅刷新。
      final AppDatabase database = fixture.container.read(appDatabaseProvider);
      // 当前分类唯一的父任务。
      final TodoRecord scheduled =
          await (database.select(database.todoItems)
                ..where((TodoItems table) => table.title.equals('安排时间唯一父任务')))
              .getSingle();
      await repository.setCompleted(scheduled.id, true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('todo-mobile-count-2')),
        findsNothing,
      );
      await repository.setCompleted(scheduled.id, false);
      await tester.pumpAndSettle();
      expect(_countLabel(tester, 2), '1');
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  _todoTest('冷启动从底栏进入待办时全部标签完整可见', (WidgetTester tester) async {
    await _startTodos(tester, openTodos: false);
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/todos')));
    await tester.pumpAndSettle();
    expect(_selected(tester), isNull);
    expect(_pager(tester).page, 0);
    // 首次进入的标签行不能继承其他滚动视口的偏移。
    final SingleChildScrollView tabs = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey<String>('todo-mobile-tabs-scroll')),
    );
    expect(tabs.controller!.offset, 0);
    expect(
      find
          .byKey(const ValueKey<String>('todo-mobile-quadrant-all'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  _todoTest('短屏双倍字号完整展示历史年月日且日期仍可选择', (WidgetTester tester) async {
    await _startTodos(tester, seedTasks: false);
    tester.view.physicalSize = const Size(320, 360);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-history-open')),
    );
    await tester.pumpAndSettle();
    // 读取实际日期内容与文字布局，不能只检查容器没有越界。
    final Finder picker = find.byKey(
      const ValueKey<String>('todo-mobile-history-date-picker'),
    );
    // 日期的全部信息必须保留在可见文字中。
    final Text label = tester.widget<Text>(
      find.descendant(of: picker, matching: find.byType(Text)),
    );
    expect(label.data, contains('2026'));
    expect(label.data, contains('10'));
    expect(label.data, contains('8'));
    // 验证绘制时没有因省略号丢失日期。
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: picker, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    // 沿用现有锚定日历，真实点按下一天并提交。
    await tester.tap(find.text('9').hitTestable());
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TodoMobileDashboard>(find.byType(TodoMobileDashboard))
          .selectedDay,
      DateTime(2026, 10, 9),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-pager')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  _todoTest('窄屏大字号的标签完整可滚动且空分组仅保留一行', (WidgetTester tester) async {
    // 不播种任务，以真实空分类检查最小占位。
    final _TodoFixture fixture = await _startTodos(tester, seedTasks: false);
    for (final double width in <double>[320, 360, 390]) {
      tester.view.physicalSize = Size(width, 360);
      for (final double scale in <double>[1, 2]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        for (final ThemeMode mode in <ThemeMode>[
          ThemeMode.light,
          ThemeMode.dark,
        ]) {
          await fixture.container
              .read(themeControllerProvider.notifier)
              .setThemeMode(mode);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            find
                .byKey(const ValueKey<String>('todo-mobile-history-open'))
                .hitTestable(),
            findsOneWidget,
          );
          expect(find.text('暂无进行中任务'), findsNothing);
          expect(
            find.byKey(const ValueKey<String>('todo-quadrant-toggle-all-3')),
            findsNothing,
          );
          // 空分组与添加按钮同高，大字号也不出现大块空态。
          expect(
            tester
                .getSize(
                  find.byKey(const ValueKey<String>('todo-quadrant-card-3')),
                )
                .height,
            48,
          );
          // 分组新增操作贴齐内容右边，不因标题弹性占位而向中间漂移。
          expect(
            tester
                .getRect(
                  find
                      .byKey(const ValueKey<String>('todo-quadrant-create-3'))
                      .hitTestable(),
                )
                .right,
            closeTo(width - 8, 0.5),
          );
        }
      }
    }
    // 导航滚动至末尾后完整显示分类，不缩小字号。
    await tester.drag(
      find.byKey(const ValueKey<String>('todo-mobile-tabs-scroll')),
      const Offset(-900, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('有空再做').hitTestable(), findsWidgets);
    await tester.tap(
      find
          .byKey(const ValueKey<String>('todo-mobile-quadrant-0'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无进行中任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-history-open')),
    );
    await tester.pumpAndSettle();
    expect(find.text('完成历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _todoTest('分类独立滚动且历史与底栏往返保留树展开和日期', (WidgetTester tester) async {
    // 足量真实任务使全部和单分类都有独立的滚动范围。
    final _TodoFixture fixture = await _startTodos(tester);
    await tester.tap(
      find
          .byKey(ValueKey<String>('todo-title-${fixture.root.id}'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('需要保留展开状态的子任务'), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey<String>('todo-mobile-page-all')),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    // 全部页的位置在独立分类滚动后仍应保持。
    final double allOffset = _verticalController(tester, 'all').offset;
    expect(allOffset, greaterThan(100));
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-quadrant-3')),
    );
    await tester.pumpAndSettle();
    expect(_verticalController(tester, '3').offset, 0);
    expect(find.text('需要保留展开状态的子任务'), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey<String>('todo-mobile-page-3')),
      const Offset(0, -350),
    );
    await tester.pumpAndSettle();
    // 本分类的滚动位置，随后打开历史和离开底栏。
    final double quadrantOffset = _verticalController(tester, '3').offset;
    expect(quadrantOffset, greaterThan(100));
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-history-open')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-mobile-create')),
      findsNothing,
    );
    // 历史继续复用无卡片的父任务分组。
    final OmniPanel historyGroup = tester.widget<OmniPanel>(
      find.byKey(
        ValueKey<String>('todo-history-group-${fixture.completed.id}'),
      ),
    );
    expect(historyGroup.flat, isTrue);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-history-next-day')),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      fixture.container
          .read(appRouterProvider)
          .routeInformationProvider
          .value
          .uri
          .path,
      '/todos',
    );
    expect(_selected(tester), TodoPriorityQuadrant.urgentImportant);
    expect(_verticalController(tester, '3').offset, closeTo(quadrantOffset, 1));
    await tester.tap(find.text('时间').hitTestable().last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('待办').hitTestable().last);
    await tester.pumpAndSettle();
    expect(_selected(tester), TodoPriorityQuadrant.urgentImportant);
    expect(_verticalController(tester, '3').offset, closeTo(quadrantOffset, 1));
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-history-open')),
    );
    await tester.pumpAndSettle();
    expect(find.text('2026 年 10 月 9 日'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-history-back')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-quadrant-all')),
    );
    await tester.pumpAndSettle();
    expect(_verticalController(tester, 'all').offset, closeTo(allOffset, 1));
  });

  _todoTest('标签动画未跨半页时反向打断后标签仍与正文一致', (WidgetTester tester) async {
    await _startTodos(tester, seedTasks: false);
    await tester.drag(
      find.byKey(const ValueKey<String>('todo-mobile-tabs-scroll')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-quadrant-0')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(_pager(tester).page, lessThan(0.5));
    await tester.drag(
      find.byKey(const ValueKey<String>('todo-mobile-pager')),
      const Offset(240, 0),
    );
    await tester.pumpAndSettle();
    expect(_pager(tester).page, 0);
    expect(_selected(tester), isNull);
    expect(
      find
          .byKey(const ValueKey<String>('todo-mobile-quadrant-all'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  _todoTest('分类动画开始前立即点回全部不会继续进入旧分类', (WidgetTester tester) async {
    await _startTodos(tester, seedTasks: false);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-quadrant-3')),
    );
    // 动画已建立但尚未平移，此时全部仍是正文的真实位置。
    await tester.pump();
    await tester.pump();
    expect(_pager(tester).position.isScrollingNotifier.value, isTrue);
    expect(_pager(tester).page, 0);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-mobile-quadrant-all')),
    );
    await tester.pumpAndSettle();
    expect(_selected(tester), isNull);
    expect(_pager(tester).page, 0);
    expect(tester.takeException(), isNull);
  });

  _todoTest('减少动画时选择末分类和路由指定分类即时落位', (WidgetTester tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    // 无动画模式需要同时检查正文和标签滚动，不能传零时长 animateTo。
    final _TodoFixture fixture = await _startTodos(tester, seedTasks: false);
    fixture.container.read(appRouterProvider).go('/todos?quadrant=0');
    await tester.pumpAndSettle();
    expect(_pager(tester).page, 4);
    expect(_selected(tester), TodoPriorityQuadrant.neitherUrgentNorImportant);
    expect(
      find
          .byKey(const ValueKey<String>('todo-mobile-quadrant-0'))
          .hitTestable(),
      findsOneWidget,
    );
    fixture.container.read(appRouterProvider).go('/todos?quadrant=2');
    await tester.pumpAndSettle();
    expect(_pager(tester).page, 2);
    expect(_selected(tester), TodoPriorityQuadrant.importantNotUrgent);
    expect(tester.takeException(), isNull);
  });

  _todoTest('正文连续快滑和反向接管不会重启标签动画', (WidgetTester tester) async {
    await _startTodos(tester, seedTasks: false);
    await tester.fling(
      find.byKey(const ValueKey<String>('todo-mobile-pager')),
      const Offset(-250, 0),
      1800,
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.fling(
      find.byKey(const ValueKey<String>('todo-mobile-pager')),
      const Offset(-250, 0),
      1800,
    );
    await tester.pumpAndSettle();
    expect(_pager(tester).page, 2);
    expect(_selected(tester), TodoPriorityQuadrant.importantNotUrgent);
    await tester.fling(
      find.byKey(const ValueKey<String>('todo-mobile-pager')),
      const Offset(250, 0),
      1800,
    );
    await tester.pumpAndSettle();
    expect(_pager(tester).page, 1);
    expect(_selected(tester), TodoPriorityQuadrant.urgentImportant);
    expect(tester.takeException(), isNull);
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    _todoTest('$platform 窄布局仍使用原有待办呈现', (WidgetTester tester) async {
      await _startTodos(tester, seedTasks: false);
      expect(find.byType(TodoMobileDashboard), findsNothing);
      expect(find.text('完成历史'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, platform: platform);
  }
}

/// 复用真实仪表盘，模拟引擎启动时的零宽隐藏视口与Ticker状态。
Widget _startupDashboard({required double width, required bool visible}) =>
    MaterialApp(
      theme: AppTheme.build(brightness: Brightness.light),
      home: Align(
        alignment: Alignment.topLeft,
        child: Offstage(
          offstage: !visible,
          child: TickerMode(
            enabled: visible,
            child: SizedBox(
              width: width,
              height: 700,
              child: TodoMobileDashboard(
                selectedQuadrant: null,
                quadrantCounts: const <TodoPriorityQuadrant, int>{},
                showingHistory: false,
                selectedDay: DateTime(2026, 10, 8),
                today: DateTime(2026, 10, 8),
                onQuadrantSelected: (_) {},
                onHistoryChanged: (_) {},
                onDaySelected: (_) {},
                onCreate: () {},
                activePageBuilder: (_, _) => const SizedBox.shrink(),
                history: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );

/// 由测试框架管理平台覆盖，避免测试结束前遗留调试全局变量。
void _todoTest(
  String name,
  WidgetTesterCallback callback, {
  TargetPlatform platform = TargetPlatform.android,
}) {
  testWidgets(name, (WidgetTester tester) async {
    try {
      await callback(tester);
    } finally {
      // 在框架检查计时器前卸载真实应用，停止根应用的后台协调器。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  }, variant: TargetPlatformVariant.only(platform));
}

/// 当前可见分类的正文分页控制器。
PageController _pager(WidgetTester tester) => tester
    .widget<PageView>(find.byKey(const ValueKey<String>('todo-mobile-pager')))
    .controller!;

/// 从实际页面读取当前对用户展示的分类。
TodoPriorityQuadrant? _selected(WidgetTester tester) => tester
    .widget<TodoMobileDashboard>(find.byType(TodoMobileDashboard))
    .selectedQuadrant;

/// 仅读取已构建分类的纵向位置，滚动操作仍通过真实触摸执行。
ScrollController _verticalController(WidgetTester tester, String page) => tester
    .widget<SingleChildScrollView>(
      find
          .descendant(
            of: find.byKey(ValueKey<String>('todo-mobile-page-$page')),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
    )
    .controller!;

/// 从真实导航角标读取可见数量，避免只验证传入参数。
String _countLabel(WidgetTester tester, int quadrant) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey<String>('todo-mobile-count-$quadrant')),
        matching: find.byType(Text),
      ),
    )
    .data!;

/// 启动真实路由与待办仓储，数据仅保存在测试内存中。
Future<_TodoFixture> _startTodos(
  WidgetTester tester, {
  bool seedTasks = true,
  bool openTodos = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': 'light',
  });
  // 隔离偏好与SQLite数据库。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 数据库不连接任何正式本机文件。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 通过生产仓储生成稳定身份和合法任务树。
  final TodoRepository repository = TodoRepository(database);
  if (seedTasks) {
    for (int index = 0; index < 24; index++) {
      await repository.save(
        TodoDraft(
          title: '进行中任务${index.toString().padLeft(2, '0')}',
          scheduledDate: DateTime(2026, 10, 8),
          priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
        ),
      );
    }
  }
  // 空态测试仍需合法记录供fixture类型使用，完成后不会出现在进行中。
  await repository.save(
    TodoDraft(title: '历史记录', scheduledDate: DateTime(2026, 10, 8)),
  );
  final TodoRecord completed = await (database.select(
    database.todoItems,
  )..where((TodoItems table) => table.title.equals('历史记录'))).getSingle();
  await (database.update(
    database.todoItems,
  )..where((TodoItems table) => table.id.equals(completed.id))).write(
    TodoItemsCompanion(
      isCompleted: const Value<bool>(true),
      completedAt: Value<DateTime>(DateTime(2026, 10, 8, 10)),
    ),
  );
  // 带子任务的根记录用于共享展开状态回归。
  final TodoRecord root = seedTasks
      ? await (database.select(database.todoItems)
              ..where((TodoItems table) => table.title.equals('进行中任务00')))
            .getSingle()
      : completed;
  if (seedTasks) {
    await repository.save(
      TodoDraft(
        title: '需要保留展开状态的子任务',
        parentId: root.id,
        scheduledDate: DateTime(2026, 10, 8),
      ),
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 10, 8, 12)),
        syncRuntimeProvider.overrideWithValue(null),
      ],
      child: const OmniButlerApp(),
    ),
  );
  // 主应用的真实provider与路由，供底栏和路由指定分类回归使用。
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(OmniButlerApp)),
  );
  if (openTodos) container.read(appRouterProvider).go('/todos');
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await database.close();
  });
  return _TodoFixture(container: container, root: root, completed: completed);
}

/// 测试持有的最小业务身份与路由容器。
class _TodoFixture {
  /// 生产路由使用的provider容器。
  final ProviderContainer container;

  /// 带子任务的主任务。
  final TodoRecord root;

  /// 用于平铺历史验证的已完成记录。
  final TodoRecord completed;

  /// 创建隔离测试上下文。
  const _TodoFixture({
    required this.container,
    required this.root,
    required this.completed,
  });
}
