import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Android 管理页三类平铺记录、固定摘要及展开与筛选视觉基线。
void main() {
  testWidgets('安卓管理三分区平铺、固定搜索、独立滚动与九种视觉状态', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
    // 测试用事件仓储。
    final EventRepository eventRepository = EventRepository(database);
    // 测试用会员仓储。
    final MembershipRepository membershipRepository = MembershipRepository(
      database,
    );
    // 测试用物品仓储。
    final InventoryRepository inventoryRepository = InventoryRepository(
      database,
    );
    // 带长名称和长分类的事件名称。
    const String eventName = '需要定期检查并维护的超长家庭设备事件名称';
    await eventRepository.save(
      EventDraft(
        name: eventName,
        category: '家庭设备维护与日常安全检查',
        description: '检查运行状态并记录维护结果',
        intervalValue: 1,
        intervalUnit: EventIntervalUnit.month,
        lastCompletedAt: DateTime(2026, 9, 1),
      ),
    );
    // 保存后生成的事件标识。
    final String eventId =
        (await database.select(database.events).getSingle()).id;
    for (int index = 0; index < 7; index += 1) {
      // 用于撑开事件列表的附加记录序号。
      final int sequence = index + 1;
      await eventRepository.save(
        EventDraft(
          name: '附加周期事件 $sequence',
          intervalValue: sequence,
          intervalUnit: EventIntervalUnit.month,
          lastCompletedAt: DateTime(2026, 9, 1),
        ),
      );
    }
    // 带长名称且需要手动续费的会员标识。
    final String membershipId = await membershipRepository.save(
      MembershipDraft(
        name: '很长的专业创作与云端协作会员名称',
        category: '专业创作与云端协作服务分类',
        description: '团队共享方案',
        priceCents: 0,
        purchaseDate: DateTime(2026, 9, 1),
        expirationDate: DateTime(2026, 11, 1),
        isPermanent: false,
        autoRenew: false,
      ),
    );
    // 无价格且无到期日的永久会员标识。
    final String permanentMembershipId = await membershipRepository.save(
      MembershipDraft(
        name: '永久知识库会员',
        category: '长期知识与资料服务',
        priceCents: 0,
        purchaseDate: DateTime(2026, 8, 1),
        isPermanent: true,
        autoRenew: false,
      ),
    );
    for (int index = 0; index < 8; index += 1) {
      // 用于撑开会员列表的附加记录序号。
      final int sequence = index + 1;
      await membershipRepository.save(
        MembershipDraft(
          name: '附加会员 $sequence',
          category: '测试分类',
          priceCents: 1200,
          purchaseDate: DateTime(2026, 9, 1),
          expirationDate: DateTime(2027, 9, 1),
          isPermanent: false,
          autoRenew: true,
        ),
      );
    }
    // 带长名称、位置和价格的主物品标识。
    final String inventoryId = await inventoryRepository.save(
      InventoryDraft(
        name: '超长名称的移动摄影与户外录音设备套装',
        category: '专业摄影与影像设备',
        quantity: 2,
        purchasePriceCents: 376500,
        purchaseDate: DateTime(2024, 7, 1),
        location: '书房左侧器材收纳柜最下层',
      ),
    );
    await inventoryRepository.save(
      InventoryDraft(name: '备用连接线', parentItemId: inventoryId, quantity: 1),
    );
    for (int index = 0; index < 8; index += 1) {
      // 用于撑开物品列表的附加记录序号。
      final int sequence = index + 1;
      await inventoryRepository.save(
        InventoryDraft(
          name: '附加物品 $sequence',
          category: '测试分类',
          quantity: 1,
          location: '测试位置',
        ),
      );
    }
    // 显式管理测试依赖的容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 10, 2, 10)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    container.read(appRouterProvider).go('/events');
    await tester.pumpAndSettle();

    // 每个分区在常规与窄屏大字号下验证同一套移动契约。
    final List<({String section, String id, String listKey})> sections = [
      (section: 'events', id: eventId, listKey: 'event-card-grid'),
      (
        section: 'memberships',
        id: membershipId,
        listKey: 'membership-card-grid',
      ),
      (
        section: 'inventory',
        id: inventoryId,
        listKey: 'inventory-management-list',
      ),
    ];
    for (final section in sections) {
      container.read(appRouterProvider).go('/${section.section}');
      await tester.pumpAndSettle();
      // 当前分区的列表身份，物品列表使用滚动存储键。
      final Finder list = section.section == 'inventory'
          ? find.byKey(PageStorageKey<String>(section.listKey))
          : _key(section.listKey);
      // 当前业务的记录键前缀。
      final String prefix = switch (section.section) {
        'events' => 'event',
        'memberships' => 'membership',
        _ => 'inventory',
      };
      // 当前需要验证的含长名称记录。
      final Finder row = _key('$prefix-card-${section.id}');
      // 正常字号下记录自然高度，供大字号比较。
      double normalHeight = 0;
      for (final ({double width, double scale}) viewport in [
        (width: 390.0, scale: 1.0),
        (width: 360.0, scale: 1.0),
        (width: 320.0, scale: 2.0),
      ]) {
        tester.view.physicalSize = Size(viewport.width, 844);
        tester.platformDispatcher.textScaleFactorTestValue = viewport.scale;
        await tester.pumpAndSettle();
        await _revealRecord(tester, list: list, row: row);
        _expectWithinViewport(tester, row, viewport.width);
        if (viewport.width == 390) normalHeight = tester.getSize(row).height;
        if (viewport.scale == 2) {
          expect(tester.getSize(row).height, greaterThan(normalHeight));
        }
        if (section.section == 'events') {
          // 事件业务动作保留完整四十八像素热区。
          _expectTouchTarget(tester, _key('event-history-${section.id}'));
          _expectTouchTarget(tester, _key('event-record-${section.id}'));
          _expectTouchTarget(
            tester,
            find.descendant(
              of: row,
              matching: find.byType(OmniPopupMenuButton<String>),
            ),
          );
          expect(
            find.descendant(of: row, matching: find.byType(OmniPanel)),
            findsNothing,
          );
        } else if (section.section == 'memberships') {
          _expectTouchTarget(tester, _key('membership-renew-${section.id}'));
          expect(
            find.descendant(
              of: row,
              matching: find.byType(OmniPopupMenuButton<String>),
            ),
            findsNothing,
          );
          expect(
            tester
                .widget<OmniPanel>(
                  find.descendant(of: row, matching: find.byType(OmniPanel)),
                )
                .flat,
            isTrue,
          );
          expect(find.text('到期 2026-11-01'), findsOneWidget);
        } else {
          _expectTouchTarget(
            tester,
            _key('inventory-accessories-button-${section.id}'),
          );
          expect(_key('inventory-more-button-${section.id}'), findsNothing);
          expect(
            tester.getSize(_key('inventory-card-image-${section.id}')),
            const Size(96, 96),
          );
          expect(
            find.descendant(of: row, matching: find.byType(OmniPanel)),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
        await _scrollToTop(tester, list);
        await _expectFixedSummaryAndSearch(tester, list);
        if (viewport.scale == 2) {
          await _exerciseExpandedAndFilter(tester);
          expect(tester.takeException(), isNull);
        }
      }
      tester.view.physicalSize = const Size(390, 844);
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      await tester.pumpAndSettle();
      await _scrollToTop(tester, list);
      await expectLater(
        find.byType(OmniButlerApp),
        matchesGoldenFile(
          'goldens/management_${section.section}_light_390x844.png',
        ),
      );
      await tester.tap(_visibleKey('management-summary-toggle'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(OmniButlerApp),
        matchesGoldenFile(
          'goldens/management_${section.section}_expanded_light_390x844.png',
        ),
      );
      await tester.tap(_visibleKey('management-summary-toggle'));
      await tester.pumpAndSettle();
      await tester.tap(_visibleKey('management-filter-button'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(OmniButlerApp),
        matchesGoldenFile(
          'goldens/management_${section.section}_filters_light_390x844.png',
        ),
      );
      await tester.tap(find.byTooltip('取消筛选'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    // 永久会员的文案仍可通过列表滚动访问，截图完成后验证业务信息。
    container.read(appRouterProvider).go('/memberships');
    await tester.pumpAndSettle();
    await _revealRecord(
      tester,
      list: _key('membership-card-grid'),
      row: _key('membership-card-$permanentMembershipId'),
    );
    expect(find.text('永久有效'), findsOneWidget);
    tester.platformDispatcher.clearTextScaleFactorTestValue();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}

/// 返回跨页面复用的测试键。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 仅定位保活分区中当前可命中的共享控件。
Finder _visibleKey(String value) => _key(value).hitTestable();

/// 返回列表自身的纵向滚动位置，不改变祖先分页状态。
ScrollPosition _listPosition(WidgetTester tester, Finder list) => tester
    .state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    )
    .position;

/// 确保懒构建记录已经进入列表，并允许长行完整参与布局验证。
Future<void> _revealRecord(
  WidgetTester tester, {
  required Finder list,
  required Finder row,
}) async {
  if (row.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first,
    );
  }
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
}

/// 截图前恢复列表首屏，避免确保可见动作改变视觉基线。
Future<void> _scrollToTop(WidgetTester tester, Finder list) async {
  _listPosition(tester, list).jumpTo(0);
  await tester.pumpAndSettle();
}

/// 纵向滚动只移动列表，摘要与搜索均保持在原位置。
Future<void> _expectFixedSummaryAndSearch(
  WidgetTester tester,
  Finder list,
) async {
  // 当前摘要的固定顶部位置。
  final double summaryTop = tester
      .getTopLeft(_visibleKey('management-summary-toggle'))
      .dy;
  // 当前搜索的固定顶部位置。
  final double searchTop = tester
      .getTopLeft(_visibleKey('management-search'))
      .dy;
  // 拖动前的实际列表滚动位置。
  final double before = _listPosition(tester, list).pixels;
  await tester.drag(list, const Offset(0, -250));
  await tester.pumpAndSettle();
  expect(_listPosition(tester, list).pixels, greaterThan(before));
  expect(
    tester.getTopLeft(_visibleKey('management-summary-toggle')).dy,
    closeTo(summaryTop, 0.1),
  );
  expect(
    tester.getTopLeft(_visibleKey('management-search')).dy,
    closeTo(searchTop, 0.1),
  );
  expect(tester.takeException(), isNull);
  await _scrollToTop(tester, list);
}

/// 在窄屏大字号下实际打开完整统计和筛选面板。
Future<void> _exerciseExpandedAndFilter(WidgetTester tester) async {
  await tester.tap(_visibleKey('management-summary-toggle'));
  await tester.pumpAndSettle();
  expect(_key('management-summary-scrim'), findsOneWidget);
  expect(tester.takeException(), isNull);
  await tester.tap(_visibleKey('management-summary-toggle'));
  await tester.pumpAndSettle();
  await tester.tap(_visibleKey('management-filter-button'));
  await tester.pumpAndSettle();
  expect(_key('management-filter-sheet'), findsOneWidget);
  expect(tester.takeException(), isNull);
  await tester.tap(find.byTooltip('取消筛选'));
  await tester.pumpAndSettle();
}

/// 断言操作控件在两个方向都满足最小触控尺寸。
void _expectTouchTarget(WidgetTester tester, Finder finder) {
  // 操作控件的实际渲染尺寸。
  final Size size = tester.getSize(finder);
  expect(size.width, greaterThanOrEqualTo(48));
  expect(size.height, greaterThanOrEqualTo(48));
}

/// 断言卡片完整落在当前视口横向范围内。
void _expectWithinViewport(
  WidgetTester tester,
  Finder finder,
  double viewportWidth,
) {
  // 卡片的实际渲染边界。
  final Rect rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(viewportWidth));
}
