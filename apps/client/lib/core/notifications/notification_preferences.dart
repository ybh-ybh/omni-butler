import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通知总开关持久化键。
const String _enabledKey = 'notifications.enabled';

/// 待办通知持久化键。
const String _todoEnabledKey = 'notifications.todo_enabled';

/// 周期事件通知持久化键。
const String _eventEnabledKey = 'notifications.event_enabled';

/// 会员通知持久化键。
const String _membershipEnabledKey = 'notifications.membership_enabled';

/// 当前设备的通知偏好。
@immutable
class NotificationPreference {
  /// 是否开启全部通知。
  final bool enabled;

  /// 是否开启待办提醒。
  final bool todoEnabled;

  /// 是否开启周期事件提醒。
  final bool eventEnabled;

  /// 是否开启会员到期与续费提醒。
  final bool membershipEnabled;

  /// 创建通知偏好。
  const NotificationPreference({
    required this.enabled,
    required this.todoEnabled,
    required this.eventEnabled,
    required this.membershipEnabled,
  });

  /// 复制并替换指定通知偏好。
  NotificationPreference copyWith({
    bool? enabled,
    bool? todoEnabled,
    bool? eventEnabled,
    bool? membershipEnabled,
  }) {
    return NotificationPreference(
      enabled: enabled ?? this.enabled,
      todoEnabled: todoEnabled ?? this.todoEnabled,
      eventEnabled: eventEnabled ?? this.eventEnabled,
      membershipEnabled: membershipEnabled ?? this.membershipEnabled,
    );
  }
}

/// 当前设备通知偏好控制器。
class NotificationPreferenceController
    extends Notifier<NotificationPreference> {
  /// 从本机存储恢复通知偏好。
  @override
  NotificationPreference build() {
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.watch(sharedPreferencesProvider);
    return NotificationPreference(
      enabled: preferences.getBool(_enabledKey) ?? true,
      todoEnabled: preferences.getBool(_todoEnabledKey) ?? true,
      eventEnabled: preferences.getBool(_eventEnabledKey) ?? true,
      membershipEnabled: preferences.getBool(_membershipEnabledKey) ?? true,
    );
  }

  /// 保存通知总开关。
  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value);
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setBool(_enabledKey, value);
  }

  /// 保存待办通知开关。
  Future<void> setTodoEnabled(bool value) async {
    state = state.copyWith(todoEnabled: value);
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setBool(_todoEnabledKey, value);
  }

  /// 保存周期事件通知开关。
  Future<void> setEventEnabled(bool value) async {
    state = state.copyWith(eventEnabled: value);
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setBool(_eventEnabledKey, value);
  }

  /// 保存会员通知开关。
  Future<void> setMembershipEnabled(bool value) async {
    state = state.copyWith(membershipEnabled: value);
    // 当前设备偏好存储。
    final SharedPreferences preferences = ref.read(sharedPreferencesProvider);
    await preferences.setBool(_membershipEnabledKey, value);
  }
}

/// 当前设备通知偏好提供者。
final NotifierProvider<NotificationPreferenceController, NotificationPreference>
notificationPreferenceProvider =
    NotifierProvider<NotificationPreferenceController, NotificationPreference>(
      NotificationPreferenceController.new,
    );
