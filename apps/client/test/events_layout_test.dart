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
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证事件管理页的单双列布局与周期时间条。
void main() {
  testWidgets('宽屏默认双列并可切换为单列', (WidgetTester tester) async {
    // 固定的业务当前时间。
    final DateTime now = DateTime(2026, 9, 6, 10);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(database.close);
    // 测试用事件仓储。
    final EventRepository repository = EventRepository(database);
    await repository.save(
      EventDraft(
        name: '更换净水滤芯',
        category: '家务',
        description: '检查滤芯状态并完成更换',
        intervalValue: 10,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: DateTime(2026, 8, 31, 10),
      ),
    );
    await repository.save(
      const EventDraft(
        name: '整理证件',
        intervalValue: 1,
        intervalUnit: EventIntervalUnit.month,
      ),
    );
    await repository.save(
      EventDraft(
        name: '整理账单',
        intervalValue: 10,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: DateTime(2026, 8, 20, 10),
      ),
    );
    await repository.save(
      EventDraft(
        name: '检查药箱',
        intervalValue: 10,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: DateTime(2026, 8, 27, 10),
      ),
    );
    await repository.save(
      EventDraft(
        name: '整理旧资料',
        intervalValue: 1,
        intervalUnit: EventIntervalUnit.month,
        lastCompletedAt: DateTime(2026, 7, 1, 10),
      ),
    );
    // 已保存的事件列表。
    final List<EventRecord> records = await database
        .select(database.events)
        .get();
    // 已开始计时的事件。
    final EventRecord activeEvent = records.firstWhere(
      (EventRecord event) => event.name == '更换净水滤芯',
    );
    // 尚未首次记录的事件。
    final EventRecord unrecordedEvent = records.firstWhere(
      (EventRecord event) => event.name == '整理证件',
    );
    // 用于验证归档卡片状态的事件。
    final EventRecord archivedEvent = records.firstWhere(
      (EventRecord event) => event.name == '整理旧资料',
    );
    await repository.setArchived(archivedEvent.id, true);
    // 本月两笔和上月一笔有效完成记录，用于验证统计口径。
    await repository.addHistory(
      eventId: activeEvent.id,
      completedAt: DateTime(2026, 9, 2, 10),
    );
    await repository.addHistory(
      eventId: activeEvent.id,
      completedAt: DateTime(2026, 9, 4, 10),
    );
    await repository.addHistory(
      eventId: activeEvent.id,
      completedAt: DateTime(2026, 8, 2, 10),
    );
    // 添加历史后的最新事件快照，确保撤销恢复到正确的最近完成时间。
    final EventRecord refreshedActiveEvent = await (database.select(
      database.events,
    )..where((Events table) => table.id.equals(activeEvent.id))).getSingle();
    // 用于验证历史弹窗过滤逻辑的已撤销完成记录。
    final EventCompletionUndo revokedCompletion = await repository.recordNow(
      refreshedActiveEvent,
    );
    await repository.undoRecord(revokedCompletion);
    // 显式管理的测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(now),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();
    container.read(appRouterProvider).go('/events');
    await tester.pumpAndSettle();

    // 已开始计时的事件卡片。
    final Finder activeCard = find.byKey(
      ValueKey<String>('event-card-${activeEvent.id}'),
    );
    // 尚未首次记录的事件卡片。
    final Finder unrecordedCard = find.byKey(
      ValueKey<String>('event-card-${unrecordedEvent.id}'),
    );
    // 已开始计时的事件进度条。
    final Finder activeTimeline = find.byKey(
      ValueKey<String>('event-timeline-${activeEvent.id}'),
    );
    // 尚未首次记录的事件进度条。
    final Finder unrecordedTimeline = find.byKey(
      ValueKey<String>('event-timeline-${unrecordedEvent.id}'),
    );
    expect(activeCard, findsOneWidget);
    expect(unrecordedCard, findsOneWidget);
    expect(activeTimeline, findsOneWidget);
    expect(unrecordedTimeline, findsOneWidget);
    expect(find.text('还有 8 天'), findsOneWidget);
    expect(find.text('下次 9 月 14 日'), findsOneWidget);
    expect(find.text('上次完成 9 月 4 日'), findsOneWidget);
    expect(find.text('下次应做 9 月 14 日'), findsOneWidget);
    expect(find.text('还未开始计时'), findsOneWidget);
    expect(find.text('完成一次后开始推算'), findsOneWidget);
    expect(find.text('尚未完成'), findsOneWidget);
    expect(find.text('完成后开始周期'), findsOneWidget);
    expect(find.text('今天应做'), findsOneWidget);
    expect(find.text('已超期 7 天'), findsOneWidget);
    // 已开始计时事件的完成历史按钮。
    final Finder activeHistoryButton = find.byKey(
      ValueKey<String>('event-history-${activeEvent.id}'),
    );
    // 已开始计时事件的记录完成按钮。
    final Finder activeRecordButton = find.byKey(
      ValueKey<String>('event-record-${activeEvent.id}'),
    );
    // 待首次记录事件的首次记录按钮。
    final Finder firstRecordButton = find.byKey(
      ValueKey<String>('event-record-${unrecordedEvent.id}'),
    );
    expect(activeHistoryButton, findsOneWidget);
    expect(activeRecordButton, findsOneWidget);
    expect(firstRecordButton, findsOneWidget);
    expect(
      find.descendant(of: activeHistoryButton, matching: find.text('完成历史')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: activeRecordButton, matching: find.text('记录完成')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: firstRecordButton, matching: find.text('首次记录')),
      findsOneWidget,
    );
    // 新时间轨道应接近占满整张事件卡片的内容宽度。
    final Rect activeCardRect = tester.getRect(activeCard);
    // 已开始计时事件时间轨道的边界。
    final Rect activeTimelineRect = tester.getRect(activeTimeline);
    expect(activeTimelineRect.width, greaterThan(activeCardRect.width * 0.85));
    expect(
      tester.getRect(activeHistoryButton).top,
      greaterThan(activeTimelineRect.bottom),
    );

    // 进行中事件统计卡。
    final Finder activeMetric = find.byKey(
      const ValueKey<String>('event-metric-进行中事件'),
    );
    // 本月完成统计卡。
    final Finder completionMetric = find.byKey(
      const ValueKey<String>('event-metric-本月完成'),
    );
    // 近期应做统计卡。
    final Finder nearbyMetric = find.byKey(
      const ValueKey<String>('event-metric-近期应做'),
    );
    expect(activeMetric, findsOneWidget);
    expect(completionMetric, findsOneWidget);
    expect(nearbyMetric, findsOneWidget);
    expect(
      find.descendant(of: activeMetric, matching: find.text('4 项')),
      findsOneWidget,
    );
    expect(find.text('1 项待首次记录'), findsOneWidget);
    expect(find.text('节奏正常 1 项'), findsOneWidget);
    expect(
      find.descendant(of: completionMetric, matching: find.text('2 次')),
      findsOneWidget,
    );
    expect(find.text('覆盖 1 个事件'), findsOneWidget);
    expect(find.text('比上月多 1 次'), findsOneWidget);
    expect(
      find.descendant(of: nearbyMetric, matching: find.text('2 项')),
      findsOneWidget,
    );
    expect(find.text('超期 1 · 7 天内 1'), findsOneWidget);
    expect(find.text('优先处理超期'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('event-status-distribution')),
      findsOneWidget,
    );

    await tester.tap(activeHistoryButton);
    await tester.pumpAndSettle();
    expect(find.text('完成历史 · 3 条有效记录'), findsOneWidget);
    expect(find.text('2026 年 9 月 · 2 次'), findsOneWidget);
    expect(find.text('2026 年 8 月 · 1 次'), findsOneWidget);
    expect(find.text('9月4日 10:00'), findsOneWidget);
    expect(find.text('每 10 天'), findsOneWidget);
    expect(find.text('9月14日'), findsOneWidget);
    expect(find.textContaining('相隔 2 天'), findsOneWidget);
    expect(find.textContaining('相隔 31 天'), findsOneWidget);
    expect(find.text('手动补记'), findsNWidgets(3));
    expect(find.text('自动记录'), findsNothing);
    expect(find.textContaining('已撤销'), findsNothing);
    expect(find.text('补记完成'), findsOneWidget);
    expect(find.text('完成'), findsNothing);
    expect(find.byTooltip('记录操作'), findsNWidgets(3));
    await tester.tap(find.byTooltip('记录操作').first);
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除记录'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    // 三条记录时弹窗应随内容收缩，不占满整个视口。
    final OmniDialogScaffold historyDialog = tester.widget<OmniDialogScaffold>(
      find.byType(OmniDialogScaffold),
    );
    expect(historyDialog.width, 600);
    expect(historyDialog.height, lessThan(650));
    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/event_history_dialog_light_1440x900.png'),
    );
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('event-history-summary')))
          .width,
      lessThan(350),
    );
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();
    expect(find.text('完成历史 · 3 条有效记录'), findsNothing);

    // 尚未首次记录事件的完成历史按钮。
    final Finder unrecordedHistoryButton = find.byKey(
      ValueKey<String>('event-history-${unrecordedEvent.id}'),
    );
    await tester.tap(unrecordedHistoryButton);
    await tester.pumpAndSettle();
    expect(find.text('完成历史 · 0 条有效记录'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('event-history-summary')),
        matching: find.text('尚未完成'),
      ),
      findsOneWidget,
    );
    expect(find.text('完成后推算'), findsOneWidget);
    expect(find.text('还没有完成记录'), findsOneWidget);
    expect(find.text('完成或补记一次后，这里会形成事件节奏。'), findsOneWidget);
    expect(find.text('补记第一次'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('已归档'));
    await tester.pumpAndSettle();
    // 归档事件卡片。
    final Finder archivedCard = find.byKey(
      ValueKey<String>('event-card-${archivedEvent.id}'),
    );
    // 归档事件恢复按钮。
    final Finder restoreButton = find.byKey(
      ValueKey<String>('event-restore-${archivedEvent.id}'),
    );
    expect(archivedCard, findsOneWidget);
    expect(restoreButton, findsOneWidget);
    expect(
      find.descendant(of: archivedCard, matching: find.text('已归档')),
      findsNWidgets(2),
    );
    expect(find.text('原定应做 8 月 1 日'), findsOneWidget);
    expect(
      find.descendant(of: restoreButton, matching: find.text('恢复进行')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: activeMetric, matching: find.text('4 项')),
      findsOneWidget,
    );
    await tester.tap(find.text('进行中'));
    await tester.pumpAndSettle();

    // 双列时两张卡片的坐标。
    final Offset activeGridPosition = tester.getTopLeft(activeCard);
    final Offset unrecordedGridPosition = tester.getTopLeft(unrecordedCard);
    expect(unrecordedGridPosition.dy, closeTo(activeGridPosition.dy, 1));
    expect(
      (unrecordedGridPosition.dx - activeGridPosition.dx).abs(),
      greaterThan(100),
    );

    await expectLater(
      find.byType(OmniButlerApp),
      matchesGoldenFile('goldens/events_light_1440x900.png'),
    );

    await tester.tap(find.byKey(const ValueKey<String>('event-layout-toggle')));
    await tester.pumpAndSettle();

    // 单列时两张卡片的坐标。
    final Offset activeListPosition = tester.getTopLeft(activeCard);
    final Offset unrecordedListPosition = tester.getTopLeft(unrecordedCard);
    expect(unrecordedListPosition.dx, closeTo(activeListPosition.dx, 1));
    expect(
      (unrecordedListPosition.dy - activeListPosition.dy).abs(),
      greaterThan(40),
    );
    expect(find.text('双列'), findsOneWidget);

    tester.view.physicalSize = const Size(700, 900);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('event-statistics-scroll')),
      findsOneWidget,
    );
    // 本月完成统计卡的横向位置。
    final double completionMetricLeft = tester.getTopLeft(completionMetric).dx;
    // 近期应做统计卡的横向位置。
    final double nearbyMetricLeft = tester.getTopLeft(nearbyMetric).dx;
    expect(nearbyMetricLeft, greaterThan(completionMetricLeft));

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    await tester.ensureVisible(activeRecordButton);
    await tester.pumpAndSettle();
    await tester.tap(activeRecordButton);
    await tester.pumpAndSettle();
    // 页面顶部的完成撤销横幅。
    final Finder undoBanner = find.byKey(
      const ValueKey<String>('event-completion-undo-banner'),
    );
    expect(undoBanner, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      tester.getTopLeft(undoBanner).dy,
      lessThan(tester.getTopLeft(activeMetric).dy),
    );
    await tester.tap(
      find.descendant(of: undoBanner, matching: find.text('撤销')),
    );
    await tester.pumpAndSettle();
    expect(undoBanner, findsNothing);

    await tester.ensureVisible(activeRecordButton);
    await tester.pumpAndSettle();
    await tester.tap(activeRecordButton);
    await tester.pumpAndSettle();
    expect(undoBanner, findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(undoBanner, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(undoBanner, findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });
}
