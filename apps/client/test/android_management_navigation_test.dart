import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/inventory/data/inventory_repository.dart';
import 'package:omni_butler/features/management/presentation/android_management_shell.dart';
import 'package:omni_butler/features/management/presentation/management_mobile_scaffold.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/ui/omni_page_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Android 管理聚合页的导航、操作与功能开关联动。
void main() {
  testWidgets('Android 更多页展示分组设置并支持二级返回', (WidgetTester tester) async {
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
    container.read(appRouterProvider).go('/settings');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.byKey(const ValueKey<String>('android-settings-overview')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('android-settings-header')),
        matching: find.text('设置'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('android-settings-back')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('android-settings-group-home')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('android-settings-group-appearance')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('android-settings-group-sync')),
      findsOneWidget,
    );

    // 六个分类入口的视觉顺序。
    final List<Finder> categoryRows = <Finder>[
      find.byKey(const ValueKey<String>('android-settings-home')),
      find.byKey(const ValueKey<String>('android-settings-category-features')),
      find.byKey(
        const ValueKey<String>('android-settings-category-appearance'),
      ),
      find.byKey(
        const ValueKey<String>('android-settings-category-notifications'),
      ),
      find.byKey(const ValueKey<String>('android-settings-category-sync')),
      find.byKey(const ValueKey<String>('android-settings-category-storage')),
    ];
    // 各分类入口的顶部纵坐标。
    final List<double> categoryTops = categoryRows
        .map((Finder finder) => tester.getTopLeft(finder).dy)
        .toList(growable: false);
    expect(categoryTops, orderedEquals(categoryTops.toList()..sort()));

    await tester.tap(categoryRows[1]);
    await tester.pump();
    expect(_settingsCardOffset(tester, 'overview'), 0);
    expect(_settingsCardOffset(tester, 'detail'), 1);
    // 页面切换动画的中点等待时长。
    final Duration transitionHalfway = Duration(
      microseconds: OmniMotion.panel.inMicroseconds ~/ 2,
    );
    await tester.pump(transitionHalfway);
    // 进入时主页向左退场，详情从右进入，两张卡片保持相邻。
    final double enteringOverviewOffset = _settingsCardOffset(
      tester,
      'overview',
    );
    // 详情卡片进入中点的相对页宽位移。
    final double enteringDetailOffset = _settingsCardOffset(tester, 'detail');
    expect(enteringOverviewOffset, inExclusiveRange(-1, 0));
    expect(enteringDetailOffset, inExclusiveRange(0, 1));
    expect(enteringDetailOffset - enteringOverviewOffset, closeTo(1, 0.001));
    // 两张卡片使用与一级导航相同的缩放、圆角与阴影。
    for (final String role in <String>['overview', 'detail']) {
      // 当前层级卡片的缩放变换。
      final Transform scale = tester.widget<Transform>(
        find.byKey(ValueKey<String>('android-settings-$role-scale')),
      );
      // 当前层级卡片的物理外观。
      final PhysicalModel card = tester.widget<PhysicalModel>(
        find.byKey(ValueKey<String>('android-settings-$role-card')),
      );
      expect(scale.transform.storage[0], inExclusiveRange(0.985, 1));
      expect(card.elevation, greaterThan(0));
      expect(card.borderRadius, isNot(BorderRadius.zero));
    }
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('android-settings-detail-features')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('settings-content-features')),
      findsOneWidget,
    );
    // 二级页返回按钮的实际位置。
    final Rect settingsBackButtonRect = tester.getRect(
      find.byKey(const ValueKey<String>('android-settings-back')),
    );
    expect(settingsBackButtonRect.left, lessThan(OmniSize.touch));
    expect(settingsBackButtonRect.width, greaterThanOrEqualTo(OmniSize.touch));
    expect(settingsBackButtonRect.height, greaterThanOrEqualTo(OmniSize.touch));
    expect(find.byType(OmniPageHeader), findsNothing);
    expect(find.text('会员管理'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('android-settings-back')),
    );
    await tester.pump();
    await tester.pump(transitionHalfway);
    // 返回时详情向右退场，主页从左恢复，不能仍按进入方向播放。
    expect(
      _settingsCardOffset(tester, 'overview'),
      greaterThan(enteringOverviewOffset),
    );
    expect(
      _settingsCardOffset(tester, 'detail'),
      greaterThan(enteringDetailOffset),
    );
    expect(_settingsCardOffset(tester, 'overview'), inExclusiveRange(-1, 0));
    expect(_settingsCardOffset(tester, 'detail'), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('android-settings-overview')),
      findsOneWidget,
    );

    await tester.tap(categoryRows[2]);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('android-settings-detail-appearance')),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(transitionHalfway);
    // Android 系统返回复用同样的右移退场，而不是直接替换页面。
    expect(_settingsCardOffset(tester, 'overview'), inExclusiveRange(-1, 0));
    expect(_settingsCardOffset(tester, 'detail'), inExclusiveRange(0, 1));
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/settings',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('android-settings-overview')),
      findsOneWidget,
    );

    // 其余分类都应复用原有详情内容并可返回分类主页。
    const List<(String, String)> remainingCategories = <(String, String)>[
      ('notifications', '通知提醒'),
      ('sync', '数据同步'),
      ('storage', '回收站'),
    ];
    for (final (String name, String label) in remainingCategories) {
      await tester.tap(
        find.byKey(ValueKey<String>('android-settings-category-$name')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey<String>('android-settings-detail-$name')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('android-settings-header')),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('settings-content-$name')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('android-settings-back')),
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 管理下划线导航与独立分页保留新增和会话记忆', (WidgetTester tester) async {
    // 启动真实路由宿主和可滚动的三个管理分区。
    final _ManagementTestApp app = await _pumpManagementApp(tester);
    expect(
      find.byKey(const ValueKey<String>('android-management-shell')),
      findsOneWidget,
    );
    expect(find.byType(OmniPageHeader), findsNothing);
    // 固定顶部导航与当前下划线位置。
    final Rect header = tester.getRect(
      find.byKey(const ValueKey<String>('management-section-control')),
    );
    // 事件标签的实际触控边界。
    final Rect eventTab = tester.getRect(
      find.byKey(const ValueKey<String>('management-section-events')),
    );
    // 会员标签的实际触控边界。
    final Rect memberTab = tester.getRect(
      find.byKey(const ValueKey<String>('management-section-memberships')),
    );
    // 物品标签的实际触控边界。
    final Rect itemTab = tester.getRect(
      find.byKey(const ValueKey<String>('management-section-inventory')),
    );
    expect(eventTab.left, lessThan(memberTab.left));
    expect(memberTab.left, lessThan(itemTab.left));
    expect(
      tester
          .getRect(
            find.byKey(const ValueKey<String>('management-section-indicator')),
          )
          .center
          .dx,
      closeTo(itemTab.center.dx, 0.1),
    );
    expect(
      find.byKey(const ValueKey<String>('inventory-statistics-carousel')),
      findsNothing,
    );
    expect(
      find
          .byKey(const ValueKey<String>('management-summary-toggle'))
          .hitTestable(),
      findsOneWidget,
    );

    await tester.tap(
      find
          .byKey(const ValueKey<String>('inventory-mobile-create'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('新增物品').hitTestable(), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 末页横滑不会进入设置，浮动操作区也不泄漏一级手势。
    await _dragManagementPage(tester, -260);
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/inventory');
    await tester.drag(
      find
          .byKey(const ValueKey<String>('inventory-mobile-create'))
          .hitTestable(),
      const Offset(-120, 0),
    );
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/inventory');

    await tester.tap(
      find.byKey(const ValueKey<String>('management-section-events')),
    );
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/events');
    await _dragManagementPage(tester, 260);
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/events');
    await tester.tap(
      find.byKey(const ValueKey<String>('event-mobile-create')).hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('新增事件').hitTestable(), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 真实短拖使下划线跟手，顶部边界保持固定。
    final Finder surface = find.byKey(
      const ValueKey<String>('android-management-swipe-surface'),
    );
    // 真实分页表面的边界用于选择拖动起点。
    final Rect surfaceRect = tester.getRect(surface);
    // 手势开始前下划线的位置。
    final double indicatorStart = tester
        .getRect(
          find.byKey(const ValueKey<String>('management-section-indicator')),
        )
        .left;
    // 在页面正文上启动的真实触摸指针。
    final TestGesture gesture = await tester.startGesture(
      Offset(surfaceRect.right - 60, surfaceRect.bottom - 180),
    );
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-72, 0));
    await tester.pump();
    expect(
      tester.getRect(
        find.byKey(const ValueKey<String>('management-section-control')),
      ),
      header,
    );
    expect(
      tester
          .getRect(
            find.byKey(const ValueKey<String>('management-section-indicator')),
          )
          .left,
      greaterThan(indicatorStart),
    );
    expect(_managementPath(app), '/events');
    await gesture.moveBy(const Offset(72, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/events');
    await _dragManagementPage(tester, -20);
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/events');
    await _dragManagementPage(tester, -260);
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/memberships');
    await tester.tap(
      find
          .byKey(const ValueKey<String>('membership-mobile-create'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('新增会员').hitTestable(), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _dragManagementPage(tester, -260);
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/inventory');
    await _dragManagementPage(tester, 260);
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/memberships');

    await tester.tap(find.byKey(const ValueKey<String>('navigation-/home')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/inventory')),
    );
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/memberships');
    expect(
      app.container.read(managementSectionProvider),
      ManagementSection.memberships,
    );
    expect(tester.takeException(), isNull);
    await _disposeManagementApp(tester, app);
  });

  testWidgets('管理横滑消费层无空滚动语义且保留悬浮按钮读屏范围', (WidgetTester tester) async {
    // 读取实际交给系统辅助功能的语义节点。
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      // 使用真实路由和业务按钮复现外层语义合并。
      final _ManagementTestApp app = await _pumpManagementApp(tester);
      // 物品主操作的独立读屏节点。
      final SemanticsNode create = tester.getSemantics(
        find.bySemanticsLabel('新增物品'),
      );
      // 读屏热区不能超过可见拆分按钮。
      final Size size = tester.getSize(
        find.byKey(const ValueKey<String>('inventory-mobile-create-split')),
      );
      expect(create.rect.isEmpty, isFalse);
      expect(create.rect.width, lessThanOrEqualTo(size.width));
      expect(create.rect.height, lessThanOrEqualTo(size.height));
      expect(create.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(
        create.getSemanticsData().hasAction(SemanticsAction.scrollLeft),
        isFalse,
      );
      expect(
        create.getSemanticsData().hasAction(SemanticsAction.scrollRight),
        isFalse,
      );
      // 手势拦截边界不应向读屏暴露无法执行的横向滚动。
      final SemanticsNode boundary = tester.getSemantics(
        find.byKey(const ValueKey<String>('android-management-shell')),
      );
      expect(
        boundary.getSemanticsData().hasAction(SemanticsAction.scrollLeft),
        isFalse,
      );
      expect(
        boundary.getSemanticsData().hasAction(SemanticsAction.scrollRight),
        isFalse,
      );
      await _disposeManagementApp(tester, app);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('管理各分区搜索滚动保留且统计随标签底栏和外部路由收起', (WidgetTester tester) async {
    // 每个分区均写入足够多的独立记录。
    final _ManagementTestApp app = await _pumpManagementApp(tester);
    // 记录各分区在查询后的实际滚动位置。
    final Map<String, double> offsets = <String, double>{};
    // 分区路由、列表标识与专属搜索词。
    const List<(String, String, String)> sections = <(String, String, String)>[
      ('events', 'event-card-grid', '测试事件'),
      ('memberships', 'membership-card-grid', '测试会员'),
      ('inventory', 'inventory-management-list', '测试物品'),
    ];
    for (final (String section, String listKey, String query) in sections) {
      await tester.tap(
        find.byKey(ValueKey<String>('management-section-$section')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).hitTestable(), query);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.drag(
        _managementListFinder(listKey).hitTestable(),
        const Offset(0, -360),
      );
      await tester.pumpAndSettle();
      offsets[section] = _managementListOffset(tester, listKey);
      expect(offsets[section], greaterThan(0));
    }
    for (final (String section, String listKey, String query) in sections) {
      await tester.tap(
        find.byKey(ValueKey<String>('management-section-$section')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byType(TextField).hitTestable())
            .controller!
            .text,
        query,
      );
      expect(
        _managementListOffset(tester, listKey),
        closeTo(offsets[section]!, 0.1),
      );
    }
    // 完全展开后横拖正文蒙层和统计内容都不能切换分区。
    await tester.tap(
      find
          .byKey(const ValueKey<String>('management-summary-toggle'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(
      find
          .byKey(const ValueKey<String>('management-summary-scrim'))
          .hitTestable(),
      findsOneWidget,
    );
    await tester.drag(
      find
          .byKey(const ValueKey<String>('management-summary-scrim'))
          .hitTestable(),
      const Offset(260, 0),
    );
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/inventory');
    await tester.drag(
      find
          .byKey(const ValueKey<String>('management-summary-toggle'))
          .hitTestable(),
      const Offset(260, 0),
    );
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/inventory');
    // 点击标签离开，回来时摘要已收起，搜索和列表仍保留。
    await tester.tap(
      find.byKey(const ValueKey<String>('management-section-events')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('management-section-inventory')),
    );
    await tester.pumpAndSettle();
    _expectManagementCollapsed(tester);
    expect(
      _managementListOffset(tester, 'inventory-management-list'),
      closeTo(offsets['inventory']!, 0.1),
    );
    // 底部一级导航离开并返回也必须关闭摘要。
    await tester.tap(
      find
          .byKey(const ValueKey<String>('management-summary-toggle'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/home')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/inventory')),
    );
    await tester.pumpAndSettle();
    _expectManagementCollapsed(tester);
    expect(
      tester
          .widget<TextField>(find.byType(TextField).hitTestable())
          .controller!
          .text,
      '测试物品',
    );
    expect(
      _managementListOffset(tester, 'inventory-management-list'),
      closeTo(offsets['inventory']!, 0.1),
    );
    // 外部原路由直接切换分区时同样保持稳定子树。
    await tester.tap(
      find
          .byKey(const ValueKey<String>('management-summary-toggle'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    app.container.read(appRouterProvider).go('/memberships');
    await tester.pumpAndSettle();
    app.container.read(appRouterProvider).go('/inventory');
    await tester.pumpAndSettle();
    _expectManagementCollapsed(tester);
    expect(
      tester
          .widget<TextField>(find.byType(TextField).hitTestable())
          .controller!
          .text,
      '测试物品',
    );
    expect(
      _managementListOffset(tester, 'inventory-management-list'),
      closeTo(offsets['inventory']!, 0.1),
    );
    expect(tester.takeException(), isNull);
    await _disposeManagementApp(tester, app);
  });

  testWidgets('管理分页中途离开与隐藏零宽变更后均恢复整数页并可继续横滑', (WidgetTester tester) async {
    // 先用真实一级路由检查在途标签动画和触摸拖动。
    final _ManagementTestApp app = await _pumpManagementApp(tester);
    // 当前真实壳层的分页控制器，离开一级页面后仍须保留。
    final PageController controller = tester
        .widget<PageView>(
          find.byKey(
            const ValueKey<String>('android-management-swipe-surface'),
          ),
        )
        .controller!;
    await tester.tap(
      find.byKey(const ValueKey<String>('management-section-events')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // 标签动画已经启动但尚未停在某个分区整数位置。
    final double movingPage = controller.page!;
    expect((movingPage - movingPage.round()).abs(), greaterThan(0.01));
    // 保存这一帧真正选中的分区，离开后不得被旧动画回调改写。
    final ManagementSection selectedBeforeLeave = app.container.read(
      managementSectionProvider,
    );
    app.container.read(appRouterProvider).go('/settings');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/inventory')),
    );
    await tester.pumpAndSettle();
    // 当前启用分区顺序决定返回时应当落定的整数页。
    final List<ManagementSection> enabled = enabledManagementSections(
      app.container.read(featurePreferenceProvider),
    );
    expect(_managementPath(app), selectedBeforeLeave.route);
    expect(
      controller.page,
      closeTo(enabled.indexOf(selectedBeforeLeave).toDouble(), 0.001),
    );
    expect(controller.position.isScrollingNotifier.value, isFalse);

    app.container.read(appRouterProvider).go('/events');
    await tester.pumpAndSettle();
    // 从事件页正文拖动到未过中点的位置，保持手指仍在屏幕上。
    final Rect bounds = tester.getRect(
      find.byKey(const ValueKey<String>('android-management-swipe-surface')),
    );
    // 路由离开时仍在进行的真实触摸手势。
    final TestGesture gesture = await tester.startGesture(
      Offset(bounds.right - 60, bounds.bottom - 180),
    );
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-90, 0));
    await tester.pump();
    expect(controller.page, inExclusiveRange(0, 0.5));
    app.container.read(appRouterProvider).go('/home');
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/inventory')),
    );
    await tester.pumpAndSettle();
    expect(_managementPath(app), '/events');
    expect(controller.page, closeTo(0, 0.001));
    expect(controller.position.isScrollingNotifier.value, isFalse);

    // 使用同一真实壳层的零宽保活宿主，显式复现隐藏布局约束。
    final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: app.container,
        child: MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (BuildContext context, bool shown, Widget? child) =>
                  Align(
                    alignment: Alignment.topLeft,
                    child: Offstage(
                      offstage: !shown,
                      child: TickerMode(
                        enabled: shown,
                        child: SizedBox(
                          width: shown ? 390 : 0,
                          height: 844,
                          child: child,
                        ),
                      ),
                    ),
                  ),
              child: const AndroidManagementShell(
                selectedSection: ManagementSection.inventory,
                child: SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 隐藏与显示始终复用同一个分页控制器。
    final PageController keptController = tester
        .widget<PageView>(
          find.byKey(
            const ValueKey<String>('android-management-swipe-surface'),
          ),
        )
        .controller!;
    expect(keptController.page, closeTo(2, 0.001));
    visible.value = false;
    await tester.pumpAndSettle();
    expect(keptController.position.viewportDimension, 0);
    await app.container
        .read(featurePreferenceProvider.notifier)
        .setFeatureEnabled(AppFeature.memberships, false);
    await tester.pumpAndSettle();
    expect(keptController.position.viewportDimension, 0);
    visible.value = true;
    await tester.pumpAndSettle();
    expect(keptController.position.viewportDimension, 390);
    expect(keptController.page, closeTo(1, 0.001));
    expect(
      find.byKey(const ValueKey<String>('management-section-memberships')),
      findsNothing,
    );
    // 对齐恢复后真实双向横滑须再次更新稳定分区，不能残留 pending 状态。
    await _dragManagementPage(tester, 260);
    await tester.pumpAndSettle();
    expect(keptController.page, closeTo(0, 0.001));
    expect(
      app.container.read(managementSectionProvider),
      ManagementSection.events,
    );
    await _dragManagementPage(tester, -260);
    await tester.pumpAndSettle();
    expect(keptController.page, closeTo(1, 0.001));
    expect(
      app.container.read(managementSectionProvider),
      ManagementSection.inventory,
    );
    expect(tester.takeException(), isNull);
    await _disposeManagementApp(tester, app);
  });

  testWidgets('Android 物品拆分按钮保留次要操作并使用底部筛选', (WidgetTester tester) async {
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
      const ValueKey<String>('management-filter-button'),
    );
    // Android 物品搜索框。
    final Finder searchField = find.byKey(
      const ValueKey<String>('management-search'),
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
    expect(filterRect.height, OmniSize.touch);
    expect(filterRect.width, greaterThanOrEqualTo(OmniSize.touch));
    expect(searchRect.height, OmniSize.touch);
    expect(searchRect.width, greaterThan(250));
    expect(searchRect.top, closeTo(filterRect.top, 0.1));
    expect(tester.getSize(splitButton).height, OmniSize.touch);
    expect(createButtonRect.height, OmniSize.touch);
    expect(moreActionsButtonRect.size, const Size.square(OmniSize.touch));
    expect(createButtonRect.right, lessThan(moreActionsButtonRect.left));
    expect(find.text('新增'), findsOneWidget);
    expect(find.bySemanticsLabel('新增物品'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('更多物品操作')), findsOneWidget);
    _expectManagementScrollableLayout(
      tester,
      find.byKey(const PageStorageKey<String>('inventory-management-list')),
    );
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
    expect(find.text('新增物品'), findsNothing);
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
    await tester.tap(find.text('取消').hitTestable());
    await tester.pumpAndSettle();

    await tester.tap(filterToggle);
    await tester.pumpAndSettle();

    // 标签和位置在底部面板中换行展示，草稿不会即时过滤列表。
    final Finder filterSheet = find.byKey(
      const ValueKey<String>('management-filter-sheet'),
    );
    expect(filterSheet, findsOneWidget);
    await _tapManagementOption(tester, categories.first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ManagementSearchToolbar>(
            find.byType(ManagementSearchToolbar).first,
          )
          .filterCount,
      0,
    );
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(filterSheet, findsNothing);
    expect(
      tester
          .widget<ManagementSearchToolbar>(
            find.byType(ManagementSearchToolbar).hitTestable(),
          )
          .filterCount,
      1,
    );
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

  testWidgets('Android 会员工具栏使用底部筛选并保留分类管理', (WidgetTester tester) async {
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

    // 搜索靠左，独立筛选按钮在右侧保留完整触区。
    final Finder searchField = find
        .byKey(const ValueKey<String>('management-search'))
        .hitTestable();
    // 搜索栏右侧的筛选操作。
    final Finder filterToggle = find
        .byKey(const ValueKey<String>('management-filter-button'))
        .hitTestable();
    // 当前搜索输入的实际边界。
    final Rect searchRect = tester.getRect(searchField);
    // 当前筛选按钮的实际边界。
    final Rect filterRect = tester.getRect(filterToggle);
    // 菜单打开后仍可读取几何的拆分按钮。
    final Finder splitButton = find.byKey(
      const ValueKey<String>('membership-mobile-create-split'),
    );
    // 分类管理菜单的可触控入口。
    final Finder moreActionsButton = find
        .byKey(const ValueKey<String>('membership-mobile-more-actions'))
        .hitTestable();
    expect(
      find.byKey(const ValueKey<String>('membership-layout-toggle')),
      findsNothing,
    );
    expect(searchRect.height, OmniSize.touch);
    expect(filterRect.height, OmniSize.touch);
    expect(filterRect.width, greaterThanOrEqualTo(OmniSize.touch));
    expect(searchRect.right, lessThan(filterRect.left));
    expect(tester.getSize(splitButton).height, OmniSize.touch);
    _expectManagementScrollableLayout(
      tester,
      find.byKey(const ValueKey<String>('membership-card-grid')).hitTestable(),
    );
    await tester.tap(filterToggle);
    await tester.pumpAndSettle();
    await _tapManagementOption(tester, '自动续费');
    await _tapManagementOption(tester, categories.first);
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('management-filter-sheet')),
      findsNothing,
    );
    expect(
      tester
          .widget<ManagementSearchToolbar>(
            find.byType(ManagementSearchToolbar).hitTestable(),
          )
          .filterCount,
      2,
    );
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/memberships',
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
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('management-section-events')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('management-section-memberships')),
      findsNothing,
    );
    // 只剩一个管理分区时隐藏标签，横滑仍停留当前管理。
    await _dragManagementPage(tester, -260);
    await tester.pumpAndSettle();
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('管理'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('navigation-/inventory')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
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
    await tester.pumpAndSettle();

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

/// 读取 Android 更多层级卡片相对于视口宽度的水平位移。
double _settingsCardOffset(WidgetTester tester, String role) {
  return tester
      .widget<FractionalTranslation>(
        find.byKey(ValueKey<String>('android-settings-$role-translation')),
      )
      .translation
      .dx;
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

/// 从管理页内容下部执行横向拖动，避开顶部摘要和悬浮操作。
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

/// 验证管理页滚动视口铺到底栏上方，内容末尾保留悬浮按钮避让空间。
void _expectManagementScrollableLayout(WidgetTester tester, Finder scrollable) {
  // Android 底部导航栏。
  final Finder compactNavigation = find.byKey(
    const ValueKey<String>('compact-navigation'),
  );
  // 当前管理分区的滚动视图配置。
  final BoxScrollView scrollView = tester.widget<BoxScrollView>(scrollable);
  // 当前滚动内容的解析后边距。
  final EdgeInsets contentPadding = scrollView.padding!.resolve(
    TextDirection.ltr,
  );
  expect(
    tester.getRect(scrollable).bottom,
    closeTo(tester.getRect(compactNavigation).top, 0.1),
  );
  expect(contentPadding.bottom, 88);
}

/// 持有真实管理壳层测试的隔离依赖。
class _ManagementTestApp {
  /// 当前测试的依赖容器。
  final ProviderContainer container;

  /// 当前测试的内存数据库。
  final AppDatabase database;

  /// 避免成功路径与失败清理重复关闭数据库。
  bool disposed = false;

  /// 创建管理壳层测试环境。
  _ManagementTestApp({required this.container, required this.database});
}

/// 启动三分区均含长列表的真实安卓路由宿主。
Future<_ManagementTestApp> _pumpManagementApp(WidgetTester tester) async {
  await _configureAndroidView(tester);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': 'light',
  });
  // 当前测试使用的偏好配置。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 当前测试独立的内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 三个业务仓储只写入本测试数据。
  final EventRepository events = EventRepository(database);
  // 为会员分区准备独立的长列表。
  final MembershipRepository memberships = MembershipRepository(database);
  // 为物品分区准备独立的长列表。
  final InventoryRepository inventory = InventoryRepository(database);
  // 每个分区写入十六条可搜索且可滚动的记录。
  for (int index = 0; index < 16; index++) {
    await events.save(
      EventDraft(
        name: '测试事件 $index',
        description: '日常维护测试记录',
        intervalValue: index + 1,
        intervalUnit: EventIntervalUnit.day,
      ),
    );
    await memberships.save(
      MembershipDraft(
        name: '测试会员 $index',
        category: '测试分类',
        priceCents: 1200,
        purchaseDate: DateTime(2026, 9, 1),
        expirationDate: DateTime(2027, 9, 1),
        isPermanent: false,
        autoRenew: false,
      ),
    );
    await inventory.save(
      InventoryDraft(
        name: '测试物品 $index',
        category: '测试分类',
        quantity: 1,
        location: '测试位置',
      ),
    );
  }
  // 固定时间避免统计随实际日期变化。
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
  await tester.pumpAndSettle();
  // 同时注册失败路径清理，避免一个失败污染后续用例。
  final _ManagementTestApp app = _ManagementTestApp(
    container: container,
    database: database,
  );
  addTearDown(() => _disposeManagementApp(tester, app));
  return app;
}

/// 读取真实路由中当前管理地址。
String _managementPath(_ManagementTestApp app) => app.container
    .read(appRouterProvider)
    .routeInformationProvider
    .value
    .uri
    .path;

/// 读取当前列表真实纵向滚动位置。
double _managementListOffset(WidgetTester tester, String listKey) {
  // 对应业务列表的唯一纵向滚动状态。
  final ScrollableState scrollable = tester.state(
    find
        .descendant(
          of: _managementListFinder(listKey),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  return scrollable.position.pixels;
}

/// 兼容物品分页使用的持久滚动身份。
Finder _managementListFinder(String listKey) => find.byKey(
  listKey == 'inventory-management-list'
      ? PageStorageKey<String>(listKey)
      : ValueKey<String>(listKey),
);

/// 验证可见页已收起统计且正文回到原几何位置。
void _expectManagementCollapsed(WidgetTester tester) {
  expect(
    find
        .byKey(const ValueKey<String>('management-summary-scrim'))
        .hitTestable(),
    findsNothing,
  );
  // 正文的实际变换在收起状态归零。
  final Transform translation = tester.widget<Transform>(
    find
        .byKey(const ValueKey<String>('management-body-translation'))
        .hitTestable(),
  );
  expect(translation.transform.storage[13], 0);
}

/// 点击包含可选数量后缀的筛选选项。
Future<void> _tapManagementOption(WidgetTester tester, String label) async {
  // 只在底部面板内部寻找业务条件，避免碰到背后的记录文案。
  final Finder option = find.byWidgetPredicate(
    (Widget widget) =>
        widget is ManagementFilterOption &&
        (widget.label == label || widget.label.startsWith('$label ')),
  );
  await tester.ensureVisible(option);
  await tester.tap(option);
  await tester.pumpAndSettle();
}

/// 释放测试容器和原生数据库句柄。
Future<void> _disposeManagementApp(
  WidgetTester tester,
  _ManagementTestApp app,
) async {
  if (app.disposed) return;
  app.disposed = true;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  app.container.dispose();
  await tester.pump(const Duration(milliseconds: 100));
  await app.database.close();
  debugDefaultTargetPlatformOverride = null;
}
