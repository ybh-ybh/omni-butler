import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the real compact navigation panel before inspecting its shortcuts.
Future<void> openAndroidMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('navigation-more')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey<String>('android-more-panel')),
    findsOneWidget,
  );
}

/// Navigates through the real panel and waits for its full-screen destination.
Future<void> openAndroidMoreDestination(WidgetTester tester, String id) async {
  await openAndroidMore(tester);
  await tester.tap(find.byKey(ValueKey<String>('more-shortcut-$id')));
  await tester.pumpAndSettle();
}
