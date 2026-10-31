import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/home/data/quote_repository.dart';
import 'package:omni_butler/features/home/presentation/quote_library_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 可注入名言库弹窗的测试文件网关。
class _FakeQuoteJsonFileGateway implements QuoteJsonFileGateway {
  /// 导入时返回的文件。
  final QuoteJsonInputFile? inputFile;

  /// 导出时模拟的保存地址。
  final Uri? outputUri;

  /// 最近一次导出的文件名。
  String? savedFileName;

  /// 最近一次导出的文件字节。
  Uint8List? savedBytes;

  /// 创建测试文件网关。
  _FakeQuoteJsonFileGateway({this.inputFile, this.outputUri});

  /// 返回预设导入文件。
  @override
  Future<QuoteJsonInputFile?> pickImportFile() async => inputFile;

  /// 记录导出参数并返回预设地址。
  @override
  Future<Uri?> saveExportFile({
    required String fileName,
    required Uint8List bytes,
  }) async {
    savedFileName = fileName;
    savedBytes = bytes;
    return outputUri;
  }
}

/// Delay persistence at the repository boundary without replacing the editor.
class _DelayedQuoteRepository extends QuoteRepository {
  /// Keep the first attempt pending until the test releases it.
  final Completer<void> gate = Completer<void>();

  /// Fail the first attempt so the original draft can be retried.
  bool fail = true;

  /// Count accepted repository calls to check duplicate protection.
  int calls = 0;

  /// Use the same database as the production repository implementation.
  _DelayedQuoteRepository(super.database);

  /// Resume the real save only after the controlled delay succeeds.
  @override
  Future<void> save(QuoteDraft draft) async {
    calls++;
    await gate.future;
    if (fail) throw StateError('模拟保存失败');
    await super.save(draft);
  }
}

/// 验证名言库 JSON 操作菜单与导入预览交互。
void main() {
  // Android preserves the original action while Windows keeps its existing text.
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name}名言异步保存保持平台外观并允许失败重试', (tester) async {
      // Real database reads remain active while only saves are delayed.
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      // Preserve the editor's normal provider wiring and save validation.
      final _DelayedQuoteRepository repository = _DelayedQuoteRepository(
        database,
      );
      addTearDown(() {
        if (!repository.gate.isCompleted) repository.gate.complete();
      });
      await _pumpDialog(
        tester,
        database: database,
        gateway: _FakeQuoteJsonFileGateway(),
        repository: repository,
        platform: platform,
      );
      await tester.tap(find.text('新增名言'));
      await tester.pumpAndSettle();
      // The default wide test viewport preserves the established side sheet.
      expect(
        find.byKey(const ValueKey<String>('quote-editor-fullscreen')),
        findsNothing,
      );
      expect(find.byType(OmniSideSheetScaffold), findsOneWidget);
      await tester.enterText(find.byType(OmniTextField).first, '保留的名言草稿');
      // Capture the resting visual geometry and colors before the pending save.
      final Finder save = find.widgetWithText(OmniButton, '保存');
      // The Android action should keep its original measured surface.
      final Rect before = tester.getRect(save);
      // Native style resolution distinguishes busy from normally disabled.
      final ButtonStyle style = tester
          .widget<FilledButton>(
            find.descendant(of: save, matching: find.byType(FilledButton)),
          )
          .style!;
      await tester.tap(save);
      await tester.pumpAndSettle();
      // The desktop implementation intentionally retains its original busy label.
      final Finder pending = find.widgetWithText(
        OmniButton,
        platform == TargetPlatform.android ? '保存' : '保存中',
      );
      expect(tester.widget<OmniButton>(pending).onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      if (platform == TargetPlatform.android) {
        expect(tester.getRect(pending), before);
        // The same native fill is retained even though repeat taps are disabled.
        final ButtonStyle busyStyle = tester
            .widget<FilledButton>(
              find.descendant(of: pending, matching: find.byType(FilledButton)),
            )
            .style!;
        expect(
          busyStyle.backgroundColor!.resolve(<WidgetState>{
            WidgetState.disabled,
          }),
          style.backgroundColor!.resolve(<WidgetState>{}),
        );
      }
      await tester.tap(pending);
      expect(repository.calls, 1);
      repository.gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('名言未保存，请保留草稿并重试。'), findsOneWidget);
      expect(find.text('保留的名言草稿'), findsOneWidget);
      repository.fail = false;
      await tester.tap(find.widgetWithText(OmniButton, '保存'));
      await tester.pumpAndSettle();
      expect(repository.calls, 2);
      expect(
        (await database.select(database.quotes).getSingle()).content,
        '保留的名言草稿',
      );
      await _disposeDialog(tester, database);
    });
  }

  testWidgets('旧编辑器遇到MCP下行后保留窗口和草稿，不覆盖服务器内容', (WidgetTester tester) async {
    // 真实内存库与仓储，模拟已同步的正式名言。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 先保存再读取编辑开始时的身份。
    final QuoteRepository repository = QuoteRepository(database);
    await repository.save(const QuoteDraft(content: '原名言'));
    // 只有原身份才能被后来的服务器事实更新。
    final QuoteRecord original = await database
        .select(database.quotes)
        .getSingle();
    await _pumpDialog(
      tester,
      database: database,
      gateway: _FakeQuoteJsonFileGateway(),
    );
    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(OmniTextField).first, '尚未提交的用户草稿');
    // 编辑器仍打开时模拟远端下行，列表更新不能重置编辑基线。
    await repository.save(QuoteDraft(id: original.id, content: 'MCP正式内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OmniButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('记录已在其他设备或 MCP 中修改'), findsOneWidget);
    expect(find.text('编辑名言'), findsOneWidget);
    expect(find.text('尚未提交的用户草稿'), findsOneWidget);
    expect(
      (await database.select(database.quotes).getSingle()).content,
      'MCP正式内容',
    );
    await _disposeDialog(tester, database);
  });

  testWidgets('Android宽屏保留卡片列表和侧边编辑器', (WidgetTester tester) async {
    // A wide Android viewport represents the unchanged tablet presentation.
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Seed one quote so the established card and leading icon are rendered.
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // The production repository keeps the test on the normal read path.
    final QuoteRepository repository = QuoteRepository(database);
    await repository.save(const QuoteDraft(content: '宽屏名言'));
    await _pumpDialog(
      tester,
      database: database,
      gateway: _FakeQuoteJsonFileGateway(),
      platform: TargetPlatform.android,
    );

    expect(
      find.byKey(const ValueKey<String>('quote-library-fullscreen')),
      findsNothing,
    );
    expect(find.byType(OmniPanel), findsOneWidget);
    expect(find.byIcon(Icons.format_quote_rounded), findsOneWidget);
    await tester.tap(find.text('宽屏名言'));
    await tester.pumpAndSettle();
    expect(find.byType(OmniSideSheetScaffold), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('quote-editor-fullscreen')),
      findsNothing,
    );
    await _disposeDialog(tester, database);
  });

  testWidgets('紧凑布局可预览并选择替换导入且不发生溢出', (WidgetTester tester) async {
    // 模拟 Android 紧凑视口。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 当前名言库仓储。
    final QuoteRepository repository = QuoteRepository(database);
    await repository.save(const QuoteDraft(content: '旧名言', source: '旧作者'));
    // 会产生一条文件内重复项的导入文件。
    final QuoteJsonInputFile inputFile = QuoteJsonInputFile(
      name: 'quotes.json',
      bytes: Uint8List.fromList(
        utf8.encode('''[
          {"content":"新名言","author":"新作者"},
          {"content":"新名言","author":"新作者"}
        ]'''),
      ),
    );
    // 替代系统文件选择器的测试网关。
    final _FakeQuoteJsonFileGateway gateway = _FakeQuoteJsonFileGateway(
      inputFile: inputFile,
    );

    await _pumpDialog(
      tester,
      database: database,
      gateway: gateway,
      platform: TargetPlatform.android,
    );
    await tester.tap(find.byKey(const ValueKey<String>('quote-transfer-menu')));
    await tester.pumpAndSettle();
    expect(find.text('导入 JSON'), findsOneWidget);
    expect(find.text('导出 JSON'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('quote-import-json-action')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('导入预览'), findsOneWidget);
    expect(find.text('文件共 2 条，去重后 1 条 · 文件内重复 1 条'), findsOneWidget);
    expect(find.text('合并导入'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('quote-import-replace-warning')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('quote-import-mode-replace')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('quote-import-replace-warning')),
      findsOneWidget,
    );
    expect(find.text('替换并导入'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('quote-import-confirm-button')),
    );
    await tester.pumpAndSettle();
    // 导入后的全部新旧名言。
    final List<QuoteRecord> records = await database
        .select(database.quotes)
        .get();

    expect(records, hasLength(2));
    expect(
      records.singleWhere((QuoteRecord row) => row.deletedAt == null).content,
      '新名言',
    );
    expect(
      records.singleWhere((QuoteRecord row) => row.content == '旧名言').deletedAt,
      isNotNull,
    );
    await tester.pump(const Duration(seconds: 5));
    await _disposeDialog(tester, database);
  });

  // Both themes use the same compact full-screen geometry and nested flows.
  for (final Brightness brightness in <Brightness>[
    Brightness.light,
    Brightness.dark,
  ]) {
    testWidgets('安卓全屏名言库适配窄屏大字并保留操作层级 $brightness', (
      WidgetTester tester,
    ) async {
      // Exercise the minimum supported phone width with doubled system text.
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      // Seed one editable row so list and fixed actions can be measured together.
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final QuoteRepository repository = QuoteRepository(database);
      await repository.save(const QuoteDraft(content: '窄屏名言', source: '测试作者'));
      await _pumpDialog(
        tester,
        database: database,
        gateway: _FakeQuoteJsonFileGateway(),
        platform: TargetPlatform.android,
        brightness: brightness,
      );

      expect(
        find.byKey(const ValueKey<String>('quote-library-fullscreen')),
        findsOneWidget,
      );
      expect(find.text('完成'), findsNothing);
      // Compact Android renders the list directly on the former card surface.
      final Finder library = find.byKey(
        const ValueKey<String>('quote-library-fullscreen'),
      );
      final Material librarySurface = tester.widget<Material>(library);
      expect(
        librarySurface.color,
        OmniColors.of(tester.element(library)).paper,
      );
      expect(
        find.descendant(of: library, matching: find.byType(OmniPanel)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('quote-library-list')),
          matching: find.byIcon(Icons.format_quote_rounded),
        ),
        findsNothing,
      );
      final Rect listBounds = tester.getRect(
        find.byKey(const ValueKey<String>('quote-library-list')),
      );
      expect(listBounds.left, 0);
      expect(listBounds.right, 320);
      // The three actions remain equal, at least 48dp tall, and below the list.
      final List<Rect> actionBounds =
          <String>[
                'quote-background-action',
                'quote-transfer-menu',
                'quote-add-action',
              ]
              .map(
                (String key) =>
                    tester.getRect(find.byKey(ValueKey<String>(key))),
              )
              .toList();
      for (final Rect bounds in actionBounds) {
        expect(bounds.height, greaterThanOrEqualTo(48));
        expect(bounds.top, closeTo(actionBounds.first.top, 0.1));
        expect(bounds.width, closeTo(actionBounds.first.width, 0.1));
      }
      expect(
        tester
            .getRect(find.byKey(const ValueKey<String>('quote-library-list')))
            .bottom,
        lessThanOrEqualTo(actionBounds.first.top),
      );
      for (final String label in <String>['更换背景', '导入导出 JSON', '新增名言']) {
        expect(find.text(label).hitTestable(), findsOneWidget);
      }

      // The JSON menu is fully above its fixed trigger with a visible gap.
      await tester.tap(
        find.byKey(const ValueKey<String>('quote-transfer-menu')),
      );
      await tester.pumpAndSettle();
      for (final String key in <String>[
        'quote-import-json-action',
        'quote-export-json-action',
      ]) {
        final Rect menuItem = tester.getRect(find.byKey(ValueKey<String>(key)));
        expect(menuItem.bottom, lessThan(actionBounds[1].top));
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // Background management opens above the library and returns to it.
      await tester.tap(
        find.byKey(const ValueKey<String>('quote-background-action')),
      );
      await tester.pumpAndSettle();
      expect(find.text('背景图片'), findsOneWidget);
      expect(find.text('首页横幅背景'), findsNothing);
      expect(find.byType(OmniExpandableBottomSheetScaffold), findsOneWidget);
      final Rect sheetBounds = tester.getRect(
        find.byKey(const ValueKey<String>('omni-expandable-sheet-surface')),
      );
      expect(sheetBounds.top, greaterThanOrEqualTo(640 * 0.45));
      expect(sheetBounds.height, lessThanOrEqualTo(640 * 0.55));
      final Rect cancelBounds = tester.getRect(
        find.widgetWithText(OmniButton, '取消'),
      );
      final Rect primaryBounds = tester.getRect(
        find.byKey(const ValueKey<String>('attachment-picker-primary')),
      );
      final Rect titleBounds = tester.getRect(find.text('背景图片'));
      expect(cancelBounds.center.dy, closeTo(primaryBounds.center.dy, 0.1));
      expect(titleBounds.center.dy, closeTo(cancelBounds.center.dy, 0.1));
      expect(titleBounds.center.dx, closeTo(160, 0.1));
      expect(cancelBounds.left, lessThan(primaryBounds.left));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('quote-library-fullscreen')),
        findsOneWidget,
      );

      // The existing full-screen editor is the next back-stack layer.
      await tester.tap(find.byKey(const ValueKey<String>('quote-add-action')));
      await tester.pumpAndSettle();
      final Finder editor = find.byKey(
        const ValueKey<String>('quote-editor-fullscreen'),
      );
      expect(editor, findsOneWidget);
      expect(find.byType(OmniFullscreenFormScaffold), findsOneWidget);
      expect(find.byType(OmniTextField), findsWidgets);
      final Rect editorTitleBounds = tester.getRect(
        find.descendant(of: editor, matching: find.text('新增名言')),
      );
      final Rect editorCancelBounds = tester.getRect(
        find.descendant(
          of: editor,
          matching: find.widgetWithText(OmniButton, '取消'),
        ),
      );
      final Rect editorSaveBounds = tester.getRect(
        find.byKey(const ValueKey<String>('quote-editor-save')),
      );
      expect(editorTitleBounds.center.dx, closeTo(160, 0.1));
      expect(editorTitleBounds.top, lessThan(editorCancelBounds.top));
      expect(editorCancelBounds.left, lessThan(editorSaveBounds.left));
      expect(
        editorCancelBounds.center.dy,
        closeTo(editorSaveBounds.center.dy, 0.1),
      );
      await tester.tap(
        find.descendant(
          of: editor,
          matching: find.widgetWithText(OmniButton, '取消'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('quote-library-fullscreen')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _disposeDialog(tester, database);
    });
  }

  testWidgets('导出入口将固定 JSON 格式交给文件网关', (WidgetTester tester) async {
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 当前名言库仓储。
    final QuoteRepository repository = QuoteRepository(database);
    await repository.save(const QuoteDraft(content: '导出名言', source: '作者'));
    // 记录导出内容的测试网关。
    final _FakeQuoteJsonFileGateway gateway = _FakeQuoteJsonFileGateway(
      outputUri: Uri.file('quotes.json'),
    );

    await _pumpDialog(tester, database: database, gateway: gateway);
    await tester.tap(find.byTooltip('导入或导出'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('quote-export-json-action')),
    );
    await tester.pumpAndSettle();

    expect(gateway.savedFileName, matches(r'^omni-butler-quotes-\d{8}\.json$'));
    expect(gateway.savedBytes, isNotNull);
    // 网关收到的导出 JSON。
    final Object? exported = jsonDecode(utf8.decode(gateway.savedBytes!));
    expect(exported, <Map<String, String>>[
      <String, String>{'content': '导出名言', 'author': '作者'},
    ]);
    await tester.pump(const Duration(seconds: 5));
    await _disposeDialog(tester, database);
  });
}

/// 使用真实主题和数据库提供者展示名言库弹窗。
Future<void> _pumpDialog(
  WidgetTester tester, {
  required AppDatabase database,
  required QuoteJsonFileGateway gateway,
  QuoteRepository? repository,
  TargetPlatform platform = TargetPlatform.windows,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        if (repository != null)
          quoteRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: brightness)
            .copyWith(platform: platform),
        home: Scaffold(body: QuoteLibraryDialog(fileGateway: gateway)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 先卸载数据流监听，再关闭测试数据库。
Future<void> _disposeDialog(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pump(Duration.zero);
  await database.close();
}
