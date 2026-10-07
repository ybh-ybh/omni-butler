import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:uuid/uuid.dart';

/// 待办完成方式。
enum TodoTaskType {
  /// 普通勾选任务。
  normal,

  /// 逐项记录进度并手动确认完成。
  progress,
}

/// 结构编辑中的进度项；列表位置决定顺序。
class TodoProgressStepDraft {
  /// 原有进度项标识；空值表示新增。
  final String? id;

  /// 可选进度项名称。
  final String? name;

  /// 创建进度项草稿。
  const TodoProgressStepDraft({this.id, this.name});
}

/// 一次进度操作的撤销凭据，仅恢复未被后续操作改变的整批项目。
class TodoProgressChange {
  /// 所属任务标识。
  final String todoId;

  /// 本次实际改变前的项目快照。
  final List<TodoProgressStepRecord> steps;

  /// 本次写入时间。
  final DateTime changedAt;

  /// 本次目标完成状态。
  final bool completed;

  /// 创建只读撤销凭据。
  TodoProgressChange({
    required this.todoId,
    required List<TodoProgressStepRecord> steps,
    required this.changedAt,
    required this.completed,
  }) : steps = List<TodoProgressStepRecord>.unmodifiable(steps);

  /// 本次实际改变的进度项数。
  int get changedCount => steps.length;
}

/// 待办重复规则。
enum TodoRepeatRule {
  /// 不重复。
  none,

  /// 每天重复。
  daily,

  /// 每周重复。
  weekly,

  /// 每月重复。
  monthly,
}

/// 重复待办编辑或删除范围。
enum TodoSeriesScope {
  /// 只处理当前实例。
  single,

  /// 处理当前实例及此后的同系列实例。
  future,
}

/// 待办编辑草稿。
class TodoDraft {
  /// 可选现有记录标识。
  final String? id;

  /// 待办标题。
  final String title;

  /// 待办描述。
  final String? description;

  /// 待办完成方式；创建后不支持转换类型。
  final TodoTaskType taskType;

  /// 可选进度单位。
  final String? progressUnit;

  /// 完整进度结构；编辑时空值表示保留原结构。
  final List<TodoProgressStepDraft>? progressSteps;

  /// 打开结构编辑时的原有名称和顺序，防止覆盖期间新增或改名的项目。
  final List<TodoProgressStepDraft>? progressStepsBaseline;

  /// 可选父任务标识；为空表示主任务。
  final String? parentId;

  /// 所属自然日。
  final DateTime scheduledDate;

  /// 可选截止时间。
  final DateTime? dueAt;

  /// 优先象限。
  final TodoPriorityQuadrant priorityQuadrant;

  /// 提醒时间。
  final DateTime? reminderAt;

  /// 重复规则。
  final TodoRepeatRule repeatRule;

  /// 创建待办草稿。
  const TodoDraft({
    this.id,
    required this.title,
    this.description,
    this.taskType = TodoTaskType.normal,
    this.progressUnit,
    this.progressSteps,
    this.progressStepsBaseline,
    this.parentId,
    required this.scheduledDate,
    this.dueAt,
    this.priorityQuadrant = TodoPriorityQuadrant.importantNotUrgent,
    this.reminderAt,
    this.repeatRule = TodoRepeatRule.none,
  });
}

/// 进行中页面使用的两层待办树。
class TodoTreeNode {
  /// 主任务记录。
  final TodoRecord root;

  /// 主任务直属子任务。
  final List<TodoRecord> children;

  /// 创建两层待办树。
  const TodoTreeNode({required this.root, required this.children});

  /// 已完成子任务数量。
  int get completedChildrenCount =>
      children.where((TodoRecord child) => child.isCompleted).length;

  /// 未完成子任务数量。
  int get pendingChildrenCount => children.length - completedChildrenCount;

  /// 整棵树是否仍有未完成节点。
  bool get hasPending => !root.isCompleted || pendingChildrenCount > 0;
}

/// 完成历史中的待办及其父任务上下文。
class TodoHistoryEntry {
  /// 已完成待办记录。
  final TodoRecord todo;

  /// 可选父任务完整记录。
  final TodoRecord? parent;

  /// 可选父任务标题。
  String? get parentTitle => parent?.title;

  /// 创建完成历史条目。
  const TodoHistoryEntry({required this.todo, this.parent});
}

/// 待办本地优先仓储。
class TodoRepository {
  /// 创建及本地结构编辑时允许的进度项上限。
  static const int maxProgressSteps = 1000;

  /// 同级任务排序使用的默认间隔。
  static const int _sortOrderStep = 1024;

  /// 本地数据库。
  final AppDatabase _database;

  /// UUID 生成器。
  final Uuid _uuid;

  /// 创建待办仓储。
  TodoRepository(this._database, {this._uuid = const Uuid()});

  /// 监听指定未删除任务，供编辑侧栏追踪同步更新。
  Stream<TodoRecord?> watchById(String todoId) =>
      (_database.select(_database.todoItems)..where(
            (TodoItems table) =>
                table.id.equals(todoId) & table.deletedAt.isNull(),
          ))
          .watchSingleOrNull();

  /// 监听有效进度项；所属任务删除后返回空列表。
  Stream<List<TodoProgressStepRecord>> watchProgressSteps(String todoId) {
    // 同时订阅父表与步骤表，避免父项删除后的残留展示。
    final query =
        _database.select(_database.todoProgressSteps).join(<Join>[
            innerJoin(
              _database.todoItems,
              _database.todoItems.id.equalsExp(
                _database.todoProgressSteps.todoId,
              ),
            ),
          ])
          ..where(
            _database.todoProgressSteps.todoId.equals(todoId) &
                _database.todoProgressSteps.deletedAt.isNull() &
                _database.todoItems.deletedAt.isNull(),
          )
          ..orderBy(<OrderingTerm>[
            OrderingTerm.asc(_database.todoProgressSteps.sortOrder),
            OrderingTerm.asc(_database.todoProgressSteps.id),
          ]);
    return query.watch().map(
      (List<TypedResult> rows) => rows
          .map((TypedResult row) => row.readTable(_database.todoProgressSteps))
          .toList(growable: false),
    );
  }

  /// 监听指定自然日的有效待办。
  Stream<List<TodoRecord>> watchForDay(DateTime day) {
    // 规范化后的目标自然日。
    final DateTime normalizedDay = _normalizeDay(day);
    return Stream<void>.fromFuture(_materializeRepeats(normalizedDay))
        .asyncExpand((_) => _database.watchTodosForDay(normalizedDay));
  }

  /// 监听全部进行中任务树；任务不再受计划日期限制。
  Stream<List<TodoTreeNode>> watchActiveTrees(DateTime today) {
    // 规范化后的当前自然日。
    final DateTime normalizedToday = _normalizeDay(today);
    return Stream<void>.fromFuture(_materializeRepeats(normalizedToday))
        .asyncExpand((_) => _database.watchAllTodos())
        .map(_buildActiveTrees);
  }

  /// 监听指定完成日期的历史记录。
  Stream<List<TodoHistoryEntry>> watchCompletedForDay(DateTime day) {
    // 完成历史日期起点。
    final DateTime start = _normalizeDay(day);
    // 完成历史日期终点。
    final DateTime end = start.add(const Duration(days: 1));
    return _database.watchAllTodos().map((List<TodoRecord> records) {
      // 按标识索引的全部待办。
      final Map<String, TodoRecord> recordsById = <String, TodoRecord>{
        for (final TodoRecord record in records) record.id: record,
      };
      // 当天完成的历史条目。
      final List<TodoHistoryEntry> history = records
          .where((TodoRecord record) {
            // 当前完成时间。
            final DateTime? completedAt = record.completedAt;
            return record.isCompleted &&
                completedAt != null &&
                !completedAt.isBefore(start) &&
                completedAt.isBefore(end);
          })
          .map(
            (TodoRecord record) => TodoHistoryEntry(
              todo: record,
              parent: record.parentId == null
                  ? null
                  : recordsById[record.parentId!],
            ),
          )
          .toList(growable: false);
      history.sort((TodoHistoryEntry left, TodoHistoryEntry right) {
        return right.todo.completedAt!.compareTo(left.todo.completedAt!);
      });
      return history;
    });
  }

  /// 监听回收站中的待办。
  Stream<List<TodoRecord>> watchDeleted() {
    return _database.watchDeletedTodos();
  }

  /// 保存新增或编辑后的待办。
  Future<void> save(
    TodoDraft draft, {
    TodoSeriesScope scope = TodoSeriesScope.single,
  }) => _database.transaction(() => _save(draft, scope: scope));

  /// 在单一事务内保存任务与进度结构。
  Future<void> _save(TodoDraft draft, {required TodoSeriesScope scope}) async {
    // 清理后的标题。
    final String normalizedTitle = draft.title.trim();
    if (normalizedTitle.isEmpty) {
      throw const FormatException('待办标题不能为空');
    }
    if (draft.reminderAt != null &&
        draft.reminderAt!.isBefore(DateTime.now())) {
      throw const FormatException('提醒时间不能早于当前时间');
    }
    // 当前写入时间。
    final DateTime now = DateTime.now();
    // 可选现有记录标识。
    final String? existingId = draft.id;
    // 可选现有记录；编辑时用于保留父子关系。
    final TodoRecord? existingRecord = existingId == null
        ? null
        : await _todoById(existingId, includeDeleted: true);
    if (existingId != null &&
        (existingRecord == null || existingRecord.deletedAt != null)) {
      throw const FormatException('任务不存在或已被删除');
    }
    if (existingRecord != null &&
        existingRecord.taskType != draft.taskType.name) {
      throw const FormatException('创建后不能转换任务类型');
    }
    // 已规范化的可选单位。
    final String? progressUnit = _cleanOptional(draft.progressUnit);
    if ((progressUnit?.length ?? 0) > 10) {
      throw const FormatException('进度单位不能超过 10 个字符');
    }
    if (draft.taskType == TodoTaskType.progress &&
        (draft.parentId != null ||
            existingRecord?.parentId != null ||
            draft.repeatRule != TodoRepeatRule.none)) {
      throw const FormatException('进度任务只能独立创建，不能使用子任务或重复规则');
    }
    if (draft.taskType == TodoTaskType.normal &&
        (draft.progressSteps != null || progressUnit != null)) {
      throw const FormatException('普通任务不能包含进度项');
    }
    // 实际父任务标识；普通编辑不会意外提升子任务。
    final String? effectiveParentId =
        draft.parentId ?? existingRecord?.parentId;
    // 可选父任务记录。
    final TodoRecord? parent = effectiveParentId == null
        ? null
        : await (_database.select(_database.todoItems)..where(
                (TodoItems table) =>
                    table.id.equals(effectiveParentId) &
                    table.deletedAt.isNull(),
              ))
              .getSingleOrNull();
    if (effectiveParentId != null && parent == null) {
      throw const FormatException('父任务不存在或已被删除');
    }
    if (parent?.parentId != null) {
      throw const FormatException('当前版本只支持主任务和一级子任务');
    }
    if (parent?.taskType == TodoTaskType.progress.name) {
      throw const FormatException('进度任务不能添加子任务');
    }
    // 规范化后的重复规则。
    final String? repeatRule = parent != null
        ? null
        : draft.repeatRule == TodoRepeatRule.none
        ? null
        : draft.repeatRule.name;
    // 实际使用的优先象限；子任务继承主任务象限。
    final int effectivePriorityQuadrant =
        parent?.priorityQuadrant ?? draft.priorityQuadrant.value;
    // 实际计划日期；子任务继承主任务计划日期。
    final DateTime effectiveScheduledDate = _normalizeDay(
      parent?.scheduledDate ?? draft.scheduledDate,
    );
    if (existingId == null) {
      // 同一事务内创建任务和初始进度项。
      final String newId = _uuid.v7();
      // 重复系列标识。
      final String? seriesId = parent?.repeatSeriesId != null
          ? _uuid.v7()
          : draft.repeatRule == TodoRepeatRule.none
          ? null
          : _uuid.v7();
      // 当前同级列表末尾的排序值。
      final int sortOrder = await _nextSortOrder(
        parentId: parent?.id,
        priorityQuadrant: effectivePriorityQuadrant,
      );
      // 新增待办数据。
      final TodoItemsCompanion companion = TodoItemsCompanion.insert(
        id: newId,
        title: normalizedTitle,
        description: Value<String?>(_cleanOptional(draft.description)),
        taskType: Value<String>(draft.taskType.name),
        progressUnit: Value<String?>(progressUnit),
        parentId: Value<String?>(parent?.id),
        scheduledDate: effectiveScheduledDate,
        dueAt: Value<DateTime?>(draft.dueAt),
        priorityQuadrant: Value<int>(effectivePriorityQuadrant),
        reminderAt: Value<DateTime?>(draft.reminderAt),
        repeatRule: Value<String?>(repeatRule),
        repeatSeriesId: Value<String?>(seriesId),
        sortOrder: Value<int>(sortOrder),
        createdAt: now,
        updatedAt: now,
      );
      await _database.createTodo(companion);
      if (draft.taskType == TodoTaskType.progress) {
        await _saveProgressStructure(
          newId,
          draft.progressSteps ?? const <TodoProgressStepDraft>[],
          now,
          isNew: true,
        );
      }
      return;
    }

    if (scope == TodoSeriesScope.future) {
      // 当前原始实例。
      final TodoRecord? existing =
          await (_database.select(_database.todoItems)
                ..where((TodoItems table) => table.id.equals(existingId)))
              .getSingleOrNull();
      if (existing?.repeatSeriesId != null) {
        // 当前及未来同系列实例。
        final List<TodoRecord> futureRecords =
            await (_database.select(_database.todoItems)..where(
                  (TodoItems table) =>
                      table.repeatSeriesId.equals(existing!.repeatSeriesId!) &
                      table.scheduledDate.isBiggerOrEqualValue(
                        _normalizeDay(existing.scheduledDate),
                      ) &
                      table.deletedAt.isNull(),
                ))
                .get();
        for (final TodoRecord record in futureRecords) {
          await _database.updateTodo(
            record.id,
            TodoItemsCompanion(
              title: Value<String>(normalizedTitle),
              description: Value<String?>(_cleanOptional(draft.description)),
              dueAt: Value<DateTime?>(
                _moveClockToDay(draft.dueAt, record.scheduledDate),
              ),
              priorityQuadrant: Value<int>(effectivePriorityQuadrant),
              reminderAt: Value<DateTime?>(
                _moveClockToDay(draft.reminderAt, record.scheduledDate),
              ),
              repeatRule: Value<String?>(repeatRule),
              updatedAt: Value<DateTime>(now),
              syncState: const Value<String>('localSaved'),
            ),
          );
          if (record.parentId == null) {
            await _cascadeChildrenContext(
              record.id,
              scheduledDate: record.scheduledDate,
              priorityQuadrant: effectivePriorityQuadrant,
              now: now,
            );
          }
        }
        return;
      }
    }

    // 编辑单条待办数据，不覆盖创建时间和完成状态。
    final TodoItemsCompanion companion = TodoItemsCompanion(
      title: Value<String>(normalizedTitle),
      description: Value<String?>(_cleanOptional(draft.description)),
      progressUnit: Value<String?>(progressUnit),
      parentId: Value<String?>(parent?.id),
      scheduledDate: Value<DateTime>(effectiveScheduledDate),
      dueAt: Value<DateTime?>(draft.dueAt),
      priorityQuadrant: Value<int>(effectivePriorityQuadrant),
      reminderAt: Value<DateTime?>(draft.reminderAt),
      repeatRule: Value<String?>(repeatRule),
      updatedAt: Value<DateTime>(now),
      syncState: const Value<String>('localSaved'),
    );
    await _database.transaction(() async {
      await _database.updateTodo(existingId, companion);
      if (draft.taskType == TodoTaskType.progress &&
          draft.progressSteps != null) {
        await _saveProgressStructure(
          existingId,
          draft.progressSteps!,
          now,
          baseline: draft.progressStepsBaseline,
        );
      }
      if (existingRecord?.parentId == null) {
        await _cascadeChildrenContext(
          existingId,
          scheduledDate: effectiveScheduledDate,
          priorityQuadrant: effectivePriorityQuadrant,
          now: now,
        );
      }
    });
  }

  /// 切换待办完成状态。
  Future<void> setCompleted(String id, bool completed) async {
    // 读取一次当前目标；进度任务全满才可确认，普通任务沿用原树规则。
    final TodoRecord? target = await _todoById(id);
    if (target?.taskType == TodoTaskType.progress.name) {
      await _database.transaction(() async {
        // 在事务内重新校验，防止同步或其他窗口修改。
        final TodoRecord? current = await _todoById(id);
        if (current == null) return;
        if (completed) {
          // 当前有效进度项。
          final List<TodoProgressStepRecord> steps = await _progressSteps(id);
          if (steps.isEmpty ||
              steps.any((TodoProgressStepRecord step) => !step.isCompleted)) {
            throw const FormatException('请先完成全部进度项，再确认任务完成');
          }
        }
        if (current.isCompleted != completed) {
          await _writeCompletion(id, completed: completed, now: DateTime.now());
        }
      });
      return;
    }
    if (target == null) {
      return;
    }
    // 当前状态更新时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      if (target.parentId == null) {
        // 主任务完成或重开时对称级联，保持服务器按子任务派生的状态一致。
        final List<TodoRecord> tree = await _treeRecords(target.id);
        for (final TodoRecord record in tree) {
          if (record.isCompleted != completed) {
            await _writeCompletion(record.id, completed: completed, now: now);
          }
        }
        return;
      }
      await _writeCompletion(target.id, completed: completed, now: now);
      if (completed && target.parentId != null) {
        // 完成子任务后读取整棵任务树，判断它是否为最后一个未完成子任务。
        final List<TodoRecord> tree = await _treeRecords(target.parentId!);
        // 当前主任务。
        final TodoRecord? root = tree.isEmpty ? null : tree.first;
        // 当前主任务的全部直属子任务。
        final List<TodoRecord> children = tree.skip(1).toList(growable: false);
        // 是否已经完成全部直属子任务。
        final bool allChildrenCompleted =
            children.isNotEmpty &&
            children.every((TodoRecord child) => child.isCompleted);
        if (root != null && !root.isCompleted && allChildrenCompleted) {
          // 最后一个子任务完成时同步完成主任务，保持任务树整体状态一致。
          await _writeCompletion(root.id, completed: true, now: now);
        }
      }
      if (!completed && target.parentId != null) {
        // 子任务重新打开时同步重新打开主任务，保持树状态一致。
        await _writeCompletion(target.parentId!, completed: false, now: now);
      }
    });
  }

  /// 显式确认已经满进度的任务。
  Future<void> confirmProgressTask(String todoId) async {
    // 确认入口只适用于进度任务。
    final TodoRecord? target = await _todoById(todoId);
    if (target == null || target.taskType != TodoTaskType.progress.name) {
      throw const FormatException('进度任务不存在或已被删除');
    }
    await setCompleted(todoId, true);
  }

  /// 原子修改指定稳定进度项，满进度也不会自动完成任务。
  Future<TodoProgressChange> setProgressStepsCompleted(
    String todoId,
    List<String> stepIds,
    bool completed,
  ) => _database.transaction(() async {
    // 当前仍有效的任务。
    final TodoRecord? target = await _todoById(todoId);
    if (target == null || target.taskType != TodoTaskType.progress.name) {
      throw const FormatException('进度任务不存在或已被删除');
    }
    if (target.isCompleted) throw const FormatException('请先重新打开任务，再修改进度');
    // 调用方选择的稳定标识，重复选择只处理一次。
    final Set<String> selected = stepIds.toSet();
    // 当前完整有效步骤。
    final List<TodoProgressStepRecord> current = await _progressSteps(todoId);
    if (!selected.every(
      (String id) =>
          current.any((TodoProgressStepRecord step) => step.id == id),
    )) {
      throw const FormatException('选中的进度项已被修改或删除，请重新选择');
    }
    // 真正发生状态变化的项目，供撤销精确恢复。
    final List<TodoProgressStepRecord> changed = current
        .where(
          (TodoProgressStepRecord step) =>
              selected.contains(step.id) && step.isCompleted != completed,
        )
        .toList(growable: false);
    // 当前操作时间。
    final DateTime now = _progressWriteTime(changed);
    for (final TodoProgressStepRecord step in changed) {
      await (_database.update(
        _database.todoProgressSteps,
      )..where((TodoProgressSteps table) => table.id.equals(step.id))).write(
        TodoProgressStepsCompanion(
          isCompleted: Value<bool>(completed),
          completedAt: Value<DateTime?>(completed ? now : null),
          updatedAt: Value<DateTime>(now),
        ),
      );
    }
    await _reopenInvalidProgressTask(todoId, now);
    return TodoProgressChange(
      todoId: todoId,
      steps: changed,
      changedAt: now,
      completed: completed,
    );
  });

  /// 仅当整批项目仍处于本次操作后的状态时撤销，避免覆盖其他窗口或设备。
  Future<bool> undoProgressChange(TodoProgressChange change) =>
      _database.transaction(() async {
        // 当前目标任务；删除后的任务不能被撤销复活。
        final TodoRecord? target = await _todoById(change.todoId);
        if (target == null ||
            target.taskType != TodoTaskType.progress.name ||
            change.steps.isEmpty) {
          return false;
        }
        // 当前有效步骤的索引。
        final Map<String, TodoProgressStepRecord> current =
            <String, TodoProgressStepRecord>{
              for (final TodoProgressStepRecord step in await _progressSteps(
                change.todoId,
              ))
                step.id: step,
            };
        for (final TodoProgressStepRecord previous in change.steps) {
          // 目标项目必须仍精确匹配原操作结果。
          final TodoProgressStepRecord? step = current[previous.id];
          if (step == null ||
              step.isCompleted != change.completed ||
              !step.updatedAt.isAtSameMomentAs(change.changedAt)) {
            return false;
          }
        }
        // 撤销作为新的写入同步，而非删除原始同步操作。
        final DateTime now = _progressWriteTime(current.values);
        for (final TodoProgressStepRecord previous in change.steps) {
          await (_database.update(_database.todoProgressSteps)..where(
                (TodoProgressSteps table) => table.id.equals(previous.id),
              ))
              .write(
                TodoProgressStepsCompanion(
                  isCompleted: Value<bool>(previous.isCompleted),
                  completedAt: Value<DateTime?>(previous.completedAt),
                  updatedAt: Value<DateTime>(now),
                ),
              );
        }
        await _reopenInvalidProgressTask(change.todoId, now);
        return true;
      });

  /// 生成可经服务端毫秒精度往返的递增操作时间。
  DateTime _progressWriteTime(Iterable<TodoProgressStepRecord> steps) {
    // PostgreSQL 时间戳精确到毫秒；同项目的写入版本至少递增一毫秒。
    int milliseconds = DateTime.now().millisecondsSinceEpoch;
    for (final TodoProgressStepRecord step in steps) {
      if (step.updatedAt.millisecondsSinceEpoch >= milliseconds) {
        milliseconds = step.updatedAt.millisecondsSinceEpoch + 1;
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  /// 按展示顺序读取有效进度项。
  Future<List<TodoProgressStepRecord>> _progressSteps(String todoId) =>
      (_database.select(_database.todoProgressSteps)
            ..where(
              (TodoProgressSteps table) =>
                  table.todoId.equals(todoId) & table.deletedAt.isNull(),
            )
            ..orderBy(<OrderingTerm Function(TodoProgressSteps)>[
              (TodoProgressSteps table) => OrderingTerm.asc(table.sortOrder),
              (TodoProgressSteps table) => OrderingTerm.asc(table.id),
            ]))
          .get();

  /// 差量保存结构，保留同一项目的完成状态与创建时间。
  Future<void> _saveProgressStructure(
    String todoId,
    List<TodoProgressStepDraft> drafts,
    DateTime now, {
    List<TodoProgressStepDraft>? baseline,
    bool isNew = false,
  }) async {
    // 当前有效结构。
    final List<TodoProgressStepRecord> existing = await _progressSteps(todoId);
    if (!isNew) {
      if (baseline == null || baseline.length != existing.length) {
        throw const FormatException('进度项已发生变化，请重新打开编辑后再保存');
      }
      for (int index = 0; index < existing.length; index += 1) {
        if (baseline[index].id != existing[index].id ||
            _cleanOptional(baseline[index].name) != existing[index].name) {
          throw const FormatException('进度项已发生变化，请重新打开编辑后再保存');
        }
      }
    }
    // 所属任务用于保护已确认的进度结构。
    final TodoRecord? target = await _todoById(todoId);
    if (target == null) throw const FormatException('进度任务不存在');
    if (target.isCompleted) throw const FormatException('请先重新打开任务，再管理进度项');
    if (drafts.isEmpty) throw const FormatException('请至少保留一个进度项');
    // 已经合并得到的超限数据可以保留或减少，不能继续增加。
    if (drafts.length > maxProgressSteps && drafts.length > existing.length) {
      throw const FormatException('最多添加 1000 个进度项');
    }
    // 有效原项目按稳定标识索引。
    final Map<String, TodoProgressStepRecord> byId =
        <String, TodoProgressStepRecord>{
          for (final TodoProgressStepRecord step in existing) step.id: step,
        };
    // 本次保留的原项目标识。
    final Set<String> retained = <String>{};
    // 超限时不允许以删除抵消新增，避免绕过添加上限。
    final bool addsNew = drafts.any(
      (TodoProgressStepDraft draft) => draft.id == null,
    );
    if (existing.length >= maxProgressSteps &&
        addsNew &&
        drafts.length > maxProgressSteps) {
      throw const FormatException('进度项已达上限，请先减少数量');
    }
    for (int index = 0; index < drafts.length; index += 1) {
      // 当前编辑项目。
      final TodoProgressStepDraft draft = drafts[index];
      // 规范化名称，不把展示占位文字保存到数据库。
      final String? name = _cleanOptional(draft.name);
      if ((name?.length ?? 0) > 200) {
        throw const FormatException('进度项名称不能超过 200 个字符');
      }
      // 当前用户顺序值。
      final int sortOrder = (index + 1) * _sortOrderStep;
      if (draft.id == null) {
        await _database
            .into(_database.todoProgressSteps)
            .insert(
              TodoProgressStepsCompanion.insert(
                id: _uuid.v7(),
                todoId: todoId,
                name: Value<String?>(name),
                sortOrder: Value<int>(sortOrder),
                createdAt: now,
                updatedAt: now,
              ),
            );
      } else {
        // 原进度项不存在时拒绝保存，不复活已删除项目。
        final TodoProgressStepRecord? previous = byId[draft.id];
        if (previous == null || !retained.add(draft.id!)) {
          throw const FormatException('进度项已被修改或删除，请重新打开编辑');
        }
        if (previous.name != name || previous.sortOrder != sortOrder) {
          await (_database.update(_database.todoProgressSteps)..where(
                (TodoProgressSteps table) => table.id.equals(previous.id),
              ))
              .write(
                TodoProgressStepsCompanion(
                  name: Value<String?>(name),
                  sortOrder: Value<int>(sortOrder),
                  updatedAt: Value<DateTime>(now),
                ),
              );
        }
      }
    }
    for (final TodoProgressStepRecord step in existing) {
      if (!retained.contains(step.id)) {
        await (_database.update(
          _database.todoProgressSteps,
        )..where((TodoProgressSteps table) => table.id.equals(step.id))).write(
          TodoProgressStepsCompanion(
            deletedAt: Value<DateTime>(now),
            updatedAt: Value<DateTime>(now),
          ),
        );
      }
    }
    await _reopenInvalidProgressTask(todoId, now);
  }

  /// 只撤销失效的确认，永不根据满进度自动确认。
  Future<void> _reopenInvalidProgressTask(String todoId, DateTime now) async {
    // 当前父任务状态。
    final TodoRecord? target = await _todoById(todoId);
    if (target == null || !target.isCompleted) return;
    // 当前完整进度用于验证确认是否仍有效。
    final List<TodoProgressStepRecord> steps = await _progressSteps(todoId);
    if (steps.isEmpty ||
        steps.any((TodoProgressStepRecord step) => !step.isCompleted)) {
      await _writeCompletion(todoId, completed: false, now: now);
    }
  }

  /// 将待办移动到指定优先象限。
  Future<void> setPriorityQuadrant(
    String id,
    TodoPriorityQuadrant priorityQuadrant,
  ) async {
    // 当前目标任务。
    final TodoRecord? target = await _todoById(id);
    if (target == null) {
      return;
    }
    // 实际移动的主任务标识。
    final String rootId = target.parentId ?? target.id;
    // 当前任务树记录。
    final List<TodoRecord> tree = await _treeRecords(rootId);
    // 当前更新时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      for (final TodoRecord record in tree) {
        await _database.updateTodo(
          record.id,
          TodoItemsCompanion(
            priorityQuadrant: Value<int>(priorityQuadrant.value),
            updatedAt: Value<DateTime>(now),
            syncState: const Value<String>('localSaved'),
          ),
        );
      }
    });
  }

  /// 保存指定象限内主任务的用户顺序。
  Future<void> reorderRoots(
    TodoPriorityQuadrant priorityQuadrant,
    List<String> orderedRootIds,
  ) async {
    // 当前更新时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      for (int index = 0; index < orderedRootIds.length; index += 1) {
        await _database.updateTodo(
          orderedRootIds[index],
          TodoItemsCompanion(
            priorityQuadrant: Value<int>(priorityQuadrant.value),
            sortOrder: Value<int>((index + 1) * _sortOrderStep),
            updatedAt: Value<DateTime>(now),
            syncState: const Value<String>('localSaved'),
          ),
        );
      }
    });
  }

  /// 将待办移入回收站。
  Future<void> delete(
    String id, {
    TodoSeriesScope scope = TodoSeriesScope.single,
  }) async {
    if (scope == TodoSeriesScope.single) {
      await _softDeleteTree(id);
      return;
    }
    // 当前原始实例。
    final TodoRecord? existing = await (_database.select(
      _database.todoItems,
    )..where((TodoItems table) => table.id.equals(id))).getSingleOrNull();
    if (existing?.repeatSeriesId == null) {
      await _softDeleteTree(id);
      return;
    }
    // 当前及未来未完成的同系列实例。
    final List<TodoRecord> futureRecords =
        await (_database.select(_database.todoItems)..where(
              (TodoItems table) =>
                  table.repeatSeriesId.equals(existing!.repeatSeriesId!) &
                  table.scheduledDate.isBiggerOrEqualValue(
                    _normalizeDay(existing.scheduledDate),
                  ) &
                  table.isCompleted.equals(false) &
                  table.deletedAt.isNull(),
            ))
            .get();
    // 同一批软删除使用同一时间，便于整树准确恢复。
    final DateTime deletedAt = DateTime.now();
    await _database.transaction(() async {
      for (final TodoRecord record in futureRecords) {
        final List<TodoRecord> tree = await _treeRecords(record.id);
        for (final TodoRecord treeRecord in tree) {
          await _writeDeletedAt(treeRecord.id, deletedAt);
        }
      }
      if (existing!.parentId == null) {
        // 终止标记阻止尚未物化的未来实例再次生成。
        await _database.updateTodo(
          existing.id,
          TodoItemsCompanion(
            repeatRule: const Value<String>('stopped'),
            updatedAt: Value<DateTime>(deletedAt),
            syncState: const Value<String>('localSaved'),
          ),
        );
      }
    });
  }

  /// 从回收站恢复待办。
  Future<void> restore(String id) async {
    // 准备恢复的记录，包括已删除记录。
    final TodoRecord? target = await _todoById(id, includeDeleted: true);
    if (target == null || target.deletedAt == null) {
      return;
    }
    // 主任务同批删除的直属子任务。
    final List<TodoRecord> children = target.parentId == null
        ? await (_database.select(_database.todoItems)..where(
                (TodoItems table) =>
                    table.parentId.equals(target.id) &
                    table.deletedAt.equals(target.deletedAt!),
              ))
              .get()
        : <TodoRecord>[];
    await _database.transaction(() async {
      await _database.restoreTodo(target.id);
      for (final TodoRecord child in children) {
        await _database.restoreTodo(child.id);
      }
    });
  }

  /// 永久删除待办。
  Future<void> permanentlyDelete(String id) async {
    // 待永久删除的记录。
    final TodoRecord? target = await _todoById(id, includeDeleted: true);
    if (target == null) {
      return;
    }
    await _database.transaction(() async {
      if (target.parentId == null) {
        // 先删除子任务，避免自关联约束阻止删除主任务。
        final List<TodoRecord> children = await (_database.select(
          _database.todoItems,
        )..where((TodoItems table) => table.parentId.equals(target.id))).get();
        for (final TodoRecord child in children) {
          await _database.permanentlyDeleteTodo(child.id);
        }
      }
      await _database.permanentlyDeleteTodo(target.id);
    });
  }

  /// 为指定自然日按需生成缺失的独立重复实例。
  Future<void> _materializeRepeats(DateTime day) async {
    // 全部重复主任务实例，包括软删除的单次例外与终止标记。
    final List<TodoRecord> repeating =
        await (_database.select(_database.todoItems)
              ..where(
                (TodoItems table) =>
                    table.repeatRule.isNotNull() & table.parentId.isNull(),
              )
              ..orderBy(<OrderingTerm Function(TodoItems)>[
                (TodoItems table) => OrderingTerm.asc(table.scheduledDate),
              ]))
            .get();
    // 按重复系列分组。
    final Map<String, List<TodoRecord>> series = <String, List<TodoRecord>>{};
    for (final TodoRecord record in repeating) {
      // 系列稳定标识；兼容早期没有系列标识的数据。
      final String key = record.repeatSeriesId ?? record.id;
      series.putIfAbsent(key, () => <TodoRecord>[]).add(record);
    }
    // 当前生成时间。
    final DateTime now = DateTime.now();
    for (final MapEntry<String, List<TodoRecord>> entry in series.entries) {
      // 当前系列最早实例负责确定重复日历。
      final TodoRecord seed = entry.value.first;
      if (!_occursOn(seed, day)) {
        continue;
      }
      // 当前自然日是否已经存在实例，包含软删除记录以避免自动复活。
      final bool exists = entry.value.any(
        (TodoRecord record) => _normalizeDay(record.scheduledDate) == day,
      );
      if (exists) {
        continue;
      }
      // 目标日前最近一条记录决定系列是否已经终止。
      final List<TodoRecord> previousRecords = entry.value
          .where(
            (TodoRecord record) =>
                !_normalizeDay(record.scheduledDate).isAfter(day),
          )
          .toList(growable: false);
      if (previousRecords.isNotEmpty &&
          previousRecords.last.repeatRule == 'stopped') {
        continue;
      }
      // 最近一条未删除实例作为内容与子任务模板。
      final List<TodoRecord> activeTemplates = entry.value
          .where(
            (TodoRecord record) =>
                record.deletedAt == null &&
                _normalizeDay(record.scheduledDate).isBefore(day),
          )
          .toList(growable: false);
      if (activeTemplates.isEmpty) {
        continue;
      }
      // 当前实例模板。
      final TodoRecord template = activeTemplates.last;
      // 当前模板的有效子任务。
      final List<TodoRecord> templateChildren =
          await (_database.select(_database.todoItems)
                ..where(
                  (TodoItems table) =>
                      table.parentId.equals(template.id) &
                      table.deletedAt.isNull(),
                )
                ..orderBy(<OrderingTerm Function(TodoItems)>[
                  (TodoItems table) => OrderingTerm.asc(table.sortOrder),
                  (TodoItems table) => OrderingTerm.asc(table.createdAt),
                ]))
              .get();
      // 新重复实例的主任务标识。
      final String newRootId = stableBusinessId('repeat-todo', <String>[
        entry.key,
        businessDayKey(day),
      ]);
      await _database.transaction(() async {
        // 同一设备多个页面可能同时展开同一天，事务内再次检查稳定主键。
        if (await _todoById(newRootId, includeDeleted: true) != null) {
          return;
        }
        await _database.createTodo(
          TodoItemsCompanion.insert(
            id: newRootId,
            title: template.title,
            description: Value<String?>(template.description),
            scheduledDate: day,
            dueAt: Value<DateTime?>(_moveClockToDay(template.dueAt, day)),
            priorityQuadrant: Value<int>(template.priorityQuadrant),
            reminderAt: Value<DateTime?>(
              _moveClockToDay(template.reminderAt, day),
            ),
            repeatRule: Value<String?>(seed.repeatRule),
            repeatSeriesId: Value<String>(entry.key),
            sortOrder: Value<int>(template.sortOrder),
            createdAt: now,
            updatedAt: now,
          ),
        );
        for (final TodoRecord child in templateChildren) {
          await _database.createTodo(
            TodoItemsCompanion.insert(
              id: stableBusinessId('repeat-subtask', <String>[
                entry.key,
                child.repeatSeriesId ?? child.id,
                businessDayKey(day),
              ]),
              title: child.title,
              description: Value<String?>(child.description),
              parentId: Value<String>(newRootId),
              scheduledDate: day,
              dueAt: Value<DateTime?>(_moveClockToDay(child.dueAt, day)),
              priorityQuadrant: Value<int>(template.priorityQuadrant),
              reminderAt: Value<DateTime?>(
                _moveClockToDay(child.reminderAt, day),
              ),
              repeatSeriesId: Value<String?>(child.repeatSeriesId ?? child.id),
              sortOrder: Value<int>(child.sortOrder),
              createdAt: now,
              updatedAt: now,
            ),
          );
        }
      });
    }
  }

  /// 将数据库记录组装为进行中的两层任务树。
  List<TodoTreeNode> _buildActiveTrees(List<TodoRecord> records) {
    // 按父任务分组的直属子任务。
    final Map<String, List<TodoRecord>> childrenByParent =
        <String, List<TodoRecord>>{};
    for (final TodoRecord record in records) {
      // 当前父任务标识。
      final String? parentId = record.parentId;
      if (parentId != null) {
        childrenByParent
            .putIfAbsent(parentId, () => <TodoRecord>[])
            .add(record);
      }
    }
    // 仍存在未完成节点的主任务树。
    final List<TodoTreeNode> trees = <TodoTreeNode>[];
    for (final TodoRecord record in records) {
      if (record.parentId != null) {
        continue;
      }
      // 当前直属子任务。
      final List<TodoRecord> children =
          childrenByParent[record.id] ?? <TodoRecord>[];
      children.sort(_compareSiblingOrder);
      // 当前组装后的任务树。
      final TodoTreeNode tree = TodoTreeNode(
        root: record,
        children: List<TodoRecord>.unmodifiable(children),
      );
      if (tree.hasPending) {
        trees.add(tree);
      }
    }
    trees.sort((TodoTreeNode left, TodoTreeNode right) {
      // 象限行动优先级倒序。
      final int quadrantComparison = right.root.priorityQuadrant.compareTo(
        left.root.priorityQuadrant,
      );
      return quadrantComparison != 0
          ? quadrantComparison
          : _compareSiblingOrder(left.root, right.root);
    });
    return trees;
  }

  /// 比较同级任务的用户顺序、截止时间与创建时间。
  int _compareSiblingOrder(TodoRecord left, TodoRecord right) {
    // 用户排序值比较结果。
    final int orderComparison = left.sortOrder.compareTo(right.sortOrder);
    if (orderComparison != 0) {
      return orderComparison;
    }
    // 无截止时间任务使用的远期时间。
    final DateTime distantFuture = DateTime(9999);
    // 截止时间比较结果。
    final int dueComparison = (left.dueAt ?? distantFuture).compareTo(
      right.dueAt ?? distantFuture,
    );
    return dueComparison != 0
        ? dueComparison
        : left.createdAt.compareTo(right.createdAt);
  }

  /// 返回指定父级与象限末尾的新排序值。
  Future<int> _nextSortOrder({
    required String? parentId,
    required int priorityQuadrant,
  }) async {
    // 当前同级任务查询。
    final query = _database.select(_database.todoItems)
      ..where((TodoItems table) {
        // 父级筛选条件。
        final Expression<bool> parentExpression = parentId == null
            ? table.parentId.isNull()
            : table.parentId.equals(parentId);
        return parentExpression &
            table.priorityQuadrant.equals(priorityQuadrant) &
            table.deletedAt.isNull();
      })
      ..orderBy(<OrderingTerm Function(TodoItems)>[
        (TodoItems table) => OrderingTerm.desc(table.sortOrder),
      ])
      ..limit(1);
    // 当前最后一条同级任务。
    final TodoRecord? last = await query.getSingleOrNull();
    return (last?.sortOrder ?? 0) + _sortOrderStep;
  }

  /// 查找指定待办。
  Future<TodoRecord?> _todoById(String id, {bool includeDeleted = false}) {
    // 指定待办查询。
    final query = _database.select(_database.todoItems)
      ..where((TodoItems table) {
        // 标识条件。
        final Expression<bool> idExpression = table.id.equals(id);
        return includeDeleted
            ? idExpression
            : idExpression & table.deletedAt.isNull();
      });
    return query.getSingleOrNull();
  }

  /// 返回主任务与其直属子任务。
  Future<List<TodoRecord>> _treeRecords(String rootId) async {
    // 当前主任务。
    final TodoRecord? root = await _todoById(rootId);
    if (root == null) {
      return <TodoRecord>[];
    }
    // 当前有效子任务。
    final List<TodoRecord> children =
        await (_database.select(_database.todoItems)..where(
              (TodoItems table) =>
                  table.parentId.equals(rootId) & table.deletedAt.isNull(),
            ))
            .get();
    return <TodoRecord>[root, ...children];
  }

  /// 写入待办完成状态与完成时间。
  Future<void> _writeCompletion(
    String id, {
    required bool completed,
    required DateTime now,
  }) {
    return _database.updateTodo(
      id,
      TodoItemsCompanion(
        isCompleted: Value<bool>(completed),
        completedAt: Value<DateTime?>(completed ? now : null),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 让直属子任务继承主任务的计划日期与象限。
  Future<void> _cascadeChildrenContext(
    String rootId, {
    required DateTime scheduledDate,
    required int priorityQuadrant,
    required DateTime now,
  }) async {
    // 当前主任务的有效直属子任务。
    final List<TodoRecord> children =
        await (_database.select(_database.todoItems)..where(
              (TodoItems table) =>
                  table.parentId.equals(rootId) & table.deletedAt.isNull(),
            ))
            .get();
    for (final TodoRecord child in children) {
      await _database.updateTodo(
        child.id,
        TodoItemsCompanion(
          scheduledDate: Value<DateTime>(scheduledDate),
          priorityQuadrant: Value<int>(priorityQuadrant),
          updatedAt: Value<DateTime>(now),
          syncState: const Value<String>('localSaved'),
        ),
      );
    }
  }

  /// 将主任务及其直属子任务作为同一批次软删除。
  Future<void> _softDeleteTree(String id) async {
    // 当前目标任务。
    final TodoRecord? target = await _todoById(id);
    if (target == null) {
      return;
    }
    // 实际删除的树记录；单独删除子任务时只包含自身。
    final List<TodoRecord> records = target.parentId == null
        ? await _treeRecords(target.id)
        : <TodoRecord>[target];
    // 当前统一删除时间。
    final DateTime deletedAt = DateTime.now();
    await _database.transaction(() async {
      for (final TodoRecord record in records) {
        await _writeDeletedAt(record.id, deletedAt);
      }
    });
  }

  /// 写入软删除时间。
  Future<void> _writeDeletedAt(String id, DateTime deletedAt) {
    return _database.updateTodo(
      id,
      TodoItemsCompanion(
        deletedAt: Value<DateTime>(deletedAt),
        updatedAt: Value<DateTime>(deletedAt),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 判断重复模板是否应在指定自然日出现。
  bool _occursOn(TodoRecord seed, DateTime day) {
    // 模板所属自然日。
    final DateTime start = _normalizeDay(seed.scheduledDate);
    if (day.isBefore(start)) {
      return false;
    }
    // 间隔天数。
    final int days = day.difference(start).inDays;
    return switch (seed.repeatRule) {
      'daily' => true,
      'weekly' => days % 7 == 0,
      'monthly' => _isMonthlyOccurrence(start, day),
      _ => false,
    };
  }

  /// 判断目标日期是否符合月重复与月末回退规则。
  bool _isMonthlyOccurrence(DateTime start, DateTime day) {
    // 相对起始月份的月份差。
    final int monthDelta =
        (day.year - start.year) * 12 + day.month - start.month;
    if (monthDelta < 0) {
      return false;
    }
    // 目标月份最后一天。
    final int lastDay = DateTime(day.year, day.month + 1, 0).day;
    // 本月应生成的日期。
    final int expectedDay = start.day > lastDay ? lastDay : start.day;
    return day.day == expectedDay;
  }

  /// 将可选时间的时分秒移动到指定自然日。
  DateTime? _moveClockToDay(DateTime? source, DateTime day) {
    if (source == null) {
      return null;
    }
    // 数据库时间点对应的当前设备本地时间。
    final DateTime localSource = source.toLocal();
    return DateTime(
      day.year,
      day.month,
      day.day,
      localSource.hour,
      localSource.minute,
      localSource.second,
      localSource.millisecond,
      localSource.microsecond,
    );
  }

  /// 规范化自然日。
  DateTime _normalizeDay(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }

  /// 清理可选文本。
  String? _cleanOptional(String? value) {
    // 清理后的文本。
    final String? normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
