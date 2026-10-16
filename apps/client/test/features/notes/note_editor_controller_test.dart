import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/data/note_editor_controller.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';

/// 无原生麦克风的录音边界，验证控制器退出确实调用停止。
class _Recorder implements NoteRecorderService {
  /// 完成原音事件。
  final StreamController<NoteRecordingResult> events =
      StreamController.broadcast();

  /// 当前录音状态。
  @override
  NoteRecordingState state = const NoteRecordingState();

  /// 停止调用次数。
  int stops = 0;

  /// 最近一次传给录音器的剩余额度。
  Duration? remaining;

  /// 完成事件入口。
  @override
  Stream<NoteRecordingResult> get completed => events.stream;

  /// 测试只记录录音启动参数。
  @override
  Future<void> start(
    String noteId, {
    Duration remaining = NoteRecorderService.noteLimit,
    String? draftId,
  }) async {
    this.remaining = remaining;
    state = NoteRecordingState(
      phase: NoteRecordingPhase.recording,
      noteId: noteId,
      draftId: draftId,
    );
  }

  /// 首次入口扫描不模拟任何遗留恢复任务。
  @override
  Future<List<NoteRecordingResult>> recoverPending() async => [];

  /// 测试默认没有持久删除标记。
  @override
  Future<bool> isPermanentlyDiscarded(String noteId) async => false;

  /// 停止录音但无需真实硬件。
  @override
  Future<NoteRecordingResult?> stop({String? reason}) async {
    stops++;
    state = const NoteRecordingState();
    return null;
  }

  /// 不使用的原生接口不应在这些测试中调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 控制真实事务开始时点，允许模拟网络式迟到保存结果。
class _ControlledRepository extends NoteRepository {
  /// 绑定真实内存数据库。
  _ControlledRepository(super.database);

  /// 捕获所有请求快照。
  final List<NoteDraft> requests = [];

  /// 只阻塞下一次保存。
  Completer<void>? gate;

  /// 下一次保存产生可恢复异常。
  bool fail = false;

  /// 计时器测试不执行 SQLite，仅验证调度边界。
  bool timingOnly = false;

  /// 请求被记录后等待测试释放，随后执行生产事务。
  @override
  Future<NoteEntryRecord?> save(
    NoteDraft draft, {
    bool hasAudio = false,
    bool hasImages = false,
  }) async {
    requests.add(draft);
    // 每次请求固定自己的闸门，后续保存不被同一闸门阻塞。
    final Completer<void>? waiting = gate;
    gate = null;
    await waiting?.future;
    if (fail) throw StateError('磁盘写入失败');
    if (timingOnly) return null;
    return super.save(draft, hasAudio: hasAudio, hasImages: hasImages);
  }
}

/// 验证定时器边界、持久化失败及保存期间的真实编辑竞态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 每例隔离数据库。
  late AppDatabase database;
  // 可控制事务时点的仓储。
  late _ControlledRepository repository;
  // 不访问设备的录音器。
  late _Recorder recorder;
  // 被测编辑会话。
  late NoteEditorController editor;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = _ControlledRepository(database);
    recorder = _Recorder();
    editor = NoteEditorController(repository, recorder);
  });
  tearDown(() async {
    editor.dispose();
    await recorder.events.close();
    await database.close();
  });

  /// 创建真实有效标签，避免整理合并测试被过滤失效身份。
  Future<void> seedTaxonomies() async {
    // 固定标签创建时刻。
    final DateTime now = DateTime.utc(2026, 10, 11);
    for (final String id in ['keep', 'remove', 'local', 'remote']) {
      await database
          .into(database.taxonomyEntries)
          .insert(
            TaxonomyEntriesCompanion.insert(
              id: id,
              module: 'notes',
              kind: 'tag',
              name: id,
              colorValue: const Value(null),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  }

  test('正文dirty期间B整理改变而revision不变，A保存仍保留B日期标签', () async {
    await seedTaxonomies();
    // A打开的原始记录。
    final NoteEntryRecord initial = (await repository.save(
      const NoteDraft(
        id: 'shared',
        body: '初始正文',
        dayKey: '2026-10-10',
        baseRevision: '',
        tags: {'keep'},
      ),
    ))!;
    await editor.open(initial.id);
    editor.edit(body: 'A人工输入');
    await (database.update(
      database.noteEntries,
    )..where((row) => row.id.equals(initial.id))).write(
      const NoteEntriesCompanion(
        dayKey: Value('2026-10-09'),
        tags: Value('["keep","remote"]'),
      ),
    );
    expect((await repository.find(initial.id))!.revision, initial.revision);
    await editor.flush();
    // A只能提交正文，不得撤销B整理。
    final NoteEntryRecord saved = (await repository.find(initial.id))!;
    expect(saved.body, 'A人工输入');
    expect(saved.dayKey, '2026-10-09');
    expect(noteTagIds(saved.tags), {'keep', 'remote'});
    expect(editor.draft.tags, {'keep', 'remote'});
  });

  test('用户标签增删按打开时基线合并B新增，保留明确本机日期选择', () async {
    await seedTaxonomies();
    // 标签基线包含用户将移除的身份。
    final NoteEntryRecord initial = (await repository.save(
      const NoteDraft(
        id: 'shared',
        body: '初始正文',
        dayKey: '2026-10-10',
        baseRevision: '',
        tags: {'keep', 'remove'},
      ),
    ))!;
    await editor.open(initial.id);
    editor.edit(tags: {'keep', 'local'}, dayKey: '2026-10-12');
    await (database.update(
      database.noteEntries,
    )..where((row) => row.id.equals(initial.id))).write(
      const NoteEntriesCompanion(
        dayKey: Value('2026-10-09'),
        tags: Value('["keep","remove","remote"]'),
      ),
    );
    await editor.flush();
    // 本机移除remove、新增local，B新增remote仍在。
    final NoteEntryRecord saved = (await repository.find(initial.id))!;
    expect(noteTagIds(saved.tags), {'keep', 'local', 'remote'});
    expect(saved.dayKey, '2026-10-12');
  });

  test('纯录音尚未落库时浏览旧篇后enter恢复原草稿身份与创建时间', () async {
    // 可浏览的旧篇。
    final NoteEntryRecord old = (await repository.save(
      const NoteDraft(
        id: 'old',
        body: '旧篇正文',
        dayKey: '2026-10-10',
        baseRevision: '',
      ),
    ))!;
    // 尚未有效输入的录音草稿。
    final String recordingId = editor.draft.id;
    await editor.startRecording();
    final NoteDraft recording = editor.draft;
    expect(recording.createdAt, isNotNull);
    expect(await repository.find(recordingId), isNull);
    await editor.open(old.id);
    expect(editor.draft.id, old.id);
    await editor.enter();
    expect(editor.draft.id, recordingId);
    expect(editor.draft.body, isEmpty);
    expect(editor.draft.createdAt, recording.createdAt);
    expect(editor.draft.creationTimezone, recording.creationTimezone);
    expect(recorder.state.noteId, recordingId);
    expect(recorder.stops, 0);
    expect(await repository.find(recordingId), isNull);
  });

  test('正常退出保存失败会拒绝关闭但仍保留dirty输入供复制', () async {
    repository.fail = true;
    editor.edit(body: '退出不能丢失的文字');
    await expectLater(editor.shutdown(), throwsStateError);
    expect(editor.dirty, isTrue);
    expect(editor.draft.body, '退出不能丢失的文字');
    expect(editor.error, contains('磁盘写入失败'));
    expect(await repository.find(editor.draft.id), isNull);
    expect(recorder.stops, 1);
  });

  testWidgets('停止输入恰好 500ms 才触发保存', (tester) async {
    repository.timingOnly = true;
    editor.edit(body: '第一条');
    await tester.pump(const Duration(milliseconds: 499));
    expect(repository.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.requests.single.body, '第一条');
    expect(editor.dirty, isFalse);
  });

  testWidgets('持续每 400ms 输入仍在首次输入 2s 保存最新快照', (tester) async {
    repository.timingOnly = true;
    editor.edit(body: '0');
    for (int step = 1; step <= 4; step++) {
      await tester.pump(const Duration(milliseconds: 400));
      editor.edit(body: '$step');
    }
    await tester.pump(const Duration(milliseconds: 399));
    expect(repository.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.requests.single.body, '4');
  });

  test('空白草稿只改元数据不留档，重新进入创建独立空白身份', () async {
    // 入口草稿身份。
    final String initialId = editor.draft.id;
    editor.edit(dayKey: '2026-10-01', tags: {'tag'});
    await editor.flush();
    expect(await database.select(database.noteEntries).get(), isEmpty);
    expect(await database.select(database.noteVersions).get(), isEmpty);
    await editor.enter();
    expect(editor.draft.id, isNot(initialId));
    expect(editor.draft.body, isEmpty);
  });

  test('20,000字完整保存，超限失败保留全部输入且禁止新建丢弃', () async {
    // 边界正文，不截断多余输入。
    final String maximum = List.filled(20000, '念').join();
    editor.edit(body: maximum);
    await editor.flush();
    expect((await repository.find(editor.draft.id))!.body, maximum);
    // 用户继续输入的超限正文。
    final String overflow = [maximum, '尾'].join();
    editor.edit(body: overflow);
    await editor.flush();
    expect(editor.dirty, isTrue);
    expect(editor.draft.body, overflow);
    expect(editor.error, contains('20,000'));
    await editor.newNote();
    expect(editor.draft.body, overflow);
    expect((await repository.find(editor.draft.id))!.body, maximum);
  });

  test('正常离场 shutdown 排空不足500ms的输入并停止录音', () async {
    editor.edit(body: '离场前最后一个字');
    await editor.shutdown();
    expect((await repository.find(editor.draft.id))!.body, '离场前最后一个字');
    expect(editor.dirty, isFalse);
    expect(recorder.stops, 1);
  });

  test('保存失败保留草稿，明确重试后落盘', () async {
    repository.fail = true;
    editor.edit(body: '不能丢失');
    await editor.flush();
    expect(editor.draft.body, '不能丢失');
    expect(editor.dirty, isTrue);
    expect(editor.error, contains('磁盘写入失败'));
    expect(await repository.find(editor.draft.id), isNull);
    repository.fail = false;
    await editor.flush();
    expect((await repository.find(editor.draft.id))!.body, '不能丢失');
    expect(editor.error, isNull);
    expect(editor.dirty, isFalse);
  });

  test('保存期间的新输入不被旧响应覆盖，下一次保存承接新revision', () async {
    // 阻塞首次保存以制造用户继续输入。
    final Completer<void> gate = Completer();
    repository.gate = gate;
    editor.edit(body: '旧输入');
    // 正在进行的保存任务。
    final Future<void> saving = editor.flush();
    editor.edit(body: '更新输入', dayKey: '2026-10-12');
    gate.complete();
    await saving;
    expect(editor.draft.body, '更新输入');
    expect(editor.draft.dayKey, '2026-10-12');
    expect(editor.dirty, isTrue);
    expect((await repository.find(editor.draft.id))!.body, '旧输入');
    await editor.flush();
    expect((await repository.find(editor.draft.id))!.body, '更新输入');
    expect(await database.select(database.noteVersions).get(), hasLength(2));
  });

  test('等待保存期间远端更新，当前输入持久为候选且不覆盖远端', () async {
    editor.edit(body: '共同起点');
    await editor.flush();
    // 起点版本。
    final NoteDraft base = editor.draft;
    // 人工保存开始后停在事务前。
    final Completer<void> gate = Completer();
    repository.gate = gate;
    editor.edit(body: '本机候选');
    // 未完成的本机保存。
    final Future<void> pending = editor.flush();
    // 第二设备提交的真实事务。
    final NoteEntryRecord? remote = await NoteRepository(database).save(
      NoteDraft(
        id: base.id,
        body: '远端正文',
        dayKey: base.dayKey,
        baseRevision: base.baseRevision,
      ),
    );
    editor.acceptRemote(remote);
    expect(editor.draft.body, '本机候选');
    gate.complete();
    await pending;
    expect(editor.conflicted, isTrue);
    expect(editor.dirty, isTrue);
    expect(editor.draft.body, '本机候选');
    expect((await repository.find(base.id))!.body, '远端正文');
    expect(
      (await database.select(database.noteVersions).get()).map((v) => v.body),
      contains('本机候选'),
    );
    await editor.flush();
    expect((await repository.find(base.id))!.body, '远端正文');
    await editor.useVersion('本机候选');
    expect((await repository.find(base.id))!.body, '本机候选');
    expect(editor.conflicted, isFalse);
  });
}
