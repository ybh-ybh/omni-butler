import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';

/// 确认期间关联对象变化，调用方应重新显示实际篇数再确认。
class NoteTagNotesChanged implements Exception {
  /// 当前实际受影响的活动笔记身份。
  final Set<String> actualNoteIds;

  /// 固定发生变化时的身份快照。
  NoteTagNotesChanged(Set<String> actualNoteIds)
    : actualNoteIds = Set.unmodifiable(actualNoteIds);

  /// 面向用户的重新确认提示。
  @override
  String toString() => '标签关联的笔记已变化，请重新确认删除范围';
}

/// 协调标签与笔记生命周期，核心标签仓储不反向依赖笔记领域。
class NoteTagActions {
  /// 所有参与仓储共用的数据库与事务边界。
  final AppDatabase database;

  /// 复用笔记正文、版本及附件的软删除语义。
  final NoteRepository notes;

  /// 复用全部笔记（含回收站）的标签解除语义。
  final TaxonomyRepository taxonomy;

  /// 创建同一数据库内的领域协调入口。
  NoteTagActions(this.database, this.notes, this.taxonomy) {
    if (!identical(database, notes.database)) {
      throw ArgumentError('标签与笔记操作必须使用同一数据库');
    }
  }

  /// 确认框只统计正式、未回收且仍带有此标签的笔记。
  Future<Set<String>> activeNoteIds(String tagId) =>
      database.transaction(() async {
        await _requireTag(tagId);
        return _activeNoteIds(tagId);
      });

  /// 事务内复核确认对象后原子回收笔记并解除全部标签关联。
  Future<Set<String>> deleteTagAndNotes(
    String tagId, {
    required Set<String> expectedNoteIds,
  }) => database.transaction(() async {
    await _requireTag(tagId);
    // 事务取得的实际对象不能被确认时点之后的同步变化偷偷扩大。
    final Set<String> actualNoteIds = await _activeNoteIds(tagId);
    if (actualNoteIds.length != expectedNoteIds.length ||
        !actualNoteIds.containsAll(expectedNoteIds)) {
      throw NoteTagNotesChanged(actualNoteIds);
    }
    for (final String noteId in actualNoteIds) {
      await notes.softDelete(noteId);
    }
    // 批量回收不提供标签撤销，避免外层回滚污染仓储的内存撤销缓存。
    await taxonomy.delete(tagId, retainUndoLinks: false);
    return Set<String>.unmodifiable(actualNoteIds);
  });

  /// 拒绝删除其他模块条目、分类、已删除标签或不存在的身份。
  Future<void> _requireTag(String tagId) async {
    // 查询原始条目，不能借同名标签替代失效身份。
    final TaxonomyEntry? tag = await (database.select(
      database.taxonomyEntries,
    )..where((table) => table.id.equals(tagId))).getSingleOrNull();
    if (tag == null ||
        tag.module != 'notes' ||
        tag.kind != 'tag' ||
        tag.deletedAt != null) {
      throw StateError('笔记标签已不可用，请刷新后重试');
    }
  }

  /// 使用持久化标签身份匹配，保留多标签笔记的确定删除语义。
  Future<Set<String>> _activeNoteIds(String tagId) async {
    // 本机已同步的活动正式笔记是本次操作的全部范围。
    final List<NoteEntryRecord> records = await (database.select(
      database.noteEntries,
    )..where((table) => table.deletedAt.isNull())).get();
    return records
        .where((note) => noteTagIds(note.tags).contains(tagId))
        .map((note) => note.id)
        .toSet();
  }
}
