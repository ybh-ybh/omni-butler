import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show DateTimeRange;
import 'package:omni_butler/core/database/app_database.dart';

import '../markdown/note_markdown.dart';
import 'note_repository.dart';

/// 两端共用的不可变查询条件，浮层自行维护未应用的副本。
@immutable
class NoteSearchFilter {
  /// 时间范围和可选的自定义日期。
  final String range;

  /// 自定义范围包含结束日全天。
  final DateTimeRange? customRange;

  /// 标签包含、排除或无有效标签。
  final String tagMode;

  /// 所选标签身份。
  final Set<String> tagIds;

  /// 图片、正文链接与语音的交集。
  final Set<String> contents;

  /// 只匹配往年同月同日。
  final bool onThisDay;

  /// 创建与外部集合隔离的查询条件。
  NoteSearchFilter({
    this.range = 'all',
    this.customRange,
    this.tagMode = 'include',
    Set<String> tagIds = const {},
    Set<String> contents = const {},
    this.onThisDay = false,
  }) : tagIds = Set.unmodifiable(tagIds),
       contents = Set.unmodifiable(contents);

  /// 默认无筛选。
  const NoteSearchFilter.empty()
    : range = 'all',
      customRange = null,
      tagMode = 'include',
      tagIds = const {},
      contents = const {},
      onThisDay = false;

  /// 有任一真正影响结果的条件时标记过滤按钮。
  bool get isActive =>
      range != 'all' ||
      tagMode == 'none' ||
      tagIds.isNotEmpty ||
      contents.isNotEmpty ||
      onThisDay;

  /// 复制条件，不把尚未应用的集合修改泄漏给列表。
  NoteSearchFilter copyWith({
    String? range,
    DateTimeRange? customRange,
    String? tagMode,
    Set<String>? tagIds,
    Set<String>? contents,
    bool? onThisDay,
  }) => NoteSearchFilter(
    range: range ?? this.range,
    customRange: customRange ?? this.customRange,
    tagMode: tagMode ?? this.tagMode,
    tagIds: tagIds ?? this.tagIds,
    contents: contents ?? this.contents,
    onThisDay: onThisDay ?? this.onThisDay,
  );
}

/// 统一匹配正式笔记；注入今天以验证跨年和闰日，日期始终使用归档日。
bool matchesNoteSearch(
  NoteEntryRecord note, {
  required NoteSearchFilter filter,
  required List<TaxonomyEntry> taxonomies,
  required List<NoteAudioSegmentRecord> audio,
  Set<String> imageNoteIds = const {},
  String query = '',
  String? selectedDay,
  DateTime? now,
}) {
  if (note.deletedAt != null ||
      selectedDay != null && note.dayKey != selectedDay) {
    return false;
  }
  // 只把仍存在的标签计入筛选，远端删除后不会把幽灵标签留在查询里。
  final Set<String> activeIds = taxonomies
      .where((tag) => tag.kind == 'tag' && tag.deletedAt == null)
      .map((tag) => tag.id)
      .toSet();
  // 笔记及筛选内有效的标签身份。
  final Set<String> tags = noteTagIds(note.tags).intersection(activeIds);
  // 筛选中仍然有效的标签身份。
  final Set<String> selected = filter.tagIds.intersection(activeIds);
  if (filter.tagMode == 'none' && tags.isNotEmpty ||
      (filter.tagMode == 'exclude'
          ? tags.any(selected.contains)
          : !tags.containsAll(selected))) {
    return false;
  }
  // 原音墓碑不参与内容和关键词匹配。
  final List<NoteAudioSegmentRecord> segments = audio
      .where((item) => item.noteId == note.id && item.deletedAt == null)
      .toList();
  if (filter.contents.contains('image') && !imageNoteIds.contains(note.id) ||
      filter.contents.contains('audio') && segments.isEmpty ||
      filter.contents.contains('link') &&
          !RegExp(
            r'https?://[^\s<>]+',
            caseSensitive: false,
          ).hasMatch(note.body)) {
    return false;
  }
  // 本地今天用于相对日期，正式笔记日期不重新解释时区。
  final DateTime instant = now ?? DateTime.now();
  // 相对日期查询使用的本地自然日。
  final DateTime today = DateTime(instant.year, instant.month, instant.day);
  if (filter.onThisDay &&
      (note.dayKey.substring(0, 4).compareTo('${today.year}') >= 0 ||
          note.dayKey.substring(5) != businessDayKey(today).substring(5))) {
    return false;
  }
  // 相对范围和自定义范围都包含自然日边界。
  final DateTime? start = switch (filter.range) {
    'today' => today,
    'week' => DateTime(today.year, today.month, today.day - today.weekday + 1),
    'month' => DateTime(today.year, today.month),
    'lastMonth' => DateTime(today.year, today.month - 1),
    'last7' => DateTime(today.year, today.month, today.day - 6),
    'last30' => DateTime(today.year, today.month, today.day - 29),
    'custom' => filter.customRange?.start,
    _ => null,
  };
  // 包含在筛选范围内的最后自然日。
  final DateTime? end = filter.range == 'lastMonth'
      ? DateTime(today.year, today.month, 0)
      : filter.range == 'custom'
      ? filter.customRange?.end
      : start == null
      ? null
      : today;
  if (start != null && note.dayKey.compareTo(businessDayKey(start)) < 0 ||
      end != null && note.dayKey.compareTo(businessDayKey(end)) > 0) {
    return false;
  }
  // 正文使用可见文字，标签和转写仍可独立命中。
  final String keyword = query.trim().toLowerCase();
  return keyword.isEmpty ||
      [
        NoteMarkdown.plainText(note.body),
        ...taxonomies
            .where((tag) => tags.contains(tag.id))
            .map((tag) => tag.name),
        ...segments.map((segment) => segment.transcript ?? ''),
      ].any((value) => value.toLowerCase().contains(keyword));
}
