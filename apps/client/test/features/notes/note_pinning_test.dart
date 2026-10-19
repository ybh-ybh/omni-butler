import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';

/// 用真实 SQLite 验证独立置顶、旧草稿保全和迁移兼容。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 每例单独的内存数据库。
  late AppDatabase database;
  // 与生产界面相同的仓储。
  late NoteRepository repository;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = NoteRepository(database);
  });
  tearDown(() => database.close());

  /// 创建固定时间的合法笔记，避免排序依赖测试机器时区。
  Future<NoteEntryRecord> create(String id, String day, int seconds) async =>
      (await repository.save(
        NoteDraft(
          id: id,
          body: '正文$id',
          dayKey: day,
          baseRevision: '',
          recordTimeSeconds: seconds,
          recordUtcOffsetMinutes: 0,
          createdAt: DateTime.utc(2024),
          creationTimezone: 'UTC|+00:00',
        ),
      ))!;

  test('置顶优先，组内记录时间倒序，同秒按ID稳定排序，取消后恢复归档顺序', () async {
    await create('new', '2024-02-01', 0);
    await create('a', '2024-01-01', 3600);
    await create('b', '2024-01-01', 3600);
    await create('early', '2024-01-01', 1);
    await repository.setPinned('b', true);
    await repository.setPinned('early', true);
    await repository.setPinned('a', true);
    expect((await repository.watchAll().first).map((note) => note.id), [
      'a',
      'b',
      'early',
      'new',
    ]);
    await repository.setPinned('b', false);
    expect((await repository.watchAll().first).map((note) => note.id), [
      'a',
      'early',
      'new',
      'b',
    ]);
  });

  test('置顶只改状态和修改时间，重复确认幂等，旧正文草稿保存保留最新置顶', () async {
    // 模拟用户进入编辑器时读取的旧状态。
    final NoteEntryRecord original = await create('note', '2024-01-01', 1);
    expect(original.isPinned, isFalse);
    await repository.setPinned('note', true);
    // 独立菜单修改不得产生正文版本或改写真实创建时刻。
    final NoteEntryRecord pinned = (await repository.find('note'))!;
    expect(pinned.isPinned, isTrue);
    expect(pinned.revision, original.revision);
    expect(pinned.body, original.body);
    expect(pinned.tags, original.tags);
    expect(pinned.createdAt, original.createdAt);
    expect(pinned.dayKey, original.dayKey);
    expect(pinned.recordTimeSeconds, original.recordTimeSeconds);
    expect(await database.select(database.noteVersions).get(), hasLength(1));
    await repository.setPinned('note', true);
    expect((await repository.find('note'))!.updatedAt, pinned.updatedAt);
    await repository.save(
      NoteDraft(
        id: original.id,
        body: '旧编辑器修改正文',
        dayKey: original.dayKey,
        baseRevision: original.revision,
      ),
    );
    expect((await repository.find('note'))!.isPinned, isTrue);
    await repository.setPinned('note', false);
    expect((await repository.find('note'))!.isPinned, isFalse);
  });

  test('删除后拒绝置顶且不复活，恢复保留原置顶', () async {
    await create('note', '2024-01-01', 1);
    await repository.setPinned('note', true);
    await repository.softDelete('note');
    await expectLater(repository.setPinned('note', false), throwsStateError);
    await expectLater(repository.setPinned('missing', true), throwsStateError);
    expect(await repository.watchAll().first, isEmpty);
    await repository.restore('note');
    expect((await repository.find('note'))!.isPinned, isTrue);
  });

  test('v24真实文件升级v25默认未置顶，正文和时间原样保留', () async {
    // 独立文件用于关闭后重新打开触发真实迁移。
    final Directory directory = await Directory.systemTemp.createTemp(
      'note-pin-',
    );
    // 测试专用SQLite文件，避免触碰业务库。
    final File file = File('${directory.path}/notes.sqlite');
    // 可重开的真实数据库句柄。
    AppDatabase legacy = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await NoteRepository(legacy).save(
        const NoteDraft(
          id: 'legacy',
          body: '原正文',
          dayKey: '2024-01-01',
          baseRevision: '',
          recordTimeSeconds: 3600,
          recordUtcOffsetMinutes: 480,
        ),
      );
      await legacy.customStatement(
        'ALTER TABLE note_entries DROP COLUMN is_pinned',
      );
      await legacy.customStatement('PRAGMA user_version = 24');
      await legacy.close();
      legacy = AppDatabase.forTesting(NativeDatabase(file));
      // 已迁移的正式笔记仍可通过生产仓储读取。
      final NoteEntryRecord restored = (await NoteRepository(legacy)
          .find('legacy'))!;
      expect(restored.isPinned, isFalse);
      expect(restored.body, '原正文');
      expect(restored.recordTimeSeconds, 3600);
      expect(restored.recordUtcOffsetMinutes, 480);
      expect(
        (await legacy.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        25,
      );
    } finally {
      await legacy.close();
      await directory.delete(recursive: true);
    }
  });

  test('v9旧快照补默认false且不改原始文件，新快照置顶往返上传JSON布尔', () {
    // 完整表集只让笔记行模拟v9缺失置顶字段。
    final Map<String, dynamic> tables = {
      for (final String name in SyncSnapshot.tableNames)
        name: <Map<String, Object?>>[],
    };
    // 原始备份行不得在解析时被修改。
    final Map<String, Object?> old = {'id': 'old', 'body': '旧正文'};
    tables['note_entries'] = [old];
    // 旧版格式在内存补SQLite布尔默认值。
    final SyncSnapshot restored = SyncSnapshot.fromJson({
      'version': 9,
      'tables': tables,
      'pendingOperations': 0,
    });
    expect(restored.tables['note_entries']!.single['is_pinned'], 0);
    expect(old.containsKey('is_pinned'), isFalse);
    expect((restored.operations.single['data'] as Map)['is_pinned'], false);
    restored.tables['note_entries']!.single['is_pinned'] = 1;
    // 当前备份保留原始SQLite值，而换服使用严格JSON布尔。
    final SyncSnapshot roundTrip = SyncSnapshot.fromJson(
      Map<String, dynamic>.from(restored.toJson()),
    );
    expect(roundTrip.tables['note_entries']!.single['is_pinned'], 1);
    expect((roundTrip.operations.single['data'] as Map)['is_pinned'], true);
    expect(SyncSnapshot.version, 10);
    expect(SyncSnapshot.migrationProtocolVersion, 3);
  });
}
