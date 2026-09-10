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
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证会员管理页的摘要与单双列布局切换。
void main() {
  testWidgets('宽屏默认双列并可切换为单列', (WidgetTester tester) async {
    // 固定的业务当前时间。
    final DateTime now = DateTime(2026, 9, 6, 10);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用会员仓储。
    final MembershipRepository repository = MembershipRepository(database);
    // 第一张会员卡标识。
    final String firstId = await repository.save(
      MembershipDraft(
        name: '设计工具会员',
        provider: '设计服务商',
        category: '办公工具',
        description: '专业设计与协作',
        priceCents: 9600,
        purchaseDate: DateTime(2026, 9, 1),
        expirationDate: DateTime(2027, 9, 1),
        isPermanent: false,
        autoRenew: true,
        renewalDate: DateTime(2026, 9, 7),
      ),
    );
    // 第二张会员卡标识。
    final String secondId = await repository.save(
      MembershipDraft(
        name: '音乐会员',
        provider: '音乐服务商',
        category: '影音娱乐',
        priceCents: 1800,
        purchaseDate: DateTime(2026, 8, 1),
        expirationDate: DateTime(2027, 8, 1),
        isPermanent: false,
        autoRenew: false,
      ),
    );
    // 第二个会员最近一次续费记录。
    await repository.recordPayment(
      membershipId: secondId,
      amountCents: 1800,
      startDate: DateTime(2026, 9, 5),
      billingCycle: BillingCycle.year,
      validFrom: DateTime(2026, 9, 5),
      validUntil: DateTime(2027, 8, 1),
    );
    // 分类管理器顺序故意与名称顺序相反，验证筛选行沿用 sortOrder。
    final TaxonomyRepository taxonomyRepository = TaxonomyRepository(database);
    await taxonomyRepository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.membership,
        kind: TaxonomyKind.category,
        name: '影音娱乐',
        colorValue: 0xFF8E5CD9,
        sortOrder: 0,
      ),
    );
    await taxonomyRepository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.membership,
        kind: TaxonomyKind.category,
        name: '办公工具',
        colorValue: 0xFF8E5CD9,
        sortOrder: 1,
      ),
    );
    // 显式管理的测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(now),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();
    container.read(appRouterProvider).go('/memberships');
    await tester.pumpAndSettle();

    expect(find.text('未来 3 天'), findsOneWidget);
    expect(find.text('1 项'), findsOneWidget);
    expect(find.text('设计服务商'), findsNothing);
    expect(find.text('办公工具 · 专业设计与协作'), findsOneWidget);
    expect(find.textContaining('剩余 '), findsNWidgets(2));
    expect(find.text('¥ 96.00 / 年', findRichText: true), findsOneWidget);
    expect(find.text('续费 2026-09-05'), findsOneWidget);
    expect(find.text('购买 2026-08-01'), findsNothing);
    expect(find.text('当前月份'), findsOneWidget);
    expect(find.text('累计会员支出'), findsOneWidget);
    expect(find.text('请及时处理'), findsOneWidget);
    expect(find.text('本月比上月多 ¥ 96.00'), findsOneWidget);
    expect(find.textContaining('+¥'), findsNothing);
    expect(find.textContaining('-¥'), findsNothing);

    // 本月支出卡片底部的独立图表区域。
    final Finder monthChart = find.byKey(
      const ValueKey<String>('membership-metric-chart-本月支出'),
    );
    // 本月支出卡片。
    final Finder monthMetric = find.byKey(
      const ValueKey<String>('membership-metric-本月支出'),
    );
    expect(monthChart, findsOneWidget);
    expect(
      tester.getRect(monthChart).top,
      greaterThan(tester.getRect(find.text('当前月份')).bottom),
    );
    expect(
      tester.getRect(monthChart).bottom,
      lessThanOrEqualTo(tester.getRect(monthMetric).bottom),
    );

    // 位于自动续费快捷筛选右侧的常驻搜索框。
    final Finder searchField = find.byKey(
      const ValueKey<String>('membership-search-field'),
    );
    // 自动续费快捷筛选标签。
    final Finder autoRenewFilter = find.text('自动续费');
    expect(searchField, findsOneWidget);
    expect(
      tester.getRect(searchField).left,
      greaterThan(tester.getRect(autoRenewFilter).right),
    );
    // 快捷筛选轨道与内部滑块。
    final Finder quickFilters = find.byKey(
      const ValueKey<String>('membership-quick-filters'),
    );
    // 自动续费快捷筛选项。
    final Finder quickAutoRenew = find.byKey(
      const ValueKey<String>('membership-quick-autoRenew'),
    );
    final double quickStart = tester.getTopLeft(quickFilters).dx;
    await tester.tap(quickAutoRenew);
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(quickFilters).dx, closeTo(quickStart, 0.1));
    await tester.pumpAndSettle();
    expect(find.text('自动续费'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('membership-quick-all')),
    );
    await tester.pumpAndSettle();
    expect(find.text('筛选'), findsNothing);
    expect(find.text('管理分类'), findsOneWidget);
    expect(find.text('分类'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('membership-category-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('membership-category-办公工具')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('membership-category-影音娱乐')),
      findsOneWidget,
    );
    expect(find.text('全部分类 2'), findsOneWidget);
    expect(find.text('办公工具 1'), findsOneWidget);
    expect(find.text('影音娱乐 1'), findsOneWidget);
    expect(
      tester
          .getRect(
            find.byKey(const ValueKey<String>('membership-category-影音娱乐')),
          )
          .left,
      lessThan(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('membership-category-办公工具')),
            )
            .left,
      ),
    );

    // 两张会员卡。
    final Finder firstCard = find.byKey(
      ValueKey<String>('membership-card-$firstId'),
    );
    final Finder secondCard = find.byKey(
      ValueKey<String>('membership-card-$secondId'),
    );
    // 自动续费会员不显示续费按钮。
    final Finder firstRenewButton = find.byKey(
      ValueKey<String>('membership-renew-$firstId'),
    );
    // 普通会员的续费按钮。
    final Finder secondRenewButton = find.byKey(
      ValueKey<String>('membership-renew-$secondId'),
    );
    // 第二张卡片的到期时间条。
    final Finder secondTimeline = find.byKey(
      ValueKey<String>('membership-timeline-$secondId'),
    );
    // 搜索输入框。
    final Finder searchInput = find.descendant(
      of: searchField,
      matching: find.byType(TextField),
    );
    await tester.tap(autoRenewFilter);
    await tester.enterText(searchInput, '音乐服务商');
    await tester.pumpAndSettle();
    expect(firstCard, findsNothing);
    expect(secondCard, findsNothing);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(firstCard, findsOneWidget);
    expect(secondCard, findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('membership-quick-all')),
    );
    await tester.pumpAndSettle();
    expect(firstCard, findsOneWidget);
    expect(secondCard, findsOneWidget);
    // 办公工具分类标签。
    final Finder officeCategory = find.byKey(
      const ValueKey<String>('membership-category-办公工具'),
    );
    await tester.tap(officeCategory);
    await tester.pumpAndSettle();
    expect(firstCard, findsOneWidget);
    expect(secondCard, findsNothing);
    await tester.tap(officeCategory);
    await tester.pumpAndSettle();
    expect(firstCard, findsOneWidget);
    expect(secondCard, findsOneWidget);
    expect(firstRenewButton, findsNothing);
    expect(
      find.descendant(of: secondRenewButton, matching: find.byType(TextButton)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: secondRenewButton,
        matching: find.byType(OutlinedButton),
      ),
      findsNothing,
    );
    expect(
      tester.getRect(secondTimeline).right,
      lessThan(tester.getRect(secondRenewButton).left),
    );
    // 双列时两张卡片横向排列。
    final Offset firstGridPosition = tester.getTopLeft(firstCard);
    // 双列时第二张卡片位置。
    final Offset secondGridPosition = tester.getTopLeft(secondCard);
    expect(secondGridPosition.dy, closeTo(firstGridPosition.dy, 1));
    expect(
      (secondGridPosition.dx - firstGridPosition.dx).abs(),
      greaterThan(100),
    );

    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/memberships_light_1440x900.png'),
    );

    await tester.tap(secondRenewButton);
    await tester.pumpAndSettle();
    expect(find.text('新增支付记录'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 第一张会员卡的更多菜单。
    final Finder firstCardMenu = find.descendant(
      of: firstCard,
      matching: find.byType(OmniPopupMenuButton<String>),
    );
    await tester.tap(firstCardMenu);
    await tester.pumpAndSettle();
    expect(find.text('支付记录'), findsOneWidget);
    await tester.tapAt(const Offset(1200, 700));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('membership-layout-toggle')),
    );
    await tester.pumpAndSettle();

    // 单列时第一张卡片位置。
    final Offset firstListPosition = tester.getTopLeft(firstCard);
    // 单列时第二张卡片位置。
    final Offset secondListPosition = tester.getTopLeft(secondCard);
    expect(secondListPosition.dx, closeTo(firstListPosition.dx, 1));
    expect(
      (secondListPosition.dy - firstListPosition.dy).abs(),
      greaterThan(40),
    );
    expect(find.text('双列'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('会员分类重命名后筛选和卡片使用关联 ID 的新名称', (WidgetTester tester) async {
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
    // 测试用 taxonomy 仓储。
    final TaxonomyRepository taxonomyRepository = TaxonomyRepository(database);
    await taxonomyRepository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.membership,
        kind: TaxonomyKind.category,
        name: '效率工具',
        colorValue: 0xFF1EA7A1,
      ),
    );
    // 重命名前的会员分类条目。
    final TaxonomyEntry category =
        (await (database.select(database.taxonomyEntries)..where(
                  (TaxonomyEntries table) =>
                      table.module.equals(TaxonomyModule.membership.name) &
                      table.kind.equals(TaxonomyKind.category.name) &
                      table.name.equals('效率工具') &
                      table.deletedAt.isNull(),
                ))
                .get())
            .single;
    // 测试用会员仓储。
    final MembershipRepository membershipRepository = MembershipRepository(
      database,
    );
    // 测试会员标识。
    final String membershipId = await membershipRepository.save(
      MembershipDraft(
        name: '专注应用会员',
        category: '效率工具',
        categoryIds: <String>{category.id},
        priceCents: 1200,
        purchaseDate: DateTime(2026, 9, 1),
        expirationDate: DateTime(2027, 9, 1),
        isPermanent: false,
        autoRenew: false,
      ),
    );
    // 只重命名 taxonomy，不改动会员表中的旧文本，模拟真实操作。
    await taxonomyRepository.save(
      TaxonomyDraft(
        id: category.id,
        module: TaxonomyModule.membership,
        kind: TaxonomyKind.category,
        name: '效率工具1',
        colorValue: category.colorValue,
        sortOrder: category.sortOrder,
      ),
    );
    // 重命名同步更新会员表中的冗余分类文本。
    final MembershipRecord renamedMembership = await (database.select(
      database.memberships,
    )..where((Memberships table) => table.id.equals(membershipId))).getSingle();
    expect(renamedMembership.category, '效率工具1');
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
    container.read(appRouterProvider).go('/memberships');
    await tester.pumpAndSettle();

    // 重命名后的筛选项和卡片使用同一个关联 ID 对应的新名称。
    expect(
      find.byKey(const ValueKey<String>('membership-category-效率工具1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('membership-category-效率工具')),
      findsNothing,
    );
    expect(find.text('效率工具1 · 未分类'), findsNothing);
    expect(find.text('效率工具1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
