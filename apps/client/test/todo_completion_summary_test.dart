import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/data/todo_completion_summary.dart';

import 'support/todo_completion_test_data.dart';

/// 验证时间窗口、同日分组与筛选均使用同一份完成单元。
void main() {
  test('七、三十、三百六十五天窗口包含首尾并排除未来自然日', () {
    // 闰年后的窗口让跨年和二月边界同时参与统计。
    final DateTime today = DateTime(2025, 1, 1);
    // 各时间窗口的边界记录。
    final List<TodoCompletionEntry> entries = <TodoCompletionEntry>[
      for (final int offset in <int>[0, -6, -7, -29, -30, -364, -365, 1])
        completionTestEntry('$offset', completionDayOffset(today, offset)),
    ];
    // 窗口依赖自然日而非当前小时。
    final TodoCompletionSummary summary = TodoCompletionSummary(
      entries: entries,
      now: DateTime(2025, 1, 1, 12),
    );
    expect(summary.countLastDays(7), 2);
    expect(summary.countLastDays(30), 4);
    expect(summary.countLastDays(365), 6);
    expect(summary.entries.length, 7);
    expect(summary.firstHeatmapDay, DateTime(2024, 1, 3));
    expect(summary.groups().last.day, DateTime(2024, 1, 2));
  });

  test('跨午夜窗口向前推进，闰日和 UTC 时间转换成本地日期', () {
    // 从 UTC 下行的时刻应先转换到设备时区。
    final DateTime utc = DateTime.utc(2024, 2, 29, 19, 30);
    // 测试按实际时区推导期望，不假定 CI 的设备时区。
    final DateTime local = utc.toLocal();
    // 包含刚跨过七天窗口起点的完成记录。
    final List<TodoCompletionEntry> entries = <TodoCompletionEntry>[
      completionTestEntry('utc', utc),
      completionTestEntry('edge', DateTime(2024, 2, 23, 23, 59)),
    ];
    // 午夜前的同一快照。
    final TodoCompletionSummary before = TodoCompletionSummary(
      entries: entries,
      now: DateTime(2024, 2, 29, 23, 59),
    );
    // 午夜后无需业务数据变化也要更新统计。
    final TodoCompletionSummary after = TodoCompletionSummary(
      entries: entries,
      now: DateTime(2024, 3, 1),
    );
    expect(
      completionDayOffset(DateTime(2024, 2, 28), 1),
      DateTime(2024, 2, 29),
    );
    expect(
      completionDayOffset(DateTime(2024, 3, 1), -1),
      DateTime(2024, 2, 29),
    );
    expect(before.groups(keyword: 'edge').length, 1);
    // 单独核对边界记录，避免本机 UTC 偏移影响午夜断言。
    final List<TodoCompletionEntry> edgeOnly = <TodoCompletionEntry>[
      entries.last,
    ];
    expect(
      TodoCompletionSummary(
        entries: edgeOnly,
        now: before.today,
      ).countLastDays(7),
      1,
    );
    expect(
      TodoCompletionSummary(
        entries: edgeOnly,
        now: after.today,
      ).countLastDays(7),
      0,
    );
    expect(entries.first.day, DateTime(local.year, local.month, local.day));
    expect(after.firstHeatmapDay, completionDayOffset(after.today, -364));
  });

  test('先筛选再同日分组，父任务上下文可检索且原章节序号不变', () {
    // 同一进度任务在两个不同日期完成，普通子任务也按父项聚合。
    final TodoCompletionSummary summary = TodoCompletionSummary(
      entries: completionTestEntries(),
      now: DateTime(2026, 10, 25),
    );
    // 父任务关键词匹配到两个日期的章节明细。
    final List<TodoCompletionGroup> java = summary.groups(keyword: '  JAVA  ');
    expect(java.length, 2);
    expect(java.first.entries.length, 2);
    expect(java.first.root.title, 'Java 学习');
    expect(java.first.entries.last.title, '第8章');
    expect(summary.groups(keyword: '后端').length, 2);
    expect(summary.groups(keyword: '项目收尾').single.entries.length, 2);
    expect(summary.groups(keyword: '不存在'), isEmpty);
    expect(summary.groups(kind: TodoCompletionKind.progress).length, 2);
    // 日期首尾均包含，类型与关键词同时生效。
    final List<TodoCompletionGroup> filtered = summary.groups(
      keyword: 'Java',
      kind: TodoCompletionKind.progress,
      start: DateTime(2026, 10, 25),
      end: DateTime(2026, 10, 25),
    );
    expect(filtered.single.entries.length, 2);
    expect(summary.countLastDays(7), 6);
    expect(summary.monthCounts[DateTime(2026, 10)], 6);
    expect(summary.months.last, DateTime(2024, 5));
    expect(summary.groups().last.entries.single.title, '归档旧资料');
  });

  test('普通类型包含独立任务和子任务，进度类型保留全部章节', () {
    // 混合样本含两个独立任务、两个子任务和三个章节。
    final TodoCompletionSummary summary = TodoCompletionSummary(
      entries: completionTestEntries(),
      now: DateTime(2026, 10, 25),
    );
    // 普通筛选包含一年前的独立任务与父项下的子任务。
    final List<TodoCompletionEntry> normal = summary
        .groups(kind: TodoCompletionKind.normal)
        .expand((TodoCompletionGroup group) => group.entries)
        .toList();
    expect(
      normal.map((TodoCompletionEntry entry) => entry.id),
      unorderedEquals(<String>['mail', 'build', 'notes', 'old']),
    );
    expect(
      summary
          .groups(keyword: '项目收尾', kind: TodoCompletionKind.normal)
          .single
          .entries
          .length,
      2,
    );
    expect(
      summary
          .groups(kind: TodoCompletionKind.progress)
          .expand((TodoCompletionGroup group) => group.entries)
          .length,
      3,
    );
    expect(summary.countLastDays(7), 6);
    expect(summary.monthCounts[DateTime(2026, 10)], 6);
  });

  test('同日按最近完成时间排序，同刻使用稳定身份且不合并不同所属任务', () {
    // 两个根任务和同时间的明细用于检验稳定次序。
    final TodoRecord parent = completionTestTodo('root', '父任务');
    // 所有记录故意以不稳定输入顺序传入。
    final TodoCompletionSummary summary = TodoCompletionSummary(
      now: DateTime(2026, 10, 25),
      entries: <TodoCompletionEntry>[
        completionTestEntry(
          'z',
          DateTime(2026, 10, 25, 10),
          todo: completionTestTodo('z', '子任务Z', parentId: parent.id),
          parent: parent,
        ),
        completionTestEntry(
          'a',
          DateTime(2026, 10, 25, 10),
          todo: completionTestTodo('a', '子任务A', parentId: parent.id),
          parent: parent,
        ),
        completionTestEntry('new', DateTime(2026, 10, 25, 11)),
        completionTestEntry('old', DateTime(2026, 10, 24, 23)),
      ],
    );
    // 分组时间取当前日期内最新记录。
    final List<TodoCompletionGroup> groups = summary.groups();
    expect(groups.first.entries.single.id, 'new');
    expect(
      groups[1].entries.map((TodoCompletionEntry entry) => entry.id),
      <String>['a', 'z'],
    );
    expect(groups.last.day, DateTime(2026, 10, 24));
    expect(groups[1].id, '2026-10-25-root');
  });
}
