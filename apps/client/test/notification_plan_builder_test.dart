import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/notifications/local_notification_service.dart';
import 'package:omni_butler/core/notifications/notification_preferences.dart';

/// 全部通知分类均开启的默认偏好。
const NotificationPreference _enabledPreference = NotificationPreference(
  enabled: true,
  todoEnabled: true,
  eventEnabled: true,
  membershipEnabled: true,
);

/// 通知计划构建器测试。
void main() {
  group('NotificationPlanBuilder', () {
    test('只为未来且未完成的待办生成提醒', () {
      // 固定当前时间。
      final DateTime now = DateTime(2026, 9, 4, 9);
      // 待办通知计划。
      final List<PlannedNotification> plans = const NotificationPlanBuilder()
          .build(
            todos: <TodoRecord>[
              _todo('future', now.add(const Duration(hours: 1))),
              _todo('past', now.subtract(const Duration(minutes: 1))),
              _todo(
                'completed',
                now.add(const Duration(hours: 2)),
                completed: true,
              ),
            ],
            events: const <EventRecord>[],
            memberships: const <MembershipRecord>[],
            preference: _enabledPreference,
            now: now,
          );

      expect(plans, hasLength(1));
      expect(plans.single.key, 'todo:future');
      expect(plans.single.scheduledAt, DateTime(2026, 9, 4, 10));
    });

    test('按事件提前天数与提醒时刻计算下一次提醒', () {
      // 固定当前时间。
      final DateTime now = DateTime(2026, 9, 1, 8);
      // 周期事件。
      final EventRecord event = _event(
        lastCompletedAt: DateTime(2026, 8, 15, 12),
      );
      // 事件通知计划。
      final List<PlannedNotification> plans = const NotificationPlanBuilder()
          .build(
            todos: const <TodoRecord>[],
            events: <EventRecord>[event],
            memberships: const <MembershipRecord>[],
            preference: _enabledPreference,
            now: now,
          );

      expect(plans, hasLength(1));
      expect(plans.single.key, 'event:event-1');
      expect(plans.single.scheduledAt, DateTime(2026, 9, 12, 9, 30));
    });

    test('到期与自动续费使用各自提前天数生成两条提醒', () {
      // 固定当前时间。
      final DateTime now = DateTime(2026, 9, 1);
      // 会员通知计划。
      final List<PlannedNotification> plans = const NotificationPlanBuilder()
          .build(
            todos: const <TodoRecord>[],
            events: const <EventRecord>[],
            memberships: <MembershipRecord>[_membership()],
            preference: _enabledPreference,
            now: now,
          );

      expect(plans, hasLength(2));
      expect(
        plans.map((PlannedNotification plan) => plan.key),
        containsAll(<String>[
          'membership-expiration:member-1',
          'membership-renewal:member-1',
        ]),
      );
      expect(
        plans
            .firstWhere(
              (PlannedNotification plan) => plan.key.contains('expiration'),
            )
            .scheduledAt,
        DateTime(2026, 9, 30, 8),
      );
      expect(
        plans
            .firstWhere(
              (PlannedNotification plan) => plan.key.contains('renewal'),
            )
            .scheduledAt,
        DateTime(2026, 10, 13, 8),
      );
    });

    test('总开关关闭时不生成提醒', () {
      // 固定当前时间。
      final DateTime now = DateTime(2026, 9, 4, 9);
      // 全部关闭后的通知计划。
      final List<PlannedNotification> plans = const NotificationPlanBuilder()
          .build(
            todos: <TodoRecord>[
              _todo('future', now.add(const Duration(hours: 1))),
            ],
            events: <EventRecord>[_event()],
            memberships: <MembershipRecord>[_membership()],
            preference: const NotificationPreference(
              enabled: false,
              todoEnabled: true,
              eventEnabled: true,
              membershipEnabled: true,
            ),
            now: now,
          );

      expect(plans, isEmpty);
    });
  });
}

/// 创建测试待办。
TodoRecord _todo(String id, DateTime reminderAt, {bool completed = false}) {
  return TodoRecord(
    id: id,
    title: '测试待办 $id',
    scheduledDate: DateTime(2026, 9, 4),
    priorityQuadrant: 1,
    isCompleted: completed,
    reminderAt: reminderAt,
    sortOrder: 0,
    syncState: 'localSaved',
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 1),
  );
}

/// 创建测试周期事件。
EventRecord _event({DateTime? lastCompletedAt}) {
  return EventRecord(
    id: 'event-1',
    name: '更换滤芯',
    intervalValue: 1,
    intervalUnit: 'month',
    lastCompletedAt: lastCompletedAt ?? DateTime(2026, 9, 15, 12),
    reminderEnabled: true,
    reminderDaysBefore: 3,
    reminderTimeMinutes: 570,
    isArchived: false,
    syncState: 'localSaved',
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 1),
  );
}

/// 创建测试会员。
MembershipRecord _membership() {
  return MembershipRecord(
    id: 'member-1',
    name: '视频会员',
    priceCents: 2000,
    billingCycle: 'month',
    baseStatus: 'active',
    purchaseDate: DateTime(2026, 8, 1),
    expirationDate: DateTime(2026, 10, 10),
    isPermanent: false,
    autoRenew: true,
    renewalDate: DateTime(2026, 10, 20),
    isFavorite: false,
    needsRenewal: false,
    expirationReminderEnabled: true,
    expirationReminderDays: 10,
    renewalReminderEnabled: true,
    renewalReminderDays: 7,
    reminderTimeMinutes: 480,
    syncState: 'localSaved',
    createdAt: DateTime(2026, 8, 1),
    updatedAt: DateTime(2026, 8, 1),
  );
}
