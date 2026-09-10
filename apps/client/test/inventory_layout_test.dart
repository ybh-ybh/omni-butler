import 'package:drift/native.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证物品管理页顶部统计内容和价值图例布局。
void main() {
  testWidgets('展示三状态统计和右置分类价值明细', (WidgetTester tester) async {
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
    // 测试用物品仓储。
    final InventoryRepository repository = InventoryRepository(database);
    final String cameraId = await repository.save(
      InventoryDraft(
        name: '相机',
        category: '数码',
        location: '书房',
        purchasePriceCents: 10000,
        purchaseDate: DateTime(2026, 8, 1),
        purchasePlatform: '线下门店',
        warrantyExpiration: DateTime(2027, 8, 1),
        tags: <String>['摄影'],
        notes: '周末拍摄使用',
        status: InventoryStatus.inUse,
        quantity: 1,
      ),
    );
    // 配套物品应计入数量徽标与购入价值统计。
    await repository.save(
      InventoryDraft(
        name: '相机肩带',
        parentItemId: cameraId,
        category: '数码',
        location: '书房',
        purchasePriceCents: 5000,
        quantity: 1,
      ),
    );
    await repository.save(
      const InventoryDraft(
        name: '键盘',
        category: '数码',
        location: '书房',
        purchasePriceCents: 2000,
        status: InventoryStatus.idle,
        quantity: 1,
      ),
    );
    // 管理器中的分类顺序故意与名称顺序相反，并包含未使用的旧分类。
    final TaxonomyRepository taxonomyRepository = TaxonomyRepository(database);
    for (final (String name, int order) in <(String, int)>[
      ('工具', 0),
      ('数码', 1),
      ('家具', 2),
      ('书籍', 3),
      ('办公用品', 4),
      ('电子设备', 5),
    ]) {
      await taxonomyRepository.save(
        TaxonomyDraft(
          module: TaxonomyModule.inventory,
          kind: TaxonomyKind.category,
          name: name,
          colorValue: 0xFF1EA7A1,
          sortOrder: order,
        ),
      );
    }
    // 位置管理器同样使用显式顺序。
    for (final (String name, int order) in <(String, int)>[
      ('储物间', 0),
      ('书房', 1),
    ]) {
      await taxonomyRepository.save(
        TaxonomyDraft(
          module: TaxonomyModule.inventory,
          kind: TaxonomyKind.location,
          name: name,
          colorValue: 0xFF1EA7A1,
          sortOrder: order,
        ),
      );
    }
    await repository.save(
      const InventoryDraft(
        name: '电钻',
        category: '工具',
        location: '储物间',
        purchasePriceCents: 3000,
        status: InventoryStatus.lent,
        quantity: 1,
      ),
    );
    // 已售出记录不计入当前三状态统计。
    await repository.save(
      const InventoryDraft(
        name: '旧手机',
        category: '数码',
        location: '抽屉',
        purchasePriceCents: 9000,
        status: InventoryStatus.sold,
        quantity: 1,
      ),
    );
    // 显式管理的测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();
    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();

    expect(find.text('总物品数'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-total-count')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-accessory-count')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('inventory-accessory-count-$cameraId')),
      findsOneWidget,
    );
    expect(find.text('配套物品数'), findsOneWidget);
    expect(find.text('1 条'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-accessory-summary')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-status-metric-在用')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-status-metric-闲置')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-status-metric-已借出')),
      findsOneWidget,
    );
    expect(find.text('已售出'), findsOneWidget);
    expect(find.text('购入总值'), findsOneWidget);
    expect(find.text('¥0.2k'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-category-legend-数码')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-category-legend-工具')),
      findsOneWidget,
    );
    expect(find.text('¥ 170.00'), findsOneWidget);
    expect(find.text('¥ 30.00'), findsOneWidget);

    // 标签和位置筛选默认收起，搜索框左侧提供独立筛选按钮。
    final Finder filterToggle = find.byKey(
      const ValueKey<String>('inventory-filter-toggle'),
    );
    final Finder searchField = find.byKey(
      const ValueKey<String>('inventory-search-field'),
    );
    expect(filterToggle, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-tag-filters')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-location-filters')),
      findsNothing,
    );
    expect(
      tester.getRect(filterToggle).right,
      lessThan(tester.getRect(searchField).left),
    );

    // 主物品项不显示备注，有配套物品时在更多按钮左侧显示快捷入口。
    final Finder accessoryButton = find.byKey(
      ValueKey<String>('inventory-accessories-button-$cameraId'),
    );
    final Finder moreButton = find.byKey(
      ValueKey<String>('inventory-more-button-$cameraId'),
    );
    expect(find.text('周末拍摄使用'), findsNothing);
    expect(accessoryButton, findsOneWidget);
    expect(
      find.descendant(of: accessoryButton, matching: find.byType(Badge)),
      findsNothing,
    );
    expect(
      tester.getRect(accessoryButton).right,
      lessThanOrEqualTo(tester.getRect(moreButton).left),
    );

    // 点击物品项打开详情卡，并在过渡中产生卡牌翻转矩阵。
    await tester.tap(find.byKey(ValueKey<String>('inventory-card-$cameraId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final Transform flipTransform = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('inventory-detail-flip')),
    );
    expect(flipTransform.transform.storage[0], greaterThan(0));
    expect(flipTransform.transform.storage[0], lessThan(1));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('inventory-detail-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-detail-notes')),
      findsOneWidget,
    );
    expect(find.text('周末拍摄使用'), findsOneWidget);
    expect(find.text('标签'), findsNothing);
    expect(find.text('摄影'), findsNothing);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('周末拍摄使用'),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );
    final Finder itemName = find.widgetWithText(SelectableText, '相机');
    expect(itemName, findsOneWidget);
    // 短物品名只占一行，不再预留约 25px 的第二行空白。
    final SelectableText itemNameText = tester.widget<SelectableText>(itemName);
    expect(itemNameText.minLines, 1);
    expect(itemNameText.maxLines, 2);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('inventory-detail-header')),
          )
          .height,
      lessThanOrEqualTo(62),
    );
    // 详情值字号保持易读，物品名与图片之间不留大块空白。
    final Text notesText = tester.widget<Text>(find.text('周末拍摄使用'));
    expect(notesText.style?.fontSize, 16);
    expect(
      tester
              .getRect(
                find.byKey(const ValueKey<String>('inventory-detail-image')),
              )
              .top -
          tester.getRect(itemName).bottom,
      lessThanOrEqualTo(40),
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-detail-flip')),
      findsNothing,
    );
    expect(find.text('品牌'), findsNothing);
    expect(find.text('型号'), findsNothing);
    expect(find.text('创建时间'), findsNothing);
    expect(find.text('更新时间'), findsNothing);
    expect(find.text('购买链接'), findsNothing);
    expect(find.text('保修到期'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-detail-edit-button')),
      findsOneWidget,
    );
    // 底部关闭与编辑操作使用更高的大尺寸按钮。
    final Finder closeButton = find.byKey(
      const ValueKey<String>('inventory-detail-close-button'),
    );
    final Finder editButton = find.byKey(
      const ValueKey<String>('inventory-detail-edit-button'),
    );
    expect(tester.getSize(closeButton).height, greaterThanOrEqualTo(40));
    expect(tester.getSize(editButton).height, greaterThanOrEqualTo(40));
    // 固化完整物品详情卡的桌面视觉基线。
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/inventory_detail_light_1440x900.png'),
    );
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();

    // 配套物品快捷按钮无需打开更多菜单即可进入管理弹窗。
    await tester.tap(accessoryButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('inventory-accessory-summary')),
      findsOneWidget,
    );
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 固化物品页默认收起筛选后的桌面视觉基线。
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/inventory_light_1440x900.png'),
    );

    // 布局选择器默认六列，并提供四、五、六列选项。
    final Finder layoutSelector = find.byKey(
      const ValueKey<String>('inventory-layout-selector'),
    );
    expect(layoutSelector, findsOneWidget);
    expect(find.text('6列'), findsOneWidget);
    await tester.tap(layoutSelector);
    await tester.pumpAndSettle();
    expect(find.text('4列'), findsOneWidget);
    expect(find.text('5列'), findsOneWidget);
    await tester.tap(find.text('5列').last);
    await tester.pumpAndSettle();
    expect(find.text('5列'), findsOneWidget);
    expect(preferences.getInt('inventory.layout_columns'), 5);

    // 点击筛选按钮后以展开动画显示标签和位置筛选。
    await tester.tap(filterToggle);
    await tester.pump();
    expect(find.byType(SizeTransition), findsWidgets);
    await tester.pumpAndSettle();

    // 标签和位置筛选保持独立，并能过滤现有分类与文本位置数据。
    expect(
      find.byKey(const ValueKey<String>('inventory-tag-filters')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-location-filters')),
      findsOneWidget,
    );
    expect(find.text('全部标签 4'), findsOneWidget);
    expect(find.text('工具 1'), findsOneWidget);
    expect(find.text('数码 3'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-tag-办公用品')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-tag-电子设备')),
      findsNothing,
    );
    expect(
      tester
          .getRect(find.byKey(const ValueKey<String>('inventory-tag-工具')))
          .left,
      lessThan(
        tester
            .getRect(find.byKey(const ValueKey<String>('inventory-tag-数码')))
            .left,
      ),
    );
    expect(
      tester
          .getRect(find.byKey(const ValueKey<String>('inventory-location-储物间')))
          .left,
      lessThan(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('inventory-location-书房')),
            )
            .left,
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-location-储物间')),
      findsOneWidget,
    );
    expect(find.text('储物间 1'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('inventory-tag-工具')));
    await tester.pumpAndSettle();
    expect(find.text('电钻'), findsOneWidget);
    expect(find.text('相机'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('inventory-tag-all')));
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-location-书房')),
    );
    await tester.pumpAndSettle();
    expect(find.text('相机'), findsOneWidget);
    expect(find.text('键盘'), findsOneWidget);
    expect(find.text('电钻'), findsNothing);

    // 再次点击筛选按钮后以收起动画隐藏筛选行，并保留当前筛选条件。
    await tester.tap(filterToggle);
    await tester.pump();
    expect(find.byType(SizeTransition), findsWidgets);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('inventory-tag-filters')),
      findsNothing,
    );
    expect(find.text('相机'), findsOneWidget);
    expect(find.text('键盘'), findsOneWidget);

    // 桌面宽屏下三个工具控件使用统一高度。
    final double categoryButtonHeight = tester
        .getRect(
          find.byKey(const ValueKey<String>('inventory-manage-category')),
        )
        .height;
    final double locationButtonHeight = tester
        .getRect(
          find.byKey(const ValueKey<String>('inventory-manage-location')),
        )
        .height;
    final double layoutSelectorHeight = tester.getRect(layoutSelector).height;
    expect(categoryButtonHeight, closeTo(layoutSelectorHeight, 0.1));
    expect(locationButtonHeight, closeTo(layoutSelectorHeight, 0.1));

    // 桌面宽屏下操作按钮与搜索框保持同一行并靠右排列。
    final Rect searchRect = tester.getRect(
      find.byKey(const ValueKey<String>('inventory-search-field')),
    );
    final Rect categoryActionRect = tester.getRect(find.text('管理分类'));
    expect(categoryActionRect.left, greaterThan(searchRect.right));
    expect(
      (categoryActionRect.center.dy - searchRect.center.dy).abs(),
      lessThanOrEqualTo(6),
    );

    // 分类明细位于环形图右侧。
    final Finder donut = find.byKey(
      const ValueKey<String>('inventory-value-donut'),
    );
    final Finder valuePanel = find.byKey(
      const ValueKey<String>('inventory-value-statistics'),
    );
    final Finder categoryLegend = find.byKey(
      const ValueKey<String>('inventory-category-legend-数码'),
    );
    expect(
      tester.getRect(categoryLegend).left,
      greaterThan(tester.getRect(donut).right),
    );
    expect(tester.getRect(valuePanel).height, lessThan(160));

    // 物品页点击管理分类后应稳定打开管理器。
    await tester.tap(find.text('管理分类'));
    await tester.pumpAndSettle();
    expect(find.text('物品分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('移动端物品项与详情卡保持完整布局', (WidgetTester tester) async {
    // 固定 Android 移动测试视口。
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
    // 测试用物品仓储。
    final InventoryRepository repository = InventoryRepository(database);
    // 用于验证跨年使用时长的当前日期。
    final DateTime today = DateTime.now();
    // 固定为当前日期之前两年两个月的月初。
    final DateTime longAgoPurchaseDate = DateTime(today.year, today.month - 26);
    // 带完整详情数据的主物品标识。
    final String itemId = await repository.save(
      InventoryDraft(
        name: '移动摄影套装',
        category: '数码',
        quantity: 1,
        purchasePriceCents: 176900,
        purchaseDate: longAgoPurchaseDate,
        purchasePlatform: '线下门店',
        location: '书房',
        tags: const <String>['摄影'],
        notes: '移动端详情备注',
      ),
    );
    await repository.save(
      InventoryDraft(name: '相机肩带', parentItemId: itemId, quantity: 1),
    );
    // 显式管理的测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();
    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();

    // 移动端默认收起筛选，并完整显示配套物品快捷入口。
    expect(
      find.byKey(const ValueKey<String>('inventory-tag-filters')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey<String>('inventory-accessories-button-$itemId')),
      findsOneWidget,
    );
    expect(find.text('¥ 1,769'), findsOneWidget);
    expect(find.text('已使用 2 年 2 月'), findsOneWidget);
    expect(
      find.byKey(ValueKey<String>('inventory-meta-divider-$itemId')),
      findsOneWidget,
    );
    // 位置、数量与配套文字均从 14px 缩小到 12px。
    final Text locationText = tester.widget<Text>(
      find.byKey(ValueKey<String>('inventory-location-$itemId')),
    );
    final Text quantityText = tester.widget<Text>(
      find.byKey(ValueKey<String>('inventory-quantity-$itemId')),
    );
    final Text accessoryText = tester.widget<Text>(
      find.byKey(ValueKey<String>('inventory-accessory-count-$itemId')),
    );
    expect(locationText.style?.fontSize, 12);
    expect(quantityText.style?.fontSize, 12);
    expect(accessoryText.style?.fontSize, 12);
    expect(accessoryText.style?.color, quantityText.style?.color);
    // 已使用文字从 12px 缩小到 10px。
    final Text usageText = tester.widget<Text>(
      find.byKey(ValueKey<String>('inventory-usage-$itemId')),
    );
    expect(usageText.style?.fontSize, 10);
    // 物品名与状态行的垂直间距收紧到 4px。
    final Finder statusRow = find.byKey(
      ValueKey<String>('inventory-status-row-$itemId'),
    );
    final Finder itemName = find.byKey(
      ValueKey<String>('inventory-name-$itemId'),
    );
    expect(
      tester.getRect(itemName).top - tester.getRect(statusRow).bottom,
      lessThanOrEqualTo(4),
    );
    expect(tester.takeException(), isNull);

    // 从移动端物品项打开详情卡，卡片边界保持在视口内。
    await tester.tap(find.byKey(ValueKey<String>('inventory-card-$itemId')));
    await tester.pumpAndSettle();
    final Rect detailRect = tester.getRect(
      find.byKey(const ValueKey<String>('inventory-detail-card')),
    );
    expect(detailRect.left, greaterThanOrEqualTo(0));
    expect(detailRect.right, lessThanOrEqualTo(390));
    expect(find.text('移动端详情备注'), findsOneWidget);
    expect(find.text('保修到期'), findsNothing);
    expect(find.text('购买链接'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('物品分类重命名后筛选使用关联 ID 的新名称', (WidgetTester tester) async {
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
    // 测试用分类仓储。
    final TaxonomyRepository taxonomyRepository = TaxonomyRepository(database);
    await taxonomyRepository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.category,
        name: '书籍',
        colorValue: 0xFF1EA7A1,
      ),
    );
    // 重命名前的分类条目。
    final TaxonomyEntry category =
        (await (database.select(database.taxonomyEntries)..where(
                  (TaxonomyEntries table) =>
                      table.module.equals(TaxonomyModule.inventory.name) &
                      table.kind.equals(TaxonomyKind.category.name) &
                      table.deletedAt.isNull(),
                ))
                .get())
            .single;
    // 测试用物品仓储。
    final InventoryRepository inventoryRepository = InventoryRepository(
      database,
    );
    // 测试物品标识。
    final String itemId = await inventoryRepository.save(
      InventoryDraft(
        name: '读书笔记本',
        category: '书籍',
        categoryIds: <String>{category.id},
        quantity: 1,
      ),
    );
    // 只重命名 taxonomy，不改动物品表中的旧文本，模拟真实操作。
    await taxonomyRepository.save(
      TaxonomyDraft(
        id: category.id,
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.category,
        name: '书籍1',
        colorValue: category.colorValue,
        sortOrder: category.sortOrder,
      ),
    );
    // 重命名同步更新物品表中的冗余分类文本。
    final InventoryRecord renamedItem = await (database.select(
      database.inventoryItems,
    )..where((InventoryItems table) => table.id.equals(itemId))).getSingle();
    expect(renamedItem.category, '书籍1');
    // 显式管理的测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    container.read(appRouterProvider).go('/inventory');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 默认收起的筛选区需先通过搜索栏左侧按钮展开。
    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-filter-toggle')),
    );
    await tester.pumpAndSettle();

    // 重命名后的筛选项使用同一个关联 ID 对应的新名称。
    expect(
      find.byKey(const ValueKey<String>('inventory-tag-书籍1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-tag-书籍')),
      findsNothing,
    );
    expect(find.text('书籍1 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
