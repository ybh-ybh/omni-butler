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

/// 验证 Android 管理页三类记录卡片的紧凑尺寸、触控区域与吸顶行为。
void main() {
  testWidgets('安卓管理记录卡保持紧凑并仅吸顶筛选栏', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

    // 需要覆盖的常见 Android 逻辑宽度。
    const List<double> viewportWidths = <double>[320, 360, 390];
    for (final double viewportWidth in viewportWidths) {
      tester.view.physicalSize = Size(viewportWidth, 844);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('event-layout-toggle')),
        findsNothing,
      );
      // 当前事件卡片。
      final Finder eventCard = find.byKey(
        ValueKey<String>('event-card-$eventId'),
      );
      // 当前事件历史操作。
      final Finder historyButton = find.byKey(
        ValueKey<String>('event-history-$eventId'),
      );
      // 当前事件记录操作。
      final Finder recordButton = find.byKey(
        ValueKey<String>('event-record-$eventId'),
      );
      // 当前事件记录操作的可见按钮表面。
      final Finder recordButtonSurface = find.descendant(
        of: recordButton,
        matching: find.byKey(
          const ValueKey<String>('event-compact-action-surface'),
        ),
      );
      // 当前事件更多操作。
      final Finder eventMenu = find.descendant(
        of: eventCard,
        matching: find.byType(OmniPopupMenuButton<String>),
      );
      // 顶部菜单与底部操作改用 48 像素热区，卡片仍须保持紧凑高度。
      expect(tester.getSize(eventCard).height, lessThanOrEqualTo(178));
      _expectTouchTarget(tester, historyButton);
      _expectTouchTarget(tester, recordButton);
      expect(tester.getSize(recordButtonSurface).height, 28);
      _expectTouchTarget(tester, eventMenu);
      _expectWithinViewport(tester, eventCard, viewportWidth);
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/management_events_light_390x844.png'),
    );
    await _expectStatisticsScrollsAwayWhileFilterSticks(
      tester,
      statistics: find.byKey(
        const ValueKey<String>('event-statistics-carousel'),
      ),
      filter: find.byKey(const ValueKey<String>('event-status-selector')),
      scrollable: find.byKey(const ValueKey<String>('event-card-grid')),
    );

    container.read(appRouterProvider).go('/memberships');
    await tester.pumpAndSettle();
    for (final double viewportWidth in viewportWidths) {
      tester.view.physicalSize = Size(viewportWidth, 844);
      await tester.pumpAndSettle();
      // 当前会员卡片。
      final Finder membershipCard = find.byKey(
        ValueKey<String>('membership-card-$membershipId'),
      );
      // 当前会员续费操作。
      final Finder renewButton = find.byKey(
        ValueKey<String>('membership-renew-$membershipId'),
      );
      // 当前会员更多操作。
      final Finder membershipMenu = find.descendant(
        of: membershipCard,
        matching: find.byType(OmniPopupMenuButton<String>),
      );
      // 无到期日会员卡片。
      final Finder permanentMembershipCard = find.byKey(
        ValueKey<String>('membership-card-$permanentMembershipId'),
      );
      expect(tester.getSize(membershipCard).height, lessThanOrEqualTo(100));
      expect(
        tester.getSize(permanentMembershipCard).height,
        lessThanOrEqualTo(100),
      );
      expect(
        tester
            .getSize(
              find.descendant(
                of: permanentMembershipCard,
                matching: find.byType(OmniTag),
              ),
            )
            .height,
        18,
      );
      _expectTouchTarget(tester, renewButton);
      _expectTouchTarget(tester, membershipMenu);
      _expectWithinViewport(tester, membershipCard, viewportWidth);
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/management_memberships_light_390x844.png'),
    );
    await _expectStatisticsScrollsAwayWhileFilterSticks(
      tester,
      statistics: find.byKey(
        const ValueKey<String>('membership-statistics-carousel'),
      ),
      filter: find.byKey(const ValueKey<String>('membership-search-field')),
      scrollable: find.byKey(const ValueKey<String>('membership-card-grid')),
    );

    container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();
    for (final double viewportWidth in viewportWidths) {
      tester.view.physicalSize = Size(viewportWidth, 844);
      await tester.pumpAndSettle();
      // 当前物品卡片。
      final Finder inventoryCard = find.byKey(
        ValueKey<String>('inventory-card-$inventoryId'),
      );
      // 当前物品配套入口。
      final Finder accessoriesButton = find.byKey(
        ValueKey<String>('inventory-accessories-button-$inventoryId'),
      );
      // 当前物品更多操作。
      final Finder inventoryMenu = find.byKey(
        ValueKey<String>('inventory-more-button-$inventoryId'),
      );
      expect(tester.getSize(inventoryCard).height, 104);
      expect(
        tester
            .getSize(
              find.descendant(
                of: inventoryCard,
                matching: find.byType(OmniTag),
              ),
            )
            .height,
        18,
      );
      _expectTouchTarget(tester, accessoriesButton);
      _expectTouchTarget(tester, inventoryMenu);
      _expectWithinViewport(tester, inventoryCard, viewportWidth);
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/management_inventory_light_390x844.png'),
    );
    await _expectStatisticsScrollsAwayWhileFilterSticks(
      tester,
      statistics: find.byKey(
        const ValueKey<String>('inventory-statistics-carousel'),
      ),
      filter: find.byKey(const ValueKey<String>('inventory-search-field')),
      scrollable: find.byKey(const ValueKey<String>('inventory-card-grid')),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}

/// 断言统计卡随列表离开，筛选栏到顶后保持固定。
Future<void> _expectStatisticsScrollsAwayWhileFilterSticks(
  WidgetTester tester, {
  required Finder statistics,
  required Finder filter,
  required Finder scrollable,
}) async {
  // 滚动前统计卡的边界。
  final Rect initialStatisticsRect = tester.getRect(statistics);
  // 滚动前筛选栏的顶部位置。
  final double initialFilterTop = tester.getTopLeft(filter).dy;
  await tester.drag(scrollable, const Offset(0, -360));
  await tester.pumpAndSettle();
  // 统计头收起后筛选栏的固定顶部位置。
  final double pinnedFilterTop = tester.getTopLeft(filter).dy;
  expect(initialStatisticsRect.top, lessThan(initialFilterTop));
  expect(pinnedFilterTop, lessThan(initialFilterTop));
  expect(statistics, findsNothing);

  await tester.drag(scrollable, const Offset(0, -120));
  await tester.pumpAndSettle();
  // 列表继续滚动后的筛选栏位置。
  final double continuedFilterTop = tester.getTopLeft(filter).dy;
  expect(continuedFilterTop, closeTo(pinnedFilterTop, 0.1));
  expect(tester.takeException(), isNull);
}

/// 断言操作控件在两个方向都满足最小触控尺寸。
void _expectTouchTarget(WidgetTester tester, Finder finder) {
  // 操作控件的实际渲染尺寸。
  final Size size = tester.getSize(finder);
  expect(size.width, greaterThanOrEqualTo(44));
  expect(size.height, greaterThanOrEqualTo(44));
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
