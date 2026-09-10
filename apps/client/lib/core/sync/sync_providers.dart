import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:powersync/powersync.dart';

/// 生产环境同步运行时提供者；应用入口必须覆盖该值。
final Provider<OmniSyncRuntime?> syncRuntimeProvider =
    Provider<OmniSyncRuntime?>((Ref ref) => null);

/// 根据设备同步会话自动连接或断开 PowerSync。
class SyncController extends AsyncNotifier<void> {
  /// 监听认证状态并应用对应同步连接。
  @override
  Future<void> build() async {
    // 当前生产同步运行时。
    final OmniSyncRuntime? runtime = ref.watch(syncRuntimeProvider);
    if (runtime == null) {
      return;
    }
    // 用户是否明确开启多端同步。
    final bool syncEnabled = ref.watch(syncPreferenceProvider);
    if (!syncEnabled) {
      await runtime.disconnect();
      return;
    }
    // 当前已恢复完成的设备同步会话。
    final SyncSession? session = await ref.watch(authControllerProvider.future);
    if (session == null || session.isOffline) {
      await runtime.disconnect();
      return;
    }
    await runtime.connect(session.identity.id);
  }

  /// 清空同步数据库，用于用户明确选择“断开并删除本机数据”。
  Future<void> clearLocalData() async {
    // 当前生产同步运行时。
    final OmniSyncRuntime? runtime = ref.read(syncRuntimeProvider);
    if (runtime != null) {
      await runtime.disconnectAndClear();
    }
  }
}

/// 设备会话驱动的 PowerSync 连接控制器。
final AsyncNotifierProvider<SyncController, void> syncControllerProvider =
    AsyncNotifierProvider<SyncController, void>(SyncController.new);

/// 当前 PowerSync 连接、上传和下载状态。
final StreamProvider<SyncStatus?> syncStatusProvider =
    StreamProvider<SyncStatus?>((Ref ref) async* {
      // 当前生产同步运行时。
      final OmniSyncRuntime? runtime = ref.watch(syncRuntimeProvider);
      if (runtime == null) {
        yield null;
        return;
      }
      yield runtime.powerSync.currentStatus;
      yield* runtime.powerSync.statusStream;
    });

/// 当前本地待上传操作数量。
final StreamProvider<int> syncUploadQueueCountProvider = StreamProvider<int>((
  Ref ref,
) async* {
  // 当前生产同步运行时。
  final OmniSyncRuntime? runtime = ref.watch(syncRuntimeProvider);
  if (runtime == null) {
    yield 0;
    return;
  }
  // 读取并输出当前队列大小。
  Future<int> loadCount() async {
    // PowerSync 队列统计。
    final UploadQueueStats stats = await runtime.powerSync
        .getUploadQueueStats();
    return stats.count;
  }

  yield await loadCount();
  await for (final _ in runtime.powerSync.updates) {
    yield await loadCount();
  }
});
