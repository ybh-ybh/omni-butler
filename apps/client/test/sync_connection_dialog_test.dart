import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/features/settings/presentation/sync_connection_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 只记录用户意图的协调器替身，不修改任何会话或数据库。
class _DialogCoordinator implements SyncConnectionCoordinator {
  /// 预检返回的固定双方数据。
  final SyncConnectionPreview result;

  /// 已检查的服务器地址。
  final List<String> checkedAddresses = <String>[];

  /// 明确确认后才记录的数据策略。
  final List<SyncConnectionStrategy> strategies = <SyncConnectionStrategy>[];

  /// 同 owner 续连次数。
  int reconnects = 0;

  /// 延迟预检，用于验证提交期间禁止返回与重复请求。
  Completer<void>? previewGate;

  /// 延迟最终确认，用于验证迁移期间禁止退出。
  Completer<void>? confirmGate;

  /// 创建独立表单测试协调器。
  _DialogCoordinator(this.result);

  /// 模拟无副作用的预检。
  @override
  Future<SyncConnectionPreview> preview({
    required String serverAddress,
    required String syncKey,
  }) async {
    checkedAddresses.add(serverAddress);
    await previewGate?.future;
    return result;
  }

  /// 捕获迁移策略，不执行实际破坏操作。
  @override
  Future<void> start({
    required SyncConnectionPreview preview,
    required String syncKey,
    required SyncConnectionStrategy strategy,
  }) async {
    strategies.add(strategy);
    await confirmGate?.future;
  }

  /// 捕获用户明确确认的同 owner 续连。
  @override
  Future<void> reconnect({
    required SyncConnectionPreview preview,
    required String syncKey,
  }) async {
    reconnects++;
  }

  /// 与测试无关的接口不得被默默执行。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 创建展示不同数据来源和空本机情况的预检结果。
SyncConnectionPreview _preview({
  String? localOwnerId = 'owner-a',
  int localCount = 3,
}) => SyncConnectionPreview(
  serverAddress: 'http://192.168.1.10:9000',
  ownerId: 'owner-b',
  localOwnerId: localOwnerId,
  sourceAddress: localOwnerId == null ? null : 'https://a.example.com',
  localCounts: <String, int>{'todo_items': localCount},
  remoteCounts: const <String, int>{'todo_items': 7},
  localDeletedCount: 1,
  remoteDeletedCount: 2,
  queuedOperations: 4,
  maxOperations: 100000,
  maxBytes: 32 * 1024 * 1024,
);

/// 展示真实设置表单，仅替换统一连接协调器。
Future<void> _showDialog(
  WidgetTester tester,
  _DialogCoordinator? coordinator, {
  TargetPlatform platform = TargetPlatform.windows,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        syncConnectionCoordinatorProvider.overrideWithValue(coordinator),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: platform),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showSyncConnectionDialog(context),
              child: const Text('打开连接设置'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开连接设置'));
  await tester.pumpAndSettle();
}

/// 填写三项输入并完成只读预检。
Future<void> _checkServer(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).at(0), '192.168.1.10');
  await tester.enterText(find.byType(TextFormField).at(1), '9000');
  await tester.ensureVisible(find.byType(TextFormField).at(2));
  await tester.enterText(
    find.byType(TextFormField).at(2),
    'valid-deployment-secret',
  );
  await tester.tap(find.text('检查服务器'));
  await tester.pumpAndSettle();
}

/// 验证两步确认、三种策略、取消无副作用以及紧凑布局。
void main() {
  // 普通手机与窄屏大字号均覆盖键盘避让和草稿恢复。
  for (final (double width, double scale) in <(double, double)>[
    (390, 1),
    (320, 2),
  ]) {
    testWidgets('安卓全屏连接保持顶部操作、键盘避让与草稿 $width/$scale', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      // 不同来源场景需要明确确认替换方向。
      final _DialogCoordinator coordinator = _DialogCoordinator(_preview());
      await _showDialog(
        tester,
        coordinator,
        platform: TargetPlatform.android,
        textScale: scale,
      );
      expect(find.byType(OmniSideSheetScaffold), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('android-sync-connection-editor')),
        findsOneWidget,
      );
      expect(find.text('连接服务器'), findsOneWidget);
      // 键盘弹起与滚动不会带走取消或检查操作。
      final Offset submitPosition = tester.getTopLeft(
        find.byKey(const ValueKey<String>('sync-connection-submit')),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(TextFormField).at(2));
      expect(
        tester.getTopLeft(
          find.byKey(const ValueKey<String>('sync-connection-submit')),
        ),
        submitPosition,
      );
      expect(
        tester.getBottomLeft(find.byType(TextFormField).at(2)).dy,
        lessThanOrEqualTo(844 - 280),
      );
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await _checkServer(tester);
      expect(find.text('确认连接'), findsOneWidget);
      expect(coordinator.strategies, isEmpty);
      await tester.tap(find.text('返回修改'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(0))
            .controller!
            .text,
        '192.168.1.10',
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(2))
            .controller!
            .text,
        'valid-deployment-secret',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('android-sync-connection-editor')),
        findsNothing,
      );
      expect(coordinator.strategies, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('安卓预检和确认执行期间禁止退出与重复提交', (WidgetTester tester) async {
    // 两个异步阶段各有独立闸门。
    final _DialogCoordinator coordinator =
        _DialogCoordinator(_preview(localOwnerId: null))
          ..previewGate = Completer<void>()
          ..confirmGate = Completer<void>();
    await _showDialog(tester, coordinator, platform: TargetPlatform.android);
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'valid-deployment-secret',
    );
    await tester.tap(find.text('检查服务器'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.tap(find.text('取消'));
    await tester.tap(find.text('检查服务器'));
    expect(coordinator.checkedAddresses.length, 1);
    expect(find.text('连接服务器'), findsOneWidget);
    coordinator.previewGate!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并本机与服务器数据'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.tap(find.text('取消'));
    await tester.tap(find.text('合并本机与服务器数据'));
    expect(coordinator.strategies.length, 1);
    expect(find.text('确认连接'), findsOneWidget);
    coordinator.confirmGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('确认连接'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('协调器未就绪时显示错误，不绕过迁移流程直接连接', (WidgetTester tester) async {
    await _showDialog(tester, null);
    await _checkServer(tester);
    expect(find.textContaining('同步连接尚未就绪'), findsOneWidget);
    expect(find.text('连接自托管同步服务'), findsOneWidget);
    expect(find.text('确认数据处理方式'), findsNothing);
  });

  // 分别覆盖桌面与手机的首次连接确认。
  for (final Size size in <Size>[const Size(1100, 800), const Size(390, 844)]) {
    testWidgets('首次连接须预检和确认合并：${size.width}', (WidgetTester tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 从未连接过的数据只允许首次合并。
      final _DialogCoordinator coordinator = _DialogCoordinator(
        _preview(localOwnerId: null),
      );
      // 手机明确覆盖安卓全屏结构，桌面覆盖原有侧栏结构。
      final bool android = size.width < 500;
      await _showDialog(
        tester,
        coordinator,
        platform: android ? TargetPlatform.android : TargetPlatform.windows,
      );
      expect(find.byType(TextFormField), findsNWidgets(3));
      await _checkServer(tester);
      expect(coordinator.checkedAddresses, <String>['192.168.1.10:9000']);
      expect(coordinator.strategies, isEmpty);
      expect(find.text(android ? '确认连接' : '确认数据处理方式'), findsOneWidget);
      expect(find.text('本机：3 条记录 · 回收站 1 条'), findsOneWidget);
      expect(find.text('服务器：7 条记录 · 回收站 2 条'), findsOneWidget);
      expect(find.text('本机尚未上传：4 项操作'), findsOneWidget);
      expect(find.byType(RadioListTile<SyncConnectionStrategy>), findsNothing);
      await tester.tap(find.text('合并本机与服务器数据'));
      await tester.pumpAndSettle();
      expect(coordinator.strategies, <SyncConnectionStrategy>[
        SyncConnectionStrategy.mergeInitial,
      ]);
      expect(find.text(android ? '确认连接' : '确认数据处理方式'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('不同服务器默认保留服务端，明确确认后才替换本机', (WidgetTester tester) async {
    // 默认应避免误清远端数据。
    final _DialogCoordinator coordinator = _DialogCoordinator(_preview());
    await _showDialog(tester, coordinator);
    await _checkServer(tester);
    expect(find.text('本机来源：https://a.example.com'), findsOneWidget);
    expect(coordinator.strategies, isEmpty);
    await tester.tap(find.text('使用服务器数据替换本机'));
    await tester.pumpAndSettle();
    expect(coordinator.strategies, <SyncConnectionStrategy>[
      SyncConnectionStrategy.replaceLocal,
    ]);
  });

  testWidgets('空本机覆盖服务器显示清空警告并提交明确策略', (WidgetTester tester) async {
    // 本机空库仍允许覆盖，但必须显示全部清空的影响。
    final _DialogCoordinator coordinator = _DialogCoordinator(
      _preview(localCount: 0),
    );
    await _showDialog(tester, coordinator);
    await _checkServer(tester);
    await tester.ensureVisible(find.text('保留本机数据'));
    await tester.tap(find.text('保留本机数据'));
    await tester.pumpAndSettle();
    expect(find.text('本机没有业务记录：将清空服务器全部业务记录。'), findsOneWidget);
    expect(coordinator.strategies, isEmpty);
    await tester.tap(find.text('以本机数据覆盖此服务器'));
    await tester.pumpAndSettle();
    expect(coordinator.strategies, <SyncConnectionStrategy>[
      SyncConnectionStrategy.replaceServer,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预检后取消不建立会话、不提交迁移', (WidgetTester tester) async {
    // 任一来源都可在确认之前安全取消。
    final _DialogCoordinator coordinator = _DialogCoordinator(_preview());
    await _showDialog(tester, coordinator);
    await _checkServer(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(coordinator.strategies, isEmpty);
    expect(coordinator.reconnects, 0);
    expect(find.text('确认数据处理方式'), findsNothing);
  });

  testWidgets('相同 owner 继续原有同步，不显示替换策略', (WidgetTester tester) async {
    // 地址变化不等同于数据源身份变化。
    final _DialogCoordinator coordinator = _DialogCoordinator(
      _preview(localOwnerId: 'owner-b'),
    );
    await _showDialog(tester, coordinator);
    await _checkServer(tester);
    expect(find.byType(RadioListTile<SyncConnectionStrategy>), findsNothing);
    await tester.tap(find.text('继续原服务器同步'));
    await tester.pumpAndSettle();
    expect(coordinator.reconnects, 1);
    expect(coordinator.strategies, isEmpty);
  });

  testWidgets('非法端口或携带路径的地址在预检前提示错误', (WidgetTester tester) async {
    // 非法输入不能调用任何协调器动作。
    final _DialogCoordinator coordinator = _DialogCoordinator(_preview());
    await _showDialog(tester, coordinator);
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'valid-deployment-secret',
    );
    // 覆盖空值、范围边界和非整数输入。
    for (final String port in <String>['', '0', '65536', 'abc', '3.5']) {
      await tester.enterText(find.byType(TextFormField).at(1), port);
      await tester.tap(find.text('检查服务器'));
      await tester.pumpAndSettle();
      expect(find.text('端口必须是 1 到 65535 之间的整数'), findsOneWidget);
      expect(coordinator.checkedAddresses, isEmpty);
    }
    await tester.enterText(find.byType(TextFormField).at(1), '3000');
    await tester.enterText(
      find.byType(TextFormField).at(0),
      '192.168.1.10/omni-butler/api/v1',
    );
    await tester.tap(find.text('检查服务器'));
    await tester.pumpAndSettle();
    expect(find.text('请只填写 IP 地址或域名，端口在下方填写'), findsOneWidget);
    expect(coordinator.checkedAddresses, isEmpty);
  });
}
