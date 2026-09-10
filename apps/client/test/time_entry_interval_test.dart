import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';

/// 验证跨天分段、区间查询与单条进行中约束。
void main() {
  test('跨天记录会出现在两天查询中并按自然日拆分统计', () async {
    // 测试数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 时间记录仓储。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    // 睡眠开始时间。
    final DateTime startedAt = DateTime(2026, 9, 9, 23);
    // 睡眠结束时间。
    final DateTime endedAt = DateTime(2026, 9, 10, 7);
    await repository.save(
      TimeEntryDraft(
        startedAt: startedAt,
        endedAt: endedAt,
        activity: '睡眠',
        category: '睡眠',
      ),
    );

    // 开始日查询结果。
    final List<TimeEntryRecord> firstDayRecords = await repository
        .watchForDay(DateTime(2026, 9, 9))
        .first;
    // 结束日查询结果。
    final List<TimeEntryRecord> secondDayRecords = await repository
        .watchForDay(DateTime(2026, 9, 10))
        .first;
    expect(firstDayRecords, hasLength(1));
    expect(secondDayRecords, hasLength(1));

    // 跨天记录的自然日分段。
    final List<TimeEntryRecord> segments = splitTimeEntriesForRange(
      records: firstDayRecords,
      rangeStart: DateTime(2026, 9, 9),
      rangeEnd: DateTime(2026, 9, 11),
      now: endedAt,
    );
    expect(segments, hasLength(2));
    expect(segments[0].startMinute, 23 * 60);
    expect(segments[0].endMinute, 24 * 60);
    expect(segments[1].startMinute, 0);
    expect(segments[1].endMinute, 7 * 60);
    expect(repository.summarizeByCategory(segments)['睡眠'], 8 * 60);

    await database.close();
  });

  test('同一设备只允许一条进行中记录', () async {
    // 测试数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 时间记录仓储。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    await repository.save(TimeEntryDraft(startedAt: DateTime(2026, 9, 10, 9)));

    await expectLater(
      repository.save(TimeEntryDraft(startedAt: DateTime(2026, 9, 10, 10))),
      throwsA(isA<ActiveTimeEntryConflict>()),
    );

    await database.close();
  });
}
