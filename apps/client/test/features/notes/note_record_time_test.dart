import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/data/note_editor_controller.dart';
import 'package:omni_butler/features/notes/data/note_local_draft_repository.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';

/// 时间编辑测试不访问原生录音硬件。
class _IdleRecorder implements NoteRecorderService {
  /// 本测试不产生录音完成事件。
  @override
  Stream<NoteRecordingResult> get completed => const Stream.empty();

  /// 录音始终空闲，取消草稿无需停止硬件。
  @override
  NoteRecordingState get state => const NoteRecordingState();

  /// 本测试没有需要清理的原音清单。
  @override
  Future<void> discardPendingForDraft(
    String draftId, {
    Set<String> protectedPaths = const {},
  }) async {}

  /// 其他硬件方法不应被时间编辑调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 覆盖固定墙钟边界，以及正式数据与未提交草稿的隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('固定记录时间', () {
    // 使用固定当前时刻，使边界判断不会随测试执行日期变化。
    final DateTime now = DateTime.utc(2026, 10, 19, 12);

    test('有效闰日及1970年下限均可选择', () {
      expect(
        () => const NoteRecordTime('2024-02-29', 86399, 480).validate(now: now),
        returnsNormally,
      );
      expect(
        () => const NoteRecordTime('1970-01-01', 0, 0).validate(now: now),
        returnsNormally,
      );
      expect(
        () => const NoteRecordTime('1969-12-31', 86399, 0).validate(now: now),
        throwsFormatException,
      );
    });

    test('无效月末、非闰日、秒数和偏移均拒绝', () {
      for (final NoteRecordTime value in const [
        NoteRecordTime('2025-02-29', 0, 0),
        NoteRecordTime('2026-04-31', 0, 0),
        NoteRecordTime('2026-10-19', -1, 0),
        NoteRecordTime('2026-10-19', 86400, 0),
        NoteRecordTime('2026-10-19', 0, 841),
        NoteRecordTime('2026-10-19', 0, -841),
        NoteRecordTime('2026-1-01', 0, 0),
      ]) {
        expect(
          () => value.validate(now: now),
          throwsFormatException,
          reason: value.label,
        );
      }
    });

    test('当前秒可选，下一秒和按偏移还原后的未来瞬间不可选', () {
      expect(
        () => const NoteRecordTime('2026-10-19', 43200, 0).validate(now: now),
        returnsNormally,
      );
      expect(
        () => const NoteRecordTime('2026-10-19', 43201, 0).validate(now: now),
        throwsFormatException,
      );
      expect(
        () => const NoteRecordTime('2026-10-19', 43200, -60).validate(now: now),
        throwsFormatException,
      );
      expect(
        () => const NoteRecordTime('2026-10-19', 46800, 60).validate(now: now),
        returnsNormally,
      );
    });

    test('墙钟显示只取保存字段，UTC偏移仅影响实际瞬间', () {
      // 两个偏移表示不同瞬间，但用户看到的年月日时分秒一致。
      const NoteRecordTime east = NoteRecordTime('2024-03-10', 9015, 480);
      // 夏令时跳变日仍完整保留所选02:30:15。
      const NoteRecordTime west = NoteRecordTime('2024-03-10', 9015, -300);
      expect(east.wallTime, DateTime.utc(2024, 3, 10, 2, 30, 15));
      expect(west.wallTime, east.wallTime);
      expect(east.label, '2024-03-10 02:30:15');
      expect(east.instant, DateTime.utc(2024, 3, 9, 18, 30, 15));
      expect(west.instant, DateTime.utc(2024, 3, 10, 7, 30, 15));
    });

    test('旧记录保留归档日，已知创建偏移恢复时钟，未知时区使用UTC', () {
      // 创建瞬间的UTC日与旧归档日不同，不得自行更改归档日。
      final DateTime created = DateTime.utc(2024, 1, 1, 23, 59, 58);
      // 已知偏移需要跨日还原时分秒。
      final NoteRecordTime known = NoteRecordTime.resolve(
        dayKey: '2024-01-03',
        createdAt: created,
        creationTimezone: 'CST|+08:00',
      );
      // 历史未知地区不使用运行测试机器的当前时区。
      final NoteRecordTime unknown = NoteRecordTime.resolve(
        dayKey: '2024-01-03',
        createdAt: created,
        creationTimezone: 'legacy:unknown',
      );
      expect(known.label, '2024-01-03 07:59:58');
      expect(known.utcOffsetMinutes, 480);
      expect(unknown.label, '2024-01-03 23:59:58');
      expect(unknown.utcOffsetMinutes, 0);
      // 损坏的历史偏移不能让客户端与服务端推导出不同时间。
      final NoteRecordTime malformed = NoteRecordTime.resolve(
        dayKey: '2024-01-03',
        createdAt: created,
        creationTimezone: 'legacy|+99:99',
      );
      expect(malformed.label, unknown.label);
      expect(malformed.utcOffsetMinutes, 0);
    });
  });

  group('记录时间持久化', () {
    // 每例使用独立数据库，避免正式数据互相污染。
    late AppDatabase database;
    // 被测生产仓储。
    late NoteRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = NoteRepository(database);
    });
    tearDown(() => database.close());

    /// 固定原始创建时间，确保测试不依赖墙钟和设备时区。
    Future<NoteEntryRecord> create({
      String id = 'note',
      String day = '2024-01-02',
      int seconds = 3600,
    }) async => (await repository.save(
      NoteDraft(
        id: id,
        body: '正式正文',
        dayKey: day,
        recordTimeSeconds: seconds,
        recordUtcOffsetMinutes: 480,
        createdAt: DateTime.utc(2024, 1, 1, 17),
        creationTimezone: 'CST|+08:00',
        baseRevision: '',
      ),
    ))!;

    test('单改时分秒不产生正文版本、不重写创建信息，重复确认保持updatedAt', () async {
      // 时间修改前的正式版本与创建信息。
      final NoteEntryRecord before = await create();
      // 只改同一天的时分秒。
      const NoteRecordTime selected = NoteRecordTime('2024-01-02', 7201, 480);
      await repository.updateRecordTime(before.id, selected);
      // 独立入口提交后的正式记录。
      final NoteEntryRecord after = (await repository.find(before.id))!;
      expect(after.recordTime.label, '2024-01-02 02:00:01');
      expect(after.body, before.body);
      expect(after.revision, before.revision);
      expect(after.createdAt, before.createdAt);
      expect(after.creationTimezone, before.creationTimezone);
      expect(await database.select(database.noteVersions).get(), hasLength(1));
      await repository.updateRecordTime(before.id, selected);
      expect((await repository.find(before.id))!.updatedAt, after.updatedAt);
    });

    test('日期独立修改后旧正文草稿提交保留最新正式时间', () async {
      // 编辑器在独立日期入口修改前打开的旧基线。
      final NoteEntryRecord before = await create();
      // tracked草稿只修改正文，日期不属于此次编辑。
      final NoteDraft stale = NoteDraft(
        id: before.id,
        body: '后来提交的正文',
        dayKey: before.dayKey,
        recordTimeSeconds: before.recordTimeSeconds,
        recordUtcOffsetMinutes: before.recordUtcOffsetMinutes,
        baseRevision: before.revision,
        originalTags: {},
        createdAt: before.createdAt,
        creationTimezone: before.creationTimezone,
      );
      await repository.updateRecordTime(
        before.id,
        const NoteRecordTime('2023-12-31', 3600, 480),
      );
      // 提交旧草稿后仍应使用独立入口保存的日期。
      final NoteEntryRecord saved = (await repository.save(stale))!;
      expect(saved.body, stale.body);
      expect(saved.recordTime.label, '2023-12-31 01:00:00');
      expect(saved.createdAt, before.createdAt);
      expect(await database.select(database.noteVersions).get(), hasLength(2));
    });

    test('排序使用归档日和记录时钟，同秒按身份稳定排序', () async {
      await create(id: 'z', seconds: 100);
      await create(id: 'b', seconds: 300);
      await create(id: 'a', seconds: 300);
      await create(id: 'next-day', day: '2024-01-03', seconds: 0);
      expect((await repository.watchAll().first).map((note) => note.id), [
        'next-day',
        'a',
        'b',
        'z',
      ]);
    });

    test('不存在或已删除笔记不能写入日期，失败不改变正式记录', () async {
      // 使用始终合法的历史时刻，失败原因必须来自笔记状态。
      const NoteRecordTime selected = NoteRecordTime('2023-12-31', 3600, 480);
      await expectLater(
        repository.updateRecordTime('missing', selected),
        throwsStateError,
      );
      // 删除后的记录仍可追溯，但独立修改入口必须拒绝。
      final NoteEntryRecord before = await create();
      await (database.update(database.noteEntries)
            ..where((table) => table.id.equals(before.id)))
          .write(NoteEntriesCompanion(deletedAt: Value(DateTime.utc(2024, 2))));
      await expectLater(
        repository.updateRecordTime(before.id, selected),
        throwsStateError,
      );
      expect(
        (await repository.find(before.id))!.recordTime.label,
        before.recordTime.label,
      );
    });

    test('安卓时间修改先暂存且可恢复，取消不改正式记录', () async {
      // 打开的正式笔记。
      final NoteEntryRecord before = await create();
      // 显式保存模式对应安卓历史编辑页。
      final NoteEditorController editor = NoteEditorController(
        repository,
        _IdleRecorder(),
        explicitCommit: true,
      );
      try {
        await editor.open(before.id);
        editor.edit(recordTime: const NoteRecordTime('2024-02-29', 86399, 480));
        await editor.flush();
        expect(
          (await repository.find(before.id))!.recordTime.label,
          before.recordTime.label,
        );
        // 从数据库重新读取，验证重启可恢复的数据而非只验证内存。
        final NoteLocalDraftRecord local = (await editor.localDrafts.forNote(
          before.id,
        ))!;
        // 生产恢复函数保留主动修改标记与秒级字段。
        final NoteDraft restored = noteDraftFromLocal(local);
        expect(restored.recordTime.label, '2024-02-29 23:59:59');
        expect(restored.recordTime.utcOffsetMinutes, 480);
        expect(restored.dateEdited, isTrue);
        await editor.cancel();
        expect(editor.error, isNull);
        expect(await editor.localDrafts.forNote(before.id), isNull);
        expect(
          (await repository.find(before.id))!.recordTime.label,
          before.recordTime.label,
        );
        expect(
          await database.select(database.noteVersions).get(),
          hasLength(1),
        );
      } finally {
        editor.dispose();
      }
    });

    test('安卓确定后显式保存才发布记录时间，纯时间修改没有正文新版本', () async {
      // 保留原始版本以确认时间修改不创建正文历史。
      final NoteEntryRecord before = await create();
      // 每例独立会话避免草稿代次互相影响。
      final NoteEditorController editor = NoteEditorController(
        repository,
        _IdleRecorder(),
        explicitCommit: true,
      );
      try {
        await editor.open(before.id);
        editor.edit(recordTime: const NoteRecordTime('2024-02-29', 86399, 480));
        expect(await editor.commit(), NoteCommitResult.committed);
        expect(
          (await repository.find(before.id))!.recordTime.label,
          '2024-02-29 23:59:59',
        );
        expect(
          await database.select(database.noteVersions).get(),
          hasLength(1),
        );
      } finally {
        editor.dispose();
      }
    });
  });
}
