import 'dart:async';

import 'package:drift/drift.dart' show BooleanExpressionOperators, OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_panel.dart';
import 'package:omni_butler/features/todos/presentation/todo_progress_widgets.dart';
import 'package:omni_butler/shared/ui/omni_icon_button.dart';

/// 验证共享任务行直接加一的异步边界、失败重试和精确撤销。
void main() {
  _testAction('延迟提交重复点击只写一次且任务行卸载后仍完成捕获步骤', (
    WidgetTester tester,
    _QuickActionFixture fixture,
  ) async {
    fixture.repository.gate = Completer<void>();
    await _pumpTile(tester, fixture);
    // 捕获真实按钮当前公开回调，模拟同一帧到达的连续操作。
    final VoidCallback advance = tester
        .widget<OmniIconButton>(fixture.button)
        .onPressed!;
    advance();
    advance();
    await tester.pump();
    expect(fixture.repository.calls, 1);
    expect(tester.widget<OmniIconButton>(fixture.button).onPressed, isNull);
    expect(await fixture.completedIds(), fixture.originalCompletedIds);
    fixture.visible.value = false;
    await tester.pump();
    expect(find.byType(TodoProgressTaskTile), findsNothing);
    fixture.repository.gate!.complete();
    await _settleWrite(tester);
    expect(fixture.repository.calls, 1);
    expect(await fixture.completedIds(), <String>[
      fixture.steps[0].id,
      fixture.steps[1].id,
      fixture.steps[2].id,
    ]);
    expect(find.textContaining('已完成“'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _testAction('首次写入失败显示提示且保留原进度随后可再次点击成功', (
    WidgetTester tester,
    _QuickActionFixture fixture,
  ) async {
    fixture.repository.failNext = true;
    await _pumpTile(tester, fixture);
    await tester.tap(fixture.button);
    await _settleWrite(tester);
    expect(find.text('进度更新失败，请重试。'), findsOneWidget);
    expect(await fixture.completedIds(), fixture.originalCompletedIds);
    expect(tester.widget<OmniIconButton>(fixture.button).onPressed, isNotNull);
    await tester.tap(fixture.button);
    await _settleWrite(tester);
    expect(fixture.repository.calls, 2);
    expect(find.text('已完成“第2章”'), findsOneWidget);
    expect(find.text('进度更新失败，请重试。'), findsNothing);
    expect(await fixture.completedIds(), <String>[
      fixture.steps[0].id,
      fixture.steps[1].id,
      fixture.steps[2].id,
    ]);
  });

  _testAction('撤销仅恢复本次加一步骤并保留原完成项和之后的其它更新', (
    WidgetTester tester,
    _QuickActionFixture fixture,
  ) async {
    await _pumpTile(tester, fixture);
    await tester.tap(fixture.button);
    await _settleWrite(tester);
    expect(find.text('已完成“第2章”'), findsOneWidget);
    // 模拟另一入口随后完成不同步骤，当前撤销不得覆盖该独立写入。
    await TodoRepository(fixture.database).setProgressStepsCompleted(
      fixture.todo.id,
      <String>[fixture.steps[3].id],
      true,
    );
    await _settleWrite(tester);
    await tester.tap(find.text('撤销'));
    await _settleWrite(tester);
    expect(find.text('已撤销本次进度更新'), findsOneWidget);
    expect(await fixture.completedIds(), <String>[
      fixture.steps[0].id,
      fixture.steps[2].id,
      fixture.steps[3].id,
    ]);
    expect(
      (await fixture.database.select(fixture.database.todoItems).get())
          .single
          .isCompleted,
      isFalse,
    );
  });

  _testAction('步骤尚未加载或加载失败时加一保持禁用且不写数据库', (
    WidgetTester tester,
    _QuickActionFixture fixture,
  ) async {
    fixture.repository.controlledSteps =
        StreamController<List<TodoProgressStepRecord>>();
    await _pumpTile(tester, fixture);
    expect(find.text('正在读取进度…'), findsOneWidget);
    expect(tester.widget<OmniIconButton>(fixture.button).onPressed, isNull);
    await tester.tap(fixture.button);
    expect(fixture.repository.calls, 0);
    await tester.pumpAndSettle();
    expect(find.byType(TodoProgressPanel), findsNothing);
    fixture.repository.controlledSteps!.addError(StateError('模拟步骤加载失败'));
    await _settleWrite(tester);
    expect(find.text('进度读取失败'), findsOneWidget);
    expect(tester.widget<OmniIconButton>(fixture.button).onPressed, isNull);
    await tester.tap(fixture.button);
    expect(fixture.repository.calls, 0);
    await tester.pumpAndSettle();
    expect(find.byType(TodoProgressPanel), findsNothing);
    expect(await fixture.completedIds(), fixture.originalCompletedIds);
  });
}

/// 只控制外部异步结果，成功分支仍执行生产仓储的真实数据库写入。
class _ControlledTodoRepository extends TodoRepository {
  /// 可选提交闸门用于保持请求在途。
  Completer<void>? gate;

  /// 仅使下一次提交失败，后续仍可用同一按钮重试。
  bool failNext = false;

  /// 记录外部写入入口调用次数，验证重复操作没有变成重复请求。
  int calls = 0;

  /// 可选步骤流用于模拟尚无数据和加载错误。
  StreamController<List<TodoProgressStepRecord>>? controlledSteps;

  /// 最近一次在途写入，供清理过程等待真实完成。
  Future<TodoProgressChange>? pendingWrite;

  /// 与真实生产仓储共享同一个独立内存数据库。
  _ControlledTodoRepository(super.database);

  /// 返回可控步骤流或实际数据库流。
  @override
  Stream<List<TodoProgressStepRecord>> watchProgressSteps(String todoId) =>
      controlledSteps?.stream ?? super.watchProgressSteps(todoId);

  /// 让按钮真正经过生产仓储，只有时机和一次外部失败由测试控制。
  @override
  Future<TodoProgressChange> setProgressStepsCompleted(
    String todoId,
    List<String> stepIds,
    bool completed,
  ) {
    calls += 1;
    // 请求目标在调用时复制，避免调用方后续更改影响数据库断言。
    final List<String> ids = List<String>.unmodifiable(stepIds);
    return pendingWrite = _writeControlled(todoId, ids, completed);
  }

  /// 等待闸门后提交同一批目标或抛出一次模拟存储错误。
  Future<TodoProgressChange> _writeControlled(
    String todoId,
    List<String> stepIds,
    bool completed,
  ) async {
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('模拟写入失败');
    }
    return super.setProgressStepsCompleted(todoId, stepIds, completed);
  }
}

/// 每个场景持有自己的数据库、可控仓储和稳定步骤身份。
class _QuickActionFixture {
  /// 测试独占的内存数据库。
  final AppDatabase database;

  /// 仅控制外部延迟和失败的真实仓储子类。
  final _ControlledTodoRepository repository;

  /// 当前测试任务快照。
  final TodoRecord todo;

  /// 仓储实际顺序中的全部步骤。
  final List<TodoProgressStepRecord> steps;

  /// 在保留应用和仓储时卸载任务行。
  final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  /// 创建当前测试的共享上下文。
  _QuickActionFixture(this.database, this.repository, this.todo, this.steps);

  /// 当前任务行的公开加一按钮。
  Finder get button =>
      find.byKey(ValueKey<String>('progress-update-${todo.id}'));

  /// 初始跳序完成的第一和第三项。
  List<String> get originalCompletedIds => <String>[steps[0].id, steps[2].id];

  /// 从数据库读取真实完成集合，避免仅依赖组件局部状态。
  Future<List<String>> completedIds() async {
    // 返回顺序与生产仓储相同的有效完成步骤。
    final query = database.select(database.todoProgressSteps)
      ..where(
        (TodoProgressSteps table) =>
            table.isCompleted.equals(true) & table.deletedAt.isNull(),
      )
      ..orderBy([
        (TodoProgressSteps table) => OrderingTerm.asc(table.sortOrder),
      ]);
    return (await query.get())
        .map((TodoProgressStepRecord step) => step.id)
        .toList();
  }
}

/// 为异步边界用例准备真实数据，并在框架检查前完成所有资源清理。
void _testAction(
  String description,
  Future<void> Function(WidgetTester tester, _QuickActionFixture fixture)
  callback,
) {
  testWidgets(description, (WidgetTester tester) async {
    // 每个场景独占数据库，失败不会污染其他场景。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 不经过可控写入入口准备初始数据。
    final TodoRepository seedRepository = TodoRepository(database);
    // 保留调用前平台状态，避免测试全局不变量失败。
    final TargetPlatform? originalPlatform = debugDefaultTargetPlatformOverride;
    // 可控仓储从初始化到清理始终属于当前测试。
    final _ControlledTodoRepository repository = _ControlledTodoRepository(
      database,
    );
    // fixture 在种子创建完成之后才能构造。
    _QuickActionFixture? fixture;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await seedRepository.save(
        TodoDraft(
          title: '阅读四章',
          scheduledDate: DateTime(2026, 10, 7),
          taskType: TodoTaskType.progress,
          progressUnit: '章',
          progressSteps: List<TodoProgressStepDraft>.generate(
            4,
            (int index) => const TodoProgressStepDraft(),
          ),
        ),
      );
      // 真实仓储生成的任务身份。
      final TodoRecord todo =
          (await database.select(database.todoItems).get()).single;
      // 初始顺序用于核对加一精确选择第二项。
      final List<TodoProgressStepRecord> steps = await database
          .select(database.todoProgressSteps)
          .get();
      steps.sort(
        (TodoProgressStepRecord left, TodoProgressStepRecord right) =>
            left.sortOrder.compareTo(right.sortOrder),
      );
      await seedRepository.setProgressStepsCompleted(todo.id, <String>[
        steps[0].id,
        steps[2].id,
      ], true);
      fixture = _QuickActionFixture(database, repository, todo, steps);
      await callback(tester, fixture);
      expect(tester.takeException(), isNull);
    } finally {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        if (repository.gate != null && !repository.gate!.isCompleted) {
          repository.gate!.complete();
        }
        if (repository.pendingWrite != null) {
          try {
            await tester.runAsync(() => repository.pendingWrite!);
          } catch (_) {
            // 模拟失败已交给生产组件处理，清理仍需继续释放资源。
          }
        }
        await tester.runAsync(() async {
          await repository.controlledSteps?.close();
          await database.close();
        });
      } finally {
        fixture?.visible.dispose();
        debugDefaultTargetPlatformOverride = originalPlatform;
      }
    }
  });
}

/// 使用生产任务行和真实Provider覆盖构建可卸载的独立交互环境。
Future<void> _pumpTile(WidgetTester tester, _QuickActionFixture fixture) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(fixture.database),
        todoRepositoryProvider.overrideWithValue(fixture.repository),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: ValueListenableBuilder<bool>(
                valueListenable: fixture.visible,
                builder: (BuildContext context, bool visible, Widget? child) =>
                    visible
                    ? TodoProgressTaskTile(
                        todo: fixture.todo,
                        onEdit: () {},
                        onDelete: () {},
                        onConfirm: () {},
                      )
                    : const Text('任务行已移除'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _settleWrite(tester);
}

/// 只推进写库和短动画，保留成功提示中的真实撤销入口。
Future<void> _settleWrite(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await tester.pump(const Duration(milliseconds: 250));
}
