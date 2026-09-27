import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/notifications/local_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// 可暂停原生调度的插件替身，观察实际安装和撤销顺序。
class _ControlledNotifications implements FlutterLocalNotificationsPlugin {
  /// 当前原生系统仍保存的通知。
  final Map<int, String?> installed = <int, String?>{};

  /// 原生调度调用的业务载荷。
  final List<String?> schedules = <String?>[];

  /// 第一条计划已经进入不可撤销的原生调用。
  final Completer<void> started = Completer<void>();

  /// 延迟第一条原生调用完成。
  final Completer<void> release = Completer<void>();

  /// 是否暂停第一条计划。
  bool holdFirst = true;

  /// 是否模拟迟到的旧原生调用失败。
  bool failFirst = false;

  /// 注销已经登记的通知。
  @override
  Future<void> cancel({required int id, String? tag}) async {
    installed.remove(id);
  }

  /// 原生层在返回前可被迁移状态变化打断其调用方。
  @override
  Future<void> zonedSchedule({
    required int id,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    schedules.add(payload);
    if (schedules.length == 1 && holdFirst) {
      started.complete();
      await release.future;
      if (failFirst) throw StateError('旧数据源原生调用迟到失败');
    }
    installed[id] = payload;
  }

  /// 测试未使用的平台功能不得被调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 创建不依赖当前时钟的待执行通知计划。
PlannedNotification _plan(String owner) => PlannedNotification(
  key: 'todo:$owner',
  title: owner,
  body: '通知测试',
  scheduledAt: DateTime.utc(2027, 1, 1),
  payload: 'todo:$owner',
);

/// 计算成功计划应持久保存的指纹。
String _fingerprint(PlannedNotification plan) =>
    sha256.convert(utf8.encode(plan.fingerprintPart)).toString();

/// 验证维护切换、在途调用、恢复和禁用平台不会污染新数据源通知。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tz_data.initializeTimeZones();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('旧原生调度迟到后新计划才执行并清理旧通知，最终指纹属于新数据源', () async {
    // 实际偏好写入和可控原生插件。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 暂停第一条旧数据源通知。
    final _ControlledNotifications plugin = _ControlledNotifications();
    // 跳过平台初始化，仅测生产调度流程。
    final LocalNotificationService service = LocalNotificationService(
      preferences,
      plugin: plugin,
    )..availability = NotificationAvailability.ready;
    // 第一条旧通知已进入原生调用，第二条尚未发出。
    final Future<void> old = service.reconcile(<PlannedNotification>[
      _plan('a'),
      _plan('a-next'),
    ]);
    await plugin.started.future;
    service.setMigrationSuspended(true);
    await service.reconcile(<PlannedNotification>[_plan('ignored')]);
    service.setMigrationSuspended(false);
    // 新数据源必须排队等待旧调用收尾。
    final Future<void> current = service.reconcile(<PlannedNotification>[
      _plan('b'),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(plugin.schedules, <String>['todo:a']);
    plugin.release.complete();
    await Future.wait(<Future<void>>[old, current]);
    expect(plugin.schedules, <String>['todo:a', 'todo:b']);
    expect(plugin.installed.values, <String>['todo:b']);
    expect(
      preferences.getString('notifications.schedule_fingerprint'),
      _fingerprint(_plan('b')),
    );
    expect(
      preferences.getStringList('notifications.scheduled_ids'),
      hasLength(1),
    );
    expect(service.availability, NotificationAvailability.ready);
    await service.dispose();
  });

  test('恢复时相同计划仍重新协调，避免部分取消后错误复用指纹', () async {
    // 偏好和原生替身均不依赖系统通知权限。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 本次不暂停原生操作。
    final _ControlledNotifications plugin = _ControlledNotifications()
      ..holdFirst = false;
    // 生产服务的通知调度状态。
    final LocalNotificationService service = LocalNotificationService(
      preferences,
      plugin: plugin,
    )..availability = NotificationAvailability.ready;
    await service.reconcile(<PlannedNotification>[_plan('a')]);
    await service.reconcile(<PlannedNotification>[_plan('a')]);
    expect(plugin.schedules, hasLength(1));
    service.setMigrationSuspended(true);
    service.setMigrationSuspended(false);
    await service.reconcile(<PlannedNotification>[_plan('a')]);
    expect(plugin.schedules, hasLength(2));
    expect(plugin.installed.values, <String>['todo:a']);
    expect(
      preferences.getString('notifications.schedule_fingerprint'),
      _fingerprint(_plan('a')),
    );
    await service.dispose();
  });

  test('旧代次原生失败不会禁用新数据源的通知服务', () async {
    // 用于核对最终通知记录的持久偏好。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 旧调用在切换后返回失败。
    final _ControlledNotifications plugin = _ControlledNotifications()
      ..failFirst = true;
    // 新数据源应在旧调用失败之后继续安装。
    final LocalNotificationService service = LocalNotificationService(
      preferences,
      plugin: plugin,
    )..availability = NotificationAvailability.ready;
    // 已开始的旧调用。
    final Future<void> old = service.reconcile(<PlannedNotification>[
      _plan('a'),
    ]);
    await plugin.started.future;
    service.setMigrationSuspended(true);
    service.setMigrationSuspended(false);
    // 切换后的新计划。
    final Future<void> current = service.reconcile(<PlannedNotification>[
      _plan('b'),
    ]);
    plugin.release.complete();
    await Future.wait(<Future<void>>[old, current]);
    expect(service.availability, NotificationAvailability.ready);
    expect(service.lastError, isNull);
    expect(plugin.installed.values, <String>['todo:b']);
    await service.dispose();
  });

  test('禁用服务保留原行为，维护开关不会触发原生调用', () async {
    // 无偏好和平台能力的默认测试服务。
    final LocalNotificationService service =
        LocalNotificationService.disabled();
    service.setMigrationSuspended(true);
    await service.reconcile(<PlannedNotification>[_plan('a')]);
    service.setMigrationSuspended(false);
    await service.reconcile(<PlannedNotification>[_plan('b')]);
    expect(service.availability, NotificationAvailability.unsupported);
    expect(service.lastError, isNull);
    await service.dispose();
  });
}
