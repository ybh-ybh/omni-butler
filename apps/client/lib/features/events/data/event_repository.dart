import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:uuid/uuid.dart';

/// 周期事件单位。
enum EventIntervalUnit {
  /// 天。
  day,

  /// 周。
  week,

  /// 月。
  month,

  /// 年。
  year,
}

/// 周期事件状态。
enum EventDueStatus {
  /// 尚未记录首次完成。
  unrecorded,

  /// 正常。
  normal,

  /// 进入提醒窗口。
  upcoming,

  /// 已经超期。
  overdue,
}

/// 周期事件编辑草稿。
class EventDraft {
  /// 可选现有事件标识。
  final String? id;

  /// 事件名称。
  final String name;

  /// 可选事件说明。
  final String? description;

  /// 可选分类。
  final String? category;

  /// 周期间隔数值。
  final int intervalValue;

  /// 周期单位。
  final EventIntervalUnit intervalUnit;

  /// 可选最近完成时间。
  final DateTime? lastCompletedAt;

  /// 是否开启提醒。
  final bool reminderEnabled;

  /// 提前提醒天数。
  final int reminderDaysBefore;

  /// 提醒时刻相对午夜的分钟数。
  final int reminderTimeMinutes;

  /// 可选备注。
  final String? notes;

  /// 创建周期事件草稿。
  const EventDraft({
    this.id,
    required this.name,
    this.description,
    this.category,
    required this.intervalValue,
    required this.intervalUnit,
    this.lastCompletedAt,
    this.reminderEnabled = false,
    this.reminderDaysBefore = 0,
    this.reminderTimeMinutes = 540,
    this.notes,
  });
}

/// 事件完成操作的撤销信息。
class EventCompletionUndo {
  /// 事件标识。
  final String eventId;

  /// 新增完成历史标识。
  final String completionId;

  /// 操作前最近完成时间。
  final DateTime? previousCompletedAt;

  /// 创建事件撤销信息。
  const EventCompletionUndo({
    required this.eventId,
    required this.completionId,
    required this.previousCompletedAt,
  });
}

/// 周期事件本地优先仓储。
class EventRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// UUID 生成器。
  final Uuid _uuid;

  /// 创建周期事件仓储。
  EventRepository(this._database, {this._uuid = const Uuid()});

  /// 监听有效事件并按下一次应做时间排序。
  Stream<List<EventRecord>> watchActive() {
    // 有效事件查询。
    final query = _database.select(_database.events)
      ..where(
        (Events table) =>
            table.deletedAt.isNull() & table.isArchived.equals(false),
      );
    return query.watch().map((List<EventRecord> records) {
      // 按应做时间排序的副本。
      final List<EventRecord> sorted = List<EventRecord>.of(records);
      sorted.sort((EventRecord left, EventRecord right) {
        // 左侧应做时间。
        final DateTime? leftDue = nextDueAt(left);
        // 右侧应做时间。
        final DateTime? rightDue = nextDueAt(right);
        if (leftDue == null && rightDue == null) {
          return left.createdAt.compareTo(right.createdAt);
        }
        if (leftDue == null) {
          return 1;
        }
        if (rightDue == null) {
          return -1;
        }
        return leftDue.compareTo(rightDue);
      });
      return sorted;
    });
  }

  /// 监听归档事件。
  Stream<List<EventRecord>> watchArchived() {
    // 归档事件查询。
    final query = _database.select(_database.events)
      ..where(
        (Events table) =>
            table.deletedAt.isNull() & table.isArchived.equals(true),
      )
      ..orderBy(<OrderingTerm Function(Events)>[
        (Events table) => OrderingTerm.desc(table.updatedAt),
      ]);
    return query.watch();
  }

  /// 监听全部未删除事件的有效完成历史用于顶部统计。
  Stream<List<EventCompletionRecord>> watchActiveHistory() {
    // 完成历史与事件联表查询。
    final query =
        _database.select(_database.eventCompletions).join(<Join>[
          innerJoin(
            _database.events,
            _database.events.id.equalsExp(_database.eventCompletions.eventId),
          ),
        ])..where(
          _database.eventCompletions.deletedAt.isNull() &
              _database.eventCompletions.isRevoked.equals(false) &
              _database.events.deletedAt.isNull(),
        );
    return query.watch().map(
      (List<TypedResult> rows) => rows
          .map((TypedResult row) => row.readTable(_database.eventCompletions))
          .toList(growable: false),
    );
  }

  /// 监听指定事件的完成历史。
  Stream<List<EventCompletionRecord>> watchHistory(String eventId) {
    // 完成历史查询。
    final query = _database.select(_database.eventCompletions)
      ..where(
        (EventCompletions table) =>
            table.eventId.equals(eventId) & table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(EventCompletions)>[
        (EventCompletions table) => OrderingTerm.desc(table.completedAt),
      ]);
    return query.watch();
  }

  /// 新增一条可追溯的事件完成历史。
  Future<void> addHistory({
    required String eventId,
    required DateTime completedAt,
    String? notes,
  }) async {
    // 当前创建时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      await _database
          .into(_database.eventCompletions)
          .insert(
            EventCompletionsCompanion.insert(
              id: _uuid.v7(),
              eventId: eventId,
              completedAt: completedAt,
              notes: Value<String?>(_cleanOptional(notes)),
              source: const Value<String>('manual'),
              createdAt: now,
            ),
          );
      await _recalculateLastCompleted(eventId, now);
    });
  }

  /// 编辑一条事件完成历史。
  Future<void> updateHistory({
    required String id,
    required String eventId,
    required DateTime completedAt,
    String? notes,
  }) async {
    // 当前更新时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      await (_database.update(_database.eventCompletions)..where(
            (EventCompletions table) =>
                table.id.equals(id) & table.eventId.equals(eventId),
          ))
          .write(
            EventCompletionsCompanion(
              completedAt: Value<DateTime>(completedAt),
              notes: Value<String?>(_cleanOptional(notes)),
              isRevoked: const Value<bool>(false),
            ),
          );
      await _recalculateLastCompleted(eventId, now);
    });
  }

  /// 软删除一条事件完成历史并重新计算事件时间。
  Future<void> deleteHistory(EventCompletionRecord completion) async {
    // 当前删除时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      await (_database.update(_database.eventCompletions)
            ..where((EventCompletions table) => table.id.equals(completion.id)))
          .write(EventCompletionsCompanion(deletedAt: Value<DateTime>(now)));
      await _recalculateLastCompleted(completion.eventId, now);
    });
  }

  /// 保存新增或编辑后的周期事件。
  Future<void> save(EventDraft draft) async {
    // 清理后的事件名称。
    final String name = draft.name.trim();
    if (name.isEmpty) {
      throw const FormatException('事件名称不能为空');
    }
    if (draft.intervalValue <= 0) {
      throw const FormatException('周期间隔必须大于 0');
    }
    if (draft.reminderDaysBefore < 0) {
      throw const FormatException('提前提醒天数不能为负数');
    }
    if (draft.reminderTimeMinutes < 0 || draft.reminderTimeMinutes >= 1440) {
      throw const FormatException('提醒时刻必须位于当天');
    }
    // 当前写入时间。
    final DateTime now = DateTime.now();
    // 可选现有事件标识。
    final String? existingId = draft.id;
    if (existingId == null) {
      await _database
          .into(_database.events)
          .insert(
            EventsCompanion.insert(
              id: _uuid.v7(),
              name: name,
              description: Value<String?>(_cleanOptional(draft.description)),
              category: Value<String?>(_cleanOptional(draft.category)),
              intervalValue: Value<int>(draft.intervalValue),
              intervalUnit: Value<String>(draft.intervalUnit.name),
              lastCompletedAt: Value<DateTime?>(draft.lastCompletedAt),
              reminderEnabled: Value<bool>(draft.reminderEnabled),
              reminderDaysBefore: Value<int>(draft.reminderDaysBefore),
              reminderTimeMinutes: Value<int>(draft.reminderTimeMinutes),
              notes: Value<String?>(_cleanOptional(draft.notes)),
              createdAt: now,
              updatedAt: now,
            ),
          );
      return;
    }
    await (_database.update(
      _database.events,
    )..where((Events table) => table.id.equals(existingId))).write(
      EventsCompanion(
        name: Value<String>(name),
        description: Value<String?>(_cleanOptional(draft.description)),
        category: Value<String?>(_cleanOptional(draft.category)),
        intervalValue: Value<int>(draft.intervalValue),
        intervalUnit: Value<String>(draft.intervalUnit.name),
        lastCompletedAt: Value<DateTime?>(draft.lastCompletedAt),
        reminderEnabled: Value<bool>(draft.reminderEnabled),
        reminderDaysBefore: Value<int>(draft.reminderDaysBefore),
        reminderTimeMinutes: Value<int>(draft.reminderTimeMinutes),
        notes: Value<String?>(_cleanOptional(draft.notes)),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 记录当前完成时间并返回撤销信息。
  Future<EventCompletionUndo> recordNow(EventRecord event) async {
    // 当前完成时间。
    final DateTime now = DateTime.now();
    // 新完成历史标识。
    final String completionId = _uuid.v7();
    await _database.transaction(() async {
      await _database
          .into(_database.eventCompletions)
          .insert(
            EventCompletionsCompanion.insert(
              id: completionId,
              eventId: event.id,
              completedAt: now,
              source: const Value<String>('recordNow'),
              createdAt: now,
            ),
          );
      await (_database.update(
        _database.events,
      )..where((Events table) => table.id.equals(event.id))).write(
        EventsCompanion(
          lastCompletedAt: Value<DateTime>(now),
          updatedAt: Value<DateTime>(now),
          syncState: const Value<String>('localSaved'),
        ),
      );
    });
    return EventCompletionUndo(
      eventId: event.id,
      completionId: completionId,
      previousCompletedAt: event.lastCompletedAt,
    );
  }

  /// 撤销最近一次记录操作。
  Future<void> undoRecord(EventCompletionUndo undo) async {
    // 当前撤销时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      await (_database.update(_database.eventCompletions)..where(
            (EventCompletions table) =>
                table.id.equals(undo.completionId) &
                table.eventId.equals(undo.eventId),
          ))
          .write(const EventCompletionsCompanion(isRevoked: Value<bool>(true)));
      await (_database.update(
        _database.events,
      )..where((Events table) => table.id.equals(undo.eventId))).write(
        EventsCompanion(
          lastCompletedAt: Value<DateTime?>(undo.previousCompletedAt),
          updatedAt: Value<DateTime>(now),
          syncState: const Value<String>('localSaved'),
        ),
      );
    });
  }

  /// 归档或恢复周期事件。
  Future<void> setArchived(String id, bool archived) async {
    // 当前更新时间。
    final DateTime now = DateTime.now();
    await (_database.update(
      _database.events,
    )..where((Events table) => table.id.equals(id))).write(
      EventsCompanion(
        isArchived: Value<bool>(archived),
        archivedAt: Value<DateTime?>(archived ? now : null),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 将周期事件移入回收站。
  Future<void> delete(String id) async {
    // 当前删除时间。
    final DateTime now = DateTime.now();
    await (_database.update(
      _database.events,
    )..where((Events table) => table.id.equals(id))).write(
      EventsCompanion(
        deletedAt: Value<DateTime>(now),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 计算周期事件下一次应做时间。
  DateTime? nextDueAt(EventRecord event) {
    // 最近完成时间。
    final DateTime? last = event.lastCompletedAt;
    if (last == null) {
      return null;
    }
    return dueAtAfterCompletion(event, last);
  }

  /// 根据指定完成时间计算下一次应做时间。
  DateTime dueAtAfterCompletion(EventRecord event, DateTime completedAt) {
    return switch (event.intervalUnit) {
      'day' => completedAt.add(Duration(days: event.intervalValue)),
      'week' => completedAt.add(Duration(days: event.intervalValue * 7)),
      'year' => _addMonths(completedAt, event.intervalValue * 12),
      _ => _addMonths(completedAt, event.intervalValue),
    };
  }

  /// 根据全部有效历史重新计算最近完成时间。
  Future<void> _recalculateLastCompleted(String eventId, DateTime now) async {
    // 最新有效历史。
    final EventCompletionRecord? latest =
        await (_database.select(_database.eventCompletions)
              ..where(
                (EventCompletions table) =>
                    table.eventId.equals(eventId) &
                    table.deletedAt.isNull() &
                    table.isRevoked.equals(false),
              )
              ..orderBy(<OrderingTerm Function(EventCompletions)>[
                (EventCompletions table) =>
                    OrderingTerm.desc(table.completedAt),
              ])
              ..limit(1))
            .getSingleOrNull();
    await (_database.update(
      _database.events,
    )..where((Events table) => table.id.equals(eventId))).write(
      EventsCompanion(
        lastCompletedAt: Value<DateTime?>(latest?.completedAt),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 计算周期事件当前状态。
  EventDueStatus statusFor(EventRecord event, DateTime now) {
    // 下一次应做时间。
    final DateTime? dueAt = nextDueAt(event);
    if (dueAt == null) {
      return EventDueStatus.unrecorded;
    }
    if (now.isAfter(dueAt)) {
      return EventDueStatus.overdue;
    }
    // 提醒窗口开始时间。
    final DateTime warningStart = dueAt.subtract(
      Duration(days: event.reminderDaysBefore),
    );
    if (!now.isBefore(warningStart)) {
      return EventDueStatus.upcoming;
    }
    return EventDueStatus.normal;
  }

  /// 按月增加日期并处理不存在的月末日期。
  DateTime _addMonths(DateTime source, int months) {
    // 目标月份零基索引。
    final int targetMonthIndex = source.month - 1 + months;
    // 目标年份。
    final int targetYear = source.year + targetMonthIndex ~/ 12;
    // 目标月份。
    final int targetMonth = targetMonthIndex % 12 + 1;
    // 目标月份最后一天。
    final int lastDay = DateTime(targetYear, targetMonth + 1, 0).day;
    // 目标日期。
    final int targetDay = source.day > lastDay ? lastDay : source.day;
    return DateTime(
      targetYear,
      targetMonth,
      targetDay,
      source.hour,
      source.minute,
      source.second,
      source.millisecond,
      source.microsecond,
    );
  }

  /// 清理可选文本。
  String? _cleanOptional(String? value) {
    // 清理后的文本。
    final String? normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
