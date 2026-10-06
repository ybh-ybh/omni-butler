import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Android 更多层级卡片的中途反向、重复返回与减少动态效果。
void main() {
  testWidgets('进入详情途中系统返回不跳位，重复返回不重启动画', (WidgetTester tester) async {
    // 当前测试使用的完整应用环境。
    final _SettingsTransitionTestApp app = await _pumpSettingsApp(tester);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('android-settings-category-appearance'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // 系统返回前两张卡片的真实横向位置。
    final double overviewBeforeBack = _cardOffset(tester, 'overview');
    // 详情卡片此时尚未完全进入视口。
    final double detailBeforeBack = _cardOffset(tester, 'detail');
    expect(overviewBeforeBack, inExclusiveRange(-1, 0));
    expect(detailBeforeBack, inExclusiveRange(0, 1));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_cardOffset(tester, 'overview'), closeTo(overviewBeforeBack, 1e-9));
    expect(_cardOffset(tester, 'detail'), closeTo(detailBeforeBack, 1e-9));
    expect(_currentPath(app), '/settings');

    // 已经执行的返回时长，用于检查重复返回不会延后原定结束时刻。
    const Duration elapsedReturn = Duration(milliseconds: 70);
    await tester.pump(elapsedReturn);
    // 返回中途的详情位置，应向右移动而不是继续进入。
    final double detailDuringReturn = _cardOffset(tester, 'detail');
    expect(detailDuringReturn, greaterThan(detailBeforeBack));
    expect(detailDuringReturn, lessThan(1));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_cardOffset(tester, 'detail'), closeTo(detailDuringReturn, 1e-9));
    expect(_currentPath(app), '/settings');
    await tester.pump(OmniMotion.panel - elapsedReturn);
    // 220ms 时必须已经落位；Flutter 插值模拟在下一帧才报告完成。
    expect(_cardOffset(tester, 'overview'), 0);
    expect(_cardOffset(tester, 'detail'), 1);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      find.byKey(const ValueKey<String>('android-settings-overview')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('android-settings-detail-appearance'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    expect(_cardOffset(tester, 'overview'), 0);
    expect(_currentPath(app), '/settings');
    expect(tester.takeException(), isNull);
    await _disposeSettingsApp(tester, app);
  });

  testWidgets('禁用动画时更多详情立即进入和返回且没有卡片装饰', (WidgetTester tester) async {
    await _verifyReducedMotionTransitions(
      tester,
      const FakeAccessibilityFeatures(disableAnimations: true),
    );
  });

  testWidgets('无障碍导航时更多详情立即进入和返回且没有卡片装饰', (WidgetTester tester) async {
    await _verifyReducedMotionTransitions(
      tester,
      const FakeAccessibilityFeatures(accessibleNavigation: true),
    );
  });

  testWidgets('详情页离开更多主分支后再次进入保留层级并可正常返回', (WidgetTester tester) async {
    // 当前测试使用的完整应用环境。
    final _SettingsTransitionTestApp app = await _pumpSettingsApp(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('android-settings-category-features')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('navigation-/home')));
    await tester.pumpAndSettle();
    expect(_currentPath(app), '/home');
    expect(
      find.byKey(const ValueKey<String>('android-settings-detail-features')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/settings')),
    );
    await tester.pumpAndSettle();
    expect(_currentPath(app), '/settings');
    expect(
      find.byKey(const ValueKey<String>('android-settings-detail-features')),
      findsOneWidget,
    );
    _expectStationaryCard(tester, 'detail');
    await tester.tap(
      find.byKey(const ValueKey<String>('android-settings-back')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('android-settings-overview')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('android-settings-detail-features'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    expect(_currentPath(app), '/settings');
    expect(tester.takeException(), isNull);
    await _disposeSettingsApp(tester, app);
  });

  testWidgets('返回更多一级列表时保留进入前的滚动位置', (WidgetTester tester) async {
    // 使用较矮的 Android 视口让分类列表产生实际滚动。
    final _SettingsTransitionTestApp app = await _pumpSettingsApp(tester);
    tester.view.physicalSize = const Size(390, 480);
    await tester.pumpAndSettle();
    // 分类主页中的真实滚动视口。
    final Finder overviewScrollable = find.descendant(
      of: find.byKey(const ValueKey<String>('android-settings-overview')),
      matching: find.byType(Scrollable),
    );
    await tester.drag(overviewScrollable, const Offset(0, -180));
    await tester.pumpAndSettle();
    // 最后一个分类入口，用于验证滚动到列表底部后再返回。
    final Finder storageCategory = find.byKey(
      const ValueKey<String>('android-settings-category-storage'),
    );
    await tester.ensureVisible(storageCategory);
    await tester.pumpAndSettle();
    // 进入详情前保留下来的分类列表状态。
    final ScrollableState originalScroll = tester.state<ScrollableState>(
      overviewScrollable,
    );
    // 进入详情前的有效纵向位移。
    final double originalOffset = originalScroll.position.pixels;
    expect(originalOffset, greaterThan(0));
    await tester.tap(storageCategory);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('android-settings-back')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(overviewScrollable),
      same(originalScroll),
    );
    expect(originalScroll.position.pixels, closeTo(originalOffset, 0.01));
    await _disposeSettingsApp(tester, app);
  });
}

/// 当前设置动画测试持有的依赖容器和数据库。
class _SettingsTransitionTestApp {
  /// 当前完整应用的依赖容器。
  final ProviderContainer container;

  /// 当前完整应用的内存数据库。
  final AppDatabase database;

  /// 测试依赖是否已经释放。
  bool disposed = false;

  /// 创建设置动画测试环境。
  _SettingsTransitionTestApp({required this.container, required this.database});
}

/// 启动 Android 紧凑布局并完整落位到更多首页。
Future<_SettingsTransitionTestApp> _pumpSettingsApp(WidgetTester tester) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': 'light',
  });
  // 测试用主题与功能偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 测试用内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 显式管理的应用依赖容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 10, 6, 10)),
    ],
  );
  // 在启动应用前登记清理，保证断言或启动失败也能释放资源。
  final _SettingsTransitionTestApp app = _SettingsTransitionTestApp(
    container: container,
    database: database,
  );
  addTearDown(() => _disposeSettingsApp(tester, app));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OmniButlerApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  container.read(appRouterProvider).go('/settings');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return app;
}

/// 卸载完整应用后释放订阅、容器与内存数据库。
Future<void> _disposeSettingsApp(
  WidgetTester tester,
  _SettingsTransitionTestApp app,
) async {
  if (app.disposed) {
    return;
  }
  app.disposed = true;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  app.container.dispose();
  await tester.pump(const Duration(milliseconds: 100));
  await app.database.close();
  debugDefaultTargetPlatformOverride = null;
}

/// 验证指定减少动态效果偏好下无需推进时间即可完成进入和返回。
Future<void> _verifyReducedMotionTransitions(
  WidgetTester tester,
  FakeAccessibilityFeatures features,
) async {
  // 当前测试使用的完整应用环境。
  final _SettingsTransitionTestApp app = await _pumpSettingsApp(tester);
  tester.platformDispatcher.accessibilityFeaturesTestValue = features;
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pump();
  await tester.tap(
    find.byKey(const ValueKey<String>('android-settings-category-appearance')),
  );
  await tester.pump();
  expect(
    find.byKey(const ValueKey<String>('android-settings-detail-appearance')),
    findsOneWidget,
  );
  expect(
    find.byKey(const ValueKey<String>('android-settings-overview')),
    findsNothing,
  );
  _expectStationaryCard(tester, 'detail');

  await tester.tap(find.byKey(const ValueKey<String>('android-settings-back')));
  await tester.pump();
  await tester.pump();
  expect(
    find.byKey(const ValueKey<String>('android-settings-overview')),
    findsOneWidget,
  );
  expect(
    find.byKey(
      const ValueKey<String>('android-settings-detail-appearance'),
      skipOffstage: false,
    ),
    findsNothing,
  );
  _expectStationaryCard(tester, 'overview');
  expect(_currentPath(app), '/settings');
  expect(tester.takeException(), isNull);
  await _disposeSettingsApp(tester, app);
}

/// 检查完整落位的页面没有偏移、缩放、圆角或阴影残留。
void _expectStationaryCard(WidgetTester tester, String role) {
  // 当前完整展示页面的缩放变换。
  final Transform scale = tester.widget<Transform>(
    find.byKey(ValueKey<String>('android-settings-$role-scale')),
  );
  // 当前完整展示页面的卡片外观。
  final PhysicalModel card = tester.widget<PhysicalModel>(
    find.byKey(ValueKey<String>('android-settings-$role-card')),
  );
  expect(_cardOffset(tester, role), 0);
  expect(scale.transform.storage[0], 1);
  expect(card.borderRadius, BorderRadius.zero);
  expect(card.elevation, 0);
}

/// 读取卡片实际使用的横向位移比例。
double _cardOffset(WidgetTester tester, String role) {
  return tester
      .widget<FractionalTranslation>(
        find.byKey(ValueKey<String>('android-settings-$role-translation')),
      )
      .translation
      .dx;
}

/// 读取当前完整应用的路由路径。
String _currentPath(_SettingsTransitionTestApp app) {
  return app.container
      .read(appRouterProvider)
      .routeInformationProvider
      .value
      .uri
      .path;
}
