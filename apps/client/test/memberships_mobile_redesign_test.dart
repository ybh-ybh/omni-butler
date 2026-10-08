import 'dart:ui' show SemanticsAction;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/management/presentation/management_mobile_scaffold.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/memberships/presentation/memberships_page.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证会员移动布局的数据口径、筛选事务和自然字号排版。
void main() {
  testWidgets('会员价格与名称同排，状态分类分色且日期在进度条下分列', (WidgetTester tester) async {
    // 普通字号下读取真实会员布局，而非模拟行组件。
    final _MembershipFixture fixture = await _pumpMemberships(
      tester,
      size: const Size(440, 844),
    );
    // 左侧身份信息区域与右侧价格的边界。
    final Rect identity = tester.getRect(
      _key('membership-identity-${fixture.firstId}'),
    );
    // 同排价格应处于身份信息高度内。
    final Rect price = tester.getRect(
      _key('membership-price-${fixture.firstId}'),
    );
    expect(price.left, greaterThan(identity.right));
    expect(price.center.dy, inInclusiveRange(identity.top, identity.bottom));
    // 分类描述使用中性色，状态单独使用带浅色底的标签。
    final Finder detail = _key('membership-detail-${fixture.firstId}');
    expect(
      tester.widget<Text>(detail).style?.color,
      OmniColors.of(tester.element(detail)).muted,
    );
    expect(
      find.descendant(
        of: _key('membership-card-${fixture.firstId}'),
        matching: find.byType(OmniTag),
      ),
      findsOneWidget,
    );
    // 三段日期说明在进度条下共享一行且占据左、中、右位置。
    final Rect start = tester.getRect(find.text('购买 2026-09-01'));
    // 当前会员的剩余时长文字。
    final Rect remaining = tester.getRect(
      find.descendant(
        of: _key('membership-timeline-${fixture.firstId}'),
        matching: find.textContaining('剩余'),
      ),
    );
    // 到期日期保持靠右，完整金额与日期不截断。
    final Rect expiration = tester.getRect(find.text('到期 2027-09-01'));
    expect(start.top, remaining.top);
    expect(expiration.top, remaining.top);
    expect(start.right, lessThan(remaining.left));
    expect(remaining.right, lessThan(expiration.left));
    expect(start.left, 16);
    expect(expiration.right, 424);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp双倍字号下长金额完整换行且续费入口仍可点击', (WidgetTester tester) async {
    // 长金额使用真实保存记录，验证宽度测量后的换行分支。
    final _MembershipFixture fixture = await _pumpMemberships(
      tester,
      size: const Size(320, 844),
      textScale: 2,
      manualPriceCents: 12345678900,
    );
    await tester.enterText(_searchField(), '音乐');
    await tester.pumpAndSettle();
    // 完整金额位于身份信息下方，不超过记录的左右留白。
    final Finder price = _key('membership-price-${fixture.manualId}');
    // 自然换行后的价格几何。
    final Rect priceRect = tester.getRect(price);
    expect(tester.widget<Text>(price).data, contains('123456789.00'));
    expect(priceRect.left, greaterThanOrEqualTo(16));
    expect(priceRect.right, lessThanOrEqualTo(304));
    expect(
      priceRect.top,
      greaterThanOrEqualTo(
        tester.getRect(_key('membership-identity-${fixture.manualId}')).bottom,
      ),
    );
    expect(priceRect.height, greaterThan(42));
    expect(tester.takeException(), isNull);
    await tester.tap(_key('membership-renew-${fixture.manualId}'));
    await tester.pumpAndSettle();
    expect(find.text('新增支付记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('会员摘要保持全量口径，完整统计保留支出趋势和续费', (WidgetTester tester) async {
    await _pumpMemberships(tester);
    expect(find.text('本月 ¥96.00', findRichText: true), findsOneWidget);
    expect(find.text('年度 ¥114.00', findRichText: true), findsOneWidget);
    expect(find.text('3天续费 1', findRichText: true), findsOneWidget);

    await tester.enterText(_searchField(), '音乐');
    await tester.pumpAndSettle();
    expect(find.text('音乐会员'), findsOneWidget);
    expect(find.text('设计会员'), findsNothing);
    expect(find.text('本月 ¥96.00', findRichText: true), findsOneWidget);

    await tester.tap(_key('management-summary-toggle'));
    await tester.pumpAndSettle();
    expect(_key('membership-mobile-statistics'), findsOneWidget);
    expect(_key('membership-metric-chart-本月支出'), findsOneWidget);
    expect(_key('membership-metric-chart-年度累计'), findsOneWidget);
    expect(_key('membership-metric-chart-即将续费'), findsOneWidget);
    expect(find.text('本月比上月多 ¥ 78.00'), findsOneWidget);
    expect(find.text('未来 3 天'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('会员筛选草稿取消不提交，应用和移除条件实时更新列表', (WidgetTester tester) async {
    await _pumpMemberships(tester);
    await tester.tap(_key('management-filter-button'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动续费 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('取消筛选'));
    await tester.pumpAndSettle();
    expect(find.text('设计会员'), findsOneWidget);
    expect(find.text('音乐会员'), findsOneWidget);

    await tester.tap(_key('management-filter-button'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动续费 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('办公工具 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('设计会员'), findsOneWidget);
    expect(find.text('音乐会员'), findsNothing);
    expect(find.text('筛选 2'), findsOneWidget);

    await tester.tap(_key('management-filter-button'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置'));
    await tester.tap(find.byTooltip('取消筛选'));
    await tester.pumpAndSettle();
    expect(find.text('筛选 2'), findsOneWidget);

    await tester.tap(find.text('自动续费'));
    await tester.pumpAndSettle();
    expect(find.text('筛选 1'), findsOneWidget);
    await tester.tap(find.text('办公工具'));
    await tester.pumpAndSettle();
    expect(find.text('音乐会员'), findsOneWidget);

    await tester.enterText(_searchField(), '不会匹配的名称');
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的会员'), findsOneWidget);
    await tester.tap(find.text('清除搜索与筛选'));
    await tester.pumpAndSettle();
    expect(find.text('设计会员'), findsOneWidget);
    expect(find.text('音乐会员'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('会员平铺行在双倍字号下完整显示日期并保持操作热区', (WidgetTester tester) async {
    // 当前会员标识用于读取真实记录行。
    final _MembershipFixture fixture = await _pumpMemberships(
      tester,
      textScale: 2,
    );
    // 首条会员平铺记录的面板。
    final Finder firstCard = _key('membership-card-${fixture.firstId}');
    // 会员记录只使用无边框面板。
    final OmniPanel panel = tester.widget<OmniPanel>(
      find.descendant(of: firstCard, matching: find.byType(OmniPanel)),
    );
    expect(panel.flat, isTrue);
    expect(find.text('购买 2026-09-01'), findsOneWidget);
    expect(find.text('到期 2027-09-01'), findsOneWidget);
    // 大字号自动将价格移到身份信息下方，日期按完整内容换行。
    final Rect identity = tester.getRect(
      _key('membership-identity-${fixture.firstId}'),
    );
    // 完整价格不挤占两层身份信息。
    final Rect price = tester.getRect(
      _key('membership-price-${fixture.firstId}'),
    );
    expect(price.top, greaterThanOrEqualTo(identity.bottom));
    expect(price.right, lessThanOrEqualTo(374));
    expect(
      tester.getRect(find.text('到期 2027-09-01')).top,
      greaterThan(tester.getRect(find.text('购买 2026-09-01')).top),
    );
    // 移动行不显示更多按钮，长按操作覆盖整条记录。
    final Finder menu = find.descendant(
      of: firstCard,
      matching: find.byType(OmniContextMenu<String>),
    );
    expect(menu, findsOneWidget);
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(_key('management-summary-toggle'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('会员支付统计读取失败时不显示伪零并提供重试', (WidgetTester tester) async {
    await _pumpMemberships(tester, paymentError: true);
    expect(find.text('本月 ¥0.00', findRichText: true), findsNothing);
    expect(find.textContaining('统计读取失败'), findsWidgets);
    expect(
      tester
          .widgetList<ManagementSummaryLine>(find.byType(ManagementSummaryLine))
          .every((ManagementSummaryLine line) => line.onRetry != null),
      isTrue,
    );
    expect(find.text('设计会员'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('会员支付统计加载期间显示占位且会员列表仍可读取', (WidgetTester tester) async {
    await _pumpMemberships(tester, paymentLoading: true);
    expect(find.text('正在读取统计'), findsWidgets);
    expect(find.text('本月 ¥0.00', findRichText: true), findsNothing);
    expect(find.text('设计会员'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('会员右上角续费保留原流程，整行长按打开支付记录等操作', (WidgetTester tester) async {
    // 开启真实语义树，验证没有可见按钮时仍可调用长按。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      // 自动续费和手动续费记录使用不同入口契约。
      final _MembershipFixture fixture = await _pumpMemberships(tester);
      // 普通会员的行尾续费操作。
      final Finder renew = _key('membership-renew-${fixture.manualId}');
      // 对齐名称所在行，避免仍留在价格行。
      final Rect nameRect = tester.getRect(find.text('音乐会员'));
      // 实际续费按钮的触控区域。
      final Rect renewRect = tester.getRect(renew);
      expect(renewRect.top, lessThan(nameRect.bottom));
      expect(renewRect.width, greaterThanOrEqualTo(48));
      expect(renewRect.height, greaterThanOrEqualTo(48));
      expect(_key('membership-renew-${fixture.firstId}'), findsNothing);
      expect(find.byTooltip('更多操作'), findsNothing);
      await tester.tap(renew);
      await tester.pumpAndSettle();
      expect(find.text('新增支付记录'), findsOneWidget);
      expect(find.text('移入回收站'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.longPress(find.text('设计会员'));
      await tester.pumpAndSettle();
      expect(find.text('支付记录'), findsOneWidget);
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('更换图片'), findsOneWidget);
      expect(find.text('移入回收站'), findsOneWidget);
      await tester.tap(find.text('支付记录'));
      await tester.pumpAndSettle();
      expect(find.text('设计会员 · 支付记录'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      // 读屏长按和触屏长按使用同一菜单入口。
      final int menuNode = tester
          .getSemantics(_key('membership-context-menu-${fixture.firstId}'))
          .id;
      tester
          .element(_key('membership-context-menu-${fixture.firstId}'))
          .findRenderObject()!
          .owner!
          .semanticsOwner!
          .performAction(menuNode, SemanticsAction.longPress);
      await tester.pumpAndSettle();
      expect(find.text('支付记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}

/// 返回公共移动控件的稳定测试键。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 返回共享搜索框实际接收键盘输入的控件。
Finder _searchField() => find.descendant(
  of: _key('management-search'),
  matching: find.byType(TextField),
);

/// 保存测试使用的会员记录标识。
class _MembershipFixture {
  /// 首条会员标识。
  final String firstId;

  /// 手动续费会员标识。
  final String manualId;

  /// 创建固定业务夹具。
  const _MembershipFixture({required this.firstId, required this.manualId});
}

/// 使用真实内存仓储和独立页面验证会员移动视图。
Future<_MembershipFixture> _pumpMemberships(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  int manualPriceCents = 1800,
  bool paymentError = false,
  bool paymentLoading = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 隔离生产数据的内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 实际保存和支付汇总使用的会员仓储。
  final MembershipRepository repository = MembershipRepository(database);
  // 本月购买并即将自动续费的会员。
  final String firstId = await repository.save(
    MembershipDraft(
      name: '设计会员',
      category: '办公工具',
      description: '团队协作',
      priceCents: 9600,
      purchaseDate: DateTime(2026, 9, 1),
      expirationDate: DateTime(2027, 9, 1),
      isPermanent: false,
      autoRenew: true,
      renewalDate: DateTime(2026, 9, 7),
    ),
  );
  // 手动续费会员用于验证常驻入口的新位置和原表单。
  final String manualId = await repository.save(
    MembershipDraft(
      name: '音乐会员',
      category: '影音娱乐',
      priceCents: manualPriceCents,
      purchaseDate: DateTime(2026, 8, 1),
      expirationDate: DateTime(2027, 8, 1),
      isPermanent: false,
      autoRenew: false,
    ),
  );
  // 管理实际响应式读取的依赖容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 9, 6, 10)),
      if (paymentError)
        activeMembershipPaymentsProvider.overrideWith(
          (Ref ref) => Stream<List<MembershipPaymentRecord>>.error(
            StateError('测试支付读取失败'),
          ),
        ),
      if (paymentLoading)
        activeMembershipPaymentsProvider.overrideWith(
          (Ref ref) => const Stream<List<MembershipPaymentRecord>>.empty(),
        ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.android),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(
          body: SafeArea(child: MembershipsPage(embeddedInManagement: true)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _MembershipFixture(firstId: firstId, manualId: manualId);
}
