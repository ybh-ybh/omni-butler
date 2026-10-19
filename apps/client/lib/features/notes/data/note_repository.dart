import 'dart:convert';
import 'dart:io';

import 'note_record_time.dart';
export 'note_record_time.dart';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/data/note_image_repository.dart';
import 'package:uuid/uuid.dart';

/// 解码标签身份，旧数据损坏时明确报错而非猜测名称。
Set<String> noteTagIds(String encoded) =>
    (jsonDecode(encoded) as List).cast<String>().toSet();

/// 取消或永久删除只保留代次身份，避免正文和整理信息继续进入本机备份。
NoteLocalDraftsCompanion noteDraftTombstone() => NoteLocalDraftsCompanion(
  body: const Value(''),
  dayKey: const Value(''),
  recordTimeSeconds: const Value(null),
  recordUtcOffsetMinutes: const Value(null),
  baseRevision: const Value(''),
  tags: const Value('[]'),
  originalTags: const Value(null),
  createdAt: const Value(null),
  creationTimezone: const Value(null),
  dateEdited: const Value(false),
  isNew: const Value(false),
  discarded: const Value(true),
  pendingInsertions: const Value('{}'),
  updatedAt: Value(DateTime.now()),
);

/// 保留原始时区名称与有符号 UTC 偏移，不推测 IANA 地区。
String noteCreationTimezone(DateTime instant) {
  // 创建时的本地时间及偏移分钟。
  final DateTime local = instant.toLocal();
  final int offset = local.timeZoneOffset.inMinutes;
  return '${local.timeZoneName}|${offset < 0 ? '-' : '+'}'
      '${(offset.abs() ~/ 60).toString().padLeft(2, '0')}:'
      '${(offset.abs() % 60).toString().padLeft(2, '0')}';
}

/// 用采集时保留的偏移还原归档日期，恢复设备时区不改变日期。
String noteRecordingDayKey(DateTime instant, String? timezone) {
  // 设备名称可能包含分隔符，偏移只取字符串尾部。
  final RegExpMatch? match = RegExp(r'\|([+-])(\d{2}):(\d{2})$')
      .firstMatch(timezone ?? '');
  if (match == null) return businessDayKey(instant.toLocal());
  final int minutes =
      (int.parse(match[2]!) * 60 + int.parse(match[3]!)) *
      (match[1] == '-' ? -1 : 1);
  return businessDayKey(instant.toUtc().add(Duration(minutes: minutes)));
}

/// 一次待持久化的编辑器内容。
class NoteDraft {
  /// 稳定草稿身份。
  final String id;

  /// 人工正文。
  final String body;

  /// 归档日期。
  final String dayKey;

  /// 固定记录时钟秒数，旧草稿允许为空。
  final int? recordTimeSeconds;

  /// 选择时的 UTC 偏移分钟。
  final int? recordUtcOffsetMinutes;

  /// 当前记录时间，旧草稿和新建输入使用同一兼容规则。
  NoteRecordTime get recordTime => NoteRecordTime.resolve(
    dayKey: dayKey,
    createdAt: createdAt ?? DateTime.now(),
    creationTimezone:
        creationTimezone ??
        (createdAt == null ? noteCreationTimezone(DateTime.now()) : null),
    seconds: recordTimeSeconds,
    utcOffsetMinutes: recordUtcOffsetMinutes,
  );

  /// 当前编辑起点的正文版本。
  final String baseRevision;

  /// 用户标签身份。
  final Set<String> tags;

  /// 首次有效输入或录音开始的原始时刻。
  final DateTime? createdAt;

  /// 与创建时刻一起固定的时区。
  final String? creationTimezone;

  /// 编辑起点的标签，null表示调用方明确替换完整整理信息。
  final Set<String>? originalTags;

  /// 本次是否由用户主动选择记录日期或时分秒。
  final bool dateEdited;

  /// 创建编辑器草稿。
  const NoteDraft({
    required this.id,
    required this.body,
    required this.dayKey,
    required this.baseRevision,
    this.tags = const {},
    this.createdAt,
    this.creationTimezone,
    this.originalTags,
    this.dateEdited = false,
    this.recordTimeSeconds,
    this.recordUtcOffsetMinutes,
  });
}

/// 正式记录和草稿共用固定墙钟时间解析。
extension NoteEntryRecordTime on NoteEntryRecord {
  /// 新字段缺失时保留旧归档日并从原始创建信息推导时钟。
  NoteRecordTime get recordTime => NoteRecordTime.resolve(
    dayKey: dayKey,
    createdAt: createdAt,
    creationTimezone: creationTimezone,
    seconds: recordTimeSeconds,
    utcOffsetMinutes: recordUtcOffsetMinutes,
  );
}

/// 笔记本地保存与原音归属，网络失败不回滚本地记录。
class NoteRepository {
  /// 绑定的数据源。
  final AppDatabase database;

  /// 创建仓储。
  const NoteRepository(this.database);

  /// 置顶优先，再按记录自然日、时钟和稳定身份监听有效笔记。
  Stream<List<NoteEntryRecord>> watchAll() =>
      (database.select(database.noteEntries)
            ..where((table) => table.deletedAt.isNull())
            ..orderBy([
              (table) => OrderingTerm.desc(table.isPinned),
              (table) => OrderingTerm.desc(table.dayKey),
              (table) => OrderingTerm.desc(table.createdAt),
              (table) => OrderingTerm.asc(table.id),
            ]))
          .watch()
          .map(
            (notes) => notes
              ..sort((first, second) {
                if (first.isPinned != second.isPinned) {
                  return first.isPinned ? -1 : 1;
                }
                // 按用户所见的自然日、时钟和稳定身份排序。
                final int day = second.dayKey.compareTo(first.dayKey);
                if (day != 0) return day;
                // 相同日期使用记录时钟，不使用真实创建时刻。
                final int clock = second.recordTime.seconds.compareTo(
                  first.recordTime.seconds,
                );
                return clock != 0 ? clock : first.id.compareTo(second.id);
              }),
          );

  /// 独立更新置顶状态，正文、标签、附件和历史版本保持原样。
  Future<void> setPinned(String id, bool pinned) =>
      database.transaction(() async {
        // 在事务内重新确认目标未删除，避免迟到菜单复活笔记。
        final NoteEntryRecord? current = await find(id);
        if (current == null || current.deletedAt != null) {
          throw StateError('笔记已删除或不可用');
        }
        if (current.isPinned == pinned) return;
        await (database.update(
          database.noteEntries,
        )..where((table) => table.id.equals(id))).write(
          NoteEntriesCompanion(
            isPinned: Value(pinned),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });

  /// 桌面独立修改只写正式记录时间，不提交编辑器内的其他草稿。
  Future<void> updateRecordTime(String id, NoteRecordTime value) =>
      database.transaction(() async {
        value.validate();
        // 在实际事务内重新确认笔记仍然存在且可编辑。
        final NoteEntryRecord? current = await find(id);
        if (current == null || current.deletedAt != null) {
          throw StateError('笔记已删除或不可用');
        }
        if (current.recordTime.label == value.label &&
            current.recordTime.utcOffsetMinutes == value.utcOffsetMinutes) {
          return;
        }
        await (database.update(
          database.noteEntries,
        )..where((table) => table.id.equals(id))).write(
          NoteEntriesCompanion(
            dayKey: Value(value.dayKey),
            recordTimeSeconds: Value(value.seconds),
            recordUtcOffsetMinutes: Value(value.utcOffsetMinutes),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });

  /// 读取一篇笔记，包括软删除以区分迟到的保存。
  Future<NoteEntryRecord?> find(String id) => (database.select(
    database.noteEntries,
  )..where((table) => table.id.equals(id))).getSingleOrNull();

  /// 正文与不可变版本在同一事务中保存，空白草稿不留档。
  Future<NoteEntryRecord?> save(
    NoteDraft draft, {
    bool hasAudio = false,
    bool hasImages = false,
  }) => database.transaction(() async {
    // 当前数据库版本。
    final NoteEntryRecord? previous = await find(draft.id);
    if (previous == null && draft.baseRevision.isNotEmpty) {
      throw StateError('原笔记已永久删除，当前输入可复制或另存为新笔记');
    }
    if (previous?.deletedAt != null) throw StateError('笔记已在回收站，修改未覆盖原记录');
    if (previous == null &&
        draft.body.trim().isEmpty &&
        !hasAudio &&
        !hasImages) {
      return null;
    }
    if (draft.body.length > 20000) {
      throw const FormatException('正文最多 20,000 字，请复制保存超出内容');
    }
    // 正文输入不隐含改写远端整理信息，标签按用户实际新增/移除合并。
    final Set<String> mergedTags =
        previous != null && draft.originalTags != null
        ? (noteTagIds(previous.tags)
                ..addAll(draft.tags.difference(draft.originalTags!)))
              .difference(draft.originalTags!.difference(draft.tags))
        : draft.tags;
    if (mergedTags.length > 10) {
      throw const FormatException('合并后超过 10 个标签，请调整标签后重试');
    }
    // 只有明确改动的日期才覆盖最新持久值。
    final bool tracked = previous != null && draft.originalTags != null;
    final String effectiveDay = tracked && !draft.dateEdited
        ? previous.dayKey
        : draft.dayKey;
    // 未主动改时间的旧草稿不能覆盖另一个入口的正式时间。
    final NoteRecordTime effectiveTime = tracked && !draft.dateEdited
        ? previous.recordTime
        : draft.recordTime;
    if (draft.dateEdited && draft.recordTimeSeconds != null) {
      effectiveTime.validate();
    }
    // 日期、时钟和偏移共同决定是否写入完整时间组。
    final bool recordTimeChanged =
        previous == null ||
        previous.dayKey != effectiveDay ||
        previous.recordTime.seconds != effectiveTime.seconds ||
        previous.recordTime.utcOffsetMinutes != effectiveTime.utcOffsetMinutes;
    // 当前写入时刻，创建时间不随编辑更新。
    final DateTime now = DateTime.now();
    // 标签身份排序，避免纯顺序变化反复同步。
    final List<String> tagIds = mergedTags.toList()..sort();
    // 本地验证标签存在且仍可使用。
    final List<TaxonomyEntry> validTaxonomies =
        await (database.select(database.taxonomyEntries)..where(
              (table) =>
                  table.module.equals('notes') & table.deletedAt.isNull(),
            ))
            .get();
    // 当前可用的标签身份。
    final Set<String> validTags = validTaxonomies
        .where((item) => item.kind == 'tag')
        .map((item) => item.id)
        .toSet();
    tagIds.removeWhere((id) => !validTags.contains(id));
    if (previous != null &&
        previous.body == draft.body &&
        previous.dayKey == effectiveDay &&
        previous.recordTime.seconds == effectiveTime.seconds &&
        previous.recordTime.utcOffsetMinutes ==
            effectiveTime.utcOffsetMinutes &&
        previous.tags == jsonEncode(tagIds)) {
      return previous;
    }
    // 只修改发生变化的列，禁止普通编辑带 deleted_at:null 意外恢复。
    final bool bodyChanged = previous == null || previous.body != draft.body;
    // 此次正文版本。
    final String revision = bodyChanged ? const Uuid().v4() : previous.revision;
    if (previous != null &&
        bodyChanged &&
        previous.revision != draft.baseRevision) {
      await database
          .into(database.noteVersions)
          .insert(
            NoteVersionsCompanion.insert(
              id: revision,
              noteId: draft.id,
              body: draft.body,
              baseRevision: draft.baseRevision,
              revision: revision,
              createdAt: now,
            ),
          );
      // 返回当前版展示冲突，不能抛异常回滚已保存的候选。
      return previous;
    }
    if (previous == null) {
      await database
          .into(database.noteEntries)
          .insert(
            NoteEntriesCompanion.insert(
              id: draft.id,
              body: Value(draft.body),
              dayKey: draft.dayKey,
              recordTimeSeconds: Value(effectiveTime.seconds),
              recordUtcOffsetMinutes: Value(effectiveTime.utcOffsetMinutes),
              tags: Value(jsonEncode(tagIds)),
              revision: revision,
              createdAt: draft.createdAt ?? now,
              creationTimezone: Value(
                draft.creationTimezone ??
                    noteCreationTimezone(draft.createdAt ?? now),
              ),
              updatedAt: now,
            ),
          );
    } else {
      if (bodyChanged) {
        // 先持久版本再更新正文，PowerSync 捕获顺序满足服务端基线校验。
        await database
            .into(database.noteVersions)
            .insert(
              NoteVersionsCompanion.insert(
                id: revision,
                noteId: draft.id,
                body: draft.body,
                baseRevision: draft.baseRevision,
                revision: revision,
                createdAt: now,
              ),
            );
      }
      await (database.update(
        database.noteEntries,
      )..where((table) => table.id.equals(draft.id))).write(
        NoteEntriesCompanion(
          body: bodyChanged ? Value(draft.body) : const Value.absent(),
          revision: bodyChanged ? Value(revision) : const Value.absent(),
          // 时间有任意变化时整组写入，上传端仍需补齐 SDK 裁去的未变列。
          dayKey: recordTimeChanged
              ? Value(effectiveDay)
              : const Value.absent(),
          recordTimeSeconds: recordTimeChanged
              ? Value(effectiveTime.seconds)
              : const Value.absent(),
          recordUtcOffsetMinutes: recordTimeChanged
              ? Value(effectiveTime.utcOffsetMinutes)
              : const Value.absent(),
          tags: jsonEncode(tagIds) != previous.tags
              ? Value(jsonEncode(tagIds))
              : const Value.absent(),
          updatedAt: Value(now),
        ),
      );
    }
    if (bodyChanged && previous == null) {
      await database
          .into(database.noteVersions)
          .insert(
            NoteVersionsCompanion.insert(
              id: revision,
              noteId: draft.id,
              body: draft.body,
              baseRevision: revision,
              revision: revision,
              createdAt: now,
            ),
          );
    }
    return find(draft.id);
  });

  /// 按开始顺序监听原音和候选转写。
  Stream<List<NoteAudioSegmentRecord>> watchAudio(String noteId) =>
      (database.select(database.noteAudioSegments)
            ..where(
              (table) => table.noteId.equals(noteId) & table.deletedAt.isNull(),
            )
            ..orderBy([
              (table) => OrderingTerm.asc(table.sortOrder),
              (table) => OrderingTerm.asc(table.id),
            ]))
          .watch();

  /// 监听不可变版本，供用户恢复离线冲突。
  Stream<List<NoteVersionRecord>> watchVersions(String noteId) =>
      (database.select(database.noteVersions)
            ..where(
              (table) => table.noteId.equals(noteId) & table.deletedAt.isNull(),
            )
            ..orderBy([(table) => OrderingTerm.desc(table.createdAt)]))
          .watch();

  /// 将已持久化可播放原音绑定到固定笔记，不改变人工正文。
  Future<void> addAudio({
    required NoteDraft draft,
    required String id,
    required String localPath,
    required int durationMs,
    required String mime,
    DateTime? startedAt,
  }) async {
    // 已有段身份，崩溃恢复或通知重复结束不得重复插入。
    final NoteAudioSegmentRecord? existing = await (database.select(
      database.noteAudioSegments,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
    if (existing != null) return;
    // 原音文件长度和校验值，摘要流式计算避免长录音占满内存。
    final File file = File(localPath);
    final int size = await file.length();
    final String digest = (await sha256.bind(file.openRead()).first).toString();
    if (durationMs <= 0 || size <= 44) {
      throw const FormatException('录音没有可保存的采样数据');
    }
    await database.transaction(() async {
      // 两个恢复或结束回调必须在同一事务内重新核实身份和总配额。
      final NoteAudioSegmentRecord? duplicate = await (database.select(
        database.noteAudioSegments,
      )..where((table) => table.id.equals(id))).getSingleOrNull();
      if (duplicate != null) return;
      // 串行查询已有段，避免并发新增超额与重复排序号。
      final List<NoteAudioSegmentRecord> segments = await (database.select(
        database.noteAudioSegments,
      )..where((table) => table.noteId.equals(draft.id))).get();
      if (durationMs > 1800000 ||
          segments.fold<int>(0, (sum, item) => sum + item.durationMs) +
                  durationMs >
              3600000) {
        throw const FormatException('录音超出单段 30 分钟或单篇 60 分钟上限，原音已保留等待恢复');
      }
      await save(draft, hasAudio: true);
      // 完成时刻；排序只取既有段的稳定顺序。
      final DateTime now = DateTime.now();
      await database
          .into(database.noteAudioSegments)
          .insert(
            NoteAudioSegmentsCompanion.insert(
              id: id,
              noteId: draft.id,
              sortOrder: segments.length,
              durationMs: durationMs,
              mime: mime,
              sha256: digest,
              byteSize: size,
              createdAt: startedAt ?? now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.noteAudioLocalFiles)
          .insertOnConflictUpdate(
            NoteAudioLocalFilesCompanion.insert(
              id: id,
              localPath: Value(localPath),
            ),
          );
    });
  }

  /// 另存使用独立原音身份；删除原记录不会删除新篇的文件引用。
  Future<NoteEntryRecord> saveAsNew(
    NoteDraft source, {
    bool hasAdditionalAudio = false,
    Set<String> excludedAudioIds = const {},
    bool hasAdditionalImages = false,
    Set<String> excludedImageIds = const {},
  }) async {
    // 包括回收站原音，以便删除与离线编辑并发时显式恢复副本。
    final List<NoteAudioSegmentRecord> audio =
        await (database.select(database.noteAudioSegments)..where(
              (table) =>
                  table.noteId.equals(source.id) &
                  table.id.isNotIn(excludedAudioIds),
            ))
            .get();
    // 预检完整原件，不能将缺失资产默默丢弃后宣称另存成功。
    final Map<String, String> paths = {};
    for (final NoteAudioSegmentRecord segment in audio) {
      // 本机文件是否仍可独立引用。
      final NoteAudioLocalFileRecord? local = await (database.select(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
      final File? file = local?.localPath == null
          ? null
          : File(local!.localPath!);
      if (file == null ||
          !await file.exists() ||
          await file.length() != segment.byteSize ||
          (await sha256.bind(file.openRead()).first).toString() !=
              segment.sha256) {
        throw StateError('原音不完整，请先恢复或下载原音；当前正文可复制保存');
      }
      paths[segment.id] = file.path;
    }
    // 图片存在性独立于正文，Android 另存也必须保留正式图片。
    final NoteImageRepository imageRepository = NoteImageRepository(database);
    // 当前另存排除用户暂存删除的图片。
    final List<NoteImageRecord> sourceImages = (await imageRepository.published(
      source.id,
    )).where((item) => !excludedImageIds.contains(item.id)).toList();
    if (source.body.trim().isEmpty &&
        audio.isEmpty &&
        !hasAdditionalAudio &&
        sourceImages.isEmpty &&
        !hasAdditionalImages) {
      throw StateError('当前没有可另存的正文或原音');
    }
    // 新创建时刻不冒充原记录的创建时刻。
    final DateTime now = DateTime.now();
    final NoteDraft replacement = NoteDraft(
      id: const Uuid().v4(),
      body: source.body,
      dayKey: source.dayKey,
      recordTimeSeconds: source.recordTime.seconds,
      recordUtcOffsetMinutes: source.recordTime.utcOffsetMinutes,
      baseRevision: '',
      tags: source.tags,
      createdAt: now,
      creationTimezone: noteCreationTimezone(now),
    );
    return database.transaction(() async {
      // 副本资产及正文必须一起成功，授权和旧任务身份不能继承。
      final NoteEntryRecord? saved = await save(
        replacement,
        hasAudio: audio.isNotEmpty || hasAdditionalAudio,
        hasImages: sourceImages.isNotEmpty || hasAdditionalImages,
      );
      if (saved == null) throw StateError('新笔记保存失败');
      for (final NoteAudioSegmentRecord segment in audio) {
        // 独立段身份复用已校验原件，由引用清理保护共享文件。
        final String id = const Uuid().v4();
        await database
            .into(database.noteAudioSegments)
            .insert(
              NoteAudioSegmentsCompanion.insert(
                id: id,
                noteId: saved.id,
                sortOrder: segment.sortOrder,
                durationMs: segment.durationMs,
                mime: segment.mime,
                sha256: segment.sha256,
                byteSize: segment.byteSize,
                transcript: Value(segment.transcript),
                createdAt: segment.createdAt,
                updatedAt: now,
              ),
            );
        await database
            .into(database.noteAudioLocalFiles)
            .insert(
              NoteAudioLocalFilesCompanion.insert(
                id: id,
                localPath: Value(paths[segment.id]),
              ),
            );
      }
      await imageRepository.copy(
        source.id,
        saved.id,
        excluded: excludedImageIds,
      );
      return saved;
    });
  }

  /// 正文、原音、转写与候选一起进入回收站。
  Future<void> insertReadyTranscripts(
    String noteId,
  ) => database.transaction(() async {
    // 即使另一张卡片正在编辑，也不能越过本机持久草稿自动改正文。
    final List<NoteLocalDraftRecord> drafts =
        await (database.select(database.noteLocalDrafts)..where(
              (table) =>
                  table.noteId.equals(noteId) & table.discarded.equals(false),
            ))
            .get();
    if (drafts.isNotEmpty) return;
    // 当前正式正文与原音顺序。
    NoteEntryRecord? note = await find(noteId);
    if (note == null || note.deletedAt != null) return;
    final List<NoteAudioSegmentRecord> audio =
        await (database.select(database.noteAudioSegments)
              ..where(
                (table) =>
                    table.noteId.equals(noteId) & table.deletedAt.isNull(),
              )
              ..orderBy([(table) => OrderingTerm.asc(table.sortOrder)]))
            .get();
    for (final NoteAudioSegmentRecord segment in audio) {
      // 预留起点只存在于新录音，不影响重新转写候选。
      final NoteAudioLocalFileRecord? local = await (database.select(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
      if (local?.consent != true ||
          local?.insertedRevision?.startsWith('waiting:') != true) {
        continue;
      }
      if (segment.transcript == null) break;
      // 用户已修改正文时永久保留待插入候选，不覆盖人工内容。
      final String base = local!.insertedRevision!.substring('waiting:'.length);
      if (note!.revision != base) continue;
      // 无有效人声不能制造空文字或删除音频。
      final String text = segment.transcript!.trim();
      final String body = text.isEmpty
          ? note.body
          : note.body.isEmpty
          ? text
          : '${note.body}\n\n$text';
      if (body.length > 20000) continue;
      // 正文与版本一同落库，避免重复插入和人工内容覆盖。
      final NoteEntryRecord? changed = await save(
        NoteDraft(
          id: note.id,
          body: body,
          dayKey: note.dayKey,
          recordTimeSeconds: note.recordTimeSeconds,
          recordUtcOffsetMinutes: note.recordUtcOffsetMinutes,
          baseRevision: base,
          tags: noteTagIds(note.tags),
          originalTags: noteTagIds(note.tags),
          createdAt: note.createdAt,
          creationTimezone: note.creationTimezone,
        ),
        hasAudio: true,
      );
      if (changed == null || changed.body != body) return;
      await (database.update(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(segment.id))).write(
        NoteAudioLocalFilesCompanion(insertedRevision: Value(changed.revision)),
      );
      // 其余同起点位置承接自动插入产生的新版本，仍按原音顺序处理。
      await (database.update(database.noteAudioLocalFiles)..where(
            (table) =>
                table.id.isIn(audio.map((item) => item.id)) &
                table.insertedRevision.equals('waiting:$base'),
          ))
          .write(
            NoteAudioLocalFilesCompanion(
              insertedRevision: Value('waiting:${changed.revision}'),
            ),
          );
      note = changed;
    }
  });

  /// 正文、原音、转写与候选一起进入回收站。
  Future<void> softDelete(String id) => _setDeleted(id, DateTime.now());

  /// 恢复同篇所有资产，已删除标签仍不可使用。
  Future<void> restore(String id) => _setDeleted(id, null);

  /// 原子切换绑定记录的回收站状态。
  Future<void> _setDeleted(String id, DateTime? deletedAt) =>
      database.transaction(() async {
        // 当前状态对应的主记录。
        final NoteEntryRecord? note = await find(id);
        if (note == null) return;
        await (database.update(
          database.noteEntries,
        )..where((table) => table.id.equals(id))).write(
          NoteEntriesCompanion(
            deletedAt: Value(deletedAt),
            updatedAt: Value(DateTime.now()),
          ),
        );
        await (database.update(database.noteVersions)
              ..where((table) => table.noteId.equals(id)))
            .write(NoteVersionsCompanion(deletedAt: Value(deletedAt)));
        await (database.update(
          database.noteAudioSegments,
        )..where((table) => table.noteId.equals(id))).write(
          NoteAudioSegmentsCompanion(
            deletedAt: Value(deletedAt),
            updatedAt: Value(DateTime.now()),
          ),
        );
        await (database.update(
          database.noteImages,
        )..where((table) => table.noteId.equals(id))).write(
          NoteImagesCompanion(
            deletedAt: Value(deletedAt),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });

  /// 永久删除业务记录；文件只在事务提交后由孤儿清理器移除。
  Future<void> permanentlyDelete(String id) => database.transaction(() async {
    // 明确永久删除也取消对应本机草稿，物理原件等待事务提交后再清理。
    await (database.update(
      database.noteLocalDrafts,
    )..where((table) => table.noteId.equals(id))).write(noteDraftTombstone());
    await (database.delete(
      database.noteVersions,
    )..where((table) => table.noteId.equals(id))).go();
    await (database.delete(
      database.noteAudioSegments,
    )..where((table) => table.noteId.equals(id))).go();
    await (database.delete(
      database.noteImages,
    )..where((table) => table.noteId.equals(id))).go();
    await (database.delete(
      database.noteEntries,
    )..where((table) => table.id.equals(id))).go();
  });

  /// 正式原音及未丢弃草稿共同保护文件路径，另存可以共享同一原件。
  Future<Set<String>> protectedAudioPaths() => database.transaction(() async {
    // 正式片段包含回收站，保留期内原音仍受保护。
    final Set<String> referenced =
        (await database.select(database.noteAudioSegments).get())
            .map((item) => item.id)
            .toSet();
    // 可恢复草稿代次。
    final Set<String> drafts =
        (await (database.select(
              database.noteLocalDrafts,
            )..where((table) => table.discarded.equals(false))).get())
            .map((item) => item.id)
            .toSet();
    // 已发布文件及未发布原件分别读取，不能给草稿创建正式本机文件行。
    final List<NoteAudioLocalFileRecord> local = await database
        .select(database.noteAudioLocalFiles)
        .get();
    // 草稿原件不经过自动传输器。
    final List<NoteDraftAudioSegmentRecord> staged = await database
        .select(database.noteDraftAudioSegments)
        .get();
    return {
      for (final NoteAudioLocalFileRecord item in local)
        if (referenced.contains(item.id) && item.localPath != null)
          item.localPath!,
      for (final NoteDraftAudioSegmentRecord item in staged)
        if (drafts.contains(item.draftId) && item.localPath != null)
          item.localPath!,
    };
  });

  /// 在已提交数据库状态下清理永久删除的文件，失败保留记录以便重试。
  Future<void> purgeOrphanFiles() => database.transaction(() async {
    await NoteImageRepository(database).purgeOrphans();
    // 引用快照、文件删除与本机行清理持有同一写事务，新增草稿不能夹在检查之间。
    // 本机草稿原件与正式文件共享保护集合，取消不会删掉已另存的引用。
    final Set<String> protectedPaths = await protectedAudioPaths();
    // 本机已管理的原音缓存。
    final List<NoteAudioLocalFileRecord> local = await database
        .select(database.noteAudioLocalFiles)
        .get();
    // 当前仍受业务引用保护的原音段。
    final Set<String> referenced =
        (await database.select(database.noteAudioSegments).get())
            .map((item) => item.id)
            .toSet();
    for (final NoteAudioLocalFileRecord item in local) {
      if (referenced.contains(item.id)) continue;
      if (item.localPath != null &&
          !protectedPaths.contains(item.localPath) &&
          !local.any(
            (other) =>
                other.id != item.id &&
                referenced.contains(other.id) &&
                other.localPath == item.localPath,
          )) {
        // 文件可能因系统或用户清理已不存在。
        final File file = File(item.localPath!);
        if (await file.exists()) await file.delete();
      }
      await (database.delete(
        database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(item.id))).go();
    }
    // 已取消或明确永久删除的草稿原件在事务提交后重试清理。
    final Set<String> activeDrafts =
        (await (database.select(
              database.noteLocalDrafts,
            )..where((table) => table.discarded.equals(false))).get())
            .map((item) => item.id)
            .toSet();
    // 无草稿主记录的残余新增原音也不能无限留存。
    final List<NoteDraftAudioSegmentRecord> staged = await database
        .select(database.noteDraftAudioSegments)
        .get();
    for (final NoteDraftAudioSegmentRecord item in staged) {
      if (activeDrafts.contains(item.draftId)) continue;
      if (item.localPath != null && !protectedPaths.contains(item.localPath)) {
        // 路径来自当前受管理数据源的本机录音或已验证迁移副本。
        final File file = File(item.localPath!);
        if (await file.exists()) await file.delete();
      }
      await (database.delete(
        database.noteDraftAudioSegments,
      )..where((table) => table.id.equals(item.id))).go();
    }
  });
}
