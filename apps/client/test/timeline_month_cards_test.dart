import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_review.dart';

/// Verifies readable Windows month cards and their existing day navigation.
void main() {
  testWidgets('Windows 月历展示前四条并保留完整日总时长和剩余数量', (WidgetTester tester) async {
    // Four neighboring dates exercise empty, single, exact, and overflow states.
    final DateTime firstDay = DateTime(2026, 10, 1);
    // Deliberately reversed input proves card ordering is independent of callers.
    final List<TimeEntryRecord> records = <TimeEntryRecord>[
      _record(firstDay.add(const Duration(days: 1)), 'single', 480, 540),
      for (int index = 3; index >= 0; index -= 1)
        _record(
          firstDay.add(const Duration(days: 2)),
          'exact-$index',
          index * 60,
          (index + 1) * 60,
        ),
      for (int index = 5; index >= 0; index -= 1)
        _record(
          firstDay.add(const Duration(days: 3)),
          'overflow-$index',
          index * 60,
          (index + 1) * 60,
        ),
    ];
    await _pumpMonth(tester, records: records);

    expect(_cards('2026-10-01'), findsOneWidget);
    expect(_recordCards('2026-10-01'), findsNothing);
    expect(
      find.descendant(of: _cell('2026-10-01'), matching: find.text('无记录')),
      findsOneWidget,
    );
    expect(_recordCards('2026-10-02'), findsOneWidget);
    expect(_recordCards('2026-10-03'), findsNWidgets(4));
    expect(_recordCards('2026-10-04'), findsNWidgets(4));
    expect(_more('2026-10-03'), findsNothing);
    expect(_more('2026-10-04'), findsOneWidget);
    expect(
      find.descendant(
        of: _more('2026-10-04'),
        matching: find.text('还有 2 条'),
        matchRoot: true,
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _total('2026-10-04'),
        matching: find.text('6h'),
        matchRoot: true,
      ),
      findsOneWidget,
    );
    expect(_recordCard('2026-10-04', 'overflow-4'), findsNothing);
    expect(_recordCard('2026-10-04', 'overflow-5'), findsNothing);
    for (int index = 0; index < 3; index += 1) {
      expect(
        tester.getTopLeft(_recordCard('2026-10-04', 'overflow-$index')).dy,
        lessThan(
          tester
              .getTopLeft(_recordCard('2026-10-04', 'overflow-${index + 1}'))
              .dy,
        ),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('月历短记录与长记录同高且完整名称和空值回退可读', (WidgetTester tester) async {
    // A long title must remain available even when its visible line is ellipsized.
    const String longTitle = '开发知识库并整理跨模块查询与同步问题的完整排查记录';
    // One minute and nine hours must have the same readable card height.
    final DateTime day = DateTime(2026, 10, 1);
    await _pumpMonth(
      tester,
      records: <TimeEntryRecord>[
        _record(day, 'short', 0, 1, activity: longTitle),
        _record(day, 'long', 60, 600, activity: null, category: null),
      ],
    );
    expect(
      tester.getSize(_recordCard('2026-10-01', 'short')).height,
      tester.getSize(_recordCard('2026-10-01', 'long')).height,
    );
    expect(
      find.descendant(
        of: _recordCard('2026-10-01', 'short'),
        matching: find.textContaining('1m'),
      ),
      findsOneWidget,
    );
    expect(
      _tooltipMessages(tester, _recordCard('2026-10-01', 'short')),
      contains(longTitle),
    );
    expect(
      _tooltipMessages(tester, _recordCard('2026-10-01', 'long')),
      contains('未命名记录'),
    );
    expect(
      _tooltipMessages(tester, _recordCard('2026-10-01', 'long')),
      contains('未分类'),
    );
    // Visible title truncation never removes the original activity text.
    final Text title = tester.widget<Text>(
      find.descendant(
        of: _recordCard('2026-10-01', 'short'),
        matching: find.text(longTitle),
      ),
    );
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    // The overlay must expose the complete description through actual mouse hover.
    const String fullDescription = '$longTitle · 00:00–00:01 · 1m · 测试分类';
    // A mouse pointer exercises Tooltip's hit region and delayed visibility.
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    try {
      expect(find.text(fullDescription), findsNothing);
      await mouse.moveTo(tester.getCenter(_recordCard('2026-10-01', 'short')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(fullDescription), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(fullDescription), findsNothing);
    } finally {
      await mouse.removePointer();
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('月历保留跨月和重叠切片且仅当天显示进行中', (WidgetTester tester) async {
    // The previous day's ongoing slice must end at midnight rather than now.
    final DateTime now = DateTime(2026, 10, 2, 12);
    // Logical records are projected through the production natural-day splitter.
    final List<TimeEntryRecord> records = splitTimeEntriesForRange(
      records: <TimeEntryRecord>[
        _record(DateTime(2026, 9, 30), 'cross-month', 1380, 1500),
        _record(DateTime(2026, 10, 1), 'overlap-a', 900, 960),
        _record(DateTime(2026, 10, 1), 'overlap-b', 930, 1020),
        _record(DateTime(2026, 10, 1), 'ongoing', 1380, 1380, ongoing: true),
      ],
      rangeStart: DateTime(2026, 10, 1),
      rangeEnd: DateTime(2026, 11, 1),
      now: now,
    );
    await _pumpMonth(tester, records: records, now: now);

    expect(_recordCards('2026-10-01'), findsNWidgets(4));
    expect(_recordCards('2026-10-02'), findsOneWidget);
    expect(_recordCard('2026-10-01', 'overlap-a'), findsOneWidget);
    expect(_recordCard('2026-10-01', 'overlap-b'), findsOneWidget);
    expect(
      _tooltipMessages(tester, _recordCard('2026-10-01', 'cross-month')),
      allOf(contains('00:00'), contains('01:00'), contains('1h')),
    );
    expect(
      _tooltipMessages(tester, _recordCard('2026-10-01', 'ongoing')),
      allOf(contains('23:00'), contains('24:00'), isNot(contains('进行中'))),
    );
    expect(
      _tooltipMessages(tester, _recordCard('2026-10-02', 'ongoing')),
      allOf(contains('00:00'), contains('进行中'), contains('12h')),
    );
    expect(
      find.descendant(
        of: _total('2026-10-01'),
        matching: find.text('4h30m'),
        matchRoot: true,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('月历日期卡片空白与更多均只进入当天明细', (WidgetTester tester) async {
    // All clickable content retains the original day-level navigation contract.
    final DateTime day = DateTime(2026, 10, 1);
    // Navigation and editing callbacks are observed independently.
    final List<DateTime> opened = <DateTime>[];
    // No month interaction may silently become a direct editor action.
    final List<String> edited = <String>[];
    await _pumpMonth(
      tester,
      records: <TimeEntryRecord>[
        for (int index = 0; index < 6; index += 1)
          _record(day, 'entry-$index', index * 60, (index + 1) * 60),
      ],
      onOpenDay: opened.add,
      onEdit: (TimeEntryRecord record) => edited.add(record.id),
    );
    await tester.tap(
      find.descendant(of: _cell('2026-10-01'), matching: find.text('1')),
    );
    await tester.pump();
    await tester.tap(_recordCard('2026-10-01', 'entry-0'));
    await tester.pump();
    await tester.tap(_more('2026-10-01'));
    await tester.pump();
    // The right inset is part of the day cell but outside its content cards.
    final Rect cell = tester.getRect(_cell('2026-10-01'));
    await tester.tapAt(Offset(cell.right - 3, cell.center.dy));
    await tester.pump();
    expect(opened, <DateTime>[day, day, day, day]);
    await tester.tap(_cell('2026-10-02'));
    await tester.pump();
    expect(opened.last, DateTime(2026, 10, 2));
    expect(edited, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 月历键盘每个日期仅一个停靠点且 Enter 只打开当天', (
    WidgetTester tester,
  ) async {
    // Four cards and a remaining count must not introduce extra focus stops.
    final DateTime day = DateTime(2026, 10, 1);
    // Keyboard activation is observed separately from record editing.
    final List<DateTime> opened = <DateTime>[];
    // Editing must remain absent from every calendar activation path.
    final List<String> edited = <String>[];
    await _pumpMonth(
      tester,
      records: <TimeEntryRecord>[
        for (int index = 0; index < 6; index += 1)
          _record(day, 'keyboard-$index', index * 60, (index + 1) * 60),
      ],
      onOpenDay: opened.add,
      onEdit: (TimeEntryRecord record) => edited.add(record.id),
    );
    // Request the containing day action's actual focus node through its content.
    final FocusNode dayFocus = Focus.of(
      tester.element(_recordCard('2026-10-01', 'keyboard-0')),
    );
    dayFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(dayFocus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, <DateTime>[day]);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(dayFocus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, <DateTime>[day, DateTime(2026, 10, 2)]);
    expect(edited, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 月历缩窄后回退且恢复宽度后仍保留记录与日期入口', (WidgetTester tester) async {
    // The same mounted month exercises responsive fallback without data reloads.
    final DateTime day = DateTime(2026, 10, 1);
    // The selected date can still be opened after every width transition.
    final List<DateTime> opened = <DateTime>[];
    await _pumpMonth(
      tester,
      records: <TimeEntryRecord>[_record(day, 'stable', 480, 540)],
      onOpenDay: opened.add,
    );
    expect(_recordCard('2026-10-01', 'stable'), findsOneWidget);
    for (final Size size in <Size>[
      const Size(1440, 1000),
      const Size(512, 900),
      const Size(2400, 1400),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(_cell('2026-10-01'), findsOneWidget);
      if (size.width == 512) {
        expect(_cards('2026-10-01'), findsNothing);
      }
      await tester.tap(_cell('2026-10-01'));
      await tester.pump();
      expect(opened.last, day);
      expect(tester.takeException(), isNull);
    }
    expect(_recordCard('2026-10-01', 'stable'), findsOneWidget);
  });

  testWidgets('Windows 深色双倍粗体月历保留卡片文字且窄屏安全回退', (WidgetTester tester) async {
    // Ahem is intentionally wide, so the large canvas isolates text-height safety.
    final DateTime day = DateTime(2026, 10, 1);
    await _pumpMonth(
      tester,
      records: <TimeEntryRecord>[
        for (int index = 0; index < 6; index += 1)
          _record(day, 'large-$index', index * 60, (index + 1) * 60),
      ],
      viewport: const Size(4800, 2000),
      brightness: Brightness.dark,
      scale: 2,
      boldText: true,
    );
    expect(_recordCards('2026-10-01'), findsNWidgets(4));
    expect(_more('2026-10-01'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(512, 900);
    await tester.pumpAndSettle();
    expect(_cards('2026-10-01'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android 宽屏月历保留原微缩时间条', (WidgetTester tester) async {
    // Platform identity, rather than width alone, controls the new month cards.
    final DateTime day = DateTime(2026, 10, 1);
    await _pumpMonth(
      tester,
      platform: TargetPlatform.android,
      records: <TimeEntryRecord>[_record(day, 'android', 480, 540)],
    );
    expect(_cell('2026-10-01'), findsOneWidget);
    expect(_cards('2026-10-01'), findsNothing);
    expect(_recordCard('2026-10-01', 'android'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// Mounts production month content with isolated data and a deterministic clock.
Future<void> _pumpMonth(
  WidgetTester tester, {
  required List<TimeEntryRecord> records,
  Size viewport = const Size(2400, 1400),
  TargetPlatform platform = TargetPlatform.windows,
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool boldText = false,
  DateTime? now,
  ValueChanged<DateTime>? onOpenDay,
  ValueChanged<TimeEntryRecord>? onEdit,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Summary calculations use a disposable database rather than user data.
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(database.close);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(now ?? DateTime(2026, 10, 2, 12)),
        taxonomyEntriesProvider((
          TaxonomyModule.timeline,
          TaxonomyKind.category,
        )).overrideWith(
          (Ref ref) =>
              Stream<List<TaxonomyEntry>>.value(const <TaxonomyEntry>[]),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: brightness)
            .copyWith(platform: platform),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale), boldText: boldText),
          child: child!,
        ),
        home: Scaffold(
          body: TimelineReviewContent(
            records: records,
            previousRecords: const <TimeEntryRecord>[],
            rangeStart: DateTime(2026, 10, 1),
            rangeEnd: DateTime(2026, 11, 1),
            period: TimelineStatsPeriod.month,
            onOpenDay: onOpenDay ?? (DateTime _) {},
            onEdit: onEdit ?? (TimeEntryRecord _) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Creates logical entries without saving or imposing overlap validation.
TimeEntryRecord _record(
  DateTime day,
  String id,
  int start,
  int end, {
  String? activity = '测试活动',
  String? category = '测试分类',
  bool ongoing = false,
}) => TimeEntryRecord(
  id: id,
  entryDate: day,
  startMinute: start,
  endMinute: end,
  startedAt: day.add(Duration(minutes: start)),
  endedAt: ongoing ? null : day.add(Duration(minutes: end)),
  activity: activity,
  category: category,
  syncState: 'localSaved',
  createdAt: day,
  updatedAt: day,
);

/// Finds one natural-day cell in either responsive presentation.
Finder _cell(String day) =>
    find.byKey(ValueKey<String>('timeline-month-cell-$day'));

/// Finds the readable Windows presentation for one natural day.
Finder _cards(String day) =>
    find.byKey(ValueKey<String>('timeline-month-cards-$day'));

/// Finds the full tracked duration including records hidden behind the count.
Finder _total(String day) =>
    find.byKey(ValueKey<String>('timeline-month-total-$day'));

/// Finds the remaining-record count for one date.
Finder _more(String day) =>
    find.byKey(ValueKey<String>('timeline-month-more-$day'));

/// Finds one record slice by its date and logical record identity.
Finder _recordCard(String day, String id) =>
    find.byKey(ValueKey<String>('timeline-month-record-$day-$id'));

/// Counts visible cards without assuming a particular implementation widget type.
Finder _recordCards(String day) => find.byWidgetPredicate((Widget widget) {
  // Stable record keys distinguish cards from date and summary widgets.
  final Key? key = widget.key;
  return key is ValueKey<String> &&
      key.value.startsWith('timeline-month-record-$day-');
});

/// Reads tooltip content without driving delayed hover timers.
String _tooltipMessages(WidgetTester tester, Finder root) => tester
    .widgetList<Tooltip>(
      find.descendant(
        of: root,
        matching: find.byType(Tooltip),
        matchRoot: true,
      ),
    )
    .map(
      (Tooltip tooltip) =>
          tooltip.message ?? tooltip.richMessage?.toPlainText() ?? '',
    )
    .join('\n');
