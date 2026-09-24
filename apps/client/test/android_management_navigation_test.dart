import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/management/presentation/android_management_shell.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/shared/ui/omni_page_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Android 管理聚合页的导航、操作与功能开关联动。
void main() {
  testWidgets('Android 管理滑块切换三个功能并记住上次页签', (WidgetTester tester) async {
    await _configureAndroidView(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题与功能偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 显式管理的依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 24, 10)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    container.read(appRouterProvider).go('/inventory');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.byKey(const ValueKey<String>('android-management-shell')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('management-section-control')),
      findsOneWidget,
    );
    // 事件、会员与物品页签的实际位置。
    final Rect eventsSectionRect = tester.getRect(
      find.byKey(const ValueKey<String>('management-section-events')),
    );
    final Rect membershipsSectionRect = tester.getRect(
      find.byKey(const ValueKey<String>('management-section-memberships')),
    );
    final Rect inventorySectionRect = tester.getRect(
      find.byKey(const ValueKey<String>('management-section-inventory')),
    );
    expect(eventsSectionRect.left, lessThan(membershipsSectionRect.left));
    expect(membershipsSectionRect.left, lessThan(inventorySectionRect.left));
    expect(find.byType(OmniPageHeader), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('inventory-mobile-create')),
      findsOneWidget,
    );
    expect(find.text('管理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-statistics-carousel')),
      findsOneWidget,
    );
    // 顶部滑块与首张统计卡之间的紧凑外间距。
    final Rect sectionControlRect = tester.getRect(
      find.byKey(const ValueKey<String>('management-section-control')),
    );
    // 物品统计轮播的实际位置。
    final Rect inventoryStatisticsRect = tester.getRect(
      find.byKey(const ValueKey<String>('inventory-statistics-carousel')),
    );
    expect(
      inventoryStatisticsRect.top - sectionControlRect.bottom,
      closeTo(OmniSpacing.xs, 0.1),
    );
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey<String>('statistics-carousel-indicator-0'),
            ),
          )
          .width,
      18,
    );
    expect(
      find.byKey(const ValueKey<String>('statistics-carousel-indicator-2')),
      findsNothing,
    );

    // 统计区域横滑只切换物品统计卡，不切换管理分区。
    await tester.drag(
      find.byKey(const ValueKey<String>('inventory-statistics-carousel')),
      const Offset(-260, 0),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/inventory',
    );
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey<String>('statistics-carousel-indicator-1'),
            ),
          )
          .width,
      18,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('inventory-mobile-create')),
    );
    await tester.pumpAndSettle();
    expect(find.text('添加物品'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 顶部滑块可以从当前物品页直接切换到新的第一项事件记录。
    await tester.tap(
      find.byKey(const ValueKey<String>('management-section-events')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/events',
    );

    // 第一个管理分区继续向右横滑时不循环。
    await _dragManagementPage(tester, 260);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/events',
    );
    expect(
      find.byKey(const ValueKey<String>('event-mobile-create')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-mobile-create')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('event-statistics-carousel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('statistics-carousel-indicator-2')),
      findsOneWidget,
    );
    // 事件统计轮播同样优先消费横向手势。
    await tester.drag(
      find.byKey(const ValueKey<String>('event-statistics-carousel')),
      const Offset(-260, 0),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/events',
    );
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey<String>('statistics-carousel-indicator-1'),
            ),
          )
          .width,
      18,
    );
    await tester.tap(find.byKey(const ValueKey<String>('event-mobile-create')));
    await tester.pumpAndSettle();
    expect(find.text('新建周期事件'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 短距离拖动不应误切管理分区。
    await _dragManagementPage(tester, -20);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/events',
    );

    // 向左横滑进入新顺序中的下一个分区会员管理。
    await _dragManagementPage(tester, -260);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/memberships',
    );
    expect(
      find.byKey(const ValueKey<String>('membership-mobile-create')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('membership-statistics-carousel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('statistics-carousel-indicator-2')),
      findsOneWidget,
    );
    // 再次向左横滑进入新顺序中的最后一个分区物品管理。
    await _dragManagementPage(tester, -260);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/inventory',
    );
    // 向右横滑可以返回上一个管理分区。
    await _dragManagementPage(tester, 260);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/memberships',
    );
    // 返回会员管理后继续验证新增操作与会话记忆。
    await tester.tap(
      find.byKey(const ValueKey<String>('membership-mobile-create')),
    );
    await tester.pumpAndSettle();
    expect(find.text('添加会员'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('navigation-/home')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/inventory')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/memberships',
    );
    expect(
      container.read(managementSectionProvider),
      ManagementSection.memberships,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/settings')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('事件记录'), findsNothing);
    expect(find.text('会员管理'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 物品拆分按钮收纳次要操作并支持筛选单行横滑', (WidgetTester tester) async {
    await _configureAndroidView(tester);
    // 用于验证拆分按钮无障碍语义的句柄。
    final SemanticsHandle semanticsHandle = tester.ensureSemantics();
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
    // 足以撑开标签横向列表的分类名称。
    const List<String> categories = <String>[
      '专业摄影与影像设备',
      '电脑外设与办公工具',
      '家庭清洁与维护用品',
      '旅行收纳与户外装备',
      '厨房电器与烹饪工具',
      '运动健康与训练设备',
    ];
    // 足以撑开位置横向列表的存放地点。
    const List<String> locations = <String>[
      '书房左侧收纳柜',
      '客厅电视柜下层',
      '卧室衣柜顶部',
      '厨房储物间右侧',
      '阳台工具收纳箱',
      '玄关备用物品柜',
    ];
    for (int index = 0; index < categories.length; index += 1) {
      // 当前测试物品的分类名称。
      final String category = categories[index];
      // 当前测试物品的存放位置。
      final String location = locations[index];
      await repository.save(
        InventoryDraft(
          name: '测试物品 $index',
          category: category,
          quantity: 1,
          location: location,
        ),
      );
    }
    // 显式管理的依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 24, 10)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    container.read(appRouterProvider).go('/inventory');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Android 物品筛选开关。
    final Finder filterToggle = find.byKey(
      const ValueKey<String>('inventory-filter-toggle'),
    );
    // Android 物品搜索框。
    final Finder searchField = find.byKey(
      const ValueKey<String>('inventory-search-field'),
    );
    // Android 物品新增拆分按钮。
    final Finder splitButton = find.byKey(
      const ValueKey<String>('inventory-mobile-create-split'),
    );
    // Android 物品新增主操作。
    final Finder createButton = find.byKey(
      const ValueKey<String>('inventory-mobile-create'),
    );
    // Android 物品次要操作菜单入口。
    final Finder moreActionsButton = find.byKey(
      const ValueKey<String>('inventory-mobile-more-actions'),
    );
    // 筛选开关的实际位置。
    final Rect filterRect = tester.getRect(filterToggle);
    // 搜索框的实际位置。
    final Rect searchRect = tester.getRect(searchField);
    // 新增主操作的实际位置。
    final Rect createButtonRect = tester.getRect(createButton);
    // 次要操作入口的实际位置。
    final Rect moreActionsButtonRect = tester.getRect(moreActionsButton);

    expect(
      find.byKey(const ValueKey<String>('inventory-layout-selector')),
      findsNothing,
    );
    expect(filterRect.size, const Size.square(OmniSize.touch));
    expect(searchRect.height, OmniSize.touch);
    expect(searchRect.width, greaterThan(300));
    expect(searchRect.top, closeTo(filterRect.top, 0.1));
    expect(tester.getSize(splitButton).height, OmniSize.touch);
    expect(createButtonRect.height, OmniSize.touch);
    expect(moreActionsButtonRect.size, const Size.square(OmniSize.touch));
    expect(createButtonRect.right, lessThan(moreActionsButtonRect.left));
    expect(find.text('新增'), findsOneWidget);
    expect(find.bySemanticsLabel('新增物品'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('更多物品操作')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('inventory-move-button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-manage-category')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-manage-location')),
      findsNothing,
    );

    // 图标外框保持原尺寸，关闭状态第三条横线完整显示。
    final Finder toggleIcon = find.byKey(
      const ValueKey<String>('inventory-mobile-toggle-icon'),
    );
    // 第三条横线的缩放变换用于确认展开与收起的实际动画进度。
    final Finder thirdLine = find.byKey(
      const ValueKey<String>('inventory-mobile-toggle-line-2'),
    );
    expect(tester.getSize(toggleIcon), const Size.square(OmniSize.icon));
    expect(tester.widget<Transform>(thirdLine).transform.entry(0, 0), 1);

    await tester.tap(moreActionsButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // 菜单展开途中应处于部分透明、部分展开状态。
    final FadeTransition menuFade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey<String>('inventory-mobile-actions-fade')),
    );
    // 由底边向上展开的菜单动画。
    final SizeTransition menuExpansion = tester.widget<SizeTransition>(
      find.byKey(const ValueKey<String>('inventory-mobile-actions-expand')),
    );
    expect(menuFade.opacity.value, inExclusiveRange(0, 1));
    expect(menuExpansion.sizeFactor.value, inExclusiveRange(0, 1));
    expect(menuExpansion.alignment, Alignment.bottomRight);
    expect(
      tester.widget<Transform>(thirdLine).transform.entry(0, 0),
      inExclusiveRange(0, 1),
    );
    // 菜单完成展开后，图标仍按独立的 500ms 时长继续变形。
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<Transform>(thirdLine).transform.entry(0, 0),
      inExclusiveRange(0, 1),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Transform>(thirdLine).transform.entry(0, 0), 0);
    // 第一条线完成顺时针 45 度旋转，与第二条线形成叉号。
    expect(
      tester
          .widget<Transform>(
            find.byKey(
              const ValueKey<String>('inventory-mobile-toggle-line-0'),
            ),
          )
          .transform
          .entry(1, 0),
      closeTo(0.7071, 0.001),
    );
    // 完整展开的菜单边界必须位于按钮上方，宽度更窄且右侧对齐。
    final Rect menuRect = tester.getRect(
      find.byKey(const ValueKey<String>('inventory-mobile-actions-menu')),
    );
    // 菜单打开后原拆分按钮仍保持原位置和尺寸。
    final Rect splitRect = tester.getRect(splitButton);
    expect(menuRect.bottom, closeTo(splitRect.top - OmniSpacing.xs, 0.1));
    expect(menuRect.width, lessThan(splitRect.width));
    expect(menuRect.right, closeTo(splitRect.right, 0.1));
    expect(tester.getRect(createButton), createButtonRect);
    expect(find.text('一键搬家'), findsOneWidget);
    expect(find.text('管理标签'), findsOneWidget);
    expect(find.text('管理位置'), findsOneWidget);
    // 菜单项按主次动作约定从上至下排列。
    expect(
      tester.getRect(find.text('管理标签')).top,
      greaterThan(tester.getRect(find.text('一键搬家')).bottom),
    );
    expect(
      tester.getRect(find.text('管理位置')).top,
      greaterThan(tester.getRect(find.text('管理标签')).bottom),
    );

    // 点击菜单外部会收起菜单，且不会触发新增。
    await tester.tapAt(const Offset(20, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.widget<Transform>(thirdLine).transform.entry(0, 0),
      inExclusiveRange(0, 1),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Transform>(thirdLine).transform.entry(0, 0), 1);
    expect(find.text('管理标签'), findsNothing);
    expect(find.text('添加物品'), findsNothing);
    await tester.tap(moreActionsButton);
    await tester.pumpAndSettle();

    await tester.tap(find.text('管理标签'));
    await tester.pumpAndSettle();
    expect(find.text('物品标签'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tester.widget<Transform>(thirdLine).transform.entry(0, 0), 1);

    await tester.tap(moreActionsButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理位置'));
    await tester.pumpAndSettle();
    expect(find.text('物品位置'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(moreActionsButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键搬家'));
    await tester.pumpAndSettle();
    expect(find.text('1/2 · 选择物品'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(filterToggle);
    await tester.pumpAndSettle();

    // Android 标签筛选行。
    final Finder tagFilters = find.byKey(
      const ValueKey<String>('inventory-tag-filters'),
    );
    // Android 位置筛选行。
    final Finder locationFilters = find.byKey(
      const ValueKey<String>('inventory-location-filters'),
    );
    expect(tester.getSize(tagFilters).height, OmniSize.touch);
    expect(tester.getSize(locationFilters).height, OmniSize.touch);
    expect(
      tester.getRect(locationFilters).top,
      greaterThan(tester.getRect(tagFilters).bottom),
    );

    // 当前可见的第一个具体标签筛选项。
    final Finder firstTagChip = find
        .descendant(of: tagFilters, matching: find.byType(ChoiceChip))
        .at(1);
    await tester.tap(firstTagChip);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: filterToggle, matching: find.text('1')),
      findsOneWidget,
    );

    // 标签筛选行内的水平滚动区域。
    final Finder tagScrollable = find.descendant(
      of: tagFilters,
      matching: find.byType(Scrollable),
    );
    // 位置筛选行内的水平滚动区域。
    final Finder locationScrollable = find.descendant(
      of: locationFilters,
      matching: find.byType(Scrollable),
    );
    // 标签横向列表的滚动状态。
    final ScrollableState tagScrollState = tester.state(tagScrollable);
    // 位置横向列表的滚动状态。
    final ScrollableState locationScrollState = tester.state(
      locationScrollable,
    );
    expect(tagScrollState.position.maxScrollExtent, greaterThan(0));
    expect(locationScrollState.position.maxScrollExtent, greaterThan(0));

    await tester.drag(tagScrollable, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(tagScrollState.position.pixels, greaterThan(0));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/inventory',
    );

    await tester.drag(locationScrollable, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(locationScrollState.position.pixels, greaterThan(0));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/inventory',
    );

    semanticsHandle.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 会员工具栏紧凑排列并支持分类单行横滑', (WidgetTester tester) async {
    await _configureAndroidView(tester);
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
    // 足以撑开分类横向列表的长分类名称。
    const List<String> categories = <String>[
      '影音流媒体服务',
      '专业创作与协作工具',
      '云存储与数据备份',
      '在线学习与知识服务',
      '运动健康订阅服务',
      '开发工具与云平台',
    ];
    for (int index = 0; index < categories.length; index += 1) {
      // 当前测试会员的分类名称。
      final String category = categories[index];
      await repository.save(
        MembershipDraft(
          name: '测试会员 $index',
          category: category,
          priceCents: 1200,
          purchaseDate: DateTime(2026, 9, 1),
          expirationDate: DateTime(2027, 9, 1),
          isPermanent: false,
          autoRenew: false,
        ),
      );
    }
    // 显式管理的依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 24, 10)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    container.read(appRouterProvider).go('/memberships');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Android 会员快捷筛选轨道，初始应随筛选区折叠。
    final Finder quickFilters = find.byKey(
      const ValueKey<String>('membership-quick-filters'),
    );
    // Android 会员搜索框。
    final Finder searchField = find.byKey(
      const ValueKey<String>('membership-search-field'),
    );
    // Android 会员筛选开关。
    final Finder filterToggle = find.byKey(
      const ValueKey<String>('membership-filter-toggle'),
    );
    // Android 会员分类筛选行。
    final Finder categoryFilters = find.byKey(
      const ValueKey<String>('membership-category-filters'),
    );
    // 搜索框的实际位置。
    final Rect searchRect = tester.getRect(searchField);
    // 筛选开关的实际位置。
    final Rect filterRect = tester.getRect(filterToggle);
    // Android 会员新增拆分按钮。
    final Finder splitButton = find.byKey(
      const ValueKey<String>('membership-mobile-create-split'),
    );
    // Android 会员次要操作菜单入口。
    final Finder moreActionsButton = find.byKey(
      const ValueKey<String>('membership-mobile-more-actions'),
    );

    expect(
      find.byKey(const ValueKey<String>('membership-layout-toggle')),
      findsNothing,
    );
    expect(quickFilters, findsNothing);
    expect(categoryFilters, findsNothing);
    expect(searchRect.height, OmniSize.touch);
    expect(filterRect.size, const Size.square(OmniSize.touch));
    expect(searchRect.top, closeTo(filterRect.top, 0.1));
    expect(searchRect.width, greaterThan(300));
    expect(tester.getSize(splitButton).height, OmniSize.touch);
    expect(
      tester.getSize(moreActionsButton),
      const Size.square(OmniSize.touch),
    );
    expect(
      find.byKey(const ValueKey<String>('membership-manage-category')),
      findsNothing,
    );

    await tester.tap(filterToggle);
    await tester.pumpAndSettle();
    // 全宽状态轨道的实际位置。
    final Rect quickRect = tester.getRect(quickFilters);
    // 分类筛选行的实际位置。
    final Rect categoryRect = tester.getRect(categoryFilters);
    expect(quickRect.height, OmniSize.touch);
    expect(quickRect.width, greaterThan(360));
    expect(categoryRect.height, OmniSize.touch);
    expect(quickRect.top, greaterThan(searchRect.bottom));
    expect(categoryRect.top, greaterThan(quickRect.bottom));

    await tester.tap(
      find.byKey(const ValueKey<String>('membership-quick-autoRenew')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: filterToggle, matching: find.text('1')),
      findsOneWidget,
    );

    // 当前可见的第一个具体分类筛选项。
    final Finder firstCategoryChip = find
        .descendant(of: categoryFilters, matching: find.byType(ChoiceChip))
        .at(1);
    await tester.tap(firstCategoryChip);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: filterToggle, matching: find.text('2')),
      findsOneWidget,
    );

    // 分类筛选行内的水平滚动区域。
    final Finder categoryScrollable = find.descendant(
      of: categoryFilters,
      matching: find.byType(Scrollable),
    );
    // 分类横向列表的滚动状态。
    final ScrollableState categoryScrollState = tester.state(
      categoryScrollable,
    );
    expect(categoryScrollState.position.maxScrollExtent, greaterThan(0));

    await tester.drag(categoryScrollable, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(categoryScrollState.position.pixels, greaterThan(0));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/memberships',
    );

    await tester.tap(filterToggle);
    await tester.pumpAndSettle();
    expect(quickFilters, findsNothing);
    expect(categoryFilters, findsNothing);
    expect(
      find.descendant(of: filterToggle, matching: find.text('2')),
      findsOneWidget,
    );

    await tester.tap(moreActionsButton);
    await tester.pumpAndSettle();
    expect(find.text('管理分类'), findsOneWidget);
    // 单项菜单仍沿用物品拆分按钮的上方窄列表位置。
    final Rect menuRect = tester.getRect(
      find.byKey(const ValueKey<String>('membership-mobile-actions-menu')),
    );
    // 拆分按钮的实际位置。
    final Rect splitRect = tester.getRect(splitButton);
    expect(menuRect.bottom, closeTo(splitRect.top - OmniSpacing.xs, 0.1));
    expect(menuRect.width, lessThan(splitRect.width));
    expect(menuRect.right, closeTo(splitRect.right, 0.1));
    await tester.tap(find.text('管理分类'));
    await tester.pumpAndSettle();
    expect(find.text('会员分类'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 管理页隐藏已关闭页签并支持单选项', (WidgetTester tester) async {
    await _configureAndroidView(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
      'features.events.enabled': false,
      'features.memberships.enabled': false,
    });
    // 测试用主题与功能偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 显式管理的依赖容器。
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
    container.read(appRouterProvider).go('/inventory');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.byKey(const ValueKey<String>('management-section-inventory')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('management-section-events')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('management-section-memberships')),
      findsNothing,
    );
    // 只剩一个管理分区时横滑不离开当前页面。
    await _dragManagementPage(tester, -260);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/inventory',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 三个管理功能全部关闭时隐藏底栏入口', (WidgetTester tester) async {
    await _configureAndroidView(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
      'features.inventory.enabled': false,
      'features.events.enabled': false,
      'features.memberships.enabled': false,
    });
    // 测试用主题与功能偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          appDatabaseProvider.overrideWithValue(database),
        ],
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('管理'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('navigation-/inventory')),
      findsNothing,
    );

    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 管理横滑会跳过已关闭的中间分区', (WidgetTester tester) async {
    await _configureAndroidView(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
      'features.memberships.enabled': false,
    });
    // 测试用主题与功能偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 显式管理的依赖容器。
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
    container.read(appRouterProvider).go('/events');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await _dragManagementPage(tester, -260);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/inventory',
    );
    expect(
      container.read(managementSectionProvider),
      ManagementSection.inventory,
    );
    expect(
      find.byKey(const ValueKey<String>('management-section-memberships')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}

/// 配置 Android 紧凑布局测试视口。
Future<void> _configureAndroidView(WidgetTester tester) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
}

/// 从管理页内容下部执行横向拖动，避开顶部统计轮播。
Future<void> _dragManagementPage(WidgetTester tester, double deltaX) async {
  // Android 管理页整页横滑表面。
  final Finder swipeSurface = find.byKey(
    const ValueKey<String>('android-management-swipe-surface'),
  );
  // 横滑表面的实际位置。
  final Rect surfaceRect = tester.getRect(swipeSurface);
  // 靠近内容底部且避开右下角悬浮按钮的起点。
  final Offset start = Offset(
    deltaX < 0 ? surfaceRect.right - 60 : surfaceRect.left + 60,
    surfaceRect.bottom - 200,
  );
  await tester.dragFrom(start, Offset(deltaX, 0));
}
