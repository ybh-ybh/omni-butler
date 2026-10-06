import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_store.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_cleanup_coordinator.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/recycle_bin_fixture.dart';

/// 验证清理任务生命周期、重叠防护和数据库代次切换。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 测试两个独立数据库代次。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('根应用卸载立即取消定时器，同一容器重新挂载恢复清理', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    // 当前根应用共享的本机偏好。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 正常首页使用的独立业务库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 计数清理替代真实删除，重点验证根应用的持有周期。
    int calls = 0;
    // 根应用复用的可启停清理器。
    final RecycleBinCleanupCoordinator coordinator =
        RecycleBinCleanupCoordinator(
          purge: () async {
            calls++;
          },
          canRun: () => true,
        );
    // 保持同一个容器，模拟根窗口关闭后重新打开。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        recycleBinCleanupProvider.overrideWithValue(coordinator),
      ],
    );
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const OmniButlerApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 1));
      expect(calls, 1);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const OmniButlerApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 2);
      await coordinator.didRequestAppExit();
      await container
          .read(themeControllerProvider.notifier)
          .setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(calls, 2, reason: '退出后普通主题重建不能重新启动已停止的清理任务');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump(const Duration(milliseconds: 100));
      await database.close();
    }
  });
  testWidgets('启动和每分钟检查，前台恢复立即检查，停止后不再执行', (WidgetTester tester) async {
    // 已执行次数用于区分启动、定时和前台恢复。
    int calls = 0;
    // 独立清理器只注入无数据库副作用的计数操作。
    final RecycleBinCleanupCoordinator coordinator =
        RecycleBinCleanupCoordinator(
          purge: () async {
            calls++;
          },
          canRun: () => true,
        );
    coordinator.start();
    await tester.pump();
    expect(calls, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 2);
    coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(calls, 2);
    coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 3);
    await coordinator.stop();
    await tester.pump(const Duration(minutes: 2));
    coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(calls, 3);
  });

  testWidgets('重复触发共用操作，停止等待在途事务完成', (WidgetTester tester) async {
    // 阻塞清理模拟尚未结束的数据库事务。
    final Completer<void> gate = Completer<void>();
    // 实际启动次数。
    int calls = 0;
    // 可排空的清理器。
    final RecycleBinCleanupCoordinator coordinator =
        RecycleBinCleanupCoordinator(
          purge: () {
            calls++;
            return gate.future;
          },
          canRun: () => true,
        );
    coordinator.start();
    await tester.pump();
    unawaited(coordinator.check());
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 1);
    // 停止钩子必须等待当前操作完成。
    bool stopped = false;
    // 退出响应需等闸门放行，在测试主流程内断言结果。
    final Future<AppExitResponse> stopping = coordinator
        .didRequestAppExit()
        .then((AppExitResponse response) {
          stopped = true;
          return response;
        });
    await tester.pump();
    expect(stopped, isFalse);
    gate.complete();
    await tester.pump();
    expect(await stopping, AppExitResponse.exit);
    expect(stopped, isTrue);
    expect(calls, 1);
  });

  testWidgets('写门禁暂停任务，异常不会阻止下次重试', (WidgetTester tester) async {
    // 模拟迁移或冻结门禁。
    bool allowed = false;
    // 注入首次失败，随后检查可继续。
    int calls = 0;
    // 接受动态写门禁的清理器。
    final RecycleBinCleanupCoordinator coordinator =
        RecycleBinCleanupCoordinator(
          canRun: () => allowed,
          purge: () async {
            calls++;
            if (calls == 1) throw StateError('injected');
          },
        );
    coordinator.start();
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 0);
    allowed = true;
    await coordinator.check();
    expect(calls, 1);
    await coordinator.check();
    expect(calls, 2);
    await coordinator.stop();
  });

  test('维护期间不清理，新数据库代次立即重新检查', () async {
    // 旧数据库及切换后的新数据库。
    final AppDatabase first = AppDatabase.forTesting(NativeDatabase.memory());
    // 数据库切换后使用的独立实例。
    final AppDatabase second = AppDatabase.forTesting(NativeDatabase.memory());
    // 两个数据库都含一条必须清理的记录。
    final DateTime expired = DateTime.now().subtract(const Duration(days: 31));
    await seedRecycleRecord(first, RecycleEntityType.quote, 'first', expired);
    await seedRecycleRecord(second, RecycleEntityType.quote, 'second', expired);
    // 启动时模拟持久维护状态。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(first),
        syncMaintenanceProvider.overrideWithValue(true),
      ],
    );
    // 保持任务Provider挂载，模拟根应用持续监听。
    final subscription = container.listen(recycleBinCleanupProvider, (_, _) {});
    try {
      expect(container.read(recycleBinCleanupProvider), isNull);
      expect(await first.select(first.quotes).get(), hasLength(1));
      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(first),
        syncMaintenanceProvider.overrideWithValue(false),
      ]);
      await container.pump();
      // 等待真实异步事务，Widget假时钟不能代替数据库I/O。
      await container.read(recycleBinCleanupProvider)!.check();
      expect(await first.select(first.quotes).get(), isEmpty);
      // 旧任务必须停止，新任务持有新库。
      final RecycleBinCleanupCoordinator old = container.read(
        recycleBinCleanupProvider,
      )!;
      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(second),
        syncMaintenanceProvider.overrideWithValue(false),
      ]);
      await container.pump();
      await container.read(recycleBinCleanupProvider)!.check();
      expect(container.read(recycleBinCleanupProvider), isNot(same(old)));
      expect(await second.select(second.quotes).get(), isEmpty);
      await old.check();
    } finally {
      await container.read(recycleBinCleanupProvider)?.stop();
      subscription.close();
      container.dispose();
      await first.close();
      await second.close();
    }
  });

  test('Provider销毁后停止钩子仍保留，关闭真实数据库等待清理排空', () async {
    // 独立运行时与控制库，不访问用户数据。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_recycle_drain_',
    );
    // 无网络认证仓储。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 真实PowerSync共享数据库。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/runtime.sqlite',
      initializeUpload: false,
    );
    // 迁移和退出使用的真实协调器。
    final SyncConnectionCoordinator connection = SyncConnectionCoordinator(
      store: SyncConnectionStore(File('${directory.path}/control.sqlite')),
      secureStorage: const FlutterSecureStorage(),
      directory: directory,
      runtime: runtime,
      auth: auth,
    );
    // 在清理SQL前暂停，销毁Provider后仍必须能完成事务。
    final _BlockedRecycleRepository repository = _BlockedRecycleRepository(
      runtime.database,
    );
    await seedRecycleRecord(
      runtime.database,
      RecycleEntityType.quote,
      'expired',
      DateTime.now().subtract(const Duration(days: 31)),
    );
    // 注入正式停止钩子的依赖环境。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(runtime.database),
        syncRuntimeProvider.overrideWithValue(runtime),
        syncConnectionCoordinatorProvider.overrideWithValue(connection),
        recycleBinRepositoryProvider.overrideWithValue(repository),
      ],
    );
    container.read(recycleBinCleanupProvider);
    await container.pump();
    expect(repository.calls, 1);
    container.dispose();
    // 关闭不能抢先越过未完成的清理任务。
    bool closed = false;
    // 生产退出协调器等待所有后台停止钩子。
    final Future<void> closing = connection.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    repository.gate.complete();
    try {
      await closing.timeout(const Duration(seconds: 10));
      expect(closed, isTrue);
      expect(repository.deleted, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

/// 阻塞清理用于验证实际数据库在排空之前保持可用。
class _BlockedRecycleRepository extends RecycleBinRepository {
  /// 控制清理开始时机的闸门。
  final Completer<void> gate = Completer<void>();

  /// 已启动清理次数。
  int calls = 0;

  /// 真实SQL清理返回数量。
  int? deleted;

  /// 使用正式数据库与待办仓储。
  _BlockedRecycleRepository(AppDatabase database)
    : super(database, TodoRepository(database));

  /// 先等待闸门，再执行生产路径的过期删除事务。
  @override
  Future<int> purgeExpired({DateTime? now}) async {
    calls++;
    await gate.future;
    return deleted = await super.purgeExpired(now: now);
  }
}
