import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:uuid/uuid.dart';

/// 编辑器与录音共享的应用级会话，不随导航预载产生正式笔记。
class NoteEditorController extends ChangeNotifier {
  /// 当前数据源仓储。
  final NoteRepository repository;

  /// 当前设备唯一录音器。
  final NoteRecorderService recorder;

  /// 内存中的正文和归档元数据。
  late NoteDraft draft;

  /// 当前保存状态。
  String saveStatus = '空白笔记';

  /// 可恢复的失败原因。
  String? error;

  /// 未保存编辑标志。
  bool dirty = false;

  /// 正文冲突需用户明确选择版本。
  bool conflicted = false;

  /// 防止较早保存回写较新输入。
  int _generation = 0;

  /// 停止输入后保存计时器。
  Timer? _debounce;

  /// 持续输入最多两秒落盘。
  Timer? _deadline;

  /// 当前串行保存任务。
  Future<void>? _saving;

  /// 完成录音的持久化订阅。
  late final StreamSubscription<NoteRecordingResult> _completed;

  /// 自动转写只授权新录音，历史不追溯纳入。
  bool voiceConsent = false;

  /// 当前正在保存的原音任务，退出时排空。
  Future<void> _audioWrites = Future.value();

  /// 活跃录音开始时固定的草稿上下文。
  NoteDraft? _recordingDraft;

  /// 仅录音开始时已有明确授权的本段可以自动转写。
  bool _recordingConsent = false;

  /// 草稿是否已形成持久笔记。
  bool _persisted = false;

  /// 日期是否由用户明确选择。
  bool _explicitDay = false;

  /// 是否已销毁通知器。
  bool _closed = false;

  /// 已检测到但尚未恢复的原音数量。
  int pendingRecoveryCount = 0;

  /// 同一会话只主动检测一次恢复清单。
  bool _recoveryScanned = false;

  /// 创建编辑会话；内存草稿不入历史。
  NoteEditorController(this.repository, this.recorder) {
    _blank();
    _completed = recorder.completed.listen((result) {
      _audioWrites = _audioWrites.then((_) => _persistAudio(result)).catchError(
        (Object failure) {
          pendingRecoveryCount++;
          error = '原音待恢复：$failure';
          _notify();
        },
      );
    });
  }

  /// 安全通知仍在存活的页面。
  void _notify() {
    if (!_closed) notifyListeners();
  }

  /// 只分配内存草稿身份，实际写入由有效内容触发。
  void _blank() {
    _persisted = false;
    _explicitDay = false;
    draft = NoteDraft(
      id: const Uuid().v4(),
      body: '',
      dayKey: businessDayKey(DateTime.now()),
      baseRevision: '',
    );
    dirty = false;
    conflicted = false;
    error = null;
    saveStatus = '空白笔记';
    _generation++;
  }

  /// 主动进入入口；在录音时始终返回原笔记。
  Future<void> enter() async {
    await checkRecovery();
    if (recorder.state.isActive && recorder.state.noteId != null) {
      if (draft.id != recorder.state.noteId) await open(recorder.state.noteId!);
      return;
    }
    await newNote();
  }

  /// 显式新建先结束并保存原音，再切换空白编辑器。
  Future<void> newNote() async {
    if (recorder.state.isActive) {
      await recorder.stop();
      await _audioWrites;
    }
    await flush();
    if (dirty) return;
    _blank();
    _notify();
  }

  /// 历史或搜索只打开原记录。
  Future<void> open(String id) async {
    if (id == draft.id) return;
    await flush();
    if (dirty) return;
    // 旧记录可能已在另一设备删除。
    final NoteEntryRecord? note = await repository.find(id);
    if (note == null || note.deletedAt != null) {
      if (note == null &&
          recorder.state.isActive &&
          recorder.state.noteId == id &&
          _recordingDraft?.id == id) {
        // 纯录音草稿尚未落库，恢复原始内存上下文，不能新建或转移归属。
        draft = _recordingDraft!;
        _persisted = false;
        dirty = false;
        error = null;
        saveStatus = '录音中，原音持续保存';
        _generation++;
        _notify();
        return;
      }
      error = '笔记不存在或已在回收站';
      _notify();
      return;
    }
    _load(note);
    _notify();
  }

  /// 将持久版本载入编辑器。
  void _load(NoteEntryRecord note) {
    _persisted = true;
    draft = NoteDraft(
      id: note.id,
      body: note.body,
      dayKey: note.dayKey,
      baseRevision: note.revision,
      categoryId: note.categoryId,
      categoryName: note.categoryName,
      tags: noteTagIds(note.tags),
      createdAt: note.createdAt,
      creationTimezone: note.creationTimezone,
      originalTags: noteTagIds(note.tags),
    );
    dirty = false;
    conflicted = false;
    error = null;
    saveStatus = '已保存到本机';
    _generation++;
  }

  /// 清洁编辑器可接收转写或同步变化，不覆盖人工未保存输入。
  void acceptRemote(NoteEntryRecord? note) {
    if (dirty || conflicted) {
      return;
    }
    if (note == null) {
      if (_persisted) {
        error = '原笔记已永久删除，当前内容可复制或另存为新笔记';
        _notify();
      }
      return;
    }
    if (note.id != draft.id) return;
    if (note.deletedAt != null) {
      error = '笔记已在回收站，当前输入可复制';
      _notify();
      return;
    }
    if (note.revision == draft.baseRevision &&
        note.dayKey == draft.dayKey &&
        note.categoryId == draft.categoryId &&
        note.categoryName == draft.categoryName &&
        setEquals(noteTagIds(note.tags), draft.tags)) {
      return;
    }
    _load(note);
    _notify();
  }

  /// 输入、日期、类别及标签变更共用自动保存。
  void edit({
    String? body,
    String? dayKey,
    String? categoryId,
    String? categoryName,
    bool clearCategory = false,
    Set<String>? tags,
  }) {
    if (dayKey != null) _explicitDay = true;
    // 第一次有效输入固定真实时刻，自动保存延迟不改变创建时间。
    final DateTime now = DateTime.now();
    final DateTime? createdAt =
        draft.createdAt ?? (body?.trim().isNotEmpty == true ? now : null);
    // 打开空白页跨午夜后首次输入按产生内容时归档。
    final String effectiveDay =
        !_persisted &&
            !_explicitDay &&
            draft.body.trim().isEmpty &&
            body?.trim().isNotEmpty == true
        ? businessDayKey(now)
        : dayKey ?? draft.dayKey;
    draft = NoteDraft(
      id: draft.id,
      body: body ?? draft.body,
      dayKey: effectiveDay,
      baseRevision: draft.baseRevision,
      categoryId: clearCategory ? null : categoryId ?? draft.categoryId,
      categoryName: clearCategory ? null : categoryName ?? draft.categoryName,
      tags: tags ?? draft.tags,
      createdAt: createdAt,
      creationTimezone:
          draft.creationTimezone ??
          (createdAt == null ? null : noteCreationTimezone(createdAt)),
      originalTags: draft.originalTags,
      categoryEdited:
          draft.categoryEdited || clearCategory || categoryId != null,
      dateEdited: draft.dateEdited || dayKey != null,
    );
    dirty = true;
    _generation++;
    saveStatus = '保存中';
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(flush()),
    );
    _deadline ??= Timer(const Duration(seconds: 2), () => unawaited(flush()));
    _notify();
  }

  /// 排空待保存输入；失败保留草稿，不伪装成功。
  Future<void> flush() async {
    _debounce?.cancel();
    _deadline?.cancel();
    _deadline = null;
    if (_saving != null) {
      await _saving;
      if (dirty && !conflicted && error == null) await flush();
      return;
    }
    if (!dirty || conflicted) return;
    _saving = _save();
    await _saving;
    _saving = null;
  }

  /// 当前输入快照保存完成后只更新其对应版本身份。
  Future<void> _save() async {
    // 防止异步结果越过后续编辑。
    final int generation = _generation;
    // 不可变的待保存输入。
    final NoteDraft saving = draft;
    try {
      // 仓储返回不同正文说明保存的是冲突候选。
      final NoteEntryRecord? note = await repository.save(saving);
      if (note != null && note.body != saving.body) {
        conflicted = true;
        error = '正文存在其他版本；当前输入已保留为候选，请选择版本';
        saveStatus = '待解决冲突';
        _notify();
        return;
      }
      if (generation == _generation) {
        dirty = false;
        error = null;
        if (note != null) {
          _load(note);
        } else {
          saveStatus = '空白笔记';
        }
      } else if (note != null) {
        // 保存期间的继续输入只携带新的整理差异，保留刚合并的远端新增标签。
        final Set<String> savedTags = noteTagIds(note.tags);
        final Set<String> continuedTags =
            (savedTags..addAll(draft.tags.difference(saving.tags))).difference(
              saving.tags.difference(draft.tags),
            );
        draft = NoteDraft(
          id: draft.id,
          body: draft.body,
          dayKey: draft.dateEdited ? draft.dayKey : note.dayKey,
          baseRevision: note.revision,
          categoryId: draft.categoryEdited ? draft.categoryId : note.categoryId,
          categoryName: draft.categoryEdited
              ? draft.categoryName
              : note.categoryName,
          tags: continuedTags,
          createdAt: note.createdAt,
          creationTimezone: note.creationTimezone,
          originalTags: noteTagIds(note.tags),
          categoryEdited:
              draft.categoryEdited && draft.categoryId != note.categoryId,
          dateEdited: draft.dateEdited && draft.dayKey != note.dayKey,
        );
      }
    } catch (failure) {
      error = '$failure';
      saveStatus = '保存失败，重试';
    }
    _notify();
  }

  /// 用户明确选择版本后才覆盖当前正文。
  Future<void> useVersion(String body) async {
    // 更新起点，明确覆盖可见最新版本。
    final NoteEntryRecord? current = await repository.find(draft.id);
    if (current == null || current.deletedAt != null) return;
    _load(current);
    edit(body: body);
    await flush();
  }

  /// 录音启动绑定原笔记，允许历史浏览保持该归属。
  Future<void> startRecording() async {
    await flush();
    if (dirty) return;
    if (!_persisted && draft.createdAt == null) {
      // 开始实际采集时固定日期和创建时区。
      final DateTime now = DateTime.now();
      draft = NoteDraft(
        id: draft.id,
        body: draft.body,
        dayKey: _explicitDay ? draft.dayKey : businessDayKey(now),
        baseRevision: draft.baseRevision,
        categoryId: draft.categoryId,
        categoryName: draft.categoryName,
        tags: draft.tags,
        createdAt: now,
        creationTimezone: noteCreationTimezone(now),
      );
    }
    // 计算已保存总时长，不把暂停算入额度。
    final List<NoteAudioSegmentRecord> segments =
        await (repository.database.select(
          repository.database.noteAudioSegments,
        )..where((table) => table.noteId.equals(draft.id))).get();
    // 当前剩余额度。
    final Duration remaining = Duration(
      milliseconds:
          3600000 - segments.fold<int>(0, (sum, item) => sum + item.durationMs),
    );
    if (remaining <= Duration.zero) {
      error = '本篇录音已达 60 分钟，请新建笔记';
      _notify();
      return;
    }
    _recordingDraft = draft;
    _recordingConsent = voiceConsent;
    try {
      await recorder.start(draft.id, remaining: remaining);
    } catch (_) {
      if (!_persisted && draft.body.trim().isEmpty) {
        // 拒绝权限或设备启动失败尚无有效内容，不能提前固定创建时刻。
        draft = NoteDraft(
          id: draft.id,
          body: draft.body,
          dayKey: draft.dayKey,
          baseRevision: draft.baseRevision,
          categoryId: draft.categoryId,
          categoryName: draft.categoryName,
          tags: draft.tags,
          originalTags: draft.originalTags,
          categoryEdited: draft.categoryEdited,
          dateEdited: draft.dateEdited,
        );
        _recordingDraft = null;
      }
      rethrow;
    }
  }

  /// 原音持久化成功才移除恢复清单。
  Future<void> _persistAudio(
    NoteRecordingResult result, {
    bool recovery = false,
  }) async {
    // 完成事件可能晚于整篇永久删除，恢复清单也必须服从同一删除事实。
    if (await recorder.isPermanentlyDiscarded(result.noteId)) {
      await recorder.discardPendingForNote(result.noteId);
      return;
    }
    // 浏览别的笔记时读取录音所属笔记，不使用当前编辑器身份。
    NoteEntryRecord? stored = await repository.find(result.noteId);
    // 被删除的原音不能使原笔记复活，仍保留恢复清单供用户另存。
    if (stored?.deletedAt != null) throw StateError('原笔记已删除，录音原件仍保留');
    // 若仍在本篇编辑，首先排空人工输入。
    if (draft.id == result.noteId) await flush();
    stored = await repository.find(result.noteId);
    // 固定开始日期，跨午夜录音不移动归档日期。
    final NoteDraft recording = stored != null
        ? NoteDraft(
            id: stored.id,
            body: stored.body,
            dayKey: stored.dayKey,
            baseRevision: stored.revision,
            categoryId: stored.categoryId,
            categoryName: stored.categoryName,
            tags: noteTagIds(stored.tags),
            createdAt: stored.createdAt,
            creationTimezone: stored.creationTimezone,
          )
        : draft.id == result.noteId
        ? draft
        : _recordingDraft?.id == result.noteId
        ? _recordingDraft!
        : NoteDraft(
            id: result.noteId,
            body: '',
            dayKey: noteRecordingDayKey(
              result.startedAt,
              result.creationTimezone,
            ),
            baseRevision: '',
            createdAt: result.startedAt,
            creationTimezone: result.creationTimezone ?? 'legacy:unknown',
          );
    await repository.addAudio(
      draft: recording,
      id: result.id,
      localPath: result.path,
      durationMs: result.duration.inMilliseconds,
      mime: result.mimeType,
      startedAt: result.startedAt,
    );
    if (!recovery &&
        _recordingConsent &&
        _recordingDraft?.id == result.noteId) {
      // 未修改预留位置才允许自动填入，否则只保留候选。
      final NoteEntryRecord? anchored = await repository.find(result.noteId);
      final bool untouched =
          _recordingDraft?.body == anchored?.body &&
          !(draft.id == result.noteId && dirty);
      // 仅对本次新录音明确授权；历史恢复不默认沿用新录音授权。
      await (repository.database.update(
        repository.database.noteAudioLocalFiles,
      )..where((table) => table.id.equals(result.id))).write(
        NoteAudioLocalFilesCompanion(
          consent: const Value(true),
          insertedRevision: untouched
              ? Value('waiting:${anchored!.revision}')
              : const Value(null),
        ),
      );
    }
    await recorder.acknowledge(result.id);
    if (pendingRecoveryCount > 0) pendingRecoveryCount--;
    if (draft.id == result.noteId) {
      // 原音写入后取得正式正文版本。
      final NoteEntryRecord? saved = await repository.find(result.noteId);
      if (saved != null && !dirty) _load(saved);
    }
    if (result.interruptionReason != null) error = result.interruptionReason;
    _notify();
  }

  /// 用户启动恢复时逐段挂回原记录，不自动重新录音。
  Future<void> recover() async {
    // 恢复原音可能来自上次进程，逐段串行避免重复身份。
    final List<NoteRecordingResult> recovered = await recorder.recoverPending();
    for (final NoteRecordingResult item in recovered) {
      // 原笔记不存在时不能分辨未落库草稿与删除墓碑，显式恢复为新篇。
      final NoteEntryRecord? original = await repository.find(item.noteId);
      final NoteRecordingResult restored =
          original != null && original.deletedAt == null
          ? item
          : NoteRecordingResult(
              id: item.id,
              noteId: const Uuid().v4(),
              path: item.path,
              duration: item.duration,
              startedAt: item.startedAt,
              creationTimezone: item.creationTimezone,
              mimeType: item.mimeType,
              interruptionReason: '原笔记已不可用，原音已恢复为独立新笔记，可在历史查看',
            );
      await _persistAudio(restored, recovery: true);
    }
    pendingRecoveryCount = 0;
    _notify();
  }

  /// 只检查未确认原音并提示，不自动开始录音或发送语音供应商。
  Future<void> checkRecovery() async {
    if (_recoveryScanned) return;
    _recoveryScanned = true;
    try {
      pendingRecoveryCount = (await recorder.recoverPending()).length;
      _notify();
    } catch (failure) {
      _recoveryScanned = false;
      error = '检查上次录音失败：$failure';
      _notify();
    }
  }

  /// 正常退出先刷新正文再结束录音并排空持久化。
  Future<void> shutdown() async {
    await flush();
    await recorder.stop(reason: '应用退出，已保存可用原音');
    await _audioWrites;
    if (dirty) throw StateError(error ?? '正文尚未保存，请重试或另存为新笔记');
  }

  /// 原记录删除或发生冲突时，显式另存当前正文和整理信息。
  Future<void> saveAsNew() async {
    // 固定当前内容；旧记录、版本和原音仍按原生命周期管理。
    final NoteDraft previous = draft;
    final NoteEntryRecord saved = await repository.saveAsNew(previous);
    _load(saved);
    _notify();
  }

  /// 释放页面通知和计时器；未确认原音仍保留恢复清单。
  @override
  void dispose() {
    _closed = true;
    _debounce?.cancel();
    _deadline?.cancel();
    unawaited(_completed.cancel());
    super.dispose();
  }
}
