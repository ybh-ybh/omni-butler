import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/notifications/local_notification_service.dart';
import 'package:omni_butler/core/notifications/notification_providers.dart';
import 'package:omni_butler/features/memberships/data/membership_repository.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';

/// Omni Butler 根应用。
class OmniButlerApp extends ConsumerStatefulWidget {
  /// 创建根应用。
  const OmniButlerApp({super.key});

  /// 创建根应用状态。
  @override
  ConsumerState<OmniButlerApp> createState() => _OmniButlerAppState();
}

/// Omni Butler 根应用状态。
class _OmniButlerAppState extends ConsumerState<OmniButlerApp> {
  /// 通知点击载荷订阅。
  StreamSubscription<String>? _payloadSubscription;

  /// 自动续费检查定时器。
  Timer? _autoRenewalTimer;

  /// 是否正在执行自动续费检查。
  bool _autoRenewalRunning = false;

  /// 初始化通知点击导航。
  @override
  void initState() {
    super.initState();
    // 当前平台通知服务。
    final LocalNotificationService service = ref.read(
      localNotificationServiceProvider,
    );
    _payloadSubscription = service.payloads.listen(_openNotificationPayload);
    // 由系统通知启动应用时的初始载荷。
    final String? initialPayload = service.initialPayload;
    if (initialPayload != null) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        _openNotificationPayload(initialPayload);
      });
    }
    unawaited(_processAutoRenewals());
    _autoRenewalTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_processAutoRenewals()),
    );
  }

  /// 执行一次已到期会员的自动续费处理。
  Future<void> _processAutoRenewals() async {
    // 当前设备功能偏好。
    final FeaturePreference featurePreference = ref.read(
      featurePreferenceProvider,
    );
    if (_autoRenewalRunning ||
        !featurePreference.isEnabled(AppFeature.memberships)) {
      return;
    }
    _autoRenewalRunning = true;
    try {
      final MembershipRepository repository = ref.read(
        membershipRepositoryProvider,
      );
      await repository.processAutoRenewals(DateTime.now());
    } catch (error, stackTrace) {
      debugPrint('自动续费处理失败：$error\n$stackTrace');
    } finally {
      _autoRenewalRunning = false;
    }
  }

  /// 根据通知业务载荷跳转到对应模块。
  void _openNotificationPayload(String payload) {
    // 应用路由器。
    final router = ref.read(appRouterProvider);
    if (payload.startsWith('todo:')) {
      router.go('/todos');
    } else if (payload.startsWith('event:')) {
      router.go('/events');
    } else if (payload.startsWith('membership:')) {
      router.go('/memberships');
    } else {
      router.go('/settings');
    }
  }

  /// 释放通知载荷订阅。
  @override
  void dispose() {
    _payloadSubscription?.cancel();
    _autoRenewalTimer?.cancel();
    super.dispose();
  }

  /// 构建带路由和双配色主题的应用。
  @override
  Widget build(BuildContext context) {
    ref.watch(notificationCoordinatorProvider);
    ref.watch(syncControllerProvider);
    // 当前主题偏好。
    final ThemePreference preference = ref.watch(themeControllerProvider);
    // 应用路由器。
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Omni Butler',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(brightness: Brightness.light),
      darkTheme: AppTheme.build(brightness: Brightness.dark),
      themeMode: preference.mode,
      routerConfig: router,
    );
  }
}
