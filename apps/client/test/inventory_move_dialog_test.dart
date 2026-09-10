import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_move_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证物品搬家工作台的选择、预览和响应式迁移流程。
void main() {
  testWidgets('桌面端从位置树选择主物品并连同继承位置配件迁移', (WidgetTester tester) async {
    // 固定桌面测试视口。
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 测试 taxonomy 仓储。
    final TaxonomyRepository taxonomyRepository = TaxonomyRepository(database);
    // 书房位置。
    final TaxonomyEntry study = await _createLocation(
      database,
      taxonomyRepository,
      '书房',
      0,
    );
    // 储物间位置。
    final TaxonomyEntry storage = await _createLocation(
      database,
      taxonomyRepository,
      '储物间',
      1,
    );
    // 测试物品仓储。
    final InventoryRepository repository = InventoryRepository(database);
    // 测试主物品标识。
    final String cameraId = await repository.save(
      InventoryDraft(
        name: '相机',
        quantity: 1,
        location: study.name,
        locationIds: <String>{study.id},
      ),
    );
    // 随主物品存放的配件标识。
    final String strapId = await repository.save(
      InventoryDraft(name: '相机肩带', quantity: 1, parentItemId: cameraId),
    );
    // 独立位于储物间的测试物品。
    await repository.save(
      InventoryDraft(
        name: '电钻',
        quantity: 2,
        location: storage.name,
        locationIds: <String>{storage.id},
      ),
    );
    // 测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();
    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();

    // 物品页工具栏提供一键搬家入口。
    final Finder moveButton = find.byKey(
      const ValueKey<String>('inventory-move-button'),
    );
    expect(moveButton, findsOneWidget);
    await tester.tap(moveButton);
    await tester.pumpAndSettle();

    // 桌面端同时展示来源树、搬运方向和迁移目标区域。
    expect(
      find.byKey(const ValueKey<String>('inventory-move-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-source-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-target-panel')),
      findsOneWidget,
    );
    expect(find.text('书房'), findsWidgets);
    expect(find.text('储物间'), findsWidgets);
    // 固化桌面双栏搬家工作台的视觉基线。
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/inventory_move_light_1440x900.png'),
    );

    // 搜索配套物品时保留其同组主物品上下文。
    await tester.enterText(
      find.byKey(const ValueKey<String>('inventory-move-search')),
      '相机肩带',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('inventory-move-item-$cameraId')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('inventory-move-item-$strapId')),
      findsOneWidget,
    );
    // 清空搜索恢复完整位置树。
    await tester.enterText(
      find.byKey(const ValueKey<String>('inventory-move-search')),
      '',
    );
    await tester.pumpAndSettle();

    // 选择主物品后，继承位置配件自动出现在右侧且不能单独移除。
    await tester.tap(
      find.byKey(ValueKey<String>('inventory-move-item-$cameraId')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('inventory-move-selected-$cameraId')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('inventory-move-selected-$strapId')),
      findsOneWidget,
    );
    expect(find.textContaining('随主物品自动迁移'), findsWidgets);
    expect(find.text('已选 2 条记录，共 2 件'), findsOneWidget);

    // 选择目标位置并执行迁移。
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-move-destination')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('储物间').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-move-submit')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('已将 2 项迁移到“储物间”'), findsOneWidget);

    // 主物品写入新位置，继承位置配件继续保持空位置。
    final InventoryRecord movedCamera = await (database.select(
      database.inventoryItems,
    )..where((InventoryItems table) => table.id.equals(cameraId))).getSingle();
    // 迁移后的继承位置配件。
    final InventoryRecord movedStrap = await (database.select(
      database.inventoryItems,
    )..where((InventoryItems table) => table.id.equals(strapId))).getSingle();
    expect(movedCamera.location, storage.name);
    expect(movedStrap.location, isNull);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('移动端使用选择和确认两步流程迁移物品', (WidgetTester tester) async {
    // 固定移动端测试视口。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 测试 taxonomy 仓储。
    final TaxonomyRepository taxonomyRepository = TaxonomyRepository(database);
    // 客厅位置。
    final TaxonomyEntry livingRoom = await _createLocation(
      database,
      taxonomyRepository,
      '客厅',
      0,
    );
    // 卧室位置。
    final TaxonomyEntry bedroom = await _createLocation(
      database,
      taxonomyRepository,
      '卧室',
      1,
    );
    // 测试物品仓储。
    final InventoryRepository repository = InventoryRepository(database);
    // 测试物品标识。
    final String speakerId = await repository.save(
      InventoryDraft(
        name: '蓝牙音箱',
        quantity: 1,
        location: livingRoom.name,
        locationIds: <String>{livingRoom.id},
      ),
    );
    // 测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();
    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-move-button')),
    );
    await tester.pumpAndSettle();

    // 第一步只显示物品选择区域。
    expect(find.text('1/2 · 选择物品'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-move-source-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-target-panel')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(ValueKey<String>('inventory-move-item-$speakerId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 第二步显示目标位置和迁移预览。
    expect(find.text('2/2 · 确认迁移'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-move-source-panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-target-panel')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-move-destination')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('卧室').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-move-submit')),
    );
    await tester.pumpAndSettle();

    // 移动端迁移结果正确且没有布局异常。
    final InventoryRecord movedSpeaker = await (database.select(
      database.inventoryItems,
    )..where((InventoryItems table) => table.id.equals(speakerId))).getSingle();
    expect(movedSpeaker.location, bedroom.name);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows 窄窗口仍保持双栏且没有横向溢出', (WidgetTester tester) async {
    // 固定 Windows 窄窗口测试视口。
    tester.view.physicalSize = const Size(700, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: const Scaffold(body: InventoryMoveDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 桌面窄窗口不会降级成移动端分步流程。
    expect(
      find.byKey(const ValueKey<String>('inventory-move-source-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-move-target-panel')),
      findsOneWidget,
    );
    expect(find.textContaining('/2 ·'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}

/// 创建并返回指定名称的测试位置。
Future<TaxonomyEntry> _createLocation(
  AppDatabase database,
  TaxonomyRepository repository,
  String name,
  int sortOrder,
) async {
  await repository.save(
    TaxonomyDraft(
      module: TaxonomyModule.inventory,
      kind: TaxonomyKind.location,
      name: name,
      colorValue: 0xFF1EA7A1,
      sortOrder: sortOrder,
    ),
  );
  return (database.select(database.taxonomyEntries)..where(
        (TaxonomyEntries table) =>
            table.module.equals(TaxonomyModule.inventory.name) &
            table.kind.equals(TaxonomyKind.location.name) &
            table.name.equals(name) &
            table.deletedAt.isNull(),
      ))
      .getSingle();
}
