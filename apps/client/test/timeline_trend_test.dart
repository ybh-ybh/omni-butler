import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_review.dart';

/// 验证记录趋势按时间容量计算进度，而非按最长记录归一化。
void main() {
  for (final TimelineStatsPeriod period in TimelineStatsPeriod.values) {
    testWidgets('${period.name} 趋势使用固定容量，空记录为零，达到容量才满格', (
      WidgetTester tester,
    ) async {
      // 同一用例复用数据库，连续刷新不创建额外连接。
      final AppDatabase database = _testDatabase();
      // 周一且为月初，保证三个周期首条进度对应完整时间区间。
      final DateTime start = DateTime(2026, 6, 1);
      // 三小时在六小时时段、一天、一周中应占的比例。
      final double expectedProgress = switch (period) {
        TimelineStatsPeriod.day => 0.5,
        TimelineStatsPeriod.week => 0.125,
        TimelineStatsPeriod.month => 1 / 56,
      };
      await _pumpTrend(
        tester,
        database: database,
        period: period,
        start: start,
        records: [_record(start, 180)],
      );
      expect(
        _trendProgress(tester).first.value,
        closeTo(expectedProgress, 1e-9),
      );
      expect(
        _trendProgress(tester).skip(1).map((bar) => bar.value),
        everyElement(0),
      );

      await _pumpTrend(
        tester,
        database: database,
        period: period,
        start: start,
        records: [],
      );
      expect(_trendProgress(tester).map((bar) => bar.value), everyElement(0));

      // 月视图首条累计整周七天，其他周期只需首日记录。
      final List<TimeEntryRecord> fullRecords = [
        for (
          int day = 0;
          day < (period == TimelineStatsPeriod.month ? 7 : 1);
          day++
        )
          _record(
            start.add(Duration(days: day)),
            period == TimelineStatsPeriod.day ? 360 : 1440,
          ),
      ];
      await _pumpTrend(
        tester,
        database: database,
        period: period,
        start: start,
        records: fullRecords,
      );
      expect(_trendProgress(tester).first.value, 1);

      // 重叠数据超过容量时进度仍限制在满格，避免非法进度值。
      await _pumpTrend(
        tester,
        database: database,
        period: period,
        start: start,
        records: [...fullRecords, _record(start, 60)],
      );
      expect(_trendProgress(tester).first.value, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('月初不足一周的条目与完整自然周使用相同刻度', (WidgetTester tester) async {
    // 独立用例使用独立数据库。
    final AppDatabase database = _testDatabase();
    // 十月从周四开始，首个条目只包含四天。
    final DateTime start = DateTime(2026, 10, 1);
    await _pumpTrend(
      tester,
      database: database,
      period: TimelineStatsPeriod.month,
      start: start,
      records: [_record(start, 180), _record(DateTime(2026, 10, 5), 180)],
    );
    // 相同三小时记录在月初和完整周的进度应一致。
    final List<LinearProgressIndicator> bars = _trendProgress(tester);
    expect(bars[0].value, closeTo(1 / 56, 1e-9));
    expect(bars[1].value, bars[0].value);
    expect(tester.takeException(), isNull);
  });
}

/// 挂载真实复盘主体，以受控记录验证趋势条的呈现值。
Future<void> _pumpTrend(
  WidgetTester tester, {
  required AppDatabase database,
  required TimelineStatsPeriod period,
  required DateTime start,
  required List<TimeEntryRecord> records,
}) async {
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 各周期左闭右开的日期范围。
  final DateTime end = switch (period) {
    TimelineStatsPeriod.day => start.add(const Duration(days: 1)),
    TimelineStatsPeriod.week => start.add(const Duration(days: 7)),
    TimelineStatsPeriod.month => DateTime(start.year, start.month + 1),
  };
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        taxonomyEntriesProvider((
          TaxonomyModule.timeline,
          TaxonomyKind.category,
        )).overrideWith((Ref ref) => Stream<List<TaxonomyEntry>>.value([])),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: TimelineReviewContent(
            records: records,
            previousRecords: const [],
            rangeStart: start,
            rangeEnd: end,
            period: period,
            onOpenDay: (_) {},
            onEdit: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 创建供真实分类统计使用的内存数据库，并在用例结束时释放。
AppDatabase _testDatabase() {
  // 每个用例仅创建一次连接。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  return database;
}

/// 读取趋势面板中的进度条，排除类别结构使用的进度条。
List<LinearProgressIndicator> _trendProgress(WidgetTester tester) => tester
    .widgetList<LinearProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('timeline-daily-trend')),
        matching: find.byType(LinearProgressIndicator),
      ),
    )
    .toList();

/// 创建从当天午夜开始的统计记录。
TimeEntryRecord _record(DateTime day, int minutes) => TimeEntryRecord(
  id: '${day.toIso8601String()}-$minutes',
  entryDate: day,
  startMinute: 0,
  endMinute: minutes,
  startedAt: day,
  endedAt: day.add(Duration(minutes: minutes)),
  activity: '测试记录',
  category: '学习',
  syncState: 'localSaved',
  createdAt: day,
  updatedAt: day,
);
