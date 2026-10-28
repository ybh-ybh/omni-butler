import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/audio/note_wav.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../tool/clear_note_test_data.dart';

/// Delegates one completed deletion before failing the next owner.
class _PartialDiscard implements NoteRecorderService {
  /// Bind failure injection to the real isolated recorder.
  _PartialDiscard(this.delegate);

  /// The recorder performs real manifest and audio cleanup in the fixture.
  final NoteRecorderService delegate;

  /// Remember which owner's deletion completed before the injected failure.
  String? completedOwner;

  @override
  NoteRecordingState get state => delegate.state;

  @override
  Future<String> recordingDirectoryIdentity() =>
      delegate.recordingDirectoryIdentity();

  @override
  Future<void> discardPendingForNote(
    String noteId, {
    String? draftId,
    String? recordingId,
    Set<String> protectedPaths = const {},
  }) async {
    if (completedOwner != null) {
      throw const FileSystemException('injected post-commit deletion failure');
    }
    await delegate.discardPendingForNote(
      noteId,
      draftId: draftId,
      recordingId: recordingId,
      protectedPaths: protectedPaths,
    );
    completedOwner = noteId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Exercise recovery only with an isolated runtime and synthetic WAV files.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // Every test owns an independent parent and audio directory.
  late Directory root;
  // All originals and recovery manifests are inside this test-only scope.
  late Directory audioDirectory;
  // The maintenance tool exclusively owns this test backup parent.
  late Directory backupParent;
  // The database runtime is never pointed at the user's application data.
  late OmniSyncRuntime runtime;
  // A real recorder is used only for its file and marker operations.
  late NoteRecorderService recorder;
  // The injected player remains idle and owns no microphone session.
  late NoteAudioPlayerService player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('note-resume-isolated-');
    audioDirectory = await Directory(p.join(root.path, 'audio')).create();
    backupParent = Directory(p.join(root.path, 'backups'));
    runtime = await OmniSyncRuntime.openAtPath(
      AuthRepository(const FlutterSecureStorage()),
      p.join(root.path, 'active.sqlite'),
      initializeUpload: false,
    );
    player = NoteAudioPlayerService();
    recorder = NoteRecorderService(
      player: player,
      android: false,
      directoryResolver: () async => audioDirectory,
    );
  });

  tearDown(() async {
    await runtime.close();
    await recorder.dispose();
    await player.dispose();
    await root.delete(recursive: true);
  });

  /// Create a valid, independent test audio original.
  Future<File> createAudio(String name) async {
    // The file exists only under this test's isolated audio directory.
    final File file = File(p.join(audioDirectory.path, '$name.wav'));
    return file.writeAsBytes([
      ...NoteWav.header(32000),
      ...List.filled(32000, 0),
    ]);
  }

  /// Create a recoverable original with the production manifest format.
  Future<File> createManifest(String owner, String id, File original) async {
    // The manifest filename and id must agree during cleanup preflight.
    final File file = File(p.join(audioDirectory.path, '$id.pending.json'));
    await file.writeAsString(
      jsonEncode({
        'id': id,
        'noteId': owner,
        'path': original.path,
        'startedAt': '2026-10-11T00:00:00Z',
        'creationTimezone': 'UTC|+00:00',
      }),
    );
    return file;
  }

  /// Run maintenance with the same explicit roots and optional journal.
  Future<NoteTestCleanupReport> clean({
    bool execute = false,
    Directory? resumeFrom,
    NoteRecorderService? recordingService,
    OmniSyncRuntime? databaseRuntime,
  }) => clearNoteTestData(
    runtime: databaseRuntime ?? runtime,
    recordings: [
      NoteCleanupRecordingScope(audioDirectory, recordingService ?? recorder),
    ],
    audioRoots: [audioDirectory],
    backupParent: backupParent,
    execute: execute,
    resumeFrom: resumeFrom,
  );

  /// Prepare two target originals and fail after one real deletion completes.
  Future<
    ({
      Directory backup,
      String completedOwner,
      Map<String, File> files,
      File shared,
    })
  >
  partialCleanup({
    bool absentRetryPath = false,
    bool addTextNote = false,
  }) async {
    // Distinct note IDs ensure the injected failure occurs on the second owner.
    final Map<String, File> files = {
      'note-a': await createAudio('note-a'),
      'note-b': await createAudio('note-b'),
    };
    // One extra target original is shared with non-note inventory data.
    final File shared = await createAudio('shared-original');
    // All note writes use the same isolated production repository.
    final NoteRepository repository = NoteRepository(runtime.database);
    for (final MapEntry<String, File> entry in files.entries) {
      await repository.addAudio(
        draft: NoteDraft(
          id: entry.key,
          body: 'test note ${entry.key}',
          dayKey: '2026-10-11',
          baseRevision: '',
        ),
        id: '${entry.key}-segment',
        localPath: entry.value.path,
        durationMs: 1000,
        mime: 'audio/wav',
      );
      await createManifest(entry.key, '${entry.key}-segment', entry.value);
    }
    await repository.addAudio(
      draft: const NoteDraft(
        id: 'note-a',
        body: 'test note note-a',
        dayKey: '2026-10-11',
        baseRevision: '',
      ),
      id: 'shared-segment',
      localPath: shared.path,
      durationMs: 1000,
      mime: 'audio/wav',
    );
    if (addTextNote) {
      await repository.save(
        const NoteDraft(
          id: 'note-z-text',
          body: 'text only',
          dayKey: '2026-10-11',
          baseRevision: '',
        ),
      );
    }
    // Inventory remains the source of truth for this shared original.
    final DateTime now = DateTime.utc(2026, 10, 11);
    await runtime.database
        .into(runtime.database.inventoryItems)
        .insert(
          InventoryItemsCompanion.insert(
            id: 'non-note-item',
            name: 'retain shared original',
            imageLocalPath: Value(shared.path),
            createdAt: now,
            updatedAt: now,
          ),
        );
    if (absentRetryPath) {
      // A legacy marker may refer to a file already absent before backup.
      final String markerName =
          '${const Uuid().v5(Namespace.url.value, 'notes-deleted:note-a')}.deleted.json';
      // Persist the unbacked path while leaving the original file absent.
      final File marker = File(p.join(audioDirectory.path, markerName));
      await marker.writeAsString(
        jsonEncode({
          'noteId': 'note-a',
          'protectedPaths': <String>[],
          'pendingPaths': [p.join(audioDirectory.path, 'already-absent.wav')],
        }),
      );
    }
    // The wrapper records the actually completed owner regardless of set order.
    final _PartialDiscard failing = _PartialDiscard(recorder);
    await expectLater(
      clean(execute: true, recordingService: failing),
      throwsA(isA<FileSystemException>()),
    );
    expect(failing.completedOwner, isNotNull);
    // A single backup must exist before either filesystem mutation.
    final Directory backup =
        (await backupParent.list().toList()).single as Directory;
    // The journal is the only permitted source for resuming this run.
    final Map<String, dynamic> manifest = jsonDecode(
      await File(p.join(backup.path, 'manifest.json')).readAsString(),
    ) as Map<String, dynamic>;
    expect(manifest['phase'], 'database-cleaned');
    expect(await File(p.join(backup.path, 'database.sqlite')).exists(), isTrue);
    expect(manifest['files'], isNotEmpty);
    for (final dynamic item in manifest['files'] as List) {
      // The backup must match the journal's complete length and digest.
      final File copy = File(item['backupPath'] as String);
      expect(await copy.exists(), isTrue);
      expect(await copy.length(), item['byteSize']);
      expect(
        (await sha256.bind(copy.openRead()).first).toString(),
        item['sha256'],
      );
    }
    expect(await files[failing.completedOwner]!.exists(), isFalse);
    expect(
      await files.entries
          .singleWhere((item) => item.key != failing.completedOwner)
          .value
          .exists(),
      isTrue,
    );
    expect(await shared.exists(), isTrue);
    expect(
      await runtime.database.select(runtime.database.noteAudioLocalFiles).get(),
      isNotEmpty,
    );
    expect(
      await runtime.database.select(runtime.database.noteEntries).get(),
      isEmpty,
    );
    return (
      backup: backup,
      completedOwner: failing.completedOwner!,
      files: files,
      shared: shared,
    );
  }

  test('explicit resume finishes an interrupted file phase and remains idempotent', () async {
    // The first owner is deleted, while the second owner remains recoverable.
    final state = await partialCleanup();
    // The committed non-note queue must survive both rejected and resumed runs.
    final List<Map<String, Object?>> remainingQueue = await runtime.powerSync
        .getAll('SELECT * FROM ps_crud ORDER BY id');
    await expectLater(
      clean(execute: true),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(clean(resumeFrom: state.backup), throwsStateError);
    // Resume is explicit and reuses the existing backup instead of deleting SQL again.
    final NoteTestCleanupReport result = await clean(
      execute: true,
      resumeFrom: state.backup,
    );
    expect(result.executed, isTrue);
    expect(
      await Directory(result.backupPath!).resolveSymbolicLinks(),
      await state.backup.resolveSymbolicLinks(),
    );
    for (final File file in state.files.values) {
      expect(await file.exists(), isFalse);
    }
    expect(await state.shared.exists(), isTrue);
    expect(
      await runtime.database.select(runtime.database.noteAudioLocalFiles).get(),
      isEmpty,
    );
    expect(
      await runtime.database.select(runtime.database.inventoryItems).get(),
      hasLength(1),
    );
    expect(
      await runtime.powerSync.getAll('SELECT * FROM ps_crud ORDER BY id'),
      remainingQueue,
    );
    // A completed journal can be safely presented again without new mutation.
    expect(
      (await clean(execute: true, resumeFrom: state.backup)).executed,
      isTrue,
    );
    expect(await state.shared.exists(), isTrue);
    expect((await backupParent.list().toList()), hasLength(1));
    expect(
      (jsonDecode(
        await File(p.join(state.backup.path, 'manifest.json')).readAsString(),
      ) as Map)['phase'],
      'completed',
    );
  });

  test('resume rejects a different database without mutating either runtime', () async {
    // Keep the original interrupted state available after the rejected attempt.
    final state = await partialCleanup();
    // A different database file is never an acceptable recovery target.
    final OmniSyncRuntime other = await OmniSyncRuntime.openAtPath(
      AuthRepository(const FlutterSecureStorage()),
      p.join(root.path, 'other.sqlite'),
      initializeUpload: false,
    );
    try {
      await expectLater(
        clean(execute: true, resumeFrom: state.backup, databaseRuntime: other),
        throwsStateError,
      );
      expect(
        await other.database.select(other.database.noteEntries).get(),
        isEmpty,
      );
      expect(
        await state.files.entries
            .singleWhere((item) => item.key != state.completedOwner)
            .value
            .exists(),
        isTrue,
      );
      expect(await state.shared.exists(), isTrue);
      expect(
        (jsonDecode(
          await File(p.join(state.backup.path, 'manifest.json')).readAsString(),
        ) as Map)['phase'],
        'database-cleaned',
      );
    } finally {
      await other.close();
    }
  });

  test('resume rejects altered backup bytes without deleting the remaining original', () async {
    // The old SQL has committed, but one file still needs safe recovery.
    final state = await partialCleanup();
    // Modify a backup object while keeping its journal digest unchanged.
    final Map<String, dynamic> manifest = jsonDecode(
      await File(p.join(state.backup.path, 'manifest.json')).readAsString(),
    ) as Map<String, dynamic>;
    // Select the first audio copy to simulate backup corruption.
    final Map<String, dynamic> copy =
        (manifest['files'] as List).first as Map<String, dynamic>;
    await File(copy['backupPath'] as String).writeAsBytes([1, 2, 3]);
    await expectLater(
      clean(execute: true, resumeFrom: state.backup),
      throwsStateError,
    );
    expect(
      await state.files.entries
          .singleWhere((item) => item.key != state.completedOwner)
          .value
          .exists(),
      isTrue,
    );
    expect(await state.shared.exists(), isTrue);
    expect(
      await runtime.database.select(runtime.database.noteAudioLocalFiles).get(),
      isNotEmpty,
    );
    expect(
      (jsonDecode(
        await File(p.join(state.backup.path, 'manifest.json')).readAsString(),
      ) as Map)['phase'],
      'database-cleaned',
    );
  });

  test(
    'resume rejects a changed remaining original before file cleanup',
    () async {
      // One source audio remains after the injected partial deletion.
      final state = await partialCleanup();
      // Only mutate the isolated remaining file to simulate an intervening change.
      final File remaining = state.files.entries
          .singleWhere((item) => item.key != state.completedOwner)
          .value;
      await remaining.writeAsBytes([1, 2, 3, 4]);
      await expectLater(
        clean(execute: true, resumeFrom: state.backup),
        throwsStateError,
      );
      expect(await remaining.readAsBytes(), [1, 2, 3, 4]);
      expect(await state.shared.exists(), isTrue);
      expect(
        await runtime.database
            .select(runtime.database.noteAudioLocalFiles)
            .get(),
        isNotEmpty,
      );
    },
  );

  test('resume refuses when a protected original is missing', () async {
    // The protected shared original belongs to both test data and inventory.
    final state = await partialCleanup();
    await state.shared.delete();
    await expectLater(
      clean(execute: true, resumeFrom: state.backup),
      throwsStateError,
    );
    expect(
      await state.files.entries
          .singleWhere((item) => item.key != state.completedOwner)
          .value
          .exists(),
      isTrue,
    );
    expect(
      await runtime.database.select(runtime.database.inventoryItems).get(),
      hasLength(1),
    );
    expect(
      await runtime.database.select(runtime.database.noteAudioLocalFiles).get(),
      isNotEmpty,
    );
  });

  test(
    'resume rejects recreated target business data without removing it',
    () async {
      // Interrupted cleanup must not overwrite a subsequent user change.
      final state = await partialCleanup();
      // Recreate one target note after the original database transaction committed.
      final NoteRepository repository = NoteRepository(runtime.database);
      await repository.save(
        NoteDraft(
          id: state.completedOwner,
          body: 'recreated content',
          dayKey: '2026-10-11',
          baseRevision: '',
        ),
      );
      // Capture the new queue so rejection also proves no queue mutation.
      final List<Map<String, Object?>> queue = await runtime.powerSync.getAll(
        'SELECT * FROM ps_crud ORDER BY id',
      );
      await expectLater(
        clean(execute: true, resumeFrom: state.backup),
        throwsStateError,
      );
      expect(
        (await repository.find(state.completedOwner))!.body,
        'recreated content',
      );
      expect(
        await runtime.powerSync.getAll('SELECT * FROM ps_crud ORDER BY id'),
        queue,
      );
      expect(
        await state.files.entries
            .singleWhere((item) => item.key != state.completedOwner)
            .value
            .exists(),
        isTrue,
      );
      expect(await state.shared.exists(), isTrue);
    },
  );

  test('resume creates the remaining text-only note deletion marker', () async {
    // A text-only note may not have had its marker written before failure.
    final state = await partialCleanup(addTextNote: true);
    expect(await recorder.isPermanentlyDiscarded('note-z-text'), isFalse);
    await clean(execute: true, resumeFrom: state.backup);
    expect(await recorder.isPermanentlyDiscarded('note-z-text'), isTrue);
  });

  test('resume rejects recreation of an originally absent marker original', () async {
    // The journal must distinguish absent retry paths from backed-up originals.
    final state = await partialCleanup(absentRetryPath: true);
    // A newly created file has no verified backup and cannot be deleted.
    final File recreated = File(
      p.join(audioDirectory.path, 'already-absent.wav'),
    );
    await recreated.writeAsBytes([1, 2, 3]);
    await expectLater(
      clean(execute: true, resumeFrom: state.backup),
      throwsStateError,
    );
    expect(await recreated.readAsBytes(), [1, 2, 3]);
    expect(
      await state.files.entries
          .singleWhere((item) => item.key != state.completedOwner)
          .value
          .exists(),
      isTrue,
    );
  });

  test(
    'resume rejects a legacy journal without the required baseline',
    () async {
      // An old journal cannot prove what was deleted or protected.
      final state = await partialCleanup();
      // Remove the version marker to simulate a legacy journal.
      final File journal = File(p.join(state.backup.path, 'manifest.json'));
      // Retain all other fields to verify the version gate specifically.
      final Map<String, dynamic> value =
          jsonDecode(await journal.readAsString()) as Map<String, dynamic>;
      value.remove('schemaVersion');
      await journal.writeAsString(jsonEncode(value));
      await expectLater(
        clean(execute: true, resumeFrom: state.backup),
        throwsStateError,
      );
      expect(
        await state.files.entries
            .singleWhere((item) => item.key != state.completedOwner)
            .value
            .exists(),
        isTrue,
      );
      expect(await state.shared.exists(), isTrue);
    },
  );

  test(
    'resume rejects a modified database backup before touching originals',
    () async {
      // The database backup is required even if audio backups remain intact.
      final state = await partialCleanup();
      // Corrupt only this isolated backup, never the active database.
      final File databaseBackup = File(
        p.join(state.backup.path, 'database.sqlite'),
      );
      await databaseBackup.writeAsBytes([1, 2, 3]);
      await expectLater(
        clean(execute: true, resumeFrom: state.backup),
        throwsStateError,
      );
      expect(
        await state.files.entries
            .singleWhere((item) => item.key != state.completedOwner)
            .value
            .exists(),
        isTrue,
      );
      expect(await state.shared.exists(), isTrue);
    },
  );
}
