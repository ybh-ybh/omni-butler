import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/events/data/event_repository.dart';
import 'package:omni_butler/features/home/presentation/home_context_card.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证今日脉络通过真实仓储读取、刷新并展示近期安排。
void main() {
  testWidgets('默认关闭提醒的未来事件仍展示，新增完成记录后自动移出近期清单', (WidgetTester tester) async {
    // 固定日期以验证日历窗口和记录后的应做日期。
    final DateTime now = DateTime(2026, 10, 6, 14);
    // 真实内存数据库与事件仓储。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 所有读写均使用生产仓储，保留真实数据库通知链路。
    final EventRepository repository = EventRepository(database);
    await repository.save(
      EventDraft(
        name: '本周更换滤芯',
        intervalValue: 30,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: DateTime(2026, 9, 10, 9),
      ),
    );
    // 刚保存的默认关闭通知、零天提前量的事件。
    final EventRecord event =
        (await database.select(database.events).get()).single;
    expect(event.reminderEnabled, isFalse);
    expect(event.reminderDaysBefore, 0);
    expect(repository.statusFor(event, now), EventDueStatus.normal);
    await _pumpCard(tester, database: database, now: now);

    expect(find.text('本周更换滤芯'), findsOneWidget);
    expect(find.text('4 天后'), findsOneWidget);
    expect(
      find.byKey(ValueKey<String>('home-context-event-item-${event.id}')),
      findsOneWidget,
    );

    await repository.addHistory(eventId: event.id, completedAt: now);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey<String>('home-context-event-item-${event.id}')),
      findsNothing,
    );
    expect(find.text('近期暂无待处理事件'), findsOneWidget);
    expect(find.textContaining('下一项：本周更换滤芯'), findsOneWidget);
  });

  testWidgets('尚未首次记录的事件明确说明日期无法计算', (WidgetTester tester) async {
    // 测试当天。
    final DateTime now = DateTime(2026, 10, 6, 14);
    // 仅包含未记录事件的内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await EventRepository(database).save(
      const EventDraft(
        name: '首次检查烟雾报警器',
        intervalValue: 1,
        intervalUnit: EventIntervalUnit.month,
      ),
    );
    await _pumpCard(tester, database: database, now: now);

    expect(find.text('等待首次记录'), findsOneWidget);
    expect(find.text('先记录一次完成时间，即可计算下次日期。'), findsOneWidget);
    // 纯未记录空态已有解释，不再重复显示同义警告。
    expect(find.text('1 项尚未记录完成时间，暂无法计算日期'), findsNothing);
    expect(find.text('近期暂无待处理事件'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('context-details-expanded-周期事件')),
      findsNothing,
    );
  });

  testWidgets('事件与会员空态保留全部入口并跳转对应模块', (WidgetTester tester) async {
    // 空数据库用于验证两个空态入口。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 最小真实路由仅验证卡片提供的目标地址。
    final GoRouter router = await _pumpCard(
      tester,
      database: database,
      now: DateTime(2026, 10, 6),
    );

    expect(find.text('还没有周期事件'), findsOneWidget);
    expect(find.text('还没有会员记录'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('home-context-open-周期事件')),
    );
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/events');
    expect(find.text('事件功能页'), findsOneWidget);

    router.go('/');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('home-context-open-会员提醒')),
    );
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/memberships');
    expect(find.text('会员功能页'), findsOneWidget);
  });

  testWidgets('会员按实际提醒日期排序，今天续费排在明天到期之前', (WidgetTester tester) async {
    // 固定日期与时间用于区分续费和到期的优先次序。
    final DateTime now = DateTime(2026, 10, 6, 14);
    // 同时包含续费提醒与到期提醒的真实数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 生产会员仓储负责保存两种提醒状态。
    final MembershipRepository repository = MembershipRepository(database);
    await repository.save(
      MembershipDraft(
        name: '今天续费的年度会员',
        priceCents: 10000,
        purchaseDate: DateTime(2026, 1, 1),
        expirationDate: DateTime(2027, 1, 1),
        isPermanent: false,
        autoRenew: true,
        renewalDate: DateTime(2026, 10, 6),
        needsRenewal: true,
        expirationReminderDays: 1,
      ),
    );
    await repository.save(
      MembershipDraft(
        name: '明天到期的月度会员',
        priceCents: 1000,
        purchaseDate: DateTime(2026, 9, 7),
        expirationDate: DateTime(2026, 10, 7),
        isPermanent: false,
        autoRenew: false,
      ),
    );
    await _pumpCard(tester, database: database, now: now);

    expect(find.text('今天续费的年度会员'), findsOneWidget);
    expect(find.text('明天到期的月度会员'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('今天续费的年度会员')).dy,
      lessThan(tester.getTopLeft(find.text('明天到期的月度会员')).dy),
    );
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('明天'), findsOneWidget);
  });

  testWidgets('点击事项名称或日期保持首页且不会记录完成或续费', (WidgetTester tester) async {
    // 使用当天自然日构造始终临近的两种事项。
    final DateTime now = DateUtils.dateOnly(DateTime.now());
    // 真实数据库保留点击前后的业务记录以检查无副作用。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await EventRepository(database).save(
      EventDraft(
        name: '点击名称不会记录的事件',
        intervalValue: 30,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: now.subtract(const Duration(days: 32)),
      ),
    );
    await MembershipRepository(database).save(
      MembershipDraft(
        name: '点击名称不会续费的会员',
        priceCents: 1000,
        purchaseDate: now.subtract(const Duration(days: 28)),
        expirationDate: now.add(const Duration(days: 2)),
        isPermanent: false,
        autoRenew: false,
      ),
    );
    // 当前事件用于限定事件日期区域。
    final EventRecord event =
        (await database.select(database.events).get()).single;
    // 当前会员用于限定会员日期区域。
    final MembershipRecord membership =
        (await database.select(database.memberships).get()).single;
    // 点击前已有的首次完成记录。
    final List<EventCompletionRecord> previousCompletions = await database
        .select(database.eventCompletions)
        .get();
    // 点击前已有的购买记录。
    final List<MembershipPaymentRecord> previousPayments = await database
        .select(database.membershipPayments)
        .get();
    // 路由状态用于确认事项点击保持在首页。
    final GoRouter router = await _pumpCard(
      tester,
      database: database,
      now: now,
    );
    // 完整事件行包含日期与名称，排除同日其他事项影响。
    final Finder eventRow = find.byKey(
      ValueKey<String>('home-context-event-item-${event.id}'),
    );
    // 完整会员行包含日期与名称。
    final Finder membershipRow = find.byKey(
      ValueKey<String>('home-context-membership-item-${membership.id}'),
    );

    await tester.tap(find.text(event.name));
    await tester.pump();
    expect(router.routeInformationProvider.value.uri.path, '/');
    await tester.tap(
      find.descendant(
        of: eventRow,
        matching: find.text(
          '${now.subtract(const Duration(days: 2)).day}'.padLeft(2, '0'),
        ),
      ),
    );
    await tester.pump();
    expect(router.routeInformationProvider.value.uri.path, '/');
    await tester.tap(find.text(membership.name));
    await tester.pump();
    expect(router.routeInformationProvider.value.uri.path, '/');
    await tester.tap(
      find.descendant(
        of: membershipRow,
        matching: find.text(
          '${membership.expirationDate!.day}'.padLeft(2, '0'),
        ),
      ),
    );
    await tester.pump();

    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(find.text('新增支付记录'), findsNothing);
    expect(
      await database.select(database.eventCompletions).get(),
      previousCompletions,
    );
    expect(
      await database.select(database.membershipPayments).get(),
      previousPayments,
    );
    expect((await database.select(database.events).get()).single, event);
    expect(
      (await database.select(database.memberships).get()).single,
      membership,
    );
  });

  testWidgets('首页记录连点只写一次当前完成时间，撤销后恢复原日期与清单', (WidgetTester tester) async {
    // 与生产 recordNow 使用相同的真实日期，避免固定时钟令记录落在过去。
    final DateTime now = DateUtils.dateOnly(DateTime.now());
    // 真实事务和查询通知用于检验写入与撤销的完整链路。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await EventRepository(database).save(
      EventDraft(
        name: '首页直接记录浇水',
        intervalValue: 30,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: now.subtract(const Duration(days: 32)),
      ),
    );
    // 原事件时间用于确认记录推进且撤销准确恢复。
    final EventRecord event =
        (await database.select(database.events).get()).single;
    // 原始首次完成记录数量。
    final int previousCompletionCount =
        (await database.select(database.eventCompletions).get()).length;
    // 路由保持在首页，记录后由数据库通知更新当前清单。
    final GoRouter router = await _pumpCard(
      tester,
      database: database,
      now: now,
    );
    // 独立记录按钮允许直接操作当前事件。
    final Finder recordButton = find.byKey(
      ValueKey<String>('home-context-record-${event.id}'),
    );
    // 明细行用于验证记录后移出、撤销后恢复。
    final Finder eventRow = find.byKey(
      ValueKey<String>('home-context-event-item-${event.id}'),
    );
    // SQLite 保存精度为秒，向前留一秒避免毫秒截断误报。
    final DateTime earliestCompletion = DateTime.now().subtract(
      const Duration(seconds: 1),
    );

    await tester.tap(recordButton);
    await tester.tap(recordButton);
    await tester.pump(const Duration(milliseconds: 100));
    // 包含初始记录与本次完成的真实数据库结果。
    final List<EventCompletionRecord> completions = await database
        .select(database.eventCompletions)
        .get();
    // 更新后的事件汇总时间必须来自刚才的按钮操作。
    final EventRecord completedEvent =
        (await database.select(database.events).get()).single;
    await tester.pump(const Duration(milliseconds: 300));

    expect(completions, hasLength(previousCompletionCount + 1));
    expect(
      completions.where(
        (EventCompletionRecord completion) =>
            completion.source == 'recordNow' && !completion.isRevoked,
      ),
      hasLength(1),
    );
    expect(completedEvent.lastCompletedAt, isNot(event.lastCompletedAt));
    expect(
      completedEvent.lastCompletedAt!.isBefore(earliestCompletion),
      isFalse,
    );
    expect(completedEvent.lastCompletedAt!.isAfter(DateTime.now()), isFalse);
    expect(eventRow, findsNothing);
    expect(find.text('近期暂无待处理事件'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/');
    // 限时撤销消息只推进短帧，避免 pumpAndSettle 消耗六秒有效期。
    final Finder undoMessage = find.byKey(
      const ValueKey<String>('omni-message-popup'),
    );
    expect(undoMessage, findsOneWidget);
    await tester.tap(
      find.descendant(of: undoMessage, matching: find.text('撤销')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // 撤销应保留历史但将本次记录标记失效。
    final List<EventCompletionRecord> undoneCompletions = await database
        .select(database.eventCompletions)
        .get();
    // 汇总日期重新取回原来的有效完成时间。
    final EventRecord restoredEvent =
        (await database.select(database.events).get()).single;
    await tester.pump(const Duration(milliseconds: 300));

    expect(restoredEvent.lastCompletedAt, event.lastCompletedAt);
    expect(
      undoneCompletions.where(
        (EventCompletionRecord completion) => !completion.isRevoked,
      ),
      hasLength(previousCompletionCount),
    );
    expect(
      undoneCompletions
          .singleWhere(
            (EventCompletionRecord completion) =>
                completion.source == 'recordNow',
          )
          .isRevoked,
      isTrue,
    );
    expect(eventRow, findsOneWidget);
    expect(recordButton, findsOneWidget);
    expect(undoMessage, findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/');
  });

  testWidgets('首页续费取消不写入，保存连点只新增一笔并延期移出提醒', (WidgetTester tester) async {
    // 当天真实日期与续费弹窗的默认付费日期一致。
    final DateTime now = DateUtils.dateOnly(DateTime.now());
    // 真实会员仓储用于确认支付记录与到期日一起变化。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await MembershipRepository(database).save(
      MembershipDraft(
        name: '首页直接续费云空间',
        priceCents: 1000,
        billingCycle: BillingCycle.week,
        purchaseDate: now.subtract(const Duration(days: 4)),
        expirationDate: now.add(const Duration(days: 3)),
        expirationReminderDays: 7,
        isPermanent: false,
        autoRenew: false,
      ),
    );
    // 续费前的会员信息作为有效期基线。
    final MembershipRecord membership =
        (await database.select(database.memberships).get()).single;
    // 首次购买记录不应被取消动作修改。
    final List<MembershipPaymentRecord> previousPayments = await database
        .select(database.membershipPayments)
        .get();
    // 续费弹窗应留在首页路由中完成。
    final GoRouter router = await _pumpCard(
      tester,
      database: database,
      now: now,
    );
    // 会员明细中的独立续费入口。
    final Finder renewButton = find.byKey(
      ValueKey<String>('home-context-renew-${membership.id}'),
    );

    await tester.tap(renewButton);
    await tester.pumpAndSettle();
    expect(find.text('新增支付记录'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(
      await database.select(database.membershipPayments).get(),
      previousPayments,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('新增支付记录'), findsNothing);
    expect(
      await database.select(database.membershipPayments).get(),
      previousPayments,
    );
    expect(
      (await database.select(database.memberships).get()).single,
      membership,
    );

    await tester.tap(renewButton);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '金额（元）'), '12.50');
    await tester.enterText(find.widgetWithText(TextField, '备注'), '首页续费回归');
    await tester.tap(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    // 新旧支付记录一起读取，确保快速点击没有重复记账。
    final List<MembershipPaymentRecord> payments = await database
        .select(database.membershipPayments)
        .get();
    // 修改后的到期日必须从原有效期叠加一周。
    final MembershipRecord renewedMembership =
        (await database.select(database.memberships).get()).single;
    // 本次带有独立备注的支付仅存在一笔。
    final MembershipPaymentRecord payment = payments.singleWhere(
      (MembershipPaymentRecord payment) => payment.notes == '首页续费回归',
    );

    expect(payments, hasLength(previousPayments.length + 1));
    expect(payment.amountCents, 1250);
    expect(payment.membershipId, membership.id);
    expect(
      renewedMembership.expirationDate,
      membership.expirationDate!.add(const Duration(days: 7)),
    );
    expect(find.text('新增支付记录'), findsNothing);
    expect(
      find.byKey(
        ValueKey<String>('home-context-membership-item-${membership.id}'),
      ),
      findsNothing,
    );
    expect(find.text('暂无到期或续费提醒'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/');
  });

  testWidgets('首页续费保存失败保留表单并恢复按钮，重试成功只写入一笔', (WidgetTester tester) async {
    // 当天日期保持会员处于到期提醒窗口。
    final DateTime now = DateUtils.dateOnly(DateTime.now());
    // 使用真实 SQLite 事务验证失败后的回滚与重试。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await MembershipRepository(database).save(
      MembershipDraft(
        name: '保存失败后可重试的会员',
        priceCents: 1000,
        billingCycle: BillingCycle.week,
        purchaseDate: now.subtract(const Duration(days: 4)),
        expirationDate: now.add(const Duration(days: 3)),
        expirationReminderDays: 7,
        isPermanent: false,
        autoRenew: false,
      ),
    );
    // 失败操作不能改变现有会员有效期。
    final MembershipRecord membership =
        (await database.select(database.memberships).get()).single;
    // 已有购买记录作为支付事务回滚的基线。
    final List<MembershipPaymentRecord> previousPayments = await database
        .select(database.membershipPayments)
        .get();
    // 续费失败与重试均应留在首页。
    final GoRouter router = await _pumpCard(
      tester,
      database: database,
      now: now,
    );
    await tester.tap(
      find.byKey(ValueKey<String>('home-context-renew-${membership.id}')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '金额（元）'), '18.50');
    await tester.enterText(find.widgetWithText(TextField, '备注'), '失败后保留的续费内容');
    // 首次提交由临时数据库触发器拒绝，完整经过生产仓储错误路径。
    await database.customStatement('''
      CREATE TEMP TRIGGER reject_home_payment
      BEFORE INSERT ON membership_payments
      BEGIN
        SELECT RAISE(ABORT, 'simulated payment write failure');
      END;
    ''');
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      await database.select(database.membershipPayments).get(),
      previousPayments,
    );
    expect(
      (await database.select(database.memberships).get()).single,
      membership,
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(find.text('新增支付记录'), findsOneWidget);
    // 保存失败必须结束加载状态，使原表单可以再次提交。
    final OmniButton saveButton = tester.widget<OmniButton>(
      find.widgetWithText(OmniButton, '保存'),
    );
    // 同时恢复取消按钮，避免失败后把用户困在弹窗中。
    final OmniButton cancelButton = tester.widget<OmniButton>(
      find.widgetWithText(OmniButton, '取消'),
    );
    expect(saveButton.loading, isFalse);
    expect(saveButton.onPressed, isNotNull);
    expect(cancelButton.onPressed, isNotNull);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '金额（元）'))
          .controller!
          .text,
      '18.50',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '备注'))
          .controller!
          .text,
      '失败后保留的续费内容',
    );
    await database.customStatement('DROP TRIGGER reject_home_payment');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    // 重试只写入一笔真实支付，失败提交不留半成品。
    final List<MembershipPaymentRecord> payments = await database
        .select(database.membershipPayments)
        .get();
    // 保留输入的支付记录用于检查重试没有清空金额与备注。
    final MembershipPaymentRecord retriedPayment = payments.singleWhere(
      (MembershipPaymentRecord payment) => payment.notes == '失败后保留的续费内容',
    );
    expect(payments, hasLength(previousPayments.length + 1));
    expect(retriedPayment.amountCents, 1850);
    expect(
      (await database.select(database.memberships).get()).single.expirationDate,
      membership.expirationDate!.add(const Duration(days: 7)),
    );
    expect(find.text('新增支付记录'), findsNothing);
    expect(find.text('暂无到期或续费提醒'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/');
  });

  testWidgets('首页撤销失败保留本次完成，点击重试恢复原日期与事项', (WidgetTester tester) async {
    // 与生产完成时间保持同一天，记录后事件会移出临近清单。
    final DateTime now = DateUtils.dateOnly(DateTime.now());
    // 真实内存数据库可在撤销更新时模拟存储失败。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await EventRepository(database).save(
      EventDraft(
        name: '撤销失败后可重试的事件',
        intervalValue: 30,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: now.subtract(const Duration(days: 32)),
      ),
    );
    // 原完成日期用于验证成功重试恢复了正确的历史状态。
    final EventRecord event =
        (await database.select(database.events).get()).single;
    // 初始完成历史数量不包含稍后的首页记录。
    final int previousCompletionCount =
        (await database.select(database.eventCompletions).get()).length;
    await _pumpCard(tester, database: database, now: now);
    await tester.tap(
      find.byKey(ValueKey<String>('home-context-record-${event.id}')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // 已完成的事件作为首次撤销失败后仍应保留的数据。
    final EventRecord completedEvent =
        (await database.select(database.events).get()).single;
    await tester.pump(const Duration(milliseconds: 100));
    expect(completedEvent.lastCompletedAt, isNot(event.lastCompletedAt));
    // 仅拒绝撤销标记更新，不阻止先前的正常完成操作。
    await database.customStatement('''
      CREATE TEMP TRIGGER reject_home_event_undo
      BEFORE UPDATE OF is_revoked ON event_completions
      WHEN NEW.is_revoked = 1
      BEGIN
        SELECT RAISE(ABORT, 'simulated completion undo failure');
      END;
    ''');
    // 通过可见撤销入口触发真实失败，并保留其重试凭据。
    final Finder message = find.byKey(
      const ValueKey<String>('omni-message-popup'),
    );
    await tester.tap(find.descendant(of: message, matching: find.text('撤销')));
    await tester.pump(const Duration(milliseconds: 100));
    // 失败事务没有撤销本次记录，也不应另写一笔完成历史。
    final List<EventCompletionRecord> failedCompletions = await database
        .select(database.eventCompletions)
        .get();
    expect(failedCompletions, hasLength(previousCompletionCount + 1));
    expect(
      failedCompletions
          .singleWhere(
            (EventCompletionRecord completion) =>
                completion.source == 'recordNow',
          )
          .isRevoked,
      isFalse,
    );
    expect(
      (await database.select(database.events).get()).single.lastCompletedAt,
      completedEvent.lastCompletedAt,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('撤销失败，请重试'), findsOneWidget);
    expect(
      find.descendant(of: message, matching: find.text('重试')),
      findsOneWidget,
    );

    await database.customStatement('DROP TRIGGER reject_home_event_undo');
    await tester.tap(find.descendant(of: message, matching: find.text('重试')));
    await tester.pump(const Duration(milliseconds: 100));
    // 重试沿用同一完成记录，只把其撤销状态改为成功。
    final List<EventCompletionRecord> retriedCompletions = await database
        .select(database.eventCompletions)
        .get();
    expect(retriedCompletions, hasLength(previousCompletionCount + 1));
    expect(
      retriedCompletions
          .singleWhere(
            (EventCompletionRecord completion) =>
                completion.source == 'recordNow',
          )
          .isRevoked,
      isTrue,
    );
    expect(
      (await database.select(database.events).get()).single.lastCompletedAt,
      event.lastCompletedAt,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(ValueKey<String>('home-context-event-item-${event.id}')),
      findsOneWidget,
    );
    expect(message, findsNothing);
  });

  testWidgets('窄屏深色大字号长名称无溢出且记录续费按钮可操作', (WidgetTester tester) async {
    // 当天日期使两种提醒均出现在近期列表。
    final DateTime now = DateUtils.dateOnly(DateTime.now());
    // 分别构造超过一行的事件和会员名称。
    const String eventName = '为家中每一个房间更换新风系统的超长名称空气过滤滤芯并检查密封';
    // 用于验证会员名称也受到相同宽度约束。
    const String membershipName = '家庭影音娱乐云存储与在线协作设计工具联合年度会员超长名称';
    // 长名称真实业务数据。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    await EventRepository(database).save(
      EventDraft(
        name: eventName,
        intervalValue: 10,
        intervalUnit: EventIntervalUnit.day,
        lastCompletedAt: now.subtract(const Duration(days: 6)),
      ),
    );
    await MembershipRepository(database).save(
      MembershipDraft(
        name: membershipName,
        priceCents: 10000,
        purchaseDate: now.subtract(const Duration(days: 30)),
        expirationDate: now.add(const Duration(days: 4)),
        isPermanent: false,
        autoRenew: false,
      ),
    );
    // 事件标识用于定位长标题右侧的记录按钮。
    final EventRecord event =
        (await database.select(database.events).get()).single;
    // 会员标识用于定位长标题右侧的续费按钮。
    final MembershipRecord membership =
        (await database.select(database.memberships).get()).single;
    await _pumpCard(
      tester,
      database: database,
      now: now,
      width: 320,
      brightness: Brightness.dark,
      textScale: 1.3,
    );

    expect(find.text(eventName), findsOneWidget);
    expect(find.text(membershipName), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.text(eventName)).right, lessThanOrEqualTo(320));
    expect(
      tester.getRect(find.text(membershipName)).right,
      lessThanOrEqualTo(320),
    );
    // 记录与续费按钮必须在窄屏内，且仍有可以点击的命中区域。
    final Finder recordButton = find.byKey(
      ValueKey<String>('home-context-record-${event.id}'),
    );
    // 长会员名不能将续费操作挤出屏幕。
    final Finder renewButton = find.byKey(
      ValueKey<String>('home-context-renew-${membership.id}'),
    );
    expect(tester.getRect(recordButton).right, lessThanOrEqualTo(320));
    expect(tester.getRect(renewButton).right, lessThanOrEqualTo(320));
    expect(recordButton.hitTestable(), findsOneWidget);
    expect(renewButton.hitTestable(), findsOneWidget);
    await tester.tap(recordButton);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      (await database.select(database.eventCompletions).get()).where(
        (EventCompletionRecord completion) => completion.source == 'recordNow',
      ),
      hasLength(1),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(renewButton);
    await tester.tap(renewButton);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('新增支付记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}

/// 挂载真实数据库驱动的卡片，同时隔离其他首页模块以精确检查布局。
Future<GoRouter> _pumpCard(
  WidgetTester tester, {
  required AppDatabase database,
  required DateTime now,
  double width = 560,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // 使用实际功能偏好提供者的测试存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 仅覆盖数据库、时钟与持久偏好，保留事件和会员生产数据流。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
      nowProvider.overrideWithValue(now),
    ],
  );
  // 与实际应用一致的模块地址。
  final GoRouter router = GoRouter(
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) => Scaffold(
          body: SingleChildScrollView(child: HomeTodayContextCard(now: now)),
        ),
      ),
      GoRoute(
        path: '/events',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Text('事件功能页')),
      ),
      GoRoute(
        path: '/memberships',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Text('会员功能页')),
      ),
    ],
  );
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    router.dispose();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.build(brightness: brightness),
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
  return router;
}
