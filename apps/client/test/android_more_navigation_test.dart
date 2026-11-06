import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/home/presentation/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exercises the production menu with scaled fonts, safe areas and real taps.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadPreviewFonts);
  // Every viewport uses the production app and isolated persistence.
  for (final Brightness brightness in Brightness.values) {
    // Large-font and short-screen cases exercise both wrapping and scrolling.
    for (final profile in <({double width, double height, double scale})>[
      (width: 320, height: 844, scale: 1),
      (width: 360, height: 844, scale: 1),
      (width: 390, height: 844, scale: 1),
      (width: 320, height: 844, scale: 2),
      (width: 390, height: 400, scale: 2),
    ]) {
      testWidgets(
        '更多面板 ${brightness.name} ${profile.width}x${profile.height} ${profile.scale}',
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          tester.view.physicalSize = Size(profile.width, profile.height);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = FakeViewPadding(bottom: 24);
          tester.platformDispatcher.textScaleFactorTestValue = profile.scale;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          SharedPreferences.setMockInitialValues(<String, Object>{
            'appearance.theme_mode': brightness.name,
            'home.cards.order': <String>[
              'quote',
              'todos',
              'timeStatus',
              'todayContext',
            ],
          });
          // Keep fonts, theme and business widgets identical to the real app.
          final SharedPreferences preferences =
              await SharedPreferences.getInstance();
          // Never read or mutate the user's business data during previews.
          final AppDatabase database = AppDatabase.forTesting(
            NativeDatabase.memory(),
          );
          // Preloaded branches must also use an isolated chat cache.
          final AssistantCache cache = AssistantCache.forTesting(
            NativeDatabase.memory(),
          );
          await tester.runAsync(() => cache.readScope(null));
          // Provider overrides isolate the entire production navigation graph.
          final ProviderContainer container = ProviderContainer(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              appDatabaseProvider.overrideWithValue(database),
              assistantCacheProvider.overrideWithValue(cache),
              authControllerProvider.overrideWith(_LocalAuth.new),
              nowProvider.overrideWithValue(DateTime(2026, 11, 6, 14, 30)),
            ],
          );
          // The capture boundary remains mounted through all menu operations.
          final GlobalKey capture = GlobalKey();
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            container.dispose();
            await tester.pump();
            await cache.close();
            await database.close();
          });
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: RepaintBoundary(
                key: capture,
                child: const OmniButlerApp(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          // Menu toggles must not replace the home page or resize its viewport.
          final Element home = tester.element(find.byType(HomePage));
          // The navigation remains fixed above the bottom system safe area.
          final Rect navigation = tester.getRect(_key('compact-navigation'));
          // Stable filenames distinguish all independently rendered viewports.
          final String name =
              '${brightness.name}-${profile.width.toInt()}x${profile.height.toInt()}-${profile.scale.toInt()}x';
          await _capture(tester, capture, '$name-home');
          await tester.tap(_key('navigation-more'));
          await tester.pumpAndSettle();
          // The panel meets the top edge of the navigation without covering it.
          final Rect panel = tester.getRect(_key('android-more-panel'));
          expect(panel.bottom, closeTo(navigation.top, .1));
          expect(panel.left, 0);
          expect(panel.right, profile.width);
          expect(_key('navigation-more').hitTestable(), findsOneWidget);
          expect(tester.getRect(_key('compact-navigation')), navigation);
          expect(tester.element(find.byType(HomePage)), same(home));
          for (final String id in <String>[
            'todos',
            'timeline',
            'management',
            'settings',
          ]) {
            // Each visible icon label retains a physical touch-sized target.
            final Rect entry = tester.getRect(_key('more-shortcut-$id'));
            expect(entry.width, greaterThanOrEqualTo(48));
            expect(entry.height, greaterThanOrEqualTo(48));
            expect(_key('more-shortcut-$id').hitTestable(), findsOneWidget);
          }
          await _capture(tester, capture, '$name-more');
          // Native back consumes only the panel, including at the home root.
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(_key('android-more-panel'), findsNothing);
          expect(container.read(appRouterProvider).state.uri.path, '/home');
          // A downward gesture closes without activating the shortcut beneath it.
          await tester.tap(_key('navigation-more'));
          await tester.pumpAndSettle();
          await tester.dragFrom(
            Offset(profile.width / 2, panel.top + 8),
            const Offset(0, 55),
          );
          await tester.pumpAndSettle();
          expect(_key('android-more-panel'), findsNothing);
          expect(container.read(appRouterProvider).state.uri.path, '/home');
          // Other navigation items remain usable while the panel is visible.
          await tester.tap(_key('navigation-more'));
          await tester.pumpAndSettle();
          await tester.tap(_key('navigation-/notes'));
          await tester.pumpAndSettle();
          expect(_key('android-more-panel'), findsNothing);
          expect(container.read(appRouterProvider).state.uri.path, '/notes');
          expect(tester.takeException(), isNull);
          debugDefaultTargetPlatformOverride = null;
        },
      );
    }
  }
}

/// Resolves local mode without touching secure-storage or remote endpoints.
class _LocalAuth extends AuthController {
  /// Supplies a deterministic signed-out state.
  @override
  Future<SyncSession?> build() async => null;
}

/// Uses stable production identities instead of localized duplicate labels.
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// Loads actual Chinese glyphs only for explicitly requested local previews.
Future<void> _loadPreviewFonts() async {
  if (Platform.environment['OMNI_MORE_PREVIEW'] == null) return;
  // A local font is a test-only resource, never a bundled application asset.
  final ByteData bytes = ByteData.sublistView(
    await File(
      Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
    ).readAsBytes(),
  );
  for (final String family in <String>[
    'Roboto',
    'Ahem',
    'Noto Sans CJK SC',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
  ]) {
    // Register the same actual glyphs under the production fallback families.
    final FontLoader loader = FontLoader(family)..addFont(Future.value(bytes));
    await loader.load();
  }
  // Keep material icon geometry identical to the installed Flutter SDK.
  final FontLoader icons = FontLoader('MaterialIcons')
    ..addFont(
      File(
        Platform.environment['OMNI_UI_ICONS'] ?? 'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      ).readAsBytes().then(ByteData.sublistView),
    );
  await icons.load();
}

/// Exports the actual rendered production surface only when explicitly enabled.
Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  // CI verifies behavior without producing local visual artifacts.
  final String? directory = Platform.environment['OMNI_MORE_PREVIEW'];
  if (directory == null) return;
  await tester.runAsync(() async {
    // Capture after all layout and animation work has settled.
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // Encode outside fake async so file writes cannot stall the widget clock.
    final ui.Image image = await boundary.toImage();
    // Preserve lossless pixels for human inspection.
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}
