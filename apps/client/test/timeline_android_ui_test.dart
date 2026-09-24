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
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_review.dart';
import 'package:omni_butler/shared/ui/omni_page_header.dart';
import 'package:omni_butler/shared/ui/omni_sliding_segmented_control.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Android 紧凑时间页的滑块与悬浮拆分按钮。
void main() {
  testWidgets('Android 时间页使用顶部滑块和右下角拆分按钮', (WidgetTester tester) async {
    // 测试使用的时间页上下文。
    final _TimelineAndroidTestContext testContext = await _pumpAndroidTimeline(
      tester,
    );
    // 页面模式滑块。
    final Finder viewControl = find.byKey(
      const ValueKey<String>('timeline-view-mode'),
    );
    // Android 时间页悬浮拆分按钮。
    final Finder splitButton = find.byKey(
      const ValueKey<String>('timeline-mobile-create-split'),
    );
    // 拆分按钮主操作。
    final Finder primaryButton = find.byKey(
      const ValueKey<String>('timeline-mobile-create'),
    );
    // 拆分按钮菜单入口。
    final Finder moreActionsButton = find.byKey(
      const ValueKey<String>('timeline-mobile-more-actions'),
    );

    expect(find.byType(OmniPageHeader), findsNothing);
    expect(find.text('时间管理'), findsNothing);
    expect(
      find.byType(OmniSlidingSegmentedControl<TimelineViewMode>),
      findsOneWidget,
    );
    expect(tester.getSize(viewControl).height, OmniSize.touch);
    expect(tester.getSize(viewControl).width, closeTo(374, 0.1));
    expect(
      find.descendant(
        of: viewControl,
        matching: find.byIcon(Icons.insights_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: viewControl,
        matching: find.byIcon(Icons.view_timeline_outlined),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(splitButton).height, OmniSize.touch);
    expect(
      find.descendant(
        of: primaryButton,
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsOneWidget,
    );
    // 底部导航栏的实际位置。
    final Rect navigationRect = tester.getRect(
      find.byKey(const ValueKey<String>('navigation-/timeline')),
    );
    expect(tester.getRect(splitButton).bottom, lessThan(navigationRect.top));
    // 时间复盘滚动视口应填满到底部导航栏上方。
    final Rect reviewViewportRect = tester.getRect(
      find.byKey(const ValueKey<String>('timeline-review-content')),
    );
    expect(reviewViewportRect.bottom, closeTo(navigationRect.top, 1.1));
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('timeline-view-mode-details')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('timeline-details-content')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(const ValueKey<String>('timeline-view-mode-review')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('timeline-review-content')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(primaryButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(moreActionsButton);
    await tester.pumpAndSettle();
    // Android 时间页次要操作菜单。
    Finder actionsMenu = find.byKey(
      const ValueKey<String>('timeline-mobile-actions-menu'),
    );
    expect(actionsMenu, findsOneWidget);
    expect(
      find.descendant(of: actionsMenu, matching: find.byType(Divider)),
      findsOneWidget,
    );
    // 补记时间菜单项的实际位置。
    final Rect backfillRect = tester.getRect(
      find.descendant(of: actionsMenu, matching: find.text('补记时间')),
    );
    // 分类菜单项的实际位置。
    final Rect categoriesRect = tester.getRect(
      find.descendant(of: actionsMenu, matching: find.text('分类')),
    );
    expect(backfillRect.top, lessThan(categoriesRect.top));
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.descendant(of: actionsMenu, matching: find.text('补记时间')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(moreActionsButton);
    await tester.pumpAndSettle();
    actionsMenu = find.byKey(
      const ValueKey<String>('timeline-mobile-actions-menu'),
    );
    await tester.tap(
      find.descendant(of: actionsMenu, matching: find.text('分类')),
    );
    await tester.pumpAndSettle();
    expect(find.text('时间分类'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await testContext.dispose(tester);
  });

  testWidgets('Android 时间页在记录进行中切换为结束主操作', (WidgetTester tester) async {
    // 测试固定当前时间。
    final DateTime now = DateTime(2026, 9, 10, 10, 20);
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 测试用时间仓储。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    await repository.save(
      TimeEntryDraft(startedAt: now.subtract(const Duration(hours: 1))),
    );
    // 测试使用的时间页上下文。
    final _TimelineAndroidTestContext testContext = await _pumpAndroidTimeline(
      tester,
      database: database,
      now: now,
    );
    // 拆分按钮主操作。
    final Finder primaryButton = find.byKey(
      const ValueKey<String>('timeline-mobile-create'),
    );

    expect(find.text('结束记录'), findsWidgets);
    expect(
      find.descendant(
        of: primaryButton,
        matching: find.byIcon(Icons.stop_rounded),
      ),
      findsOneWidget,
    );
    await tester.tap(primaryButton);
    await tester.pumpAndSettle();
    expect(find.text('结束并保存'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '例如：睡眠、学习 Text2SQL'),
      '专注工作',
    );
    await tester.tap(find.text('结束并保存'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: primaryButton,
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsOneWidget,
    );
    expect(find.text('开始记录'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('ongoing-time-entry-banner')),
      findsNothing,
    );

    await testContext.dispose(tester);
  });
}

/// 创建并打开 Android 紧凑时间页。
Future<_TimelineAndroidTestContext> _pumpAndroidTimeline(
  WidgetTester tester, {
  AppDatabase? database,
  DateTime? now,
}) async {
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
  // 当前测试实际使用的数据库。
  final AppDatabase activeDatabase =
      database ?? AppDatabase.forTesting(NativeDatabase.memory());
  // 当前测试固定时间。
  final DateTime activeNow = now ?? DateTime(2026, 9, 10, 10, 20);
  // 显式管理的测试依赖容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(activeDatabase),
      nowProvider.overrideWithValue(activeNow),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OmniButlerApp(),
    ),
  );
  await tester.pump();
  container.read(appRouterProvider).go('/timeline');
  await tester.pumpAndSettle();
  return _TimelineAndroidTestContext(
    database: activeDatabase,
    container: container,
  );
}

/// Android 时间页 Widget 测试持有的资源。
class _TimelineAndroidTestContext {
  /// 测试数据库。
  final AppDatabase database;

  /// Riverpod 容器。
  final ProviderContainer container;

  /// 创建 Android 时间页测试上下文。
  const _TimelineAndroidTestContext({
    required this.database,
    required this.container,
  });

  /// 释放测试资源。
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  }
}
