import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures the month calendar with real Chinese fonts and isolated data.
void main() {
  setUpAll(() async {
    // The host font is used only by this explicitly invoked preview tool.
    final ByteData font = ByteData.sublistView(
      await File(
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
      ).readAsBytes(),
    );
    // These aliases cover the production theme and Flutter test fallback.
    for (final String family in <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
      'Noto Sans CJK SC',
      'Ahem',
    ]) {
      // Each alias receives the same real glyph metrics.
      final FontLoader loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(font));
      await loader.load();
    }
    // The installed Flutter icon font avoids missing navigation glyphs.
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          Platform.environment['OMNI_UI_ICONS'] ?? 'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
    await Directory('../../output/windows-month-cards-preview')
        .create(recursive: true);
  });

  // Full application frames include the actual sidebar and toolbar widths.
  for (final _PreviewCase scenario in <_PreviewCase>[
    const _PreviewCase('windows-light-1440', Size(1440, 1000)),
    const _PreviewCase('windows-light-1920', Size(1920, 1000)),
    const _PreviewCase(
      'windows-dark-1440',
      Size(1440, 1000),
      brightness: Brightness.dark,
    ),
    const _PreviewCase('windows-narrow-512', Size(512, 1000)),
    const _PreviewCase(
      'windows-large-bold-1920',
      Size(1920, 1300),
      scale: 2,
      bold: true,
    ),
    const _PreviewCase(
      'windows-large-bold-3200',
      Size(3200, 1500),
      scale: 2,
      bold: true,
    ),
  ]) {
    testWidgets('月历真实中文预览 ${scenario.name}', (WidgetTester tester) async {
      tester.view.physicalSize = scenario.viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // All ongoing records share a deterministic, local observation time.
      final DateTime now = DateTime(2026, 10, 8, 18, 30);
      // This preview lives outside test/ because it requires local fonts.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues(<String, Object>{
        'appearance.theme_mode': scenario.brightness.name,
      });
      // Preferences are isolated from the real application's state.
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      // The preview owns this database and never opens the user's data.
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      await _seedMonth(database);
      // Sync is explicitly disabled even when the full router is mounted.
      final ProviderContainer container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
          nowProvider.overrideWithValue(now),
          syncRuntimeProvider.overrideWithValue(null),
        ],
      );
      // The root capture includes real scroll clipping and navigation chrome.
      final GlobalKey captureKey = GlobalKey();
      container.read(appRouterProvider).go('/timeline');
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: RepaintBoundary(
              key: captureKey,
              child: MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: AppTheme.build(brightness: scenario.brightness)
                    .copyWith(platform: TargetPlatform.windows),
                routerConfig: container.read(appRouterProvider),
                builder: (BuildContext context, Widget? child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scenario.scale),
                    boldText: scenario.bold,
                  ),
                  child: child!,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Scope the period label to avoid matching the calendar weekday.
        final Finder monthOption = find.descendant(
          of: find.byKey(const ValueKey<String>('timeline-period-control')),
          matching: find.text('月'),
        );
        await tester.tap(monthOption);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey<String>('timeline-month-fingerprint')),
          findsOneWidget,
        );
        // Narrow columns must keep the readable miniature calendar fallback.
        final bool expectCards =
            scenario.name != 'windows-narrow-512' &&
            scenario.name != 'windows-large-bold-1920';
        _expectCardTextGeometry(tester, expectCards: expectCards);
        expect(tester.takeException(), isNull);
        await _capture(tester, captureKey, scenario.name);
        if (scenario.name == 'windows-light-1440') {
          await _capture(
            tester,
            captureKey,
            'windows-calendar-detail-1440',
            bounds: _calendarDetailBounds(tester, captureKey),
          );
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        container.dispose();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(database.close);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
}

/// Checks painted glyph geometry rather than only accepting nonzero row sizes.
void _expectCardTextGeometry(WidgetTester tester, {required bool expectCards}) {
  // Record keys distinguish overview cards from other page text and tooltips.
  final Finder cards = find.byWidgetPredicate((Widget widget) {
    // Production record keys are unique within each natural-day projection.
    final Key? key = widget.key;
    return key is ValueKey<String> &&
        key.value.startsWith('timeline-month-record-');
  });
  if (!expectCards) {
    expect(cards, findsNothing);
    return;
  }
  expect(cards, findsWidgets);
  // All seeded records lie within the two visible calendar weeks.
  for (final Element element in cards.evaluate()) {
    // Each passive record card contains a title and a complete time line.
    final Finder labels = find.descendant(
      of: find.byWidget(element.widget),
      matching: find.byType(RichText),
    );
    expect(labels, findsNWidgets(2));
    // The title may ellipsize, but its first Chinese character must be painted.
    final RenderParagraph title = tester.renderObject<RenderParagraph>(
      labels.at(0),
    );
    // Every fixture title begins with one UTF-16 code unit of Chinese text.
    final List<ui.TextBox> firstGlyphBoxes = title.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 1),
    );
    expect(
      firstGlyphBoxes,
      isNotEmpty,
      reason: '${element.widget.key} must paint its first title character',
    );
    // Positive intersection proves the glyph is inside the paragraph clip.
    final Rect firstGlyph = firstGlyphBoxes.first.toRect().intersect(
      Offset.zero & title.size,
    );
    expect(firstGlyph.width, greaterThan(0));
    expect(firstGlyph.height, greaterThan(0));
    // Time metadata must remain fully readable rather than silently clipping.
    final RenderParagraph detail = tester.renderObject<RenderParagraph>(
      labels.at(1),
    );
    // The natural text width remains meaningful when softWrap is disabled.
    final double naturalWidth = detail.getMaxIntrinsicWidth(double.infinity);
    expect(
      naturalWidth,
      lessThanOrEqualTo(detail.size.width + 0.1),
      reason: '${element.widget.key} must fit its complete time line',
    );
    expect(detail.didExceedMaxLines, isFalse);
    // The trailing duration unit must still have an actual visible glyph box.
    final String detailText = detail.text.toPlainText();
    expect(detailText, isNotEmpty);
    // The seeded time strings end in a single-code-unit Latin duration suffix.
    final List<ui.TextBox> lastGlyphBoxes = detail.getBoxesForSelection(
      TextSelection(
        baseOffset: detailText.length - 1,
        extentOffset: detailText.length,
      ),
    );
    expect(lastGlyphBoxes, isNotEmpty);
    // Verify every directional box in case a locale introduces mixed runs.
    for (final ui.TextBox box in lastGlyphBoxes) {
      expect(box.left, greaterThanOrEqualTo(-0.1));
      expect(box.right, lessThanOrEqualTo(detail.size.width + 0.1));
      expect(box.top, greaterThanOrEqualTo(-0.1));
      expect(box.bottom, lessThanOrEqualTo(detail.size.height + 0.1));
      expect(box.right - box.left, greaterThan(0));
      expect(box.bottom - box.top, greaterThan(0));
    }
  }
}

/// Selects the live month panel through the bottom of the second calendar week.
Rect _calendarDetailBounds(WidgetTester tester, GlobalKey captureKey) {
  // The root boundary defines the local coordinate system used by OffsetLayer.
  final RenderRepaintBoundary boundary =
      captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // The panel includes its heading and weekdays, excluding the record toolbar.
  final Rect panel = tester.getRect(
    find.byKey(const ValueKey<String>('timeline-fingerprint')),
  );
  // October 11 is the Sunday at the end of the second row in October 2026.
  final Rect secondWeekEnd = tester.getRect(
    find.byKey(const ValueKey<String>('timeline-month-cell-2026-10-11')),
  );
  // Keep a small in-panel margin below the last included date row.
  final Offset topLeft = boundary.globalToLocal(panel.topLeft);
  // The right edge includes the panel's normal side padding and border.
  final Offset bottomRight = boundary.globalToLocal(
    Offset(panel.right, secondWeekEnd.bottom + 8),
  );
  // Pixel-aligned scene bounds preserve sharp unscaled Chinese glyphs.
  final Rect bounds = Rect.fromLTRB(
    topLeft.dx.floorToDouble(),
    topLeft.dy.floorToDouble(),
    bottomRight.dx.ceilToDouble(),
    bottomRight.dy.ceilToDouble(),
  );
  expect(bounds.left, greaterThanOrEqualTo(0));
  expect(bounds.top, greaterThanOrEqualTo(0));
  expect(bounds.right, lessThanOrEqualTo(boundary.size.width));
  expect(bounds.bottom, lessThanOrEqualTo(boundary.size.height));
  return bounds;
}

/// Describes one real viewport, theme, and accessibility configuration.
class _PreviewCase {
  /// Names the generated image without depending on the current time.
  final String name;

  /// Defines the complete application surface in logical pixels.
  final Size viewport;

  /// Selects the same production colors used by the desktop application.
  final Brightness brightness;

  /// Applies the operating system's text scale through MediaQuery.
  final double scale;

  /// Applies the system accessibility bold preference to all text.
  final bool bold;

  /// Creates one deterministic visual acceptance case.
  const _PreviewCase(
    this.name,
    this.viewport, {
    this.brightness = Brightness.light,
    this.scale = 1,
    this.bold = false,
  });
}

/// Seeds representative month days using only the in-memory repositories.
Future<void> _seedMonth(AppDatabase database) async {
  // Production persistence keeps the preview's split and duration behavior real.
  final TimeEntryRepository repository = TimeEntryRepository(database);
  // Taxonomy colors follow the categories visible in the reference screenshots.
  final TaxonomyRepository taxonomy = TaxonomyRepository(database);
  // Each category is scoped to the isolated preview database.
  for (final (String, Color) category in <(String, Color)>[
    ('睡眠', const Color(0xFF646970)),
    ('开发', const Color(0xFFD8A505)),
    ('吃饭', const Color(0xFF9260DF)),
    ('娱乐', const Color(0xFF199DFF)),
    ('学习', const Color(0xFF5F66A5)),
  ]) {
    await taxonomy.save(
      TaxonomyDraft(
        module: TaxonomyModule.timeline,
        kind: TaxonomyKind.category,
        name: category.$1,
        colorValue: category.$2.toARGB32(),
      ),
    );
  }
  // October 1 has one record while October 3 remains entirely empty.
  await _saveEntry(repository, 1, 480, 630, '阅读与整理笔记', '学习');
  // Exactly four entries exercise the absence of the extra-record footer.
  for (final (int, int, String, String?) entry in <(int, int, String, String?)>[
    (0, 420, '睡眠', '睡眠'),
    (480, 600, '开发知序', '开发'),
    (720, 765, '午饭', '吃饭'),
    (840, 980, '源码阅读', '学习'),
  ]) {
    await _saveEntry(repository, 2, entry.$1, entry.$2, entry.$3, entry.$4);
  }
  // This logical record appears as a separate slice in both October 4 and 5.
  await _saveEntry(repository, 4, 1380, 1440 + 440, '睡眠', '睡眠');
  // The dense day includes a one-minute entry and a long title near the top.
  for (final (int, int, String, String?) entry in <(int, int, String, String?)>[
    (440, 441, '查看消息', '娱乐'),
    (450, 480, '早餐与整理', '吃饭'),
    (510, 720, '开发知序：优化 Windows 时间月历中的每日记录展示', '开发'),
    (720, 780, '午饭', '吃饭'),
    (780, 1020, '开发知序', '开发'),
    (1080, 1140, '散步和听播客', '娱乐'),
    (1200, 1320, '阅读技术文章', '学习'),
  ]) {
    await _saveEntry(repository, 5, entry.$1, entry.$2, entry.$3, entry.$4);
  }
  // The final entry has no category and exercises the theme's fallback color.
  for (final (int, int, String, String?) entry in <(int, int, String, String?)>[
    (0, 480, '睡眠', '睡眠'),
    (540, 660, '开发知序', '开发'),
    (720, 780, '午饭', '吃饭'),
    (840, 1020, '整理工作计划', null),
  ]) {
    await _saveEntry(repository, 6, entry.$1, entry.$2, entry.$3, entry.$4);
  }
  // A second overnight record leaves three visible slots on the current day.
  await _saveEntry(repository, 7, 1380, 1440 + 420, '睡眠', '睡眠');
  await _saveEntry(repository, 8, 430, 465, '早餐', '吃饭');
  await _saveEntry(repository, 8, 480, 750, '开发知序', '开发');
  // Ongoing data is saved last so its open interval does not block the samples.
  await repository.save(
    TimeEntryDraft(
      startedAt: DateTime(2026, 10, 8, 17, 10),
      activity: '整理今天的开发记录',
      category: '学习',
    ),
  );
}

/// Saves one sample with minute offsets, including intentional midnight spans.
Future<void> _saveEntry(
  TimeEntryRepository repository,
  int dayNumber,
  int startMinute,
  int endMinute,
  String activity,
  String? category,
) async {
  // A single natural-day origin makes overnight sample bounds explicit.
  final DateTime day = DateTime(2026, 10, dayNumber);
  await repository.save(
    TimeEntryDraft(
      startedAt: day.add(Duration(minutes: startMinute)),
      endedAt: day.add(Duration(minutes: endMinute)),
      activity: activity,
      category: category,
    ),
  );
}

/// Captures full frames or live layer bounds without post-processing images.
Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  String name, {
  Rect? bounds,
}) async {
  await tester.runAsync(() async {
    // The mounted application boundary captures its final painted frame.
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // Logical pixel scale keeps each image directly comparable to its viewport.
    final ui.Image image = bounds == null
        ? await boundary.toImage(pixelRatio: 1)
        : await (boundary.debugLayer! as OffsetLayer).toImage(
            bounds,
            pixelRatio: 1,
          );
    try {
      // PNG bytes preserve sharp Chinese text for visual review.
      final ByteData bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await File('../../output/windows-month-cards-preview/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
