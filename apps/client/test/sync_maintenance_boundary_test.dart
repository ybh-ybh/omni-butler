import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_providers.dart';
import 'package:omni_butler/core/sync/sync_maintenance_boundary.dart';

/// 只模拟已由 SQLite 集成测试验证的维护状态和用户按钮意图。
class _BoundaryCoordinator implements SyncConnectionCoordinator {
  /// 维护状态流保持与生产相同的广播语义。
  final StreamController<SyncConnectionState> _changes =
      StreamController<SyncConnectionState>.broadcast();

  /// 当前可同步读取的状态，覆盖应用初始帧。
  SyncConnectionState _state;

  /// 用户点击继续迁移的次数。
  int resumes = 0;

  /// 用户明确取消的次数。
  int cancellations = 0;

  /// 恢复过程中是否模拟故障并继续保持门禁。
  bool failResume = false;

  /// 创建独立维护状态替身。
  _BoundaryCoordinator(this._state);

  /// 提供当前状态给首帧读取。
  @override
  SyncConnectionState get state => _state;

  /// 提供后续状态变化。
  @override
  Stream<SyncConnectionState> get changes => _changes.stream;

  /// 同时更新直接读取和异步订阅两种状态来源。
  void publish(SyncConnectionState value) {
    _state = value;
    _changes.add(value);
  }

  /// 记录恢复请求；失败必须由边界捕获而不解除维护遮罩。
  @override
  Future<void> resume() async {
    resumes += 1;
    if (failResume) throw StateError('模拟重试失败');
  }

  /// 模拟协调器在安全取消后解除维护状态。
  @override
  Future<void> cancel() async {
    cancellations += 1;
    publish(SyncConnectionState(generation: state.generation + 1));
  }

  /// 状态代次切换后的释放动作在界面测试中没有真实数据库。
  @override
  Future<void> releaseRetired() async {}

  /// 测试结束释放流订阅。
  @override
  Future<void> close() => _changes.close();

  /// 未声明的生产数据操作不能被测试替身默默执行。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 持有真实本地状态的业务子树，检测维护切换是否意外重新挂载。
class _LifecycleProbe extends StatefulWidget {
  /// 创建生命周期探针，不使用全局键掩盖父级结构改变。
  const _LifecycleProbe({required this.onInitialize, required this.onDispose});

  /// 记录业务页面初始化次数。
  final VoidCallback onInitialize;

  /// 记录业务页面销毁次数。
  final VoidCallback onDispose;

  /// 创建包含用户未提交输入的页面状态。
  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

/// 输入与点击计数都属于页面自身，不能在维护切换时丢失。
class _LifecycleProbeState extends State<_LifecycleProbe> {
  /// 页面未提交的输入内容。
  final TextEditingController controller = TextEditingController();

  /// 页面输入焦点，用于验证维护时键盘准入被关闭。
  final FocusNode focus = FocusNode();

  /// 页面收到的真实按钮点击次数。
  int clicks = 0;

  /// 首次挂载时记录初始化，状态更新不应触发本方法。
  @override
  void initState() {
    super.initState();
    widget.onInitialize();
  }

  /// 只有整个应用子树卸载时才能释放输入状态。
  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    widget.onDispose();
    super.dispose();
  }

  /// 使用实际控件验证维护开始和结束两侧的可交互性。
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(
        key: const ValueKey<String>('lifecycle-button'),
        onPressed: () => setState(() {
          clicks += 1;
        }),
        child: Text('页面计数：$clicks'),
      ),
      TextField(
        key: const ValueKey<String>('lifecycle-input'),
        controller: controller,
        focusNode: focus,
      ),
    ],
  );
}

/// 挂载真实维护遮罩，业务按钮和输入框保持在遮罩下方。
Future<void> _mount(
  WidgetTester tester,
  _BoundaryCoordinator coordinator, {
  required VoidCallback onPressed,
  bool compact = false,
  FocusNode? focus,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        syncConnectionCoordinatorProvider.overrideWithValue(coordinator),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SyncMaintenanceBoundary(
            compact: compact,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextButton(
                  key: const ValueKey<String>('business-button'),
                  onPressed: onPressed,
                  child: const Text('修改旧数据'),
                ),
                TextField(
                  key: const ValueKey<String>('business-input'),
                  focusNode: focus,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 验证主窗口和悬浮窗共享的交互维护边界。
void main() {
  testWidgets('维护开始和结束保持有状态业务子树挂载，输入和交互随门禁恢复', (WidgetTester tester) async {
    // 使用生产 Provider 订阅通路，只替换协调器状态来源。
    final _BoundaryCoordinator coordinator = _BoundaryCoordinator(
      const SyncConnectionState(),
    );
    addTearDown(coordinator.close);
    // 页面初始化和销毁次数不应随遮罩切换变化。
    int initializations = 0;
    // 真正卸载前页面必须保持零次销毁。
    int disposals = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncConnectionCoordinatorProvider.overrideWithValue(coordinator),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SyncMaintenanceBoundary(
              child: _LifecycleProbe(
                onInitialize: () {
                  initializations += 1;
                },
                onDispose: () {
                  disposals += 1;
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 保存原始 State 引用，避免仅凭相同文字误判子树没有重新创建。
    final _LifecycleProbeState original = tester.state<_LifecycleProbeState>(
      find.byType(_LifecycleProbe),
    );
    await tester.tap(find.byKey(const ValueKey<String>('lifecycle-button')));
    await tester.enterText(
      find.byKey(const ValueKey<String>('lifecycle-input')),
      '未提交的内容',
    );
    expect(original.clicks, 1);
    expect(original.focus.hasFocus, isTrue);

    coordinator.publish(
      const SyncConnectionState(maintenance: true, busy: true, message: '正在迁移'),
    );
    await tester.pump();
    await tester.pump();
    expect(
      identical(tester.state(find.byType(_LifecycleProbe)), original),
      isTrue,
    );
    expect(initializations, 1);
    expect(disposals, 0);
    expect(original.controller.text, '未提交的内容');
    expect(original.focus.hasFocus, isFalse);
    await tester.tap(
      find.byKey(const ValueKey<String>('lifecycle-button')),
      warnIfMissed: false,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('lifecycle-input')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(original.clicks, 1);
    expect(original.focus.hasFocus, isFalse);
    expect(original.controller.text, '未提交的内容');

    coordinator.publish(const SyncConnectionState());
    await tester.pump();
    await tester.pump();
    expect(
      identical(tester.state(find.byType(_LifecycleProbe)), original),
      isTrue,
    );
    expect(initializations, 1);
    expect(disposals, 0);
    await tester.tap(find.byKey(const ValueKey<String>('lifecycle-button')));
    await tester.enterText(
      find.byKey(const ValueKey<String>('lifecycle-input')),
      '恢复后的内容',
    );
    expect(original.clicks, 2);
    expect(original.focus.hasFocus, isTrue);
    expect(original.controller.text, '恢复后的内容');

    await tester.pumpWidget(const SizedBox.shrink());
    expect(initializations, 1);
    expect(disposals, 1);
  });

  for (final bool compact in <bool>[false, true]) {
    testWidgets('${compact ? "悬浮窗" : "主窗口"}维护状态阻止旧页面点击并禁用输入焦点', (
      WidgetTester tester,
    ) async {
      // 初始没有维护状态，允许建立真实焦点。
      final _BoundaryCoordinator coordinator = _BoundaryCoordinator(
        const SyncConnectionState(),
      );
      addTearDown(coordinator.close);
      // 验证已有焦点在维护开始时被移除。
      final FocusNode focus = FocusNode();
      addTearDown(focus.dispose);
      // 旧页面真实收到的点击次数。
      int clicks = 0;
      await _mount(
        tester,
        coordinator,
        onPressed: () {
          clicks += 1;
        },
        compact: compact,
        focus: focus,
      );
      await tester.tap(find.byKey(const ValueKey<String>('business-input')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      coordinator.publish(
        const SyncConnectionState(
          maintenance: true,
          busy: true,
          message: '正在验证同步检查点',
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.tap(
        find.byKey(const ValueKey<String>('business-button')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(clicks, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('继续迁移'), findsNothing);
      expect(find.text('取消，保留本机数据'), findsNothing);
      expect(find.text(compact ? '正在迁移，请在主窗口继续' : '正在验证同步检查点'), findsOneWidget);
      // 清掉挂载订阅后再关闭替身流，避免测试资源遗留。
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('主窗口失败可重试但未知提交阶段不可取消，重试异常保持遮罩', (WidgetTester tester) async {
    // 提交结果未知时只能继续同一次迁移。
    final _BoundaryCoordinator coordinator = _BoundaryCoordinator(
      const SyncConnectionState(
        maintenance: true,
        message: '迁移已暂停',
        error: '服务器响应丢失',
        canCancel: false,
      ),
    )..failResume = true;
    addTearDown(coordinator.close);
    // 旧界面仍然保持挂载但不得收到任何点击。
    int clicks = 0;
    await _mount(
      tester,
      coordinator,
      onPressed: () {
        clicks += 1;
      },
    );
    expect(find.text('服务器响应丢失'), findsOneWidget);
    expect(find.text('继续迁移'), findsOneWidget);
    expect(find.text('取消，保留本机数据'), findsNothing);
    await tester.tap(find.text('继续迁移'));
    await tester.pump();
    expect(coordinator.resumes, 1);
    expect(tester.takeException(), isNull);
    expect(find.text('迁移已暂停'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('business-button')),
      warnIfMissed: false,
    );
    expect(clicks, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('仅 prepared 阶段显示安全取消，取消完成后业务按钮恢复', (WidgetTester tester) async {
    // 服务器尚未修改时才暴露取消入口。
    final _BoundaryCoordinator coordinator = _BoundaryCoordinator(
      const SyncConnectionState(
        maintenance: true,
        message: '已保留本机数据',
        error: '网络暂不可用',
        canCancel: true,
      ),
    );
    addTearDown(coordinator.close);
    // 用真实按钮验证维护解除后的交互恢复。
    int clicks = 0;
    await _mount(
      tester,
      coordinator,
      onPressed: () {
        clicks += 1;
      },
    );
    expect(find.text('取消，保留本机数据'), findsOneWidget);
    await tester.tap(find.text('取消，保留本机数据'));
    await tester.pump();
    await tester.pump();
    expect(coordinator.cancellations, 1);
    expect(find.text('已保留本机数据'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('business-button')));
    expect(clicks, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('悬浮窗错误状态只指引主窗口，不提供重试或取消入口', (WidgetTester tester) async {
    // 即使允许取消，悬浮窗也不执行跨库迁移操作。
    final _BoundaryCoordinator coordinator = _BoundaryCoordinator(
      const SyncConnectionState(
        maintenance: true,
        message: '迁移已暂停',
        error: '具体网络错误',
        canCancel: true,
      ),
    );
    addTearDown(coordinator.close);
    // 底层业务点击仍必须被挡住。
    int clicks = 0;
    await _mount(
      tester,
      coordinator,
      onPressed: () {
        clicks += 1;
      },
      compact: true,
    );
    expect(find.text('正在迁移，请在主窗口继续'), findsOneWidget);
    expect(find.text('具体网络错误'), findsNothing);
    expect(find.text('继续迁移'), findsNothing);
    expect(find.text('取消，保留本机数据'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('business-button')),
      warnIfMissed: false,
    );
    expect(clicks, 0);
    expect(coordinator.resumes, 0);
    expect(coordinator.cancellations, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
