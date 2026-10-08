import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/inventory/presentation/inventory_page.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// 验证手机物品页的数据口径、筛选事务和大字号自然布局。
void main() {
  testWidgets('物品平铺行和完整统计保留配套金额且不乘数量', (WidgetTester tester) async {
    // 含主物品和配套物品的独立测试场景。
    final _InventoryMobileFixture fixture = await _mountInventory(tester);
    // 第一条物品记录及其缩略图。
    final Finder record = find.byKey(
      ValueKey<String>('inventory-card-${fixture.cameraId}'),
    );
    final Finder image = find.byKey(
      ValueKey<String>('inventory-card-image-${fixture.cameraId}'),
    );
    expect(tester.getSize(image), const Size(96, 96));
    expect(tester.getSize(record).height, greaterThan(104));
    expect(
      find.byKey(const ValueKey<String>('inventory-card-grid')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-statistics-carousel')),
      findsNothing,
    );
    expect(find.text('配套 1'), findsOneWidget);
    expect(find.text('数量 3'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('management-summary-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.text('购入总值'), findsOneWidget);
    // 100 元主物品、50 元配套和 20 元闲置物品；主物品数量 3 不改变价格口径。
    expect(find.text('¥ 170.00'), findsOneWidget);
    expect(find.text('主物品 2 条'), findsOneWidget);
    expect(find.text('配套物品 1 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('筛选只在应用时生效并能单独移除和重置', (WidgetTester tester) async {
    // 初始化可区分位置与分类的两件主物品。
    final _InventoryMobileFixture fixture = await _mountInventory(tester);
    // 可应用筛选的底部面板入口。
    final Finder filter = find.byKey(
      const ValueKey<String>('management-filter-button'),
    );
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('inventory-location-filters')),
        matching: find.text('书房'),
      ),
    );
    // 系统返回取消草稿，不改变已应用条件。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('inventory-card-${fixture.keyboardId}')),
      findsOneWidget,
    );
    expect(find.text('位置：书房'), findsNothing);

    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('inventory-location-filters')),
        matching: find.text('书房'),
      ),
    );
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('inventory-card-${fixture.keyboardId}')),
      findsNothing,
    );
    expect(find.text('位置：书房'), findsOneWidget);
    await tester.tap(find.text('位置：书房'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('inventory-card-${fixture.keyboardId}')),
      findsOneWidget,
    );

    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('inventory-tag-filters')),
        matching: find.text('摄影'),
      ),
    );
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('标签：摄影'), findsOneWidget);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置'));
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('标签：摄影'), findsNothing);
    expect(
      find.byKey(ValueKey<String>('inventory-card-${fixture.keyboardId}')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('配套入口仅有配套时出现在右上角，长按仍可为其他物品管理配套', (WidgetTester tester) async {
    // 两件主物品分别有和没有配套。
    final _InventoryMobileFixture fixture = await _mountInventory(tester);
    // 有配套的主物品行尾入口。
    final Finder accessories = find.byKey(
      ValueKey<String>('inventory-accessories-button-${fixture.cameraId}'),
    );
    // 与名称同一行的触控区域。
    final Rect nameRect = tester.getRect(find.text('旅行摄影套装与备用镜头'));
    expect(tester.getRect(accessories).top, lessThan(nameRect.bottom));
    expect(tester.getSize(accessories).height, greaterThanOrEqualTo(48));
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(
      find.byKey(
        ValueKey<String>('inventory-accessories-button-${fixture.keyboardId}'),
      ),
      findsNothing,
    );
    await tester.tap(accessories);
    await tester.pumpAndSettle();
    expect(find.text('旅行摄影套装与备用镜头 · 配套物品'), findsOneWidget);
    expect(find.text('相机肩带'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-detail-card')),
      findsNothing,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.longPress(find.text('闲置键盘'));
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('配套物品'), findsOneWidget);
    expect(find.text('更换图片'), findsOneWidget);
    expect(find.text('移入回收站'), findsOneWidget);
    await tester.tap(find.text('配套物品'));
    await tester.pumpAndSettle();
    expect(find.text('闲置键盘 · 配套物品'), findsOneWidget);
    expect(find.text('还没有配套物品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('配套搜索回溯主物品且空结果可清空全部条件', (WidgetTester tester) async {
    // 搜索使用实际仓储而非模拟筛选。
    final _InventoryMobileFixture fixture = await _mountInventory(tester);
    await tester.enterText(find.byType(TextField), '肩带');
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('inventory-card-${fixture.cameraId}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('inventory-card-${fixture.keyboardId}')),
      findsNothing,
    );
    await tester.enterText(find.byType(TextField), '不存在的物品');
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的物品'), findsOneWidget);
    await tester.tap(find.text('清空搜索和筛选'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('inventory-card-${fixture.cameraId}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('inventory-card-${fixture.keyboardId}')),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('320dp 深色双倍字号下行与统计没有布局溢出', (WidgetTester tester) async {
    await _mountInventory(
      tester,
      size: const Size(320, 568),
      brightness: Brightness.dark,
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(const ValueKey<String>('management-summary-toggle')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byKey(const ValueKey<String>('management-summary-details')),
      const Offset(0, -350),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('统计失败明确提示而不会显示为零元', (WidgetTester tester) async {
    await _mountInventory(tester, failStatistics: true);
    expect(find.text('物品统计读取失败'), findsWidgets);
    expect(find.text('¥ 0.00'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('短屏双倍字号与键盘避让时空结果仍可滚动清空', (WidgetTester tester) async {
    await _mountInventory(
      tester,
      size: const Size(320, 420),
      textScale: 2,
      keyboardInset: 180,
    );
    await tester.enterText(find.byType(TextField), '不存在的物品');
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的物品'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 清空按钮应能通过空态自己的纵向滚动进入触控范围。
    final Finder clear = find.text('清空搜索和筛选');
    await tester.ensureVisible(clear);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的物品'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('短屏双倍字号的首次物品空态可完整滚动阅读', (WidgetTester tester) async {
    await _mountInventory(
      tester,
      size: const Size(320, 420),
      textScale: 2,
      keyboardInset: 180,
      emptyRecords: true,
    );
    // 首次空态的末行文字需要能滚到可视区域。
    final Finder hint = find.text('从最常找不到的那件物品开始记录');
    expect(hint, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(hint);
    await tester.pumpAndSettle();
    expect(hint.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

/// 只暴露测试需要断言的业务标识。
class _InventoryMobileFixture {
  /// 摄影物品标识。
  final String cameraId;

  /// 闲置键盘标识。
  final String keyboardId;

  /// 创建本次独立测试场景。
  const _InventoryMobileFixture({
    required this.cameraId,
    required this.keyboardId,
  });
}

/// 用内存数据库构造真实物品页，并在测试结束时释放流和数据库。
Future<_InventoryMobileFixture> _mountInventory(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool failStatistics = false,
  double keyboardInset = 0,
  bool emptyRecords = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  // 通过真实视图指标模拟键盘，保留 Scaffold 对 MediaQuery 的正常消费行为。
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // 手机布局偏好的独立存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 每个测试独立创建并关闭的数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 使用正式仓储验证配套回溯和金额口径。
  final InventoryRepository repository = InventoryRepository(database);
  // 数量大于一的主物品用于防止价格统计被误乘。
  final String cameraId = await repository.save(
    const InventoryDraft(
      name: '旅行摄影套装与备用镜头',
      category: '数码',
      location: '书房',
      tags: <String>['摄影'],
      quantity: 3,
      purchasePriceCents: 10000,
    ),
  );
  await repository.save(
    InventoryDraft(
      name: '相机肩带',
      parentItemId: cameraId,
      category: '数码',
      quantity: 1,
      purchasePriceCents: 5000,
    ),
  );
  // 不同位置和分类的第二件物品。
  final String keyboardId = await repository.save(
    const InventoryDraft(
      name: '闲置键盘',
      category: '办公',
      location: '储物间',
      status: InventoryStatus.idle,
      quantity: 1,
      purchasePriceCents: 2000,
    ),
  );
  // 显式管理的依赖容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      if (emptyRecords)
        inventoryItemsProvider.overrideWith(
          (Ref ref, String query) =>
              Stream<List<InventoryRecord>>.value(<InventoryRecord>[]),
        ),
      if (failStatistics)
        inventoryAllAccessoriesProvider.overrideWith(
          (Ref ref) => Stream<List<InventoryRecord>>.error(StateError('统计离线')),
        ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(brightness: brightness),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(body: InventoryPage(embeddedInManagement: true)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _InventoryMobileFixture(cameraId: cameraId, keyboardId: keyboardId);
}
