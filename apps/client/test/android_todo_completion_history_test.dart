import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/android_todo_completion_history.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_panel.dart';

import 'support/todo_completion_test_data.dart';

/// Exercises real Android history interactions without reading a user database.
void main() {
  setUpAll(_loadFonts);

  _historyTest('完成历史正文右滑打开侧栏', (WidgetTester tester) async {
    await _pumpHistory(tester);
    // Start inside the scrollable body rather than its toolbar or route edge.
    final Rect body = tester.getRect(_key('list'));
    await tester.dragFrom(
      body.topLeft + const Offset(80, 300),
      const Offset(220, 0),
    );
    await tester.pumpAndSettle();
    expect(_key('sidebar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _historyTest('按完成日展示跨日卡片，父组默认折叠且操作作用于具体任务', (WidgetTester tester) async {
    // Captured callbacks distinguish child actions from parent context.
    final List<String> edited = <String>[];
    // Reopening a child must never reopen the surrounding parent implicitly.
    final List<String> reopened = <String>[];
    await _pumpHistory(
      tester,
      onEdit: (TodoRecord todo) => edited.add(todo.id),
      onReopen: (TodoRecord todo) => reopened.add(todo.id),
    );
    expect(_key('group-2026-10-25-mail'), findsOneWidget);
    expect(_key('group-2026-10-25-release'), findsOneWidget);
    expect(_key('group-2026-10-25-java'), findsOneWidget);
    expect(_key('group-2026-10-24-java'), findsOneWidget);
    expect(_key('entry-build'), findsNothing);
    expect(_key('entry-chapter-3'), findsNothing);
    expect(_key('more-release'), findsNothing);
    await tester.tap(find.text('项目收尾'));
    await tester.pumpAndSettle();
    expect(_key('entry-build'), findsOneWidget);
    expect(_key('entry-notes'), findsOneWidget);
    await tester.tap(_key('more-build'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑').hitTestable());
    await tester.pumpAndSettle();
    expect(edited, <String>['build']);
    await tester.tap(_key('more-build'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新打开').hitTestable());
    await tester.pumpAndSettle();
    expect(reopened, <String>['build']);
    expect(tester.takeException(), isNull);
  });

  _historyTest('搜索章节名称和原始序号并保留所属任务上下文', (WidgetTester tester) async {
    await _pumpHistory(tester);
    await _openSearch(tester);
    await tester.enterText(_key('query'), '集合与泛型');
    await tester.pumpAndSettle();
    expect(find.text('Java 学习'), findsOneWidget);
    expect(_key('entry-chapter-3'), findsOneWidget);
    expect(_key('entry-chapter-8'), findsNothing);
    expect(_key('group-2026-10-25-release'), findsNothing);
    await tester.enterText(_key('query'), '第8章');
    await tester.pumpAndSettle();
    expect(_key('entry-chapter-8'), findsOneWidget);
    expect(find.text('第8章'), findsWidgets);
    expect(_key('entry-chapter-3'), findsNothing);
    await tester.enterText(_key('query'), '项目收尾');
    await tester.pumpAndSettle();
    expect(_key('entry-build'), findsOneWidget);
    expect(_key('entry-notes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _historyTest('进度入口打开共享进度面板并保留历史展开', (WidgetTester tester) async {
    // Existing completed steps provide a real progress panel snapshot.
    final List<TodoCompletionEntry> entries = completionTestEntries();
    // Both dates belong to the same task identity passed to the shared panel.
    final TodoRecord task = entries
        .firstWhere(
          (TodoCompletionEntry entry) =>
              entry.kind == TodoCompletionKind.progress,
        )
        .todo;
    await _pumpHistory(tester, entries: entries, progressTask: task);
    await tester.tap(find.text('Java 学习').first);
    await tester.pumpAndSettle();
    expect(_key('entry-chapter-3'), findsOneWidget);
    await tester.tap(find.byTooltip('查看进度').first);
    await tester.pumpAndSettle();
    expect(find.byType(TodoProgressPanel), findsOneWidget);
    expect(
      tester
          .widget<TodoProgressPanel>(find.byType(TodoProgressPanel))
          .record
          .id,
      'java',
    );
    await tester.tap(find.text('关闭').hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(TodoProgressPanel), findsNothing);
    expect(_key('entry-chapter-3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _historyTest('侧栏类型与月份取交集，清除日期不清除类型且统计保持全量', (WidgetTester tester) async {
    await _pumpHistory(tester);
    await _openSidebar(tester);
    expect(_stat(tester, 7), '6');
    expect(_stat(tester, 30), '6');
    expect(_stat(tester, 365), '6');
    await _tapSidebar(tester, 'kind-progress');
    expect(_key('group-2026-10-25-mail'), findsNothing);
    expect(_key('group-2026-10-25-java'), findsOneWidget);
    expect(_key('clear-kind'), findsOneWidget);
    await _openSidebar(tester);
    expect(_stat(tester, 7), '6');
    await _tapSidebar(tester, 'month-2024-05');
    expect(_key('group-2026-10-25-java'), findsNothing);
    expect(_key('clear-date'), findsOneWidget);
    await tester.tap(_key('clear-date'));
    await tester.pumpAndSettle();
    expect(_key('group-2026-10-25-java'), findsOneWidget);
    expect(_key('group-2026-10-25-mail'), findsNothing);
    await tester.tap(_key('clear-kind'));
    await tester.pumpAndSettle();
    expect(_key('group-2026-10-25-mail'), findsOneWidget);
    expect(_key('clear-date'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _historyTest('全屏搜索继承范围但独立修改，取消恢复主列表展开和位置', (WidgetTester tester) async {
    await _pumpHistory(tester);
    await _openSidebar(tester);
    await _tapSidebar(tester, 'kind-normal');
    await _openSidebar(tester);
    await _tapSidebar(tester, 'month-2026-10');
    await tester.tap(find.text('项目收尾'));
    await tester.pumpAndSettle();
    // The list position belongs to the history page, not to its search route.
    final ScrollPosition originalPosition = _listPosition(tester);
    // A zero offset is still a meaningful restoration assertion for this fixture.
    final double offset = originalPosition.pixels;
    await _openSearch(tester);
    expect(_key('clear-kind'), findsOneWidget);
    expect(_key('clear-date'), findsOneWidget);
    await tester.enterText(_key('query'), 'Java');
    await tester.pumpAndSettle();
    expect(_key('entry-chapter-3'), findsNothing);
    await tester.tap(_key('filter-open'));
    await tester.pumpAndSettle();
    await tester.tap(_key('filter-kind-progress'));
    await tester.tap(_key('filter-apply'));
    await tester.pumpAndSettle();
    expect(_key('entry-chapter-3'), findsOneWidget);
    await tester.tap(_key('search-cancel'));
    await tester.pumpAndSettle();
    expect(_key('query'), findsNothing);
    expect(_key('entry-build'), findsOneWidget);
    expect(_key('entry-notes'), findsOneWidget);
    expect(_key('group-2026-10-25-java'), findsNothing);
    expect(identical(_listPosition(tester), originalPosition), isTrue);
    expect(_listPosition(tester).pixels, closeTo(offset, .1));
    expect(tester.takeException(), isNull);
  });

  _historyTest('筛选取消与系统返回丢弃草稿，应用后才影响搜索', (WidgetTester tester) async {
    await _pumpHistory(tester);
    await _openSearch(tester);
    await tester.enterText(_key('query'), 'Java');
    await tester.pumpAndSettle();
    await tester.tap(_key('filter-open'));
    await tester.pumpAndSettle();
    await tester.tap(_key('filter-kind-normal'));
    await tester.tap(_key('filter-cancel'));
    await tester.pumpAndSettle();
    expect(_key('entry-chapter-3'), findsOneWidget);
    await tester.tap(_key('filter-open'));
    await tester.pumpAndSettle();
    await tester.tap(_key('filter-kind-normal'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('filter'), findsNothing);
    expect(_key('query'), findsOneWidget);
    expect(_key('entry-chapter-3'), findsOneWidget);
    await tester.tap(_key('filter-open'));
    await tester.pumpAndSettle();
    await tester.tap(_key('filter-kind-normal'));
    await tester.tap(_key('filter-apply'));
    await tester.pumpAndSettle();
    expect(_key('entry-chapter-3'), findsNothing);
    expect(_key('clear-kind'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('query'), findsNothing);
    expect(_key('history'), findsOneWidget);
    expect(_key('clear-kind'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _historyTest('完整年度热图横滚不关闭侧栏，点击日期与返回路径明确', (WidgetTester tester) async {
    await _pumpHistory(tester);
    await _openSidebar(tester);
    // Each valid calendar date is represented exactly once in the full year.
    final Finder days = find.descendant(
      of: _key('heatmap'),
      matching: find.byWidgetPredicate(
        (Widget widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'android-completion-day-',
            ),
      ),
    );
    expect(days, findsNWidgets(365));
    await tester.drag(_key('heatmap-scroll'), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(_key('sidebar'), findsOneWidget);
    await tester.drag(_key('heatmap-scroll'), const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(_key('sidebar'), findsOneWidget);
    // The same date also labels the covered history, so target the heatmap only.
    final Finder selectedDay = find.descendant(
      of: _key('heatmap'),
      matching: _key('day-2026-10-25'),
    );
    await tester.ensureVisible(selectedDay);
    await tester.pumpAndSettle();
    await tester.tap(selectedDay);
    await tester.pumpAndSettle();
    expect(_key('sidebar'), findsNothing);
    expect(_key('group-2026-10-25-java'), findsOneWidget);
    expect(_key('group-2026-10-24-java'), findsNothing);
    expect(_key('clear-date'), findsOneWidget);
    await _openSidebar(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('sidebar'), findsNothing);
    expect(_key('history'), findsOneWidget);
    expect(_key('clear-date'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _historyTest('后台完成流更新保留当前展开和滚动，重新打开后条目消失', (WidgetTester tester) async {
    // A controllable stream simulates synchronization without a network service.
    final StreamController<List<TodoCompletionEntry>> updates =
        StreamController<List<TodoCompletionEntry>>();
    // Dispose the provider first so stream close does not wait on a paused listener.
    addTearDown(updates.close);
    // Extra older items make the current list genuinely scrollable.
    final List<TodoCompletionEntry> entries = <TodoCompletionEntry>[
      ...completionTestEntries(),
      // Stable dates keep newly added data below the current viewport.
      for (int index = 0; index < 30; index++)
        completionTestEntry('older-$index', DateTime(2026, 10, 20 - index)),
    ];
    await _pumpHistory(tester, stream: updates.stream);
    updates.add(entries);
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目收尾'));
    await tester.pumpAndSettle();
    await tester.drag(_key('list'), const Offset(0, -120));
    await tester.pumpAndSettle();
    // Real scrolling must occur before claiming restoration coverage.
    final ScrollPosition position = _listPosition(tester);
    // The captured offset is compared after the provider emits its new snapshot.
    final double offset = position.pixels;
    expect(offset, greaterThan(0));
    updates.add(<TodoCompletionEntry>[
      ...entries,
      completionTestEntry('additional-old', DateTime(2023, 1, 1)),
    ]);
    await tester.pumpAndSettle();
    expect(identical(_listPosition(tester), position), isTrue);
    expect(position.pixels, closeTo(offset, 1));
    expect(_key('entry-build'), findsOneWidget);
    updates.addError(StateError('background read failed'));
    await tester.pumpAndSettle();
    expect(_key('entry-build'), findsOneWidget);
    expect(_key('entry-notes'), findsOneWidget);
    expect(identical(_listPosition(tester), position), isTrue);
    expect(position.pixels, closeTo(offset, 1));
    // The error banner now scrolls with filters, so reveal it after restoration checks.
    await tester.drag(_key('list'), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('完成历史读取失败'), findsOneWidget);
    updates.add(
      entries
          .where((TodoCompletionEntry entry) => entry.id != 'build')
          .toList(),
    );
    await tester.pumpAndSettle();
    expect(_key('entry-build'), findsNothing);
    expect(_key('entry-notes'), findsOneWidget);
    expect(find.text('完成历史读取失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _historyTest('侧栏拖动取消恢复原位，正常左滑仍可关闭', (WidgetTester tester) async {
    await _pumpHistory(tester);
    await _openSidebar(tester);
    // Starting on the heading excludes the independent heatmap scroll gesture.
    final Offset start = tester.getCenter(find.text('完成概览'));
    // The settled position is the target after cancellation snaps the drawer back.
    final double originalLeft = tester.getTopLeft(_key('sidebar')).dx;
    // Keep the pointer down beyond the normal dismissal threshold before canceling.
    final TestGesture gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-130, 0));
    await tester.pump();
    expect(tester.getTopLeft(_key('sidebar')).dx, lessThan(originalLeft - 60));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(_key('sidebar'), findsOneWidget);
    expect(tester.getTopLeft(_key('sidebar')).dx, closeTo(originalLeft, .1));
    await tester.dragFrom(start, const Offset(-190, 0));
    await tester.pumpAndSettle();
    expect(_key('sidebar'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _historyTest('短屏双倍字号完整范围与键盘同时出现时搜索仍可操作', (WidgetTester tester) async {
    await _pumpHistory(tester, scale: 2);
    await _openSearch(tester);
    await tester.tap(_key('filter-open'));
    await tester.pumpAndSettle();
    await tester.tap(_key('filter-kind-progress'));
    await tester.ensureVisible(_key('filter-start-date'));
    await tester.pumpAndSettle();
    await tester.tap(_key('filter-start-date'));
    await tester.pumpAndSettle();
    await _tapCalendarDay(tester, DateTime(2026, 10, 1));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_key('filter-end-date'));
    await tester.pumpAndSettle();
    await tester.tap(_key('filter-end-date'));
    await tester.pumpAndSettle();
    await _tapCalendarDay(tester, DateTime(2026, 10, 24));
    await tester.pumpAndSettle();
    await tester.tap(_key('filter-apply'));
    await tester.pumpAndSettle();
    expect(_key('clear-date'), findsOneWidget);
    expect(_key('clear-kind'), findsOneWidget);
    tester.view.physicalSize = const Size(320, 360);
    tester.view.viewInsets = const FakeViewPadding(bottom: 150);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.enterText(_key('query'), 'Java');
    await tester.pumpAndSettle();
    expect(_key('query').hitTestable(), findsOneWidget);
    expect(_key('search-cancel').hitTestable(), findsOneWidget);
    expect(_key('filter-open').hitTestable(), findsOneWidget);
    await _capture(tester, 'short-large-range-keyboard');
    // Search results remain reachable below the complete range and type controls.
    await tester.scrollUntilVisible(
      _key('entry-chapter-12'),
      120,
      scrollable: find
          .descendant(of: _key('list'), matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    expect(_key('entry-chapter-12').hitTestable(), findsOneWidget);
    await _capture(tester, 'short-large-range-keyboard-results');
    expect(tester.takeException(), isNull);
  });

  _historyTest('切换数据库后撤去旧搜索和筛选，不能继续操作旧完成记录', (WidgetTester tester) async {
    // The replacement identity represents a completely different local library.
    final AppDatabase replacement = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(replacement.close);
    // A private container lets the test replace the actual watched source.
    final ProviderContainer container = await _pumpHistory(tester);
    await _openSearch(tester);
    await tester.enterText(_key('query'), '项目收尾');
    await tester.pumpAndSettle();
    expect(_key('entry-build'), findsOneWidget);
    await tester.tap(_key('filter-open'));
    await tester.pumpAndSettle();
    container.updateOverrides([
      appDatabaseProvider.overrideWithValue(replacement),
      nowProvider.overrideWithValue(DateTime(2026, 10, 25, 12)),
      todoCompletionEntriesProvider.overrideWith(
        (Ref ref) => Stream<List<TodoCompletionEntry>>.error(
          StateError('new source not ready'),
        ),
      ),
    ]);
    await tester.pumpAndSettle();
    expect(_key('filter'), findsNothing);
    expect(_key('query'), findsNothing);
    expect(_key('entry-build'), findsNothing);
    expect(_key('group-2026-10-25-release'), findsNothing);
    expect(_key('more-build'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _historyTest('千步骤展开与搜索均只构建视口附近的明细', (WidgetTester tester) async {
    // A thousand-step fixture exercises the supported upper boundary.
    final TodoRecord task = completionTestTodo(
      'large',
      '千步学习计划',
      progress: true,
    );
    await _pumpHistory(
      tester,
      entries: <TodoCompletionEntry>[
        // Each identity remains unique even when completion timestamps are equal.
        for (int index = 1; index <= 1000; index++)
          completionTestEntry(
            'large-$index',
            DateTime(2026, 10, 25, 10),
            todo: task,
            ordinal: index,
          ),
      ],
    );
    await tester.tap(find.text('千步学习计划'));
    await tester.pump();
    // The first expanding frame must not temporarily mount all child rows.
    for (int frame = 0; frame < 3; frame++) {
      expect(_builtEntries(), greaterThan(0));
      expect(_builtEntries(), lessThan(40));
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
    await _openSearch(tester);
    await tester.enterText(_key('query'), '千步');
    await tester.pumpAndSettle();
    expect(_builtEntries(), greaterThan(0));
    expect(_builtEntries(), lessThan(40));
    expect(tester.takeException(), isNull);
  });

  _historyTest('空历史保留可操作导航，搜索无结果保持查询可清除', (WidgetTester tester) async {
    await _pumpHistory(tester, entries: <TodoCompletionEntry>[]);
    expect(_key('back').hitTestable(), findsOneWidget);
    expect(_key('sidebar-open').hitTestable(), findsOneWidget);
    await _openSearch(tester);
    await tester.enterText(_key('query'), '不存在的任务');
    await tester.pumpAndSettle();
    expect(_key('query'), findsOneWidget);
    expect(_key('search-cancel').hitTestable(), findsOneWidget);
    await tester.enterText(_key('query'), '');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  _historyTest('大量折叠父组只构建视口附近的卡片', (WidgetTester tester) async {
    await _pumpHistory(
      tester,
      entries: <TodoCompletionEntry>[
        // Distinct roots exercise the number of lazy delegates rather than one group.
        for (int index = 0; index < 500; index++)
          completionTestEntry(
            'group-step-$index',
            DateTime(2026, 10, 25, 10),
            todo: completionTestTodo(
              'group-$index',
              '学习计划$index',
              progress: true,
            ),
            ordinal: 1,
          ),
      ],
    );
    // Only cards near the current viewport should own real render objects.
    final int mounted = find
        .byWidgetPredicate(
          (Widget widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'android-completion-group-',
              ),
        )
        .evaluate()
        .length;
    expect(mounted, greaterThan(0));
    expect(mounted, lessThan(40));
    expect(_builtEntries(), 0);
    expect(tester.takeException(), isNull);
  });

  _historyTest('加载失败可重试且成功后恢复真实完成记录', (WidgetTester tester) async {
    // Each fresh provider subscription models a separate repository read attempt.
    int attempts = 0;
    // The first read fails and the explicit retry returns the stable snapshot.
    final Stream<List<TodoCompletionEntry>> reads =
        Stream<List<TodoCompletionEntry>>.multi((
          MultiStreamController<List<TodoCompletionEntry>> events,
        ) {
          attempts++;
          if (attempts == 1) {
            events.addError(StateError('test read failure'));
          } else {
            events.add(completionTestEntries());
          }
          events.close();
        });
    await _pumpHistory(tester, stream: reads);
    expect(find.text('完成历史读取失败'), findsOneWidget);
    expect(_key('back').hitTestable(), findsOneWidget);
    await tester.tap(find.text('重试').hitTestable());
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(_key('group-2026-10-25-release'), findsOneWidget);
    expect(find.text('完成历史读取失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // Profiles cover both themes, narrow large text, tablets, and short screens.
  for (final (String, Size, double, Brightness, AppThemePalette) profile
      in <(String, Size, double, Brightness, AppThemePalette)>[
        (
          'phone-light',
          const Size(390, 844),
          1,
          Brightness.light,
          AppThemePalette.classicBlue,
        ),
        (
          'phone-dark',
          const Size(390, 844),
          1,
          Brightness.dark,
          AppThemePalette.classicBlue,
        ),
        (
          'narrow-large',
          const Size(320, 640),
          2,
          Brightness.light,
          AppThemePalette.classicBlue,
        ),
        (
          'short-large',
          const Size(320, 360),
          2,
          Brightness.dark,
          AppThemePalette.classicBlue,
        ),
        (
          'tablet',
          const Size(840, 900),
          1,
          Brightness.light,
          AppThemePalette.values.last,
        ),
      ]) {
    _historyTest('安卓完成历史可操作布局与中文预览 ${profile.$1}', (WidgetTester tester) async {
      await _pumpHistory(
        tester,
        size: profile.$2,
        scale: profile.$3,
        brightness: profile.$4,
        palette: profile.$5,
      );
      expect(_key('back').hitTestable(), findsOneWidget);
      expect(_key('sidebar-open').hitTestable(), findsOneWidget);
      expect(_key('search-open').hitTestable(), findsOneWidget);
      await _capture(tester, '${profile.$1}-main');
      await _openSidebar(tester);
      expect(_key('sidebar-close').hitTestable(), findsOneWidget);
      await _capture(tester, '${profile.$1}-sidebar');
      await _tapSidebar(tester, 'kind-progress');
      expect(_key('clear-kind').hitTestable(), findsOneWidget);
      await _openSearch(tester);
      await tester.enterText(_key('query'), 'Java');
      await tester.pumpAndSettle();
      expect(_key('search-cancel').hitTestable(), findsOneWidget);
      await _capture(tester, '${profile.$1}-search');
      await tester.tap(_key('filter-open'));
      await tester.pumpAndSettle();
      expect(_key('filter-apply').hitTestable(), findsOneWidget);
      expect(_key('filter-cancel').hitTestable(), findsOneWidget);
      await _capture(tester, '${profile.$1}-filter');
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_key('history'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

/// Captures the production rendering surface only when previews are requested.
final GlobalKey _previewKey = GlobalKey();

/// Uses Android theme behavior without leaking the override into other tests.
void _historyTest(String name, WidgetTesterCallback callback) => testWidgets(
  name,
  callback,
  variant: TargetPlatformVariant.only(TargetPlatform.android),
);

/// Locates the stable public interaction keys shared by all history surfaces.
Finder _key(String suffix) =>
    find.byKey(ValueKey<String>('android-completion-$suffix'));

/// Opens the current page's independent root search session.
Future<void> _openSearch(WidgetTester tester) async {
  await tester.tap(_key('search-open'));
  await tester.pumpAndSettle();
  expect(_key('query'), findsOneWidget);
}

/// Opens the archive without replacing the list route or its scroll state.
Future<void> _openSidebar(WidgetTester tester) async {
  await tester.tap(_key('sidebar-open'));
  await tester.pumpAndSettle();
  expect(_key('sidebar'), findsOneWidget);
}

/// Scrolls the actual drawer before selecting an offscreen archive condition.
Future<void> _tapSidebar(WidgetTester tester, String suffix) async {
  await tester.ensureVisible(_key(suffix));
  await tester.pumpAndSettle();
  await tester.tap(_key(suffix));
  await tester.pumpAndSettle();
  expect(_key('sidebar'), findsNothing);
}

/// Selects exactly one real calendar cell by its full accessible date.
Future<void> _tapCalendarDay(WidgetTester tester, DateTime date) async {
  // Full localized dates distinguish same-number cells from adjacent months.
  final String label = MaterialLocalizations.of(tester.element(_key('filter')))
      .formatFullDate(date);
  await tester.tap(
    find
        .byWidgetPredicate(
          (Widget widget) =>
              widget is Semantics && widget.properties.label == label,
        )
        .hitTestable(),
  );
}

/// Reads the displayed statistic rather than duplicating aggregation logic.
String? _stat(WidgetTester tester, int days) => tester
    .widget<Text>(
      find
          .descendant(of: _key('stat-$days'), matching: find.byType(Text))
          .first,
    )
    .data;

/// Reads the real vertical viewport to verify restoration after route changes.
ScrollPosition _listPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(of: _key('list'), matching: find.byType(Scrollable))
          .first,
    )
    .position;

/// Counts mounted completion rows instead of trusting a lazy-builder declaration.
int _builtEntries() => find
    .byWidgetPredicate(
      (Widget widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'android-completion-entry-',
          ),
    )
    .evaluate()
    .length;

/// Mounts the real history with deterministic time and a private completion stream.
Future<ProviderContainer> _pumpHistory(
  WidgetTester tester, {
  List<TodoCompletionEntry>? entries,
  Stream<List<TodoCompletionEntry>>? stream,
  TodoRecord? progressTask,
  ValueChanged<TodoRecord>? onEdit,
  ValueChanged<TodoRecord>? onReopen,
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
  AppThemePalette palette = AppThemePalette.classicBlue,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Source identity checks use an isolated memory database on every surface.
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // The provider overrides isolate all tests from local files and remote sync.
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 10, 25, 12)),
      todoCompletionEntriesProvider.overrideWith(
        (Ref ref) => stream ?? Stream.value(entries ?? completionTestEntries()),
      ),
      if (progressTask != null)
        todoByIdProvider(progressTask.id)
            .overrideWith((Ref ref) => Stream.value(progressTask)),
      if (progressTask != null)
        todoProgressStepsProvider(progressTask.id).overrideWith(
          (Ref ref) => Stream.value(
            (entries ?? completionTestEntries())
                .where(
                  (TodoCompletionEntry entry) =>
                      entry.todo.id == progressTask.id,
                )
                .map((TodoCompletionEntry entry) => entry.step!)
                .toList(),
          ),
        ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    container.dispose();
    await database.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: _previewKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(brightness: brightness, palette: palette),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SafeArea(
              child: AndroidTodoCompletionHistory(
                onBack: () {},
                onEdit: onEdit ?? (TodoRecord todo) {},
                onReopen: onReopen ?? (TodoRecord todo) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

/// Loads portable SDK fonts normally and actual Chinese glyphs for opt-in previews.
Future<void> _loadFonts() async {
  // Package metadata resolves the current SDK without a machine-specific path.
  final File configFile = File('.dart_tool/package_config.json').absolute;
  // Parsed metadata contains the Flutter package root URI.
  final Map<String, dynamic> config =
      jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
  // Only the framework entry is needed to find its bundled fonts.
  final Map<String, dynamic> flutterPackage =
      (config['packages'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (Map<String, dynamic> entry) => entry['name'] == 'flutter',
          );
  // The SDK ships both text and icon fonts used by normal widget tests.
  final Uri fonts = Directory.fromUri(
    configFile.uri.resolve(flutterPackage['rootUri'] as String),
  ).parent.parent.uri.resolve('bin/cache/artifacts/material_fonts/');
  // Local Chinese fonts are required only when writing reviewable PNG artifacts.
  final File font =
      Platform.environment['OMNI_ANDROID_COMPLETION_PREVIEW'] == null
      ? File.fromUri(fonts.resolve('roboto-regular.ttf'))
      : File(
          Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
        );
  // Font bytes are reused for the theme families and the testing fallback.
  final ByteData bytes = ByteData.sublistView(await font.readAsBytes());
  // Registering every family prevents mixed real glyphs and placeholder boxes.
  for (final String family in <String>[
    'Ahem',
    'Roboto',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
  ]) {
    // Each loader registers one family with the same verified font file.
    final FontLoader loader = FontLoader(family);
    loader.addFont(Future<ByteData>.value(bytes));
    await loader.load();
  }
  // Real icons make layout screenshots useful for visual acceptance.
  final FontLoader icons = FontLoader('MaterialIcons');
  icons.addFont(
    Future<ByteData>.value(
      ByteData.sublistView(
        await File.fromUri(fonts.resolve('materialicons-regular.otf'))
            .readAsBytes(),
      ),
    ),
  );
  await icons.load();
}

/// Writes optional Chinese screenshots outside tracked visual baselines.
Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['OMNI_ANDROID_COMPLETION_PREVIEW'] == null) return;
  // The boundary contains the actual production widgets and root overlay routes.
  final RenderRepaintBoundary boundary =
      _previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // Dedicated output keeps the Android preview separate from desktop artifacts.
    final Directory directory = Directory(
      '../../output/android-todo-completion-preview',
    );
    await directory.create(recursive: true);
    // Logical resolution makes viewport sizes directly reviewable.
    final ui.Image rendered = await boundary.toImage(pixelRatio: 1);
    try {
      // PNG encoding is completed before disposing native image resources.
      final ByteData bytes = (await rendered.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      rendered.dispose();
    }
  });
}
