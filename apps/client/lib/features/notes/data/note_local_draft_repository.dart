import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_audio_models.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/features/notes/data/note_draft_audio_edits.dart';
import 'package:omni_butler/features/notes/data/note_image_repository.dart';

/// 显式提交发现其他设备已改动，正式记录保持不变。
class NoteLocalDraftConflict implements Exception {
  /// 面向用户的冲突原因。
  final String message;

  /// 保存可恢复的冲突说明。
  const NoteLocalDraftConflict(this.message);

  /// 展示原因而非内部类型名称。
  @override
  String toString() => message;
}

/// 从本机草稿恢复完整的正文与整理基线。
NoteDraft noteDraftFromLocal(NoteLocalDraftRecord local) => NoteDraft(
  id: local.noteId,
  body: local.body,
  dayKey: local.dayKey,
  recordTimeSeconds: local.recordTimeSeconds,
  recordUtcOffsetMinutes: local.recordUtcOffsetMinutes,
  baseRevision: local.baseRevision,
  tags: noteTagIds(local.tags),
  originalTags: local.originalTags == null
      ? null
      : noteTagIds(local.originalTags!),
  createdAt: local.createdAt,
  creationTimezone: local.creationTimezone,
  dateEdited: local.dateEdited,
);

/// 两端未发布草稿与新增原音仅写本机表。
class NoteLocalDraftRepository {
  /// 正式笔记仓储负责现有版本、配额和标签约束。
  final NoteRepository notes;

  /// 绑定同一数据库，发布可使用一个原子事务。
  const NoteLocalDraftRepository(this.notes);

  /// 当前实际数据源。
  AppDatabase get database => notes.database;

  /// 包括丢弃标记，恢复清单不能让旧草稿复活。
  Future<NoteLocalDraftRecord?> find(String id) => (database.select(
    database.noteLocalDrafts,
  )..where((table) => table.id.equals(id))).getSingleOrNull();

  /// 当前可恢复的本机草稿。
  Future<List<NoteLocalDraftRecord>> list() =>
      (database.select(database.noteLocalDrafts)
            ..where((table) => table.discarded.equals(false))
            ..orderBy([(table) => OrderingTerm.desc(table.updatedAt)]))
          .get();

  /// 所有草稿变更用于阻止后台转写覆盖尚未提交的正文。
  Stream<List<NoteLocalDraftRecord>> watch() => (database.select(
    database.noteLocalDrafts,
  )..where((table) => table.discarded.equals(false))).watch();

  /// 保留唯一的新建入口草稿。
  Future<NoteLocalDraftRecord?> composer() async {
    // 数据库迁移遗留多篇时取最近一篇，其余仍可从草稿列表恢复。
    final List<NoteLocalDraftRecord> drafts = await list();
    return drafts.where((item) => item.isNew).firstOrNull;
  }

  /// 正式笔记的未提交编辑不会因卡片切换丢失。
  Future<NoteLocalDraftRecord?> forNote(String noteId) async {
    // 只恢复尚未取消的这一代。
    final List<NoteLocalDraftRecord> drafts = await list();
    return drafts.where((item) => item.noteId == noteId).firstOrNull;
  }

  /// 自动落本机草稿，不访问任何同步业务表。
  Future<void> save({
    required String id,
    required NoteDraft draft,
    required bool isNew,
    Map<String, bool> pendingInsertions = const {},
    Set<String> pendingAudioDeletions = const {},
    Set<String> pendingImageDeletions = const {},
  }) => database.transaction(() async {
    // 已取消草稿不能被迟到的自动保存重新激活。
    final NoteLocalDraftRecord? previous = await find(id);
    if (previous?.discarded == true) {
      throw StateError('这份草稿已取消，不能继续写入');
    }
    await database
        .into(database.noteLocalDrafts)
        .insertOnConflictUpdate(
          NoteLocalDraftsCompanion.insert(
            id: id,
            noteId: draft.id,
            body: Value(draft.body),
            dayKey: draft.dayKey,
            recordTimeSeconds: Value(draft.recordTimeSeconds),
            recordUtcOffsetMinutes: Value(draft.recordUtcOffsetMinutes),
            baseRevision: draft.baseRevision,
            tags: Value(jsonEncode(draft.tags.toList()..sort())),
            originalTags: Value(
              draft.originalTags == null
                  ? null
                  : jsonEncode(draft.originalTags!.toList()..sort()),
            ),
            createdAt: Value(draft.createdAt),
            creationTimezone: Value(draft.creationTimezone),
            dateEdited: Value(draft.dateEdited),
            isNew: Value(isNew),
            pendingInsertions: Value(
              NoteDraftAudioEdits(
                insertions: pendingInsertions,
                deletions: pendingAudioDeletions,
                imageDeletions: pendingImageDeletions,
              ).toJson(),
            ),
            updatedAt: DateTime.now(),
          ),
        );
  });

  /// 当前草稿新增录音，不包括已发布原音。
  Future<List<NoteDraftAudioSegmentRecord>> audio(String draftId) =>
      (database.select(database.noteDraftAudioSegments)
            ..where((table) => table.draftId.equals(draftId))
            ..orderBy([(table) => OrderingTerm.asc(table.sortOrder)]))
          .get();

  /// 录音完成后先可靠暂存，再由调用方确认恢复清单。
  Future<bool> stageAudio(
    NoteRecordingResult result, {
    required String draftId,
    required bool consent,
  }) async {
    // 字节校验不在数据库事务中长时间占用锁。
    final File file = File(result.path);
    // 必须存在真实采样数据，不能保存只有 WAV 头的空录音。
    final int size = await file.length();
    // 原音内容摘要供发布和备份验证。
    final String digest = (await sha256.bind(file.openRead()).first).toString();
    if (result.duration <= Duration.zero || size <= 44) {
      throw const FormatException('录音没有可保存的采样数据');
    }
    return database.transaction(() async {
      // 草稿代次是音频完成与取消之间的权威边界。
      final NoteLocalDraftRecord? draft = await find(draftId);
      if (draft == null || draft.discarded) return false;
      if (draft.noteId != result.noteId) throw StateError('录音与草稿归属不一致');
      // 回调与恢复可以重复，但不能生成重复片段。
      final NoteDraftAudioSegmentRecord? existing = await (database.select(
        database.noteDraftAudioSegments,
      )..where((table) => table.id.equals(result.id))).getSingleOrNull();
      if (existing != null) return existing.draftId == draftId;
      // 单篇配额同时计入正式片段和本机新增片段。
      final List<NoteAudioSegmentRecord> published = await (database.select(
        database.noteAudioSegments,
      )..where((table) => table.noteId.equals(result.noteId))).get();
      // 当前草稿内稳定排序的原音。
      final List<NoteDraftAudioSegmentRecord> staged = await audio(draftId);
      // 待确认片段已取消或原音已明确移除时，不能继续占用本篇录音额度。
      final Set<String> removed = NoteDraftAudioEdits.fromJson(
        draft.pendingInsertions,
      ).deletions;
      // 暂停时间不包含在实际采样时长中。
      final int duration = result.duration.inMilliseconds;
      if (duration > 1800000 ||
          duration +
                  published
                      .where((item) => !removed.contains(item.id))
                      .fold<int>(0, (sum, item) => sum + item.durationMs) +
                  staged
                      .where((item) => !removed.contains(item.id))
                      .fold<int>(0, (sum, item) => sum + item.durationMs) >
              3600000) {
        throw const FormatException('录音超出单段 30 分钟或单篇 60 分钟上限，原音仍可恢复');
      }
      await database
          .into(database.noteDraftAudioSegments)
          .insert(
            NoteDraftAudioSegmentsCompanion.insert(
              id: result.id,
              draftId: draftId,
              noteId: result.noteId,
              localPath: Value(result.path),
              durationMs: duration,
              mime: result.mimeType,
              sha256: digest,
              byteSize: size,
              startedAt: result.startedAt,
              consent: Value(consent),
              sortOrder: staged.length,
            ),
          );
      return true;
    });
  }

  /// 取消事实先持久化，文件清理可以失败并在后续重试。
  Future<void> discard(String id) =>
      (database.update(database.noteLocalDrafts)
            ..where((table) => table.id.equals(id)))
          .write(noteDraftTombstone())
          .then((_) {});

  /// 正文、版本、原音提升和草稿移除必须同时成功。
  Future<NoteEntryRecord?> commit(String id, {bool saveAsNew = false}) async {
    // 固定本次待提交草稿与音频身份。
    final NoteLocalDraftRecord? local = await find(id);
    if (local == null || local.discarded) throw StateError('草稿不存在或已取消');
    // 原件预检失败时正式笔记完全不变。
    final List<NoteDraftAudioSegmentRecord> allStaged = await audio(id);
    // 新增图片和原音共享一次发布事务。
    final NoteImageRepository images = NoteImageRepository(database);
    // 固定预检范围，事务内复查避免漏掉迟到文件。
    final List<NoteDraftImageRecord> allImages = await images.staged(id);
    // 删除元数据只来自当前草稿，正式归属在事务内再次校验。
    final NoteDraftAudioEdits audioEdits = NoteDraftAudioEdits.fromJson(
      local.pendingInsertions,
    );
    final List<NoteDraftAudioSegmentRecord> staged = allStaged
        .where((item) => !audioEdits.deletions.contains(item.id))
        .toList();
    // 待删除的新图不提升，保留孤儿记录供提交后清理。
    final List<NoteDraftImageRecord> stagedImages = allImages
        .where((item) => !audioEdits.imageDeletions.contains(item.id))
        .toList();
    for (final NoteDraftImageRecord item in stagedImages) {
      await images.verify(item.localPath, item.sizeBytes, item.sha256);
    }
    for (final NoteDraftAudioSegmentRecord item in staged) {
      // 本机草稿拥有的原音。
      final File? file = item.localPath == null ? null : File(item.localPath!);
      if (file == null ||
          !await file.exists() ||
          await file.length() != item.byteSize ||
          (await sha256.bind(file.openRead()).first).toString() !=
              item.sha256) {
        throw StateError('草稿原音不完整，请恢复原音后重试；文字仍已保留');
      }
    }
    return database.transaction(() async {
      // 校验预检期间没有发生取消或另一轮修改。
      final NoteLocalDraftRecord? latest = await find(id);
      if (latest == null || latest.discarded || latest != local) {
        throw StateError('草稿已变化，请重试保存');
      }
      // 原音预检期间有新增片段时整体重试，不能删除尚未提升的录音。
      final List<NoteDraftAudioSegmentRecord> latestAudio = await audio(id);
      // 预检期间图片变化必须重试，不能删掉尚未提升的原件。
      final List<NoteDraftImageRecord> latestImages = await images.staged(id);
      if (latestImages.length != allImages.length ||
          !latestImages.every(allImages.contains)) {
        throw StateError('草稿图片已变化，请重试保存');
      }
      if (latestAudio.length != allStaged.length ||
          !latestAudio.every((item) => allStaged.contains(item))) {
        throw StateError('草稿原音已变化，请重试保存');
      }
      // 正式正文版本是并发提交的唯一基线。
      final NoteEntryRecord? current = await notes.find(local.noteId);
      if (!saveAsNew &&
          !local.isNew &&
          (current == null || current.deletedAt != null)) {
        throw const NoteLocalDraftConflict('原笔记已删除，草稿已保留，可另存为新笔记');
      }
      if (!saveAsNew &&
          current != null &&
          current.revision != local.baseRevision &&
          current.body != local.body) {
        throw const NoteLocalDraftConflict('正文已有其他版本，草稿已保留，请选择版本或另存');
      }
      // 草稿和正式笔记共用原有正文与标签约束。
      final NoteDraft draft = noteDraftFromLocal(local);
      // 已有原音允许用户清空正文后显式保存。
      final List<NoteAudioSegmentRecord> existing = await (database.select(
        database.noteAudioSegments,
      )..where((table) => table.noteId.equals(local.noteId))).get();
      // 图片单独参与空白判断，不改变正文版本或覆盖远端图片集合。
      final List<NoteImageRecord> existingImages = await images.published(
        local.noteId,
      );
      // 正式记录只会在此显式提交分支创建。
      final NoteEntryRecord? saved = saveAsNew
          ? await notes.saveAsNew(
              draft,
              hasAdditionalAudio: staged.isNotEmpty,
              excludedAudioIds: audioEdits.deletions,
              hasAdditionalImages: stagedImages.isNotEmpty,
              excludedImageIds: audioEdits.imageDeletions,
            )
          : await notes.save(
              draft,
              hasAudio:
                  staged.isNotEmpty ||
                  existing.any(
                    (item) =>
                        item.deletedAt == null &&
                        !audioEdits.deletions.contains(item.id),
                  ),
              hasImages:
                  stagedImages.isNotEmpty ||
                  existingImages.any(
                    (item) =>
                        item.deletedAt == null &&
                        !audioEdits.imageDeletions.contains(item.id),
                  ),
            );
      if (saved == null) return null;
      if (saved.body != draft.body) {
        throw const NoteLocalDraftConflict('正文已有其他版本，草稿仍保留');
      }
      await images.publish(saved.id, stagedImages);
      if (!saveAsNew) {
        await images.remove(local.noteId, audioEdits.imageDeletions);
      }
      if (stagedImages.isNotEmpty || audioEdits.imageDeletions.isNotEmpty) {
        // 图片编辑更新展示排序依据，但不生成新的正文版本。
        await (database.update(database.noteEntries)
              ..where((table) => table.id.equals(saved.id)))
            .write(NoteEntriesCompanion(updatedAt: Value(DateTime.now())));
      }
      await (database.delete(database.noteDraftImages)..where(
            (table) =>
                table.draftId.equals(id) &
                table.id.isIn(stagedImages.map((item) => item.id)),
          ))
          .go();
      // 音频添加沿用已提交的正文基线，不产生额外正文版本。
      final NoteDraft committed = NoteDraft(
        id: saved.id,
        body: saved.body,
        dayKey: saved.dayKey,
        recordTimeSeconds: saved.recordTimeSeconds,
        recordUtcOffsetMinutes: saved.recordUtcOffsetMinutes,
        baseRevision: saved.revision,
        tags: noteTagIds(saved.tags),
        originalTags: noteTagIds(saved.tags),
        createdAt: saved.createdAt,
        creationTimezone: saved.creationTimezone,
      );
      for (final NoteDraftAudioSegmentRecord item in staged) {
        await notes.addAudio(
          draft: committed,
          id: item.id,
          localPath: item.localPath!,
          durationMs: item.durationMs,
          mime: item.mime,
          startedAt: item.startedAt,
        );
        await (database.update(
          database.noteAudioLocalFiles,
        )..where((table) => table.id.equals(item.id))).write(
          NoteAudioLocalFilesCompanion(
            consent: Value(item.consent),
            insertedRevision: Value(
              item.consent ? 'waiting:${saved.revision}' : null,
            ),
          ),
        );
      }
      if (!saveAsNew) {
        // 插入候选只有在正文正式提交后才能标记已使用。
        for (final MapEntry<String, bool> insertion
            in audioEdits.insertions.entries) {
          if (audioEdits.deletions.contains(insertion.key)) continue;
          if (!existing.any((item) => item.id == insertion.key)) continue;
          await (database.update(
            database.noteAudioLocalFiles,
          )..where((table) => table.id.equals(insertion.key))).write(
            NoteAudioLocalFilesCompanion(
              insertedRevision: Value(saved.revision),
              candidateTranscript: insertion.value == true
                  ? const Value(null)
                  : const Value.absent(),
            ),
          );
        }
        // 删除只作用于本篇片段；另存不会修改原篇。原件随后由既有引用清理器处理。
        await (database.delete(database.noteAudioSegments)..where(
              (table) =>
                  table.noteId.equals(local.noteId) &
                  table.id.isIn(audioEdits.deletions),
            ))
            .go();
      }
      // 已删新增片段保留为无草稿引用的待清理原件，避免丢失安全清理路径。
      await (database.delete(database.noteDraftAudioSegments)..where(
            (table) =>
                table.draftId.equals(id) &
                table.id.isIn(staged.map((item) => item.id)),
          ))
          .go();
      await (database.delete(
        database.noteLocalDrafts,
      )..where((table) => table.id.equals(id))).go();
      return saved;
    });
  }
}
