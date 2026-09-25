// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/shared/layout/responsive_shell.dart';
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 测试使用的在线设备会话。
const SyncSession _onlineSession = SyncSession(
  identity: SyncIdentity(id: 'responsive-shell-sync-user'),
  apiBaseUrl: 'http://127.0.0.1:3000/omni-butler/api/v1',
  isOffline: false,
);

/// 测试使用的离线设备会话。
const SyncSession _offlineSession = SyncSession(
  identity: SyncIdentity(id: 'responsive-shell-sync-user'),
  apiBaseUrl: 'http://127.0.0.1:3000/omni-butler/api/v1',
  isOffline: true,
);

/// 返回指定设备会话的认证控制器。
class _TestAuthController extends AuthController {
  /// 本次测试使用的设备会话。
  final SyncSession? session;

  /// 创建固定设备会话控制器。
  _TestAuthController(this.session);

  /// 返回固定设备会话。
  @override
  Future<SyncSession?> build() async => session;
}

/// 返回已完成状态的同步控制器。
class _IdleSyncController extends SyncController {
  /// 不执行实际同步连接。
  @override
  Future<void> build() async {}
}

/// 验证桌面壳层同步状态与顶栏入口。
void main() {
  testWidgets('关闭同步时隐藏侧栏状态且顶栏不再展示本机数据入口', (WidgetTester tester) async {
    await _pumpShell(tester, syncEnabled: false);

    expect(
      find.byKey(const ValueKey<String>('sidebar-sync-status')),
      findsNothing,
    );
    expect(find.text('仅保存在本机'), findsNothing);
    expect(find.byTooltip('个人本机数据'), findsNothing);
    expect(find.byTooltip('外观模式'), findsOneWidget);
    expect(find.text('搜索待办、事件、物品和会员'), findsOneWidget);

    tester.view.physicalSize = const Size(640, 760);
    await tester.pumpAndSettle();

    expect(find.byTooltip('个人本机数据'), findsNothing);
    expect(find.byTooltip('外观模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('连接尚未建立时显示连接中', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      status: _syncStatus(connected: false, connecting: true),
    );

    expect(find.text('连接中'), findsOneWidget);
  });

  testWidgets('上传下载、待上传队列和首次同步均显示正在同步', (WidgetTester tester) async {
    // 需要依次验证的同步中状态组合。
    final List<({SyncStatus status, int queueCount})>
    cases = <({SyncStatus status, int queueCount})>[
      (status: _syncStatus(connected: true, uploading: true), queueCount: 0),
      (status: _syncStatus(connected: true, downloading: true), queueCount: 0),
      (status: _syncStatus(connected: true, hasSynced: true), queueCount: 2),
      (status: _syncStatus(connected: true), queueCount: 0),
    ];

    for (final ({SyncStatus status, int queueCount}) testCase in cases) {
      await _pumpShell(
        tester,
        syncEnabled: true,
        status: testCase.status,
        queueCount: testCase.queueCount,
      );
      expect(find.text('正在同步'), findsOneWidget);
    }
  });

  testWidgets('完成完整同步且队列为空时显示同步完成', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      status: _syncStatus(connected: true, hasSynced: true),
    );

    expect(find.text('同步完成'), findsOneWidget);
    expect(find.text('本机数据已同步至服务器'), findsOneWidget);
  });

  testWidgets('离线状态优先于连接状态显示', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      session: _offlineSession,
      status: _syncStatus(connected: false, connecting: true),
    );

    expect(find.text('离线'), findsOneWidget);
  });

  testWidgets('完成过同步后连接中断显示离线', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      status: _syncStatus(connected: false, hasSynced: true),
    );

    expect(find.text('离线'), findsOneWidget);
  });

  testWidgets('PowerSync 错误优先显示同步异常', (WidgetTester tester) async {
    await _pumpShell(
      tester,
      syncEnabled: true,
      session: _offlineSession,
      status: _syncStatus(
        connected: false,
        connecting: true,
        error: StateError('测试同步异常'),
      ),
    );

    expect(find.text('同步异常'), findsOneWidget);
    expect(find.text('请前往设置查看详情'), findsOneWidget);
  });
}

/// 在桌面宽屏中挂载带指定同步状态的响应式壳层。
Future<void> _pumpShell(
  WidgetTester tester, {
  required bool syncEnabled,
  SyncSession? session = _onlineSession,
  SyncStatus? status,
  int queueCount = 0,
}) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': 'light',
    'sync.enabled': syncEnabled,
  });
  // 测试使用的设备偏好存储。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 未显式提供时使用的初始未连接状态。
  final SyncStatus effectiveStatus =
      status ?? _syncStatus(connected: false, connecting: false);

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        authControllerProvider.overrideWith(() => _TestAuthController(session)),
        syncControllerProvider.overrideWith(_IdleSyncController.new),
        syncStatusProvider.overrideWithValue(
          AsyncData<SyncStatus?>(effectiveStatus),
        ),
        syncUploadQueueCountProvider.overrideWithValue(
          AsyncData<int>(queueCount),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: const ResponsiveShell(
          location: '/home',
          child: SizedBox.expand(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 创建可控制关键字段的 PowerSync 状态。
SyncStatus _syncStatus({
  required bool connected,
  bool connecting = false,
  bool uploading = false,
  bool downloading = false,
  bool hasSynced = false,
  Object? error,
}) {
  return SyncStatus(
    connected: connected,
    connecting: connecting,
    lastSyncedAt: hasSynced ? DateTime.utc(2026, 9, 25, 12) : null,
    downloadProgress: null,
    downloading: downloading,
    uploading: uploading,
    downloadError: error,
    uploadError: null,
    priorityStatusEntries: const <SyncPriorityStatus>[],
    streamSubscriptions: null,
    lastAppliedCheckpoint: null,
  );
}
