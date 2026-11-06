import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/home/presentation/home_time_status_card.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';

/// Keep all persisted intervals and the running duration deterministic.
final DateTime _previewNow = DateTime(2026, 11, 6, 15, 30);

/// Store review images outside the tracked application source tree.
const String _outputDirectory = '../../output/android-home-time-preview';

/// Render the production card with real Chinese glyphs and isolated data.
void main() {
  setUpAll(() async {
    // Load the same Chinese font used by the existing business preview tool.
    final String fontPath =
        Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc';
    // Resolve the SDK icon font without depending on a running application.
    final String iconPath =
        Platform.environment['OMNI_UI_ICONS'] ??
        'D:/program/code/flutter/bin/cache/artifacts/material_fonts/'
            'materialicons-regular.otf';
    // Reuse immutable font bytes across every family used by the theme.
    final ByteData fontBytes = await _readFont(fontPath);
    // Override the test fallback as well as production font families.
    for (final String family in <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Roboto',
      'Noto Sans CJK SC',
      'Ahem',
    ]) {
      // Register each family with the same real CJK glyph metrics.
      final FontLoader loader = FontLoader(family);
      loader.addFont(Future<ByteData>.value(fontBytes));
      await loader.load();
    }
    // Preserve real icon glyphs in the card's existing controls.
    final FontLoader icons = FontLoader('MaterialIcons');
    icons.addFont(_readFont(iconPath));
    await icons.load();
    await Directory(_outputDirectory).create(recursive: true);
  });

  // Exercise both mobile widths with each supported preview text scale.
  for (final double width in <double>[320, 390]) {
    // Keep the system scale intact in every generated image.
    for (final double textScale in <double>[1, 2]) {
      // Verify muted labels and category borders in both themes.
      for (final Brightness brightness in Brightness.values) {
        testWidgets(
          'Android time rows ${width.toInt()} ${textScale.toInt()}x ${brightness.name}',
          (WidgetTester tester) async {
            await _captureCard(
              tester,
              width: width,
              textScale: textScale,
              brightness: brightness,
            );
          },
          variant: TargetPlatformVariant.only(TargetPlatform.android),
        );
      }
    }
  }

  testWidgets('Android time rows 800 1x light', (WidgetTester tester) async {
    await _captureCard(
      tester,
      width: 800,
      textScale: 1,
      brightness: Brightness.light,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android time rows 320 2x light bold', (
    WidgetTester tester,
  ) async {
    await _captureCard(
      tester,
      width: 320,
      textScale: 2,
      brightness: Brightness.light,
      boldText: true,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

/// Read required preview fonts and fail clearly when a local path is missing.
Future<ByteData> _readFont(String path) async {
  // Preserve the exact requested path in any missing-font error.
  final File file = File(path);
  if (!await file.exists()) {
    throw StateError('Preview font not found: $path');
  }
  return ByteData.sublistView(await file.readAsBytes());
}

/// Build one complete card without starting sync or opening user data.
Future<void> _captureCard(
  WidgetTester tester, {
  required double width,
  required double textScale,
  required Brightness brightness,
  bool boldText = false,
}) async {
  // Provide enough vertical space to inspect every row at its natural height.
  final Size viewport = Size(width, textScale == 1 ? 1100 : 1700);
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Persist only synthetic records in a fresh in-memory SQLite database.
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // Use production repositories and subscriptions through this isolated source.
  final ProviderContainer container = ProviderContainer(
    overrides: [appDatabaseProvider.overrideWithValue(database)],
  );
  // Capture the complete rendered card, including its natural row heights.
  final GlobalKey captureKey = GlobalKey();
  // Match the home surface inside the image boundary, including flat areas.
  final ThemeData theme = AppTheme.build(brightness: brightness)
      .copyWith(platform: TargetPlatform.android);
  try {
    await _seedRecords(database);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              boldText: boldText,
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: captureKey,
                child: ColoredBox(
                  color: theme.scaffoldBackgroundColor,
                  child: HomeTimeStatusCard(now: _previewNow, flat: true),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未命名记录'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('这段备注不应显示在首页列表'), findsNothing);
    _expectFirstGlyphsVisible(tester);
    expect(
      tester.getRect(find.text('睡眠')).bottom,
      lessThanOrEqualTo(tester.getRect(find.byKey(captureKey)).bottom),
    );
    expect(tester.takeException(), isNull);
    // Name every artifact by width, text scale, and theme for direct comparison.
    final String filename =
        'android-${width.toInt()}-${textScale.toInt()}x-${brightness.name}'
        '${boldText ? '-bold' : ''}.png';
    // Render actual Flutter paint output instead of constructing mock images.
    final RenderRepaintBoundary boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      // Keep one image pixel per logical pixel for layout measurements.
      final ui.Image image = await boundary.toImage();
      try {
        // Save lossless pixels so small text and the three-pixel border stay clear.
        final ByteData bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!;
        await File('$_outputDirectory/$filename').writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  } finally {
    // Unmount subscribers before disposing their provider-owned streams.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    // Drain both fake timers and real cancellation futures before closing Drift.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => database.close().timeout(const Duration(seconds: 10)),
    );
  }
}

/// Verify actual glyph layout rather than accepting an empty nonzero-width box.
void _expectFirstGlyphsVisible(WidgetTester tester) {
  // Target only record titles and categories, excluding the donut legend.
  final Finder labels = find.byWidgetPredicate((Widget widget) {
    // Production keys identify the two text columns independently of contents.
    final Key? key = widget.key;
    return widget is Text &&
        key is ValueKey<String> &&
        (key.value.startsWith('home-time-entry-title-') ||
            key.value.startsWith('home-time-entry-category-'));
  });
  expect(labels, findsNWidgets(10));
  // Check every row so short labels and legacy fallbacks receive equal coverage.
  for (final Element element in labels.evaluate()) {
    // Resolve the concrete RichText below the keyed Text widget.
    final Finder richText = find.descendant(
      of: find.byWidget(element.widget),
      matching: find.byType(RichText),
    );
    // Query the paragraph's laid-out glyph selection, including ellipsis effects.
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      richText,
    );
    // All fixture strings begin with a single-code-unit Chinese character.
    final List<ui.TextBox> firstGlyphBoxes = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 1),
    );
    expect(
      firstGlyphBoxes,
      isNotEmpty,
      reason: '${element.widget.key} must paint its first character',
    );
  }
}

/// Seed disjoint intervals that cover every meaningful display fallback.
Future<void> _seedRecords(AppDatabase database) async {
  // Create real taxonomy records to exercise the production color mapping.
  final TaxonomyRepository taxonomy = TaxonomyRepository(database);
  await taxonomy.save(
    const TaxonomyDraft(
      module: TaxonomyModule.timeline,
      kind: TaxonomyKind.category,
      name: '工作与项目开发分类',
      colorValue: 0xFF3370FF,
    ),
  );
  await taxonomy.save(
    const TaxonomyDraft(
      module: TaxonomyModule.timeline,
      kind: TaxonomyKind.category,
      name: '休息',
      colorValue: 0xFF8B6AD9,
    ),
  );
  await taxonomy.save(
    const TaxonomyDraft(
      module: TaxonomyModule.timeline,
      kind: TaxonomyKind.category,
      name: '阅读',
      colorValue: 0xFF1EA7A1,
    ),
  );
  // Use the same persistence and interval validation as real user edits.
  final TimeEntryRepository repository = TimeEntryRepository(database);
  await repository.save(
    TimeEntryDraft(
      startedAt: DateTime(2026, 11, 5, 23, 30),
      endedAt: DateTime(2026, 11, 6, 7),
      activity: '睡眠',
      category: '休息',
    ),
  );
  await repository.save(
    TimeEntryDraft(
      startedAt: DateTime(2026, 11, 6, 9),
      endedAt: DateTime(2026, 11, 6, 10, 45),
      activity: '整理项目需求并完成安卓首页时间记录列表的布局与细节调整',
      category: '工作与项目开发分类',
      notes: '这段备注不应显示在首页列表',
    ),
  );
  await repository.save(
    TimeEntryDraft(
      startedAt: DateTime(2026, 11, 6, 11),
      endedAt: DateTime(2026, 11, 6, 11, 30),
      activity: 'Legacy title placeholder',
    ),
  );
  // Only legacy data can omit a completed title; normal saves require one.
  await (database.update(database.timeEntries)..where(
        (TimeEntries table) =>
            table.activity.equals('Legacy title placeholder'),
      ))
      .write(const TimeEntriesCompanion(activity: Value<String?>(null)));
  await repository.save(
    TimeEntryDraft(
      startedAt: DateTime(2026, 11, 6, 12),
      endedAt: DateTime(2026, 11, 6, 12, 45),
      activity: '阅读与笔记',
      category: '阅读',
    ),
  );
  await repository.save(
    TimeEntryDraft(
      startedAt: DateTime(2026, 11, 6, 14),
      activity: '实现时间列表布局',
      category: '工作与项目开发分类',
    ),
  );
}
