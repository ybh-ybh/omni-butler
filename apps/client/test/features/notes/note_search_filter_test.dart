import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart' show DateTimeRange;
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/data/note_search_filter.dart';

/// 日期、墓碑与交集在纯查询层验证，不依赖设备当天日期。
void main() {
  /// 以归档日创建最小正式笔记，采集时刻故意使用其他日期。
  NoteEntryRecord note(
    String day, {
    String body = '',
    String tags = '[]',
    DateTime? deletedAt,
  }) => NoteEntryRecord(
    isPinned: false,
    id: day,
    body: body,
    tags: tags,
    dayKey: day,
    createdAt: DateTime(2026, 10, 16),
    updatedAt: DateTime(2026, 10, 16),
    revision: 'r1',
    creationTimezone: 'UTC|+00:00',
    deletedAt: deletedAt,
  );

  test('本周跨年以周一开始并包含今天，自定义包含首尾自然日', () {
    // 一月初的周范围跨越年份，仍沿用共享匹配规则。
    final DateTime now = DateTime(2026, 1, 2, 23, 59);
    // 周一至今天，未来归档日不提前匹配。
    final NoteSearchFilter week = NoteSearchFilter(range: 'week');
    // 包含时间分量的自定义范围仍以自然日比较。
    final NoteSearchFilter custom = NoteSearchFilter(
      range: 'custom',
      customRange: DateTimeRange(
        start: DateTime(2025, 12, 30, 18),
        end: DateTime(2026, 1, 1, 1),
      ),
    );
    // 固定归档日期独立验证边界，不受执行当天影响。
    for (final (String, bool, bool) sample in [
      ('2025-12-28', false, false),
      ('2025-12-29', true, false),
      ('2025-12-30', true, true),
      ('2026-01-01', true, true),
      ('2026-01-02', true, false),
      ('2026-01-03', false, false),
    ]) {
      expect(
        matchesNoteSearch(
          note(sample.$1),
          filter: week,
          taxonomies: [],
          audio: [],
          now: now,
        ),
        sample.$2,
        reason: '本周 ${sample.$1}',
      );
      expect(
        matchesNoteSearch(
          note(sample.$1),
          filter: custom,
          taxonomies: [],
          audio: [],
          now: now,
        ),
        sample.$3,
        reason: '自定义 ${sample.$1}',
      );
    }
  });

  test('那年今日使用归档日并排除今年与未来', () {
    // 固定今天，创建时间不参与往年同日匹配。
    final DateTime now = DateTime(2026, 10, 16);
    // 本次用例使用的不可变查询条件。
    final NoteSearchFilter filter = NoteSearchFilter(onThisDay: true);
    for (final String day in ['2025-10-16', '2024-10-16']) {
      expect(
        matchesNoteSearch(
          note(day),
          filter: filter,
          taxonomies: [],
          audio: [],
          now: now,
        ),
        isTrue,
      );
    }
    for (final String day in ['2026-10-16', '2027-10-16', '2025-10-15']) {
      expect(
        matchesNoteSearch(
          note(day),
          filter: filter,
          taxonomies: [],
          audio: [],
          now: now,
        ),
        isFalse,
      );
    }
  });

  test('闰日仅匹配往年二月二十九日，不折算相邻日期', () {
    // 闰年今天仍按相同月日匹配。
    final NoteSearchFilter filter = NoteSearchFilter(onThisDay: true);
    expect(
      matchesNoteSearch(
        note('2024-02-29'),
        filter: filter,
        taxonomies: [],
        audio: [],
        now: DateTime(2028, 2, 29),
      ),
      isTrue,
    );
    expect(
      matchesNoteSearch(
        note('2023-02-28'),
        filter: filter,
        taxonomies: [],
        audio: [],
        now: DateTime(2028, 2, 29),
      ),
      isFalse,
    );
    expect(
      matchesNoteSearch(
        note('2024-02-29'),
        filter: filter,
        taxonomies: [],
        audio: [],
        now: DateTime(2026, 2, 28),
      ),
      isFalse,
    );
  });

  test('近七天跨年包含首尾自然日，墓碑不命中', () {
    // 一月初的范围跨入上一年。
    final NoteSearchFilter filter = NoteSearchFilter(range: 'last7');
    // 用于边界验证的固定本地日期。
    final DateTime now = DateTime(2026, 1, 3);
    expect(
      matchesNoteSearch(
        note('2025-12-28'),
        filter: filter,
        taxonomies: [],
        audio: [],
        now: now,
      ),
      isTrue,
    );
    expect(
      matchesNoteSearch(
        note('2026-01-03'),
        filter: filter,
        taxonomies: [],
        audio: [],
        now: now,
      ),
      isTrue,
    );
    expect(
      matchesNoteSearch(
        note('2025-12-27'),
        filter: filter,
        taxonomies: [],
        audio: [],
        now: now,
      ),
      isFalse,
    );
    expect(
      matchesNoteSearch(
        note('2026-01-03', deletedAt: now),
        filter: filter,
        taxonomies: [],
        audio: [],
        now: now,
      ),
      isFalse,
    );
  });

  test('失效标签不影响无标签判断，选择集合不可外部修改', () {
    // 已删除标签与筛选中的幽灵身份都被忽略。
    final Set<String> ids = {'retired'};
    // 本次用例使用的不可变查询条件。
    final NoteSearchFilter filter = NoteSearchFilter(
      tagMode: 'none',
      tagIds: ids,
    );
    ids.add('another');
    expect(filter.tagIds, {'retired'});
    expect(() => filter.contents.add('audio'), throwsUnsupportedError);
    expect(
      matchesNoteSearch(
        note('2025-10-16', tags: '["retired"]'),
        filter: filter,
        taxonomies: [],
        audio: [],
      ),
      isTrue,
    );
  });

  test('内容和关键词取交集，正文格式按可见文本匹配', () {
    // 图片事实与正文链接分别满足不同内容条件。
    final NoteEntryRecord entry = note(
      '2026-10-16',
      body: '**学习记录**\nhttps://example.com',
    );
    // 本次用例使用的不可变查询条件。
    final NoteSearchFilter filter = NoteSearchFilter(
      contents: {'image', 'link'},
    );
    expect(
      matchesNoteSearch(
        entry,
        filter: filter,
        taxonomies: [],
        audio: [],
        imageNoteIds: {entry.id},
        query: '学习记录',
      ),
      isTrue,
    );
    expect(
      matchesNoteSearch(
        entry,
        filter: filter,
        taxonomies: [],
        audio: [],
        query: '学习记录',
      ),
      isFalse,
    );
    expect(
      matchesNoteSearch(
        entry,
        filter: filter.copyWith(contents: {'audio'}),
        taxonomies: [],
        audio: [],
      ),
      isFalse,
    );
  });
}
