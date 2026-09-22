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
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证时间复盘页面的核心信息层级和视觉基线。
void main() {
  testWidgets('桌面时间复盘优先展示多维统计并保留明细入口', (WidgetTester tester) async {
    // 桌面视觉基线尺寸。
    const Size viewport = Size(1440, 900);
    // 测试使用的稳定当前时间。
    final DateTime now = DateTime(2026, 9, 10, 18, 30);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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
    // 用于准备本周和上周数据的时间仓储。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    await _seedTimelineRecords(repository);
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
    await tester.pump();
    container.read(appRouterProvider).go('/timeline');
    await tester.pumpAndSettle();

    expect(find.text('时间管理'), findsWidgets);
    expect(find.text('看清时间去了哪里，也看见它如何变化'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('timeline-review-content')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('timeline-fingerprint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('timeline-category-structure')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('timeline-entry-list')),
      findsNothing,
    );
    // 底部两张统计卡片应保持等高。
    // 类别结构卡片的全局位置。
    final Rect categoryRect = tester.getRect(
      find.byKey(const ValueKey<String>('timeline-category-structure')),
    );
    // 记录趋势卡片的全局位置。
    final Rect trendRect = tester.getRect(
      find.byKey(const ValueKey<String>('timeline-daily-trend')),
    );
    expect(categoryRect.height, closeTo(trendRect.height, 0.01));

    tester.view.physicalSize = const Size(1440, 1100);
    await tester.pumpAndSettle();
    // 高视口下复盘滚动区的全局位置。
    final Rect filledReviewRect = tester.getRect(
      find.byKey(const ValueKey<String>('timeline-review-content')),
    );
    // 高视口下类别结构卡片的全局位置。
    final Rect filledCategoryRect = tester.getRect(
      find.byKey(const ValueKey<String>('timeline-category-structure')),
    );
    // 高视口下记录趋势卡片的全局位置。
    final Rect filledTrendRect = tester.getRect(
      find.byKey(const ValueKey<String>('timeline-daily-trend')),
    );
    expect(filledCategoryRect.height, closeTo(filledTrendRect.height, 0.01));
    expect(filledCategoryRect.bottom, closeTo(filledReviewRect.bottom, 0.01));
    tester.view.physicalSize = viewport;
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/timeline_review_light_1440x900.png'),
    );

    await tester.tap(find.text('月'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('timeline-month-fingerprint')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('日').first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('timeline-day-fingerprint')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('记录明细'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('timeline-details-content')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('timeline-day-board')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('timeline-entry-list')),
      findsOneWidget,
    );
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/timeline_details_light_1440x900.png'),
    );
    // 当前 24 小时时间轴的全局位置。
    final Rect dayBoardRect = tester.getRect(
      find.byKey(const ValueKey<String>('timeline-day-board')),
    );
    await tester.tapAt(
      Offset(dayBoardRect.left + 180, dayBoardRect.bottom - 28),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('移动端时间复盘保持单列统计层级', (WidgetTester tester) async {
    // 移动端视觉基线尺寸。
    const Size viewport = Size(390, 844);
    // 测试使用的稳定当前时间。
    final DateTime now = DateTime(2026, 9, 10, 18, 30);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
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
    // 用于准备本周和上周数据的时间仓储。
    final TimeEntryRepository repository = TimeEntryRepository(database);
    await _seedTimelineRecords(repository);
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
    await tester.pump();
    container.read(appRouterProvider).go('/timeline');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('timeline-review-content')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('timeline-fingerprint')),
      findsOneWidget,
    );
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/timeline_review_light_390x844.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}

/// 写入能够呈现多类别、跨日与周期对比的测试记录。
Future<void> _seedTimelineRecords(TimeEntryRepository repository) async {
  // 待写入的时间记录草稿。
  final List<TimeEntryDraft> drafts = <TimeEntryDraft>[
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 7),
      startMinute: 0,
      endMinute: 450,
      activity: '睡眠',
      category: '休息',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 7),
      startMinute: 540,
      endMinute: 720,
      activity: '项目开发',
      category: '工作',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 7),
      startMinute: 840,
      endMinute: 1020,
      activity: '学习 Text2SQL',
      category: '学习',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 8),
      startMinute: 30,
      endMinute: 480,
      activity: '睡眠',
      category: '休息',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 8),
      startMinute: 570,
      endMinute: 720,
      activity: '项目开发',
      category: '工作',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 8),
      startMinute: 1140,
      endMinute: 1230,
      activity: '散步',
      category: '运动',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 9),
      startMinute: 120,
      endMinute: 660,
      activity: '睡眠',
      category: '休息',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 9),
      startMinute: 900,
      endMinute: 1080,
      activity: '学习 Flutter',
      category: '学习',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 10),
      startMinute: 140,
      endMinute: 660,
      activity: '睡眠',
      category: '休息',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 10),
      startMinute: 660,
      endMinute: 840,
      activity: '学习 Text2SQL',
      category: '学习',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 10),
      startMinute: 900,
      endMinute: 960,
      activity: '午睡',
      category: '休息',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 9, 10),
      startMinute: 1080,
      endMinute: 1170,
      activity: '吃饭',
      category: '其他',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 8, 31),
      startMinute: 540,
      endMinute: 690,
      activity: '项目开发',
      category: '工作',
    ),
    TimeEntryDraft(
      entryDate: DateTime(2026, 8, 31),
      startMinute: 840,
      endMinute: 930,
      activity: '学习',
      category: '学习',
    ),
  ];
  for (final TimeEntryDraft draft in drafts) {
    await repository.save(draft);
  }
}
