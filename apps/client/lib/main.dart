// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/notifications/local_notification_service.dart';
import 'package:omni_butler/core/notifications/notification_providers.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/floating/platform/windows_window_host.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/core/sync/sync_connection_store.dart';

/// 初始化本地依赖并启动应用。
Future<void> main() async {
  // Windows 端启用 Flutter 实验性同引擎多窗口能力。
  if (Platform.isWindows) {
    isWindowingEnabled = true;
  }
  WidgetsFlutterBinding.ensureInitialized();
  // 设备本地主题偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 当前平台系统安全存储。
  const FlutterSecureStorage secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );
  // 原数据库和迁移控制文件使用同一应用私有文档目录。
  final Directory documents = await getApplicationDocumentsDirectory();
  // 控制库不参与任何远端同步或业务清空。
  final SyncConnectionStore connectionStore = SyncConnectionStore(
    File(path.join(documents.path, 'omni_butler_connection.sqlite')),
  );
  // 崩溃后仅从原子提交过的活动指针恢复运行时。
  final Map<String, dynamic>? active = await connectionStore.read('active');
  // 旧安装无需移动原数据库，第一次迁移成功后才切换路径。
  final String databasePath =
      active?['databasePath'] as String? ??
      path.join(documents.path, 'omni_butler.sqlite');
  if (!path.isWithin(
    path.absolute(documents.path),
    path.absolute(databasePath),
  )) {
    throw StateError('活动数据库不在应用私有目录内，已停止启动');
  }
  // 活动会话键与活动数据库在控制库内同时提交。
  final AuthRepository authRepository = AuthRepository(
    secureStorage,
    storageKey: active?['sessionKey'] as String? ?? 'sync.device_session',
  );
  // 尚未启动业务订阅，因此可以先恢复迁移门禁。
  final OmniSyncRuntime syncRuntime = await OmniSyncRuntime.openAtPath(
    authRepository,
    databasePath,
  );
  // 主窗口和悬浮窗共享唯一迁移协调器。
  final SyncConnectionCoordinator coordinator = SyncConnectionCoordinator(
    store: connectionStore,
    secureStorage: secureStorage,
    directory: Directory(path.join(documents.path, 'sync_migrations')),
    runtime: syncRuntime,
    auth: authRepository,
  );
  await coordinator.initialize();
  // 当前平台本地通知服务。
  final LocalNotificationService notificationService = LocalNotificationService(
    preferences,
  );
  await notificationService.initialize();

  // 带有全部设备依赖覆盖的应用根节点。
  final Widget application = ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      secureStorageProvider.overrideWithValue(secureStorage),
      syncConnectionCoordinatorProvider.overrideWithValue(coordinator),
      authRepositoryProvider.overrideWith((Ref ref) {
        ref.watch(
          syncConnectionStateProvider.select(
            (state) => state.value?.generation,
          ),
        );
        return coordinator.auth;
      }),
      appDatabaseProvider.overrideWith((Ref ref) {
        ref.watch(
          syncConnectionStateProvider.select(
            (state) => state.value?.generation,
          ),
        );
        return coordinator.runtime.database;
      }),
      syncRuntimeProvider.overrideWith((Ref ref) {
        ref.watch(
          syncConnectionStateProvider.select(
            (state) => state.value?.generation,
          ),
        );
        return coordinator.runtime;
      }),
      localNotificationServiceProvider.overrideWithValue(notificationService),
    ],
    child: Platform.isWindows
        ? const WindowsWindowHost()
        : const OmniButlerApp(),
  );
  if (Platform.isWindows) {
    runWidget(application);
    return;
  }
  runApp(application);
}
