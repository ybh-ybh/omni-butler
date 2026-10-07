import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/management/presentation/management_navigation.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/shared/ui/omni_page_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 桌面菜单应保持的业务分区顺序。
const List<ManagementSection> _desktopSections = <ManagementSection>[
  ManagementSection.events,
  ManagementSection.inventory,
  ManagementSection.memberships,
];

/// 验证桌面管理入口合并、标题切换和功能开关联动。
void main() {
  // 同时覆盖展开侧栏、窄导航轨和浅深两种主题。
  for (final ({Size size, Brightness brightness, String navigationKey}) scenario
      in <({Size size, Brightness brightness, String navigationKey})>[
        (
          size: const Size(1440, 900),
          brightness: Brightness.light,
          navigationKey: 'expanded-sidebar',
        ),
        (
          size: const Size(640, 760),
          brightness: Brightness.dark,
          navigationKey: 'medium-navigation',
        ),
      ]) {
    _testDesktopWidgets('${scenario.navigationKey} 三分区共用管理入口且菜单布局正常', (
      WidgetTester tester,
    ) async {
      // 当前主题和视口的独立应用环境。
      final _DesktopHarness harness = await _pumpDesktopApp(
        tester,
        size: scenario.size,
        brightness: scenario.brightness,
      );
      expect(_key(scenario.navigationKey), findsOneWidget);
      _expectSingleManagementEntry();

      await tester.tap(_key('navigation-/inventory'));
      await tester.pumpAndSettle();
      expect(harness.path, '/inventory');

      // 逐一验证原有直达路由也能选中同一个管理入口。
      for (final ManagementSection section in _desktopSections) {
        harness.router.go(section.route);
        await tester.pumpAndSettle();
        _expectSingleManagementEntry();
        _expectManagementSelected(tester);
        // Windows 三个管理分区的进出路由都应立即完成。
        final TransitionRoute<dynamic> route =
            ModalRoute.of(tester.element(_key('desktop-management-switcher')))!
                as TransitionRoute<dynamic>;
        expect(route.transitionDuration, Duration.zero);
        expect(route.reverseTransitionDuration, Duration.zero);
        expect(
          find.descendant(
            of: _key('desktop-management-switcher'),
            matching: find.text(section.label),
          ),
          findsOneWidget,
        );

        await _openManagementMenu(tester);
        expect(
          _key('desktop-management-selected-${section.name}'),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (Widget widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'desktop-management-selected-',
                ),
          ),
          findsOneWidget,
        );
        // 菜单顺序必须符合事件、物品、会员，且每个条目都在视口内。
        final List<double> optionTops = <double>[];
        // 按界面顺序检查每个可切换业务。
        for (final ManagementSection option in _desktopSections) {
          // 当前菜单条目的屏幕边界。
          final Rect bounds = tester.getRect(
            _key('desktop-management-option-${option.name}'),
          );
          optionTops.add(bounds.top);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(scenario.size.width));
          expect(bounds.bottom, lessThanOrEqualTo(scenario.size.height));
        }
        expect(optionTops, orderedEquals(optionTops.toList()..sort()));
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
    });
  }

  _testDesktopWidgets('标题菜单切换三页后各自新增按钮仍可打开原编辑器', (WidgetTester tester) async {
    // 使用全功能开启的桌面应用环境。
    final _DesktopHarness harness = await _pumpDesktopApp(tester);
    await tester.tap(_key('navigation-/inventory'));
    await tester.pumpAndSettle();

    // 每个分区对应的原有新增按钮和编辑器标题。
    for (final ({ManagementSection section, String action, String editor})
        target
        in <({ManagementSection section, String action, String editor})>[
          (section: ManagementSection.events, action: '新增事件', editor: '新建周期事件'),
          (
            section: ManagementSection.memberships,
            action: '新增会员',
            editor: '添加会员',
          ),
          (
            section: ManagementSection.inventory,
            action: '新增物品',
            editor: '添加物品',
          ),
        ]) {
      await _selectManagementSection(tester, target.section);
      expect(harness.path, target.section.route);
      _expectManagementSelected(tester);
      // 限定到页头，避免空状态中的同名操作干扰验证。
      final Finder createAction = find.descendant(
        of: find.byType(OmniPageHeader),
        matching: find.text(target.action),
      );
      expect(createAction, findsOneWidget);
      await tester.tap(createAction);
      await tester.pumpAndSettle();
      expect(find.text(target.editor), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(harness.path, target.section.route);
      expect(tester.takeException(), isNull);
    }
  });

  _testDesktopWidgets('离开管理后再次进入恢复菜单选择及直达路由的最近分区', (WidgetTester tester) async {
    // 验证会话记忆的应用环境。
    final _DesktopHarness harness = await _pumpDesktopApp(tester);
    await tester.tap(_key('navigation-/inventory'));
    await tester.pumpAndSettle();
    await _selectManagementSection(tester, ManagementSection.memberships);
    await tester.tap(_key('navigation-/home'));
    await tester.pumpAndSettle();
    await tester.tap(_key('navigation-/inventory'));
    await tester.pumpAndSettle();
    expect(harness.path, '/memberships');

    harness.router.go('/events');
    await tester.pumpAndSettle();
    await tester.tap(_key('navigation-/settings'));
    await tester.pumpAndSettle();
    await tester.tap(_key('navigation-/inventory'));
    await tester.pumpAndSettle();
    expect(harness.path, '/events');
    _expectManagementSelected(tester);
  });

  _testDesktopWidgets('默认物品功能关闭时进入事件且菜单不展示已关闭分区', (WidgetTester tester) async {
    // 模拟设备启动前已关闭物品管理。
    final _DesktopHarness harness = await _pumpDesktopApp(
      tester,
      preferences: <String, Object>{'features.inventory.enabled': false},
    );
    _expectSingleManagementEntry();
    await tester.tap(_key('navigation-/inventory'));
    await tester.pumpAndSettle();
    expect(harness.path, '/events');
    await _openManagementMenu(tester);
    expect(_key('desktop-management-option-inventory'), findsNothing);
    expect(_key('desktop-management-option-events'), findsOneWidget);
    expect(_key('desktop-management-option-memberships'), findsOneWidget);
    await tester.tap(_key('desktop-management-option-memberships'));
    await tester.pumpAndSettle();
    expect(harness.path, '/memberships');

    harness.router.go('/inventory');
    await tester.pumpAndSettle();
    expect(harness.path, '/home');
    expect(tester.takeException(), isNull);
  });

  _testDesktopWidgets('记忆分区关闭后回退可用分区且全部关闭时隐藏管理入口', (WidgetTester tester) async {
    // 支持在会话内修改功能开关的桌面环境。
    final _DesktopHarness harness = await _pumpDesktopApp(tester);
    harness.router.go('/memberships');
    await tester.pumpAndSettle();
    await tester.tap(_key('navigation-/settings'));
    await tester.pumpAndSettle();
    await harness.container
        .read(featurePreferenceProvider.notifier)
        .setFeatureEnabled(AppFeature.memberships, false);
    await tester.pumpAndSettle();
    await tester.tap(_key('navigation-/inventory'));
    await tester.pumpAndSettle();
    expect(harness.path, '/events');
    await _openManagementMenu(tester);
    expect(_key('desktop-management-option-memberships'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(_key('navigation-/settings'));
    await tester.pumpAndSettle();

    // 关闭剩余分区时聚合入口应随最后一个可用功能一起消失。
    for (final AppFeature feature in <AppFeature>[
      AppFeature.events,
      AppFeature.inventory,
    ]) {
      await harness.container
          .read(featurePreferenceProvider.notifier)
          .setFeatureEnabled(feature, false);
    }
    await tester.pumpAndSettle();
    expect(_key('navigation-/inventory'), findsNothing);
    expect(_key('navigation-/events'), findsNothing);
    expect(_key('navigation-/memberships'), findsNothing);
    harness.router.go('/events');
    await tester.pumpAndSettle();
    expect(harness.path, '/home');
    expect(tester.takeException(), isNull);
  });

  _testDesktopWidgets('Esc、外部点击和重复选择当前分区都不改变当前路由', (WidgetTester tester) async {
    // 以事件直达路由验证菜单的取消行为。
    final _DesktopHarness harness = await _pumpDesktopApp(tester);
    harness.router.go('/events');
    await tester.pumpAndSettle();

    await _openManagementMenu(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_key('desktop-management-option-events'), findsNothing);
    expect(harness.path, '/events');

    await _openManagementMenu(tester);
    await tester.tapAt(const Offset(1300, 700));
    await tester.pumpAndSettle();
    expect(_key('desktop-management-option-events'), findsNothing);
    expect(harness.path, '/events');

    await _selectManagementSection(tester, ManagementSection.events);
    expect(_key('desktop-management-option-events'), findsNothing);
    expect(harness.path, '/events');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android 宽窗口通过侧栏管理入口和标题菜单切换分区', (WidgetTester tester) async {
    // Android 宽窗口使用桌面壳层，但仍启用路由分支预载。
    final _DesktopHarness harness = await _pumpDesktopApp(
      tester,
      size: const Size(1024, 800),
    );
    expect(_key('medium-navigation'), findsOneWidget);
    expect(_key('compact-navigation'), findsNothing);
    _expectSingleManagementEntry();
    await tester.tap(_key('navigation-/inventory'));
    await tester.pumpAndSettle();
    expect(harness.path, '/inventory');

    // 两个原独立入口都应能从宽窗口标题菜单到达。
    for (final ManagementSection section in <ManagementSection>[
      ManagementSection.events,
      ManagementSection.memberships,
    ]) {
      await _selectManagementSection(tester, section);
      expect(harness.path, section.route);
      expect(_key('android-management-shell'), findsNothing);
      _expectManagementSelected(tester);
      expect(tester.takeException(), isNull);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

/// 用框架提供的平台变体确保全局平台在不变量检查前恢复。
void _testDesktopWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

/// 单个测试使用的依赖容器及路由访问入口。
class _DesktopHarness {
  /// 独立的应用依赖容器。
  final ProviderContainer container;

  /// 保存当前测试容器。
  const _DesktopHarness(this.container);

  /// 返回当前应用路由器。
  GoRouter get router => container.read(appRouterProvider);

  /// 返回当前页面的业务路由。
  String get path => router.routeInformationProvider.value.uri.path;
}

/// 使用内存数据库启动桌面壳层，并按页面、订阅、数据库顺序清理。
Future<_DesktopHarness> _pumpDesktopApp(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  Brightness brightness = Brightness.light,
  Map<String, Object> preferences = const <String, Object>{},
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(preferences);
  // 当前测试的本机偏好替身。
  final SharedPreferences storage = await SharedPreferences.getInstance();
  // 不读取或写入用户数据的内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 当前测试的依赖覆盖范围。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(storage),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 10, 6, 10)),
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
      child: MaterialApp.router(
        theme: AppTheme.build(brightness: brightness),
        routerConfig: container.read(appRouterProvider),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _DesktopHarness(container);
}

/// 根据稳定测试标识查找可见控件。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 验证三项原导航已经合并为单个管理入口。
void _expectSingleManagementEntry() {
  expect(_key('navigation-/inventory'), findsOneWidget);
  expect(_key('navigation-/events'), findsNothing);
  expect(_key('navigation-/memberships'), findsNothing);
  expect(
    find
            .descendant(of: _key('expanded-sidebar'), matching: find.text('管理'))
            .evaluate()
            .isNotEmpty ||
        find.byTooltip('管理').evaluate().isNotEmpty,
    isTrue,
  );
}

/// 验证管理入口呈现选中图标与当前主题的品牌色。
void _expectManagementSelected(WidgetTester tester) {
  // 管理聚合入口内的实际导航图标。
  final Icon icon = tester.widget<Icon>(
    find.descendant(
      of: _key('navigation-/inventory'),
      matching: find.byType(Icon),
    ),
  );
  // 该入口所在主题的语义色。
  final OmniColors colors = OmniColors.of(
    tester.element(_key('navigation-/inventory')),
  );
  expect(icon.icon, Icons.dashboard_customize_rounded);
  expect(icon.color, colors.brand);
}

/// 打开当前业务页标题旁的管理切换菜单。
Future<void> _openManagementMenu(WidgetTester tester) async {
  await tester.tap(_key('desktop-management-switcher'));
  await tester.pumpAndSettle();
}

/// 通过真实菜单点击切换指定管理分区。
Future<void> _selectManagementSection(
  WidgetTester tester,
  ManagementSection section,
) async {
  await _openManagementMenu(tester);
  await tester.tap(_key('desktop-management-option-${section.name}'));
  await tester.pumpAndSettle();
}
