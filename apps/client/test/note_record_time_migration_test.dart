import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/features/notes/data/note_local_draft_repository.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';

/// 真实SQLite升级和旧快照兼容须保留用户原始归档信息。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v23真实文件升级当前版本，正式记录与草稿补空字段并保持原值', () async {
    // 独占临时目录不接触用户数据库。
    final Directory directory = await Directory.systemTemp.createTemp(
      'notes-record-v23-',
    );
    // 重开同一文件触发Drift真实迁移。
    final File file = File('${directory.path}/notes.sqlite');
    // 先创建可删除新增列的完整结构。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(file));
    // 固定旧记录真实创建时间。
    final DateTime created = DateTime.utc(2024, 1, 1, 23, 59, 58);
    try {
      await database
          .into(database.noteEntries)
          .insert(
            NoteEntriesCompanion.insert(
              id: 'legacy',
              body: const Value('原正文'),
              dayKey: '2024-01-03',
              revision: 'original-revision',
              createdAt: created,
              creationTimezone: const Value('CST|+08:00'),
              updatedAt: created,
            ),
          );
      await database
          .into(database.noteLocalDrafts)
          .insert(
            NoteLocalDraftsCompanion.insert(
              id: 'legacy-draft',
              noteId: 'legacy',
              body: const Value('未提交正文'),
              dayKey: '2024-01-03',
              baseRevision: 'original-revision',
              createdAt: Value(created),
              creationTimezone: const Value('CST|+08:00'),
              updatedAt: created,
            ),
          );
      for (final String table in ['note_entries', 'note_local_drafts']) {
        await database.customStatement(
          'ALTER TABLE $table DROP COLUMN record_time_seconds',
        );
        await database.customStatement(
          'ALTER TABLE $table DROP COLUMN record_utc_offset_minutes',
        );
      }
      await database.customStatement('PRAGMA user_version = 23');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      // 正式记录保留原日期、正文、版本和创建元数据。
      final NoteEntryRecord note = await database
          .select(database.noteEntries)
          .getSingle();
      expect(note.body, '原正文');
      expect(note.dayKey, '2024-01-03');
      expect(note.revision, 'original-revision');
      expect(note.createdAt.toUtc(), created);
      expect(note.updatedAt.toUtc(), created);
      expect(note.recordTimeSeconds, isNull);
      expect(note.recordUtcOffsetMinutes, isNull);
      expect(note.recordTime.label, '2024-01-03 07:59:58');
      // 旧本机草稿同样可恢复且不会被判为主动时间修改。
      final NoteLocalDraftRecord local = await database
          .select(database.noteLocalDrafts)
          .getSingle();
      expect(local.recordTimeSeconds, isNull);
      expect(local.recordUtcOffsetMinutes, isNull);
      expect(noteDraftFromLocal(local).recordTime.label, '2024-01-03 07:59:58');
      expect(local.body, '未提交正文');
      expect(local.dateEdited, isFalse);
      expect(
        (await database.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        25,
      );
      expect(
        await database.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('v8快照仅在内存补空记录字段，保留原始输入和换服协议', () {
    // 所有当前业务表均存在，仅笔记行缺少v9新增字段。
    final Map<String, dynamic> tables = {
      for (final String name in SyncSnapshot.tableNames)
        name: <Map<String, Object?>>[],
    };
    // 模拟真实旧版SQLite行，不推导或改写历史时间。
    final Map<String, Object?> note = {
      'id': 'legacy',
      'day_key': '2024-01-03',
      'created_at': '2024-01-01T23:59:58Z',
      'creation_timezone': 'CST|+08:00',
    };
    // 本机草稿时间字段与正式笔记同步兼容。
    final Map<String, Object?> draft = {
      'id': 'draft',
      'note_id': 'legacy',
      'day_key': '2024-01-03',
    };
    tables['note_entries'] = [note];
    tables['note_local_drafts'] = [draft];
    // 解析只规范化副本，不破坏旧备份摘要依赖的原始结构。
    final SyncSnapshot restored = SyncSnapshot.fromJson({
      'version': 8,
      'tables': tables,
      'pendingOperations': 2,
    });
    for (final String table in ['note_entries', 'note_local_drafts']) {
      expect(
        restored.tables[table]!.single,
        containsPair('record_time_seconds', null),
      );
      expect(
        restored.tables[table]!.single,
        containsPair('record_utc_offset_minutes', null),
      );
      expect(restored.tables[table]!.single['day_key'], '2024-01-03');
    }
    expect(note.containsKey('record_time_seconds'), isFalse);
    expect(draft.containsKey('record_utc_offset_minutes'), isFalse);
    expect(restored.pendingOperations, 2);
    expect(restored.toJson()['version'], 10);
    expect(SyncSnapshot.migrationProtocolVersion, 3);
    // 正式同步白名单包括秒数和偏移，本机草稿仍不进入换服操作。
    final Map<String, Object?> operation = restored.operations.single;
    expect(operation['table'], 'note_entries');
    expect(operation['data'] as Map, containsPair('record_time_seconds', null));
    expect(
      operation['data'] as Map,
      containsPair('record_utc_offset_minutes', null),
    );
  });
}
