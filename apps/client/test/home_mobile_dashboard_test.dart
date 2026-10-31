import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/home/data/home_card_preferences.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fails one user-requested quote rotation while retaining the real database.
class _FailingQuoteChangeDatabase extends AppDatabase {
  /// Whether the next rotation should fail before persistence.
  bool failChange = true;

  /// Number of accepted rotation attempts.
  int changeCalls = 0;

  /// Creates an isolated database with controllable quote rotation failures.
  _FailingQuoteChangeDatabase() : super.forTesting(NativeDatabase.memory());

  /// Delegates successful retries to the production rotation logic.
  @override
  Future<QuoteRecord?> changeQuoteForDay(DateTime day) async {
    changeCalls += 1;
    if (failChange) throw StateError('模拟名言切换失败');
    return super.changeQuoteForDay(day);
  }
}

/// 验证安卓首页真实业务模块的分页、手势隔离与本次运行状态。
void main() {
  testWidgets('首页快捷入口同排且名言单击轮换长按打开全屏库', (WidgetTester tester) async {
    // Use the real mobile page to verify touch targets and header placement.
    final _HomeTestApp app = await _pumpHome(tester);
    // Keep the shortcut order independent from optional feature route choices.
    final List<String> ids = <String>[
      'todos',
      'timeline',
      'management',
      'settings',
    ];
    // All ordinary-size shortcuts occupy one row below the quote.
    final List<Rect> bounds = ids
        .map((String id) => tester.getRect(_key('home-shortcut-$id')))
        .toList();
    expect(
      bounds.first.top,
      greaterThan(tester.getRect(_key('home-quote-card')).bottom),
    );
    for (final Rect boundsForEntry in bounds) {
      expect(boundsForEntry.size.shortestSide, greaterThanOrEqualTo(48));
      expect(
        boundsForEntry.top,
        closeTo(tester.getRect(_key('home-shortcut-todos')).top, 0.1),
      );
    }
    expect(
      bounds.map((Rect rect) => rect.left),
      orderedEquals(bounds.map((Rect rect) => rect.left).toList()..sort()),
    );
    expect(find.byTooltip('知序助手'), findsNothing);
    expect(find.byTooltip('名言库'), findsNothing);
    expect(find.byTooltip('设置横幅背景'), findsNothing);
    expect(_key('home-quote-menu'), findsNothing);
    // Attribution stays pinned to the card's padded bottom-right corner.
    final Rect quoteCard = tester.getRect(_key('home-quote-card'));
    final Rect quoteSource = tester.getRect(_key('home-quote-source'));
    expect(
      quoteCard.right - quoteSource.right,
      closeTo(OmniSpacing.sm + 1, 0.1),
    );
    expect(
      quoteCard.bottom - quoteSource.bottom,
      closeTo(OmniSpacing.sm + 1, 0.1),
    );
    // Read the persisted initial selection before exercising card gestures.
    final QuoteRecord initialQuote = (await app.database.quoteForDay(
      DateTime(2026, 10, 8),
    ))!;
    // Two immediate taps must commit only one rotation while the first is pending.
    await tester.tap(_key('home-quote-interaction'));
    await tester.tap(_key('home-quote-interaction'));
    await tester.pumpAndSettle();
    // The next quote remains visible and persisted after the guarded rotation.
    final QuoteRecord changedQuote = (await app.database.quoteForDay(
      DateTime(2026, 10, 8),
    ))!;
    expect(changedQuote.id, isNot(initialQuote.id));
    expect(find.text('“${changedQuote.content}”'), findsOneWidget);
    // Long press opens management without rotating the retained quote again.
    await tester.longPress(_key('home-quote-interaction'));
    await tester.pumpAndSettle();
    expect(_key('quote-library-fullscreen'), findsOneWidget);
    expect(_key('quote-background-action'), findsOneWidget);
    expect(_key('quote-transfer-menu'), findsOneWidget);
    expect(_key('quote-add-action'), findsOneWidget);
    expect(find.text('完成'), findsNothing);
    expect(_key('compact-navigation').hitTestable(), findsNothing);
    // The stored daily selection proves long press did not also fire the tap.
    final QuoteRecord quoteAfterLongPress = (await app.database.quoteForDay(
      DateTime(2026, 10, 8),
    ))!;
    expect(quoteAfterLongPress.id, changedQuote.id);
    await tester.tap(_key('quote-library-back'));
    await tester.pumpAndSettle();
    expect(_key('home-quote-card'), findsOneWidget);
    expect(find.text('“${changedQuote.content}”'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('320宽双倍字号的快捷入口使用两列且不裁剪文字', (WidgetTester tester) async {
    // Large system text must reflow without reducing its scale.
    final _HomeTestApp app = await _pumpHome(
      tester,
      size: const Size(320, 844),
      textScale: 2,
      cards: const <String>['todos'],
    );
    // Measure the actual laid-out controls rather than a breakpoint flag.
    final Rect todos = tester.getRect(_key('home-shortcut-todos'));
    // The second shortcut stays in the first row.
    final Rect timeline = tester.getRect(_key('home-shortcut-timeline'));
    // The remaining shortcuts wrap onto a second row.
    final Rect management = tester.getRect(_key('home-shortcut-management'));
    // Settings keeps the same second-row baseline.
    final Rect settings = tester.getRect(_key('home-shortcut-settings'));
    expect(todos.top, closeTo(timeline.top, 0.1));
    expect(management.top, greaterThanOrEqualTo(todos.bottom));
    expect(management.top, closeTo(settings.top, 0.1));
    for (final String label in <String>['全部待办', '时间记录', '管理', '设置']) {
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('隐藏名言仍显示快捷入口且功能开关即时过滤', (WidgetTester tester) async {
    // Feature shortcuts are independent from the optional home cards.
    final _HomeTestApp app = await _pumpHome(tester, cards: const <String>[]);
    expect(_key('home-quote-card'), findsNothing);
    expect(_key('home-shortcut-settings'), findsOneWidget);
    // Toggle existing preferences through their production controller.
    final FeaturePreferenceController preference = app.container.read(
      featurePreferenceProvider.notifier,
    );
    await preference.setFeatureEnabled(AppFeature.todos, false);
    await preference.setFeatureEnabled(AppFeature.timeline, false);
    await preference.setFeatureEnabled(AppFeature.inventory, false);
    await preference.setFeatureEnabled(AppFeature.memberships, false);
    await tester.pumpAndSettle();
    expect(_key('home-shortcut-todos'), findsNothing);
    expect(_key('home-shortcut-timeline'), findsNothing);
    expect(_key('home-shortcut-management'), findsOneWidget);
    await preference.setFeatureEnabled(AppFeature.events, false);
    await tester.pumpAndSettle();
    expect(_key('home-shortcut-management'), findsNothing);
    expect(_key('home-shortcut-settings').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('安卓长名言自然增高且正文不省略', (WidgetTester tester) async {
    // A single enabled quote makes the real daily selection deterministic.
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // The long text intentionally exceeds the compact banner height.
    const String content =
        '认真观察生活中的每一个细节，让记录成为理解自己的过程。'
        '把今天需要完成的事情逐一写下来，也为休息和思考留出足够的空间。'
        '在变化中保持耐心，允许每一次尝试慢慢积累成新的经验。';
    await database
        .into(database.quotes)
        .insert(
          QuotesCompanion.insert(
            id: 'long-mobile-quote',
            content: content,
            createdAt: DateTime(2026, 10, 8),
            updatedAt: DateTime(2026, 10, 8),
          ),
        );
    // Keep the default font size so growth comes from content, not text scaling.
    final _HomeTestApp app = await _pumpHome(tester, database: database);
    // Inspect the full displayed text together with its real banner bounds.
    final Text quote = tester.widget<Text>(find.text('“$content”'));
    expect(quote.maxLines, isNull);
    expect(quote.overflow, TextOverflow.visible);
    expect(tester.getSize(_key('home-quote-card')).height, greaterThan(112));
    final Rect longCard = tester.getRect(_key('home-quote-card'));
    final Rect longSource = tester.getRect(_key('home-quote-source'));
    expect(longCard.right - longSource.right, closeTo(OmniSpacing.sm + 1, 0.1));
    expect(
      longCard.bottom - longSource.bottom,
      closeTo(OmniSpacing.sm + 1, 0.1),
    );
    expect(
      tester.getRect(find.text('“$content”')).bottom,
      lessThan(longSource.top),
    );
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('空名言状态仍可长按进入全屏名言库', (WidgetTester tester) async {
    // Simulate a migrated dataset where the empty library must not be reseeded.
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await database.customStatement(
      'CREATE TABLE device_sync_metadata (id TEXT PRIMARY KEY, value TEXT)',
    );
    await database.customStatement(
      'INSERT INTO device_sync_metadata (id, value) VALUES (?, ?)',
      <Object?>[AppDatabase.suppressDefaultSeedingMetadataId, '1'],
    );
    final _HomeTestApp app = await _pumpHome(tester, database: database);
    expect(find.text('暂无可用名言，可在名言库中添加'), findsOneWidget);

    await tester.longPress(_key('home-quote-interaction'));
    await tester.pumpAndSettle();
    expect(_key('quote-library-fullscreen'), findsOneWidget);
    expect(find.text('名言库为空，首页会展示内置占位内容。'), findsOneWidget);
    expect(_key('quote-add-action').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('名言切换失败保留当前文字并允许重试', (WidgetTester tester) async {
    // The production database remains active except for the controlled failure.
    final _FailingQuoteChangeDatabase database = _FailingQuoteChangeDatabase();
    final _HomeTestApp app = await _pumpHome(tester, database: database);
    // Capture the current persisted quote before the failing request.
    final QuoteRecord initialQuote = (await database.quoteForDay(
      DateTime(2026, 10, 8),
    ))!;

    await tester.tap(_key('home-quote-interaction'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(database.changeCalls, 1);
    expect(find.text('名言切换失败，请重试'), findsOneWidget);
    expect(find.text('“${initialQuote.content}”'), findsOneWidget);
    // A later tap is accepted and advances through the same real rotation path.
    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pump();
    database.failChange = false;
    await tester.tap(_key('home-quote-interaction'));
    await tester.pumpAndSettle();
    final QuoteRecord retriedQuote = (await database.quoteForDay(
      DateTime(2026, 10, 8),
    ))!;
    expect(database.changeCalls, 2);
    expect(retriedQuote.id, isNot(initialQuote.id));
    expect(find.text('“${retriedQuote.content}”'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('各模块删除重复标题且胶囊只展开选中模块文字', (WidgetTester tester) async {
    // 包含可选刻度页，确保每个分页标题都遵循同一规则。
    final _HomeTestApp app = await _pumpHome(
      tester,
      cards: const <String>[
        'quote',
        'todos',
        'timeStatus',
        'todayContext',
        'dayRuler',
      ],
    );
    // 标题及其图标操作不再占用正文空间。
    expect(_key('home-todo-header'), findsNothing);
    expect(_key('home-time-header'), findsNothing);
    expect(_key('home-todo-toggle-all'), findsNothing);
    // 所有模块切换后仅选中项保留可见文字，背景与真实点击范围对齐。
    for (final String module in <String>[
      'todos',
      'timeStatus',
      'todayContext',
      'dayRuler',
    ]) {
      await _selectModule(tester, module);
      expect(find.text('今日待办'), findsNothing);
      expect(find.text('时间状态'), findsNothing);
      expect(find.text('今日脉络'), findsNothing);
      expect(find.text('今日刻度'), findsNothing);
      // 选中胶囊采用与待办一致的内缩边距。
      final Rect indicator = tester.getRect(_key('home-mobile-tabs-indicator'));
      // 选中模块真实热区仍保留完整文字与图标。
      final Rect selected = tester.getRect(_key('home-mobile-tab-$module'));
      expect(indicator.left, closeTo(selected.left + 4, 0.01));
      expect(indicator.right, closeTo(selected.right - 4, 0.01));
      expect(indicator.center.dy, closeTo(selected.center.dy, 0.01));
      expect(selected.height, greaterThanOrEqualTo(48));
      for (final String label in <String>[
        'todos',
        'timeStatus',
        'todayContext',
        'dayRuler',
      ]) {
        expect(
          _key('home-mobile-label-$label'),
          label == module ? findsOneWidget : findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    }
    await _disposeHome(tester, app);
  });

  testWidgets('象限批量操作覆盖第四个父任务且不改变其他象限', (WidgetTester tester) async {
    // 超过旧三条限制的父子数据用来验证实际显示范围。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 通过生产仓储保持真实父子关系和排序。
    final TodoRepository repository = TodoRepository(database);
    // 使用固定日期避免机器时间影响任务口径。
    final DateTime day = DateTime(2026, 10, 8);
    for (int index = 0; index < 5; index++) {
      await repository.save(
        TodoDraft(
          title: '象限父项 $index',
          scheduledDate: day,
          priorityQuadrant: index < 4
              ? TodoPriorityQuadrant.urgentImportant
              : TodoPriorityQuadrant.importantNotUrgent,
        ),
      );
      // 保存后的根项身份用于绑定唯一子项。
      final TodoRecord parent =
          (await database.select(database.todoItems).get()).singleWhere(
            (TodoRecord item) => item.title == '象限父项 $index',
          );
      await repository.save(
        TodoDraft(
          title: '象限子项 $index',
          parentId: parent.id,
          scheduledDate: day,
        ),
      );
    }
    // 标准手机高度可直接点击前两个象限的标题栏。
    final _HomeTestApp app = await _pumpHome(tester, database: database);
    expect(_key('home-todo-quadrant-toggle-all-1'), findsNothing);
    // 批量按钮确实位于象限标题栏右侧，并满足触控尺寸。
    final Rect button = tester.getRect(_key('home-todo-quadrant-toggle-all-3'));
    // 标题栏的完整范围用于验证右对齐和垂直居中。
    final Rect heading = tester.getRect(_key('home-todo-quadrant-heading-3'));
    expect(button.right, closeTo(heading.right, 0.01));
    expect(button.bottom, closeTo(heading.bottom, 0.01));
    expect(button.height, greaterThanOrEqualTo(48));
    await tester.tap(_key('home-todo-quadrant-toggle-all-2'));
    await tester.pumpAndSettle();
    expect(find.text('象限子项 4'), findsOneWidget);
    await tester.tap(_key('home-todo-quadrant-toggle-all-3'));
    await tester.pumpAndSettle();
    for (int index = 0; index < 5; index++) {
      expect(find.text('象限子项 $index'), findsOneWidget);
    }
    await tester.tap(_key('home-todo-quadrant-toggle-all-3'));
    await tester.pumpAndSettle();
    for (int index = 0; index < 4; index++) {
      expect(find.text('象限子项 $index'), findsNothing);
    }
    expect(find.text('象限子项 4'), findsOneWidget);
    // 数据流变化后不再显示没有可展开内容的批量按钮。
    await repository.setCompleted(
      (await database.select(database.todoItems).get())
          .singleWhere((TodoRecord item) => item.title == '象限子项 4')
          .id,
      true,
    );
    await tester.pumpAndSettle();
    expect(_key('home-todo-quadrant-toggle-all-2'), findsNothing);
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('首页点选与横滑只切换平铺模块，名言和悬浮操作固定', (WidgetTester tester) async {
    // 使用已隐藏刻度的真实本机偏好启动应用。
    final _HomeTestApp app = await _pumpHome(tester);
    // 名言保留在分页之外的初始边界。
    final Rect quoteBefore = tester.getRect(_key('home-quote-card'));
    // 右下角时间记录入口在模块之间保持固定。
    final Rect actionBefore = tester.getRect(_key('home-mobile-create-split'));
    expect(find.text('今日工作台'), findsNothing);
    expect(find.text('首页设置'), findsNothing);
    expect(_key('home-mobile-tab-dayRuler'), findsNothing);
    // Keep the persisted selection as evidence that drags never become taps.
    final QuoteRecord quoteBeforeDrag = (await app.database.quoteForDay(
      DateTime(2026, 10, 8),
    ))!;
    _expectPage(tester, 0);
    _expectFlatPanel(tester, 'home-todo-card');

    // 每个模块都可以单次点按进入，触控高度不小于 48dp。
    for (final (String, int, String) module in <(String, int, String)>[
      ('timeStatus', 1, 'home-time-status-card'),
      ('todayContext', 2, 'home-context-card'),
    ]) {
      expect(
        tester.getSize(_key('home-mobile-tab-${module.$1}')).height,
        greaterThanOrEqualTo(48),
      );
      await _selectModule(tester, module.$1);
      _expectPage(tester, module.$2);
      _expectFlatPanel(tester, module.$3);
      expect(tester.getRect(_key('home-quote-card')), quoteBefore);
      expect(tester.getRect(_key('home-mobile-create-split')), actionBefore);
    }

    await tester.drag(_key('home-mobile-pager'), const Offset(280, 0));
    await tester.pumpAndSettle();
    _expectPage(tester, 1);
    await tester.drag(_key('home-mobile-pager'), const Offset(280, 0));
    await tester.pumpAndSettle();
    _expectPage(tester, 0);

    // 首尾继续横拖不能交给一级导航，也不会循环。
    await tester.drag(_key('home-mobile-pager'), const Offset(280, 0));
    await tester.pumpAndSettle();
    _expectPage(tester, 0);
    await _selectModule(tester, 'todayContext');
    await tester.drag(_key('home-mobile-pager'), const Offset(-280, 0));
    await tester.pumpAndSettle();
    _expectPage(tester, 2);
    expect(_currentPath(app), '/home');

    // 在横幅上滑动也不会离开首页。
    await tester.drag(_key('home-quote-card'), const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(_currentPath(app), '/home');
    _expectPage(tester, 2);
    // Vertical scrolling through the same surface also cancels quote activation.
    await tester.drag(_key('home-quote-card'), const Offset(0, -72));
    await tester.pumpAndSettle();
    final QuoteRecord quoteAfterDrags = (await app.database.quoteForDay(
      DateTime(2026, 10, 8),
    ))!;
    expect(quoteAfterDrags.id, quoteBeforeDrag.id);
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('设置导航打开首页设置并保存修改，返回首页保留当前模块', (WidgetTester tester) async {
    // 真实路由与原本机偏好共同验证入口迁移后的完整操作路径。
    final _HomeTestApp app = await _pumpHome(tester);
    expect(find.text('今日工作台'), findsNothing);
    expect(find.text('首页设置'), findsNothing);
    expect(
      tester.getTopLeft(_key('home-quote-card')).dy,
      closeTo(tester.getTopLeft(_key('home-mobile-header')).dy + 8, 0.1),
    );
    await _selectModule(tester, 'timeStatus');
    await tester.tap(_key('home-shortcut-settings'));
    await tester.pumpAndSettle();
    expect(_currentPath(app), '/settings');
    expect(find.text('更多'), findsNothing);
    expect(_key('compact-navigation'), findsNothing);
    expect(_key('android-settings-home').hitTestable(), findsOneWidget);
    await tester.tap(_key('android-settings-home'));
    await tester.pumpAndSettle();
    expect(_key('home-settings-quote-switch'), findsOneWidget);
    await tester.tap(_key('home-settings-quote-switch'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加今日刻度'));
    await tester.pumpAndSettle();
    expect(app.preferences.getStringList('home.cards.order'), <String>[
      'todos',
      'timeStatus',
      'todayContext',
      'dayRuler',
    ]);
    expect(_key('android-settings-detail-home'), findsOneWidget);
    expect(_key('compact-navigation'), findsNothing);
    expect(find.byType(OmniSideSheetScaffold), findsNothing);
    await tester.tap(_key('android-settings-back'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectPage(tester, 1);
    expect(_key('home-quote-card'), findsNothing);
    expect(_key('home-mobile-tab-dayRuler'), findsOneWidget);
    expect(find.text('今日工作台'), findsNothing);
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  // 两种明暗主题都验证新设置详情的可用性。
  for (final String themeMode in <String>['light', 'dark']) {
    testWidgets('首页设置小屏大字分组与功能管理跳转 $themeMode', (WidgetTester tester) async {
      // 真实应用按小屏和放大字号启动。
      final _HomeTestApp app = await _pumpHome(
        tester,
        size: const Size(360, 640),
        textScale: 1.5,
        themeMode: themeMode,
      );
      await tester.tap(_key('home-shortcut-settings'));
      await tester.pumpAndSettle();
      await tester.tap(_key('android-settings-home'));
      await tester.pumpAndSettle();
      expect(_key('android-settings-detail-home'), findsOneWidget);
      expect(_key('home-settings-banner-panel'), findsOneWidget);
      expect(_key('home-settings-added-panel'), findsOneWidget);
      expect(find.byType(OmniSideSheetScaffold), findsNothing);
      expect(_key('compact-navigation'), findsNothing);
      // 只滚动正文，使底部功能管理入口在大字布局下仍能访问。
      final Finder contentScrollable = find
          .descendant(
            of: _key('home-card-manager-content'),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('前往功能管理'),
        180,
        scrollable: contentScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('前往功能管理').hitTestable(), findsOneWidget);
      await tester.tap(find.text('前往功能管理'));
      await tester.pumpAndSettle();
      expect(_key('android-settings-detail-features'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_key('android-settings-overview'), findsOneWidget);
      expect(_currentPath(app), '/settings');
      expect(tester.takeException(), isNull);
      await _disposeHome(tester, app);
    });
  }

  testWidgets('连续快滑和斜向拖动不越界，也不切换一级页面', (WidgetTester tester) async {
    // 使用真实路由与手势竞争环境。
    final _HomeTestApp app = await _pumpHome(tester);
    await _selectModule(tester, 'timeStatus');
    await tester.fling(_key('home-mobile-pager'), const Offset(-240, 0), 900);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.fling(_key('home-mobile-pager'), const Offset(240, 0), 900);
    await tester.pumpAndSettle();
    // 连续反向输入落在现存模块内，且页面已完整吸附。
    final double currentPage = _pager(tester).controller!.page!;
    expect(currentPage, inInclusiveRange(0, 2));
    expect(currentPage, closeTo(currentPage.roundToDouble(), 0.001));
    expect(_currentPath(app), '/home');

    await _selectModule(tester, 'todos');
    await tester.drag(_key('home-mobile-pager'), const Offset(-18, -180));
    await tester.pumpAndSettle();
    _expectPage(tester, 0);
    expect(_currentPath(app), '/home');
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  // 拆分按钮两个命中区域都位于首页正文之外，需要分别验证手势边界。
  for (final String actionKey in <String>[
    'home-mobile-create',
    'home-mobile-more-actions',
  ]) {
    testWidgets('悬浮按钮区域横拖保持首页并保留点击操作 $actionKey', (WidgetTester tester) async {
      // 真实全局横滑和首页浮层共同参与命中测试。
      final _HomeTestApp app = await _pumpHome(tester);
      await _expectFabSemanticBounds(tester);
      await tester.drag(_key(actionKey), const Offset(-260, 0));
      await tester.pumpAndSettle();
      expect(_currentPath(app), '/home');
      _expectPage(tester, 0);
      await tester.tap(_key(actionKey));
      await tester.pumpAndSettle();
      if (actionKey == 'home-mobile-create') {
        expect(_key('time-entry-editor'), findsOneWidget);
        await tester.tap(find.text('取消'));
      } else {
        expect(find.text('补记时间'), findsOneWidget);
        expect(find.text('新增待办'), findsOneWidget);
        await tester.tapAt(const Offset(10, 400));
      }
      await tester.pumpAndSettle();
      expect(_currentPath(app), '/home');
      expect(tester.takeException(), isNull);
      await _disposeHome(tester, app);
    });
  }

  testWidgets('待办展开与纵滚位置跨模块保留，末项可以滚出悬浮按钮', (WidgetTester tester) async {
    // 长任务树来自真实仓储，避免只检查保活控件属性。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 用于验证展开状态及最末项完成的父任务。
    final TodoRecord parent = await _seedTodoTree(database);
    // 所有界面订阅共用该内存数据库。
    final _HomeTestApp app = await _pumpHome(tester, database: database);
    await tester.tap(_key('home-todo-tree-toggle-${parent.id}'));
    await tester.pumpAndSettle();
    expect(find.text('分页子任务 1'), findsOneWidget);
    // 正常高度下先将名言滚出，再继续滚动当前模块。
    await tester.drag(_key('home-mobile-pager'), const Offset(0, -420));
    await tester.pumpAndSettle();
    // 当前待办页真实纵向滚动位置。
    final double scrollBefore = _moduleScroll(tester, 'todos').pixels;
    expect(scrollBefore, greaterThan(100));
    expect(_key('home-quote-card'), findsNothing);
    expect(
      tester.getTopLeft(_key('home-mobile-tabs')).dy,
      closeTo(tester.getTopLeft(_key('home-mobile-vertical-layout')).dy, 0.1),
    );

    await _selectModule(tester, 'timeStatus');
    await _selectModule(tester, 'todayContext');
    await _selectModule(tester, 'todos');
    expect(find.text('分页子任务 1'), findsOneWidget);
    expect(_moduleScroll(tester, 'todos').pixels, closeTo(scrollBefore, 0.1));

    // 到达滚动末尾后最后一行必须能完整位于悬浮按钮上方。
    final ScrollPosition position = _moduleScroll(tester, 'todos');
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    // 从真实数据库取得最后任务的稳定标识。
    final TodoRecord last = (await database.select(database.todoItems).get())
        .singleWhere((TodoRecord row) => row.title == '分页子任务 18');
    // 末行勾选框使用生产点击入口。
    final Finder lastAction = _key('home-todo-checkbox-action-${last.id}');
    expect(lastAction.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(lastAction).bottom,
      lessThan(tester.getRect(_key('home-mobile-create-split')).top),
    );
    await tester.tap(lastAction);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(
      (await database.select(database.todoItems).get())
          .singleWhere((TodoRecord row) => row.id == last.id)
          .isCompleted,
      isTrue,
    );
    expect(_currentPath(app), '/home');
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('时间图例筛选跨模块和功能页往返保留，重排按模块身份定位', (WidgetTester tester) async {
    // 两种真实类别让图例过滤产生可验证的时长变化。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await _seedTimeEntries(database);
    // 图例与偏好控制器均使用生产实现。
    final _HomeTestApp app = await _pumpHome(tester, database: database);
    await _selectModule(tester, 'timeStatus');
    expect(_donutDuration(tester), '1h30m');
    await tester.tap(_key('home-time-legend-item-工作'));
    await tester.pumpAndSettle();
    expect(_donutDuration(tester), '0h30m');
    await _selectModule(tester, 'todos');
    await _selectModule(tester, 'timeStatus');
    expect(_donutDuration(tester), '0h30m');

    // Partially collapse the header with a real drag while keeping its entry visible.
    await tester.drag(_key('home-quote-card'), const Offset(0, -48));
    await tester.pumpAndSettle();
    // Observe the actual coordinated home scroll position across push and pop.
    final ScrollController homeScroll = tester
        .widget<NestedScrollView>(_key('home-mobile-vertical-layout'))
        .controller!;
    // Capture a nonzero position rather than merely asserting retained widgets.
    final double homeOffsetBeforeFeature = homeScroll.offset;
    expect(homeOffsetBeforeFeature, greaterThan(0));
    expect(_key('home-shortcut-todos').hitTestable(), findsOneWidget);
    await tester.tap(_key('home-shortcut-todos'));
    await tester.pumpAndSettle();
    expect(_currentPath(app), '/todos');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectPage(tester, 1);
    expect(_donutDuration(tester), '0h30m');
    expect(homeScroll.offset, closeTo(homeOffsetBeforeFeature, 0.1));

    // 调整当前模块顺序后仍保留时间页和图例状态。
    final HomeCardPreferenceController preference = app.container.read(
      homeCardPreferenceProvider.notifier,
    );
    await preference.reorderContentCards(1, 0);
    await tester.pumpAndSettle();
    _expectPage(tester, 0);
    expect(_donutDuration(tester), '0h30m');
    expect(app.preferences.getStringList('home.cards.order'), <String>[
      'quote',
      'timeStatus',
      'todos',
      'todayContext',
    ]);

    // 删除当前首项后选择下一相邻模块，并保留之前隐藏的刻度。
    await preference.setVisible(HomeCardId.timeStatus, false);
    await tester.pumpAndSettle();
    _expectPage(tester, 0);
    expect(_key('home-mobile-tab-timeStatus'), findsNothing);
    expect(_key('home-mobile-tab-dayRuler'), findsNothing);
    expect(_key('home-todo-header'), findsNothing);
    expect(_key('home-todo-content'), findsOneWidget);
    await preference.setVisible(HomeCardId.dayRuler, true);
    await tester.pumpAndSettle();
    expect(app.preferences.getStringList('home.cards.order'), <String>[
      'quote',
      'todos',
      'todayContext',
      'dayRuler',
    ]);
    await _selectModule(tester, 'dayRuler');
    _expectPage(tester, 2);
    _expectFlatPanel(tester, 'home-day-ruler');
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('真实时间功能开关与单页恢复保持待办身份、展开和滚动状态', (WidgetTester tester) async {
    // 真实待办树使根布局或分页重建造成的状态丢失可以被观察。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 待办父任务用于在首轮打开后展开长列表。
    final TodoRecord parent = await _seedTodoTree(database);
    // 保存时间在前、待办在后的顺序，验证冷启动遵循本机偏好。
    final _HomeTestApp app = await _pumpHome(
      tester,
      database: database,
      cards: const <String>['quote', 'timeStatus', 'todos'],
    );
    _expectPage(tester, 0);
    expect(_key('home-time-header'), findsNothing);
    expect(_key('home-time-content'), findsOneWidget);
    await _selectModule(tester, 'todos');
    _expectPage(tester, 1);
    await tester.tap(_key('home-todo-tree-toggle-${parent.id}'));
    await tester.pumpAndSettle();
    // 留在正文中段，避免隐藏导航后视口变高导致末尾偏移被合法钳制。
    await tester.drag(_key('home-mobile-pager'), const Offset(0, -350));
    await tester.pumpAndSettle();
    // 开关悬浮按钮前的真实正文位置。
    final double scrollBefore = _moduleScroll(tester, 'todos').pixels;
    expect(scrollBefore, greaterThan(100));
    // 通过生产功能控制器移除时间模块及对应悬浮入口。
    final FeaturePreferenceController features = app.container.read(
      featurePreferenceProvider.notifier,
    );
    await features.setFeatureEnabled(AppFeature.timeline, false);
    await tester.pumpAndSettle();
    _expectPage(tester, 0);
    expect(_key('home-mobile-tabs'), findsNothing);
    expect(_key('home-mobile-create-split'), findsNothing);
    expect(find.text('分页子任务 1'), findsOneWidget);
    expect(_moduleScroll(tester, 'todos').pixels, closeTo(scrollBefore, 0.1));

    await features.setFeatureEnabled(AppFeature.timeline, true);
    await tester.pumpAndSettle();
    _expectPage(tester, 1);
    expect(_key('home-mobile-tabs'), findsOneWidget);
    expect(_key('home-mobile-create-split'), findsOneWidget);
    expect(find.text('分页子任务 1'), findsOneWidget);
    expect(_moduleScroll(tester, 'todos').pixels, closeTo(scrollBefore, 0.1));
    expect(app.preferences.getStringList('home.cards.order'), <String>[
      'quote',
      'timeStatus',
      'todos',
    ]);

    // 当前非首项在恢复后重排到首项，也保持已展开的业务子树。
    await app.container
        .read(homeCardPreferenceProvider.notifier)
        .reorderContentCards(1, 0);
    await tester.pumpAndSettle();
    _expectPage(tester, 0);
    expect(find.text('分页子任务 1'), findsOneWidget);
    expect(_moduleScroll(tester, 'todos').pixels, closeTo(scrollBefore, 0.1));
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('系统减少动效时标签点击立即落位且不启动分页动画', (WidgetTester tester) async {
    // 所有业务和导航仍使用真实应用。
    final _HomeTestApp app = await _pumpHome(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await tester.pump();
    await tester.tap(_key('home-mobile-tab-todayContext'));
    await tester.pump();
    _expectPage(tester, 2);
    expect(
      _pager(tester).controller!.position.isScrollingNotifier.value,
      isFalse,
    );
    expect(_currentPath(app), '/home');
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  // 单模块与全部内容隐藏均需要独立覆盖横向手势隔离。
  for (final List<String> cards in <List<String>>[
    <String>['quote', 'todos'],
    <String>['quote'],
    <String>[],
  ]) {
    testWidgets('首页只有 ${cards.join(',')} 时不显示标签且不向一级导航接力', (
      WidgetTester tester,
    ) async {
      // 精确恢复空列表或单模块，而不是自动重新添加默认卡片。
      final _HomeTestApp app = await _pumpHome(tester, cards: cards);
      expect(_key('home-mobile-tabs'), findsNothing);
      // 顶部以外的空白也必须消费左右滑动。
      for (final double distance in <double>[-260, 260]) {
        await tester.dragFrom(const Offset(195, 560), Offset(distance, 0));
        await tester.pumpAndSettle();
        expect(_currentPath(app), '/home');
      }
      expect(
        find.text('首页设置'),
        cards.where((String card) => card != 'quote').isEmpty
            ? findsOneWidget
            : findsNothing,
      );
      expect(app.preferences.getStringList('home.cards.order'), cards);
      expect(tester.takeException(), isNull);
      await _disposeHome(tester, app);
    });
  }

  testWidgets('360 宽度深色首页沿用平铺外观且没有布局溢出', (WidgetTester tester) async {
    // 显式释放平台覆盖，以在 Flutter 测试不变量检查前恢复环境。
    final _HomeTestApp app = await _pumpHome(
      tester,
      size: const Size(360, 780),
      themeMode: 'dark',
    );
    // 各模块都完成实际布局，避免只验证首屏。
    for (final String module in <String>[
      'todos',
      'timeStatus',
      'todayContext',
    ]) {
      await _selectModule(tester, module);
      expect(tester.takeException(), isNull);
    }
    expect(
      Theme.of(tester.element(_key('home-mobile-pager'))).brightness,
      Brightness.dark,
    );
    await _disposeHome(tester, app);
  });

  testWidgets('短屏和两倍字号允许名言上滚并将模块标签固定在顶部', (WidgetTester tester) async {
    // 足够长的真实业务内容用于验证折叠后的继续滚动。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 短屏初始视口不要求先命中子任务展开按钮。
    final TodoRepository repository = TodoRepository(database);
    // 直接展示的根任务让折叠后的正文仍能继续滚动。
    for (int index = 0; index < 8; index += 1) {
      await repository.save(
        TodoDraft(
          title: '大字号待办 $index',
          scheduledDate: DateTime(2026, 10, 8),
          priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
        ),
      );
    }
    // 完整应用的依赖与平台覆盖需要在测试主体结束前释放。
    final _HomeTestApp app = await _pumpHome(
      tester,
      database: database,
      size: const Size(360, 320),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    // 大字号时横幅仍保留自然高度，仅允许整体向上滚出。
    final double quoteTop = tester.getTopLeft(_key('home-quote-card')).dy;
    await tester.dragFrom(const Offset(180, 120), const Offset(0, -380));
    await tester.pumpAndSettle();
    expect(
      tester
          .getTopLeft(
            find.byKey(
              const ValueKey<String>('home-quote-card'),
              skipOffstage: false,
            ),
          )
          .dy,
      lessThan(quoteTop - 30),
    );
    expect(_key('home-mobile-tabs').hitTestable(), findsOneWidget);
    // The shortcuts add header height; finish collapsing it with a real drag.
    await tester.drag(_key('home-mobile-pager'), const Offset(0, -380));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_key('home-mobile-tabs')).dy, closeTo(0, 0.1));
    // 顶部已折叠后，继续滚动只推动业务正文。
    final double tabsTop = tester.getTopLeft(_key('home-mobile-tabs')).dy;
    await tester.drag(_key('home-mobile-pager'), const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_key('home-mobile-tabs')).dy,
      closeTo(tabsTop, 0.1),
    );
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });

  testWidgets('Windows 首页移除工具栏并从设置管理卡片', (WidgetTester tester) async {
    // 桌面回归也在测试主体内清理平台模拟。
    final _HomeTestApp app = await _pumpHome(
      tester,
      size: const Size(1440, 900),
      platform: TargetPlatform.windows,
    );
    expect(_key('home-mobile-pager'), findsNothing);
    expect(find.text('今日工作台'), findsNothing);
    expect(find.text('管理卡片'), findsNothing);
    // 桌面三个业务面板继续使用默认卡片样式。
    for (final String panel in <String>[
      'home-todo-card',
      'home-time-status-card',
      'home-context-card',
    ]) {
      expect(tester.widget<OmniPanel>(_key(panel)).flat, isFalse);
    }
    await tester.tap(_key('navigation-/settings'));
    await tester.pumpAndSettle();
    await tester.tap(_key('settings-category-home'));
    await tester.pumpAndSettle();
    expect(_key('home-card-manager-content'), findsOneWidget);
    expect(find.byType(OmniSideSheetScaffold), findsNothing);
    await tester.tap(find.byTooltip('移除每日名言'));
    await tester.pumpAndSettle();
    expect(app.preferences.getStringList('home.cards.order'), <String>[
      'todos',
      'timeStatus',
      'todayContext',
    ]);
    await tester.tap(_key('navigation-/home'));
    await tester.pumpAndSettle();
    expect(_key('home-quote-card'), findsNothing);
    expect(tester.takeException(), isNull);
    await _disposeHome(tester, app);
  });
}

/// 读屏主操作的命中范围仅覆盖悬浮按钮，不能扩展成整个首页。
Future<void> _expectFabSemanticBounds(WidgetTester tester) async {
  // 让测试读取交给系统辅助功能的真实语义树。
  final SemanticsHandle semantics = tester.ensureSemantics();
  try {
    await tester.pump();
    // 主操作合并后的语义节点边界。
    final Rect bounds = tester.getSemantics(find.bySemanticsLabel('开始记录')).rect;
    // 完整拆分按钮为主操作提供严格的最大边界。
    final Size buttonSize = tester.getSize(_key('home-mobile-create-split'));
    expect(bounds.width, lessThanOrEqualTo(buttonSize.width));
    expect(bounds.height, lessThanOrEqualTo(buttonSize.height));
    expect(bounds.isEmpty, isFalse);
  } finally {
    semantics.dispose();
  }
}

/// 当前测试持有的真实数据依赖及本机偏好。
class _HomeTestApp {
  /// 页面实际订阅的依赖容器。
  final ProviderContainer container;

  /// 用于检查偏好不被重置的设备存储。
  final SharedPreferences preferences;

  /// 与生产仓储共用的隔离内存数据库。
  final AppDatabase database;

  /// 防止显式释放与失败清理重复关闭环境。
  bool disposed = false;

  /// 创建单次首页测试环境。
  _HomeTestApp({
    required this.container,
    required this.preferences,
    required this.database,
  });
}

/// 返回首页稳定标识对应的控件。
Finder _key(String key) => find.byKey(ValueKey<String>(key));

/// 读取真实分页控件，使用其实际滚动位置验证落位。
PageView _pager(WidgetTester tester) =>
    tester.widget<PageView>(_key('home-mobile-pager'));

/// 检查当前分页已完整落在指定索引。
void _expectPage(WidgetTester tester, int index) {
  expect(_pager(tester).controller!.page, closeTo(index.toDouble(), 0.001));
}

/// 检查业务面板确实启用了平铺呈现。
void _expectFlatPanel(WidgetTester tester, String panelKey) {
  expect(tester.widget<OmniPanel>(_key(panelKey)).flat, isTrue);
}

/// 通过真实标签执行一次模块切换并等待布局完成。
Future<void> _selectModule(WidgetTester tester, String module) async {
  await tester.tap(_key('home-mobile-tab-$module'));
  await tester.pumpAndSettle();
}

/// 读取一个模块内部唯一的纵向滚动位置。
ScrollPosition _moduleScroll(WidgetTester tester, String module) {
  return tester
      .stateList<ScrollableState>(
        find.descendant(
          of: _key('home-mobile-page-$module'),
          matching: find.byType(Scrollable),
        ),
      )
      .singleWhere(
        (ScrollableState state) => state.position.axis == Axis.vertical,
      )
      .position;
}

/// 读取今日圆环当前实际显示的汇总时长。
String _donutDuration(WidgetTester tester) =>
    tester.widget<Text>(_key('home-time-donut-duration-今日')).data!;

/// 返回完整应用当前的一级路由。
String _currentPath(_HomeTestApp app) =>
    app.container.read(appRouterProvider).state.uri.path;

/// 用真实父子关系生成超过手机一屏的待办内容。
Future<TodoRecord> _seedTodoTree(AppDatabase database) async {
  // 测试业务日期不依赖执行机器时区或时钟。
  final DateTime now = DateTime(2026, 10, 8, 14);
  // 页面实际使用的生产待办仓储。
  final TodoRepository repository = TodoRepository(database);
  await repository.save(
    TodoDraft(
      title: '分页父任务',
      scheduledDate: now,
      priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
    ),
  );
  // 刚保存的根任务稳定身份。
  final TodoRecord parent = await database
      .select(database.todoItems)
      .getSingle();
  // 按保存顺序生成足够多的子任务。
  for (int index = 1; index <= 18; index += 1) {
    await repository.save(
      TodoDraft(title: '分页子任务 $index', parentId: parent.id, scheduledDate: now),
    );
  }
  return parent;
}

/// 保存两个不同类别的完整时间段用于验证图例筛选。
Future<void> _seedTimeEntries(AppDatabase database) async {
  // 首页订阅的生产时间仓储。
  final TimeEntryRepository repository = TimeEntryRepository(database);
  await repository.save(
    TimeEntryDraft(
      startedAt: DateTime(2026, 10, 8, 9),
      endedAt: DateTime(2026, 10, 8, 10),
      activity: '开发首页',
      category: '工作',
    ),
  );
  await repository.save(
    TimeEntryDraft(
      startedAt: DateTime(2026, 10, 8, 11),
      endedAt: DateTime(2026, 10, 8, 11, 30),
      activity: '阅读设计',
      category: '学习',
    ),
  );
}

/// 挂载完整应用，仅覆盖数据库、设备偏好和固定业务时间。
Future<_HomeTestApp> _pumpHome(
  WidgetTester tester, {
  AppDatabase? database,
  Size size = const Size(390, 844),
  TargetPlatform platform = TargetPlatform.android,
  String themeMode = 'light',
  double textScale = 1,
  List<String> cards = const <String>[
    'quote',
    'todos',
    'timeStatus',
    'todayContext',
  ],
}) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': themeMode,
    'home.cards.order': cards,
  });
  // 本次环境使用的本机配置存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 允许测试提前保存真实业务数据。
  final AppDatabase activeDatabase =
      database ?? AppDatabase.forTesting(NativeDatabase.memory());
  // 页面和仓储继续走生产 Provider，不覆盖业务数据流。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(activeDatabase),
      nowProvider.overrideWithValue(DateTime(2026, 10, 8, 14)),
    ],
  );
  // 失败时保留兜底清理，成功时在测试主体内主动释放。
  final _HomeTestApp app = _HomeTestApp(
    container: container,
    preferences: preferences,
    database: activeDatabase,
  );
  addTearDown(() => _disposeHome(tester, app));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OmniButlerApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
  return app;
}

/// 在测试框架检查全局不变量前卸载应用并恢复平台覆盖。
Future<void> _disposeHome(WidgetTester tester, _HomeTestApp app) async {
  if (app.disposed) return;
  app.disposed = true;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  app.container.dispose();
  await tester.pump(const Duration(milliseconds: 100));
  await app.database.close();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
  tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
  debugDefaultTargetPlatformOverride = null;
}
