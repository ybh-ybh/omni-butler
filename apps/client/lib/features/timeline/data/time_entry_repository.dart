import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:uuid/uuid.dart';

/// 时间记录冲突异常。
class TimeEntryConflict implements Exception {
  /// 发生冲突的现有记录。
  final TimeEntryRecord existing;

  /// 创建时间记录冲突异常。
  const TimeEntryConflict(this.existing);

  /// 返回用户可理解的冲突说明。
  @override
  String toString() => '与“${timeEntryDisplayActivity(existing)}”的时间区间重叠';
}

/// 已存在进行中记录异常。
class ActiveTimeEntryConflict implements Exception {
  /// 已存在的进行中记录。
  final TimeEntryRecord existing;

  /// 创建进行中记录冲突异常。
  const ActiveTimeEntryConflict(this.existing);

  /// 返回用户可理解的冲突说明。
  @override
  String toString() => '“${timeEntryDisplayActivity(existing)}”仍在进行，请先结束它';
}

/// 时间记录编辑草稿。
class TimeEntryDraft {
  /// 可选现有记录标识。
  final String? id;

  /// 可选绝对开始时间。
  final DateTime? startedAt;

  /// 绝对结束时间；为空表示先开始记录。
  final DateTime? endedAt;

  /// 兼容旧调用的所属自然日。
  final DateTime? entryDate;

  /// 兼容旧调用的起始分钟数。
  final int? startMinute;

  /// 兼容旧调用的结束分钟数。
  final int? endMinute;

  /// 可选活动内容；结束记录时必须填写。
  final String? activity;

  /// 可选类别。
  final String? category;

  /// 可选备注。
  final String? notes;

  /// 创建时间记录草稿。
  const TimeEntryDraft({
    this.id,
    this.startedAt,
    this.endedAt,
    this.entryDate,
    this.startMinute,
    this.endMinute,
    this.activity,
    this.category,
    this.notes,
  });
}

/// 24 小时时间记录本地优先仓储。
class TimeEntryRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// UUID 生成器。
  final Uuid _uuid;

  /// 创建时间记录仓储。
  TimeEntryRepository(this._database, {this._uuid = const Uuid()});

  /// 监听指定自然日内有交集的有效时间记录。
  Stream<List<TimeEntryRecord>> watchForDay(DateTime day) {
    // 当日零点。
    final DateTime normalizedDay = DateUtils.dateOnly(day);
    // 下一日零点。
    final DateTime nextDay = normalizedDay.add(const Duration(days: 1));
    return watchForRange(normalizedDay, nextDay);
  }

  /// 监听左闭右开日期范围内有交集的有效时间记录。
  Stream<List<TimeEntryRecord>> watchForRange(DateTime start, DateTime end) {
    // 规范化范围起点。
    final DateTime normalizedStart = DateUtils.dateOnly(start);
    // 规范化范围终点。
    final DateTime normalizedEnd = DateUtils.dateOnly(end);
    // 与范围有交集的时间记录查询。
    final query = _database.select(_database.timeEntries)
      ..where(
        (TimeEntries table) =>
            table.startedAt.isSmallerThanValue(normalizedEnd) &
            (table.endedAt.isNull() |
                table.endedAt.isBiggerThanValue(normalizedStart)) &
            table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(TimeEntries)>[
        (TimeEntries table) => OrderingTerm.asc(table.startedAt),
      ]);
    return query.watch();
  }

  /// 监听当前设备上的全部进行中记录。
  Stream<List<TimeEntryRecord>> watchOngoing() {
    // 进行中记录查询。
    final query = _database.select(_database.timeEntries)
      ..where(
        (TimeEntries table) =>
            table.endedAt.isNull() & table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(TimeEntries)>[
        (TimeEntries table) => OrderingTerm.asc(table.startedAt),
      ]);
    return query.watch();
  }

  /// 保存补录、编辑或进行中时间记录，并阻止区间重叠。
  Future<void> save(TimeEntryDraft draft) async {
    // 兼容新旧草稿格式的绝对开始时间。
    final DateTime startedAt = _resolveStartedAt(draft);
    // 兼容新旧草稿格式的绝对结束时间。
    final DateTime? endedAt = _resolveEndedAt(draft);
    // 清理后的活动内容。
    final String? activity = _cleanOptional(draft.activity);
    if (endedAt != null && activity == null) {
      throw const FormatException('结束记录前请填写活动内容');
    }
    if (endedAt != null && !endedAt.isAfter(startedAt)) {
      throw const FormatException('结束时间必须晚于开始时间');
    }
    // 全部有效记录用于跨自然日冲突检查。
    final List<TimeEntryRecord> existingRecords = await (_database.select(
      _database.timeEntries,
    )..where((TimeEntries table) => table.deletedAt.isNull())).get();
    // 当前是否正在结束一条原本进行中的记录。
    final bool finishingOngoing =
        endedAt != null &&
        existingRecords.any(
          (TimeEntryRecord record) =>
              record.id == draft.id && record.endedAt == null,
        );
    for (final TimeEntryRecord existing in existingRecords) {
      if (existing.id == draft.id) {
        continue;
      }
      if (finishingOngoing) {
        // 允许用户逐条结束同步产生的多条进行中记录，避免冲突状态无法退出。
        continue;
      }
      if (endedAt == null && existing.endedAt == null) {
        throw ActiveTimeEntryConflict(existing);
      }
      // 当前区间是否与现有记录重叠。
      final bool overlaps = _overlaps(
        startedAt: startedAt,
        endedAt: endedAt,
        existing: existing,
      );
      if (overlaps) {
        throw TimeEntryConflict(existing);
      }
    }

    // 起始自然日。
    final DateTime day = DateUtils.dateOnly(startedAt);
    // 兼容旧客户端的起始分钟数。
    final int startMinute = startedAt.difference(day).inMinutes;
    // 兼容旧客户端的结束分钟数，跨天时允许超过一天。
    final int endMinute = endedAt?.difference(day).inMinutes ?? startMinute;
    // 当前写入时间。
    final DateTime now = DateTime.now();
    // 可选现有记录标识。
    final String? existingId = draft.id;
    if (existingId == null) {
      await _database
          .into(_database.timeEntries)
          .insert(
            TimeEntriesCompanion.insert(
              id: _uuid.v7(),
              entryDate: day,
              startMinute: startMinute,
              endMinute: endMinute,
              startedAt: startedAt,
              endedAt: Value<DateTime?>(endedAt),
              activity: Value<String?>(activity),
              category: Value<String?>(_cleanOptional(draft.category)),
              notes: Value<String?>(_cleanOptional(draft.notes)),
              createdAt: now,
              updatedAt: now,
            ),
          );
      return;
    }
    await (_database.update(
      _database.timeEntries,
    )..where((TimeEntries table) => table.id.equals(existingId))).write(
      TimeEntriesCompanion(
        entryDate: Value<DateTime>(day),
        startMinute: Value<int>(startMinute),
        endMinute: Value<int>(endMinute),
        startedAt: Value<DateTime>(startedAt),
        endedAt: Value<DateTime?>(endedAt),
        activity: Value<String?>(activity),
        category: Value<String?>(_cleanOptional(draft.category)),
        notes: Value<String?>(_cleanOptional(draft.notes)),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 将时间记录移入回收站。
  Future<void> delete(String id) async {
    // 当前删除时间。
    final DateTime now = DateTime.now();
    await (_database.update(
      _database.timeEntries,
    )..where((TimeEntries table) => table.id.equals(id))).write(
      TimeEntriesCompanion(
        deletedAt: Value<DateTime>(now),
        updatedAt: Value<DateTime>(now),
        syncState: const Value<String>('localSaved'),
      ),
    );
  }

  /// 按类别汇总分段记录的分钟数。
  Map<String, int> summarizeByCategory(List<TimeEntryRecord> records) {
    // 类别分钟汇总。
    final Map<String, int> summary = <String, int>{};
    for (final TimeEntryRecord record in records) {
      // 展示类别。
      final String category = record.category ?? '未分类';
      // 当前分段分钟数。
      final int minutes = record.endMinute - record.startMinute;
      summary.update(
        category,
        (int value) => value + minutes,
        ifAbsent: () => minutes,
      );
    }
    return summary;
  }

  /// 判断草稿区间是否与一条现有记录重叠。
  bool _overlaps({
    required DateTime startedAt,
    required DateTime? endedAt,
    required TimeEntryRecord existing,
  }) {
    // 当前区间使用远未来时间表达未结束状态。
    final DateTime currentEnd = endedAt ?? DateTime(9999, 12, 31);
    // 现有区间使用远未来时间表达未结束状态。
    final DateTime existingEnd = existing.endedAt ?? DateTime(9999, 12, 31);
    return startedAt.isBefore(existingEnd) &&
        currentEnd.isAfter(existing.startedAt);
  }

  /// 将新旧草稿格式统一换算为绝对开始时间。
  DateTime _resolveStartedAt(TimeEntryDraft draft) {
    // 新格式直接提供的开始时间。
    final DateTime? startedAt = draft.startedAt;
    if (startedAt != null) {
      return startedAt;
    }
    // 旧格式提供的自然日。
    final DateTime? entryDate = draft.entryDate;
    // 旧格式提供的起始分钟数。
    final int? startMinute = draft.startMinute;
    if (entryDate == null || startMinute == null) {
      throw const FormatException('开始时间不能为空');
    }
    return DateUtils.dateOnly(entryDate).add(Duration(minutes: startMinute));
  }

  /// 将新旧草稿格式统一换算为绝对结束时间。
  DateTime? _resolveEndedAt(TimeEntryDraft draft) {
    if (draft.startedAt != null) {
      return draft.endedAt;
    }
    // 旧格式提供的自然日。
    final DateTime? entryDate = draft.entryDate;
    // 旧格式提供的结束分钟数。
    final int? endMinute = draft.endMinute;
    if (entryDate == null || endMinute == null) {
      return null;
    }
    return DateUtils.dateOnly(entryDate).add(Duration(minutes: endMinute));
  }

  /// 清理可选文本。
  String? _cleanOptional(String? value) {
    // 清理后的文本。
    final String? normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

/// 将逻辑时间记录裁切并拆成指定范围内的自然日分段。
List<TimeEntryRecord> splitTimeEntriesForRange({
  required List<TimeEntryRecord> records,
  required DateTime rangeStart,
  required DateTime rangeEnd,
  required DateTime now,
}) {
  // 规范化范围起点。
  final DateTime normalizedStart = DateUtils.dateOnly(rangeStart);
  // 规范化范围终点。
  final DateTime normalizedEnd = DateUtils.dateOnly(rangeEnd);
  // 拆分后的自然日分段。
  final List<TimeEntryRecord> segments = <TimeEntryRecord>[];
  for (final TimeEntryRecord record in records) {
    // 进行中记录以当前时刻作为临时结束时间。
    final DateTime effectiveEnd = record.endedAt ?? now;
    // 当前记录在范围内的裁切起点。
    final DateTime clippedStart = record.startedAt.isAfter(normalizedStart)
        ? record.startedAt
        : normalizedStart;
    // 当前记录在范围内的裁切终点。
    final DateTime clippedEnd = effectiveEnd.isBefore(normalizedEnd)
        ? effectiveEnd
        : normalizedEnd;
    if (!clippedEnd.isAfter(clippedStart)) {
      continue;
    }
    // 当前待拆分自然日。
    DateTime day = DateUtils.dateOnly(clippedStart);
    while (day.isBefore(clippedEnd)) {
      // 下一自然日零点。
      final DateTime nextDay = day.add(const Duration(days: 1));
      // 当前分段起点。
      final DateTime segmentStart = clippedStart.isAfter(day)
          ? clippedStart
          : day;
      // 当前分段终点。
      final DateTime segmentEnd = clippedEnd.isBefore(nextDay)
          ? clippedEnd
          : nextDay;
      if (segmentEnd.isAfter(segmentStart)) {
        segments.add(
          record.copyWith(
            entryDate: day,
            startMinute: segmentStart.difference(day).inMinutes,
            endMinute: segmentEnd.difference(day).inMinutes,
          ),
        );
      }
      day = nextDay;
    }
  }
  segments.sort((TimeEntryRecord left, TimeEntryRecord right) {
    // 先比较自然日。
    final int dayOrder = left.entryDate.compareTo(right.entryDate);
    return dayOrder != 0
        ? dayOrder
        : left.startMinute.compareTo(right.startMinute);
  });
  return segments;
}

/// 返回记录的展示活动名称。
String timeEntryDisplayActivity(TimeEntryRecord record) {
  // 清理后的活动名称。
  final String? activity = record.activity?.trim();
  return activity == null || activity.isEmpty ? '未命名记录' : activity;
}
