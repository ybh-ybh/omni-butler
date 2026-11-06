import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/floating/presentation/floating_glass_surface.dart';
import 'package:omni_butler/features/floating/presentation/floating_window_page.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Enable optional previews without maintaining platform-specific goldens.
final String? floatingGlassPreviewDirectory =
    Platform.environment['OMNI_FLOATING_GLASS_PREVIEW_DIR'];

/// Load real Chinese glyphs only when review images are explicitly requested.
Future<void> prepareFloatingGlassPreviews() async {
  if (floatingGlassPreviewDirectory == null) return;
  // Read the same local font used by existing Windows previews.
  final ByteData font = ByteData.sublistView(
    await File(
      Platform.environment['OMNI_UI_FONT'] ?? 'C:/Windows/Fonts/msyh.ttc',
    ).readAsBytes(),
  );
  // Override both production families and the test-only placeholder family.
  for (final String family in <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Roboto',
    'Noto Sans CJK SC',
    'Ahem',
  ]) {
    // Reuse one immutable font buffer for each registered family.
    final FontLoader loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(font));
    await loader.load();
  }
  // Preserve actual button icons in exported images.
  final ByteData icons = ByteData.sublistView(
    await File(
      Platform.environment['OMNI_UI_ICONS'] ??
          'D:/program/code/flutter/bin/cache/artifacts/material_fonts/'
              'materialicons-regular.otf',
    ).readAsBytes(),
  );
  await (FontLoader(
    'MaterialIcons',
  )..addFont(Future<ByteData>.value(icons))).load();
  await Directory(floatingGlassPreviewDirectory!).create(recursive: true);
  await File('${floatingGlassPreviewDirectory!}/widget-preview-readme.txt')
      .writeAsString(
        '最终预览仅为 widget-final-dark-synthetic-*.png，悬浮窗固定深色。\n'
        '旧 widget-synthetic-* 文件属于此前方案，不代表最终结果。\n'
        '这些 PNG 使用真实业务组件、内存数据和中文字体。\n'
        '背景由 Flutter 合成，仅用于审查材质、文字、布局和控件。\n'
        '它们不能证明 Windows Acrylic、WorkerW 或桌面穿透效果。\n',
      );
}

/// Keep page state, editable content, and its simulated native status together.
class FloatingGlassTestFixture {
  /// Create an isolated fixture after its repository has been seeded.
  FloatingGlassTestFixture._({
    required this.database,
    required this.container,
    required this.parentId,
  });

  /// A memory database prevents all writes to the user's actual data.
  final AppDatabase database;

  /// The production providers share one container across material changes.
  final ProviderContainer container;

  /// The seeded parent allows collapse-state checks against a stable identity.
  final String parentId;

  /// Match the native host's conservative first frame.
  final ValueNotifier<bool> backdropApplied = ValueNotifier<bool>(false);

  /// Capture the complete view, including the optional synthetic desktop.
  final GlobalKey captureKey = GlobalKey();

  /// Observe real route actions without opening another native window.
  final List<String> openedRoutes = <String>[];

  /// Count the real close action while leaving the test page mounted.
  int closeCount = 0;

  /// Seed short Chinese content across all visible business sections.
  static Future<FloatingGlassTestFixture> create() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Store feature preferences independently of other test cases.
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // Dispose the database after provider subscriptions have been removed.
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // Exercise production repository behavior rather than mocked row widgets.
    final TodoRepository repository = TodoRepository(database);
    // Freeze the business day and displayed clock.
    final DateTime now = DateTime(2026, 11, 6, 9, 30);
    await repository.save(
      TodoDraft(
        title: '完成界面调整',
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    // Capture the parent before adding the remaining records.
    final TodoRecord parent = await database
        .select(database.todoItems)
        .getSingle();
    await repository.save(
      TodoDraft(
        title: '核对玻璃边缘',
        parentId: parent.id,
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
      ),
    );
    await repository.save(TodoDraft(title: '阅读技术文档', scheduledDate: now));
    await repository.save(
      TodoDraft(
        title: '回复项目消息',
        scheduledDate: now,
        priorityQuadrant: TodoPriorityQuadrant.urgentNotImportant,
      ),
    );
    // Share the real in-memory providers with the production floating page.
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(now),
      ],
    );
    addTearDown(container.dispose);
    // Own the status notifier for exactly one test window lifetime.
    final FloatingGlassTestFixture fixture = FloatingGlassTestFixture._(
      database: database,
      container: container,
      parentId: parent.id,
    );
    addTearDown(fixture.backdropApplied.dispose);
    return fixture;
  }

  /// Simulate the main app theme while keeping the production floating theme dark.
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(294, 500),
    Brightness upstreamBrightness = Brightness.light,
    AppThemePalette palette = AppThemePalette.classicBlue,
    double textScale = 1,
    bool highContrast = false,
    bool syntheticBackdrop = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(
            brightness: upstreamBrightness,
            palette: palette,
          ),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              highContrast: highContrast,
            ),
            child: child!,
          ),
          home: Theme(
            data: buildFloatingWindowTheme(palette),
            child: RepaintBoundary(
              key: captureKey,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (syntheticBackdrop)
                    const CustomPaint(painter: _SyntheticDesktopPainter()),
                  ValueListenableBuilder<bool>(
                    valueListenable: backdropApplied,
                    builder:
                        (BuildContext context, bool applied, Widget? child) =>
                            FloatingWindowPage(
                              backdropApplied: applied,
                              onClose: () async => closeCount += 1,
                              onOpenRoute: (String route) async =>
                                  openedRoutes.add(route),
                              onDragStart: _ignoreGesture,
                              onDragUpdate: _ignoreGesture,
                              onDragEnd: _ignoreAsyncGesture,
                              onResizeStart: _ignoreGesture,
                              onResizeUpdate: _ignoreGesture,
                              onResizeEnd: _ignoreAsyncGesture,
                            ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Save a synthetic review image without modifying checked-in goldens.
  Future<void> capture(WidgetTester tester, String name) async {
    if (floatingGlassPreviewDirectory == null) return;
    await tester.pumpAndSettle();
    // Capture actual widgets rather than recreating their layout in an image.
    final RenderRepaintBoundary boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      // Dispose the native image after PNG encoding finishes.
      final ui.Image image = await boundary.toImage();
      try {
        // Preserve the encoded byte range exactly.
        final ByteData bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!;
        await File(
          '${floatingGlassPreviewDirectory!}/widget-final-dark-synthetic-$name.png',
        ).writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  }

  /// Detach widgets before providers and native database resources are disposed.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// Native movement is outside widget-level coverage.
  static void _ignoreGesture() {}

  /// Native gesture completion is outside widget-level coverage.
  static Future<void> _ignoreAsyncGesture() async {}
}

/// Supply broad contrasting shapes solely for synthetic visual review.
class _SyntheticDesktopPainter extends CustomPainter {
  /// Keep the backdrop deterministic across every preview.
  const _SyntheticDesktopPainter();

  /// Paint a neutral desktop-like field behind the real production widget.
  @override
  void paint(Canvas canvas, Size size) {
    // Cover the complete preview with a neutral light base.
    final Paint base = Paint()..color = const Color(0xFFCFD1D4);
    canvas.drawRect(Offset.zero & size, base);
    // Use a wide diagonal curve to expose material transparency.
    final Path wave = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width * 0.88, 0)
      ..cubicTo(
        size.width * 0.76,
        size.height * 0.48,
        size.width * 0.18,
        size.height * 0.45,
        size.width * 0.36,
        size.height,
      )
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(wave, Paint()..color = const Color(0xFF5D6268));
    // A smaller dark band checks the opposite end of the contrast range.
    final Path darkWave = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width * 0.40, 0)
      ..quadraticBezierTo(
        size.width * 0.24,
        size.height * 0.40,
        0,
        size.height * 0.67,
      )
      ..close();
    canvas.drawPath(darkWave, Paint()..color = const Color(0xFF202428));
  }

  /// The synthetic desktop never animates or changes during a scenario.
  @override
  bool shouldRepaint(_SyntheticDesktopPainter oldDelegate) => false;
}
