import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_connection_store.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/audio/note_wav.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../tool/clear_note_test_data.dart';
import 'support/note_path_test_support.dart';

/// Simulates a service that returns without completing its filesystem work.
class _IncompleteDiscard extends _FailingDiscard {
  /// Bind the test double to the same preflighted directory as the real service.
  _IncompleteDiscard(super.directory);

  /// Leave the fixture unchanged so completion must detect the remaining files.
  @override
  Future<void> discardPendingForNote(
    String noteId, {
    String? draftId,
    String? recordingId,
    Set<String> protectedPaths = const {},
  }) async {}
}

/// 模拟提交后磁盘标记写入失败；不能伪装成清理成功。
class _FailingDiscard implements NoteRecorderService {
  /// Bind the injected failure to one explicitly authorized fixture directory.
  _FailingDiscard(this.directory);

  /// Keep the test double's scope independently verifiable.
  final Directory directory;

  /// Resolve only the test-owned directory without creating anything.
  @override
  Future<String> recordingDirectoryIdentity() =>
      directory.resolveSymbolicLinks();

  /// 没有活跃硬件会话。
  @override
  NoteRecordingState get state => const NoteRecordingState();

  /// 删除事实无法落盘时直接反馈异常。
  @override
  Future<void> discardPendingForNote(
    String noteId, {
    String? draftId,
    String? recordingId,
    Set<String> protectedPaths = const {},
  }) async => throw const FileSystemException('模拟磁盘写标记失败');

  /// 未使用接口不应被维护器调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 验证维护工具仅操作临时生产runtime，绝不读取用户目录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // 测试独占目录及文件体。
  late Directory directory;
  late Directory audioDirectory;
  late Directory backups;
  late OmniSyncRuntime runtime;
  late NoteAudioPlayerService player;
  late NoteRecorderService recorder;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('omni-notes-cleanup-');
    audioDirectory = await Directory('${directory.path}/audio').create();
    backups = Directory('${directory.path}/backups');
    runtime = await OmniSyncRuntime.openAtPath(
      AuthRepository(const FlutterSecureStorage()),
      '${directory.path}/active.sqlite',
      initializeUpload: false,
    );
    player = NoteAudioPlayerService();
    recorder = NoteRecorderService(
      player: player,
      directoryResolver: () async => audioDirectory,
    );
  });
  tearDown(() async {
    await runtime.close();
    await recorder.dispose();
    await player.dispose();
    await directory.delete(recursive: true);
  });

  /// 调用目标维护器并固定授权路径范围。
  Future<NoteTestCleanupReport> clean({bool execute = false}) =>
      clearNoteTestData(
        runtime: runtime,
        recordings: [NoteCleanupRecordingScope(audioDirectory, recorder)],
        audioRoots: [audioDirectory],
        backupParent: backups,
        execute: execute,
      );

  /// 生成真实可播放WAV，而非伪造数据库文件体。
  Future<File> audio(String name) async {
    // 本次写入或备份的实际文件。
    final File file = File('${audioDirectory.path}/$name.wav');
    return file.writeAsBytes([
      ...NoteWav.header(32000),
      ...List.filled(32000, 0),
    ]);
  }

  /// 写入标准未确认恢复清单，不初始化任何音频硬件。
  Future<File> pending(String noteId, String id, File file) =>
      File('${audioDirectory.path}/$id.pending.json').writeAsString(
        jsonEncode({
          'id': id,
          'noteId': noteId,
          'path': file.path,
          'startedAt': '2026-10-11T00:00:00Z',
          'creationTimezone': 'UTC|+00:00',
        }),
      );

  test('dryrun无副作用，active及回收与纯pending清理保留其他业务mixed队列且二次幂等', () async {
    // 混合上传事务同时包含非笔记任务和正式测试笔记。
    final DateTime now = DateTime.utc(2026, 10, 11);
    // 绑定当前实际数据库的生产笔记仓储。
    final NoteRepository repository = NoteRepository(runtime.database);
    await runtime.database.transaction(() async {
      await runtime.database
          .into(runtime.database.todoItems)
          .insert(
            TodoItemsCompanion.insert(
              id: 'todo',
              title: '保留其他模块',
              scheduledDate: now,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await repository.save(
        const NoteDraft(
          id: 'active',
          body: '测试正文',
          dayKey: '2026-10-11',
          baseRevision: '',
        ),
      );
    });
    await runtime.database
        .into(runtime.database.taxonomyEntries)
        .insert(
          TaxonomyEntriesCompanion.insert(
            id: 'notes-tag',
            module: 'notes',
            kind: 'tag',
            name: '保留定义',
            colorValue: const Value(null),
            createdAt: now,
            updatedAt: now,
          ),
        );
    // 原始文件或恢复清单声明的文件位置。
    final File original = await audio('recorded');
    await repository.addAudio(
      draft: const NoteDraft(
        id: 'recycle',
        body: '回收测试',
        dayKey: '2026-10-11',
        baseRevision: '',
      ),
      id: 'segment',
      localPath: original.path,
      durationMs: 1000,
      mime: 'audio/wav',
    );
    await repository.softDelete('recycle');
    // 未落库但需要清理的原音原件。
    final File pendingAudio = await audio('pending');
    // 当前恢复清单及其归属信息。
    final File manifest = await pending(
      'pure-pending',
      'pending-segment',
      pendingAudio,
    );
    // 原始非笔记队列行必须连ID、事务号和payload都保留。
    final List<Map<String, Object?>> untouched =
        (await runtime.powerSync.getAll('SELECT * FROM ps_crud ORDER BY id'))
            .where(
              (row) => ![
                'note_entries',
                'note_versions',
                'note_audio_segments',
              ].contains((jsonDecode(row['data']! as String) as Map)['type']),
            )
            .toList();
    // 默认只读预览的笔记和队列数量。
    final NoteTestCleanupReport preview = await clean();
    expect(preview.executed, isFalse);
    expect(preview.notes, 2);
    expect(preview.pendingManifests, 1);
    expect(await backups.exists(), isFalse);
    expect(await manifest.exists(), isTrue);
    // 只有完整完成后才返回的维护结果。
    final NoteTestCleanupReport result = await clean(execute: true);
    expect(result.executed, isTrue);
    expect(await File('${result.backupPath}/database.sqlite').exists(), isTrue);
    // 记录备份、SQL提交及文件完成阶段的清单。
    final Map<String, dynamic> journal = jsonDecode(
      await File('${result.backupPath}/manifest.json').readAsString(),
    ) as Map<String, dynamic>;
    expect(journal['phase'], 'completed');
    expect(journal['files'], hasLength(3));
    // 用生产连接重新打开VACUUM备份，证明业务和混合队列均可回滚。
    final OmniSyncRuntime backup = await OmniSyncRuntime.openAtPath(
      AuthRepository(const FlutterSecureStorage()),
      '${result.backupPath}/database.sqlite',
      initializeUpload: false,
    );
    try {
      expect(
        await backup.database.select(backup.database.noteEntries).get(),
        hasLength(2),
      );
      expect(
        await backup.database.select(backup.database.noteAudioLocalFiles).get(),
        hasLength(1),
      );
      expect(
        (await backup.powerSync.getAll('SELECT * FROM ps_crud')).length,
        untouched.length + preview.noteQueueRows,
      );
    } finally {
      await backup.close();
    }
    expect(await original.exists(), isFalse);
    expect(await pendingAudio.exists(), isFalse);
    expect(await manifest.exists(), isFalse);
    expect(await recorder.isPermanentlyDiscarded('pure-pending'), isTrue);
    expect(await recorder.isPermanentlyDiscarded('active'), isTrue);
    expect(
      await runtime.database.select(runtime.database.todoItems).get(),
      hasLength(1),
    );
    expect(
      await runtime.database.select(runtime.database.taxonomyEntries).get(),
      hasLength(1),
    );
    expect(
      await runtime.powerSync.getAll('SELECT * FROM ps_crud ORDER BY id'),
      untouched,
    );
    // 第二次幂等执行的结果。
    final NoteTestCleanupReport again = await clean(execute: true);
    expect(again.notes, 0);
    expect(again.pendingManifests, 0);
    expect(again.noteQueueRows, 0);
    await runtime.close();
    runtime = await OmniSyncRuntime.openAtPath(
      AuthRepository(const FlutterSecureStorage()),
      '${directory.path}/active.sqlite',
      initializeUpload: false,
    );
    expect(
      await runtime.database.select(runtime.database.noteEntries).get(),
      isEmpty,
    );
    expect(
      await runtime.database.select(runtime.database.noteAudioLocalFiles).get(),
      isEmpty,
    );
    expect(
      await runtime.powerSync.getAll('SELECT * FROM ps_crud ORDER BY id'),
      untouched,
    );
  });

  test('其他模块共享文件仍保留，清理前路径越界失败不删除业务或清单', () async {
    // 仍被其他模块引用的共享原件。
    final File shared = await audio('shared');
    // 固定测试创建时间，不依赖运行时钟。
    final DateTime now = DateTime.utc(2026, 10, 11);
    // 绑定当前实际数据库的生产笔记仓储。
    final NoteRepository repository = NoteRepository(runtime.database);
    await repository.addAudio(
      draft: const NoteDraft(
        id: 'note',
        body: '测试',
        dayKey: '2026-10-11',
        baseRevision: '',
      ),
      id: 'segment',
      localPath: shared.path,
      durationMs: 1000,
      mime: 'audio/wav',
    );
    await runtime.database
        .into(runtime.database.inventoryItems)
        .insert(
          InventoryItemsCompanion.insert(
            id: 'inventory',
            name: '保留共享引用',
            imageLocalPath: Value(shared.path),
            createdAt: now,
            updatedAt: now,
          ),
        );
    // 故意置于授权音频目录之外的测试文件。
    final File outside = await File('${directory.path}/outside.wav')
        .writeAsBytes([1, 2, 3]);
    await runtime.database
        .into(runtime.database.noteAudioLocalFiles)
        .insert(
          NoteAudioLocalFilesCompanion.insert(
            id: 'outside',
            localPath: Value(outside.path),
          ),
        );
    await expectLater(
      clean(execute: true),
      throwsA(isA<FileSystemException>()),
    );
    expect(await repository.find('note'), isNotNull);
    expect(await shared.exists(), isTrue);
    expect(await backups.exists(), isFalse);
    await (runtime.database.delete(
      runtime.database.noteAudioLocalFiles,
    )..where((row) => row.id.equals('outside'))).go();
    await clean(execute: true);
    expect(await shared.exists(), isTrue);
    expect(
      await runtime.database.select(runtime.database.inventoryItems).get(),
      hasLength(1),
    );
  });

  test('SQL删除失败完整回滚且不删原件，提交后标记失败不误报成功且可重试', () async {
    // 绑定当前实际数据库的生产笔记仓储。
    final NoteRepository repository = NoteRepository(runtime.database);
    // 原始文件或恢复清单声明的文件位置。
    final File original = await audio('failed');
    await repository.addAudio(
      draft: const NoteDraft(
        id: 'failure',
        body: '不能丢的测试输入',
        dayKey: '2026-10-11',
        baseRevision: '',
      ),
      id: 'failure-segment',
      localPath: original.path,
      durationMs: 1000,
      mime: 'audio/wav',
    );
    // 当前恢复清单及其归属信息。
    final File manifest = await pending('failure', 'failure-segment', original);
    // 注入失败前的完整原始上传队列。
    final List<Map<String, Object?>> initialQueue = await runtime.powerSync
        .getAll('SELECT * FROM ps_crud ORDER BY id');
    await runtime.powerSync.execute(
      "CREATE TRIGGER fail_note_cleanup BEFORE DELETE ON note_entries BEGIN SELECT RAISE(ABORT, 'simulated cleanup SQL failure'); END",
    );
    await expectLater(clean(execute: true), throwsA(isA<Exception>()));
    expect(await repository.find('failure'), isNotNull);
    expect(await original.exists(), isTrue);
    expect(await manifest.exists(), isTrue);
    expect(
      await runtime.powerSync.getAll('SELECT * FROM ps_crud ORDER BY id'),
      initialQueue,
    );
    expect(await recorder.isPermanentlyDiscarded('failure'), isFalse);
    await runtime.powerSync.execute('DROP TRIGGER fail_note_cleanup');
    await expectLater(
      clearNoteTestData(
        runtime: runtime,
        recordings: [
          NoteCleanupRecordingScope(
            audioDirectory,
            _FailingDiscard(audioDirectory),
          ),
        ],
        audioRoots: [audioDirectory],
        backupParent: backups,
        execute: true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await repository.find('failure'), isNull);
    expect(await original.exists(), isTrue);
    expect(await manifest.exists(), isTrue);
    // 失败的文件阶段仍可根据明确清单安全重试。
    expect((await clean(execute: true)).executed, isTrue);
    expect(await original.exists(), isFalse);
    expect(await manifest.exists(), isFalse);
  });

  test('控制库选择active且pending迁移时拒绝，保护历史备份路径', () async {
    // active指向本测试已存在的真实数据库。
    final SyncConnectionStore store = SyncConnectionStore(
      File('${directory.path}/omni_butler_connection.sqlite'),
    );
    try {
      await store.write('active', {'databasePath': runtime.databasePath});
      await store.write('backup:history', {
        'databasePath': '${directory.path}/historical.sqlite',
      });
      expect(await locateNoteCleanupDatabase(directory), runtime.databasePath);
      await store.write('pending', {'id': 'unfinished'});
      await expectLater(locateNoteCleanupDatabase(directory), throwsStateError);
      expect(await store.read('backup:history'), isNotNull);
    } finally {
      await store.close();
    }
  });

  test('preflight rejects missing, traversing and wrong-owner manifests without side effects', () async {
    // A valid business row must survive every rejected preflight.
    final NoteRepository repository = NoteRepository(runtime.database);
    await repository.save(
      const NoteDraft(
        id: 'kept',
        body: 'keep',
        dayKey: '2026-10-11',
        baseRevision: '',
      ),
    );
    // Preserve the original queue as well as the note itself.
    final List<Map<String, Object?>> initialQueue = await runtime.powerSync
        .getAll('SELECT * FROM ps_crud ORDER BY id');
    // The ordinary original remains intact throughout the rejection cases.
    final File original = await audio('invalid');
    // All malformed records use the same test-owned manifest file.
    final File manifest = await pending('kept', 'invalid', original);
    // Each case violates a different preflight invariant.
    for (final Map<String, Object?> invalid in [
      {
        'id': 'invalid',
        'noteId': 'kept',
        'path': p.join(audioDirectory.path, 'absent.wav'),
      },
      {
        'id': 'invalid',
        'noteId': 'kept',
        'path': p.join(audioDirectory.path, '..', 'audio', 'invalid.wav'),
      },
      {'id': 'other-id', 'noteId': 'kept', 'path': original.path},
      {'id': 'invalid', 'noteId': '', 'path': original.path},
    ]) {
      await manifest.writeAsString(jsonEncode(invalid));
      await expectLater(
        clean(execute: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await backups.exists(), isFalse);
      expect(await original.exists(), isTrue);
      expect(await repository.find('kept'), isNotNull);
      expect(
        await runtime.powerSync.getAll('SELECT * FROM ps_crud ORDER BY id'),
        initialQueue,
      );
    }
  });

  test('unfinished filesystem work never writes completed and remains retryable', () async {
    // A pending-only recording exercises completion independently of database rows.
    final File original = await audio('unfinished');
    // The service deliberately leaves this expected manifest in place.
    final File manifest = await pending(
      'unfinished-note',
      'unfinished',
      original,
    );
    await expectLater(
      clearNoteTestData(
        runtime: runtime,
        recordings: [
          NoteCleanupRecordingScope(
            audioDirectory,
            _IncompleteDiscard(audioDirectory),
          ),
        ],
        audioRoots: [audioDirectory],
        backupParent: backups,
        execute: true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    // Inspect the durable phase rather than accepting the service return value.
    final Directory backup =
        (await backups.list().toList()).single as Directory;
    // The committed SQL phase leaves a complete rollback record.
    final Map<String, dynamic> journal = jsonDecode(
      await File(p.join(backup.path, 'manifest.json')).readAsString(),
    ) as Map<String, dynamic>;
    expect(journal['phase'], 'database-cleaned');
    expect(journal['files'], hasLength(2));
    expect(await original.exists(), isTrue);
    expect(await manifest.exists(), isTrue);
    expect((await clean(execute: true)).executed, isTrue);
    expect(await original.exists(), isFalse);
    expect(await manifest.exists(), isFalse);
  });

  test('legacy marker-only originals are backed up and retried with shared protection', () async {
    // The unprotected original survived a previous post-commit delete failure.
    final File residual = await audio('residual');
    // A different marker protects another original even without any business row.
    final File shared = await audio('marker-shared');
    // The marker owner is part of the existing deterministic filename format.
    const String owner = 'old-note';
    // No pending manifest remains; the durable marker is the only retry evidence.
    final File marker = File(
      p.join(
        audioDirectory.path,
        '${const Uuid().v5(Namespace.url.value, 'notes-deleted:$owner')}.deleted.json',
      ),
    );
    await marker.writeAsString(
      jsonEncode({
        'noteId': owner,
        'protectedPaths': [shared.path],
        'pendingPaths': [
          residual.path,
          shared.path,
          p.join(audioDirectory.path, 'already-gone.wav'),
        ],
      }),
    );
    // Both surviving originals are backed up before the old retry is executed.
    final NoteTestCleanupReport result = await clean(execute: true);
    // Verify the exact durable completion evidence.
    final Map<String, dynamic> journal = jsonDecode(
      await File(p.join(result.backupPath!, 'manifest.json')).readAsString(),
    ) as Map<String, dynamic>;
    expect(journal['phase'], 'completed');
    expect(journal['files'], hasLength(2));
    expect(await residual.exists(), isFalse);
    expect(await shared.exists(), isTrue);
    expect((await clean(execute: true)).executed, isTrue);
    expect(await shared.exists(), isTrue);
  });

  test(
    'mismatched scope and shared pending owners fail before backup or SQL',
    () async {
      // The recorder remains bound to audioDirectory while the scope points elsewhere.
      final Directory other = await Directory(
        p.join(directory.path, 'other-audio'),
      ).create();
      await expectLater(
        clearNoteTestData(
          runtime: runtime,
          recordings: [NoteCleanupRecordingScope(other, recorder)],
          audioRoots: [audioDirectory, other],
          backupParent: backups,
          execute: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await backups.exists(), isFalse);
      // Different pending owners cannot silently create circular durable protection.
      final File shared = await audio('shared-pending');
      // Both original manifests must remain available for manual conflict resolution.
      final File first = await pending('owner-a', 'pending-a', shared);
      // This owner independently claims the same physical original.
      final File second = await pending('owner-b', 'pending-b', shared);
      await expectLater(
        clean(execute: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await backups.exists(), isFalse);
      expect(await shared.exists(), isTrue);
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isTrue);
    },
  );

  test(
    'related drafts outside the maintenance whitelist fail before mutation',
    () async {
      // A formal note with a related draft requires the separate product deletion flow.
      final NoteRepository repository = NoteRepository(runtime.database);
      await repository.save(
        const NoteDraft(
          id: 'draft-note',
          body: 'keep',
          dayKey: '2026-10-11',
          baseRevision: '',
        ),
      );
      await runtime.database
          .into(runtime.database.noteLocalDrafts)
          .insert(
            NoteLocalDraftsCompanion.insert(
              id: 'local-draft',
              noteId: 'draft-note',
              dayKey: '2026-10-11',
              baseRevision: '',
              updatedAt: DateTime.utc(2026),
            ),
          );
      await expectLater(clean(execute: true), throwsStateError);
      expect(await backups.exists(), isFalse);
      expect(await repository.find('draft-note'), isNotNull);
      expect(
        (await runtime.database.select(runtime.database.noteLocalDrafts).get())
            .single
            .discarded,
        isFalse,
      );
    },
  );

  if (Platform.isWindows) {
    test('mixed real aliases preserve other business references and stored spelling', () async {
      // Native resolution supplies a genuine long spelling even under short TEMP.
      final String longRoot = await directory.resolveSymbolicLinks();
      // Native 8.3 lookup must produce a distinct alias or fail the test.
      final String shortRoot = await shortPathOf(directory);
      expect(p.equals(longRoot, shortRoot), isFalse);
      // Exercise both directions of manifest versus protection aliasing.
      for (final bool shortManifest in [true, false]) {
        // Each direction uses a different original and note owner.
        final String id = shortManifest ? 'short-manifest' : 'long-manifest';
        // The file is physically created only once.
        final File shared = await audio(id);
        // Persisted audio and protection paths intentionally use opposite aliases.
        final String stored = p.join(
          shortManifest ? shortRoot : longRoot,
          'audio',
          '$id.wav',
        );
        // An unrelated module must protect the same file by the other spelling.
        final String protected = p.join(
          shortManifest ? longRoot : shortRoot,
          'audio',
          '$id.wav',
        );
        await pending(id, id, File(stored));
        await NoteRepository(runtime.database).addAudio(
          draft: NoteDraft(
            id: id,
            body: 'alias',
            dayKey: '2026-10-11',
            baseRevision: '',
          ),
          id: id,
          localPath: stored,
          durationMs: 1000,
          mime: 'audio/wav',
        );
        await runtime.database
            .into(runtime.database.inventoryItems)
            .insert(
              InventoryItemsCompanion.insert(
                id: id,
                name: 'shared',
                imageLocalPath: Value(protected),
                createdAt: DateTime.utc(2026),
                updatedAt: DateTime.utc(2026),
              ),
            );
        // The scope itself also uses the alias opposite to the stored manifest.
        final NoteTestCleanupReport result = await clearNoteTestData(
          runtime: runtime,
          recordings: [
            NoteCleanupRecordingScope(
              Directory(p.dirname(protected)),
              recorder,
            ),
          ],
          audioRoots: [audioDirectory],
          backupParent: backups,
          execute: true,
        );
        expect(await shared.exists(), isTrue);
        // Backups retain the original stored spelling for exact restoration.
        final Map<String, dynamic> journal = jsonDecode(
          await File(p.join(result.backupPath!, 'manifest.json'))
              .readAsString(),
        ) as Map<String, dynamic>;
        expect(
          (journal['files'] as List).any(
            (item) =>
                item['originalPath'] == stored && item['protected'] == true,
          ),
          isTrue,
        );
        expect(
          (await runtime.database.select(runtime.database.inventoryItems).get())
              .last
              .imageLocalPath,
          protected,
        );
      }
    });

    test('backup aliases and redirected ancestors are rejected before directory creation', () async {
      // One pending original makes accidental cleanup observable.
      final File original = await audio('backup-boundary');
      // This manifest must survive every rejected backup destination.
      final File manifest = await pending(
        'backup-note',
        'backup-boundary',
        original,
      );
      // The actual short alias bypassed the old textual boundary comparison.
      final String shortAudio = await shortPathOf(audioDirectory);
      // A junction models an existing ancestor redirecting into the audio root.
      final Link junction = Link(p.join(directory.path, 'audio-alias'));
      // The subprocess creates only a junction inside this fixture tree.
      final ProcessResult process = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'New-Item -ItemType Junction -Path $env:OMNI_TEST_LINK -Target $env:OMNI_TEST_TARGET -ErrorAction Stop | Out-Null',
        ],
        environment: {
          'OMNI_TEST_LINK': junction.path,
          'OMNI_TEST_TARGET': audioDirectory.path,
        },
      );
      expect(process.exitCode, 0, reason: process.stderr.toString());
      try {
        // Neither spelling may create even the first missing backup component.
        for (final String parent in [shortAudio, junction.path]) {
          await expectLater(
            clearNoteTestData(
              runtime: runtime,
              recordings: [NoteCleanupRecordingScope(audioDirectory, recorder)],
              audioRoots: [audioDirectory],
              backupParent: Directory(p.join(parent, 'future', 'backup')),
              execute: true,
            ),
            throwsStateError,
          );
          expect(
            await Directory(p.join(audioDirectory.path, 'future')).exists(),
            isFalse,
          );
          expect(await original.exists(), isTrue);
          expect(await manifest.exists(), isTrue);
        }
      } finally {
        await junction.delete();
      }
    });
  }
}
