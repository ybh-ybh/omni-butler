import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/features/notes/data/note_local_draft_repository.dart';
import 'package:omni_butler/features/notes/data/note_draft_audio_edits.dart';
import 'package:omni_butler/features/notes/data/note_image_repository.dart';
import 'package:uuid/uuid.dart';

/// 显式提交结果，失败或冲突均保留本机草稿。
enum NoteCommitResult { committed, conflict, failed, empty }

/// 编辑器与录音共享的应用级会话，不随导航预载产生正式笔记。
class NoteEditorController extends ChangeNotifier {
  /// 当前数据源仓储。
  final NoteRepository repository;

  /// 当前设备唯一录音器。
  final NoteRecorderService recorder;

  /// 启用显式提交的工作区只发布正式笔记，其他平台沿用自动保存。
  final bool explicitCommit;

  /// 与正式仓储共享事务的本机草稿存储。
  late final NoteLocalDraftRepository localDrafts;

  /// 图片仓储与编辑器使用同一数据库，页面可以直接订阅展示流。
  late final NoteImageRepository images;

  /// 当前草稿及正式图片的最新快照。
  List<NoteImageView> _visibleImages = [];

  /// 当前代次的图片监听，切换笔记后取消旧订阅。
  StreamSubscription<List<NoteImageView>>? _imageSubscription;

  /// 保存前暂存的图片删除身份。
  final Set<String> _pendingImageDeletions = {};

  /// 选择图片后的文件复制任务，发布和退出需等待完成。
  Future<void>? _imageWrites;

  /// 图片复制即使切换当前卡片仍按最初笔记身份保护。
  String? _imageWritingNoteId;

  /// 图片异步队列已报告的失败按笔记归属保留，删除前不能因队列结束而忽略。
  final Map<String, ({String draftId, Object failure})> _imageWriteFailures =
      {};

  /// 图片复制期间禁用重复选择。
  bool get imageAdding => _imageWrites != null;

  /// 纯图片草稿可以发布，不依赖正文或原音。
  bool get hasImages => _visibleImages.any((item) => !isImageRemoved(item.id));

  /// 页面隐藏当前草稿内待删除的图片。
  bool isImageRemoved(String id) => _pendingImageDeletions.contains(id);

  /// 当前本机草稿代次，与最终笔记身份分离。
  String? _draftId;

  /// 提供给卡片与录音预览的草稿代次。
  String? get draftId => _draftId;

  /// 当前草稿是否尚未发布。
  bool _isNewDraft = true;

  /// 本机落盘不代表已经显式保存到正式笔记。
  bool _localHasChanges = false;

  /// 所有未提交草稿的笔记身份，包含暂时未打开的历史卡片。
  final Set<String> _localNoteIds = {};

  /// 首次索引载入前保守阻止后台自动填入正文。
  bool _localIndexReady = false;

  /// 本机草稿索引监听。
  StreamSubscription<List<NoteLocalDraftRecord>>? _localSubscription;

  /// 当前待正式提交的转写插入标记。
  final Map<String, bool> _pendingInsertions = {};

  /// 正式保存前只隐藏已删除片段，原件与正式记录继续受保护。
  final Set<String> _pendingAudioDeletions = {};

  /// 页面过滤当前编辑中待删除的正式或新增原音。
  bool isAudioRemoved(String id) => _pendingAudioDeletions.contains(id);

  /// 连续点击发布只提交一次。
  bool committing = false;

  /// 原篇进入回收站或永久删除时冻结原草稿，仍可另存或取消。
  bool frozen = false;

  /// 取消中的草稿不能接收新输入。
  bool _cancelling = false;

  /// 开始录音时固定的草稿代次。
  String? _recordingDraftId;

  /// 权限请求与设备启动可能晚于用户点击，退出和取消必须排空这一任务。
  Future<void>? _startingRecording;

  /// 权限界面尚未返回时也能定位启动任务所归属的笔记。
  String? _startingRecordingNoteId;

  /// 删除准备复用提交门禁，同时允许其他笔记的在途录音启动继续。
  Set<String>? _preparingDeletionIds;

  /// 页面可据此防止启动过程中改变输入归属。
  bool get recordingStarting => _startingRecording != null;

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

  /// 新录音的默认转写授权，历史不追溯纳入。
  bool voiceConsent = false;

  /// 显式授权开关可覆盖当前所属片段，历史录音和其他草稿不追溯授权。
  void setVoiceConsent(bool enabled, {bool includeCurrentRecording = false}) {
    if (committing || _cancelling) return;
    voiceConsent = enabled;
    if (includeCurrentRecording &&
        recorder.state.isActive &&
        recorder.state.noteId == draft.id &&
        recorder.state.draftId == _draftId &&
        _recordingDraftId == _draftId) {
      _recordingConsent = enabled;
    }
    _notify();
  }

  /// 当前正在保存的原音任务，退出时排空。
  Future<void> _audioWrites = Future.value();

  /// 已被完成订阅捕获的暂存失败不能伪装为成功排空。
  final Map<String, ({String noteId, String? draftId, Object failure})>
  _audioWriteFailures = {};

  /// 活跃录音开始时固定的草稿上下文。
  NoteDraft? _recordingDraft;

  /// 本段自动转写授权，Windows 当前录音的显式开关可以更新。
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
  NoteEditorController(
    this.repository,
    this.recorder, {
    this.explicitCommit = false,
    NoteLocalDraftRepository? localDraftRepository,
    NoteImageRepository? imageRepository,
  }) {
    localDrafts = localDraftRepository ?? NoteLocalDraftRepository(repository);
    images = imageRepository ?? NoteImageRepository(repository.database);
    _blank();
    if (explicitCommit) {
      _localSubscription = localDrafts.watch().listen((records) {
        _localNoteIds
          ..clear()
          ..addAll(records.map((item) => item.noteId));
        _localIndexReady = true;
        _notify();
      });
    }
    _completed = recorder.completed.listen(_queueAudio);
  }

  /// 完成事件和停止返回统一排队，原生双通道交付顺序不影响可靠暂存。
  void _queueAudio(NoteRecordingResult result) {
    _audioWrites = _audioWrites
        .then((_) async {
          await _persistAudio(result);
          _audioWriteFailures.remove(result.id);
        })
        .catchError((Object failure) {
          _audioWriteFailures[result.id] = (
            noteId: result.noteId,
            draftId: result.draftId,
            failure: failure,
          );
          pendingRecoveryCount++;
          error = '原音待恢复：$failure';
          _notify();
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
    _draftId = explicitCommit ? const Uuid().v4() : null;
    _isNewDraft = true;
    _localHasChanges = false;
    _pendingInsertions.clear();
    _pendingAudioDeletions.clear();
    _pendingImageDeletions.clear();
    frozen = false;
    _generation++;
    _observeImages();
  }

  /// 固定订阅身份，旧流晚到时不能污染新卡片的发布状态。
  void _observeImages() {
    unawaited(_imageSubscription?.cancel());
    _visibleImages = [];
    // 此次订阅对应的正式与草稿身份。
    final String noteId = draft.id;
    final String? localId = _draftId;
    _imageSubscription = images.watch(noteId, draftId: localId).listen((value) {
      if (draft.id != noteId || _draftId != localId || _closed) return;
      _visibleImages = value;
      _notify();
    });
  }

  /// 多选逐张暂存，部分失败时已成功的图片仍留在草稿。
  Future<void> addImages(List<String> paths, {String? requestId}) async {
    if (!explicitCommit ||
        paths.isEmpty ||
        _imageWrites != null ||
        committing ||
        _cancelling ||
        frozen ||
        conflicted) {
      return;
    }
    // 当前选择固定归属，异步文件复制不跟随卡片切换。
    final String localId = _draftId!;
    // 最终笔记身份不会随草稿代次变化。
    final String noteId = draft.id;
    // 发布、取消与退出共享这个在途任务。
    final Future<void> work = _stageImages(
      localId,
      noteId,
      paths,
      requestId: requestId,
    );
    _imageWrites = work;
    _imageWritingNoteId = noteId;
    _notify();
    try {
      await work;
      _imageWriteFailures.remove(noteId);
    } catch (failure) {
      _imageWriteFailures[noteId] = (draftId: localId, failure: failure);
      if (_draftId == localId) error = '$failure';
      rethrow;
    } finally {
      if (identical(_imageWrites, work)) {
        _imageWrites = null;
        _imageWritingNoteId = null;
      }
      _notify();
    }
  }

  /// 首次有效图片输入沿用正文的创建时刻与本机草稿流程。
  Future<void> _stageImages(
    String localId,
    String noteId,
    List<String> paths, {
    String? requestId,
  }) async {
    // 空正文也需要先持久化草稿代次，取消才能可靠写墓碑。
    final DateTime now = DateTime.now();
    if (draft.createdAt == null) {
      draft = NoteDraft(
        id: draft.id,
        body: draft.body,
        dayKey: _explicitDay ? draft.dayKey : businessDayKey(now),
        recordTimeSeconds: draft.recordTimeSeconds,
        recordUtcOffsetMinutes: draft.recordUtcOffsetMinutes,
        baseRevision: draft.baseRevision,
        tags: draft.tags,
        originalTags: draft.originalTags,
        dateEdited: draft.dateEdited,
        createdAt: now,
        creationTimezone: noteCreationTimezone(now),
      );
    }
    _localHasChanges = true;
    _localNoteIds.add(noteId);
    dirty = true;
    _generation++;
    await flush();
    if (dirty) throw StateError(error ?? '草稿暂存失败');
    // 请求内序号生成稳定附件身份，系统恢复重复交付也不会重复导入。
    for (int index = 0; index < paths.length; index++) {
      if (!await images.stage(
        localId,
        noteId,
        paths[index],
        imageId: requestId == null
            ? null
            : const Uuid().v5(
                Namespace.url.value,
                'notes-media:$requestId:$index',
              ),
      )) {
        break;
      }
    }
  }

  /// 图片删除只改变本机草稿差量，取消恢复全部正式关联。
  Future<void> removeImage(String id) async {
    if (!explicitCommit ||
        committing ||
        _cancelling ||
        frozen ||
        conflicted ||
        imageAdding) {
      return;
    }
    if (!_visibleImages.any((item) => item.id == id)) return;
    _pendingImageDeletions.add(id);
    _localHasChanges = true;
    _localNoteIds.add(draft.id);
    dirty = true;
    _generation++;
    _notify();
    await flush();
  }

  /// 主动进入入口；在录音时始终返回原笔记。
  Future<void> enter() async {
    await checkRecovery();
    if (explicitCommit) {
      if (recorder.state.isActive && recorder.state.draftId != null) {
        await openLocalDraft(recorder.state.draftId!);
      } else {
        await openComposer();
      }
      return;
    }
    if (recorder.state.isActive && recorder.state.noteId != null) {
      if (draft.id != recorder.state.noteId) await open(recorder.state.noteId!);
      return;
    }
    await newNote();
  }

  /// 显式新建先结束并保存原音，再切换空白编辑器。
  Future<void> newNote() async {
    if (explicitCommit) {
      await openComposer();
      return;
    }
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
    if (committing || _cancelling || recordingStarting) return;
    if (id == draft.id) return;
    await flush();
    if (dirty) return;
    if (explicitCommit) {
      if (committing || _cancelling) return;
      // 恢复此卡片自己的本机编辑，不覆盖成同步正文。
      final NoteLocalDraftRecord? local = await localDrafts.forNote(id);
      if (committing || _cancelling) return;
      if (local != null) {
        _loadLocal(local);
        await _checkLocalSource();
        _notify();
        return;
      }
    }
    // 旧记录可能已在另一设备删除。
    final NoteEntryRecord? note = await repository.find(id);
    if (committing || _cancelling) return;
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
      recordTimeSeconds: note.recordTimeSeconds,
      recordUtcOffsetMinutes: note.recordUtcOffsetMinutes,
      baseRevision: note.revision,
      tags: noteTagIds(note.tags),
      createdAt: note.createdAt,
      creationTimezone: note.creationTimezone,
      originalTags: noteTagIds(note.tags),
    );
    dirty = false;
    conflicted = false;
    error = null;
    saveStatus = '已保存到本机';
    if (explicitCommit) {
      _draftId = const Uuid().v4();
      _isNewDraft = false;
      _localHasChanges = false;
      _pendingInsertions.clear();
      _pendingAudioDeletions.clear();
      _pendingImageDeletions.clear();
      frozen = false;
    }
    _generation++;
    _observeImages();
  }

  /// 清洁编辑器可接收转写或同步变化，不覆盖人工未保存输入。
  void acceptRemote(NoteEntryRecord? note) {
    if (explicitCommit && _persisted) {
      if (note == null || (note.id == draft.id && note.deletedAt != null)) {
        frozen = true;
        conflicted = true;
        error = '原笔记已删除，草稿已冻结，可另存为新笔记或取消';
        saveStatus = '草稿已保留，原笔记已删除';
        _notify();
        return;
      }
      if (note.id == draft.id && frozen) {
        frozen = false;
        conflicted = false;
        error = null;
        // 未发布修改会在下方提前返回，恢复后仍须立即刷新输入可编辑状态。
        _notify();
      }
    }
    if (dirty || conflicted || (explicitCommit && _localHasChanges)) {
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
        note.recordTime.seconds == draft.recordTime.seconds &&
        note.recordTime.utcOffsetMinutes == draft.recordTime.utcOffsetMinutes &&
        setEquals(noteTagIds(note.tags), draft.tags)) {
      return;
    }
    _load(note);
    _notify();
  }

  /// 输入、日期及标签变更共用自动保存或本机暂存。
  void edit({
    String? body,
    String? dayKey,
    Set<String>? tags,
    NoteRecordTime? recordTime,
  }) {
    if (committing || _cancelling || frozen) return;
    if (recordTime != null) {
      recordTime.validate();
      dayKey = recordTime.dayKey;
    }
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
      recordTimeSeconds: recordTime?.seconds ?? draft.recordTimeSeconds,
      recordUtcOffsetMinutes:
          recordTime?.utcOffsetMinutes ?? draft.recordUtcOffsetMinutes,
      baseRevision: draft.baseRevision,
      tags: tags ?? draft.tags,
      createdAt: createdAt,
      creationTimezone:
          draft.creationTimezone ??
          (createdAt == null ? null : noteCreationTimezone(createdAt)),
      originalTags: draft.originalTags,
      dateEdited: draft.dateEdited || dayKey != null,
    );
    dirty = true;
    if (explicitCommit) {
      _localHasChanges = true;
      _localNoteIds.add(draft.id);
    }
    _generation++;
    saveStatus = explicitCommit ? '正在暂存本机草稿' : '保存中';
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
    if (!dirty || (conflicted && !explicitCommit)) return;
    _saving = _save();
    await _saving;
    _saving = null;
  }

  /// 当前输入快照保存完成后只更新其对应版本身份。
  Future<void> _save() async {
    if (explicitCommit) {
      await _saveLocal();
      return;
    }
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
          recordTimeSeconds: draft.dateEdited
              ? draft.recordTimeSeconds
              : note.recordTimeSeconds,
          recordUtcOffsetMinutes: draft.dateEdited
              ? draft.recordUtcOffsetMinutes
              : note.recordUtcOffsetMinutes,
          baseRevision: note.revision,
          tags: continuedTags,
          createdAt: note.createdAt,
          creationTimezone: note.creationTimezone,
          originalTags: noteTagIds(note.tags),
          dateEdited:
              draft.dateEdited &&
              (draft.dayKey != note.dayKey ||
                  draft.recordTime.seconds != note.recordTime.seconds ||
                  draft.recordTime.utcOffsetMinutes !=
                      note.recordTime.utcOffsetMinutes),
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
    if (explicitCommit) {
      // 选择版本仍只是草稿变化，下一次保存才写正式版本。
      draft = NoteDraft(
        id: draft.id,
        body: draft.body,
        dayKey: draft.dayKey,
        recordTimeSeconds: draft.recordTimeSeconds,
        recordUtcOffsetMinutes: draft.recordUtcOffsetMinutes,
        baseRevision: current.revision,
        tags: draft.tags,
        originalTags: draft.originalTags,
        createdAt: draft.createdAt,
        creationTimezone: draft.creationTimezone,
        dateEdited: draft.dateEdited,
      );
      conflicted = false;
      error = null;
    } else {
      _load(current);
    }
    edit(body: body);
    await flush();
  }

  /// 录音启动绑定原笔记，允许历史浏览保持该归属。
  Future<void> startRecording() {
    if (_startingRecording != null) return _startingRecording!;
    _startingRecordingNoteId = draft.id;
    // 必须先固定在途任务，取消不能仅根据设备idle推断没有启动动作。
    final Future<void> starting = _startRecording();
    _startingRecording = starting;
    _notify();
    return starting.whenComplete(() {
      if (identical(_startingRecording, starting)) {
        _startingRecording = null;
        _startingRecordingNoteId = null;
      }
      _notify();
    });
  }

  /// 固定草稿身份后执行真正启动，阶段之间复查取消与提交门禁。
  Future<void> _startRecording() async {
    if (_recordingBlocked || _cancelling || frozen) return;
    if (recorder.state.isActive) throw StateError('已有录音进行中，请先结束当前录音');
    // 异步权限和数据库读取都必须返回到同一篇同一代草稿。
    final String startingNoteId = draft.id;
    // Android 代次为空，仍由笔记身份保护。
    final String? startingDraftId = _draftId;
    if (explicitCommit && !_isNewDraft) {
      await _checkLocalSource();
      if (frozen) return;
    }
    await flush();
    if (dirty ||
        _recordingBlocked ||
        _cancelling ||
        draft.id != startingNoteId ||
        _draftId != startingDraftId) {
      return;
    }
    if (explicitCommit) {
      // 恢复清单创建前，草稿归属必须已可靠落盘。
      _localHasChanges = true;
      dirty = true;
    }
    if (!_persisted && draft.createdAt == null) {
      // 开始实际采集时固定日期和创建时区。
      final DateTime now = DateTime.now();
      draft = NoteDraft(
        id: draft.id,
        body: draft.body,
        dayKey: _explicitDay ? draft.dayKey : businessDayKey(now),
        recordTimeSeconds: draft.recordTimeSeconds,
        recordUtcOffsetMinutes: draft.recordUtcOffsetMinutes,
        baseRevision: draft.baseRevision,
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
    final List<NoteDraftAudioSegmentRecord> staged = explicitCommit
        ? await localDrafts.audio(_draftId!)
        : const [];
    if (_recordingBlocked ||
        _cancelling ||
        draft.id != startingNoteId ||
        _draftId != startingDraftId) {
      return;
    }
    // 单篇剩余额度同时包含已发布及未发布的有效采样。
    final Duration remaining = Duration(
      milliseconds:
          3600000 -
          segments
              .where((item) => !isAudioRemoved(item.id))
              .fold<int>(0, (sum, item) => sum + item.durationMs) -
          staged
              .where((item) => !isAudioRemoved(item.id))
              .fold<int>(0, (sum, item) => sum + item.durationMs),
    );
    if (remaining <= Duration.zero) {
      error = '本篇录音已达 60 分钟，请新建笔记';
      _notify();
      return;
    }
    _recordingDraft = draft;
    _recordingDraftId = _draftId;
    _recordingConsent = voiceConsent;
    try {
      if (explicitCommit) {
        await flush();
        if (dirty ||
            _recordingBlocked ||
            _cancelling ||
            draft.id != startingNoteId ||
            _draftId != startingDraftId) {
          return;
        }
      }
      await recorder.start(
        draft.id,
        remaining: remaining,
        draftId: explicitCommit ? _draftId : null,
      );
    } catch (_) {
      if (!_persisted && draft.body.trim().isEmpty) {
        // 拒绝权限或设备启动失败尚无有效内容，不能提前固定创建时刻。
        draft = NoteDraft(
          id: draft.id,
          body: draft.body,
          dayKey: draft.dayKey,
          recordTimeSeconds: draft.recordTimeSeconds,
          recordUtcOffsetMinutes: draft.recordUtcOffsetMinutes,
          baseRevision: draft.baseRevision,
          tags: draft.tags,
          originalTags: draft.originalTags,
          dateEdited: draft.dateEdited,
        );
        _recordingDraft = null;
        if (explicitCommit) {
          dirty = true;
          _generation++;
          await flush();
        }
      }
      rethrow;
    }
  }

  /// 原音持久化成功才移除恢复清单。
  Future<void> _persistAudio(
    NoteRecordingResult result, {
    bool recovery = false,
  }) async {
    if (await recorder.isPermanentlyDiscarded('recording:${result.id}')) {
      await recorder.discardPendingForRecording(
        result.id,
        protectedPaths: await repository.protectedAudioPaths(),
      );
      return;
    }
    if (explicitCommit) {
      await _stageAudio(result, recovery: recovery);
      return;
    }
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
            recordTimeSeconds: stored.recordTimeSeconds,
            recordUtcOffsetMinutes: stored.recordUtcOffsetMinutes,
            baseRevision: stored.revision,
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
    if (explicitCommit) {
      for (final NoteRecordingResult item in recovered) {
        // 恢复也进入同一原音队列，单段取消必须等待所有在途写入。
        final Future<void> restore = _audioWrites.then(
          (_) => _stageAudio(item, recovery: true),
        );
        _audioWrites = restore.catchError((Object _) {});
        await restore;
        _audioWriteFailures.remove(item.id);
      }
      pendingRecoveryCount = 0;
      _notify();
      return;
    }
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
      _audioWriteFailures.remove(item.id);
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

  /// 删除准备只保护目标笔记，其他笔记正在启动的录音继续执行。
  bool get _recordingBlocked => _preparingDeletionIds == null
      ? committing
      : _preparingDeletionIds!.contains(draft.id);

  /// 回收前仅可靠暂存目标笔记的本机输入，不将草稿发布为正式正文。
  Future<void> prepareForDeletion(
    Set<String> noteIds, {
    Future<void> Function()? action,
  }) async {
    if (noteIds.isEmpty && action == null) return;
    if (committing || _cancelling) {
      throw StateError('笔记正在保存或取消，请稍后重试');
    }
    if (!explicitCommit) {
      throw StateError('批量回收前的草稿保护需要显式保存模式');
    }
    committing = true;
    _preparingDeletionIds = Set.unmodifiable(noteIds);
    _notify();
    try {
      if (noteIds.contains(_startingRecordingNoteId)) {
        await _startingRecording;
      }
      if (recorder.state.isActive && noteIds.contains(recorder.state.noteId)) {
        await recorder.stop(reason: '笔记将移入回收站，原音已保留在本机草稿');
      }
      // 完成事件同步入队；重复检查直到串行队列不再追加。
      // 本次等待的队列快照用于识别等待期间追加的任务。
      Future<void> pendingAudio;
      do {
        pendingAudio = _audioWrites;
        await pendingAudio;
      } while (!identical(pendingAudio, _audioWrites));
      if (noteIds.contains(_imageWritingNoteId)) await _imageWrites;
      if (noteIds.contains(draft.id)) {
        await flush();
        if (dirty) throw StateError(error ?? '正文尚未可靠暂存，删除已中止');
      }
      // 完成订阅会捕获错误以保留恢复能力，删除必须另行核实失败事实。
      for (final ({String noteId, String? draftId, Object failure}) failure
          in _audioWriteFailures.values) {
        if (noteIds.contains(failure.noteId)) {
          throw StateError('原音尚未可靠暂存，删除已中止：${failure.failure}');
        }
      }
      for (final String noteId in noteIds) {
        if (_imageWriteFailures.containsKey(noteId)) {
          throw StateError(
            '图片尚未可靠暂存，删除已中止：${_imageWriteFailures[noteId]!.failure}',
          );
        }
      }
      // 领域事务完成前继续保持门禁，目标录音与输入不能穿过准备后的空隙。
      if (action != null) await action();
    } finally {
      _preparingDeletionIds = null;
      committing = false;
      _notify();
    }
  }

  /// 正常退出先刷新正文再结束录音并排空持久化。
  Future<void> shutdown() async {
    await _imageWrites;
    try {
      await _startingRecording;
    } catch (_) {
      // 权限拒绝不应阻止已有文字可靠落盘和应用退出。
    }
    await flush();
    await recorder.stop(reason: '应用退出，已保存可用原音');
    await _audioWrites;
    if (dirty) throw StateError(error ?? '正文尚未保存，请重试或另存为新笔记');
  }

  /// 原记录删除或发生冲突时，显式另存当前正文和整理信息。
  Future<void> saveAsNew() async {
    if (explicitCommit) {
      await _commit(saveAsNew: true);
      return;
    }
    // 固定当前内容；旧记录、版本和原音仍按原生命周期管理。
    final NoteDraft previous = draft;
    final NoteEntryRecord saved = await repository.saveAsNew(previous);
    _load(saved);
    _notify();
  }

  /// 正文、日期、标签及附件是否仍有未正式提交的修改，暂存完成后仍保留此事实。
  bool get hasPendingChanges => explicitCommit ? _localHasChanges : dirty;

  /// 所有本机草稿都保护正文，不只保护当前可见的卡片。
  bool hasUncommittedDraft(String noteId) => explicitCommit
      ? !_localIndexReady ||
            _localNoteIds.contains(noteId) ||
            (draft.id == noteId && _localHasChanges)
      : draft.id == noteId && (dirty || conflicted);

  /// 显式创建独立语音草稿，先保护此前未发布的文字与附件。
  Future<bool> startFreshComposer() async {
    if (!explicitCommit ||
        committing ||
        _cancelling ||
        recordingStarting ||
        recorder.state.isActive) {
      return false;
    }
    await flush();
    if (dirty || committing || _cancelling || recordingStarting) return false;
    _blank();
    _notify();
    return true;
  }

  /// 外部相机启动前固定本机草稿，进程回收后仍能恢复原归属。
  Future<void> prepareMediaDraft() async {
    if (!explicitCommit || committing || _cancelling || frozen || conflicted) {
      throw StateError('当前草稿不可添加图片');
    }
    await flush();
    if (dirty) throw StateError(error ?? '草稿暂存失败');
    if (await localDrafts.find(_draftId!) == null) {
      await localDrafts.save(id: _draftId!, draft: draft, isNew: _isNewDraft);
    }
  }

  /// 停止并可靠暂存当前片段，不把设备空闲误认为附件已经完成落盘。
  Future<void> finishRecording({NoteRecordingResult? completed}) async {
    // 停止方法的返回与完成流均可提供可靠事实，不能只等待尚未交付的流。
    NoteRecordingResult? result = completed;
    if (recorder.state.isActive && recorder.state.draftId == _draftId) {
      result ??= await recorder.stop();
    }
    if (result != null) _queueAudio(result);
    await _audioWrites;
    if (_audioWriteFailures.values.any(
      (failure) => failure.draftId == _draftId,
    )) {
      throw StateError('原音尚未可靠暂存，请恢复原音后重试');
    }
    await flush();
    if (dirty) throw StateError(error ?? '草稿暂存失败');
  }

  /// 只丢弃本次片段，持久标记阻止迟到回调或重启恢复重新添加。
  Future<void> discardRecording(String recordingId) async {
    // 取消流程固定原草稿身份，不影响已有文字或其他原音。
    final String? owner = _draftId;
    // 已有共享引用始终受保护。
    final Set<String> protected = await repository.protectedAudioPaths();
    await recorder.discardPendingForRecording(
      recordingId,
      protectedPaths: protected,
    );
    if (recorder.state.isActive && recorder.state.recordingId == recordingId) {
      await recorder.stop();
    }
    await _audioWrites;
    await recorder.discardPendingForRecording(
      recordingId,
      protectedPaths: protected,
    );
    _audioWriteFailures.remove(recordingId);
    if (owner != _draftId) return;
    _pendingAudioDeletions.add(recordingId);
    _pendingInsertions.remove(recordingId);
    _localHasChanges = true;
    dirty = true;
    _generation++;
    await flush();
    if (dirty) throw StateError(error ?? '取消录音暂存失败');
  }

  /// 顶部输入框恢复上次的新建草稿，切换不会停止其他草稿的录音。
  Future<void> openComposer() async {
    if (!explicitCommit) {
      await newNote();
      return;
    }
    if (committing || _cancelling || recordingStarting) return;
    await flush();
    if (dirty) return;
    // 最近的新建草稿是固定顶部入口。
    final NoteLocalDraftRecord? local = await localDrafts.composer();
    if (committing || _cancelling) return;
    if (local != null) {
      _loadLocal(local);
    } else if (!_isNewDraft || _localHasChanges) {
      _blank();
    }
    _notify();
  }

  /// 草稿列表和录音提示可直接定位到独立草稿代次。
  Future<void> openLocalDraft(String id) async {
    if (!explicitCommit || committing || _cancelling || recordingStarting) {
      return;
    }
    await flush();
    if (dirty) return;
    // 不恢复已取消的一代。
    final NoteLocalDraftRecord? local = await localDrafts.find(id);
    if (committing || _cancelling) return;
    if (local == null || local.discarded) {
      error = '这份本机草稿已不可用';
    } else {
      _loadLocal(local);
      await _checkLocalSource();
    }
    _notify();
  }

  /// 展示可恢复草稿，不将其加入全部笔记或统计。
  Future<List<NoteLocalDraftRecord>> listLocalDrafts() => localDrafts.list();

  /// 恢复本机正文，不冒充已正式保存状态。
  void _loadLocal(NoteLocalDraftRecord local) {
    draft = noteDraftFromLocal(local);
    _draftId = local.id;
    _isNewDraft = local.isNew;
    _persisted = !local.isNew;
    _explicitDay = local.dateEdited;
    _localHasChanges = true;
    frozen = false;
    _localNoteIds.add(local.noteId);
    // 音频插入和删除共同恢复，旧本机草稿继续可读。
    final NoteDraftAudioEdits audioEdits = NoteDraftAudioEdits.fromJson(
      local.pendingInsertions,
    );
    _pendingInsertions
      ..clear()
      ..addAll(audioEdits.insertions);
    _pendingAudioDeletions
      ..clear()
      ..addAll(audioEdits.deletions);
    _pendingImageDeletions
      ..clear()
      ..addAll(audioEdits.imageDeletions);
    dirty = false;
    conflicted = false;
    error = null;
    saveStatus = '草稿已保留在本机';
    _generation++;
    _observeImages();
  }

  /// 自动保存只写本机表，超长输入也完整保留供用户修正。
  Future<void> _saveLocal() async {
    // 保存期间允许继续输入，较早的落盘结果不能清除较新的dirty。
    final int generation = _generation;
    // 本次写入固定草稿代次。
    final String id = _draftId!;
    try {
      await localDrafts.save(
        id: id,
        draft: draft,
        isNew: _isNewDraft,
        pendingInsertions: Map.of(_pendingInsertions),
        pendingAudioDeletions: Set.of(_pendingAudioDeletions),
        pendingImageDeletions: Set.of(_pendingImageDeletions),
      );
      if (generation == _generation && id == _draftId) {
        dirty = false;
        if (!conflicted) error = null;
        saveStatus = conflicted ? '草稿已保留，待解决冲突' : '草稿已保留在本机';
      }
    } catch (failure) {
      error = '$failure';
      saveStatus = '草稿暂存失败，请重试';
    }
    _notify();
  }

  /// 转写候选被使用的标记与正文一起显式提交。
  void markTranscriptInsertion(String segmentId, {bool candidate = true}) {
    if (!explicitCommit) return;
    _pendingInsertions[segmentId] = candidate;
    _localHasChanges = true;
    dirty = true;
    _generation++;
    _notify();
  }

  /// 删除仅进入当前本机草稿，切换／重启可恢复，取消可撤销。
  Future<void> removeAudio(String segmentId) async {
    if (!explicitCommit ||
        committing ||
        _cancelling ||
        frozen ||
        conflicted ||
        recordingStarting) {
      return;
    }
    // 所属身份先固定，异步查询不能越过用户切换卡片。
    final String? id = _draftId;
    final String noteId = draft.id;
    // 正式片段与新增片段都必须属于正在编辑的笔记或草稿。
    final NoteAudioSegmentRecord? existing =
        await (repository.database.select(repository.database.noteAudioSegments)
              ..where(
                (table) =>
                    table.id.equals(segmentId) &
                    table.noteId.equals(noteId) &
                    table.deletedAt.isNull(),
              ))
            .getSingleOrNull();
    final NoteDraftAudioSegmentRecord? staged =
        await (repository.database.select(
              repository.database.noteDraftAudioSegments,
            )..where(
              (table) =>
                  table.id.equals(segmentId) & table.draftId.equals(id ?? ''),
            ))
            .getSingleOrNull();
    if (id != _draftId ||
        noteId != draft.id ||
        committing ||
        _cancelling ||
        frozen ||
        conflicted) {
      return;
    }
    if (existing == null && staged == null) return;
    _pendingAudioDeletions.add(segmentId);
    _pendingInsertions.remove(segmentId);
    _localHasChanges = true;
    _localNoteIds.add(noteId);
    dirty = true;
    _generation++;
    _notify();
    await flush();
  }

  /// 发布新篇或保存当前历史卡，录音和正文在同一事务进入正式笔记。
  Future<NoteCommitResult> commit() => _commit();

  /// 显式另存与普通提交共享失败保留和原音提升机制。
  Future<NoteCommitResult> _commit({bool saveAsNew = false}) async {
    if (!explicitCommit) {
      await flush();
      return dirty ? NoteCommitResult.failed : NoteCommitResult.committed;
    }
    if (committing || _cancelling) return NoteCommitResult.failed;
    committing = true;
    _notify();
    // 提交仅作用于用户点击的这一代，另一篇录音保持活动。
    final String id = _draftId!;
    // 异步保存期间不允许把另一个当前笔记误绑定到提交结果。
    final String noteId = draft.id;
    try {
      await _startingRecording;
      if (recorder.state.isActive && recorder.state.draftId == id) {
        await recorder.stop();
      }
      // 用户可能已手动结束录音，设备idle不代表原音暂存队列已排空。
      await _audioWrites;
      await _imageWrites;
      await flush();
      if (dirty) return NoteCommitResult.failed;
      // 失败原音仍归属这一代恢复清单，不能通过提交墓碑使它被当作取消丢弃。
      if (_audioWriteFailures.values.any((failure) => failure.draftId == id)) {
        throw StateError('原音尚未可靠暂存，请先恢复原音后重试保存');
      }
      if (!_localHasChanges) return NoteCommitResult.empty;
      // 正式提交期间的继续输入不能被较早结果清空。
      final int generation = _generation;
      // 全部本机资产通过一个事务提升。
      final NoteEntryRecord? saved = await localDrafts.commit(
        id,
        saveAsNew: saveAsNew,
      );
      if (saved == null) return NoteCommitResult.empty;
      // 成功提交明确结束这一代编辑，旧选图失败不能阻止后续代次删除正式笔记。
      if (_imageWriteFailures[noteId]?.draftId == id) {
        _imageWriteFailures.remove(noteId);
      }
      _localNoteIds.remove(noteId);
      if (_draftId != id || draft.id != noteId) {
        return NoteCommitResult.committed;
      }
      if (_generation == generation) {
        if (_isNewDraft || saveAsNew) {
          _blank();
        } else {
          _load(saved);
        }
      } else {
        // 用户在提交期间继续输入，承接刚刚提交的版本作为下一份本机修改。
        draft = NoteDraft(
          id: saved.id,
          body: draft.body,
          dayKey: draft.dayKey,
          recordTimeSeconds: draft.recordTimeSeconds,
          recordUtcOffsetMinutes: draft.recordUtcOffsetMinutes,
          baseRevision: saved.revision,
          tags: draft.tags,
          originalTags: noteTagIds(saved.tags),
          createdAt: saved.createdAt,
          creationTimezone: saved.creationTimezone,
          dateEdited: draft.dateEdited,
        );
        _draftId = const Uuid().v4();
        _isNewDraft = false;
        _persisted = true;
        _localHasChanges = true;
        dirty = true;
        await flush();
      }
      error = null;
      conflicted = false;
      return NoteCommitResult.committed;
    } on NoteLocalDraftConflict catch (failure) {
      conflicted = true;
      error = failure.message;
      saveStatus = '草稿已保留，待解决冲突';
      return NoteCommitResult.conflict;
    } catch (failure) {
      error = '$failure';
      saveStatus = '提交失败，草稿仍在本机';
      return NoteCommitResult.failed;
    } finally {
      committing = false;
      _notify();
    }
  }

  /// 取消只丢弃当前草稿及它新增的原音，不改正式正文和既有原音。
  Future<void> cancel() async {
    if (!explicitCommit || committing || _cancelling) return;
    _cancelling = true;
    // 取消时固定这一代身份。
    final String id = _draftId!;
    // 原正式记录用于取消后恢复。
    final String noteId = draft.id;
    // 新建草稿取消后仍停留顶部空白输入。
    final bool wasNew = _isNewDraft;
    try {
      try {
        await _startingRecording;
      } catch (_) {
        // 拒绝麦克风权限后仍按用户请求取消本机草稿。
      }
      _debounce?.cancel();
      _deadline?.cancel();
      _deadline = null;
      if (_saving != null) await _saving;
      // 空白但正在启动录音的草稿也需先有持久丢弃事实。
      if (await localDrafts.find(id) == null) {
        await localDrafts.save(id: id, draft: draft, isNew: wasNew);
      }
      await localDrafts.discard(id);
      dirty = false;
      if (recorder.state.isActive && recorder.state.draftId == id) {
        await recorder.stop();
      }
      await _audioWrites;
      await _imageWrites;
      // 全部有效共享引用都受保护，取消不能删除另存使用的原件。
      final Set<String> protectedPaths = await repository.protectedAudioPaths();
      await recorder.discardPendingForDraft(id, protectedPaths: protectedPaths);
      await repository.purgeOrphanFiles();
      _audioWriteFailures.removeWhere((_, failure) => failure.draftId == id);
      if (_imageWriteFailures[noteId]?.draftId == id) {
        _imageWriteFailures.remove(noteId);
      }
      _localNoteIds.remove(noteId);
      // 正式笔记可能刚被远端删除，取消不恢复它。
      final NoteEntryRecord? current = wasNew
          ? null
          : await repository.find(noteId);
      if (current != null && current.deletedAt == null) {
        _load(current);
      } else {
        _blank();
      }
    } catch (failure) {
      error = '$failure';
      saveStatus = '取消清理待重试';
    } finally {
      _cancelling = false;
      _notify();
    }
  }

  /// 显式提交平台结束录音仅暂存，旧清单恢复也不会自动发布。
  Future<void> _stageAudio(
    NoteRecordingResult result, {
    bool recovery = false,
  }) async {
    // 恢复快照可能早于取消标记，落库前仍校验片段身份。
    if (await recorder.isPermanentlyDiscarded('recording:${result.id}')) {
      await recorder.discardPendingForRecording(
        result.id,
        protectedPaths: await repository.protectedAudioPaths(),
      );
      return;
    }
    // 已提升的片段只需确认旧清单，不能生成第二份草稿。
    final NoteAudioSegmentRecord? published = await (repository.database.select(
      repository.database.noteAudioSegments,
    )..where((table) => table.id.equals(result.id))).getSingleOrNull();
    if (published != null) {
      await recorder.acknowledge(result.id);
      return;
    }
    if (await recorder.isPermanentlyDiscarded(result.noteId)) {
      await recorder.discardPendingForNote(
        result.noteId,
        protectedPaths: await repository.protectedAudioPaths(),
      );
      return;
    }
    // 当前录音原始代次优先，恢复不会误挂到同篇的新一代编辑。
    String? id =
        result.draftId ??
        (!recovery && _recordingDraft?.id == result.noteId
            ? _recordingDraftId
            : null);
    // 持久草稿是归属事实；尚未升级的旧清单可恢复为新的本机草稿。
    NoteLocalDraftRecord? local = id == null
        ? null
        : await localDrafts.find(id);
    if (local?.discarded == true) {
      await recorder.discardPendingForDraft(
        id!,
        protectedPaths: await repository.protectedAudioPaths(),
      );
      return;
    }
    if (local == null) {
      // 原正式笔记仍可用时保留编辑归属，否则恢复成独立新草稿。
      final NoteEntryRecord? original = await repository.find(result.noteId);
      // 旧录音没有草稿代次时优先合入同篇已有本机草稿。
      local = id == null ? await localDrafts.forNote(result.noteId) : null;
      if (local == null) {
        id ??= const Uuid().v4();
        // 按真实录音开始时间恢复，不能使用恢复当天。
        final NoteDraft recovered =
            original != null && original.deletedAt == null
            ? NoteDraft(
                id: original.id,
                body: original.body,
                dayKey: original.dayKey,
                recordTimeSeconds: original.recordTimeSeconds,
                recordUtcOffsetMinutes: original.recordUtcOffsetMinutes,
                baseRevision: original.revision,
                tags: noteTagIds(original.tags),
                originalTags: noteTagIds(original.tags),
                createdAt: original.createdAt,
                creationTimezone: original.creationTimezone,
              )
            : NoteDraft(
                id: original == null ? result.noteId : const Uuid().v4(),
                body: '',
                dayKey: noteRecordingDayKey(
                  result.startedAt,
                  result.creationTimezone,
                ),
                baseRevision: '',
                createdAt: result.startedAt,
                creationTimezone: result.creationTimezone,
              );
        await localDrafts.save(
          id: id,
          draft: recovered,
          isNew: original == null || original.deletedAt != null,
        );
        local = await localDrafts.find(id);
      }
    }
    id = local!.id;
    // 被恢复为新篇时仅改变本机归属，原件身份保持不变。
    final NoteRecordingResult staged = NoteRecordingResult(
      id: result.id,
      noteId: local.noteId,
      draftId: id,
      path: result.path,
      duration: result.duration,
      startedAt: result.startedAt,
      creationTimezone: result.creationTimezone,
      mimeType: result.mimeType,
      interruptionReason: result.interruptionReason,
    );
    final bool stagedSuccessfully = await localDrafts.stageAudio(
      staged,
      draftId: id,
      consent: !recovery && _recordingDraftId == id && _recordingConsent,
    );
    if (!stagedSuccessfully) {
      // 取消与暂存竞争时按取消事实清理；其他失败必须保留恢复清单。
      final NoteLocalDraftRecord? latest = await localDrafts.find(id);
      if (latest?.discarded == true) {
        await recorder.discardPendingForDraft(
          id,
          protectedPaths: await repository.protectedAudioPaths(),
        );
        return;
      }
      throw StateError('录音尚未可靠暂存，原音已保留等待恢复');
    }
    await recorder.acknowledge(result.id);
    _localNoteIds.add(local.noteId);
    if (_draftId == id) {
      _localHasChanges = true;
      saveStatus = '草稿及原音已保留在本机';
    }
    if (pendingRecoveryCount > 0) pendingRecoveryCount--;
    if (result.interruptionReason != null) error = result.interruptionReason;
    _notify();
  }

  /// 重开本机草稿时核实原篇是否仍可编辑，恢复原篇后解除冻结。
  Future<void> _checkLocalSource() async {
    if (!explicitCommit || _isNewDraft) return;
    // 保存检查开始时的归属，异步结果不能冻结后来打开的另一篇。
    final String noteId = draft.id;
    // 含软删除记录，缺行视为永久删除。
    final NoteEntryRecord? current = await repository.find(noteId);
    if (draft.id != noteId) return;
    frozen = current == null || current.deletedAt != null;
    if (frozen) {
      conflicted = true;
      error = '原笔记已删除，草稿已冻结，可另存为新笔记或取消';
      saveStatus = '草稿已保留，原笔记已删除';
      _notify();
    }
  }

  /// 释放页面通知和计时器；未确认原音仍保留恢复清单。
  @override
  void dispose() {
    _closed = true;
    _debounce?.cancel();
    _deadline?.cancel();
    unawaited(_completed.cancel());
    unawaited(_localSubscription?.cancel());
    unawaited(_imageSubscription?.cancel());
    super.dispose();
  }
}
