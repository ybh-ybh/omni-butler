import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/shared/layout/android_sidebar_swipe_target.dart';

/// Exercises actual pointer competition instead of invoking drag callbacks.
void main() {
  testWidgets('sidebar opening requires a completed rightward swipe', (
    WidgetTester tester,
  ) async {
    // Count only committed production gesture callbacks.
    int openings = 0;
    await _mount(tester, onOpen: () => openings++);
    await _slowDrag(tester, const Offset(40, 0));
    await _slowDrag(tester, const Offset(-180, 0));
    expect(openings, 0);
    await _slowDrag(tester, const Offset(150, 0));
    expect(openings, 1);
    await tester.flingFrom(const Offset(50, 200), const Offset(55, 0), 1100);
    await tester.pump();
    expect(openings, 2);

    // A reversal is ignored even when net travel still exceeds the threshold.
    final TestGesture reversed = await tester.startGesture(
      const Offset(50, 200),
    );
    await reversed.moveBy(const Offset(170, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await reversed.moveBy(const Offset(-35, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await reversed.up();
    expect(openings, 2);

    // Cancellation never commits the otherwise long-enough gesture.
    final TestGesture cancelled = await tester.startGesture(
      const Offset(50, 200),
    );
    await cancelled.moveBy(const Offset(160, 0));
    await cancelled.cancel();
    expect(openings, 2);
  });

  testWidgets('obscuring the workspace cancels an already active swipe', (
    WidgetTester tester,
  ) async {
    // The shell changes this gate while a menu opens above the retained page.
    final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    // Count callbacks that would incorrectly escape a newly opened overlay.
    int openings = 0;
    await _mount(tester, onOpen: () => openings++, visible: visible);
    // Keep the same pointer alive through the inherited availability update.
    final TestGesture gesture = await tester.startGesture(
      const Offset(50, 200),
    );
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    visible.value = false;
    await tester.pump();
    await gesture.moveBy(const Offset(80, 0));
    await gesture.up();
    expect(openings, 0);
    visible.value = true;
    await tester.pump();
    await _slowDrag(tester, const Offset(160, 0));
    expect(openings, 1);
  });

  testWidgets('horizontal content and sliders win before the sidebar', (
    WidgetTester tester,
  ) async {
    // The initial offset leaves actual room for a rightward content scroll.
    final ScrollController scroll = ScrollController(initialScrollOffset: 200);
    addTearDown(scroll.dispose);
    // Count only fallback sidebar gestures, not child interactions.
    int openings = 0;
    // Record the actual slider value delivered by its own drag recognizer.
    double value = .2;
    await _mount(
      tester,
      onOpen: () => openings++,
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 200,
            child: SingleChildScrollView(
              controller: scroll,
              scrollDirection: Axis.horizontal,
              child: const SizedBox(width: 1000, child: Text('横向正文')),
            ),
          ),
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => Slider(
              value: value,
              onChanged: (double next) => setState(() => value = next),
            ),
          ),
        ],
      ),
    );
    await tester.dragFrom(const Offset(60, 100), const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(scroll.offset, lessThan(100));
    await tester.drag(find.byType(Slider), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(value, greaterThan(.2));
    expect(openings, 0);
  });

  testWidgets('vertical scrolling and long-press selection remain available', (
    WidgetTester tester,
  ) async {
    // The vertical list must retain its own drag direction.
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    // No selection or vertical gesture is allowed to open navigation.
    int openings = 0;
    await _mount(
      tester,
      onOpen: () => openings++,
      child: ListView.builder(
        controller: scroll,
        itemCount: 40,
        itemBuilder: (BuildContext context, int index) =>
            SizedBox(height: 60, child: Text('条目 $index')),
      ),
    );
    await tester.dragFrom(const Offset(50, 250), const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(100));
    expect(openings, 0);

    // Observe real selection changes after a held pointer starts dragging.
    String? selection;
    await _mount(
      tester,
      onOpen: () => openings++,
      child: SelectionArea(
        onSelectionChanged: (SelectedContent? content) =>
            selection = content?.plainText,
        child: const Align(
          alignment: Alignment.topLeft,
          child: Text('Select this sentence and keep the sidebar closed.'),
        ),
      ),
    );
    // Holding before moving gives text selection ownership of the pointer.
    final TestGesture selecting = await tester.startGesture(
      const Offset(30, 8),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await selecting.moveBy(const Offset(150, 0));
    await selecting.up();
    await tester.pumpAndSettle();
    expect(selection, isNotEmpty);
    expect(openings, 0);
  });

  testWidgets('desktop and wide Android surfaces do not enable opening', (
    WidgetTester tester,
  ) async {
    // Existing wide and desktop navigation retain their original behavior.
    int openings = 0;
    await _mount(
      tester,
      onOpen: () => openings++,
      platform: TargetPlatform.windows,
    );
    await _slowDrag(tester, const Offset(160, 0));
    await _mount(tester, onOpen: () => openings++, width: 1000);
    await _slowDrag(tester, const Offset(160, 0));
    expect(openings, 0);
  });
}

/// Mounts the real helper while giving tests explicit platform and overlay state.
Future<void> _mount(
  WidgetTester tester, {
  required VoidCallback onOpen,
  Widget child = const SizedBox.expand(),
  ValueNotifier<bool>? visible,
  TargetPlatform platform = TargetPlatform.android,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: visible == null
            ? AndroidSidebarSwipeTarget(
                sidebarWidth: 320,
                onOpen: onOpen,
                child: child,
              )
            : ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder:
                    (BuildContext context, bool enabled, Widget? content) =>
                        AndroidSidebarSwipeScope(
                          enabled: enabled,
                          child: AndroidSidebarSwipeTarget(
                            sidebarWidth: 320,
                            onOpen: onOpen,
                            child: child,
                          ),
                        ),
              ),
      ),
    ),
  );
  await tester.pump();
}

/// Pauses before release so this gesture exercises distance rather than velocity.
Future<void> _slowDrag(WidgetTester tester, Offset distance) async {
  // A fixed body point is far from system edges and any bottom composer.
  final TestGesture gesture = await tester.startGesture(const Offset(50, 200));
  await gesture.moveBy(distance / 2);
  await tester.pump(const Duration(milliseconds: 150));
  await gesture.moveBy(distance / 2);
  await tester.pump(const Duration(milliseconds: 150));
  await gesture.up();
  await tester.pumpAndSettle();
}
