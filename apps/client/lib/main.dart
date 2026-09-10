import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:window_manager/window_manager.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/notifications/local_notification_service.dart';
import 'package:omni_butler/core/notifications/notification_providers.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 初始化本地依赖并启动应用。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 初始化窗口管理并限制最小窗口尺寸。
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(512, 512));
  // 设备本地主题偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 当前平台系统安全存储。
  const FlutterSecureStorage secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );
  // 应用入口与 Riverpod 共用的设备会话仓储。
  const AuthRepository authRepository = AuthRepository(secureStorage);
  // 与设备会话状态共享的同步运行时。
  final OmniSyncRuntime syncRuntime = await OmniSyncRuntime.open(
    authRepository,
  );
  // 当前平台本地通知服务。
  final LocalNotificationService notificationService = LocalNotificationService(
    preferences,
  );
  await notificationService.initialize();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        secureStorageProvider.overrideWithValue(secureStorage),
        authRepositoryProvider.overrideWithValue(authRepository),
        appDatabaseProvider.overrideWithValue(syncRuntime.database),
        syncRuntimeProvider.overrideWithValue(syncRuntime),
        localNotificationServiceProvider.overrideWithValue(notificationService),
      ],
      child: const OmniButlerApp(),
    ),
  );
}
