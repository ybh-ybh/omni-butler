import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/attachments/image_sync_service.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';

/// 图片传输跟随业务会话和数据库代次，不增加客户端配置项。
final Provider<ImageSyncService?> imageSyncServiceProvider =
    Provider<ImageSyncService?>((Ref ref) {
      if (ref.watch(syncMaintenanceProvider) ||
          !ref.watch(syncPreferenceProvider)) {
        return null;
      }
      // 测试或尚未启动的同步运行时不创建后台任务。
      final runtime = ref.watch(syncRuntimeProvider);
      if (runtime == null || runtime.writesFrozen) return null;
      // 等业务身份恢复后才创建固定会话的传输器。
      final session = ref.watch(authControllerProvider).value;
      if (session == null || ref.watch(syncControllerProvider).hasError) {
        return null;
      }
      // 此实例只持有这一代数据库与认证仓储。
      final ImageSyncService service = ImageSyncService(
        database: ref.watch(appDatabaseProvider),
        auth: ref.watch(authRepositoryProvider),
      );
      // 迁移协调器必须等待图片任务停止，才能导出一致快照。
      final unregister = ref
          .watch(syncConnectionCoordinatorProvider)
          ?.registerBackgroundStop(service.stop);
      ref.onDispose(() {
        // 排空完成前保留钩子，维护流程仍可等待已销毁 Provider 的任务。
        unawaited(service.stop().whenComplete(() => unregister?.call()));
      });
      service.start();
      return service;
    });

/// 设置页展示图片同步能力、传输进度和失败说明。
final StreamProvider<ImageSyncState> imageSyncStateProvider =
    StreamProvider<ImageSyncState>((Ref ref) async* {
      // 与根应用共用唯一传输器。
      final ImageSyncService? service = ref.watch(imageSyncServiceProvider);
      yield service?.state ?? const ImageSyncState();
      if (service != null) yield* service.states;
    });
