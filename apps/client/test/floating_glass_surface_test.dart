import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/features/floating/presentation/floating_glass_surface.dart';
import 'package:omni_butler/features/floating/presentation/floating_window_page.dart';

import 'support/floating_glass_test_fixture.dart';

/// Read real rendered alpha rather than duplicating the material token values.
Future<ByteData> _surfacePixels(
  WidgetTester tester,
  GlobalKey boundaryKey,
) async {
  // Isolate the material so no test backdrop can hide an alpha regression.
  final RenderRepaintBoundary boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // Run image encoding outside the fake asynchronous test clock.
  final ByteData? pixels = await tester.runAsync(() async {
    // Keep the raster alive until the readback is complete.
    final ui.Image image = await boundary.toImage();
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    } finally {
      image.dispose();
    }
  });
  return pixels!;
}

/// Render an empty material so every alpha byte belongs to the surface itself.
Future<void> _pumpSurface(
  WidgetTester tester, {
  required GlobalKey boundaryKey,
  required bool backdropApplied,
  bool highContrast = false,
}) async {
  tester.view.physicalSize = const Size(180, 160);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFloatingWindowTheme(AppThemePalette.classicBlue),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(highContrast: highContrast),
        child: child!,
      ),
      home: RepaintBoundary(
        key: boundaryKey,
        child: FloatingGlassSurface(
          backdropApplied: backdropApplied,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Keep test window dimensions from leaking into neighboring suites.
void _resetViewAfterTest(WidgetTester tester) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Find the accessible name below the Windows-only semantics boundary.
bool _hasSemanticName(SemanticsNode node, String expected) {
  // Windows deliberately keeps the button separate from its wrapper node.
  final SemanticsData data = node.getSemanticsData();
  if (data.tooltip == expected || data.label == expected) return true;
  // Search descendants without assuming a fixed semantics implementation depth.
  bool found = false;
  node.visitChildren((SemanticsNode child) {
    found = _hasSemanticName(child, expected);
    return !found;
  });
  return found;
}

/// Verify window transparency, state continuity, and production interactions.
void main() {
  setUpAll(prepareFloatingGlassPreviews);

  // Check the single smoke material without relying on exact tint constants.
  testWidgets('深色玻璃保留真实像素 alpha', (WidgetTester tester) async {
    _resetViewAfterTest(tester);
    // The boundary contains no other widgets or desktop-like background.
    final GlobalKey boundaryKey = GlobalKey();
    await _pumpSurface(tester, boundaryKey: boundaryKey, backdropApplied: true);
    // Probe the empty center rather than a highlight or shadow edge.
    final ByteData pixels = await _surfacePixels(tester, boundaryKey);
    // A visible material must remain translucent rather than opaque or absent.
    final int centerAlpha = pixels.getUint8((80 * 180 + 90) * 4 + 3);
    expect(centerAlpha, greaterThan(0));
    expect(centerAlpha, lessThan(255));
    expect(pixels.getUint8(3), lessThan(255));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // API failure and user high-contrast preference share the safe fallback.
  for (final bool highContrast in <bool>[false, true]) {
    testWidgets('深色实底降级覆盖边角 highContrast=$highContrast', (
      WidgetTester tester,
    ) async {
      _resetViewAfterTest(tester);
      // Capture the complete native-sized content including outer margins.
      final GlobalKey boundaryKey = GlobalKey();
      await _pumpSurface(
        tester,
        boundaryKey: boundaryKey,
        backdropApplied: highContrast,
        highContrast: highContrast,
      );
      // Check every pixel so transparent rounded corners cannot escape.
      final ByteData pixels = await _surfacePixels(tester, boundaryKey);
      // Track the first gap with an actionable raster coordinate.
      int? transparentPixel;
      // Walk only alpha channels in the raw RGBA image.
      for (int offset = 3; offset < pixels.lengthInBytes; offset += 4) {
        if (pixels.getUint8(offset) != 255) {
          transparentPixel = offset ~/ 4;
          break;
        }
      }
      expect(transparentPixel, isNull);
      // The corner must be the theme's paper color, not uninitialized black.
      final Color paper = buildFloatingWindowTheme(AppThemePalette.classicBlue)
          .extension<OmniColors>()!
          .paper;
      // Compare a visible output color with the existing semantic theme.
      final int expectedRgb = paper.toARGB32() & 0xFFFFFF;
      // Read the fully opaque top-left pixel without premultiplication loss.
      final int actualRgb =
          (pixels.getUint8(0) << 16) |
          (pixels.getUint8(1) << 8) |
          pixels.getUint8(2);
      expect(actualRgb, expectedRgb);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('主应用明暗切换仍保持深色浮窗、草稿、焦点和任务展开状态', (WidgetTester tester) async {
    _resetViewAfterTest(tester);
    // Seed a real parent and child task with the native backdrop initially off.
    final FloatingGlassTestFixture fixture =
        await FloatingGlassTestFixture.create();
    await fixture.pump(tester, size: const Size(440, 700));
    await tester.tap(
      find.byKey(ValueKey<String>('floating-todo-expand-${fixture.parentId}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('核对玻璃边缘'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('floating-todo-create')),
    );
    await tester.pumpAndSettle();
    // Use the production input and preserve both its text and its focus owner.
    final Finder titleField = find.byKey(
      const ValueKey<String>('floating-todo-title-field'),
    );
    await tester.enterText(titleField, '切换材质后继续编辑');
    await tester.pump();
    // The editor identity detects remounting even if text is later restored.
    final Finder editable = find.descendant(
      of: titleField,
      matching: find.byType(EditableText),
    );
    // Keep the original text editing state and focus node.
    final EditableTextState originalEditor = tester.state(editable);
    // Retain the page identity as the material changes below it.
    final State<StatefulWidget> originalPage = tester.state(
      find.byType(FloatingWindowPage),
    );
    // Native setup success and conservative fallback must not affect content.
    for (final bool applied in <bool>[true, false, true]) {
      fixture.backdropApplied.value = applied;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(FloatingWindowPage)), same(originalPage));
      expect(tester.state(editable), same(originalEditor));
      expect(originalEditor.widget.focusNode.hasFocus, isTrue);
      expect(originalEditor.widget.controller.text, '切换材质后继续编辑');
      expect(find.text('核对玻璃边缘'), findsNothing);
      expect(find.byTooltip('展开全部子任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    // The main application can change mode without changing this dark surface.
    for (final Brightness upstreamBrightness in <Brightness>[
      Brightness.dark,
      Brightness.light,
    ]) {
      await fixture.pump(
        tester,
        size: const Size(440, 700),
        upstreamBrightness: upstreamBrightness,
      );
      expect(
        Theme.of(tester.element(find.byType(FloatingWindowPage))).brightness,
        Brightness.dark,
      );
      expect(tester.state(find.byType(FloatingWindowPage)), same(originalPage));
      expect(tester.state(editable), same(originalEditor));
      expect(originalEditor.widget.focusNode.hasFocus, isTrue);
      expect(originalEditor.widget.controller.text, '切换材质后继续编辑');
      expect(find.byTooltip('展开全部子任务'), findsOneWidget);
    }
    // Save through the real form after every appearance transition.
    final Finder save = find.byKey(
      const ValueKey<String>('floating-todo-inline-save'),
    );
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      (await fixture.database.select(fixture.database.todoItems).get()).where(
        (record) => record.title == '切换材质后继续编辑',
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
    await fixture.unmount(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // Every existing palette must retain its own accent in the fixed dark theme.
  for (final AppThemePalette palette in AppThemePalette.values) {
    testWidgets('固定深色浮窗保留${palette.label}强调色', (WidgetTester tester) async {
      _resetViewAfterTest(tester);
      // Keep one real page mounted while changing the upstream brightness.
      final FloatingGlassTestFixture fixture =
          await FloatingGlassTestFixture.create();
      fixture.backdropApplied.value = true;
      // Resolve the expected accent from the existing application palette.
      final ThemeData expectedTheme = AppTheme.build(
        brightness: Brightness.dark,
        palette: palette,
      );
      // The native floating theme must ignore both possible upstream modes.
      for (final Brightness upstreamBrightness in Brightness.values) {
        await fixture.pump(
          tester,
          palette: palette,
          upstreamBrightness: upstreamBrightness,
        );
        // Inspect the actual inherited theme at the production page.
        final ThemeData actualTheme = Theme.of(
          tester.element(find.byType(FloatingWindowPage)),
        );
        expect(actualTheme.brightness, Brightness.dark);
        expect(
          actualTheme.colorScheme.primary,
          expectedTheme.colorScheme.primary,
        );
        // Check a rendered accent-bearing icon rather than helper output alone.
        final Icon dateIcon = tester.widget<Icon>(
          find.byIcon(Icons.today_outlined),
        );
        expect(dateIcon.color, expectedTheme.extension<OmniColors>()!.brand);
        expect(tester.takeException(), isNull);
      }
      await fixture.unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  // Cover both supported window sizes with actual application text scaling.
  for (final Size size in <Size>[const Size(294, 500), const Size(440, 700)]) {
    // Include the intermediate scale as well as maximum requested text size.
    for (final double textScale in <double>[1, 1.5, 2]) {
      testWidgets('固定深色玻璃业务布局 ${size.width.toInt()}x${size.height.toInt()} '
          '${textScale}x', (WidgetTester tester) async {
        _resetViewAfterTest(tester);
        // Keep semantics active while validating icon-only actions.
        final SemanticsHandle semantics = tester.ensureSemantics();
        try {
          // Drive the same page instance used by the real Windows host.
          final FloatingGlassTestFixture fixture =
              await FloatingGlassTestFixture.create();
          fixture.backdropApplied.value = true;
          await fixture.pump(
            tester,
            size: size,
            textScale: textScale,
            syntheticBackdrop: floatingGlassPreviewDirectory != null,
          );
          expect(tester.takeException(), isNull);
          // Name files by their actual viewport and theme.
          final String previewName =
              '${size.width.toInt()}x${size.height.toInt()}'
              '-text$textScale';
          await fixture.capture(tester, '$previewName-overview');
          // Header actions remain named, tappable, and inside the viewport.
          final Finder open = find.byKey(
            const ValueKey<String>('floating-window-open-todos'),
          );
          // Close stays independent of the decorative glass perimeter.
          final Finder close = find.byKey(
            const ValueKey<String>('floating-window-close-button'),
          );
          expect(open.hitTestable(), findsOneWidget);
          expect(close.hitTestable(), findsOneWidget);
          expect(_hasSemanticName(tester.getSemantics(open), '打开每日待办'), isTrue);
          expect(
            _hasSemanticName(tester.getSemantics(close), '关闭桌面悬浮框'),
            isTrue,
          );
          await tester.tap(open);
          await tester.pumpAndSettle();
          expect(fixture.openedRoutes, <String>['/todos']);
          await tester.tap(close);
          await tester.pumpAndSettle();
          expect(fixture.closeCount, 1);

          await tester.tap(
            find.byKey(const ValueKey<String>('floating-todo-create')),
          );
          await tester.pumpAndSettle();
          // Scrollable forms remain usable even when large text exceeds height.
          final Finder title = find.byKey(
            const ValueKey<String>('floating-todo-title-field'),
          );
          await tester.ensureVisible(title);
          await tester.enterText(title, '整理今天的工作记录');
          await tester.pumpAndSettle();
          if (textScale == 1) {
            await fixture.capture(tester, '$previewName-todo-form');
          }
          // Cancel through the visible production action rather than state reset.
          final Finder cancelTodo = find.byKey(
            const ValueKey<String>('floating-todo-inline-cancel'),
          );
          await tester.ensureVisible(cancelTodo);
          await tester.tap(cancelTodo);
          await tester.pumpAndSettle();
          expect(title, findsNothing);

          // The time section remains reachable in short, scaled windows.
          final Finder start = find.byKey(
            const ValueKey<String>('floating-time-start'),
          );
          await tester.ensureVisible(start);
          await tester.pumpAndSettle();
          expect(start.hitTestable(), findsOneWidget);
          expect(
            find.byKey(const ValueKey<String>('floating-time-backfill')),
            findsOneWidget,
          );
          await tester.tap(start);
          await tester.pumpAndSettle();
          // The real activity editor proves the start button receives input.
          final Finder activity = find.byKey(
            const ValueKey<String>('floating-time-activity-field'),
          );
          await tester.ensureVisible(activity);
          await tester.enterText(activity, '专注开发');
          await tester.pumpAndSettle();
          if (textScale == 1) {
            await fixture.capture(tester, '$previewName-time-form');
          }
          // Closing the editor restores the existing page without saving data.
          final Finder cancelTime = find.byKey(
            const ValueKey<String>('floating-time-inline-cancel'),
          );
          await tester.ensureVisible(cancelTime);
          await tester.tap(cancelTime);
          await tester.pumpAndSettle();
          expect(activity, findsNothing);
          expect(tester.takeException(), isNull);
          await fixture.unmount(tester);
        } finally {
          semantics.dispose();
        }
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
    }
  }
}
