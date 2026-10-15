import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/sync_note_audio_backup.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';

import 'support/recycle_bin_fixture.dart';

/// 覆盖真实升级、旧快照、独立回收站和本机录音备份的业务边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('v19文件增加多图和本机图片草稿表，原笔记和正文版本不改变', () async {
    // 真实旧版文件只移除本次新增表，不触碰用户数据库。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_notes_v19_',
    );
    final File file = File('${directory.path}/old.sqlite');
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(file));
    final DateTime now = DateTime(2026, 10, 15);
    try {
      await database
          .into(database.noteEntries)
          .insert(
            NoteEntriesCompanion.insert(
              id: 'kept-note',
              body: const Value('保持原正文'),
              dayKey: '2026-10-15',
              revision: 'kept-revision',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database.customStatement('DROP TABLE note_images');
      await database.customStatement('DROP TABLE note_draft_images');
      await database.customStatement('PRAGMA user_version = 19');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      expect(
        (await database.select(database.noteEntries).get()).single.revision,
        'kept-revision',
      );
      expect(
        (await database.select(database.noteEntries).get()).single.body,
        '保持原正文',
      );
      expect(await database.select(database.noteImages).get(), isEmpty);
      expect(await database.select(database.noteDraftImages).get(), isEmpty);
      expect(
        (await database.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        20,
      );
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('v18文件升级仅移除笔记类别，正文标签和其他模块分类完整保留', () async {
    // 独占的旧库测试目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_notes_v18_',
    );
    // 重开同一个文件触发真实Drift升级。
    final File file = File('${directory.path}/old.sqlite');
    // 用当前结构构造旧版类别列，避免依赖生产库。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(file));
    // 固定业务时刻，升级不应改写。
    final DateTime now = DateTime(2026, 10, 12, 8);
    try {
      await database
          .into(database.noteEntries)
          .insert(
            NoteEntriesCompanion.insert(
              id: 'note',
              body: const Value('标题\n保留正文'),
              dayKey: '2026-10-11',
              tags: const Value('["note-tag"]'),
              revision: 'revision',
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final (String, String, String) item in [
        ('note-category', 'notes', 'category'),
        ('note-tag', 'notes', 'tag'),
        ('inventory-category', 'inventory', 'category'),
      ]) {
        await database
            .into(database.taxonomyEntries)
            .insert(
              TaxonomyEntriesCompanion.insert(
                id: item.$1,
                module: item.$2,
                kind: item.$3,
                name: item.$1,
                colorValue: 0,
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      await database
          .into(database.recordTaxonomyLinks)
          .insert(
            RecordTaxonomyLinksCompanion.insert(
              id: 'old-link',
              module: 'notes',
              recordId: 'note',
              taxonomyId: 'note-category',
              createdAt: now,
            ),
          );
      await database.customStatement(
        'ALTER TABLE note_entries ADD COLUMN category_id TEXT',
      );
      await database.customStatement(
        'ALTER TABLE note_entries ADD COLUMN category_name TEXT',
      );
      await database.customStatement(
        "UPDATE note_entries SET category_id = 'note-category', category_name = '旧类别'",
      );
      await database.customStatement('DROP TABLE note_draft_audio_segments');
      await database.customStatement('DROP TABLE note_local_drafts');
      await database.customStatement('PRAGMA user_version = 18');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      // 正式内容与归档元数据逐项验证。
      final NoteEntryRecord note = await database
          .select(database.noteEntries)
          .getSingle();
      expect(note.body, '标题\n保留正文');
      expect(note.tags, '["note-tag"]');
      expect(note.dayKey, '2026-10-11');
      expect(note.revision, 'revision');
      expect(note.createdAt, now);
      expect(note.updatedAt, now);
      expect(
        (await database.customSelect('PRAGMA table_info(note_entries)').get())
            .map((row) => row.read<String>('name')),
        isNot(anyOf(contains('category_id'), contains('category_name'))),
      );
      expect(
        (await database.select(database.taxonomyEntries).get()).map(
          (row) => row.id,
        ),
        unorderedEquals(['note-tag', 'inventory-category']),
      );
      expect(
        await database.select(database.recordTaxonomyLinks).get(),
        isEmpty,
      );
      expect(await database.select(database.noteLocalDrafts).get(), isEmpty);
      expect(
        await database.select(database.noteDraftAudioSegments).get(),
        isEmpty,
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

  test('旧快照只规范化内存副本，本机格式与服务端协议独立', () {
    // 旧备份没有草稿表，类别行及字段必须在恢复时退休。
    final Map<String, dynamic> tables = {
      for (final String table in SyncSnapshot.tableNames.where(
        (name) =>
            name != 'note_local_drafts' && name != 'note_draft_audio_segments',
      ))
        table: <Map<String, Object?>>[],
    };
    tables['taxonomy_entries'] = [
      {'id': 'category', 'module': 'notes', 'kind': 'category'},
      {'id': 'tag', 'module': 'notes', 'kind': 'tag'},
      {'id': 'other', 'module': 'inventory', 'kind': 'category'},
    ];
    tables['record_taxonomy_links'] = [
      {'id': 'link', 'taxonomy_id': 'category'},
    ];
    tables['note_entries'] = [
      {
        'id': 'note',
        'body': '保留正文',
        'category_id': 'category',
        'category_name': '旧类别',
      },
    ];
    // 规范化不修改校验摘要所对应的原始JSON。
    final Map<String, dynamic> json = {
      'version': 3,
      'tables': tables,
      'pendingOperations': 1,
    };
    final SyncSnapshot restored = SyncSnapshot.fromJson(json);
    expect(tables['note_entries'][0]['category_id'], 'category');
    expect(tables['taxonomy_entries'], hasLength(3));
    expect(
      restored.tables['note_entries']!.single,
      isNot(contains('category_id')),
    );
    expect(
      restored.tables['taxonomy_entries']!.map((row) => row['id']),
      unorderedEquals(['tag', 'other']),
    );
    expect(restored.tables['record_taxonomy_links'], isEmpty);
    expect(restored.tables['note_local_drafts'], isEmpty);
    expect(SyncSnapshot.version, 5);
    expect(SyncSnapshot.migrationProtocolVersion, 3);
  });

  test('笔记与通用回收站分别清空，到期清理仍覆盖两者', () async {
    // 一次测试独占内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 所有操作复用真实仓储。
    final RecycleBinRepository repository = RecycleBinRepository(
      database,
      TodoRepository(database),
    );
    // 超过保留期的绝对时刻。
    final DateTime now = DateTime(2026, 10, 12);
    try {
      await seedRecycleRecord(database, RecycleEntityType.note, 'note', now);
      await seedRecycleRecord(database, RecycleEntityType.event, 'event', now);
      expect(
        (await repository.loadItems(scope: RecycleBinScope.notes)).single.id,
        'note',
      );
      expect(
        (await repository.loadItems(scope: RecycleBinScope.general)).single.id,
        'event',
      );
      expect(await repository.empty(scope: RecycleBinScope.general), 1);
      expect((await repository.loadItems()).single.id, 'note');
      await seedRecycleRecord(database, RecycleEntityType.event, 'event2', now);
      expect(await repository.empty(scope: RecycleBinScope.notes), 1);
      expect((await repository.loadItems()).single.id, 'event2');
      await seedRecycleRecord(
        database,
        RecycleEntityType.note,
        'old-note',
        now.subtract(const Duration(days: 31)),
      );
      await seedRecycleRecord(
        database,
        RecycleEntityType.event,
        'old-event',
        now.subtract(const Duration(days: 31)),
      );
      expect(await repository.purgeExpired(now: now), 2);
      expect((await repository.loadItems()).single.id, 'event2');
    } finally {
      await database.close();
    }
  });

  test('草稿原音生成独立校验备份，不进入同步操作和正式笔记计数', () async {
    // 备份与原文件置于测试独占目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_draft_backup_',
    );
    try {
      // 文件体和摘要必须与草稿元数据一致。
      final List<int> bytes = List<int>.generate(256, (index) => index);
      final File source = await File('${directory.path}/recording.wav')
          .writeAsBytes(bytes);
      final Map<String, List<Map<String, Object?>>> tables = {
        for (final String table in SyncSnapshot.tableNames) table: [],
      };
      tables['note_local_drafts'] = [
        {'id': 'draft', 'note_id': 'note'},
      ];
      tables['note_draft_audio_segments'] = [
        {
          'id': 'segment',
          'draft_id': 'draft',
          'note_id': 'note',
          'local_path': source.path,
          'byte_size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        },
      ];
      // 草稿存储不参与服务器操作枚举。
      final SyncSnapshot snapshot = SyncSnapshot(
        tables: tables,
        pendingOperations: 0,
      );
      expect(snapshot.operations, isEmpty);
      expect(snapshot.totalCount, 0);
      expect(await findMissingMigrationNoteAudio(snapshot), isEmpty);
      final SyncSnapshot backup = await backupMigrationNoteAudio(
        snapshot,
        Directory('${directory.path}/backup'),
      );
      final Map<String, Object?> segment =
          backup.tables['note_draft_audio_segments']!.single;
      expect(segment['local_path'], isNot(source.path));
      expect(
        snapshot.tables['note_draft_audio_segments']!.single['local_path'],
        source.path,
      );
      expect(
        await isMigrationNoteAudioValid(
          segment['local_path'] as String?,
          segment,
        ),
        isTrue,
      );
      await source.delete();
      expect(await findMissingMigrationNoteAudio(backup), isEmpty);
      expect(await findMissingMigrationNoteAudio(snapshot), hasLength(1));
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
