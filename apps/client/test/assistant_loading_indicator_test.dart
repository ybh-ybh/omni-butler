import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_loading_indicator.dart';

/// Sample rendered animation frames rather than depending on painter internals.
void main() {
  for (final bool reduced in <bool>[false, true]) {
    testWidgets('Four-color loading motion reduced=$reduced', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: const Center(
              child: RepaintBoundary(
                key: ValueKey<String>('loading-preview'),
                child: AssistantLoadingIndicator(animating: true),
              ),
            ),
          ),
        ),
      );
      // Capture actual pixels so both repaint motion and reduced motion are tested.
      Future<List<int>> capture(int frame) async {
        // Only the fixed spinner surface is sampled.
        final RenderRepaintBoundary boundary = tester.renderObject(
          find.byKey(const ValueKey<String>('loading-preview')),
        );
        // Image encoding runs outside the widget test's fake clock.
        return (await tester.runAsync(() async {
          // Render a readable reference without changing layout dimensions.
          final ui.Image image = await boundary.toImage(pixelRatio: 3);
          // Lossless frames allow direct pixel comparisons.
          final ByteData? data = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          // PNG buffers must outlive the native image object.
          final List<int> bytes = data!.buffer.asUint8List().toList();
          if (!reduced && Platform.environment['OMNI_LOADING_PREVIEW'] == '1') {
            await File('../../output/assistant-loading-frame-$frame.png')
                .writeAsBytes(bytes);
          }
          image.dispose();
          return bytes;
        }))!;
      }

      // Start the cycle before sampling both positions.
      await tester.pump();
      // Two separated frames must differ only when motion is enabled.
      final List<int> first = await capture(0);
      await tester.pump(const Duration(milliseconds: 250));
      // The next phase paints different arcs at the same bounds.
      final List<int> second = await capture(1);
      expect(
        second,
        reduced ? orderedEquals(first) : isNot(orderedEquals(first)),
      );
      for (int frame = 2; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 250));
        await capture(frame);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
}
