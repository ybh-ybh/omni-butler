import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omni_butler/features/notes/data/note_image_acquisition.dart';
import 'package:omni_butler/core/attachments/image_sync_store.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/audio/note_wav.dart';
import 'package:omni_butler/features/notes/data/note_editor_controller.dart';
import 'package:omni_butler/features/notes/data/note_local_draft_repository.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/features/notes/data/note_image_repository.dart';

/// 只交付测试私有目录中的真实 WAV，不启动麦克风。
class _DraftRecorder implements NoteRecorderService {
  /// 可控完成事件使用同步通知，退出可精确排空。
  final StreamController<NoteRecordingResult> events =
      StreamController.broadcast(sync: true);

  /// 当前设备状态。
  @override
  NoteRecordingState state = const NoteRecordingState();

  /// 停止时交付的已生成原音。
  NoteRecordingResult? nextResult;

  /// 模拟崩溃后遗留的恢复清单。
  List<NoteRecordingResult> pending = [];

  /// 已可靠写入本机表的原音身份。
  final Set<String> acknowledged = {};

  /// 已取消的草稿代次。
  final Set<String> discardedDrafts = {};

  /// 停止次数用于防止切换卡片意外结束其他录音。
  int stops = 0;

  /// 本次开始时传入的实际剩余额度。
  Duration? remaining;

  /// 模拟系统权限界面尚未返回且设备仍显示idle。
  Completer<void>? startGate;

  /// 可等待已经进入实际启动协议。
  final Completer<void> startRequested = Completer();

  /// 应用控制器的唯一完成订阅。
  @override
  Stream<NoteRecordingResult> get completed => events.stream;

  /// 不分配任何真实设备。
  @override
  Future<void> start(
    String noteId, {
    Duration remaining = NoteRecorderService.noteLimit,
    String? draftId,
  }) async {
    this.remaining = remaining;
    if (!startRequested.isCompleted) startRequested.complete();
    await startGate?.future;
    state = NoteRecordingState(
      phase: NoteRecordingPhase.recording,
      noteId: noteId,
      draftId: draftId,
    );
  }

  /// 结束后发送一次固定原音结果。
  @override
  Future<NoteRecordingResult?> stop({String? reason}) async {
    stops++;
    state = const NoteRecordingState();
    // 同一次采样只交付一次。
    final NoteRecordingResult? result = nextResult;
    nextResult = null;
    if (result != null) events.add(result);
    return result;
  }

  /// 测试清单只包含显式准备的原音。
  @override
  Future<List<NoteRecordingResult>> recoverPending() async => pending;

  /// 测试不依赖真实永久删除标记。
  @override
  Future<bool> isPermanentlyDiscarded(String noteId) async =>
      discardedRecordings.contains(noteId);

  /// 单段取消的持久事实独立于整篇草稿。
  final Set<String> discardedRecordings = {};

  /// 丢弃当前片段不影响此前原音。
  @override
  Future<void> discardPendingForRecording(
    String id, {
    Set<String> protectedPaths = const {},
  }) async {
    discardedRecordings.add('recording:$id');
  }

  /// 记录可靠暂存确认。
  @override
  Future<void> acknowledge(String id) async {
    acknowledged.add(id);
  }

  /// 取消不能触碰其他草稿或整篇录音生命周期。
  @override
  Future<void> discardPendingForDraft(
    String draftId, {
    Set<String> protectedPaths = const {},
  }) async {
    discardedDrafts.add(draftId);
  }

  /// 非测试协议不能触发真实原生调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 明确控制原音暂存和提交的完成时点以复现交互竞态。
class _DelayedDrafts extends NoteLocalDraftRepository {
  /// 绑定真实 SQLite 仓储。
  _DelayedDrafts(super.notes);

  /// 进入原音暂存后的可观察事件。
  final Completer<void> stageStarted = Completer();

  /// 测试按需阻塞原音落盘。
  Completer<void>? stageGate;

  /// 暂存队列捕获失败后，删除准备仍须感知这份失败。
  bool stageFails = false;

  /// 进入提交后的可观察事件。
  final Completer<void> commitStarted = Completer();

  /// 测试按需阻塞正式事务。
  Completer<void>? commitGate;

  /// 设备已经idle时，本机原音仍可能处于可靠暂存之前。
  @override
  Future<bool> stageAudio(
    NoteRecordingResult result, {
    required String draftId,
    required bool consent,
  }) async {
    if (!stageStarted.isCompleted) stageStarted.complete();
    await stageGate?.future;
    if (stageFails) throw StateError('模拟原音暂存失败');
    return super.stageAudio(result, draftId: draftId, consent: consent);
  }

  /// 控制器必须在提交结束前拒绝切换当前草稿身份。
  @override
  Future<NoteEntryRecord?> commit(String id, {bool saveAsNew = false}) async {
    if (!commitStarted.isCompleted) commitStarted.complete();
    await commitGate?.future;
    return super.commit(id, saveAsNew: saveAsNew);
  }
}

/// 在清理取得引用快照后停住，验证新增草稿写入无法穿过同一事务。
class _PausedCleanup extends NoteRepository {
  /// 使用测试自己的数据库。
  _PausedCleanup(super.database);

  /// 引用读取已经开始。
  final Completer<void> snapshotTaken = Completer();

  /// 允许清理继续。
  final Completer<void> continueCleanup = Completer();

  /// 暂停期间其他数据库写入必须等待本次清理事务。
  @override
  Future<Set<String>> protectedAudioPaths() async {
    // 当前完整引用快照。
    final Set<String> paths = await super.protectedAudioPaths();
    snapshotTaken.complete();
    await continueCleanup.future;
    return paths;
  }
}

/// 验证真实 SQLite 事务、文件生命周期与显式发布边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 每例使用隔离数据库。
  late AppDatabase database;
  // 真实正式笔记仓储。
  late NoteRepository repository;
  // 唯一受控录音器。
  late _DraftRecorder recorder;
  // Windows 显式编辑会话。
  late NoteEditorController editor;
  // 每例拥有自己的原音目录。
  late Directory directory;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = NoteRepository(database);
    recorder = _DraftRecorder();
    directory = await Directory.systemTemp.createTemp('note-local-draft-');
    editor = NoteEditorController(
      repository,
      recorder,
      explicitCommit: true,
      imageRepository: NoteImageRepository(
        database,
        directoryProvider: () async => directory,
      ),
    );
  });
  tearDown(() async {
    editor.dispose();
    await recorder.events.close();
    await database.close();
    await directory.delete(recursive: true);
  });

  /// 在当前草稿下生成一秒可验证 PCM 原音。
  Future<NoteRecordingResult> recording({
    String id = 'audio',
    int milliseconds = 1000,
  }) async {
    // 实际采样字节数与时长一致。
    final int bytes = NoteWav.bytesPerSecond * milliseconds ~/ 1000;
    // 仅写本次测试目录。
    final File file = File('${directory.path}/$id.wav');
    await file.writeAsBytes([
      ...NoteWav.header(bytes),
      ...List.filled(bytes, 0),
    ]);
    return NoteRecordingResult(
      id: id,
      noteId: editor.draft.id,
      draftId: editor.draftId,
      path: file.path,
      duration: Duration(milliseconds: milliseconds),
      startedAt: DateTime.now(),
    );
  }

  /// 墓碑保留阻止迟到恢复的身份，不保留取消的用户内容。
  void expectEmptyTombstone(NoteLocalDraftRecord tombstone) {
    expect(tombstone.discarded, isTrue);
    expect(tombstone.body, isEmpty);
    expect(tombstone.dayKey, isEmpty);
    expect(tombstone.baseRevision, isEmpty);
    expect(tombstone.tags, '[]');
    expect(tombstone.originalTags, isNull);
    expect(tombstone.pendingInsertions, '{}');
    expect(tombstone.createdAt, isNull);
    expect(tombstone.creationTimezone, isNull);
    expect(tombstone.dateEdited, isFalse);
    expect(tombstone.isNew, isFalse);
  }

  /// 已发布原音供删除、取消与另存回归共用。
  Future<NoteEntryRecord> publishedAudio() async {
    editor.edit(body: '原始正文');
    await editor.commit();
    // 固定正式身份，不触碰任何用户数据。
    final NoteEntryRecord note =
        (await database.select(database.noteEntries).get()).single;
    await editor.open(note.id);
    // 两个片段验证删除不会越过指定身份。
    for (final String id in ['delete-audio', 'keep-audio']) {
      final NoteRecordingResult result = await recording(id: id);
      await repository.addAudio(
        draft: editor.draft,
        id: id,
        localPath: result.path,
        durationMs: 1000,
        mime: result.mimeType,
      );
    }
    await editor.open(note.id);
    return note;
  }

  /// 选择器返回的真实小图，不访问用户图片。
  Future<String> imageFile(String name) async {
    final File file = File('${directory.path}/$name.png');
    await file.writeAsBytes(img.encodePng(img.Image(width: 3, height: 2)));
    return file.path;
  }

  test('独立语音草稿先保存原文字，失败不切换身份', () async {
    editor.edit(body: '继续保留的文字');
    // 原本机草稿身份用于恢复，不进入正式笔记。
    final String previous = editor.draftId!;
    expect(await editor.startFreshComposer(), isTrue);
    expect((await editor.localDrafts.find(previous))!.body, '继续保留的文字');
    expect(editor.draftId, isNot(previous));
    expect(editor.draft.body, isEmpty);
    expect(await repository.watchAll().first, isEmpty);
    editor.edit(body: '暂存失败不丢');
    // 数据库真实失败验证新建前的门禁。
    final String failedOwner = editor.draftId!;
    await database.customStatement(
      "CREATE TRIGGER fail_fresh_draft BEFORE INSERT ON note_local_drafts BEGIN SELECT RAISE(ABORT, 'no write'); END",
    );
    expect(await editor.startFreshComposer(), isFalse);
    expect(editor.draftId, failedOwner);
    expect(editor.draft.body, '暂存失败不丢');
    await database.customStatement('DROP TRIGGER fail_fresh_draft');
  });

  test('单段取消排空原音队列且迟到回调不复活，已有片段与正文保留', () async {
    editor.edit(body: '已有正文');
    await editor.flush();
    // 已有片段必须保持有效。
    final NoteRecordingResult kept = await recording(id: 'kept');
    recorder.events.add(kept);
    await editor.finishRecording();
    // 停止后再取消也必须立即归还配额，保留的原件只等待既有孤儿清理。
    final NoteRecordingResult reviewed = await recording(id: 'reviewed-cancel');
    recorder.events.add(reviewed);
    await editor.finishRecording();
    await editor.discardRecording(reviewed.id);
    await editor.startRecording();
    expect(recorder.remaining, const Duration(seconds: 3599));
    await editor.finishRecording();
    // 本次片段在停止时完成，取消标记必须先于完成事件落地。
    final NoteRecordingResult removed = await recording(id: 'removed');
    recorder.nextResult = removed;
    recorder.state = NoteRecordingState(
      phase: NoteRecordingPhase.recording,
      noteId: editor.draft.id,
      draftId: editor.draftId,
      recordingId: removed.id,
    );
    await editor.discardRecording(removed.id);
    recorder.events.add(removed);
    await editor.finishRecording();
    expect(
      (await editor.localDrafts.audio(editor.draftId!))
          .where((item) => !editor.isAudioRemoved(item.id))
          .map((item) => item.id),
      ['kept'],
    );
    expect(editor.draft.body, '已有正文');
    expect(await editor.commit(), NoteCommitResult.committed);
    expect(
      (await database.select(database.noteAudioSegments).get()).single.id,
      kept.id,
    );
  });

  /// 生成相机或相册交付的真实图片，导入仍经过尺寸、哈希和私有复制。
  Future<File> pickedImage() async {
    // 测试目录中的原始图片，不操作真实用户文件。
    final File file = File('${directory.path}/picked.png');
    await file.writeAsBytes(img.encodePng(img.Image(width: 8, height: 8)));
    return file;
  }

  /// 创建原本机请求清单，模拟系统回收进程之前已经完成的归属暂存。
  Future<SharedPreferences> pendingImage({
    required String source,
    List<String> paths = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    // 同一个设备存储在服务重建后保持可读。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await editor.prepareMediaDraft();
    await preferences.setString(
      'notes.media.pending',
      '{"source":"$source","draftId":"${editor.draftId}","noteId":"${editor.draft.id}","requestId":"stable-request","paths":${jsonEncode(paths)}}',
    );
    return preferences;
  }

  test('系统相机成功只导入原草稿，取消相册不发布', () async {
    SharedPreferences.setMockInitialValues({});
    // 隔离系统选择器和本机偏好。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 相机与相册交付由测试系统边界决定。
    final _AcquisitionPicker picker = _AcquisitionPicker([
      XFile((await pickedImage()).path),
    ]);
    // 生产导入服务继续使用真实编辑器和仓储。
    final NoteImageAcquisition service = NoteImageAcquisition(
      editor: editor,
      sourceKey: 'source',
      preferences: preferences,
      picker: picker,
    );
    addTearDown(service.dispose);
    editor.edit(body: '相机之前的正文');
    expect(await service.acquire(camera: true), isTrue);
    expect(picker.camera, isTrue);
    expect(editor.draft.body, '相机之前的正文');
    expect(await editor.images.staged(editor.draftId!), hasLength(1));
    picker.files = [];
    expect(await service.acquire(camera: false), isFalse);
    expect(await repository.watchAll().first, isEmpty);
    expect(preferences.containsKey('notes.media.pending'), isFalse);
  });

  test('进程回收恢复与重复交付按请求去重，保留首份私有原件', () async {
    // 系统丢失结果交付的原件。
    final File file = await pickedImage();
    // 原请求没有结果，等冷启动取回。
    final SharedPreferences preferences = await pendingImage(source: 'source');
    // 只第一次恢复返回系统结果。
    final _AcquisitionPicker picker = _AcquisitionPicker([])
      ..lost = [XFile(file.path)];
    // 两次服务实例模拟进程边界。
    final NoteImageAcquisition service = NoteImageAcquisition(
      editor: editor,
      sourceKey: 'source',
      preferences: preferences,
      picker: picker,
    );
    expect(await service.recover(), isTrue);
    // 模拟数据库已经写入、请求清单尚未删除时进程退出。
    final SharedPreferences replay = await pendingImage(
      source: 'source',
      paths: [file.path],
    );
    // 首份私有文件不能被第二次导入覆盖或删除。
    final String saved = (await editor.images.staged(editor.draftId!))
        .single
        .localPath!;
    service.dispose();
    // 重启服务复用同一请求的稳定附件身份。
    final NoteImageAcquisition restarted = NoteImageAcquisition(
      editor: editor,
      sourceKey: 'source',
      preferences: replay,
      picker: _AcquisitionPicker([]),
    );
    addTearDown(restarted.dispose);
    expect(await restarted.recover(), isTrue);
    expect(await editor.images.staged(editor.draftId!), hasLength(1));
    expect(await File(saved).exists(), isTrue);
  });

  test('已取消草稿不接收系统迟到图片，数据源不符时保留原请求', () async {
    // 同一外部结果只能导回原数据源。
    final File file = await pickedImage();
    // 本机清单明确属于源A。
    final SharedPreferences preferences = await pendingImage(
      source: 'A',
      paths: [file.path],
    );
    // 源B不能根据当前编辑器猜测归属。
    final NoteImageAcquisition other = NoteImageAcquisition(
      editor: editor,
      sourceKey: 'B',
      preferences: preferences,
      picker: _AcquisitionPicker([]),
    );
    expect(await other.recover(), isFalse);
    expect(preferences.containsKey('notes.media.pending'), isTrue);
    expect(await editor.images.staged(editor.draftId!), isEmpty);
    other.dispose();
    await editor.localDrafts.discard(editor.draftId!);
    // 返回源A后仍需尊重原草稿取消墓碑。
    final NoteImageAcquisition original = NoteImageAcquisition(
      editor: editor,
      sourceKey: 'A',
      preferences: preferences,
      picker: _AcquisitionPicker([]),
    );
    addTearDown(original.dispose);
    expect(await original.recover(), isFalse);
    expect(await editor.images.staged(editor.draftId!), isEmpty);
    expect(preferences.containsKey('notes.media.pending'), isFalse);
  });

  test('图片导入失败保留请求，修复原件后可重试且不重复', () async {
    SharedPreferences.setMockInitialValues({});
    // 无效系统返回文件模拟解码失败。
    final File file = File('${directory.path}/retry.png')
      ..writeAsBytesSync([1, 2, 3]);
    // 当前设备偏好不会写入真实用户存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 生产服务负责保留失败清单。
    final NoteImageAcquisition service = NoteImageAcquisition(
      editor: editor,
      sourceKey: 'source',
      preferences: preferences,
      picker: _AcquisitionPicker([XFile(file.path)]),
    );
    addTearDown(service.dispose);
    await expectLater(service.acquire(camera: false), throwsA(anything));
    expect(preferences.containsKey('notes.media.pending'), isTrue);
    await file.writeAsBytes(img.encodePng(img.Image(width: 8, height: 8)));
    expect(await service.recover(), isTrue);
    expect(await editor.images.staged(editor.draftId!), hasLength(1));
  });

  test('多图先存本机草稿，纯图片发布原子创建两图及MinIO待传操作', () async {
    final String noteId = editor.draft.id;
    final String draftId = editor.draftId!;
    await editor.addImages([
      await imageFile('first'),
      await imageFile('second'),
    ]);
    expect(await database.select(database.noteEntries).get(), isEmpty);
    expect(await database.select(database.noteImages).get(), isEmpty);
    expect(await database.select(database.attachments).get(), isEmpty);
    expect(await editor.images.staged(draftId), hasLength(2));
    expect(
      await database
          .customSelect(
            "SELECT * FROM image_sync_metadata WHERE id LIKE 'intent:%'",
          )
          .get(),
      isEmpty,
    );
    expect(await editor.commit(), NoteCommitResult.committed);
    final NoteEntryRecord note = (await repository.find(noteId))!;
    expect(note.body, isEmpty);
    final List<NoteImageRecord> pictures = await editor.images.published(
      noteId,
    );
    expect(pictures, hasLength(2));
    expect(pictures.map((item) => item.sortOrder), [0, 1]);
    for (final NoteImageRecord picture in pictures) {
      expect(
        await ImageSyncStore(database).read('intent:noteImage:${picture.id}'),
        isNotNull,
      );
    }
    expect(await database.select(database.noteDraftImages).get(), isEmpty);
  });

  test('只改图片保留正文版本，取消撤销删除，保存差量保留并发新增图', () async {
    final String noteId = editor.draft.id;
    await editor.addImages([await imageFile('base')]);
    await editor.commit();
    final NoteEntryRecord original = (await repository.find(noteId))!;
    await editor.open(noteId);
    final String firstId = (await editor.images.published(noteId)).single.id;
    await editor.images.watch(noteId, draftId: editor.draftId).first;
    await Future<void>.delayed(Duration.zero);
    await editor.removeImage(firstId);
    await editor.cancel();
    expect(await editor.images.published(noteId), hasLength(1));
    await editor.addImages([await imageFile('added')]);
    await Future<void>.delayed(Duration.zero);
    await editor.removeImage(firstId);
    final DateTime now = DateTime.now();
    await database
        .into(database.noteImages)
        .insert(
          NoteImagesCompanion.insert(
            id: 'peer-image',
            noteId: noteId,
            sortOrder: 1,
            createdAt: now,
            updatedAt: now,
          ),
        );
    expect(await editor.commit(), NoteCommitResult.committed);
    final List<NoteImageRecord> pictures = await editor.images.published(
      noteId,
    );
    expect(pictures, hasLength(2));
    expect(pictures.any((item) => item.id == 'peer-image'), isTrue);
    expect(pictures.any((item) => item.id == firstId), isFalse);
    expect((await repository.find(noteId))!.revision, original.revision);
  });

  test('版本选择只改正文，Android式保存与另存保留图片且原篇删除不损坏副本', () async {
    final String noteId = editor.draft.id;
    editor.edit(body: '初始正文');
    await editor.addImages([await imageFile('shared')]);
    await editor.commit();
    await editor.open(noteId);
    await editor.useVersion('选中的正文版本');
    await editor.commit();
    final NoteEntryRecord note = (await repository.find(noteId))!;
    await repository.save(
      NoteDraft(
        id: noteId,
        body: 'Android 修改',
        dayKey: note.dayKey,
        baseRevision: note.revision,
      ),
    );
    expect(await editor.images.published(noteId), hasLength(1));
    final NoteEntryRecord copy = await repository.saveAsNew(
      NoteDraft(
        id: noteId,
        body: '副本',
        dayKey: note.dayKey,
        baseRevision: note.revision,
      ),
    );
    final NoteImageRecord copied = (await editor.images.published(copy.id))
        .single;
    final Attachment cache = (await editor.images.attachment(copied.id))!;
    expect(copied.id, isNot((await editor.images.published(noteId)).single.id));
    await repository.permanentlyDelete(noteId);
    await repository.purgeOrphanFiles();
    expect(await File(cache.localPath!).exists(), isTrue);
    expect(await editor.images.published(copy.id), hasLength(1));
  });

  test('缺图提交保留草稿，取消墓碑阻止迟到选图复活', () async {
    final String noteId = editor.draft.id;
    final String draftId = editor.draftId!;
    final String source = await imageFile('missing');
    await editor.addImages([source]);
    final NoteDraftImageRecord staged = (await editor.images.staged(draftId))
        .single;
    await File(staged.localPath!).delete();
    expect(await editor.commit(), NoteCommitResult.failed);
    expect(await repository.find(noteId), isNull);
    expect(await editor.images.staged(draftId), hasLength(1));
    await editor.cancel();
    expect(await editor.images.stage(draftId, noteId, source), isFalse);
    expect(await editor.images.staged(draftId), isEmpty);
  });

  test('删除原音仅存草稿，重启恢复删除标记，取消恢复正文与原件', () async {
    // 正式音频、共享原件和本机草稿分别验证。
    final NoteEntryRecord note = await publishedAudio();
    editor.edit(body: '未保存的正文');
    await editor.removeAudio('delete-audio');
    expect(
      (await database.select(database.noteAudioSegments).get()),
      hasLength(2),
    );
    expect(await File('${directory.path}/delete-audio.wav').exists(), isTrue);
    editor.dispose();
    editor = NoteEditorController(repository, recorder, explicitCommit: true);
    await editor.open(note.id);
    expect(editor.isAudioRemoved('delete-audio'), isTrue);
    expect(editor.draft.body, '未保存的正文');
    await editor.cancel();
    expect(editor.isAudioRemoved('delete-audio'), isFalse);
    expect(editor.draft.body, '原始正文');
    expect(
      (await database.select(database.noteAudioSegments).get()),
      hasLength(2),
    );
  });

  test('保存只删除本篇选中原音，共享原件和其他片段继续受保护', () async {
    final NoteEntryRecord note = await publishedAudio();
    // 另存副本引用相同原件，删除原篇不能删掉共享文件。
    final NoteEntryRecord copy = await repository.saveAsNew(editor.draft);
    await editor.removeAudio('delete-audio');
    expect(await editor.commit(), NoteCommitResult.committed);
    final List<NoteAudioSegmentRecord> audio = await database
        .select(database.noteAudioSegments)
        .get();
    expect(
      audio.where((item) => item.noteId == note.id).single.id,
      'keep-audio',
    );
    expect(audio.where((item) => item.noteId == copy.id), hasLength(2));
    await repository.purgeOrphanFiles();
    expect(await File('${directory.path}/delete-audio.wav').exists(), isTrue);
  });

  test('删除原音遇正文冲突保留草稿，另存排除删除片段且保留原篇', () async {
    final NoteEntryRecord note = await publishedAudio();
    await editor.removeAudio('delete-audio');
    editor.edit(body: '我的修改');
    await repository.save(
      NoteDraft(
        id: note.id,
        body: '其他设备的修改',
        dayKey: note.dayKey,
        baseRevision: note.revision,
      ),
    );
    expect(await editor.commit(), NoteCommitResult.conflict);
    expect(
      (await database.select(database.noteAudioSegments).get()),
      hasLength(2),
    );
    await editor.saveAsNew();
    expect(editor.error, isNull);
    final List<NoteAudioSegmentRecord> audio = await database
        .select(database.noteAudioSegments)
        .get();
    expect(audio.where((item) => item.noteId == note.id), hasLength(2));
    expect(audio.where((item) => item.noteId != note.id), hasLength(1));
    expect((await repository.find(note.id))!.body, '其他设备的修改');
  });

  test('草稿新增录音删除后不提升，保存后孤儿清理释放原件', () async {
    await editor.startRecording();
    recorder.nextResult = await recording(id: 'new-removed');
    await editor.shutdown();
    editor.edit(body: '保留文字');
    await editor.removeAudio('new-removed');
    expect(await editor.commit(), NoteCommitResult.committed);
    expect(await database.select(database.noteAudioSegments).get(), isEmpty);
    await repository.purgeOrphanFiles();
    expect(await File('${directory.path}/new-removed.wav').exists(), isFalse);
  });

  test('文字先留本机草稿，显式发布才一次创建正式正文和版本', () async {
    editor.edit(body: '标题\n正文');
    await editor.flush();
    expect(await database.select(database.noteEntries).get(), isEmpty);
    expect(await database.select(database.noteVersions).get(), isEmpty);
    expect((await editor.listLocalDrafts()).single.body, '标题\n正文');
    expect(editor.dirty, isFalse);
    expect(await editor.commit(), NoteCommitResult.committed);
    expect(
      (await database.select(database.noteEntries).get()).single.body,
      '标题\n正文',
    );
    expect(await database.select(database.noteVersions).get(), hasLength(1));
    expect(await editor.listLocalDrafts(), isEmpty);
    expect(editor.draft.body, isEmpty);
    expect(await editor.commit(), NoteCommitResult.empty);
    expect(await database.select(database.noteEntries).get(), hasLength(1));
  });

  test('重启和卡片切换恢复本机正文，取消不改原正式笔记', () async {
    // 已发布历史记录。
    final NoteEntryRecord original = (await repository.save(
      const NoteDraft(
        id: 'old',
        body: '原正文',
        dayKey: '2026-10-10',
        baseRevision: '',
      ),
    ))!;
    editor.edit(body: '未发布顶部');
    await editor.flush();
    await editor.open(original.id);
    editor.edit(body: '历史本机修改');
    await editor.flush();
    await editor.openComposer();
    expect(editor.draft.body, '未发布顶部');
    editor.dispose();
    editor = NoteEditorController(repository, recorder, explicitCommit: true);
    await editor.open(original.id);
    expect(editor.draft.body, '历史本机修改');
    expect((await repository.find(original.id))!.body, '原正文');
    await editor.cancel();
    expect(editor.draft.body, '原正文');
    expect((await repository.find(original.id))!.body, '原正文');
    await editor.openComposer();
    expect(editor.draft.body, '未发布顶部');
  });

  test('录音和授权先暂存且经孤儿清理保留，发布后才进入音频传输', () async {
    editor.voiceConsent = true;
    await editor.startRecording();
    recorder.nextResult = await recording();
    await editor.shutdown();
    expect(await database.select(database.noteEntries).get(), isEmpty);
    expect(await database.select(database.noteAudioSegments).get(), isEmpty);
    expect(await database.select(database.noteAudioLocalFiles).get(), isEmpty);
    // 草稿原音是未发布资产。
    final NoteDraftAudioSegmentRecord staged =
        (await database.select(database.noteDraftAudioSegments).get()).single;
    expect(staged.consent, isTrue);
    expect(recorder.acknowledged, contains(staged.id));
    await repository.purgeOrphanFiles();
    expect(await File(staged.localPath!).exists(), isTrue);
    expect(await editor.commit(), NoteCommitResult.committed);
    expect(
      await database.select(database.noteAudioSegments).get(),
      hasLength(1),
    );
    // 转写授权直到发布后才被后台服务看到。
    final NoteAudioLocalFileRecord local =
        (await database.select(database.noteAudioLocalFiles).get()).single;
    expect(local.consent, isTrue);
    expect(local.uploadState, 'pending');
    expect(local.insertedRevision, startsWith('waiting:'));
    expect(
      await database.select(database.noteDraftAudioSegments).get(),
      isEmpty,
    );
    expect(await File(staged.localPath!).exists(), isTrue);
  });

  test('取消删除草稿新增原音并保留取消代次，迟到恢复不能复活', () async {
    editor.edit(body: '取消后不保留的正文', tags: {'private-tag'});
    editor.markTranscriptInsertion('private-insertion');
    await editor.startRecording();
    // 原音记录固定取消前的草稿代次。
    final NoteRecordingResult result = await recording();
    recorder.nextResult = result;
    await editor.shutdown();
    // 待取消的持久身份。
    final String draftId = editor.draftId!;
    await editor.cancel();
    expect(await File(result.path).exists(), isFalse);
    expectEmptyTombstone((await editor.localDrafts.find(draftId))!);
    expect(recorder.discardedDrafts, contains(draftId));
    recorder.pending = [result];
    await editor.recover();
    expect(await editor.listLocalDrafts(), isEmpty);
    expect(await database.select(database.noteEntries).get(), isEmpty);
  });

  test('永久删除清除本机草稿内容，墓碑阻止迟到原音恢复', () async {
    // 正式记录与编辑草稿拥有各自待删除的正文。
    final NoteEntryRecord original = (await repository.save(
      const NoteDraft(
        id: 'delete-original',
        body: '正式正文',
        dayKey: '2026-10-10',
        baseRevision: '',
      ),
    ))!;
    await editor.open(original.id);
    editor.edit(body: '私有本机修改', tags: {'private-tag'});
    editor.markTranscriptInsertion('private-insertion');
    await editor.startRecording();
    // 清单保留删除前的归属，模拟稍后再次交付。
    final NoteRecordingResult result = await recording();
    recorder.nextResult = result;
    await editor.shutdown();
    // 用持久草稿身份检查删除后的最小墓碑。
    final String draftId = editor.draftId!;
    await repository.permanentlyDelete(original.id);
    expectEmptyTombstone((await editor.localDrafts.find(draftId))!);
    expect(await repository.find(original.id), isNull);
    await repository.purgeOrphanFiles();
    expect(await File(result.path).exists(), isFalse);
    recorder.pending = [result];
    await editor.recover();
    expect(await editor.listLocalDrafts(), isEmpty);
    expect(await database.select(database.noteEntries).get(), isEmpty);
  });

  test('提交冲突不写正式候选或提升新增原音，草稿可另存', () async {
    // 双端共有的初始版本。
    final NoteEntryRecord original = (await repository.save(
      const NoteDraft(
        id: 'shared',
        body: '基线',
        dayKey: '2026-10-10',
        baseRevision: '',
      ),
    ))!;
    await editor.open(original.id);
    editor.edit(body: '本机修改');
    await editor.startRecording();
    recorder.nextResult = await recording();
    await editor.shutdown();
    await repository.save(
      NoteDraft(
        id: original.id,
        body: '远端修改',
        dayKey: original.dayKey,
        baseRevision: original.revision,
      ),
    );
    // 冲突前已存在的正式版本数。
    final int versions =
        (await database.select(database.noteVersions).get()).length;
    expect(await editor.commit(), NoteCommitResult.conflict);
    expect((await repository.find(original.id))!.body, '远端修改');
    expect(
      await database.select(database.noteVersions).get(),
      hasLength(versions),
    );
    expect(await database.select(database.noteAudioSegments).get(), isEmpty);
    expect(
      await database.select(database.noteDraftAudioSegments).get(),
      hasLength(1),
    );
    await editor.saveAsNew();
    expect(await database.select(database.noteEntries).get(), hasLength(2));
    expect(
      await database.select(database.noteAudioSegments).get(),
      hasLength(1),
    );
    expect(await editor.listLocalDrafts(), isEmpty);
  });

  test('缺失原音提交失败，正文和草稿原件元数据仍保留', () async {
    editor.edit(body: '不能半篇发布');
    await editor.startRecording();
    // 模拟用户磁盘原件丢失。
    final NoteRecordingResult result = await recording();
    recorder.nextResult = result;
    await editor.shutdown();
    await File(result.path).delete();
    expect(await editor.commit(), NoteCommitResult.failed);
    expect(await database.select(database.noteEntries).get(), isEmpty);
    expect((await editor.listLocalDrafts()).single.body, '不能半篇发布');
    expect(
      await database.select(database.noteDraftAudioSegments).get(),
      hasLength(1),
    );
  });

  test('浏览其他卡片和顶部不停止原录音，保存另一篇也不停止', () async {
    // 可以独立编辑的已发布记录。
    final NoteEntryRecord old = (await repository.save(
      const NoteDraft(
        id: 'other',
        body: '另一篇',
        dayKey: '2026-10-10',
        baseRevision: '',
      ),
    ))!;
    await editor.startRecording();
    // 顶部录音绑定独立新草稿。
    final String recordingDraftId = editor.draftId!;
    await editor.open(old.id);
    editor.edit(body: '另一篇修改');
    expect(await editor.commit(), NoteCommitResult.committed);
    expect(recorder.stops, 0);
    expect(recorder.state.draftId, recordingDraftId);
    await editor.openComposer();
    expect(editor.draftId, recordingDraftId);
    expect(recorder.stops, 0);
  });

  test('所有持久草稿阻止自动插入，手工插入取消不会清转写候选', () async {
    editor.edit(body: '基线');
    await editor.commit();
    // 已发布的笔记身份。
    final NoteEntryRecord note =
        (await database.select(database.noteEntries).get()).single;
    // 已发布原音有完整原始转写和一份重新识别候选。
    final NoteRecordingResult result = await recording(id: 'original-audio');
    await repository.addAudio(
      draft: NoteDraft(
        id: note.id,
        body: note.body,
        dayKey: note.dayKey,
        baseRevision: note.revision,
      ),
      id: result.id,
      localPath: result.path,
      durationMs: result.duration.inMilliseconds,
      mime: result.mimeType,
    );
    await (database.update(database.noteAudioSegments)
          ..where((row) => row.id.equals(result.id)))
        .write(const NoteAudioSegmentsCompanion(transcript: Value('原始转写')));
    await (database.update(
      database.noteAudioLocalFiles,
    )..where((row) => row.id.equals(result.id))).write(
      NoteAudioLocalFilesCompanion(
        consent: const Value(true),
        candidateTranscript: const Value('重新识别候选'),
        insertedRevision: Value('waiting:${note.revision}'),
      ),
    );
    await editor.open(note.id);
    editor.edit(body: '草稿修改');
    editor.markTranscriptInsertion('original-audio');
    await editor.flush();
    await editor.openComposer();
    expect(editor.hasUncommittedDraft(note.id), isTrue);
    await repository.insertReadyTranscripts(note.id);
    expect((await repository.find(note.id))!.body, '基线');
    await editor.open(note.id);
    await editor.cancel();
    expect((await repository.find(note.id))!.body, '基线');
    expect(
      (await database.select(database.noteAudioLocalFiles).get())
          .single
          .candidateTranscript,
      '重新识别候选',
    );
    editor.edit(body: '基线\n重新识别候选');
    editor.markTranscriptInsertion(result.id);
    expect(await editor.commit(), NoteCommitResult.committed);
    expect(
      (await database.select(database.noteAudioLocalFiles).get())
          .single
          .candidateTranscript,
      isNull,
    );
    expect(
      (await database.select(database.noteAudioLocalFiles).get())
          .single
          .insertedRevision,
      (await repository.find(note.id))!.revision,
    );
  });

  test('手动结束录音已idle但暂存未完成时，发布必须等待原音进入同一提交', () async {
    editor.dispose();
    // 原音暂存门禁复现设备与数据库完成不同步。
    final _DelayedDrafts local = _DelayedDrafts(repository)
      ..stageGate = Completer();
    editor = NoteEditorController(
      repository,
      recorder,
      explicitCommit: true,
      localDraftRepository: local,
    );
    editor.edit(body: '文字和原音一起发布');
    await editor.startRecording();
    recorder.nextResult = await recording();
    await recorder.stop();
    await local.stageStarted.future;
    expect(recorder.state.isActive, isFalse);
    // 用户在原音仍暂存时立即点击发布。
    final Future<NoteCommitResult> submitted = editor.commit();
    await Future<void>.delayed(Duration.zero);
    expect(await database.select(database.noteEntries).get(), isEmpty);
    local.stageGate!.complete();
    expect(await submitted, NoteCommitResult.committed);
    expect(
      await database.select(database.noteAudioSegments).get(),
      hasLength(1),
    );
    expect(
      await database.select(database.noteDraftAudioSegments).get(),
      isEmpty,
    );
  });

  test('A提交延迟时切换B或顶部均被挡住，不能把B正文绑定到A', () async {
    // 已发布的第二篇供尝试切换。
    final NoteEntryRecord other = (await repository.save(
      const NoteDraft(
        id: 'other',
        body: 'B正文',
        dayKey: '2026-10-10',
        baseRevision: '',
      ),
    ))!;
    editor.dispose();
    // 正式事务前停住，允许插入用户连续点击。
    final _DelayedDrafts local = _DelayedDrafts(repository)
      ..commitGate = Completer();
    editor = NoteEditorController(
      repository,
      recorder,
      explicitCommit: true,
      localDraftRepository: local,
    );
    editor.edit(body: 'A正文');
    await editor.flush();
    // A的代次不能在提交过程中改变。
    final String originalDraft = editor.draftId!;
    // 保存尚未完成。
    final Future<NoteCommitResult> submitted = editor.commit();
    await local.commitStarted.future;
    await editor.open(other.id);
    await editor.openComposer();
    await editor.openLocalDraft(originalDraft);
    editor.edit(body: '提交中不接受的输入');
    expect(editor.draftId, originalDraft);
    expect(editor.draft.body, 'A正文');
    local.commitGate!.complete();
    expect(await submitted, NoteCommitResult.committed);
    expect((await repository.find(other.id))!.body, 'B正文');
    expect(
      (await database.select(database.noteEntries).get()).map(
        (note) => note.body,
      ),
      contains('A正文'),
    );
  });

  test('删除准备只暂存历史编辑和原音，不发布正文或丢弃草稿', () async {
    // 删除目标是一篇正式笔记，草稿正文仍是本机私有修改。
    final NoteEntryRecord note = (await repository.save(
      const NoteDraft(
        id: 'deleting',
        body: '正式原文',
        dayKey: '2026-10-15',
        baseRevision: '',
      ),
    ))!;
    await editor.open(note.id);
    editor.edit(body: '删除前仍未发布的修改');
    await editor.startRecording();
    recorder.nextResult = await recording();
    // 固定代次，准备过程不能清空或切换草稿。
    final String localId = editor.draftId!;
    await editor.prepareForDeletion({note.id});
    expect(recorder.stops, 1);
    expect(recorder.state.isActive, isFalse);
    expect(editor.draftId, localId);
    expect(editor.committing, isFalse);
    expect((await repository.find(note.id))!.body, '正式原文');
    expect((await editor.localDrafts.find(localId))!.body, '删除前仍未发布的修改');
    expect(await editor.localDrafts.audio(localId), hasLength(1));
    await repository.softDelete(note.id);
    editor.acceptRemote(await repository.find(note.id));
    expect(editor.frozen, isTrue);
    expect((await editor.localDrafts.find(localId))!.discarded, isFalse);
  });

  test('删除其他笔记不会停止顶部未发布草稿的活动录音', () async {
    editor.edit(body: '未发布顶部草稿');
    await editor.startRecording();
    // 顶部录音拥有独立笔记身份。
    final String recordingNoteId = recorder.state.noteId!;
    await editor.prepareForDeletion({'other-note'});
    expect(recorder.stops, 0);
    expect(recorder.state.noteId, recordingNoteId);
    expect(recorder.state.isActive, isTrue);
    expect(editor.committing, isFalse);
  });

  test('删除准备等待命中笔记的在途设备启动及其暂存队列', () async {
    editor.dispose();
    // 原音进入数据库前保持阻塞。
    final _DelayedDrafts local = _DelayedDrafts(repository)
      ..stageGate = Completer();
    editor = NoteEditorController(
      repository,
      recorder,
      explicitCommit: true,
      localDraftRepository: local,
    );
    editor.edit(body: '待回收关联草稿');
    recorder.startGate = Completer();
    // 设备仍idle时保留删除目标身份。
    final String noteId = editor.draft.id;
    // 正在等待系统启动完成。
    final Future<void> starting = editor.startRecording();
    await recorder.startRequested.future;
    recorder.nextResult = await recording();
    // 删除不能在录音启动结果交付前返回。
    bool prepared = false;
    // 同时等待设备启动与原音暂存。
    final Future<void> preparing = editor
        .prepareForDeletion({noteId})
        .then((_) => prepared = true);
    await Future<void>.delayed(Duration.zero);
    expect(prepared, isFalse);
    recorder.startGate!.complete();
    await starting;
    await local.stageStarted.future;
    expect(prepared, isFalse);
    local.stageGate!.complete();
    await preparing;
    expect(recorder.stops, 1);
    expect(await local.audio(editor.draftId!), hasLength(1));
  });

  test('完成订阅已捕获原音暂存失败时，删除准备抛错且保留恢复能力', () async {
    editor.dispose();
    // 让完成事件订阅处理失败，异步队列本身仍正常结束。
    final _DelayedDrafts local = _DelayedDrafts(repository)..stageFails = true;
    editor = NoteEditorController(
      repository,
      recorder,
      explicitCommit: true,
      localDraftRepository: local,
    );
    editor.edit(body: '失败后不能继续删除');
    await editor.startRecording();
    recorder.nextResult = await recording();
    await recorder.stop();
    await local.stageStarted.future;
    await expectLater(
      editor.prepareForDeletion({editor.draft.id}),
      throwsStateError,
    );
    expect(editor.committing, isFalse);
    expect(recorder.acknowledged, isEmpty);
    expect(await File('${directory.path}/audio.wav').exists(), isTrue);
    expect((await editor.localDrafts.find(editor.draftId!))!.body, '失败后不能继续删除');
    await editor.prepareForDeletion({'unrelated-note'});
    expect(await editor.commit(), NoteCommitResult.failed);
    expect(
      (await editor.localDrafts.find(editor.draftId!))!.discarded,
      isFalse,
    );
    local.stageFails = false;
    recorder.pending = [await recording()];
    await editor.recover();
    await editor.prepareForDeletion({editor.draft.id});
    expect(recorder.acknowledged, {'audio'});
    expect(await editor.commit(), NoteCommitResult.committed);
  });

  test('已结束的图片暂存失败仍阻止关联删除，重试成功后可继续', () async {
    editor.edit(body: '选图失败的本机草稿');
    await expectLater(
      editor.addImages(['${directory.path}/missing.png']),
      throwsA(isA<FileSystemException>()),
    );
    expect(editor.imageAdding, isFalse);
    await expectLater(
      editor.prepareForDeletion({editor.draft.id}),
      throwsStateError,
    );
    expect(editor.committing, isFalse);
    await editor.prepareForDeletion({'unrelated-note'});
    await editor.addImages([await imageFile('retry')]);
    await editor.prepareForDeletion({editor.draft.id});
    expect(await editor.images.staged(editor.draftId!), hasLength(1));
  });

  test('部分选图失败后成功保存结束旧代次，重开可准备删除', () async {
    editor.edit(body: '可保存的正文与已暂存图片');
    // 正式身份在发布后沿用，编辑草稿代次会重新分配。
    final String noteId = editor.draft.id;
    // 同次选图先成功一张，再遇到文件读取失败。
    final String goodImage = await imageFile('partial-success');
    await expectLater(
      editor.addImages([goodImage, '${directory.path}/missing.png']),
      throwsA(isA<FileSystemException>()),
    );
    expect(await editor.images.staged(editor.draftId!), hasLength(1));
    await expectLater(editor.prepareForDeletion({noteId}), throwsStateError);
    expect(await editor.commit(), NoteCommitResult.committed);
    await editor.open(noteId);
    await editor.prepareForDeletion({noteId});
    expect((await repository.find(noteId))!.body, '可保存的正文与已暂存图片');
    expect(await editor.images.published(noteId), hasLength(1));
    expect(editor.committing, isFalse);
  });

  test('领域删除事务尚在排队时门禁持续阻止目标输入及录音启动', () async {
    editor.edit(body: '删除前的本机内容');
    // 领域事务由测试决定完成时点。
    final Completer<void> actionGate = Completer();
    // 可观察已经排空草稿并进入领域删除。
    final Completer<void> actionEntered = Completer();
    // 捕捉删除对应的当前身份。
    final String noteId = editor.draft.id;
    // 删除门禁应横跨领域异步任务的整个生命周期。
    final Future<void> deleting = editor.prepareForDeletion(
      {noteId},
      action: () async {
        actionEntered.complete();
        await actionGate.future;
      },
    );
    await actionEntered.future;
    expect(editor.committing, isTrue);
    editor.edit(body: '不能穿过删除门禁的输入');
    await editor.startRecording();
    expect(editor.draft.body, '删除前的本机内容');
    expect(recorder.state.isActive, isFalse);
    actionGate.complete();
    await deleting;
    expect(editor.committing, isFalse);
  });

  test('空标签仍执行领域删除且失败恢复门禁，无关录音持续活动', () async {
    editor.edit(body: '其他笔记的录音');
    await editor.startRecording();
    // 空标签删除同样属于受控的领域操作。
    bool actionRan = false;
    await expectLater(
      editor.prepareForDeletion(
        {},
        action: () async {
          actionRan = true;
          expect(editor.committing, isTrue);
          expect(recorder.state.isActive, isTrue);
          throw StateError('模拟领域删除回滚');
        },
      ),
      throwsStateError,
    );
    expect(actionRan, isTrue);
    expect(editor.committing, isFalse);
    expect(recorder.state.isActive, isTrue);
    expect(recorder.stops, 0);
  });

  test('删除无关笔记时正在请求设备的录音照常启动', () async {
    editor.edit(body: '另一篇录音');
    recorder.startGate = Completer();
    // 录音权限请求已固定这篇身份。
    final Future<void> starting = editor.startRecording();
    await recorder.startRequested.future;
    await editor.prepareForDeletion({'unrelated-note'});
    recorder.startGate!.complete();
    await starting;
    expect(recorder.state.isActive, isTrue);
    expect(recorder.stops, 0);
  });

  test('软删冻结本机草稿并阻止录音，恢复后可继续编辑和显式保存', () async {
    // 编辑中的历史笔记。
    final NoteEntryRecord note = (await repository.save(
      const NoteDraft(
        id: 'soft-deleted',
        body: '原文',
        dayKey: '2026-10-10',
        baseRevision: '',
      ),
    ))!;
    await editor.open(note.id);
    editor.edit(body: '本机修改');
    await editor.flush();
    await repository.softDelete(note.id);
    editor.acceptRemote(await repository.find(note.id));
    expect(editor.frozen, isTrue);
    editor.edit(body: '删除后不能继续输入');
    await editor.startRecording();
    expect(editor.draft.body, '本机修改');
    expect(recorder.state.isActive, isFalse);
    expect(await editor.commit(), NoteCommitResult.conflict);
    await repository.restore(note.id);
    editor.acceptRemote(await repository.find(note.id));
    expect(editor.frozen, isFalse);
    editor.edit(body: '恢复后继续修改');
    expect(await editor.commit(), NoteCommitResult.committed);
    expect((await repository.find(note.id))!.body, '恢复后继续修改');
  });

  test('孤儿清理快照和删除持有同一事务，新草稿与原音插入不能穿插被误删', () async {
    // 清理使用同一实际数据库连接。
    final _PausedCleanup cleanup = _PausedCleanup(database);
    // 在引用快照与删除之间刻意插入新的草稿请求。
    final Future<void> cleaning = cleanup.purgeOrphanFiles();
    await cleanup.snapshotTaken.future;
    // 观察写入是否已经越过尚未结束的清理事务。
    bool draftWritten = false;
    editor.edit(body: '清理期间创建的新草稿');
    // 新写入必须在清理事务结束后继续。
    final Future<void> writing = editor.flush().then((_) {
      draftWritten = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(draftWritten, isFalse);
    cleanup.continueCleanup.complete();
    await cleaning;
    await writing;
    await editor.startRecording();
    // 新原音经过后续清理仍受活动草稿保护。
    final NoteRecordingResult result = await recording();
    recorder.nextResult = result;
    await editor.shutdown();
    await repository.purgeOrphanFiles();
    expect(await File(result.path).exists(), isTrue);
    expect(
      await database.select(database.noteDraftAudioSegments).get(),
      hasLength(1),
    );
  });

  test('设备仍idle的延迟启动遇到取消时必须等待并结束，不能录进新空白草稿', () async {
    recorder.startGate = Completer();
    editor.edit(body: '准备取消的草稿');
    // 用户点击录音后还停在系统权限阶段。
    final Future<void> starting = editor.startRecording();
    await recorder.startRequested.future;
    expect(recorder.state.isActive, isFalse);
    expect(editor.recordingStarting, isTrue);
    // 取消必须排空旧启动而不是立即重置成新草稿。
    final Future<void> cancelling = editor.cancel();
    await Future<void>.delayed(Duration.zero);
    recorder.startGate!.complete();
    await starting;
    await cancelling;
    expect(recorder.state.isActive, isFalse);
    expect(recorder.stops, 1);
    expect(editor.draft.body, isEmpty);
    expect(await editor.listLocalDrafts(), isEmpty);
    expect(await database.select(database.noteEntries).get(), isEmpty);
  });
}

/// 系统外部图片返回的可控边界，不替换仓储或导入事务。
class _AcquisitionPicker extends Fake implements ImagePicker {
  /// 正常外部界面返回的文件。
  List<XFile> files;

  /// 冷启动丢失结果，仅交付一次。
  List<XFile>? lost;

  /// 最近是否启动相机。
  bool camera = false;

  /// 创建图片返回边界。
  _AcquisitionPicker(this.files);

  /// 系统相机单选。
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    camera = source == ImageSource.camera;
    return files.isEmpty ? null : files.first;
  }

  /// 系统相册多选。
  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async => files;

  /// 系统回收进程后取回原始结果。
  @override
  Future<LostDataResponse> retrieveLostData() async {
    // 已交付的数据不在第二次恢复时重放。
    final List<XFile>? result = lost;
    lost = null;
    return result == null
        ? LostDataResponse.empty()
        : LostDataResponse(files: result, type: RetrieveType.image);
  }
}
