import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';

/// 验证分类标签管理器只保留直接维护清单所需操作。
void main() {
  /// 每个测试使用的内存数据库。
  late AppDatabase database;

  /// 每个测试使用的分类标签仓储。
  late TaxonomyRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TaxonomyRepository(database);
  });

  testWidgets('管理器移除启停和完成按钮并支持内联新增重命名', (WidgetTester tester) async {
    await _pumpManager(tester, database);

    expect(find.text('物品标签'), findsOneWidget);
    expect(find.text('新增标签'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.textContaining('可用于新记录'), findsNothing);
    expect(find.text('完成'), findsNothing);

    await tester.tap(find.text('新增标签'));
    await _pumpUi(tester);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '工作');
    await tester.tap(find.text('添加'));
    await _pumpUi(tester);
    expect(find.text('工作'), findsOneWidget);

    await tester.tap(find.text('工作'));
    await _pumpUi(tester);
    await tester.enterText(find.byType(TextField), '专注');
    await tester.tap(find.text('保存'));
    await _pumpUi(tester);

    // 重命名后的物品标签。
    final List<TaxonomyEntry> renamed =
        await (database.select(database.taxonomyEntries)..where(
              (TaxonomyEntries table) =>
                  table.module.equals(TaxonomyModule.inventory.name) &
                  table.kind.equals(TaxonomyKind.tag.name) &
                  table.deletedAt.isNull(),
            ))
            .get();
    expect(renamed.single.name, '专注');

    await tester.tap(find.bySemanticsLabel('修改颜色'));
    await _pumpUi(tester);
    expect(find.byTooltip('青色'), findsOneWidget);
    await tester.tap(find.byTooltip('青色'));
    await _pumpUi(tester);
    // 改色后的物品标签。
    final TaxonomyEntry recolored =
        await (database.select(database.taxonomyEntries)..where(
              (TaxonomyEntries table) => table.id.equals(renamed.single.id),
            ))
            .getSingle();
    expect(recolored.colorValue, const Color(0xFF1EA7A1).toARGB32());
    await _disposeHarness(tester);
    await database.close();
  });

  testWidgets('删除仅显示结果说明并支持十秒撤销', (WidgetTester tester) async {
    await repository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.tag,
        name: '外设',
        colorValue: 0xFF3370FF,
      ),
    );
    await _pumpManager(tester, database);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await _pumpUi(tester);
    await tester.tap(find.text('删除标签'));
    await _pumpUi(tester);

    expect(find.text('删除“外设”？'), findsOneWidget);
    expect(find.textContaining('已有记录中的标签名称会继续保留'), findsOneWidget);
    expect(find.textContaining('已用于'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _pumpUi(tester);
    expect(find.text('已删除“外设”'), findsOneWidget);
    expect(
      await (database.select(database.taxonomyEntries)..where(
            (TaxonomyEntries table) =>
                table.module.equals(TaxonomyModule.inventory.name) &
                table.kind.equals(TaxonomyKind.tag.name) &
                table.deletedAt.isNull(),
          ))
          .get(),
      isEmpty,
    );

    await tester.tap(find.text('撤销'));
    await _pumpUi(tester);
    expect(
      await (database.select(database.taxonomyEntries)..where(
            (TaxonomyEntries table) =>
                table.module.equals(TaxonomyModule.inventory.name) &
                table.kind.equals(TaxonomyKind.tag.name) &
                table.deletedAt.isNull(),
          ))
          .get(),
      hasLength(1),
    );
    await _disposeHarness(tester);
    await database.close();
  });

  testWidgets('Android 紧凑窗口使用全屏管理器', (WidgetTester tester) async {
    await _pumpManager(
      tester,
      database,
      platform: TargetPlatform.android,
      size: const Size(390, 844),
    );

    // 移动端全屏弹窗尺寸。
    final Size dialogSize = tester.getSize(find.byType(Dialog));
    expect(dialogSize, const Size(390, 844));
    expect(find.text('物品标签'), findsOneWidget);
    expect(find.text('新增标签'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeHarness(tester);
    await database.close();
  });

  testWidgets('拖拽回调按界面顺序一次性保存', (WidgetTester tester) async {
    await repository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.tag,
        name: '第一项',
        colorValue: 0xFF3370FF,
        sortOrder: 0,
      ),
    );
    await repository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.tag,
        name: '第二项',
        colorValue: 0xFF1EA7A1,
        sortOrder: 1,
      ),
    );
    await _pumpManager(tester, database);

    // 当前可拖拽列表。
    final ReorderableListView list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorderItem!(0, 1);
    await tester.pump();

    // 本地界面在数据库完成保存前已经采用的新顺序。
    final double secondItemTop = tester.getTopLeft(find.text('第二项')).dy;
    // 被移动到第二行的第一项顶部位置。
    final double firstItemTop = tester.getTopLeft(find.text('第一项')).dy;
    expect(secondItemTop, lessThan(firstItemTop));

    // 拖拽代理不会把整行语义树复制进 Windows 辅助功能树。
    final Widget proxy = list.proxyDecorator!(
      const SizedBox(),
      0,
      const AlwaysStoppedAnimation<double>(1),
    );
    expect(proxy, isA<ExcludeSemantics>());
    await _pumpUi(tester);

    // 保存后的物品标签顺序。
    final List<TaxonomyEntry> reordered =
        await (database.select(database.taxonomyEntries)
              ..where(
                (TaxonomyEntries table) =>
                    table.module.equals(TaxonomyModule.inventory.name) &
                    table.kind.equals(TaxonomyKind.tag.name) &
                    table.deletedAt.isNull(),
              )
              ..orderBy(<OrderingTerm Function(TaxonomyEntries)>[
                (TaxonomyEntries table) => OrderingTerm.asc(table.sortOrder),
              ]))
            .get();
    expect(reordered.map((TaxonomyEntry entry) => entry.name), <String>[
      '第二项',
      '第一项',
    ]);
    await _disposeHarness(tester);
    await database.close();
  });

  testWidgets('时间分类管理器保持紧凑视觉层级', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light)
              .copyWith(platform: TargetPlatform.windows),
          home: const TaxonomyManagerDialog(
            module: TaxonomyModule.timeline,
            kind: TaxonomyKind.category,
          ),
        ),
      ),
    );
    await _pumpUi(tester);

    await expectLater(
      find.byType(Dialog),
      matchesGoldenFile('goldens/taxonomy_manager_light_500x560.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
  });

  testWidgets('重命名输入框与标签行保持清晰间距', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light)
              .copyWith(platform: TargetPlatform.windows),
          home: const TaxonomyManagerDialog(
            module: TaxonomyModule.timeline,
            kind: TaxonomyKind.category,
          ),
        ),
      ),
    );
    await _pumpUi(tester);
    await tester.tap(find.text('工作'));
    await _pumpUi(tester);

    await expectLater(
      find.byType(Dialog),
      matchesGoldenFile('goldens/taxonomy_manager_edit_light_500x560.png'),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
  });
}

/// 打开测试用物品标签管理器。
Future<void> _pumpManager(
  WidgetTester tester,
  AppDatabase database, {
  TargetPlatform platform = TargetPlatform.windows,
  Size size = const Size(800, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(database)],
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: platform),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                onPressed: () => TaxonomyManagerDialog.show(
                  context,
                  module: TaxonomyModule.inventory,
                  kind: TaxonomyKind.tag,
                ),
                child: const Text('打开标签设置'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开标签设置'));
  await _pumpUi(tester);
}

/// 推进异步数据库通知和短时界面动画，避免持续进度动画阻塞测试。
Future<void> _pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// 卸载测试界面并等待 Riverpod 释放数据库流订阅。
Future<void> _disposeHarness(WidgetTester tester) async {
  await tester.tap(find.byTooltip('关闭'));
  await _pumpUi(tester);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}
