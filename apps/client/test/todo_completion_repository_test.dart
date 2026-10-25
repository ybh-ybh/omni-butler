import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';

/// 验证 Windows 完成历史共享的计数单元与双表实时更新。
void main() {
  /// 各用例独立的内存数据库。
  late AppDatabase database;

  /// 当前测试使用的业务仓储。
  late TodoRepository repository;

  /// 固定的历史完成时刻，避免与实际运行日混淆。
  final DateTime oldCompletion = DateTime(2026, 9, 12, 15, 30);

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TodoRepository(database);
  });

  tearDown(() => database.close());

  /// 建立带精确时间的任务，模拟本地或同步已保存的数据。
  Future<TodoRecord> seedTodo({
    required String id,
    String? title,
    String? description,
    String? parentId,
    TodoTaskType taskType = TodoTaskType.normal,
    String? progressUnit,
    bool completed = false,
    DateTime? completedAt,
    DateTime? deletedAt,
  }) async {
    await database
        .into(database.todoItems)
        .insert(
          TodoItemsCompanion.insert(
            id: id,
            title: title ?? id,
            description: Value<String?>(description),
            parentId: Value<String?>(parentId),
            taskType: Value<String>(taskType.name),
            progressUnit: Value<String?>(progressUnit),
            scheduledDate: DateTime(2025, 1, 1),
            isCompleted: Value<bool>(completed),
            completedAt: Value<DateTime?>(completedAt),
            deletedAt: Value<DateTime?>(deletedAt),
            createdAt: DateTime(2025, 1, 1),
            updatedAt: oldCompletion,
          ),
        );
    return (database.select(
      database.todoItems,
    )..where((TodoItems table) => table.id.equals(id))).getSingle();
  }

  /// 建立独立步骤，显式保留原顺序和完成时间。
  Future<TodoProgressStepRecord> seedStep({
    required String id,
    required String todoId,
    required int sortOrder,
    String? name,
    bool completed = false,
    DateTime? completedAt,
    DateTime? deletedAt,
  }) async {
    await database
        .into(database.todoProgressSteps)
        .insert(
          TodoProgressStepsCompanion.insert(
            id: id,
            todoId: todoId,
            name: Value<String?>(name),
            sortOrder: Value<int>(sortOrder),
            isCompleted: Value<bool>(completed),
            completedAt: Value<DateTime?>(completedAt),
            deletedAt: Value<DateTime?>(deletedAt),
            createdAt: DateTime(2025, 1, 1),
            updatedAt: oldCompletion,
          ),
        );
    return (database.select(
      database.todoProgressSteps,
    )..where((TodoProgressSteps table) => table.id.equals(id))).getSingle();
  }

  test('普通父项不重复计数，未确认父项下的完成子项仍进入历史', () async {
    await seedTodo(id: 'root', title: 'Release Notes', description: '发布说明上下文');
    await seedTodo(
      id: 'child',
      parentId: 'root',
      title: '检查构建',
      description: 'Windows BUILD',
      completed: true,
      completedAt: oldCompletion,
    );
    await seedTodo(
      id: 'normal',
      title: '独立任务',
      completed: true,
      completedAt: oldCompletion,
    );

    // 父项尚未确认时，独立任务和已完成子项各计一次。
    final List<TodoCompletionEntry> before = await repository
        .watchCompletionEntries()
        .first;
    expect(before.map((TodoCompletionEntry entry) => entry.id), <String>[
      'todo:child',
      'todo:normal',
    ]);
    expect(before.first.kind, TodoCompletionKind.subtask);
    expect(before.first.root.id, 'root');
    expect(before.last.kind, TodoCompletionKind.normal);
    expect(before.last.root.id, 'normal');
    expect(before.first.searchText, contains('release notes'));
    expect(before.first.searchText, contains('windows build'));
    expect(before.first.searchText, contains('发布说明上下文'));

    await repository.setCompleted('root', true);

    // 确认父任务不会新增计数，也不会改写已完成孩子的历史时间。
    final List<TodoCompletionEntry> after = await repository
        .watchCompletionEntries()
        .first;
    expect(after, hasLength(2));
    expect(after.first.completedAt, oldCompletion);
    expect(
      after.any((TodoCompletionEntry entry) => entry.id == 'todo:root'),
      isFalse,
    );
    expect(
      await repository.watchCompletedForDay(oldCompletion).first,
      hasLength(2),
    );
  });

  test('只按有效叶任务结构计数并隐藏缺失或删除父项下的记录', () async {
    await seedTodo(id: 'root', completed: true, completedAt: oldCompletion);
    await seedTodo(id: 'pending-child', parentId: 'root');
    await seedTodo(id: 'deleted-root', deletedAt: oldCompletion);
    await seedTodo(
      id: 'hidden-child',
      parentId: 'deleted-root',
      completed: true,
      completedAt: oldCompletion,
    );
    await seedTodo(
      id: 'orphan-child',
      parentId: 'missing-root',
      completed: true,
      completedAt: oldCompletion,
    );
    await seedTodo(id: 'missing-time', completed: true);
    await seedTodo(id: 'pending-with-time', completedAt: oldCompletion);
    expect(await repository.watchCompletionEntries().first, isEmpty);

    await repository.delete('pending-child');

    // 最后一个有效子项被删除后，已完成父项恢复为独立任务。
    final TodoCompletionEntry remaining =
        (await repository.watchCompletionEntries().first).single;
    expect(remaining.id, 'todo:root');
    expect(remaining.kind, TodoCompletionKind.normal);
  });

  test('跳序进度按步骤计数，名称与序号取自全部有效步骤', () async {
    await seedTodo(
      id: 'book',
      title: 'Reading Book',
      description: '学习笔记',
      taskType: TodoTaskType.progress,
      progressUnit: '章',
    );
    await seedStep(
      id: 'removed',
      todoId: 'book',
      sortOrder: 0,
      completed: true,
      completedAt: oldCompletion,
      deletedAt: oldCompletion,
    );
    await seedStep(id: 'first', todoId: 'book', sortOrder: 10);
    await seedStep(
      id: 'second',
      todoId: 'book',
      sortOrder: 20,
      name: '  Introduction  ',
      completed: true,
      completedAt: oldCompletion,
    );
    await seedStep(
      id: 'third',
      todoId: 'book',
      sortOrder: 30,
      name: '   ',
      completed: true,
      completedAt: oldCompletion,
    );
    await seedStep(
      id: 'no-time',
      todoId: 'book',
      sortOrder: 40,
      completed: true,
    );

    // 父任务未确认也显示已完成步骤，未完成项仍参与原始序号计算。
    final List<TodoCompletionEntry> entries = await repository
        .watchCompletionEntries()
        .first;
    expect(entries, hasLength(2));
    expect(
      entries.every(
        (TodoCompletionEntry entry) =>
            entry.kind == TodoCompletionKind.progress,
      ),
      isTrue,
    );
    expect(entries.first.id, 'step:second');
    expect(entries.first.title, 'Introduction');
    expect(entries.first.stepOrdinal, 2);
    expect(entries.first.root.id, 'book');
    expect(entries.first.searchText, contains('reading book'));
    expect(entries.first.searchText, contains('introduction'));
    expect(entries.first.searchText, contains('学习笔记'));
    expect(entries.last.stepOrdinal, 3);
    expect(entries.last.title, '第3章');
  });

  test('进度确认与重开不重复计数，步骤回退和精确撤销更新历史', () async {
    await seedTodo(id: 'book', taskType: TodoTaskType.progress);
    await seedStep(
      id: 'one',
      todoId: 'book',
      sortOrder: 10,
      completed: true,
      completedAt: oldCompletion,
    );
    await seedStep(
      id: 'two',
      todoId: 'book',
      sortOrder: 20,
      completed: true,
      completedAt: oldCompletion,
    );
    await repository.confirmProgressTask('book');
    expect(await repository.watchCompletionEntries().first, hasLength(2));
    await repository.setCompleted('book', false);
    expect(await repository.watchCompletionEntries().first, hasLength(2));

    // 撤销凭据保留步骤此前的完成时间。
    final TodoProgressChange change = await repository
        .setProgressStepsCompleted('book', <String>['two'], false);
    expect(await repository.watchCompletionEntries().first, hasLength(1));
    expect(await repository.undoProgressChange(change), isTrue);

    // 精确撤销恢复原完成日，不产生新的完成事件。
    final List<TodoCompletionEntry> restored = await repository
        .watchCompletionEntries()
        .first;
    expect(restored, hasLength(2));
    expect(restored.last.completedAt, oldCompletion);
    expect(restored.last.title, '第2步');
  });

  test('同一订阅响应步骤状态及父任务删除恢复，不依赖行数变化', () async {
    await seedTodo(id: 'book', taskType: TodoTaskType.progress);
    await seedStep(id: 'one', todoId: 'book', sortOrder: 10);

    // 持续订阅用于验证两张表更新都会触发新投影。
    final StreamIterator<List<TodoCompletionEntry>> updates =
        StreamIterator<List<TodoCompletionEntry>>(
          repository.watchCompletionEntries(),
        );
    try {
      expect(await updates.moveNext(), isTrue);
      expect(updates.current, isEmpty);
      await repository.setProgressStepsCompleted('book', <String>['one'], true);
      expect(
        await updates.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(updates.current.single.id, 'step:one');
      await repository.delete('book');
      expect(
        await updates.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(updates.current, isEmpty);
      await repository.restore('book');
      expect(
        await updates.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(updates.current.single.id, 'step:one');
    } finally {
      await updates.cancel();
    }
  });

  test('普通任务重开后移出历史，重新完成只保留新的完成时间', () async {
    await seedTodo(id: 'normal', completed: true, completedAt: oldCompletion);
    await repository.setCompleted('normal', false);
    expect(await repository.watchCompletionEntries().first, isEmpty);
    await repository.setCompleted('normal', true);

    // 当前状态只保留一个最新完成单元。
    final TodoCompletionEntry entry =
        (await repository.watchCompletionEntries().first).single;
    expect(entry.id, 'todo:normal');
    expect(entry.completedAt, isNot(oldCompletion));
  });

  test('完成时间归属本地自然日，同刻跨来源记录使用稳定身份排序', () async {
    // 本地午夜附近的实际时刻，以 UTC 数据模拟下行。
    final DateTime localCompletion = DateTime(2026, 10, 25, 0, 5);
    await seedTodo(
      id: 'same',
      completed: true,
      completedAt: localCompletion.toUtc(),
    );
    await seedTodo(id: 'book', taskType: TodoTaskType.progress);
    await seedStep(
      id: 'same',
      todoId: 'book',
      sortOrder: 10,
      completed: true,
      completedAt: localCompletion.toUtc(),
    );
    await seedTodo(id: 'older', completed: true, completedAt: oldCompletion);

    // 相同裸 ID 通过来源前缀区分，同时按完成时间倒序排列。
    final List<TodoCompletionEntry> entries = await repository
        .watchCompletionEntries()
        .first;
    expect(entries.map((TodoCompletionEntry entry) => entry.id), <String>[
      'step:same',
      'todo:same',
      'todo:older',
    ]);
    expect(entries.first.day, DateTime(2026, 10, 25));
    expect(entries.first.completedAt, localCompletion);
    expect(entries.first.completedAt.isUtc, isFalse);
  });
}
