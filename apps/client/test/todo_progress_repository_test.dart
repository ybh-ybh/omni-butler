import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_schema.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';

/// 覆盖手动确认、稳定步骤身份、撤销冲突与旧库升级。
void main() {
  /// 每个用例独立的业务数据库。
  late AppDatabase database;

  /// 待办仓储。
  late TodoRepository repository;

  /// 固定的计划日期。
  final DateTime day = DateTime(2026, 10, 7);

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TodoRepository(database);
  });
  tearDown(() => database.close());

  /// 创建包含指定数量进度项的任务。
  Future<TodoRecord> create({int count = 12}) async {
    await repository.save(
      TodoDraft(
        title: '阅读一本书',
        scheduledDate: day,
        taskType: TodoTaskType.progress,
        progressUnit: '章',
        progressSteps: List<TodoProgressStepDraft>.generate(
          count,
          (int index) =>
              TodoProgressStepDraft(name: index == 0 ? '  序言  ' : null),
        ),
      ),
    );
    return database.select(database.todoItems).getSingle();
  }

  /// 以原任务上下文保存新的进度结构。
  Future<void> structure(
    TodoRecord task,
    List<TodoProgressStepDraft>? steps,
  ) async {
    // 模拟编辑器打开时保存的结构基线。
    final List<TodoProgressStepRecord> baseline = await repository
        .watchProgressSteps(task.id)
        .first;
    await repository.save(
      TodoDraft(
        id: task.id,
        title: task.title,
        scheduledDate: day,
        taskType: TodoTaskType.progress,
        progressUnit: task.progressUnit,
        progressSteps: steps,
        progressStepsBaseline: baseline
            .map(
              (TodoProgressStepRecord step) =>
                  TodoProgressStepDraft(id: step.id, name: step.name),
            )
            .toList(),
      ),
    );
  }

  test('跳序记录 3/12、全满待确认、重开保留进度', () async {
    // 新任务和原始步骤身份。
    final TodoRecord task = await create();
    final List<TodoProgressStepRecord> steps = await repository
        .watchProgressSteps(task.id)
        .first;
    expect(steps.first.name, '序言');
    expect(steps[1].name, isNull);
    await repository.setProgressStepsCompleted(task.id, <String>[
      steps[0].id,
      steps[2].id,
      steps[7].id,
    ], true);
    expect(
      (await repository.watchProgressSteps(task.id).first)
          .where((TodoProgressStepRecord step) => step.isCompleted)
          .map((TodoProgressStepRecord step) => step.id),
      <String>[steps[0].id, steps[2].id, steps[7].id],
    );
    await expectLater(
      repository.confirmProgressTask(task.id),
      throwsFormatException,
    );
    await repository.setProgressStepsCompleted(
      task.id,
      steps.map((TodoProgressStepRecord step) => step.id).toList(),
      true,
    );
    expect((await repository.watchById(task.id).first)!.isCompleted, isFalse);
    await repository.confirmProgressTask(task.id);
    expect((await repository.watchById(task.id).first)!.completedAt, isNotNull);
    await repository.setCompleted(task.id, false);
    expect(
      (await repository.watchProgressSteps(task.id).first).every(
        (TodoProgressStepRecord step) => step.isCompleted,
      ),
      isTrue,
    );
    expect((await repository.watchById(task.id).first)!.completedAt, isNull);
  });

  test('改名和重排保留状态，批量撤销不覆盖后续修改', () async {
    // 两步任务及选择操作。
    final TodoRecord task = await create(count: 2);
    final List<TodoProgressStepRecord> steps = await repository
        .watchProgressSteps(task.id)
        .first;
    final TodoProgressChange change = await repository
        .setProgressStepsCompleted(task.id, <String>[
          steps.first.id,
          steps.last.id,
        ], true);
    expect(change.changedCount, 2);
    await structure(task, <TodoProgressStepDraft>[
      TodoProgressStepDraft(id: steps.last.id, name: '新名字'),
      TodoProgressStepDraft(id: steps.first.id),
    ]);
    // 项目被改名和重排后不能撤销旧批次。
    expect(await repository.undoProgressChange(change), isFalse);
    final List<TodoProgressStepRecord> current = await repository
        .watchProgressSteps(task.id)
        .first;
    expect(current.first.id, steps.last.id);
    expect(
      current.every((TodoProgressStepRecord step) => step.isCompleted),
      isTrue,
    );
    final TodoProgressChange next = await repository.setProgressStepsCompleted(
      task.id,
      <String>[current.first.id],
      false,
    );
    expect(await repository.undoProgressChange(next), isTrue);
    expect(
      (await repository.watchProgressSteps(task.id).first).first.isCompleted,
      isTrue,
    );
    expect((await repository.watchById(task.id).first)!.isCompleted, isFalse);
  });

  test('结构基线阻止旧编辑覆盖新增与改名，完成变化不阻止保存', () async {
    // 初始编辑基线。
    final TodoRecord task = await create(count: 1);
    final TodoProgressStepRecord step =
        (await repository.watchProgressSteps(task.id).first).single;
    final List<TodoProgressStepDraft> baseline = <TodoProgressStepDraft>[
      TodoProgressStepDraft(id: step.id, name: step.name),
    ];
    // 另一窗口新增项目，旧完整列表不允许删除它。
    await structure(task, <TodoProgressStepDraft>[
      ...baseline,
      const TodoProgressStepDraft(name: '新章节'),
    ]);
    await expectLater(
      repository.save(
        TodoDraft(
          id: task.id,
          title: '不应覆盖的标题',
          scheduledDate: day,
          taskType: TodoTaskType.progress,
          progressSteps: baseline,
          progressStepsBaseline: baseline,
        ),
      ),
      throwsFormatException,
    );
    expect((await repository.watchById(task.id).first)!.title, task.title);
    expect(await repository.watchProgressSteps(task.id).first, hasLength(2));
    // 获取新基线后仅改变完成状态，不构成结构冲突。
    final List<TodoProgressStepRecord> fresh = await repository
        .watchProgressSteps(task.id)
        .first;
    final List<TodoProgressStepDraft> freshBaseline = fresh
        .map(
          (TodoProgressStepRecord row) =>
              TodoProgressStepDraft(id: row.id, name: row.name),
        )
        .toList();
    await repository.setProgressStepsCompleted(task.id, <String>[
      step.id,
    ], true);
    await repository.save(
      TodoDraft(
        id: task.id,
        title: task.title,
        scheduledDate: day,
        taskType: TodoTaskType.progress,
        progressSteps: <TodoProgressStepDraft>[
          TodoProgressStepDraft(id: step.id, name: '修改后的序言'),
          freshBaseline.last,
        ],
        progressStepsBaseline: freshBaseline,
      ),
    );
    expect(
      (await repository.watchProgressSteps(task.id).first).first.isCompleted,
      isTrue,
    );
    // 同一长度的改名也必须被基线检测。
    await expectLater(
      repository.save(
        TodoDraft(
          id: task.id,
          title: task.title,
          scheduledDate: day,
          taskType: TodoTaskType.progress,
          progressSteps: freshBaseline,
          progressStepsBaseline: freshBaseline,
        ),
      ),
      throwsFormatException,
    );
    // 无结构修改时不需要基线，名称不会被旧输入覆盖。
    await repository.save(
      TodoDraft(
        id: task.id,
        title: '只改任务标题',
        scheduledDate: day,
        taskType: TodoTaskType.progress,
      ),
    );
    expect(
      (await repository.watchProgressSteps(task.id).first).first.name,
      '修改后的序言',
    );
  });

  test('服务端毫秒时间戳往返后仍可撤销，快速后续操作版本不同', () async {
    // 当前操作产生可稳定往返的毫秒版本。
    final TodoRecord task = await create(count: 1);
    final TodoProgressStepRecord step =
        (await repository.watchProgressSteps(task.id).first).single;
    final TodoProgressChange change = await repository
        .setProgressStepsCompleted(task.id, <String>[step.id], true);
    expect(change.changedAt.microsecond, 0);
    // 模拟服务器 TIMESTAMPTZ(3) 经 UTC 字符串下行。
    final DateTime roundTrip = DateTime.fromMillisecondsSinceEpoch(
      change.changedAt.millisecondsSinceEpoch,
      isUtc: true,
    );
    await (database.update(
      database.todoProgressSteps,
    )..where((TodoProgressSteps table) => table.id.equals(step.id))).write(
      TodoProgressStepsCompanion(updatedAt: Value<DateTime>(roundTrip)),
    );
    expect(await repository.undoProgressChange(change), isTrue);
    final TodoProgressChange next = await repository.setProgressStepsCompleted(
      task.id,
      <String>[step.id],
      true,
    );
    expect(next.changedAt.isAfter(change.changedAt), isTrue);
    expect(await repository.undoProgressChange(change), isFalse);
  });

  test('确认后撤销最近进度只重开，不撤回其他项目', () async {
    // 满进度并明确确认。
    final TodoRecord task = await create(count: 1);
    final TodoProgressStepRecord step =
        (await repository.watchProgressSteps(task.id).first).single;
    final TodoProgressChange change = await repository
        .setProgressStepsCompleted(task.id, <String>[step.id], true);
    await repository.confirmProgressTask(task.id);
    expect(await repository.undoProgressChange(change), isTrue);
    expect((await repository.watchById(task.id).first)!.isCompleted, isFalse);
    expect((await repository.watchById(task.id).first)!.completedAt, isNull);
  });

  test('删除父任务仅隐藏步骤，恢复不复活独立删除，永久清理所有步骤', () async {
    // 独立删除其中一项后再删除整任务。
    final TodoRecord task = await create(count: 2);
    final List<TodoProgressStepRecord> steps = await repository
        .watchProgressSteps(task.id)
        .first;
    await structure(task, <TodoProgressStepDraft>[
      TodoProgressStepDraft(id: steps.first.id),
    ]);
    await repository.delete(task.id);
    expect(await repository.watchProgressSteps(task.id).first, isEmpty);
    expect(
      (await database.select(database.todoProgressSteps).get()).where(
        (TodoProgressStepRecord step) => step.deletedAt == null,
      ),
      hasLength(1),
    );
    await repository.restore(task.id);
    expect(await repository.watchProgressSteps(task.id).first, hasLength(1));
    await repository.delete(task.id);
    // 回收站只计父任务，清空包含有效和单独删除的步骤。
    final RecycleBinRepository recycle = RecycleBinRepository(
      database,
      repository,
    );
    expect(await recycle.empty(), 1);
    expect(await database.select(database.todoProgressSteps).get(), isEmpty);
  });

  test('非法结构、重复与子任务拒绝且创建事务完整回滚', () async {
    await expectLater(create(count: 0), throwsFormatException);
    await expectLater(create(count: 1001), throwsFormatException);
    expect(await database.select(database.todoItems).get(), isEmpty);
    // 进度父项不允许普通子任务。
    final TodoRecord task = await create(count: 1);
    await expectLater(
      repository.save(
        TodoDraft(title: '子任务', scheduledDate: day, parentId: task.id),
      ),
      throwsFormatException,
    );
    await expectLater(
      repository.save(
        TodoDraft(
          title: '重复进度',
          scheduledDate: day,
          taskType: TodoTaskType.progress,
          repeatRule: TodoRepeatRule.daily,
          progressSteps: const <TodoProgressStepDraft>[TodoProgressStepDraft()],
        ),
      ),
      throwsFormatException,
    );
    expect(await database.select(database.todoItems).get(), hasLength(1));
    await expectLater(
      structure(task, const <TodoProgressStepDraft>[]),
      throwsFormatException,
    );
  });

  test('空合并结果不能确认；超限合并数据可保留编辑但不能继续增加', () async {
    // 模拟多设备合并后的原始数据库结果。
    final TodoRecord task = await create(count: 1);
    final TodoProgressStepRecord first =
        (await repository.watchProgressSteps(task.id).first).single;
    await (database.delete(
      database.todoProgressSteps,
    )..where((TodoProgressSteps table) => table.id.equals(first.id))).go();
    await expectLater(
      repository.confirmProgressTask(task.id),
      throwsFormatException,
    );
    // 直接落库代表下行合并，不能被本地结构上限截断。
    await database.batch((batch) {
      batch.insertAll(
        database.todoProgressSteps,
        List<TodoProgressStepsCompanion>.generate(
          1001,
          (int index) => TodoProgressStepsCompanion.insert(
            id: 'merged-$index',
            todoId: task.id,
            sortOrder: Value<int>(index * 1024),
            createdAt: day,
            updatedAt: day,
          ),
        ),
      );
    });
    final List<TodoProgressStepRecord> steps = await repository
        .watchProgressSteps(task.id)
        .first;
    final List<TodoProgressStepDraft> drafts = steps
        .map(
          (TodoProgressStepRecord step) =>
              TodoProgressStepDraft(id: step.id, name: '保留名称'),
        )
        .toList();
    await structure(task, drafts);
    expect(await repository.watchProgressSteps(task.id).first, hasLength(1001));
    await expectLater(
      structure(task, <TodoProgressStepDraft>[
        ...drafts,
        const TodoProgressStepDraft(),
      ]),
      throwsFormatException,
    );
  });

  test('旧迁移快照补充普通类型且步骤删除不计全局回收站', () {
    // v1 仅包含当时固定业务表。
    final Map<String, List<Map<String, Object?>>> tables =
        <String, List<Map<String, Object?>>>{
          for (final String name in SyncSnapshot.tableNames.where(
            (String name) => name != 'todo_progress_steps',
          ))
            name: <Map<String, Object?>>[],
        };
    tables['todo_items'] = <Map<String, Object?>>[
      <String, Object?>{'id': 'legacy', 'deleted_at': '2026-10-01'},
    ];
    final SyncSnapshot snapshot = SyncSnapshot.fromJson(<String, dynamic>{
      'version': 1,
      'tables': tables,
      'pendingOperations': 3,
    });
    expect(snapshot.tables['todo_items']!.single['task_type'], 'normal');
    expect(
      snapshot.tables['todo_items']!.single.containsKey('progress_unit'),
      isTrue,
    );
    expect(snapshot.tables['todo_progress_steps'], isEmpty);
    snapshot.tables['todo_progress_steps'] = <Map<String, Object?>>[
      <String, Object?>{'id': 'step', 'deleted_at': '2026-10-01'},
    ];
    expect(snapshot.deletedCount, 1);
    expect(snapshot.toJson()['version'], 2);
    expect(
      omniSyncSchema.rawTables.any(
        (table) => table.name == 'todo_progress_steps',
      ),
      isTrue,
    );
  });

  test('真实 v14 数据库升级保留原任务状态和日期', () async {
    // 独立文件用于跨版本重开。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_progress_v14_',
    );
    final File file = File('${directory.path}/db.sqlite');
    AppDatabase legacy = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await legacy
          .into(legacy.todoItems)
          .insert(
            TodoItemsCompanion.insert(
              id: 'old',
              title: '旧任务',
              scheduledDate: day,
              isCompleted: const Value<bool>(true),
              completedAt: Value<DateTime>(day),
              createdAt: day,
              updatedAt: day,
            ),
          );
      await legacy.customStatement('DROP TABLE todo_progress_steps');
      await legacy.customStatement(
        'ALTER TABLE todo_items DROP COLUMN task_type',
      );
      await legacy.customStatement(
        'ALTER TABLE todo_items DROP COLUMN progress_unit',
      );
      await legacy.customStatement('PRAGMA user_version = 14');
      await legacy.close();
      legacy = AppDatabase.forTesting(NativeDatabase(file));
      final TodoRecord record = await legacy
          .select(legacy.todoItems)
          .getSingle();
      expect(record.taskType, 'normal');
      expect(record.progressUnit, isNull);
      expect(record.isCompleted, isTrue);
      expect(record.completedAt, day);
      expect(await legacy.select(legacy.todoProgressSteps).get(), isEmpty);
    } finally {
      await legacy.close();
      await directory.delete(recursive: true);
    }
  });
}
