import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';

/// 单代数据库的回收站自动清理；停止时排空在途操作。
class RecycleBinCleanupCoordinator with WidgetsBindingObserver {
  /// 实际清理操作，可在测试中注入可控时钟。
  final Future<void> Function() purge;

  /// 当前是否允许写入，用于防止维护期间启动新操作。
  final bool Function() canRun;

  /// 定期检查间隔。
  final Duration interval;

  /// 已注册的周期检查。
  Timer? _timer;

  /// 当前清理操作，重复触发共用同一 Future。
  Future<void>? _running;

  /// 是否已经启动且尚未停止。
  bool _started = false;

  /// 创建可排空的自动清理协调器。
  RecycleBinCleanupCoordinator({
    required this.purge,
    required this.canRun,
    this.interval = const Duration(minutes: 1),
  });

  /// 启动时立即检查，同时监听前台恢复与分钟定时器。
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
    unawaited(check());
  }

  /// 应用恢复前台时及时处理关闭或休眠期间到期的记录。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(check());
  }

  /// 正常系统退出请求先排空清理事务，再允许引擎退出。
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await stop();
    return AppExitResponse.exit;
  }

  /// 同一时刻只清理一次，失败后允许下次检查重试。
  Future<void> check() {
    if (!_started || !canRun()) return Future<void>.value();
    return _running ??= _perform();
  }

  /// 包含同步异常的清理任务也统一捕获，避免产生未处理 Future。
  Future<void> _perform() async {
    try {
      await Future<void>.sync(purge);
    } catch (error, stackTrace) {
      debugPrint('回收站自动清理失败：$error\n$stackTrace');
    } finally {
      _running = null;
    }
  }

  /// 立即停止新触发，等待当前事务完成后再允许关闭数据库。
  Future<void> stop() async {
    _started = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    await _running;
  }
}

/// 根应用持有的清理任务，跟随数据库代次和维护状态重建。
final Provider<RecycleBinCleanupCoordinator?> recycleBinCleanupProvider =
    Provider<RecycleBinCleanupCoordinator?>((Ref ref) {
      if (ref.watch(syncMaintenanceProvider)) return null;
      // 当前运行时只用于检查写门禁，本地模式同样启动清理。
      final runtime = ref.watch(syncRuntimeProvider);
      if (runtime?.writesFrozen ?? false) return null;
      // 此清理器只持有当前数据库代次的仓储。
      final repository = ref.watch(recycleBinRepositoryProvider);
      // 当前代次停止后不能再读取已销毁的 Ref。
      bool disposed = false;
      // 本代数据库清理器。
      final RecycleBinCleanupCoordinator coordinator =
          RecycleBinCleanupCoordinator(
            purge: () async {
              await repository.purgeExpired();
            },
            canRun: () =>
                !disposed &&
                !ref.read(syncMaintenanceProvider) &&
                !(runtime?.writesFrozen ?? false),
          );
      // 维护协调器在冻结和关闭旧库前等待清理事务排空。
      final unregister = ref
          .watch(syncConnectionCoordinatorProvider)
          ?.registerBackgroundStop(coordinator.stop);
      ref.onDispose(() {
        disposed = true;
        unawaited(coordinator.stop().whenComplete(() => unregister?.call()));
      });
      coordinator.start();
      return coordinator;
    });
