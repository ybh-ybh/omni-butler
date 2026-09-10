import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/notifications/notification_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// 已调度通知标识持久化键。
const String _scheduledIdsKey = 'notifications.scheduled_ids';

/// 已调度通知计划指纹持久化键。
const String _scheduleFingerprintKey = 'notifications.schedule_fingerprint';

/// Windows 通知回调标识。
const String _windowsNotificationGuid = '79a9c8d8-3305-4c31-9160-79fba3438ddd';

/// 本地通知可用状态。
enum NotificationAvailability {
  /// 通知服务已就绪。
  ready,

  /// 当前运行环境不支持通知。
  unsupported,

  /// 初始化或调度失败。
  failed,
}

/// 一条尚未发送的本地通知计划。
@immutable
class PlannedNotification {
  /// 跨启动稳定的业务键。
  final String key;

  /// 通知标题。
  final String title;

  /// 通知正文。
  final String body;

  /// 本地触发时间。
  final DateTime scheduledAt;

  /// 点击通知时使用的业务载荷。
  final String payload;

  /// 创建本地通知计划。
  const PlannedNotification({
    required this.key,
    required this.title,
    required this.body,
    required this.scheduledAt,
    required this.payload,
  });

  /// 返回可比较的稳定序列化文本。
  String get fingerprintPart =>
      '$key|$title|$body|${scheduledAt.toIso8601String()}|$payload';
}

/// 根据业务记录生成本地通知计划。
class NotificationPlanBuilder {
  /// 创建通知计划构建器。
  const NotificationPlanBuilder();

  /// 构建全部仍在未来的通知计划。
  List<PlannedNotification> build({
    required List<TodoRecord> todos,
    required List<EventRecord> events,
    required List<MembershipRecord> memberships,
    required NotificationPreference preference,
    required DateTime now,
  }) {
    if (!preference.enabled) {
      return const <PlannedNotification>[];
    }
    // 待返回的通知计划。
    final List<PlannedNotification> plans = <PlannedNotification>[];
    if (preference.todoEnabled) {
      plans.addAll(_todoPlans(todos, now));
    }
    if (preference.eventEnabled) {
      plans.addAll(_eventPlans(events, now));
    }
    if (preference.membershipEnabled) {
      plans.addAll(_membershipPlans(memberships, now));
    }
    plans.sort(
      (PlannedNotification left, PlannedNotification right) =>
          left.scheduledAt.compareTo(right.scheduledAt),
    );
    return plans;
  }

  /// 构建未完成待办的提醒计划。
  Iterable<PlannedNotification> _todoPlans(
    List<TodoRecord> todos,
    DateTime now,
  ) sync* {
    for (final TodoRecord todo in todos) {
      // 用户设置的待办提醒时间。
      final DateTime? scheduledAt = todo.reminderAt;
      if (todo.isCompleted ||
          scheduledAt == null ||
          !scheduledAt.isAfter(now)) {
        continue;
      }
      yield PlannedNotification(
        key: 'todo:${todo.id}',
        title: '待办提醒',
        body: todo.title,
        scheduledAt: scheduledAt,
        payload: 'todo:${todo.id}',
      );
    }
  }

  /// 构建周期事件下一次到期提醒计划。
  Iterable<PlannedNotification> _eventPlans(
    List<EventRecord> events,
    DateTime now,
  ) sync* {
    for (final EventRecord event in events) {
      if (!event.reminderEnabled || event.isArchived) {
        continue;
      }
      // 下一次事件应做日期。
      final DateTime? dueAt = _nextEventDueAt(event);
      if (dueAt == null) {
        continue;
      }
      // 提前天数对应的提醒日期。
      final DateTime reminderDay = dueAt.subtract(
        Duration(days: event.reminderDaysBefore),
      );
      // 事件提醒时刻。
      final DateTime scheduledAt = DateTime(
        reminderDay.year,
        reminderDay.month,
        reminderDay.day,
        event.reminderTimeMinutes ~/ 60,
        event.reminderTimeMinutes % 60,
      );
      if (!scheduledAt.isAfter(now)) {
        continue;
      }
      yield PlannedNotification(
        key: 'event:${event.id}',
        title: '周期事件提醒',
        body: '${event.name}即将到期',
        scheduledAt: scheduledAt,
        payload: 'event:${event.id}',
      );
    }
  }

  /// 构建会员到期与自动续费提醒计划。
  Iterable<PlannedNotification> _membershipPlans(
    List<MembershipRecord> memberships,
    DateTime now,
  ) sync* {
    for (final MembershipRecord membership in memberships) {
      if (membership.isPermanent) {
        continue;
      }
      if (membership.expirationReminderEnabled &&
          membership.expirationDate != null) {
        // 会员到期提醒时间。
        final DateTime scheduledAt = _reminderAt(
          membership.expirationDate!,
          membership.expirationReminderDays,
          membership.reminderTimeMinutes,
        );
        if (scheduledAt.isAfter(now)) {
          yield PlannedNotification(
            key: 'membership-expiration:${membership.id}',
            title: '会员到期提醒',
            body: '${membership.name}即将到期',
            scheduledAt: scheduledAt,
            payload: 'membership:${membership.id}',
          );
        }
      }
      if (membership.autoRenew &&
          membership.renewalReminderEnabled &&
          membership.renewalDate != null) {
        // 会员续费提醒时间。
        final DateTime scheduledAt = _reminderAt(
          membership.renewalDate!,
          membership.renewalReminderDays,
          membership.reminderTimeMinutes,
        );
        if (scheduledAt.isAfter(now)) {
          yield PlannedNotification(
            key: 'membership-renewal:${membership.id}',
            title: '自动续费提醒',
            body: '${membership.name}即将自动续费',
            scheduledAt: scheduledAt,
            payload: 'membership:${membership.id}',
          );
        }
      }
    }
  }

  /// 计算周期事件下一次应做时间。
  DateTime? _nextEventDueAt(EventRecord event) {
    // 最近一次完成时间。
    final DateTime? last = event.lastCompletedAt;
    if (last == null) {
      return null;
    }
    return switch (event.intervalUnit) {
      'day' => last.add(Duration(days: event.intervalValue)),
      'week' => last.add(Duration(days: event.intervalValue * 7)),
      'year' => _addMonths(last, event.intervalValue * 12),
      _ => _addMonths(last, event.intervalValue),
    };
  }

  /// 计算会员配置对应的提醒时间。
  DateTime _reminderAt(DateTime target, int daysBefore, int minutes) {
    // 提醒日期。
    final DateTime day = target.subtract(Duration(days: daysBefore));
    return DateTime(day.year, day.month, day.day, minutes ~/ 60, minutes % 60);
  }

  /// 按月增加日期并将不存在的日期落到月末。
  DateTime _addMonths(DateTime source, int months) {
    // 目标月份的零基索引。
    final int targetMonthIndex = source.month - 1 + months;
    // 目标年份。
    final int targetYear = source.year + targetMonthIndex ~/ 12;
    // 目标月份。
    final int targetMonth = targetMonthIndex % 12 + 1;
    // 目标月份的最后一天。
    final int lastDay = DateTime(targetYear, targetMonth + 1, 0).day;
    // 有效目标日。
    final int targetDay = source.day > lastDay ? lastDay : source.day;
    return DateTime(
      targetYear,
      targetMonth,
      targetDay,
      source.hour,
      source.minute,
      source.second,
    );
  }
}

/// 封装 Windows 与 Android 的本地通知能力。
class LocalNotificationService {
  /// 通知插件实例。
  final FlutterLocalNotificationsPlugin _plugin;

  /// 当前设备偏好存储。
  final SharedPreferences? _preferences;

  /// 是否允许调用原生通知插件。
  final bool _nativeEnabled;

  /// 通知点击载荷控制器。
  final StreamController<String> _payloadController =
      StreamController<String>.broadcast();

  /// 当前通知可用状态。
  NotificationAvailability availability;

  /// 最近一次错误说明。
  String? lastError;

  /// 尚未被根应用消费的启动载荷。
  String? initialPayload;

  /// 创建可调用原生通知的服务。
  LocalNotificationService(SharedPreferences preferences)
    : _preferences = preferences,
      _plugin = FlutterLocalNotificationsPlugin(),
      _nativeEnabled = true,
      availability = NotificationAvailability.unsupported;

  /// 创建供测试或不支持平台使用的禁用服务。
  LocalNotificationService.disabled()
    : _preferences = null,
      _plugin = FlutterLocalNotificationsPlugin(),
      _nativeEnabled = false,
      availability = NotificationAvailability.unsupported;

  /// 通知点击载荷流。
  Stream<String> get payloads => _payloadController.stream;

  /// 初始化当前平台的通知插件。
  Future<void> initialize() async {
    if (!_nativeEnabled ||
        (defaultTargetPlatform != TargetPlatform.windows &&
            defaultTargetPlatform != TargetPlatform.android)) {
      availability = NotificationAvailability.unsupported;
      return;
    }
    try {
      tz_data.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
      // Android 初始化配置。
      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      // Windows 初始化配置。
      const WindowsInitializationSettings windowsSettings =
          WindowsInitializationSettings(
            appName: 'Omni Butler',
            appUserModelId: 'OmniButler.Desktop.App',
            guid: _windowsNotificationGuid,
          );
      // 当前支持平台的统一初始化配置。
      const InitializationSettings settings = InitializationSettings(
        android: androidSettings,
        windows: windowsSettings,
      );
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          // 当前通知业务载荷。
          final String? payload = response.payload;
          if (payload != null && payload.isNotEmpty) {
            _payloadController.add(payload);
          }
        },
      );
      // 由通知启动应用时的初始载荷。
      final NotificationAppLaunchDetails? launchDetails = await _plugin
          .getNotificationAppLaunchDetails();
      initialPayload = launchDetails?.notificationResponse?.payload;
      availability = NotificationAvailability.ready;
      lastError = null;
    } on Object catch (error) {
      availability = NotificationAvailability.failed;
      lastError = error.toString();
    }
  }

  /// 根据最新业务记录重建全部未来提醒。
  Future<void> reconcile(List<PlannedNotification> plans) async {
    if (availability != NotificationAvailability.ready ||
        _preferences == null) {
      return;
    }
    try {
      // 最新通知计划指纹。
      final String fingerprint = sha256
          .convert(
            utf8.encode(
              plans
                  .map((PlannedNotification plan) => plan.fingerprintPart)
                  .join('\n'),
            ),
          )
          .toString();
      if (_preferences.getString(_scheduleFingerprintKey) == fingerprint) {
        return;
      }
      // 上一次已调度的通知标识。
      final List<int> previousIds =
          _preferences
              .getStringList(_scheduledIdsKey)
              ?.map(int.parse)
              .toList(growable: false) ??
          const <int>[];
      for (final int id in previousIds) {
        await _plugin.cancel(id: id);
      }
      // 本次已调度的通知标识。
      final List<String> scheduledIds = <String>[];
      for (final PlannedNotification plan in plans) {
        // 当前通知的稳定整数标识。
        final int id = _stableId(plan.key);
        await _plugin.zonedSchedule(
          id: id,
          title: plan.title,
          body: plan.body,
          scheduledDate: tz.TZDateTime.from(plan.scheduledAt, tz.local),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'omni_butler_reminders',
              '生活提醒',
              channelDescription: '待办、周期事件和会员提醒',
              importance: Importance.high,
              priority: Priority.high,
            ),
            windows: WindowsNotificationDetails(subtitle: 'Omni Butler'),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: plan.payload,
        );
        scheduledIds.add(id.toString());
      }
      await _preferences.setStringList(_scheduledIdsKey, scheduledIds);
      await _preferences.setString(_scheduleFingerprintKey, fingerprint);
      lastError = null;
    } on Object catch (error) {
      availability = NotificationAvailability.failed;
      lastError = error.toString();
    }
  }

  /// 立即发送一条测试通知。
  Future<bool> showTestNotification() async {
    if (availability != NotificationAvailability.ready) {
      return false;
    }
    try {
      await _plugin.show(
        id: _stableId('test'),
        title: 'Omni Butler 通知已就绪',
        body: '之后会按你设置的时间提醒待办、事件和会员。',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'omni_butler_reminders',
            '生活提醒',
            channelDescription: '待办、周期事件和会员提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
          windows: WindowsNotificationDetails(subtitle: '测试通知'),
        ),
        payload: 'settings',
      );
      return true;
    } on Object catch (error) {
      availability = NotificationAvailability.failed;
      lastError = error.toString();
      return false;
    }
  }

  /// 将业务键转换为跨启动稳定的正整数通知标识。
  int _stableId(String key) {
    // 业务键的 SHA-256 字节。
    final List<int> bytes = sha256.convert(utf8.encode(key)).bytes;
    return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
        0x7fffffff;
  }

  /// 释放通知点击载荷流。
  Future<void> dispose() => _payloadController.close();
}
