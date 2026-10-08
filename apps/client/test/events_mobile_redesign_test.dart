import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/events/presentation/events_page.dart';
import 'package:omni_butler/features/management/presentation/management_mobile_scaffold.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 验证安卓事件平铺页的查询范围、筛选草稿和原有记录操作。
void main() {
  testWidgets('名称描述搜索只过滤列表且空结果能清除条件', (WidgetTester tester) async {
    // 使用包含活动、未记录和归档事件的独立内存页面。
    await _pumpEvents(tester);
    // 搜索前全部事件统计的胶囊数值。
    final List<String> beforeMetrics = _summaryMetrics(tester);
    expect(beforeMetrics, <String>['1', '2', '2']);
    expect(find.text('更换滤芯'), findsOneWidget);
    expect(find.text('检查药箱'), findsOneWidget);
    expect(find.text('旧证件整理'), findsNothing);

    await tester.enterText(find.byType(TextField), '药箱');
    await tester.pumpAndSettle();
    expect(find.text('检查药箱'), findsOneWidget);
    expect(find.text('更换滤芯'), findsNothing);
    expect(_summaryMetrics(tester), beforeMetrics);

    await tester.enterText(find.byType(TextField), '饮水安全');
    await tester.pumpAndSettle();
    expect(find.text('更换滤芯'), findsOneWidget);
    expect(find.text('检查药箱'), findsNothing);
    expect(_summaryMetrics(tester), beforeMetrics);

    await tester.enterText(find.byType(TextField), '没有此事件');
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的事件'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('event-clear-filters')));
    await tester.pumpAndSettle();
    expect(find.text('更换滤芯'), findsOneWidget);
    expect(find.text('检查药箱'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('归档筛选只有确认才生效且恢复保留原业务行为', (WidgetTester tester) async {
    // 包含归档事件标识的测试夹具。
    final _EventsFixture fixture = await _pumpEvents(tester);
    // 筛选前全部事件统计。
    final List<String> beforeMetrics = _summaryMetrics(tester);
    await _openFilter(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ManagementFilterOption, '已归档'));
    await tester.pumpAndSettle();
    // 使用系统返回取消面板草稿。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('更换滤芯'), findsOneWidget);
    expect(find.text('旧证件整理'), findsNothing);
    expect(
      tester
          .widget<ManagementSearchToolbar>(find.byType(ManagementSearchToolbar))
          .filterCount,
      0,
    );

    await _openFilter(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ManagementFilterOption, '已归档'));
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('旧证件整理'), findsOneWidget);
    expect(find.text('更换滤芯'), findsNothing);
    expect(_summaryMetrics(tester), beforeMetrics);
    expect(
      tester
          .widget<ManagementSearchToolbar>(find.byType(ManagementSearchToolbar))
          .filterCount,
      1,
    );

    await tester.tap(
      find.byKey(ValueKey<String>('event-restore-${fixture.archivedId}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的事件'), findsOneWidget);
    // 恢复后再次清除归档条件即可看到该事件。
    await tester.tap(find.byKey(const ValueKey<String>('event-clear-filters')));
    await tester.pumpAndSettle();
    expect(find.text('旧证件整理'), findsOneWidget);
    expect(_summaryMetrics(tester)[1], '3');
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('平铺行在窄屏大字号下保持可操作且记录支持撤销', (WidgetTester tester) async {
    // 需要检查记录与撤销结果的仓储夹具。
    final _EventsFixture fixture = await _pumpEvents(tester);
    // 当前事件的平铺行。
    final Finder eventRow = find.byKey(
      ValueKey<String>('event-card-${fixture.activeId}'),
    );
    expect(
      find.descendant(of: eventRow, matching: find.byType(OmniPanel)),
      findsNothing,
    );
    // 遍历常见安卓宽度和双倍字号，记录行使用自然高度。
    for (final double width in <double>[320, 360, 390]) {
      tester.view.physicalSize = Size(width, 844);
      await _renderEvents(tester, fixture.container, textScale: 2);
      expect(tester.getRect(eventRow).width, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    }
    await _renderEvents(tester, fixture.container);
    // 操作前的事件完成历史数量。
    final int beforeCount = await _activeHistoryCount(tester, fixture);
    await tester.tap(
      find.byKey(ValueKey<String>('event-record-${fixture.activeId}')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await _activeHistoryCount(tester, fixture), beforeCount + 1);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(await _activeHistoryCount(tester, fixture), beforeCount);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('统计失败明确显示并能重试而不伪造零值', (WidgetTester tester) async {
    // 首次返回错误，重试后提供真实的空历史结果。
    bool failStatistics = true;
    await _pumpEvents(
      tester,
      completionStream: () => failStatistics
          ? Stream<List<EventCompletionRecord>>.error(StateError('测试统计失败'))
          : Stream<List<EventCompletionRecord>>.value(
              <EventCompletionRecord>[],
            ),
    );
    // 错误摘要不提供貌似成功的零值指标。
    final ManagementSummaryLine failed = tester.widget<ManagementSummaryLine>(
      find.byType(ManagementSummaryLine).first,
    );
    expect(failed.error, '事件统计暂时无法读取');
    expect(failed.metrics, isEmpty);
    failStatistics = false;
    failed.onRetry!();
    await tester.pumpAndSettle();
    expect(_summaryMetrics(tester), <String>['1', '2', '0']);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('短屏双倍字号与键盘避让时无搜索结果仍可滚动清除', (WidgetTester tester) async {
    // 使用真实事件数据验证清除后能回到记录列表。
    final _EventsFixture fixture = await _pumpEvents(tester);
    tester.view.physicalSize = const Size(320, 420);
    await _renderEvents(
      tester,
      fixture.container,
      textScale: 2,
      keyboardInset: 180,
    );
    await tester.enterText(find.byType(TextField), '不存在的事件');
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的事件'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 清除操作可能低于短正文视口，必须能通过空态自身滚动抵达。
    final Finder clear = find.byKey(
      const ValueKey<String>('event-clear-filters'),
    );
    await tester.ensureVisible(clear);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的事件'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('短屏双倍字号的首次事件空态可完整滚动阅读', (WidgetTester tester) async {
    // 用真实空事件流覆盖没有建立任何事件的首次进入状态。
    final _EventsFixture fixture = await _pumpEvents(
      tester,
      emptyRecords: true,
    );
    tester.view.physicalSize = const Size(320, 420);
    await _renderEvents(
      tester,
      fixture.container,
      textScale: 2,
      keyboardInset: 180,
    );
    expect(find.text('先建立一个需要反复完成的事件'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 最后一行帮助文字可滚入视口。
    final Finder hint = find.text('例如：更换滤芯、整理账单或复查证件。');
    await tester.ensureVisible(hint);
    await tester.pumpAndSettle();
    expect(hint.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

/// 保存测试所需的容器、仓储和业务标识。
class _EventsFixture {
  /// 当前测试的依赖容器。
  final ProviderContainer container;

  /// 当前测试的事件仓储。
  final EventRepository repository;

  /// 用于记录操作的活动事件标识。
  final String activeId;

  /// 用于恢复操作的归档事件标识。
  final String archivedId;

  /// 创建事件测试夹具。
  const _EventsFixture({
    required this.container,
    required this.repository,
    required this.activeId,
    required this.archivedId,
  });
}

/// 创建固定日期且无需连接用户数据的安卓事件页面。
Future<_EventsFixture> _pumpEvents(
  WidgetTester tester, {
  Stream<List<EventCompletionRecord>> Function()? completionStream,
  bool emptyRecords = false,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  // 独立测试内存数据库。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 写入可验证统计与操作的事件仓储。
  final EventRepository repository = EventRepository(database);
  await repository.save(
    EventDraft(
      name: '更换滤芯',
      description: '检查饮水安全并完成维护',
      intervalValue: 10,
      intervalUnit: EventIntervalUnit.day,
      lastCompletedAt: DateTime(2026, 10, 1, 10),
    ),
  );
  await repository.save(
    const EventDraft(
      name: '检查药箱',
      description: '核对常用药品是否过期',
      intervalValue: 1,
      intervalUnit: EventIntervalUnit.month,
    ),
  );
  await repository.save(
    EventDraft(
      name: '旧证件整理',
      intervalValue: 1,
      intervalUnit: EventIntervalUnit.year,
      lastCompletedAt: DateTime(2026, 10, 2, 10),
    ),
  );
  // 获取保存后生成的标识。
  final List<EventRecord> records = await database
      .select(database.events)
      .get();
  // 需要归档的测试事件。
  final EventRecord archived = records.firstWhere(
    (EventRecord event) => event.name == '旧证件整理',
  );
  await repository.setArchived(archived.id, true);
  // 显式提供数据库和时钟，避免后台系统时间流影响断言。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(DateTime(2026, 10, 8, 10)),
      if (emptyRecords)
        activeEventsProvider.overrideWith(
          (Ref ref) => Stream<List<EventRecord>>.value(<EventRecord>[]),
        ),
      if (completionStream != null)
        activeEventCompletionsProvider.overrideWith(
          (Ref ref) => completionStream(),
        ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await database.close();
  });
  await _renderEvents(tester, container);
  return _EventsFixture(
    container: container,
    repository: repository,
    activeId: records
        .firstWhere((EventRecord event) => event.name == '更换滤芯')
        .id,
    archivedId: archived.id,
  );
}

/// 以固定的页面身份渲染指定字号的安卓事件页。
Future<void> _renderEvents(
  WidgetTester tester,
  ProviderContainer container, {
  double textScale = 1,
  double keyboardInset = 0,
}) async {
  // 通过真实视图指标模拟键盘，保留 Scaffold 对 MediaQuery 的正常消费行为。
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(body: EventsPage(embeddedInManagement: true)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 读取胶囊实际使用的业务数值而不依赖文本拼接方式。
List<String> _summaryMetrics(WidgetTester tester) {
  return tester
      .widget<ManagementSummaryLine>(find.byType(ManagementSummaryLine).first)
      .metrics
      .map((ManagementSummaryMetric metric) => metric.value)
      .toList();
}

/// 通过筛选按钮的真实触控打开底部面板。
Future<void> _openFilter(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('management-filter-button')),
  );
}

/// 读取尚未撤销的真实完成历史数量。
Future<int> _activeHistoryCount(
  WidgetTester tester,
  _EventsFixture fixture,
) async {
  // 历史列表保留撤销轨迹，统计断言只计算有效完成记录。
  final List<EventCompletionRecord> records = (await tester.runAsync(
    () => fixture.repository.watchHistory(fixture.activeId).first,
  ))!;
  return records
      .where((EventCompletionRecord record) => !record.isRevoked)
      .length;
}
