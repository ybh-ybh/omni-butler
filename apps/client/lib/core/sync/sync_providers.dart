import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:powersync/powersync.dart';

/// 生产环境同步运行时提供者；应用入口必须覆盖该值。
final Provider<OmniSyncRuntime?> syncRuntimeProvider =
    Provider<OmniSyncRuntime?>((Ref ref) => null);

/// 根据设备同步会话自动连接或断开 PowerSync。
class SyncController extends AsyncNotifier<void> {
  /// 监听认证状态并应用对应同步连接。
  @override
  Future<void> build() async {
    // 迁移协调器独占连接控制，防止 Provider 重建将旧库连回服务器。
    if (ref.watch(syncMaintenanceProvider)) return;
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
    // 连接停止后仍由原有同步异常界面显示升级原因。
    if (runtime.schemaError != null) throw runtime.schemaError!;
    // SDK 在 build 返回后才可能发现错误，订阅补充运行期反馈。
    final StreamSubscription<SyncSchemaMismatch> schemaErrors = runtime
        .schemaErrors
        .listen((SyncSchemaMismatch error) {
          if (ref.mounted) state = AsyncError<void>(error, StackTrace.current);
        });
    ref.onDispose(schemaErrors.cancel);
    // 当前已恢复完成的设备同步会话。
    final SyncSession? session = await ref.watch(authControllerProvider.future);
    if (!ref.mounted ||
        ref.read(syncMaintenanceProvider) ||
        !identical(ref.read(syncRuntimeProvider), runtime) ||
        runtime.writesFrozen) {
      return;
    }
    if (session == null) {
      await runtime.disconnect();
      return;
    }
    // 离线缓存身份仍可连接引擎，由 PowerSync 在网络恢复后重试凭证和上传。
    await runtime.connect(session.identity.id);
    if (runtime.schemaError != null) throw runtime.schemaError!;
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
    AsyncNotifierProvider<SyncController, void>(
      SyncController.new,
      // 版本不兼容需要用户升级，不沿用 Riverpod 的默认自动重试。
      retry: (int count, Object error) => error is SyncSchemaMismatch
          ? null
          : ProviderContainer.defaultRetry(count, error),
    );

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

/// PowerSync 实际落库的业务表更新，用于补偿长期驻留窗口的数据刷新。
final StreamProvider<Set<String>> syncTableUpdatesProvider =
    StreamProvider<Set<String>>((Ref ref) async* {
      // 当前生产同步运行时。
      final OmniSyncRuntime? runtime = ref.watch(syncRuntimeProvider);
      if (runtime == null) {
        return;
      }
      await for (final update in runtime.powerSync.updates) {
        // 本次事务真实发生变化的业务表。
        final Set<String> tables = Set<String>.unmodifiable(update.tables);
        yield tables;
      }
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
