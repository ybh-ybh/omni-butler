import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_completion_entry.dart';

/// 按本地日历推进日期，避免夏令时导致自然日偏移。
DateTime completionDayOffset(DateTime day, int offset) =>
    DateTime(day.year, day.month, day.day + offset);

/// 同一自然日、同一所属任务的完成明细。
class TodoCompletionGroup {
  /// 分组所属自然日。
  final DateTime day;

  /// 只用于展示上下文的所属任务。
  final TodoRecord root;

  /// 已筛选且按完成时间倒序的明细。
  final List<TodoCompletionEntry> entries;

  /// 创建完成分组。
  const TodoCompletionGroup({
    required this.day,
    required this.root,
    required this.entries,
  });

  /// 日期与所属任务共同组成稳定身份。
  String get id => '${businessDayKey(day)}-${root.id}';

  /// 分组最近一次完成时间。
  DateTime get latestCompletedAt => entries.first.completedAt;

  /// 子任务或进度明细使用可折叠分组。
  bool get expandable => entries.first.kind != TodoCompletionKind.normal;
}

/// 同一完成快照产生的年度概览与全部历史归档。
class TodoCompletionSummary {
  /// 当前本地自然日。
  final DateTime today;

  /// 全部有效完成记录，保留一年以前的历史。
  final List<TodoCompletionEntry> entries;

  /// 各本地自然日的完整完成数量。
  final Map<DateTime, int> dayCounts;

  /// 各月份的完整完成数量。
  final Map<DateTime, int> monthCounts;

  /// 一次排序后的月份归档，按时间倒序排列。
  final List<DateTime> months;

  /// 从统一快照生成统计；未来自然日不提前计入历史。
  factory TodoCompletionSummary({
    required List<TodoCompletionEntry> entries,
    required DateTime now,
  }) {
    // 完成日统计使用设备本地时区。
    final DateTime local = now.toLocal();
    // 今天零点。
    final DateTime today = DateTime(local.year, local.month, local.day);
    // 尚未到达的自然日不参与历史。
    final DateTime tomorrow = completionDayOffset(today, 1);
    // 在今天及以前完成的记录。
    final List<TodoCompletionEntry> visible = entries
        .where((TodoCompletionEntry entry) => entry.day.isBefore(tomorrow))
        .toList(growable: false);
    // 全部完成日计数。
    final Map<DateTime, int> days = <DateTime, int>{};
    // 全部归档月份计数。
    final Map<DateTime, int> months = <DateTime, int>{};
    for (final TodoCompletionEntry entry in visible) {
      // 当前完成自然日。
      final DateTime day = entry.day;
      // 当前完成月份。
      final DateTime month = DateTime(day.year, day.month);
      days.update(day, (int count) => count + 1, ifAbsent: () => 1);
      months.update(month, (int count) => count + 1, ifAbsent: () => 1);
    }
    return TodoCompletionSummary._(
      today: today,
      entries: List<TodoCompletionEntry>.unmodifiable(visible),
      dayCounts: Map<DateTime, int>.unmodifiable(days),
      monthCounts: Map<DateTime, int>.unmodifiable(months),
      months: List<DateTime>.unmodifiable(
        months.keys.toList()
          ..sort((DateTime left, DateTime right) => right.compareTo(left)),
      ),
    );
  }

  /// 保存已计算的只读统计。
  const TodoCompletionSummary._({
    required this.today,
    required this.entries,
    required this.dayCounts,
    required this.monthCounts,
    required this.months,
  });

  /// 最近三百六十五天的第一天，包含今天。
  DateTime get firstHeatmapDay => completionDayOffset(today, -364);

  /// 统计含今天的最近指定数量自然日。
  int countLastDays(int days) {
    // 滚动窗口起点。
    final DateTime first = completionDayOffset(today, 1 - days);
    return dayCounts.entries
        .where((MapEntry<DateTime, int> entry) => !entry.key.isBefore(first))
        .fold<int>(
          0,
          (int sum, MapEntry<DateTime, int> entry) => sum + entry.value,
        );
  }

  /// 先筛选明细再分组；普通类型包含独立任务和子任务。
  List<TodoCompletionGroup> groups({
    String keyword = '',
    TodoCompletionKind? kind,
    DateTime? start,
    DateTime? end,
  }) {
    // 关键词按包含匹配，不改变中文内容。
    final String query = keyword.trim().toLowerCase();
    // 日期条件仅比较自然日，首尾均包含。
    final DateTime? first = start == null
        ? null
        : DateTime(start.year, start.month, start.day);
    // 日期条件终点。
    final DateTime? last = end == null
        ? null
        : DateTime(end.year, end.month, end.day);
    // 同日同所属任务的明细索引。
    final Map<String, List<TodoCompletionEntry>> grouped =
        <String, List<TodoCompletionEntry>>{};
    for (final TodoCompletionEntry entry in entries) {
      // 子任务与普通任务共用类型筛选，章节进度单独归类。
      if (kind != null &&
          (kind == TodoCompletionKind.normal
              ? entry.kind == TodoCompletionKind.progress
              : entry.kind != kind)) {
        continue;
      }
      if (query.isNotEmpty && !entry.searchText.contains(query)) continue;
      if (first != null && entry.day.isBefore(first)) continue;
      if (last != null && entry.day.isAfter(last)) continue;
      // 日期必须参与分组，防止跨日合并。
      final String key = '${businessDayKey(entry.day)}-${entry.root.id}';
      grouped.putIfAbsent(key, () => <TodoCompletionEntry>[]).add(entry);
    }
    // 每个分组按明细最新时间排序。
    final List<TodoCompletionGroup> result = <TodoCompletionGroup>[];
    for (final List<TodoCompletionEntry> items in grouped.values) {
      items.sort((TodoCompletionEntry left, TodoCompletionEntry right) {
        // 完成时间相同仍保持稳定次序。
        final int timeOrder = right.completedAt.compareTo(left.completedAt);
        return timeOrder == 0 ? left.id.compareTo(right.id) : timeOrder;
      });
      result.add(
        TodoCompletionGroup(
          day: items.first.day,
          root: items.first.root,
          entries: List<TodoCompletionEntry>.unmodifiable(items),
        ),
      );
    }
    result.sort((TodoCompletionGroup left, TodoCompletionGroup right) {
      // 自然日优先，其次比较组内最近完成时间。
      final int dayOrder = right.day.compareTo(left.day);
      if (dayOrder != 0) return dayOrder;
      // 同一天内按最近完成时间排序。
      final int timeOrder = right.latestCompletedAt.compareTo(
        left.latestCompletedAt,
      );
      return timeOrder == 0 ? left.id.compareTo(right.id) : timeOrder;
    });
    return result;
  }
}
