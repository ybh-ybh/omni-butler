import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证居中弹窗、跨天时间与进行中记录闭环。
void main() {
  testWidgets('补记时间使用居中弹窗并允许跨天保存', (WidgetTester tester) async {
    // 测试上下文。
    final _TimelineTestContext testContext = await _pumpTimeline(tester);
    await tester.tap(find.text('补记时间'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      findsOneWidget,
    );
    expect(find.text('开始日期'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('time-range-slider')),
      findsOneWidget,
    );
    await expectLater(
      find.byKey(const ValueKey<String>('time-entry-editor')),
      matchesGoldenFile('goldens/timeline_editor_light_1440x900.png'),
    );

    // 双手柄滑动条逐段扩展到次日，并选择 22:00 到次日 07:00。
    RangeSlider slider = tester.widget<RangeSlider>(
      find.byKey(const ValueKey<String>('time-range-slider')),
    );
    slider.onChanged!(const RangeValues(620, 980));
    await tester.pumpAndSettle();
    slider = tester.widget<RangeSlider>(
      find.byKey(const ValueKey<String>('time-range-slider')),
    );
    slider.onChanged!(const RangeValues(960, 1340));
    await tester.pumpAndSettle();
    slider = tester.widget<RangeSlider>(
      find.byKey(const ValueKey<String>('time-range-slider')),
    );
    slider.onChanged!(const RangeValues(1320, 1700));
    await tester.pumpAndSettle();
    slider = tester.widget<RangeSlider>(
      find.byKey(const ValueKey<String>('time-range-slider')),
    );
    slider.onChanged!(const RangeValues(1320, 1860));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '例如：睡眠、学习 Text2SQL'),
      '睡眠',
    );
    expect(find.textContaining('跨天记录'), findsOneWidget);
    await tester.tap(find.text('保存记录'));
    await tester.pumpAndSettle();

    // 保存后的逻辑记录。
    final TimeEntryRecord record = await testContext.database
        .select(testContext.database.timeEntries)
        .getSingle();
    expect(record.startedAt, DateTime(2026, 9, 10, 22));
    expect(record.endedAt, DateTime(2026, 9, 11, 7));
    expect(record.endMinute, 31 * 60);

    await testContext.dispose(tester);
  });

  testWidgets('开始记录可留空活动并在结束时补全', (WidgetTester tester) async {
    // 测试上下文。
    final _TimelineTestContext testContext = await _pumpTimeline(tester);
    await tester.tap(find.text('开始记录'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('结束时间'), findsNothing);
    expect(find.textContaining('关闭应用也不会丢失'), findsOneWidget);
    await tester.tap(find.text('开始记录').last);
    await tester.pumpAndSettle();

    // 页面出现持久化的进行中提示条。
    expect(
      find.byKey(const ValueKey<String>('ongoing-time-entry-banner')),
      findsOneWidget,
    );
    expect(find.text('结束记录'), findsWidgets);
    // 当前进行中记录。
    TimeEntryRecord record = await testContext.database
        .select(testContext.database.timeEntries)
        .getSingle();
    expect(record.endedAt, isNull);
    expect(record.activity, isNull);

    await tester.tap(find.text('结束记录').last);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '例如：睡眠、学习 Text2SQL'),
      '深度工作',
    );
    await tester.tap(find.text('结束并保存'));
    await tester.pumpAndSettle();

    record = await testContext.database
        .select(testContext.database.timeEntries)
        .getSingle();
    expect(record.endedAt, isNotNull);
    expect(record.activity, '深度工作');
    expect(
      find.byKey(const ValueKey<String>('ongoing-time-entry-banner')),
      findsNothing,
    );

    await testContext.dispose(tester);
  });
}

/// 创建并打开时间管理页面。
Future<_TimelineTestContext> _pumpTimeline(WidgetTester tester) async {
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
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 稳定当前时间。
  final DateTime now = DateTime(2026, 9, 10, 10, 20);
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
  return _TimelineTestContext(
    database: database,
    container: container,
    today: DateUtils.dateOnly(now),
  );
}

/// 单个 Widget 测试持有的资源。
class _TimelineTestContext {
  /// 测试数据库。
  final AppDatabase database;

  /// Riverpod 容器。
  final ProviderContainer container;

  /// 稳定的当天日期。
  final DateTime today;

  /// 创建测试上下文。
  const _TimelineTestContext({
    required this.database,
    required this.container,
    required this.today,
  });

  /// 释放测试资源。
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
  }
}
