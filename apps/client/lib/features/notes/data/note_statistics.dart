import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/markdown/note_markdown.dart';

/// 同一自然周期内的正式笔记统计。
@immutable
class NoteStatisticsTotals {
  /// 正式笔记篇数。
  final int count;

  /// 正文可见字符数，与编辑器口径一致。
  final int words;

  /// 至少记录一篇笔记的自然日数量。
  final int days;

  /// 创建不可变汇总，缺失周期使用零值。
  const NoteStatisticsTotals({this.count = 0, this.words = 0, this.days = 0});

  /// 合并互不重叠的自然日或月份。
  NoteStatisticsTotals add(NoteStatisticsTotals other) => NoteStatisticsTotals(
    count: count + other.count,
    words: words + other.words,
    days: days + other.days,
  );
}

/// 从正式记录构建日、月、年索引，不依赖列表搜索或设备时区。
@immutable
class NoteStatistics {
  /// 按归档自然日索引的汇总。
  final Map<String, NoteStatisticsTotals> dates;

  /// 按 YYYY-MM 索引的汇总。
  final Map<String, NoteStatisticsTotals> months;

  /// 只包含存在正式记录的年份汇总。
  final Map<int, NoteStatisticsTotals> annual;

  /// 有记录的年份，从新到旧排列。
  final List<int> years;

  /// 冻结聚合结果，避免页面修改统计快照。
  const NoteStatistics._(this.dates, this.months, this.annual, this.years);

  /// 纯聚合入口，墓碑防御性排除；未发布草稿不属于输入类型。
  factory NoteStatistics.fromNotes(Iterable<NoteEntryRecord> notes) {
    // 先按业务自然日合并篇数和字数。
    final Map<String, NoteStatisticsTotals> dates = {};
    for (final NoteEntryRecord note in notes) {
      if (note.deletedAt != null) continue;
      // 同一天只贡献一个记录天数。
      final NoteStatisticsTotals previous =
          dates[note.dayKey] ?? const NoteStatisticsTotals();
      dates[note.dayKey] = NoteStatisticsTotals(
        count: previous.count + 1,
        words:
            previous.words +
            NoteMarkdown.plainText(note.body).characters.length,
        days: 1,
      );
    }
    // 日汇总构建月、年汇总，确保各层口径一致。
    final Map<String, NoteStatisticsTotals> months = {};
    // 年份直接来自 dayKey，不从 createdAt 推导。
    final Map<int, NoteStatisticsTotals> annual = {};
    for (final MapEntry<String, NoteStatisticsTotals> date in dates.entries) {
      // 仓储已保证 YYYY-MM-DD 的自然日格式。
      final String month = date.key.substring(0, 7);
      // 保留补记记录的归档年份。
      final int year = int.parse(date.key.substring(0, 4));
      months[month] = (months[month] ?? const NoteStatisticsTotals()).add(
        date.value,
      );
      annual[year] = (annual[year] ?? const NoteStatisticsTotals()).add(
        date.value,
      );
    }
    // 下拉菜单只出现实际有记录的年份。
    final List<int> years = annual.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    return NoteStatistics._(
      Map.unmodifiable(dates),
      Map.unmodifiable(months),
      Map.unmodifiable(annual),
      List.unmodifiable(years),
    );
  }

  /// 获取月份汇总，零记录月份仍可显示完整日历。
  NoteStatisticsTotals month(int year, int month) =>
      months['$year-${month.toString().padLeft(2, '0')}'] ??
      const NoteStatisticsTotals();
}
