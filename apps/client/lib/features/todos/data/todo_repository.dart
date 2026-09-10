import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:uuid/uuid.dart';

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

  /// 备注。
  final String? notes;

  /// 创建待办草稿。
  const TodoDraft({
    this.id,
    required this.title,
    this.description,
    required this.scheduledDate,
    this.dueAt,
    this.priorityQuadrant = TodoPriorityQuadrant.importantNotUrgent,
    this.reminderAt,
    this.repeatRule = TodoRepeatRule.none,
    this.notes,
  });
}

/// 待办本地优先仓储。
class TodoRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// UUID 生成器。
  final Uuid _uuid;

  /// 创建待办仓储。
  TodoRepository(this._database, {this._uuid = const Uuid()});

  /// 监听指定自然日的有效待办。
  Stream<List<TodoRecord>> watchForDay(DateTime day) {
    // 规范化后的目标自然日。
    final DateTime normalizedDay = _normalizeDay(day);
    return Stream<void>.fromFuture(_materializeRepeats(normalizedDay))
        .asyncExpand((_) => _database.watchTodosForDay(normalizedDay));
  }

  /// 监听回收站中的待办。
  Stream<List<TodoRecord>> watchDeleted() {
    return _database.watchDeletedTodos();
  }

  /// 保存新增或编辑后的待办。
  Future<void> save(
    TodoDraft draft, {
    TodoSeriesScope scope = TodoSeriesScope.single,
  }) async {
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
    // 规范化后的重复规则。
    final String? repeatRule = draft.repeatRule == TodoRepeatRule.none
        ? null
        : draft.repeatRule.name;
    if (existingId == null) {
      // 重复系列标识。
      final String? seriesId = draft.repeatRule == TodoRepeatRule.none
          ? null
          : _uuid.v7();
      // 新增待办数据。
      final TodoItemsCompanion companion = TodoItemsCompanion.insert(
        id: _uuid.v7(),
        title: normalizedTitle,
        description: Value<String?>(_cleanOptional(draft.description)),
        scheduledDate: _normalizeDay(draft.scheduledDate),
        dueAt: Value<DateTime?>(draft.dueAt),
        priorityQuadrant: Value<int>(draft.priorityQuadrant.value),
        reminderAt: Value<DateTime?>(draft.reminderAt),
        repeatRule: Value<String?>(repeatRule),
        repeatSeriesId: Value<String?>(seriesId),
        notes: Value<String?>(_cleanOptional(draft.notes)),
        createdAt: now,
        updatedAt: now,
      );
      await _database.createTodo(companion);
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
              priorityQuadrant: Value<int>(draft.priorityQuadrant.value),
              reminderAt: Value<DateTime?>(
                _moveClockToDay(draft.reminderAt, record.scheduledDate),
              ),
              repeatRule: Value<String?>(repeatRule),
              notes: Value<String?>(_cleanOptional(draft.notes)),
              updatedAt: Value<DateTime>(now),
              syncState: const Value<String>('localSaved'),
            ),
          );
        }
        return;
      }
    }

    // 编辑单条待办数据，不覆盖创建时间和完成状态。
    final TodoItemsCompanion companion = TodoItemsCompanion(
      title: Value<String>(normalizedTitle),
      description: Value<String?>(_cleanOptional(draft.description)),
      scheduledDate: Value<DateTime>(_normalizeDay(draft.scheduledDate)),
      dueAt: Value<DateTime?>(draft.dueAt),
      priorityQuadrant: Value<int>(draft.priorityQuadrant.value),
      reminderAt: Value<DateTime?>(draft.reminderAt),
      repeatRule: Value<String?>(repeatRule),
      notes: Value<String?>(_cleanOptional(draft.notes)),
      updatedAt: Value<DateTime>(now),
      syncState: const Value<String>('localSaved'),
    );
    await _database.updateTodo(existingId, companion);
  }

  /// 切换待办完成状态。
  Future<void> setCompleted(String id, bool completed) {
    return _database.setTodoCompleted(id, completed);
  }

  /// 将待办移动到指定优先象限。
  Future<void> setPriorityQuadrant(
    String id,
    TodoPriorityQuadrant priorityQuadrant,
  ) {
    return _database.updateTodo(
      id,
      TodoItemsCompanion(
        priorityQuadrant: Value<int>(priorityQuadrant.value),
        updatedAt: Value<DateTime>(DateTime.now()),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 将待办移入回收站。
  Future<void> delete(
    String id, {
    TodoSeriesScope scope = TodoSeriesScope.single,
  }) async {
    if (scope == TodoSeriesScope.single) {
      await _database.softDeleteTodo(id);
      return;
    }
    // 当前原始实例。
    final TodoRecord? existing = await (_database.select(
      _database.todoItems,
    )..where((TodoItems table) => table.id.equals(id))).getSingleOrNull();
    if (existing?.repeatSeriesId == null) {
      await _database.softDeleteTodo(id);
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
    for (final TodoRecord record in futureRecords) {
      await _database.softDeleteTodo(record.id);
    }
  }

  /// 从回收站恢复待办。
  Future<void> restore(String id) {
    return _database.restoreTodo(id);
  }

  /// 永久删除待办。
  Future<void> permanentlyDelete(String id) {
    return _database.permanentlyDeleteTodo(id);
  }

  /// 为指定自然日按需生成缺失的独立重复实例。
  Future<void> _materializeRepeats(DateTime day) async {
    // 全部重复待办实例，包括已软删除记录。
    final List<TodoRecord> repeating =
        await (_database.select(_database.todoItems)
              ..where((TodoItems table) => table.repeatRule.isNotNull())
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
      // 当前系列最早实例作为生成模板。
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
      await _database.createTodo(
        TodoItemsCompanion.insert(
          id: _uuid.v7(),
          title: seed.title,
          description: Value<String?>(seed.description),
          scheduledDate: day,
          dueAt: Value<DateTime?>(_moveClockToDay(seed.dueAt, day)),
          priorityQuadrant: Value<int>(seed.priorityQuadrant),
          reminderAt: Value<DateTime?>(_moveClockToDay(seed.reminderAt, day)),
          repeatRule: Value<String?>(seed.repeatRule),
          repeatSeriesId: Value<String>(entry.key),
          sortOrder: Value<int>(seed.sortOrder),
          notes: Value<String?>(seed.notes),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
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
    return DateTime(
      day.year,
      day.month,
      day.day,
      source.hour,
      source.minute,
      source.second,
      source.millisecond,
      source.microsecond,
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
