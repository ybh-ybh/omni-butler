import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_completion_checkbox.dart';
import 'package:omni_butler/features/todos/presentation/todos_page.dart';
import 'package:omni_butler/features/todos/presentation/windows_todo_completion_history.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

import 'support/todo_completion_test_data.dart';
import 'support/search_text_alignment.dart';

/// 验证 Windows 新完成历史的筛选、分组、后台刷新及真实渲染约束。
void main() {
  setUpAll(_loadFonts);

  // 统一搜索入口在宽窄、短窗、字号缩放和深色主题下均可操作。
  for (final (String, Size, double, Brightness) layout
      in <(String, Size, double, Brightness)>[
        ('wide', const Size(1440, 900), 1, Brightness.light),
        ('narrow', const Size(390, 760), 1, Brightness.light),
        ('short', const Size(1100, 430), 1, Brightness.light),
        ('large-text', const Size(640, 900), 2, Brightness.light),
        ('dark', const Size(1440, 900), 1, Brightness.dark),
      ]) {
    _historyTest('搜索内筛选面板真实选择日期并清空 ${layout.$1}', (WidgetTester tester) async {
      await _pumpHistory(
        tester,
        size: layout.$2,
        scale: layout.$3,
        brightness: layout.$4,
      );
      // 搜索表面保留与笔记相同的灰底和单一过滤入口。
      final Finder surface = find.byKey(
        const ValueKey<String>('todo-completion-search-surface'),
      );
      expect(tester.getSize(surface).height, greaterThanOrEqualTo(43.2));
      expect(find.text('开始日期'), findsNothing);
      expect(find.text('结束日期'), findsNothing);
      await _openSearchFilters(tester);
      // 整个筛选菜单必须留在当前窗口内，不能因窄窗或大字号裁掉入口。
      final Rect panel = tester.getRect(
        find.byKey(const ValueKey<String>('omni-windows-menu-surface')),
      );
      expect(panel.left, greaterThanOrEqualTo(0));
      expect(panel.right, lessThanOrEqualTo(layout.$2.width));
      expect(panel.top, greaterThanOrEqualTo(0));
      expect(panel.bottom, lessThanOrEqualTo(layout.$2.height));
      await _capturePreview(tester, 'search-filter-${layout.$1}');
      await tester.tap(
        find.byKey(const ValueKey<String>('todo-completion-start-date')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('24'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>('todo-completion-search-filter-panel'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('todo-completion-end-date')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('24'));
      await tester.pumpAndSettle();
      expect(find.text('1 项'), findsOneWidget);
      await _closeSearchFilters(tester);
      expect(find.text('昨天 · 完成 1 项'), findsOneWidget);
      // 已应用条件在菜单关闭后仍为搜索内图标保留选中反馈。
      final OmniIconButton filter = tester.widget<OmniIconButton>(
        find.byKey(const ValueKey<String>('todo-completion-search-filter')),
      );
      expect(filter.isSelected, isTrue);
      await _clearSearchFilters(tester);
      expect(find.text('7 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  // 数量尾部装饰覆盖常规、窄窗和双倍字号的实际编辑布局。
  for (final (String, Size, double) layout in <(String, Size, double)>[
    ('wide', const Size(1440, 900), 1),
    ('narrow', const Size(390, 760), 1),
    ('large-text', const Size(640, 900), 2),
  ]) {
    _historyTest('检索数量常驻搜索框且不挤占输入区域 ${layout.$1}', (WidgetTester tester) async {
      await _pumpHistory(tester, size: layout.$2, scale: layout.$3);
      // 所有焦点和输入状态共用真实搜索控件。
      final Finder search = find.byKey(
        const ValueKey<String>('todo-completion-search'),
      );
      // 数量保留原有身份，始终位于输入框内部。
      final Finder count = find.byKey(
        const ValueKey<String>('todo-completion-results-count'),
      );
      // 核对实际渲染边界，避免尾部数量盖住文字或光标。
      void verifyCount(String expected) {
        expectSearchTextCentered(
          tester,
          field: search,
          surface: find.byKey(
            const ValueKey<String>('todo-completion-search-surface'),
          ),
          hint: '搜索任务、子任务或章节',
        );
        expect(tester.widget<Text>(count).data, expected);
        expect(count.hitTestable(), findsOneWidget);
        // 搜索框的完整外边界。
        final Rect searchBounds = tester.getRect(search);
        // 尾部数量的实际文字边界。
        final Rect countBounds = tester.getRect(count);
        // 编辑内容独占的实际区域。
        final Rect inputBounds = tester.getRect(
          find.descendant(of: search, matching: find.byType(EditableText)),
        );
        expect(searchBounds.contains(countBounds.topLeft), isTrue);
        expect(searchBounds.contains(countBounds.bottomRight), isTrue);
        expect(inputBounds.right, lessThanOrEqualTo(countBounds.left));
        expect(countBounds.center.dy, closeTo(searchBounds.center.dy, 1));
        expect(find.textContaining('完成记录 ·'), findsNothing);
      }

      verifyCount('7 项');
      await tester.tap(search);
      await tester.pump();
      verifyCount('7 项');
      await tester.enterText(search, 'Java');
      await tester.pump();
      verifyCount('3 项');
      await tester.enterText(search, '没有对应任务的检索内容');
      await tester.pump();
      verifyCount('0 项');
      expect(find.text('没有匹配的完成记录'), findsOneWidget);
      await _capturePreview(tester, 'results-empty-${layout.$1}');
      await _clearSearchFilters(tester);
      verifyCount('7 项');
      expect(tester.takeException(), isNull);
    });
  }

  _historyTest('日期使用次要小字且任务以统一留白分组', (WidgetTester tester) async {
    await _pumpHistory(tester);
    // 第一个日期使用十二像素顶部留白。
    final Finder firstDay = find.byKey(
      const ValueKey<String>('todo-completion-row-day-2026-10-25'),
    );
    // 后续日期使用十六像素顶部留白。
    final Finder nextDay = find.byKey(
      const ValueKey<String>('todo-completion-row-day-2026-10-24'),
    );
    expect(
      tester.getTopLeft(find.text('今天 · 完成 5 项')).dy -
          tester.getTopLeft(firstDay).dy,
      12,
    );
    expect(
      tester.getTopLeft(find.text('昨天 · 完成 1 项')).dy -
          tester.getTopLeft(nextDay).dy,
      16,
    );
    // 日期继承当前主题的次要文字样式，明暗配色不使用硬编码灰色。
    final Text day = tester.widget<Text>(find.text('今天 · 完成 5 项'));
    // 日期标题对应的主题上下文。
    final BuildContext context = tester.element(firstDay);
    expect(
      day.style!.fontSize,
      Theme.of(context).textTheme.bodySmall!.fontSize,
    );
    expect(day.style!.color, OmniColors.of(context).muted);
    expect(day.style!.fontWeight, FontWeight.w400);
    // 两个同日可折叠组和前面的独立任务共享四像素外间距。
    for (final String id in <String>['release', 'java']) {
      // 轻量行的完整布局范围包含统一顶部间距。
      final Finder row = find.byKey(
        ValueKey<String>('todo-completion-row-group-2026-10-25-$id'),
      );
      // 实际可交互的任务标题行。
      final Finder group = find.byKey(
        ValueKey<String>('todo-completion-group-2026-10-25-$id'),
      );
      expect(tester.getTopLeft(group).dy - tester.getTopLeft(row).dy, 4);
    }
    expect(
      find.descendant(
        of: find.byKey(const PageStorageKey<String>('todo-completion-results')),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );
    await _capturePreview(tester, 'results-card-collapsed');
  });

  // 长标题与展开明细分别核对明暗主题的真实渲染。
  for (final Brightness brightness in Brightness.values) {
    _historyTest('长标题展开明细保持缩进和操作 ${brightness.name}', (
      WidgetTester tester,
    ) async {
      // 同日多次完成的长标题进度任务，用于验证自然换行。
      final TodoRecord root = completionTestTodo(
        'long',
        '整理本季度项目中积累的架构设计与接口联调实践并补充完整的中文说明和回顾记录',
        progress: true,
      );
      await _pumpHistory(
        tester,
        brightness: brightness,
        size: const Size(640, 900),
        scale: 1.5,
        entries: <TodoCompletionEntry>[
          ...completionTestEntries(),
          completionTestEntry(
            'long-step',
            DateTime(2026, 10, 25, 13),
            todo: root,
            ordinal: 9,
            stepName: '核对服务端接口的异常响应、中文长标题显示以及任务完成记录的检索与分组规则',
          ),
        ],
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('todo-completion-toggle-2026-10-25-long'),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('todo-completion-entry-long-step')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _capturePreview(tester, 'results-long-title-${brightness.name}');
    });
  }

  for (final (String, Size, double) layout in <(String, Size, double)>[
    ('wide', const Size(1440, 900), 1),
    ('narrow', const Size(390, 760), 1),
    ('large-text', const Size(640, 900), 2),
  ]) {
    _historyTest('Windows历史入口和退出始终可访问 ${layout.$1}', (
      WidgetTester tester,
    ) async {
      await _pumpHistory(
        tester,
        wholePage: true,
        size: layout.$2,
        scale: layout.$3,
      );
      expect(
        find.byWidgetPredicate(
          (Widget widget) => widget is OmniSegmentedButton,
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('todo-history-open')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('todo-primary-create')),
        findsOneWidget,
      );
      if (layout.$1 == 'wide') {
        // 历史入口与新增待办同行，位于页头右侧。
        final Rect history = tester.getRect(
          find.byKey(const ValueKey<String>('todo-history-open')),
        );
        // 新增待办继续作为最右侧主操作。
        final Rect create = tester.getRect(
          find.byKey(const ValueKey<String>('todo-primary-create')),
        );
        expect(history.center.dy, closeTo(create.center.dy, 1));
        expect(history.right, lessThan(create.left));
        expect(history.left, greaterThan(layout.$2.width / 2));
      }
      await _capturePreview(tester, 'navigation-active-${layout.$1}');
      await tester.tap(find.byKey(const ValueKey<String>('todo-history-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey<String>('todo-history-exit')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('todo-history-open')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('todo-primary-create')),
        findsNothing,
      );
      expect(find.text('退出'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capturePreview(tester, 'navigation-history-${layout.$1}');
      await tester.tap(find.byKey(const ValueKey<String>('todo-history-exit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('每日待办'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('todo-history-open')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  _historyTest('同日按所属任务合并默认收起，展开后仅操作具体子任务', (WidgetTester tester) async {
    // 实际触发的任务身份，防止错误级联父任务。
    final List<String> reopened = <String>[];
    // 实际编辑的任务身份。
    final List<String> edited = <String>[];
    await _pumpHistory(
      tester,
      onReopen: (TodoRecord todo) => reopened.add(todo.id),
      onEdit: (TodoRecord todo) => edited.add(todo.id),
    );
    expect(find.text('7 项'), findsOneWidget);
    expect(find.text('今天 · 完成 5 项'), findsOneWidget);
    expect(find.text('检查构建'), findsNothing);
    expect(
      find.byKey(
        const ValueKey<String>('todo-completion-details-2026-10-25-release'),
      ),
      findsNothing,
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('todo-completion-toggle-2026-10-25-release'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('检查构建'), findsOneWidget);
    expect(find.text('整理说明'), findsOneWidget);
    await _capturePreview(tester, 'expanded-release');
    // 子任务的完成复选框必须指向子任务自身。
    final Finder build = find.byKey(
      const ValueKey<String>('todo-completion-entry-build'),
    );
    await tester.tap(
      find.descendant(of: build, matching: find.byType(TodoCompletionCheckbox)),
    );
    await tester.pump();
    expect(reopened, <String>['build']);
    await tester.tap(
      find.descendant(of: build, matching: find.byType(OmniIconButton)),
    );
    await tester.pump();
    expect(edited, <String>['build']);
    expect(tester.takeException(), isNull);
  });

  _historyTest('检索父任务和章节自动展开，类型与日期取交集且上方统计保持完整', (WidgetTester tester) async {
    await _pumpHistory(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('todo-completion-search')),
      '  JAVA  ',
    );
    await tester.pump();
    expect(find.text('3 项'), findsOneWidget);
    expect(find.text('集合与泛型'), findsOneWidget);
    expect(find.text('第8章'), findsOneWidget);
    expect(find.text('并发与线程池'), findsOneWidget);
    await _capturePreview(tester, 'search-java');
    expect(_stat(tester, 7), '6');
    // 热力图日期替换同一个日期条件。
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-day-2026-10-25')),
    );
    await tester.pump();
    expect(find.text('2 项'), findsOneWidget);
    expect(find.text('并发与线程池'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-kind-normal')),
    );
    await tester.pump();
    expect(find.text('没有匹配的完成记录'), findsOneWidget);
    expect(_stat(tester, 7), '6');
    await _clearSearchFilters(tester);
    expect(find.text('7 项'), findsOneWidget);
    expect(find.text('检查构建'), findsNothing);
  });

  _historyTest('类型仅普通与进度两项，普通任务包含子任务且可取消筛选', (WidgetTester tester) async {
    await _pumpHistory(tester);
    expect(find.text('普通任务'), findsOneWidget);
    expect(find.text('进度任务'), findsOneWidget);
    expect(find.text('全部'), findsNothing);
    expect(find.text('子任务'), findsNothing);
    expect(find.text('章节进度'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-kind-normal')),
    );
    await tester.pump();
    expect(find.text('4 项'), findsOneWidget);
    expect(find.text('回复邮件'), findsOneWidget);
    expect(find.text('归档旧资料'), findsOneWidget);
    expect(find.text('Java 学习'), findsNothing);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('todo-completion-toggle-2026-10-25-release'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('检查构建'), findsOneWidget);
    expect(find.text('整理说明'), findsOneWidget);
    expect(_stat(tester, 7), '6');
    await _capturePreview(tester, 'types-normal');
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-kind-progress')),
    );
    await tester.pump();
    expect(find.text('3 项'), findsOneWidget);
    expect(find.text('项目收尾'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-kind-progress')),
    );
    await tester.pump();
    expect(find.text('7 项'), findsOneWidget);
    expect(find.text('检查构建'), findsOneWidget);
  });

  for (final double scale in <double>[1, 1.5]) {
    _historyTest('类型和月份条目与助手任务行同高并容纳放大字号 $scale', (WidgetTester tester) async {
      await _pumpHistory(tester, scale: scale);
      for (final String key in <String>[
        'todo-completion-kind-normal',
        'todo-completion-kind-progress',
        'todo-completion-all-dates',
        'todo-completion-month-2026-10',
        'todo-completion-month-2024-05',
      ]) {
        // 比较实际渲染区域，而非只核对组件声明的最小高度。
        final Finder row = find.byKey(ValueKey<String>(key));
        // 选择项的完整点击与悬停区域。
        final Rect bounds = tester.getRect(row);
        expect(
          bounds.height,
          greaterThanOrEqualTo(AssistantWindowsMetrics.historyHeight),
        );
        if (scale == 1) {
          expect(bounds.height, AssistantWindowsMetrics.historyHeight);
        }
        // 行标题和右侧数量或勾选都应在行的垂直区域内。
        for (final Element text
            in find
                .descendant(of: row, matching: find.byType(Text))
                .evaluate()) {
          // 文字的真实排版边界。
          final Rect textBounds = tester.getRect(
            find.byElementPredicate((Element element) => element == text),
          );
          expect(textBounds.top, greaterThanOrEqualTo(bounds.top));
          expect(textBounds.bottom, lessThanOrEqualTo(bounds.bottom));
        }
      }
      await _capturePreview(tester, 'archive-row-height-$scale');
      // 点击行的底部边缘仍选中对应月份。
      await tester.tapAt(
        tester
                .getRect(
                  find.byKey(
                    const ValueKey<String>('todo-completion-month-2024-05'),
                  ),
                )
                .bottomCenter -
            const Offset(0, 1),
      );
      await tester.pump();
      expect(find.text('归档旧资料'), findsOneWidget);
      expect(find.text('1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  _historyTest('日期范围包含首尾、月份替换范围且能查询一年以前的历史', (WidgetTester tester) async {
    await _pumpHistory(tester);
    await _openSearchFilters(tester);
    // 日期组件已有单独交互测试，本用例验证历史页的范围回调契约。
    final OmniDatePickerButton start = tester.widget<OmniDatePickerButton>(
      find.byKey(const ValueKey<String>('todo-completion-start-date')),
    );
    start.onChanged!(DateTime(2026, 10, 24));
    await tester.pump();
    // 结束日期同样包含当日全部完成项。
    final OmniDatePickerButton end = tester.widget<OmniDatePickerButton>(
      find.byKey(const ValueKey<String>('todo-completion-end-date')),
    );
    end.onChanged!(DateTime(2026, 10, 24));
    await tester.pump();
    expect(find.text('1 项'), findsOneWidget);
    await _closeSearchFilters(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-month-2024-05')),
    );
    await tester.pump();
    expect(find.text('归档旧资料'), findsOneWidget);
    await _openSearchFilters(tester);
    expect(find.text('2024-05-01'), findsOneWidget);
    expect(find.text('2024-05-31'), findsOneWidget);
    await _closeSearchFilters(tester);
    expect(find.text('1 项'), findsOneWidget);
    expect(_stat(tester, 365), '6');
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-day-2026-10-23')),
    );
    await tester.pump();
    // 空日期不覆盖已有的月份筛选。
    expect(find.text('归档旧资料'), findsOneWidget);
    expect(find.text('1 项'), findsOneWidget);
    await _openSearchFilters(tester);
    expect(find.text('2024-05-01'), findsOneWidget);
    expect(find.text('2024-05-31'), findsOneWidget);
    await _closeSearchFilters(tester);
  });

  _historyTest('刷新、延迟重读和失败保留检索、展开和已有列表，重试后可继续更新', (WidgetTester tester) async {
    // 可控订阅模拟同源后台刷新与依赖重载。
    final StreamController<List<TodoCompletionEntry>> controller =
        StreamController<List<TodoCompletionEntry>>.broadcast();
    addTearDown(controller.close);
    // 每次订阅都使用同一可控数据源。
    final ProviderContainer container = await _pumpHistory(
      tester,
      stream: controller.stream,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    controller.add(completionTestEntries());
    await tester.pump();
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('todo-completion-search')),
      'java',
    );
    await tester.pump();
    // 分组元素与输入框应在刷新期间保持同一身份。
    final Element groupElement = tester.element(
      find.byKey(
        const ValueKey<String>('todo-completion-group-2026-10-25-java'),
      ),
    );
    container.invalidate(todoCompletionEntriesProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('第8章'), findsOneWidget);
    expect(
      tester.element(
        find.byKey(
          const ValueKey<String>('todo-completion-group-2026-10-25-java'),
        ),
      ),
      same(groupElement),
    );
    controller.addError(StateError('模拟读取失败'));
    await tester.pump();
    await tester.pump();
    expect(find.text('完成历史读取失败'), findsOneWidget);
    expect(find.text('第8章'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    controller.add(
      completionTestEntries()
          .where((TodoCompletionEntry entry) => entry.id != 'chapter-8')
          .toList(),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('第8章'), findsNothing);
    expect(find.text('2 项'), findsOneWidget);
    expect(find.text('完成历史读取失败'), findsNothing);
    expect(
      tester
          .widget<OmniTextField>(
            find.byKey(const ValueKey<String>('todo-completion-search')),
          )
          .controller!
          .text,
      'java',
    );
  });

  _historyTest('首次读取失败提供重试，空数据展示完整空概览', (WidgetTester tester) async {
    // 同一个数据源先失败，重试后返回真实空结果。
    final StreamController<List<TodoCompletionEntry>> controller =
        StreamController<List<TodoCompletionEntry>>.broadcast();
    addTearDown(controller.close);
    // 初始错误没有旧数据，不应显示空历史伪装成功。
    await _pumpHistory(tester, stream: controller.stream);
    controller.addError(StateError('失败'));
    await tester.pump();
    await tester.pump();
    expect(find.text('完成历史读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    controller.add(<TodoCompletionEntry>[]);
    await tester.pump();
    await tester.pump();
    expect(find.text('还没有完成记录'), findsOneWidget);
    expect(_stat(tester, 365), '0');
  });

  _historyTest('跨午夜没有业务变动也更新七天窗口与热力图末日', (WidgetTester tester) async {
    // 七天窗口最早一天在午夜后移出统计。
    final ProviderContainer container = await _pumpHistory(
      tester,
      entries: <TodoCompletionEntry>[
        completionTestEntry('edge', DateTime(2026, 10, 19, 23, 59)),
      ],
    );
    expect(_stat(tester, 7), '1');
    container.updateOverrides([
      nowProvider.overrideWithValue(DateTime(2026, 10, 26)),
      todoCompletionEntriesProvider.overrideWith(
        (Ref ref) => Stream.value(<TodoCompletionEntry>[
          completionTestEntry('edge', DateTime(2026, 10, 19, 23, 59)),
        ]),
      ),
    ]);
    await tester.pump();
    expect(_stat(tester, 7), '0');
    expect(
      find.byKey(const ValueKey<String>('todo-completion-day-2026-10-26')),
      findsOneWidget,
    );
  });

  _historyTest('窄窗口的筛选入口保留全部月份及类型', (WidgetTester tester) async {
    await _pumpHistory(tester, size: const Size(640, 760));
    // 窄窗仍显示固定星期标签，统计移入下方结果卡片。
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('周四'), findsOneWidget);
    expect(find.text('周日'), findsOneWidget);
    expect(_stat(tester, 7), '6');
    expect(
      find.byKey(const ValueKey<String>('todo-completion-archive')),
      findsNothing,
    );
    await _openSearchFilters(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-compact-filters')),
    );
    await tester.pumpAndSettle();
    expect(find.text('普通任务'), findsOneWidget);
    expect(find.text('进度任务'), findsOneWidget);
    expect(find.text('全部'), findsNothing);
    expect(find.text('子任务'), findsNothing);
    await tester.tap(find.text('进度任务'));
    await tester.pumpAndSettle();
    expect(find.text('3 项'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-compact-filters')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通任务'));
    await tester.pumpAndSettle();
    expect(find.text('4 项'), findsOneWidget);
    // 嵌套类型选择返回后，清空仍直接清除新条件并关闭外层面板。
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-completion-clear')),
    );
    await tester.pumpAndSettle();
    expect(find.text('7 项'), findsOneWidget);
    expect(find.text('项目收尾'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _historyTest('热力图只有三百六十五个有效日期，键盘聚焦也显示日期数量', (WidgetTester tester) async {
    await _pumpHistory(tester);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'todo-completion-day-',
            ),
      ),
      findsNWidgets(365),
    );
    // 今天格的真实后代位于日期按钮的焦点域内。
    final Finder day = find.byKey(
      const ValueKey<String>('todo-completion-day-2026-10-25'),
    );
    // 用原生焦点系统进入按钮，覆盖非鼠标用户的提示。
    final BuildContext focusContext = tester.element(
      find.descendant(of: day, matching: find.byType(SizedBox)).last,
    );
    Focus.of(focusContext).requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2026年10月25日 · 完成 5 项'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('5 项'), findsOneWidget);
  });

  _historyTest('热力图无卡片且居中，三项统计横排在左栏顶部', (WidgetTester tester) async {
    await _pumpHistory(tester);
    // 三项数字沿同一水平线排列。
    final Rect week = tester.getRect(
      find.byKey(const ValueKey<String>('todo-completion-stat-7')),
    );
    // 月统计在周统计右侧。
    final Rect month = tester.getRect(
      find.byKey(const ValueKey<String>('todo-completion-stat-30')),
    );
    // 年统计在最右侧。
    final Rect year = tester.getRect(
      find.byKey(const ValueKey<String>('todo-completion-stat-365')),
    );
    // 统计整体位于下方左栏卡片顶部。
    final Rect statistics = tester.getRect(
      find.byKey(const ValueKey<String>('todo-completion-statistics')),
    );
    // 图表视口在整页可用宽度内居中。
    final Rect chart = tester.getRect(
      find.byKey(const ValueKey<String>('todo-completion-heatmap-viewport')),
    );
    // 热力图外层仅保留间距，不再包裹卡片。
    final Rect overview = tester.getRect(
      find.byKey(const ValueKey<String>('todo-completion-overview')),
    );
    // 下方左栏的实际卡片位置。
    final Rect archive = tester.getRect(
      find.byKey(const ValueKey<String>('todo-completion-archive')),
    );
    expect(week.top, closeTo(month.top, 0.1));
    expect(month.top, closeTo(year.top, 0.1));
    expect(week.right, lessThan(month.left));
    expect(month.right, lessThan(year.left));
    expect(statistics.top, greaterThanOrEqualTo(archive.top));
    expect(statistics.right, lessThanOrEqualTo(archive.right));
    expect(
      statistics.bottom,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('todo-completion-kind-normal')),
            )
            .dy,
      ),
    );
    expect(chart.center.dx, closeTo(overview.center.dx, 0.1));
    expect(chart.bottom, lessThan(archive.top));
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('todo-completion-overview')),
        matching: find.byType(OmniPanel),
      ),
      findsNothing,
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey<String>('todo-completion-day-2026-10-25')),
      ),
      const Size(16, 16),
    );
    // 相邻日期的中心距离为十六像素格子加六像素间距。
    expect(
      tester
              .getCenter(
                find.byKey(
                  const ValueKey<String>('todo-completion-day-2026-10-25'),
                ),
              )
              .dy -
          tester
              .getCenter(
                find.byKey(
                  const ValueKey<String>('todo-completion-day-2026-10-24'),
                ),
              )
              .dy,
      22,
    );
    for (final (int, String) weekday in <(int, String)>[
      (0, '2026-10-19'),
      (3, '2026-10-22'),
      (6, '2026-10-25'),
    ]) {
      expect(
        tester
            .getCenter(
              find.byKey(
                ValueKey<String>('todo-completion-weekday-${weekday.$1}'),
              ),
            )
            .dy,
        tester
            .getCenter(
              find.byKey(ValueKey<String>('todo-completion-day-${weekday.$2}')),
            )
            .dy,
      );
    }
    expect(find.text('周二'), findsNothing);
    expect(find.text('周三'), findsNothing);
    expect(find.text('周五'), findsNothing);
    expect(find.text('周六'), findsNothing);
    expect(find.textContaining('2025.10.26'), findsNothing);
    expect(find.text('少'), findsNothing);
    expect(find.text('多'), findsNothing);
  });

  _historyTest('周月年只显示短标签，悬停各自显示完整统计周期', (WidgetTester tester) async {
    await _pumpHistory(tester);
    // 真实鼠标悬停验证提示，而非只读取 Tooltip 参数。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    for (final (String, String, int) statistic in <(String, String, int)>[
      ('周', '最近一周', 7),
      ('月', '最近一个月', 30),
      ('年', '最近一年', 365),
    ]) {
      expect(find.text(statistic.$1), findsOneWidget);
      expect(find.text(statistic.$2), findsNothing);
      expect(
        tester.getTopLeft(find.text(statistic.$1)).dy,
        greaterThan(
          tester
              .getBottomLeft(
                find.byKey(
                  ValueKey<String>('todo-completion-stat-${statistic.$3}'),
                ),
              )
              .dy,
        ),
      );
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(
            ValueKey<String>('todo-completion-stat-tip-${statistic.$3}'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // 等待提示完成淡入，预览也必须包含真实可见的文字。
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(statistic.$2), findsOneWidget);
      if (statistic.$3 == 7) {
        await _capturePreview(tester, 'statistics-week-hover');
      }
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
    }
    await mouse.removePointer();
  });

  for (final double width in <double>[1440, 640]) {
    _historyTest('统计提示在原生读屏启用时保留三个独立锚点 $width', (WidgetTester tester) async {
      // 普通视觉测试未开启语义树，不能覆盖 Windows AXTree 更新。
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        await _pumpHistory(tester, size: Size(width, 900), wholePage: true);
        await tester.tap(
          find.byKey(const ValueKey<String>('todo-history-open')),
        );
        await tester.pumpAndSettle();
        // 同时存在的三个 Tooltip 必须拥有不同且可达的语义节点。
        final Set<int> anchorIds = <int>{
          for (final int days in <int>[7, 30, 365])
            tester
                .getSemantics(
                  find.byKey(
                    ValueKey<String>('todo-completion-stat-tip-$days'),
                  ),
                )
                .id,
        };
        expect(anchorIds, hasLength(3));
        // 实际移动鼠标创建、切换并移除提示浮层。
        final TestGesture mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        for (final (int, String) statistic in <(int, String)>[
          (7, '最近一周'),
          (30, '最近一个月'),
          (365, '最近一年'),
        ]) {
          await mouse.moveTo(
            tester.getCenter(
              find.byKey(
                ValueKey<String>('todo-completion-stat-tip-${statistic.$1}'),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 200));
          expect(find.text(statistic.$2), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        // 提示仍存在时退出历史，验证锚点和浮层一并释放。
        await tester.tap(
          find.byKey(const ValueKey<String>('todo-history-exit')),
        );
        await tester.pumpAndSettle();
        expect(find.text('每日待办'), findsOneWidget);
        expect(find.text('最近一年'), findsNothing);
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  _historyTest('窄窗横向滚动保留星期标签且日期不会覆盖标签旁留白', (WidgetTester tester) async {
    await _pumpHistory(
      tester,
      entries: completionPreviewEntries(),
      size: const Size(640, 760),
    );
    // 实际绘制边界用于采样统计与图表之间的留白。
    final RenderRepaintBoundary boundary =
        _previewKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    // 固定星期列的右边界。
    final Rect weekdays = tester.getRect(
      find.byKey(const ValueKey<String>('todo-completion-weekdays')),
    );
    // 横向滚动只改变网格，不移动星期列。
    final ScrollableState grid = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(
              const ValueKey<String>('todo-completion-heatmap-scroll'),
            ),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(grid.position.maxScrollExtent, greaterThan(0));
    grid.position.jumpTo(0);
    await tester.pump();
    expect(
      tester.getRect(
        find.byKey(const ValueKey<String>('todo-completion-weekdays')),
      ),
      weekdays,
    );
    grid.position.jumpTo(grid.position.maxScrollExtent);
    await tester.pump();
    // 最后一行的中心能稳定穿过滚出视口的旧日期格。
    final Rect day = tester.getRect(
      find.byKey(const ValueKey<String>('todo-completion-day-2026-10-25')),
    );
    // 热力图已去掉卡片，留白保持页面背景色。
    final Color expected = Theme.of(
      tester.element(
        find.byKey(const ValueKey<String>('todo-completion-overview')),
      ),
    ).scaffoldBackgroundColor;
    // 读取真实引擎像素，避免只验证布局矩形却漏掉越界绘制。
    final Color? actual = await tester.runAsync(() async {
      // 逻辑像素截图对应测试视口。
      final ui.Image rendered = await boundary.toImage(pixelRatio: 1);
      try {
        // 原始 RGBA 像素用于核对统计旁边没有日期色块。
        final ByteData bytes = (await rendered.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        // 星期列与图表之间取一像素，避开文字本身。
        final int offset =
            (day.center.dy.floor() * rendered.width +
                (weekdays.right + 4).floor()) *
            4;
        return Color.fromARGB(
          bytes.getUint8(offset + 3),
          bytes.getUint8(offset),
          bytes.getUint8(offset + 1),
          bytes.getUint8(offset + 2),
        );
      } finally {
        rendered.dispose();
      }
    });
    expect(actual, expected);
  });

  _historyTest('热力图空格只放大，有记录悬停发光，点击同日切换筛选', (WidgetTester tester) async {
    await _pumpHistory(tester);
    // 空格和相邻有记录日期位于同一列，便于核对缩放不移动布局。
    final Finder empty = find.byKey(
      const ValueKey<String>('todo-completion-day-2026-10-23'),
    );
    // 当天有五个完成单元。
    final Finder filled = find.byKey(
      const ValueKey<String>('todo-completion-day-2026-10-25'),
    );
    // 相邻行在缩放前的布局位置。
    final Rect original = tester.getRect(filled);
    // 真实鼠标路径驱动热力图悬停。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(empty));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 验证实际中间帧，而不只检查动画目标。
    final Transform transform = tester.widget<Transform>(
      find
          .descendant(
            of: find.byKey(
              const ValueKey<String>('todo-completion-scale-2026-10-23'),
            ),
            matching: find.byType(Transform),
          )
          .first,
    );
    expect(transform.transform.storage[0], greaterThan(1));
    expect(transform.transform.storage[0], lessThan(1.2));
    await tester.pump(const Duration(milliseconds: 150));
    // 空日期没有光晕与悬停提示。
    final BoxDecoration emptyDecoration =
        tester
                .widget<AnimatedContainer>(
                  find.byKey(
                    const ValueKey<String>('todo-completion-fill-2026-10-23'),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(emptyDecoration.boxShadow, isEmpty);
    expect(
      find.ancestor(of: empty, matching: find.byType(Tooltip)),
      findsNothing,
    );
    expect(tester.getRect(filled), original);
    await tester.tap(empty);
    await tester.pump();
    expect(find.text('7 项'), findsOneWidget);
    await mouse.moveTo(tester.getCenter(filled));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    // 实际绘制的主题色光晕应已经出现。
    final BoxDecoration painted =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.byKey(
                          const ValueKey<String>(
                            'todo-completion-fill-2026-10-25',
                          ),
                        ),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(painted.boxShadow!.single.color.a, greaterThan(0));
    expect(find.text('2026年10月25日 · 完成 5 项'), findsOneWidget);
    await _capturePreview(tester, 'heatmap-filled-hover');
    await tester.tap(filled);
    await tester.pump();
    expect(find.text('5 项'), findsOneWidget);
    await mouse.moveTo(tester.getCenter(empty));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(empty);
    await tester.pump();
    expect(find.text('5 项'), findsOneWidget);
    await tester.tap(filled);
    await tester.pump();
    expect(find.text('7 项'), findsOneWidget);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  _historyTest('减少动画时日期不缩放，仍保留主题颜色反馈', (WidgetTester tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pumpHistory(tester);
    // 真实鼠标进入有记录的日期。
    final TestGesture mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey<String>('todo-completion-day-2026-10-25')),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<AnimatedScale>(
            find.byKey(
              const ValueKey<String>('todo-completion-scale-2026-10-25'),
            ),
          )
          .scale,
      1,
    );
    expect(
      (tester
                  .widget<AnimatedContainer>(
                    find.byKey(
                      const ValueKey<String>('todo-completion-fill-2026-10-25'),
                    ),
                  )
                  .decoration!
              as BoxDecoration)
          .boxShadow,
      hasLength(1),
    );
    await mouse.removePointer();
  });

  _historyTest('搜索千步父任务也只构建可见明细', (WidgetTester tester) async {
    // 合法上限的进度任务用于验证展开后的真实惰性行为。
    final TodoRecord root = completionTestTodo(
      'large',
      '千步学习计划',
      progress: true,
    );
    await _pumpHistory(
      tester,
      entries: <TodoCompletionEntry>[
        for (int index = 1; index <= 1000; index += 1)
          completionTestEntry(
            'large-$index',
            DateTime(2026, 10, 25, 10),
            todo: root,
            ordinal: index,
          ),
      ],
    );
    // 点击展开首帧也不得为了填满零高度列表而一次挂载千行。
    final Finder toggle = find.byKey(
      const ValueKey<String>('todo-completion-toggle-2026-10-25-large'),
    );
    await tester.tap(toggle);
    await tester.pump();
    // 展开、半展开与收起三个阶段均按原视口惰性布局。
    for (int frame = 0; frame < 3; frame++) {
      expect(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'todo-completion-entry-',
                  ),
            )
            .evaluate()
            .length,
        lessThan(30),
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('todo-completion-entry-large-1')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('todo-completion-search')),
      '千步',
    );
    await tester.pump();
    expect(find.text('1000 项'), findsOneWidget);
    // 断言实际创建的行数，避免只检查外层 ListView 的声明。
    final int built = find
        .byWidgetPredicate(
          (Widget widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'todo-completion-entry-',
              ),
        )
        .evaluate()
        .length;
    expect(built, greaterThan(0));
    expect(built, lessThan(30));
    expect(tester.takeException(), isNull);
  });

  // 所有配色在明暗主题下都检查实际布局，预览模式另存中文截图。
  for (final AppThemePalette palette in AppThemePalette.values) {
    for (final Brightness brightness in Brightness.values) {
      _historyTest('完成历史渲染 ${palette.name} ${brightness.name}', (
        WidgetTester tester,
      ) async {
        await _pumpHistory(
          tester,
          entries: completionPreviewEntries(),
          palette: palette,
          brightness: brightness,
        );
        expect(
          find.byKey(const ValueKey<String>('todo-completion-overview')),
          findsOneWidget,
        );
        // 日期与清空不再占据工具栏，统一收进搜索尾部的筛选菜单。
        expect(
          find.byKey(const ValueKey<String>('todo-completion-start-date')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('todo-completion-clear')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(
              const ValueKey<String>('todo-completion-search-surface'),
            ),
            matching: find.byKey(
              const ValueKey<String>('todo-completion-search-filter'),
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await _capturePreview(
          tester,
          '${palette.name}-${brightness.name}-1440',
        );
      });
    }
  }

  for (final (String, Size, double) layout in <(String, Size, double)>[
    ('narrow', const Size(640, 760), 1),
    ('short', const Size(1100, 430), 1),
    ('large-text', const Size(900, 760), 2),
  ]) {
    _historyTest('完成历史窗口 ${layout.$1} 无溢出且能滚动至任务', (WidgetTester tester) async {
      await _pumpHistory(
        tester,
        entries: completionPreviewEntries(),
        size: layout.$2,
        scale: layout.$3,
      );
      expect(tester.takeException(), isNull);
      if (layout.$1 != 'narrow') {
        // 短窗或大字号先滚出概览，为结果列表腾出空间。
        // 只滚出外层概览，不把已惰性构建的第一条结果继续滚出视口。
        final NestedScrollViewState state = tester.state<NestedScrollViewState>(
          find.byKey(const ValueKey<String>('todo-completion-short-scroll')),
        );
        state.outerController.jumpTo(
          state.outerController.position.maxScrollExtent,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(find.text('回复邮件'), findsOneWidget);
      await _capturePreview(tester, layout.$1);
    });
  }
}

/// 全部测试使用同一绘制边界，便于输出真实渲染预览。
final GlobalKey _previewKey = GlobalKey();

/// 由测试框架管理平台覆盖的创建与恢复，保证不污染下一项用例。
void _historyTest(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.windows),
);

/// 从搜索框右侧打开日期与清空筛选菜单。
Future<void> _openSearchFilters(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('todo-completion-search-filter')),
  );
  await tester.pumpAndSettle();
}

/// 使用真实 Escape 关闭筛选菜单，保留已经选择的即时条件。
Future<void> _closeSearchFilters(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey<String>('todo-completion-search-filter-panel')),
    findsNothing,
  );
}

/// 从嵌入式筛选面板清空关键词、类型和日期。
Future<void> _clearSearchFilters(WidgetTester tester) async {
  await _openSearchFilters(tester);
  await tester.tap(find.byKey(const ValueKey<String>('todo-completion-clear')));
  await tester.pumpAndSettle();
}

/// 从界面读取统计值而不依赖内部汇总实现。
String? _stat(WidgetTester tester, int days) => tester
    .widget<Text>(find.byKey(ValueKey<String>('todo-completion-stat-$days')))
    .data;

/// 使用生产主题及独立只读完成流构建 Windows 页面。
Future<ProviderContainer> _pumpHistory(
  WidgetTester tester, {
  List<TodoCompletionEntry>? entries,
  Stream<List<TodoCompletionEntry>>? stream,
  ValueChanged<TodoRecord>? onEdit,
  ValueChanged<TodoRecord>? onReopen,
  Size size = const Size(1440, 900),
  double scale = 1,
  AppThemePalette palette = AppThemePalette.classicBlue,
  Brightness brightness = Brightness.light,
  bool wholePage = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 完整页面也只访问隔离内存数据库。
  final AppDatabase? database = wholePage
      ? AppDatabase.forTesting(NativeDatabase.memory())
      : null;
  // 测试私有 Provider 容器不启动同步、通知或真实数据库。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      if (database != null) appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 10, 25, 12)),
      todoCompletionEntriesProvider.overrideWith(
        (Ref ref) => stream ?? Stream.value(entries ?? completionTestEntries()),
      ),
    ],
  );
  if (database == null) {
    addTearDown(container.dispose);
  } else {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await database.close();
    });
  }
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
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: wholePage
                  ? const TodosPage()
                  : WindowsTodoCompletionHistory(
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
  await tester.pump(const Duration(milliseconds: 200));
  return container;
}

/// 普通测试加载 SDK 字体，显式预览加载真实中文字体。
Future<void> _loadFonts() async {
  // 当前包配置用于定位 Flutter 自带字体，兼容其他开发机和 CI。
  final File configFile = File('.dart_tool/package_config.json').absolute;
  // Flutter 的实际 SDK 包路径。
  final Map<String, dynamic> config =
      jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
  // 当前 Flutter 包的元数据。
  final Map<String, dynamic> flutterPackage =
      (config['packages'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (Map<String, dynamic> entry) => entry['name'] == 'flutter',
          );
  // SDK 自带 Material 字体目录。
  final Uri fonts = Directory.fromUri(
    configFile.uri.resolve(flutterPackage['rootUri'] as String),
  ).parent.parent.uri.resolve('bin/cache/artifacts/material_fonts/');
  // 仅预览模式依赖本机中文字体。
  final File font = Platform.environment['OMNI_COMPLETION_PREVIEW'] == null
      ? File.fromUri(fonts.resolve('roboto-regular.ttf'))
      : File(
          Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
        );
  // 所有主题候选字体共用可验证的真实字形。
  final ByteData bytes = ByteData.sublistView(await font.readAsBytes());
  for (final String family in <String>[
    'Ahem',
    'Roboto',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
  ]) {
    // 当前候选字体家族。
    final FontLoader loader = FontLoader(family);
    loader.addFont(Future.value(bytes));
    await loader.load();
  }
  // 图标也使用 SDK 的真实字体，避免只画出空白热区。
  final FontLoader icons = FontLoader('MaterialIcons');
  icons.addFont(
    Future.value(
      ByteData.sublistView(
        await File.fromUri(fonts.resolve('materialicons-regular.otf'))
            .readAsBytes(),
      ),
    ),
  );
  await icons.load();
}

/// 只在显式预览模式保存截图，不写入正常测试的视觉基线。
Future<void> _capturePreview(WidgetTester tester, String name) async {
  if (Platform.environment['OMNI_COMPLETION_PREVIEW'] == null) return;
  // 生产组件的实际 Flutter 渲染边界。
  final RenderRepaintBoundary boundary =
      _previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 所有截图集中在仓库输出目录。
    final Directory directory = Directory(
      '../../output/todo-completion-preview',
    );
    await directory.create(recursive: true);
    // 与逻辑尺寸一致的预览图。
    final ui.Image rendered = await boundary.toImage(pixelRatio: 1);
    try {
      // 编码完成后立即释放引擎图片资源。
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
