import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';

/// 整理任务仅升级本机字段，旧录音和旧快照不产生模型授权。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('真实v25升级保留ASR数据且历史整理默认关闭', () async {
    // 只在本测试拥有的临时目录验证迁移。
    final Directory directory = await Directory.systemTemp.createTemp(
      'polish-v25-',
    );
    // 重开同一真实SQLite文件触发迁移。
    final File file = File('${directory.path}/notes.sqlite');
    // 初始创建当前表，移除新增列模拟升级前真实结构。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await database
          .into(database.noteAudioLocalFiles)
          .insert(
            NoteAudioLocalFilesCompanion.insert(
              id: 'existing-audio',
              localPath: const Value('retained.wav'),
              recognitionId: const Value('asr-task'),
              recognitionState: const Value('succeeded'),
              insertedRevision: const Value('adopted-revision'),
              candidateTranscript: const Value('原有识别候选'),
              consent: const Value(true),
            ),
          );
      for (final String column in <String>[
        'polish_id',
        'polish_operation_id',
        'polish_state',
        'polished_text',
        'polish_adopted_hash',
        'polish_error',
        'polish_recognition_id',
        'polish_source_hash',
        'fallback_revision',
        'fallback_start',
        'fallback_end',
      ]) {
        await database.customStatement(
          'ALTER TABLE note_audio_local_files DROP COLUMN $column',
        );
      }
      await database.customStatement('PRAGMA user_version = 25');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      // 原有识别与正文采用数据完全保留。
      final NoteAudioLocalFileRecord row = await database
          .select(database.noteAudioLocalFiles)
          .getSingle();
      expect(row.recognitionId, 'asr-task');
      expect(row.recognitionState, 'succeeded');
      expect(row.insertedRevision, 'adopted-revision');
      expect(row.candidateTranscript, '原有识别候选');
      expect(row.consent, isTrue);
      expect(row.polishState, 'disabled');
      expect(row.polishId, isNull);
      expect(row.polishOperationId, isNull);
      expect(row.polishedText, isNull);
      expect(row.polishAdoptedHash, isNull);
      expect(row.fallbackRevision, isNull);
      expect(
        (await database.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        26,
      );
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('v10快照补空整理字段且不修改原始备份或同步操作', () {
    // 原始旧快照的本机任务行。
    final Map<String, Object?> old = <String, Object?>{
      'id': 'audio',
      'recognition_id': 'old-asr',
      'candidate_transcript': '旧候选',
    };
    // 完整快照表集，避免无关业务表影响格式迁移验证。
    final Map<String, dynamic> tables = <String, dynamic>{
      for (final String name in SyncSnapshot.tableNames)
        name: <Map<String, Object?>>[],
      'note_audio_local_files': <Map<String, Object?>>[old],
    };
    // 内存升级的新副本。
    final SyncSnapshot restored = SyncSnapshot.fromJson(<String, dynamic>{
      'version': 10,
      'tables': tables,
      'pendingOperations': 0,
    });
    expect(
      restored.tables['note_audio_local_files']!.single['polish_state'],
      'disabled',
    );
    expect(
      restored.tables['note_audio_local_files']!.single['polish_operation_id'],
      isNull,
    );
    expect(
      restored.tables['note_audio_local_files']!.single['polish_adopted_hash'],
      isNull,
    );
    expect(old.containsKey('polish_state'), isFalse);
    expect(restored.operations, isEmpty);
    expect(restored.toJson()['version'], 11);
  });
}
