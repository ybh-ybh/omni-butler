import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';

/// 正式入口注入同一协调器，所有窗口共用活动数据库和维护门禁。
final Provider<SyncConnectionCoordinator?> syncConnectionCoordinatorProvider =
    Provider<SyncConnectionCoordinator?>((Ref ref) => null);

/// 当前迁移状态及活动数据库代次。
final StreamProvider<SyncConnectionState> syncConnectionStateProvider =
    StreamProvider<SyncConnectionState>((Ref ref) async* {
      // 根应用持有的统一协调器。
      final SyncConnectionCoordinator? coordinator = ref.watch(
        syncConnectionCoordinatorProvider,
      );
      if (coordinator == null) {
        yield const SyncConnectionState();
        return;
      }
      yield coordinator.state;
      yield* coordinator.changes;
    });

/// 业务写入、自动任务及两种窗口共享的维护开关。
final Provider<bool> syncMaintenanceProvider = Provider<bool>((Ref ref) {
  // 优先读取已发布状态，初始帧同步读取协调器避免启动竞态。
  final AsyncValue<SyncConnectionState> state = ref.watch(
    syncConnectionStateProvider,
  );
  return ref.watch(syncConnectionCoordinatorProvider)?.state.maintenance ??
      state.value?.maintenance ??
      false;
});
