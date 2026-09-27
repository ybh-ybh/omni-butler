import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/notifications/local_notification_service.dart';
import 'package:omni_butler/core/notifications/notification_preferences.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';

/// 本地通知服务提供者，正式启动时由 main 注入原生实现。
final Provider<LocalNotificationService> localNotificationServiceProvider =
    Provider<LocalNotificationService>((Ref ref) {
      // 不调用平台通道的默认实现。
      final LocalNotificationService service =
          LocalNotificationService.disabled();
      ref.onDispose(() {
        unawaited(service.dispose());
      });
      return service;
    });

/// 全部需要关注提醒状态的待办流。
final StreamProvider<List<TodoRecord>> notificationTodosProvider =
    StreamProvider<List<TodoRecord>>((Ref ref) {
      // 当前设备数据库。
      final AppDatabase database = ref.watch(appDatabaseProvider);
      // 未删除待办查询。
      final query = database.select(database.todoItems)
        ..where(
          (TodoItems table) =>
              table.deletedAt.isNull() & table.isCompleted.equals(false),
        );
      return query.watch();
    });

/// 监听提醒相关数据并同步原生通知计划。
final Provider<void> notificationCoordinatorProvider = Provider<void>((
  Ref ref,
) {
  // 服务级代次使旧系统调用收尾后不能覆盖新数据源的通知。
  final LocalNotificationService service = ref.watch(
    localNotificationServiceProvider,
  );
  // 所有窗口和启动恢复共用同一维护状态。
  final bool suspended = ref.watch(syncMaintenanceProvider);
  service.setMigrationSuspended(suspended);
  // 迁移期间不依据旧库重建通知，激活后由新库统一协调。
  if (suspended) return;
  // 当前设备通知偏好。
  final NotificationPreference preference = ref.watch(
    notificationPreferenceProvider,
  );
  // 当前设备功能偏好。
  final FeaturePreference featurePreference = ref.watch(
    featurePreferenceProvider,
  );
  // 结合功能开关后的有效通知偏好。
  final NotificationPreference effectivePreference = preference.copyWith(
    todoEnabled:
        preference.todoEnabled && featurePreference.isEnabled(AppFeature.todos),
    eventEnabled:
        preference.eventEnabled &&
        featurePreference.isEnabled(AppFeature.events),
    membershipEnabled:
        preference.membershipEnabled &&
        featurePreference.isEnabled(AppFeature.memberships),
  );
  // 全部未完成待办。
  final List<TodoRecord>? todos = ref.watch(notificationTodosProvider).value;
  // 全部有效周期事件。
  final List<EventRecord>? events = ref.watch(activeEventsProvider).value;
  // 全部有效会员。
  final List<MembershipRecord>? memberships = ref
      .watch(membershipsProvider)
      .value;
  if (todos == null || events == null || memberships == null) {
    return;
  }
  // 未来通知计划。
  final List<PlannedNotification> plans = const NotificationPlanBuilder().build(
    todos: todos,
    events: events,
    memberships: memberships,
    preference: effectivePreference,
    now: DateTime.now(),
  );
  unawaited(service.reconcile(plans));
});
