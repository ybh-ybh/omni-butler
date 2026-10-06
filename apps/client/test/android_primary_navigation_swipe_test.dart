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
import 'package:omni_butler/shared/layout/primary_navigation_swipe.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Android 紧凑布局的全局卡片式横滑导航。
void main() {
  test('分页吸附要求慢拖越过半页且快速滑动方向一致', () {
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -194,
        velocity: 0,
        viewportWidth: 390,
        targetDirection: 1,
      ),
      isFalse,
    );
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -195,
        velocity: 0,
        viewportWidth: 390,
        targetDirection: 1,
      ),
      isTrue,
    );
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -20,
        velocity: 600,
        viewportWidth: 390,
        targetDirection: 1,
      ),
      isFalse,
    );
    expect(
      OmniPageSwipePhysics.shouldCommit(
        distance: -20,
        velocity: -600,
        viewportWidth: 390,
        targetDirection: 1,
      ),
      isTrue,
    );
  });

  testWidgets('五个一级页面双向切换且拖动时展示真实卡片动效', (WidgetTester tester) async {
    // 当前测试使用的应用环境。
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    expect(_currentPath(app.container), '/home');

    // 首页上实际参与手势竞争的全局横滑表面。
    final Finder swipeSurface = find.byKey(
      const ValueKey<String>('primary-navigation-swipe-surface'),
    );
    // 当前用于检查跟手中间态的真实触摸手势。
    final TestGesture gesture = await tester.startGesture(
      tester.getTopLeft(swipeSurface) + const Offset(24, 96),
    );
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-72, 0));
    await tester.pump();

    // 当前首页卡片的缩放变换。
    final Transform currentScale = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('primary-navigation-scale-0')),
    );
    // 正在进入的待办卡片缩放变换。
    final Transform targetScale = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('primary-navigation-scale-1')),
    );
    // 当前首页卡片的物理外观。
    final PhysicalModel currentCard = tester.widget<PhysicalModel>(
      find.byKey(const ValueKey<String>('primary-navigation-card-0')),
    );
    expect(currentScale.transform.storage[0], lessThan(1));
    expect(currentScale.transform.storage[0], greaterThan(0.985));
    expect(targetScale.transform.storage[0], greaterThan(0.985));
    expect(currentCard.elevation, greaterThan(0));
    expect(currentCard.borderRadius, isNot(BorderRadius.zero));
    expect(_currentPath(app.container), '/home');

    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/todos');

    // 通过协调器继续验证完整的正向一级页面顺序。
    for (final String expectedPath in <String>[
      '/timeline',
      '/inventory',
      '/settings',
    ]) {
      await _swipePrimary(tester, -220);
      expect(_currentPath(app.container), expectedPath);
    }
    // 更多页到达末端后不会循环回首页。
    await _swipePrimary(tester, -220);
    expect(_currentPath(app.container), '/settings');

    // 反向依次返回管理、时间、待办和首页。
    for (final String expectedPath in <String>[
      '/inventory',
      '/timeline',
      '/todos',
      '/home',
    ]) {
      await _swipePrimary(tester, 220);
      expect(_currentPath(app.container), expectedPath);
    }
    // 首页到达首端后不会循环到更多页。
    await _swipePrimary(tester, 220);
    expect(_currentPath(app.container), '/home');

    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('短拖回弹、底栏同款动画并跳过已关闭入口', (WidgetTester tester) async {
    // 当前测试使用的应用环境，只保留首页、管理和更多入口。
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
      preferences: <String, Object>{
        'appearance.theme_mode': 'light',
        'features.todos.enabled': false,
        'features.timeline.enabled': false,
      },
    );

    await _swipePrimary(tester, -20);
    expect(_currentPath(app.container), '/home');
    await _swipePrimary(tester, -10, velocity: -600);
    expect(_currentPath(app.container), '/inventory');

    await tester.tap(
      find.byKey(const ValueKey<String>('navigation-/settings')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-scale-3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-scale-4')),
      findsOneWidget,
    );
    expect(_currentPath(app.container), '/inventory');
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/settings');

    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('一级页面吸附逐帧匹配原生分页且连续拖动不跳回', (WidgetTester tester) async {
    // 当前测试使用的完整 Android 应用。
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    // 页面真实手势使用的一级横滑控制器。
    final PrimaryNavigationSwipeController controller = _primaryController(
      tester,
    );
    // 统计卡片原生分页在同样距离和离手速度下的参考轨迹。
    final Simulation reference = const PageScrollPhysics()
        .createBallisticSimulation(
          FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 390,
            pixels: 120,
            viewportDimension: 390,
            axisDirection: AxisDirection.right,
            devicePixelRatio: 1,
          ),
          900,
        )!;
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(-120);
    controller.endPrimarySwipe(-900);
    await tester.pump();

    // 逐帧累计时间，用于与原生弹簧的秒数对齐。
    int elapsedMilliseconds = 0;
    // 松手后早期、中段和接近落位的采样间隔。
    for (final int deltaMilliseconds in <int>[16, 84, 200]) {
      elapsedMilliseconds += deltaMilliseconds;
      await tester.pump(Duration(milliseconds: deltaMilliseconds));
      expect(
        _primaryOffset(tester, 0),
        closeTo(-reference.x(elapsedMilliseconds / 1000), 0.01),
      );
    }
    expect(_currentPath(app.container), '/home');

    // 尚未结束的弹簧位置应成为下一次拖动起点。
    final double interruptedOffset = _primaryOffset(tester, 0);
    controller.beginPrimarySwipe();
    await tester.pump();
    expect(_primaryOffset(tester, 0), closeTo(interruptedOffset, 0.01));
    controller.updatePrimarySwipe(12);
    await tester.pump();
    expect(_primaryOffset(tester, 0), closeTo(interruptedOffset + 12, 0.01));
    controller.endPrimarySwipe(900);
    await tester.pumpAndSettle();
    expect(_currentPath(app.container), '/home');
    expect(_primaryOffset(tester, 0), 0);

    // 临近终点高速甩动不能越界露白，也不能留下未完成的路由切换。
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(-380);
    controller.endPrimarySwipe(-8000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_currentPath(app.container), '/todos');
    expect(_primaryOffset(tester, 1), 0);
    await tester.pumpAndSettle();

    // 反向拖过半页后向原页甩回，原生落点应取消提交。
    await _swipePrimary(tester, 220, velocity: -900);
    expect(_currentPath(app.container), '/todos');
    await _swipePrimary(tester, 120, velocity: 900);
    expect(_currentPath(app.container), '/home');

    // 已经完整到位时，即便离手反向也应原地提交，不能先退回再吸附。
    controller.beginPrimarySwipe();
    controller.updatePrimarySwipe(-390);
    controller.endPrimarySwipe(600);
    await tester.pump();
    expect(_currentPath(app.container), '/todos');
    expect(_primaryOffset(tester, 1), 0);
    await _disposePrimaryNavigationApp(tester, app);
  });

  testWidgets('系统减少动态效果时立即切页且不保留卡片装饰', (WidgetTester tester) async {
    // 当前测试使用的应用环境。
    final _PrimaryNavigationTestApp app = await _pumpPrimaryNavigationApp(
      tester,
    );
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();

    app.container.read(appRouterProvider).go('/settings');
    await tester.pump();

    // 减弱动效后的完整目标卡片。
    final PhysicalModel card = tester.widget<PhysicalModel>(
      find.byKey(const ValueKey<String>('primary-navigation-card-4')),
    );
    // 减弱动效后的目标缩放变换。
    final Transform scale = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('primary-navigation-scale-4')),
    );
    expect(_currentPath(app.container), '/settings');
    expect(scale.transform.storage[0], 1);
    expect(card.elevation, 0);
    expect(card.borderRadius, BorderRadius.zero);
    expect(
      find.byKey(const ValueKey<String>('primary-navigation-scale-0')),
      findsNothing,
    );

    await _disposePrimaryNavigationApp(tester, app);
  });
}

/// 单个全局导航测试持有的依赖容器与内存数据库。
class _PrimaryNavigationTestApp {
  /// 当前应用的依赖容器。
  final ProviderContainer container;

  /// 当前应用的内存数据库。
  final AppDatabase database;

  /// 当前测试环境是否已经完成释放。
  bool disposed = false;

  /// 创建全局导航测试环境。
  _PrimaryNavigationTestApp({required this.container, required this.database});
}

/// 启动使用 Android 紧凑视口的完整应用。
Future<_PrimaryNavigationTestApp> _pumpPrimaryNavigationApp(
  WidgetTester tester, {
  Map<String, Object> preferences = const <String, Object>{
    'appearance.theme_mode': 'light',
  },
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(preferences);
  // 测试用主题与功能偏好存储。
  final SharedPreferences sharedPreferences =
      await SharedPreferences.getInstance();
  // 测试用内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 显式管理的应用依赖容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 10, 1, 10)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OmniButlerApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  // 已经启动完成的测试环境。
  final _PrimaryNavigationTestApp app = _PrimaryNavigationTestApp(
    container: container,
    database: database,
  );
  addTearDown(() => _disposePrimaryNavigationApp(tester, app));
  return app;
}

/// 释放预载页面订阅、依赖容器和内存数据库。
Future<void> _disposePrimaryNavigationApp(
  WidgetTester tester,
  _PrimaryNavigationTestApp app,
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

/// 返回当前页面树中的一级横滑协调器。
PrimaryNavigationSwipeController _primaryController(WidgetTester tester) {
  // 当前一级横滑作用域。
  final PrimaryNavigationSwipeScope scope = tester
      .widget<PrimaryNavigationSwipeScope>(
        find.byType(PrimaryNavigationSwipeScope),
      );
  return scope.controller;
}

/// 读取指定一级页面真实绘制的横向位移。
double _primaryOffset(WidgetTester tester, int index) {
  return tester
      .widget<Transform>(
        find.byKey(ValueKey<String>('primary-navigation-translation-$index')),
      )
      .transform
      .storage[12];
}

/// 使用累计距离执行一次一级页面横滑并等待落位。
Future<void> _swipePrimary(
  WidgetTester tester,
  double distance, {
  double velocity = 0,
}) async {
  // 本次横滑使用的一级导航协调器。
  final PrimaryNavigationSwipeController controller = _primaryController(
    tester,
  );
  controller.beginPrimarySwipe();
  controller.updatePrimarySwipe(distance);
  controller.endPrimarySwipe(velocity);
  await tester.pumpAndSettle();
}

/// 返回当前路由路径。
String _currentPath(ProviderContainer container) {
  return container
      .read(appRouterProvider)
      .routeInformationProvider
      .value
      .uri
      .path;
}
