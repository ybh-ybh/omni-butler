import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/core/sync/sync_note_audio_backup.dart';
import 'package:omni_butler/features/notes/audio/note_audio_models.dart';
import 'package:omni_butler/features/notes/data/note_local_draft_repository.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:powersync/powersync.dart';

/// 用真实 PowerSync 文件验证本机草稿边界和升级前队列身份。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 各运行时独占不同文件，允许测试同时打开旧数据源和候选库。
  final bool previousWarning =
      driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(
    () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning,
  );
  // 测试独占目录，不连接任何服务器。
  late Directory directory;
  // 不发起认证请求的仓储。
  late AuthRepository auth;
  // 当前独占运行时。
  late OmniSyncRuntime runtime;
  // 所有候选库在测试结束释放。
  final List<OmniSyncRuntime> candidates = [];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('omni_notes_powersync_');
    auth = AuthRepository(const FlutterSecureStorage());
    runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/source.sqlite',
    );
  });
  tearDown(() async {
    for (final OmniSyncRuntime candidate in candidates.reversed) {
      await candidate.close();
    }
    candidates.clear();
    await runtime.close();
    await directory.delete(recursive: true);
  });

  test('重启恢复的本机草稿不产生CRUD，发布才写正式笔记和版本', () async {
    // 草稿专属仓储只写本机表。
    final NoteLocalDraftRepository drafts = NoteLocalDraftRepository(
      NoteRepository(runtime.database),
    );
    await drafts.save(
      id: 'draft',
      draft: const NoteDraft(
        id: 'note',
        body: '中文标题\n尚未发布的正文',
        dayKey: '2026-10-12',
        baseRevision: '',
      ),
      isNew: true,
    );
    expect(await runtime.powerSync.getNextCrudTransaction(), isNull);
    expect(
      await runtime.database.select(runtime.database.noteEntries).get(),
      isEmpty,
    );
    await runtime.close();
    runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/source.sqlite',
    );
    // 重启不能把草稿误做首次导入业务数据。
    final NoteLocalDraftRepository restored = NoteLocalDraftRepository(
      NoteRepository(runtime.database),
    );
    expect((await restored.composer())!.body, '中文标题\n尚未发布的正文');
    expect(await runtime.powerSync.getNextCrudTransaction(), isNull);
    expect(await restored.commit('draft'), isNotNull);
    // 发布事务只包含正式笔记及不可变版本。
    final CrudTransaction? transaction = await runtime.powerSync
        .getNextCrudTransaction();
    expect(transaction, isNotNull);
    expect(
      transaction!.crud.map((entry) => entry.table),
      containsAll(['note_entries', 'note_versions']),
    );
    expect(
      transaction.crud.any(
        (entry) =>
            entry.table.startsWith('note_local_') ||
            entry.table.startsWith('note_draft_'),
      ),
      isFalse,
    );
    expect(await restored.list(), isEmpty);
  });

  test('选择本机数据携带草稿，选择服务器数据仅保留旧数据源草稿', () async {
    // 只在旧数据源存在的本机编辑。
    final NoteLocalDraftRepository drafts = NoteLocalDraftRepository(
      NoteRepository(runtime.database),
    );
    await drafts.save(
      id: 'draft',
      draft: const NoteDraft(
        id: 'note',
        body: '不混入服务器数据',
        dayKey: '2026-10-12',
        baseRevision: '',
      ),
      isNew: true,
    );
    // 原音与文字拥有相同草稿身份，文件必须复制到新数据源。
    final File originalAudio = await File('${directory.path}/draft.wav')
        .writeAsBytes(List<int>.filled(256, 0));
    expect(
      await drafts.stageAudio(
        NoteRecordingResult(
          id: 'segment',
          noteId: 'note',
          draftId: 'draft',
          path: originalAudio.path,
          duration: const Duration(seconds: 1),
          startedAt: DateTime(2026, 10, 12),
          mimeType: 'audio/wav',
        ),
        draftId: 'draft',
        consent: false,
      ),
      isTrue,
    );
    await runtime.freezeWrites();
    // 完整本机备份包含草稿，但服务端操作列表为空。
    final SyncSnapshot snapshot = await runtime.exportSnapshot();
    expect(snapshot.tables['note_local_drafts'], hasLength(1));
    expect(snapshot.operations, isEmpty);
    // 两种换服选择分别建立候选库。
    final OmniSyncRuntime local = await OmniSyncRuntime.createCandidate(
      auth,
      '${directory.path}/local.sqlite',
      snapshot,
      'local-target',
      mergeInitial: false,
      useLocalData: true,
    );
    candidates.add(local);
    final OmniSyncRuntime server = await OmniSyncRuntime.createCandidate(
      auth,
      '${directory.path}/server.sqlite',
      snapshot,
      'server-target',
      mergeInitial: false,
      useLocalData: false,
    );
    candidates.add(server);
    expect(
      await NoteLocalDraftRepository(NoteRepository(local.database)).list(),
      hasLength(1),
    );
    expect(
      await NoteLocalDraftRepository(NoteRepository(server.database)).list(),
      isEmpty,
    );
    // 草稿原件复制到候选库独立路径，旧源删除不影响新副本。
    final NoteDraftAudioSegmentRecord restoredAudio = await local.database
        .select(local.database.noteDraftAudioSegments)
        .getSingle();
    expect(restoredAudio.localPath, isNot(originalAudio.path));
    expect(
      await server.database
          .select(server.database.noteDraftAudioSegments)
          .get(),
      isEmpty,
    );
    await originalAudio.delete();
    expect(
      await isMigrationNoteAudioValid(restoredAudio.localPath, {
        'sha256': restoredAudio.sha256,
        'byte_size': restoredAudio.byteSize,
      }),
      isTrue,
    );
    expect(await drafts.list(), hasLength(1));
    expect(await local.powerSync.getNextCrudTransaction(), isNull);
    expect(await server.powerSync.getNextCrudTransaction(), isNull);
  });

  test('真实v18 PowerSync文件升级保留旧类别负载和事务身份', () async {
    // 构造旧业务列与版本，再由生产运行时执行升级。
    await runtime.database.customStatement(
      'ALTER TABLE note_entries ADD COLUMN category_id TEXT',
    );
    await runtime.database.customStatement(
      'ALTER TABLE note_entries ADD COLUMN category_name TEXT',
    );
    await runtime.database.customStatement(
      'DROP TABLE note_draft_audio_segments',
    );
    await runtime.database.customStatement('DROP TABLE note_local_drafts');
    await runtime.database.customStatement('PRAGMA user_version = 18');
    // 原请求可能已被服务端处理，升级不能改写其摘要对应的负载。
    final String oldPayload = jsonEncode({
      'category_id': 'retired',
      'category_name': '旧类别',
      'body': '保留正文',
    });
    await runtime.powerSync.execute(
      'INSERT INTO powersync_crud(op, id, type, data) VALUES(?, ?, ?, ?)',
      ['PATCH', 'old-note', 'note_entries', oldPayload],
    );
    // 升级前记录原始队列和事务标识。
    final CrudTransaction before = (await runtime.powerSync
        .getNextCrudTransaction())!;
    final List<Map<String, Object?>> rowsBefore = await runtime.powerSync
        .getAll('SELECT * FROM ps_crud');
    await runtime.close();
    runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/source.sqlite',
    );
    // 队列仅在服务端执行副本适配，客户端保持完整身份。
    final CrudTransaction after = (await runtime.powerSync
        .getNextCrudTransaction())!;
    expect(after.transactionId, before.transactionId);
    expect(await runtime.powerSync.getAll('SELECT * FROM ps_crud'), rowsBefore);
    expect(after.crud.single.opData, {
      'category_id': 'retired',
      'category_name': '旧类别',
      'body': '保留正文',
    });
    expect(
      (await runtime.database
              .customSelect('PRAGMA table_info(note_entries)')
              .get())
          .map((row) => row.read<String>('name')),
      isNot(contains('category_id')),
    );
    // 新版仓储仍能正常写正式记录。
    await runtime.database
        .into(runtime.database.noteEntries)
        .insert(
          NoteEntriesCompanion.insert(
            id: 'new-note',
            body: const Value('新版本'),
            dayKey: '2026-10-12',
            revision: 'v1',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
  });
}
