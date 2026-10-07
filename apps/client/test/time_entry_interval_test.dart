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

  test('默认补记快照与实时查询共用跨日、本地时间及软删除口径', () async {
    // 初始化快照需要和监听获得同一组有效记录。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 正式仓储复用同一个查询构建器。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    try {
      await repository.save(
        TimeEntryDraft(
          startedAt: DateTime(2026, 9, 9, 23).toUtc(),
          endedAt: DateTime(2026, 9, 10, 7).toUtc(),
          activity: '跨日有效',
        ),
      );
      await repository.save(
        TimeEntryDraft(
          startedAt: DateTime(2026, 9, 10, 8),
          endedAt: DateTime(2026, 9, 10, 9),
          activity: '已删除记录',
        ),
      );
      // 软删除后不得参与默认区间或滑轨阻挡。
      final List<TimeEntryRecord> beforeDelete = await repository.loadForRange(
        DateTime(2026, 9, 10),
        DateTime(2026, 9, 11),
      );
      await repository.delete(
        beforeDelete
            .singleWhere((TimeEntryRecord record) => record.activity == '已删除记录')
            .id,
      );
      await repository.save(
        TimeEntryDraft(startedAt: DateTime(2026, 9, 10, 10), activity: '进行中有效'),
      );
      // 一次读取和第一份实时快照覆盖相同自然日交集。
      final List<TimeEntryRecord> loaded = await repository.loadForRange(
        DateTime(2026, 9, 10),
        DateTime(2026, 9, 11),
      );
      final List<TimeEntryRecord> watched = await repository
          .watchForRange(DateTime(2026, 9, 10), DateTime(2026, 9, 11))
          .first;
      expect(
        loaded.map((TimeEntryRecord record) => record.id),
        watched.map((TimeEntryRecord record) => record.id),
      );
      expect(loaded.map((TimeEntryRecord record) => record.activity), <String>[
        '跨日有效',
        '进行中有效',
      ]);
      expect(loaded.first.startedAt, DateTime(2026, 9, 9, 23));
      expect(loaded.first.startedAt.isUtc, isFalse);
      expect(loaded.last.endedAt, isNull);
    } finally {
      await database.close();
    }
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
