import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/home/presentation/home_time_status_card.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';

/// Keep a deliberately long activity available to both layout and semantics.
const String _longTitle = '整理安卓首页时间记录布局并检查所有分类与不同字号下的显示效果';

/// Exercise category truncation without changing the stored taxonomy name.
const String _longCategory = '产品研发与长期个人知识体系整理';

/// Distinguish the configured category color from the theme fallback.
const Color _categoryColor = Color(0xFF7956BD);

/// Ensure details remain stored while the compact row omits their text.
const String _privateNotes = '这段备注仅在编辑界面显示';

/// Verify the Android row contract with real records and production streams.
void main() {
  // Cover small phones, normal phones, and wide Android windows.
  for (final double width in <double>[320, 390, 800]) {
    // Preserve system text scaling rather than shrinking dense rows.
    for (final double textScale in <double>[1, 2]) {
      // Exercise category colors and fallback contrast in both themes.
      for (final Brightness brightness in Brightness.values) {
        testWidgets('安卓时间列表 $width 宽 $textScale 倍字号 ${brightness.name} 保持横向分栏', (
          WidgetTester tester,
        ) async {
          // Persist all four record types through the production repository.
          final Map<String, TimeEntryRecord> records = await _pumpTimeCard(
            tester,
            width: width,
            textScale: textScale,
            brightness: brightness,
          );
          // Read the complete labels after visible text has been truncated.
          final SemanticsHandle semantics = tester.ensureSemantics();
          try {
            // Describe the displayed day segment independently of persistence.
            for (final (String, String, String, String) scenario
                in <(String, String, String, String)>[
                  ('ongoing', '12:00', '进行中', '2小时'),
                  ('uncategorized', '11:00', '11:20', '20分钟'),
                  ('completed', '09:00', '10:30', '1小时30分'),
                  ('cross-day', '00:00', '01:00', '1小时'),
                ]) {
              // Retain each logical record ID after clipping across midnight.
              final TimeEntryRecord record = records[scenario.$1]!;
              // Bring each row inside the real card scroll viewport.
              final Finder row = _row(record.id);
              await tester.ensureVisible(row);
              await tester.pumpAndSettle();
              _expectRowGeometry(tester, record.id);
              expect(
                tester.widget<Text>(_part('start', record.id)).data,
                scenario.$2,
              );
              expect(
                tester.widget<Text>(_part('end', record.id)).data,
                scenario.$3,
              );
              expect(_durationText(tester, record.id), scenario.$4);
              _expectDurationUnits(tester, record.id, textScale: textScale);
              expect(
                tester.widget<Text>(_part('category', record.id)).data,
                record.category ?? '未分类',
              );
              // The configured stripe and uncategorized stripe share chart colors.
              final Color expectedColor = record.category == null
                  ? OmniColors.of(tester.element(row)).time
                  : _categoryColor;
              expect(
                tester.widget<ColoredBox>(_part('leading', record.id)).color,
                expectedColor,
              );
              // Truncated labels must remain complete to screen readers.
              final String spoken = tester.getSemantics(row).label;
              expect(spoken, contains(record.activity));
              expect(spoken, contains(record.category ?? '未分类'));
              expect(spoken, contains(scenario.$2));
              expect(spoken, contains(scenario.$3));
              expect(find.text(_privateNotes), findsNothing);
              expect(tester.takeException(), isNull);
            }
          } finally {
            semantics.dispose();
          }
        });
      }
    }
  }

  testWidgets('320宽双倍粗体下时间与完整耗时单位不裁剪', (WidgetTester tester) async {
    // Exercise the narrowest supported viewport with both accessibility options.
    final Map<String, TimeEntryRecord> records = await _pumpTimeCard(
      tester,
      width: 320,
      textScale: 2,
      brightness: Brightness.light,
      boldText: true,
    );
    // Cover the wider ongoing label and a compound hour/minute duration.
    for (final String scenario in <String>['ongoing', 'completed']) {
      // Select the original persisted record used by the visible row.
      final TimeEntryRecord record = records[scenario]!;
      await tester.ensureVisible(_row(record.id));
      await tester.pumpAndSettle();
      _expectRowGeometry(tester, record.id);
      _expectUnclippedLabel(tester, _part('start', record.id));
      _expectUnclippedLabel(tester, _part('end', record.id));
      _expectDurationUnits(tester, record.id, textScale: 2);
      // Each unit must fit fully even when the compound duration wraps.
      final Finder labels = find.descendant(
        of: _part('trailing', record.id),
        matching: find.byType(Text),
      );
      // Measure rendered glyphs rather than relying on a missing overflow error.
      for (final Element label in labels.evaluate()) {
        _expectUnclippedLabel(
          tester,
          find.byElementPredicate((Element element) => element == label),
        );
      }
      expect(tester.takeException(), isNull);
    }
  });
}

/// Resolve the complete tappable row by its persisted identity.
Finder _row(String id) => find.byKey(ValueKey<String>('home-time-entry-$id'));

/// Resolve one visible column without matching chart or legend text.
Finder _part(String part, String id) =>
    find.byKey(ValueKey<String>('home-time-entry-$part-$id'));

/// Check scaled bold glyph widths against the actual text layout bounds.
void _expectUnclippedLabel(WidgetTester tester, Finder label) {
  // The rendered paragraph includes the effective font weight and text scale.
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(label);
  expect(paragraph.didExceedMaxLines, isFalse);
  expect(
    paragraph.getMaxIntrinsicWidth(double.infinity),
    lessThanOrEqualTo(paragraph.size.width + 0.01),
  );
}

/// Compare positions so metadata cannot silently move below the title.
void _expectRowGeometry(WidgetTester tester, String id) {
  // The outer row includes the stripe and the entire touch target.
  final Rect row = tester.getRect(_row(id));
  // The short accent leaves equal vertical insets inside the row.
  final Rect stripe = tester.getRect(_part('leading', id));
  // The first line shows the segment start time.
  final Rect start = tester.getRect(_part('start', id));
  // The second line shows either the segment end or its ongoing status.
  final Rect end = tester.getRect(_part('end', id));
  // The middle column keeps the activity as its only content.
  final Rect title = tester.getRect(_part('title', id));
  // The trailing category remains beside the title.
  final Rect category = tester.getRect(_part('category', id));
  // The duration may wrap only inside its own final column.
  final Rect duration = tester.getRect(_part('trailing', id));
  expect(stripe.width, closeTo(3, 0.01));
  expect(stripe.left, closeTo(row.left, 0.01));
  expect(stripe.top, closeTo(row.top + 8, 0.01));
  expect(stripe.bottom, closeTo(row.bottom - 8, 0.01));
  expect(stripe.center.dy, closeTo(row.center.dy, 0.01));
  expect(stripe.right, lessThan(start.left));
  expect(start.bottom, lessThanOrEqualTo(end.top));
  expect(start.right, lessThan(title.left));
  expect(end.right, lessThan(title.left));
  expect(title.right, lessThan(category.left));
  expect(category.right, lessThan(duration.left));
  expect(title.width, greaterThan(0));
  expect(category.width, greaterThan(0));
  expect(category.top, lessThan(title.bottom));
  expect(category.bottom, greaterThan(title.top));
  expect(duration.top, lessThan(title.bottom));
  expect(duration.bottom, greaterThan(title.top));
  expect(duration.right, lessThanOrEqualTo(row.right));
  // The title can use two lines while its complete value stays in semantics.
  final Text titleText = tester.widget<Text>(_part('title', id));
  expect(titleText.maxLines, 2);
  expect(titleText.overflow, TextOverflow.ellipsis);
  // The category remains a single compact label in its own column.
  final Text categoryText = tester.widget<Text>(_part('category', id));
  expect(categoryText.maxLines, 1);
  expect(categoryText.overflow, TextOverflow.ellipsis);
}

/// Read both a single duration label and stacked complete unit labels.
String _durationText(WidgetTester tester, String id) => tester
    .widgetList<Text>(
      find.descendant(
        of: _part('trailing', id),
        matching: find.byType(Text),
        matchRoot: true,
      ),
    )
    .map((Text text) => text.data ?? text.textSpan!.toPlainText())
    .join()
    .replaceAll(RegExp(r'\s+'), '');

/// Keep line breaks between complete duration units, never inside a number.
void _expectDurationUnits(
  WidgetTester tester,
  String id, {
  required double textScale,
}) {
  // A duration can be one label or several complete unit labels.
  final Finder labels = find.descendant(
    of: _part('trailing', id),
    matching: find.byType(Text),
    matchRoot: true,
  );
  // Preserve unit boundaries even when the narrow layout inserts line breaks.
  for (final Text label in tester.widgetList<Text>(labels)) {
    // Use the same plain text for ordinary and rich labels.
    final String value = label.data ?? label.textSpan!.toPlainText();
    // A visual line must include its own complete numeric value and unit.
    for (final String line in value.split('\n')) {
      expect(line, matches(RegExp(r'^\d+(?:小时(?:\d+分)?|分钟|分)$')));
    }
    if (textScale == 1) {
      expect(value, isNot(contains('\n')));
    }
  }
  if (textScale == 1) {
    // Ordinary text size keeps every duration unit on the same visual line.
    final List<double> centers = <double>[
      // Each keyed match refers to one visible duration label.
      for (final Element label in labels.evaluate())
        tester.getCenter(find.byElementPredicate((Element e) => e == label)).dy,
    ];
    expect(centers, everyElement(closeTo(centers.first, 0.1)));
  }
}

/// Mount the real card with isolated persistence and fixed business time.
Future<Map<String, TimeEntryRecord>> _pumpTimeCard(
  WidgetTester tester, {
  required double width,
  required double textScale,
  required Brightness brightness,
  bool boldText = false,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // The fixed local time determines ongoing duration and day clipping.
  final DateTime now = DateTime(2026, 11, 6, 14);
  // No production database, preference, or remote service is accessed.
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // Save a custom category so the stripe must honor the user's chosen color.
  final TaxonomyRepository taxonomy = TaxonomyRepository(database);
  await taxonomy.save(
    TaxonomyDraft(
      module: TaxonomyModule.timeline,
      kind: TaxonomyKind.category,
      name: _longCategory,
      colorValue: _categoryColor.toARGB32(),
    ),
  );
  // The same repository provides persistence and the card's watched streams.
  final TimeEntryRepository repository = TimeEntryRepository(database);
  // These intervals do not overlap and deliberately include a midnight span.
  final Map<String, TimeEntryDraft> drafts = <String, TimeEntryDraft>{
    'cross-day': TimeEntryDraft(
      startedAt: DateTime(2026, 11, 5, 23),
      endedAt: DateTime(2026, 11, 6, 1),
      activity: '跨天记录',
      category: _longCategory,
      notes: _privateNotes,
    ),
    'completed': TimeEntryDraft(
      startedAt: DateTime(2026, 11, 6, 9),
      endedAt: DateTime(2026, 11, 6, 10, 30),
      activity: _longTitle,
      category: _longCategory,
      notes: _privateNotes,
    ),
    'uncategorized': TimeEntryDraft(
      startedAt: DateTime(2026, 11, 6, 11),
      endedAt: DateTime(2026, 11, 6, 11, 20),
      activity: '没有分类的活动',
      notes: _privateNotes,
    ),
    'ongoing': TimeEntryDraft(
      startedAt: DateTime(2026, 11, 6, 12),
      activity: '仍在进行的记录',
      category: _longCategory,
      notes: _privateNotes,
    ),
  };
  // Insert ongoing activity last so real overlap validation remains active.
  for (final TimeEntryDraft draft in drafts.values) {
    await repository.save(draft);
  }
  // Preserve the original persisted identities for row lookup and semantics.
  final List<TimeEntryRecord> saved = await database
      .select(database.timeEntries)
      .get();
  // Name each scenario without depending on generated UUID values.
  final Map<String, TimeEntryRecord> records = <String, TimeEntryRecord>{
    // Match the unique activities inserted above.
    for (final MapEntry<String, TimeEntryDraft> draft in drafts.entries)
      draft.key: saved.singleWhere(
        (TimeEntryRecord record) => record.activity == draft.value.activity,
      ),
  };
  // Only persistence is replaced; date queries and taxonomy remain production code.
  final ProviderContainer container = ProviderContainer(
    overrides: [appDatabaseProvider.overrideWithValue(database)],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(database.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(brightness: brightness)
            .copyWith(platform: TargetPlatform.android),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            boldText: boldText,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: HomeTimeStatusCard(now: now, flat: true),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return records;
}
