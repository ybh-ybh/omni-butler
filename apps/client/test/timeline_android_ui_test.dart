import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_review.dart';
import 'package:omni_butler/features/timeline/presentation/timeline_page.dart';
import 'package:omni_butler/shared/ui/omni_date_time_picker.dart';
import 'package:omni_butler/shared/ui/omni_page_header.dart';
import 'package:omni_butler/shared/ui/omni_sliding_segmented_control.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Android 紧凑时间页的滑块与悬浮直接操作组。
void main() {
  testWidgets('Android 时间页使用顶部滑块和底部直接操作组', (WidgetTester tester) async {
    // 测试使用的时间页上下文。
    final _TimelineAndroidTestContext testContext = await _pumpAndroidTimeline(
      tester,
    );
    // 页面模式滑块。
    final Finder viewControl = find.byKey(
      const ValueKey<String>('timeline-view-mode'),
    );
    // Android 时间页悬浮直接操作组。
    final Finder actionGroup = find.byKey(
      const ValueKey<String>('timeline-mobile-actions'),
    );
    // 直接开始或结束记录的主操作。
    final Finder primaryButton = find.byKey(
      const ValueKey<String>('timeline-mobile-create'),
    );
    // 仅管理分类的更多入口。
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
    expect(tester.getSize(actionGroup).height, OmniSize.touch);
    expect(
      find.descendant(
        of: primaryButton,
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: primaryButton, matching: find.text('开始记录')),
      findsOneWidget,
    );
    // 底部导航栏的实际位置。
    final Rect navigationRect = tester.getRect(
      find.byKey(const ValueKey<String>('navigation-/timeline')),
    );
    expect(tester.getRect(actionGroup).bottom, lessThan(navigationRect.top));
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
    expect(
      find.byKey(const ValueKey<String>('omni-expandable-sheet-surface')),
      findsOneWidget,
    );
    expect(find.text('开始时间'), findsNothing);
    expect(find.text('详细描述（可选）'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('time-entry-start-submit')),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 补记直接可达，不需要先展开更多菜单。
    await tester.tap(
      find.byKey(const ValueKey<String>('timeline-mobile-backfill')),
    );
    await tester.pumpAndSettle();
    expect(find.text('补记'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    // 时间页根模态覆盖底部导航，取消后回到原有页面。
    expect(
      tester.getSize(find.byType(Dialog)),
      tester.view.physicalSize / tester.view.devicePixelRatio,
    );
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(moreActionsButton);
    await tester.pumpAndSettle();
    expect(find.text('分类'), findsOneWidget);
    expect(find.text('补记时间'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('timeline-mobile-categories')),
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
    // 直接开始或结束记录的主操作。
    final Finder primaryButton = find.byKey(
      const ValueKey<String>('timeline-mobile-create'),
    );

    expect(find.text('结束记录'), findsOneWidget);
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
    expect(
      find.descendant(of: primaryButton, matching: find.text('开始记录')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('ongoing-time-entry-banner')),
      findsNothing,
    );

    await testContext.dispose(tester);
  });

  testWidgets('多条进行中记录保留冲突说明和逐条结束入口', (WidgetTester tester) async {
    // 同步冲突样例使用内存库直接插入，模拟另一端产生的进行中记录。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 固定时刻用于结束弹窗默认值。
    final DateTime now = DateTime(2026, 9, 10, 10, 20);
    // 先通过生产仓储创建一条合法记录。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    await repository.save(
      TimeEntryDraft(
        startedAt: now.subtract(const Duration(hours: 1)),
        activity: '第一条记录',
      ),
    );
    // 复制实际数据库行作为同步产生的第二条记录。
    final TimeEntryRecord first = await database
        .select(database.timeEntries)
        .getSingle();
    await database
        .into(database.timeEntries)
        .insert(
          first.copyWith(
            id: 'sync-conflict',
            startedAt: now.subtract(const Duration(hours: 2)),
            startMinute: 500,
          ),
        );
    // 保持完整应用路由，验证窄屏冲突说明和按钮可达。
    final _TimelineAndroidTestContext testContext = await _pumpAndroidTimeline(
      tester,
      database: database,
      now: now,
    );
    // 冲突条内的独立逐条处理入口。
    final Finder banner = find.byKey(
      const ValueKey<String>('ongoing-time-entry-banner'),
    );
    expect(find.textContaining('检测到 2 条进行中记录'), findsOneWidget);
    expect(find.text('结束记录'), findsNWidgets(2));
    await tester.tap(find.descendant(of: banner, matching: find.text('结束记录')));
    await tester.pumpAndSettle();
    expect(find.text('结束并保存'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await testContext.dispose(tester);
  });

  testWidgets('Windows窄宽往返保留月复盘和所选日期', (WidgetTester tester) async {
    // Windows保留桌面密度，并在尺寸变化中保活模式状态。
    final _TimelineAndroidTestContext testContext = await _pumpAndroidTimeline(
      tester,
      platform: TargetPlatform.windows,
      viewport: const Size(1440, 900),
    );
    await tester.tap(find.text('月').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一周期'));
    await tester.pumpAndSettle();
    // 缩放前选中的日期不得被重建工具栏覆盖。
    final DateTime? selected = tester
        .widget<OmniDatePickerButton>(
          find.byKey(const ValueKey<String>('timeline-date-picker')),
        )
        .value;
    for (final Size size in <Size>[
      const Size(512, 512),
      const Size(1440, 900),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OmniDatePickerButton>(
              find.byKey(const ValueKey<String>('timeline-date-picker')),
            )
            .value,
        selected,
      );
      expect(
        find.byKey(const ValueKey<String>('timeline-month-fingerprint')),
        findsOneWidget,
      );
      expect(
        find
            .byKey(const ValueKey<String>('timeline-desktop-backfill'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find
            .byKey(const ValueKey<String>('timeline-period-control'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    await testContext.dispose(tester);
  });

  testWidgets('Android周期菜单与日期导航保留选择，明细保留时长摘要', (WidgetTester tester) async {
    // 使用生产路由验证周期、日期和模式的联动。
    final _TimelineAndroidTestContext testContext = await _pumpAndroidTimeline(
      tester,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('timeline-period-menu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('月').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('timeline-month-fingerprint')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('上一周期'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OmniDatePickerButton>(
            find.byKey(const ValueKey<String>('timeline-date-picker')),
          )
          .value,
      DateTime(2026, 8, 1),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('timeline-view-mode-details')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('timeline-period-menu')),
      findsNothing,
    );
    expect(find.text('已记录'), findsOneWidget);
    expect(find.text('空白时间'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('timeline-view-mode-review')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('timeline-month-fingerprint')),
      findsOneWidget,
    );
    expect(find.text('已记录'), findsNothing);
    expect(find.text('主要投入'), findsNothing);
    expect(find.text('平均每段'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('timeline-current-shortcut')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OmniDatePickerButton>(
            find.byKey(const ValueKey<String>('timeline-date-picker')),
          )
          .value,
      DateTime(2026, 9, 10),
    );
    expect(tester.takeException(), isNull);
    await testContext.dispose(tester);
  });

  for (final (TargetPlatform, Size, double) scenario
      in <(TargetPlatform, Size, double)>[
        (TargetPlatform.windows, const Size(1440, 900), 1),
        (TargetPlatform.windows, const Size(1024, 768), 1),
        (TargetPlatform.windows, const Size(640, 720), 1),
        (TargetPlatform.windows, const Size(512, 512), 1),
        (TargetPlatform.android, const Size(320, 844), 2),
        (TargetPlatform.android, const Size(719, 844), 1),
        (TargetPlatform.android, const Size(720, 844), 1),
      ]) {
    testWidgets(
      '时间页 ${scenario.$1.name} ${scenario.$2.width} 字号${scenario.$3} 所有操作可达',
      (WidgetTester tester) async {
        // 各边界独立挂载真实应用，保留平台实际控件密度。
        final _TimelineAndroidTestContext testContext =
            await _pumpAndroidTimeline(
              tester,
              viewport: scenario.$2,
              platform: scenario.$1,
              textScale: scenario.$3,
            );
        // 根据平台布局选择顶部或悬浮操作组。
        final String prefix =
            scenario.$1 == TargetPlatform.android && scenario.$2.width < 720
            ? 'timeline-mobile'
            : 'timeline-desktop';
        expect(
          find.byKey(ValueKey<String>('$prefix-backfill')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey<String>('$prefix-create')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey<String>('$prefix-more-actions')).hitTestable(),
          findsOneWidget,
        );
        expect(find.byTooltip('上一周期').hitTestable(), findsOneWidget);
        expect(find.byTooltip('下一周期').hitTestable(), findsOneWidget);
        expect(
          find
              .byKey(const ValueKey<String>('timeline-current-shortcut'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(
          find
              .byKey(
                ValueKey<String>(
                  prefix == 'timeline-mobile'
                      ? 'timeline-period-menu'
                      : 'timeline-period-control',
                ),
              )
              .hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (prefix == 'timeline-mobile') {
          // 大字号下实测操作组可以换行，滚动末尾仍能越过悬浮操作。
          final Rect actionRect = tester.getRect(
            find.byKey(ValueKey<String>('$prefix-actions')),
          );
          final Finder scrollView = find.byKey(
            const ValueKey<String>('timeline-review-content'),
          );
          await tester.drag(scrollView, const Offset(0, -3000));
          await tester.pumpAndSettle();
          final Rect trendRect = tester.getRect(
            find.byKey(const ValueKey<String>('timeline-daily-trend')),
          );
          expect(trendRect.bottom, lessThanOrEqualTo(actionRect.top));
          // 极窄大字号同时覆盖月历和单日明细的自然排版。
          if (scenario.$3 == 2) {
            await tester.tap(
              find.byKey(const ValueKey<String>('timeline-period-menu')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('月').last);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.tap(
              find.byKey(const ValueKey<String>('timeline-view-mode-details')),
            );
            await tester.pumpAndSettle();
            expect(find.text('已记录'), findsOneWidget);
            expect(find.text('空白时间'), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        }
        await testContext.dispose(tester);
      },
    );
  }

  testWidgets('跨宽窄布局保留日期、模式和周期，所有入口持续可达', (WidgetTester tester) async {
    // Android在719/720阈值切换时复用页面状态。
    final _TimelineAndroidTestContext testContext = await _pumpAndroidTimeline(
      tester,
      viewport: const Size(719, 844),
    );
    await tester.tap(find.byTooltip('上一周期'));
    await tester.pumpAndSettle();
    // 保存切换宽度前的日期，不能被新布局重置。
    final DateTime? selected = tester
        .widget<OmniDatePickerButton>(
          find.byKey(const ValueKey<String>('timeline-date-picker')),
        )
        .value;
    for (final double width in <double>[720, 719, 1024, 390]) {
      tester.view.physicalSize = Size(width, 844);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OmniDatePickerButton>(
              find.byKey(const ValueKey<String>('timeline-date-picker')),
            )
            .value,
        selected,
      );
      expect(
        find.byKey(const ValueKey<String>('timeline-week-fingerprint')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    await testContext.dispose(tester);
  });
}

/// 创建并打开 Android 紧凑时间页。
Future<_TimelineAndroidTestContext> _pumpAndroidTimeline(
  WidgetTester tester, {
  AppDatabase? database,
  DateTime? now,
  Size viewport = const Size(390, 844),
  TargetPlatform platform = TargetPlatform.android,
  double textScale = 1,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = viewport;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
  // 极窄大字号单独验证时间页，避免预载首页的既有溢出影响本页证据。
  final bool isolated = viewport.width == 320 && textScale == 2;
  if (!isolated) container.read(appRouterProvider).go('/timeline');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: isolated
          ? MaterialApp(
              theme: AppTheme.build(brightness: Brightness.light)
                  .copyWith(platform: platform),
              home: const TimelinePage(),
            )
          : const OmniButlerApp(),
    ),
  );
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
