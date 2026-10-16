import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';

/// 验证颜色退休只作用于笔记标签，覆盖真实文件、直接 SQL 和历史快照。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v22真实文件升级只清除笔记标签颜色并保留其他模块和标签字段', () async {
    // 独立文件用于验证真实关闭与升级。
    final Directory directory = await Directory.systemTemp.createTemp(
      'tag-color-',
    );
    // 升级前后使用相同物理数据库。
    final File file = File('${directory.path}/database.sqlite');
    // 允许重开的测试数据库。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await database.customSelect('SELECT 1').get();
      // 还原旧版非空颜色列，没有新版颜色约束。
      await database.customStatement('DROP TABLE taxonomy_entries');
      await database.customStatement('''
CREATE TABLE taxonomy_entries (
  id TEXT PRIMARY KEY, module TEXT NOT NULL, kind TEXT NOT NULL,
  name TEXT NOT NULL, color_value INTEGER NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0,
  is_pinned INTEGER NOT NULL DEFAULT 0, icon_emoji TEXT,
  is_enabled INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
)
''');
      for (final String module in [
        'notes',
        'inventory',
        'timeline',
        'membership',
      ]) {
        await database.customStatement(
          '''
INSERT INTO taxonomy_entries
  (id,module,kind,name,color_value,sort_order,is_pinned,icon_emoji,created_at,updated_at,deleted_at)
VALUES (?,?,'tag','保留名称',4294967295,7,1,'👩🏽‍💻','2026-10-15T00:00:00Z','2026-10-15T01:00:00Z','2026-10-15T02:00:00Z')
''',
          [module, module],
        );
      }
      await database.customStatement(
        "INSERT INTO record_taxonomy_links (id,module,record_id,taxonomy_id,created_at) VALUES ('link','notes','note','notes','2026-10-15T00:00:00Z')",
      );
      await database.customStatement('PRAGMA user_version = 22');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      // 所有字段中只有笔记标签的颜色发生变化，包含软删除标签。
      final List<TaxonomyEntry> entries = await database
          .select(database.taxonomyEntries)
          .get();
      for (final TaxonomyEntry entry in entries) {
        expect(entry.colorValue, entry.module == 'notes' ? null : 4294967295);
        expect(entry.name, '保留名称');
        expect(entry.iconEmoji, '👩🏽‍💻');
        expect(entry.isPinned, isTrue);
        expect(entry.sortOrder, 7);
        expect(entry.deletedAt, isNotNull);
      }
      expect(
        (await database.select(database.recordTaxonomyLinks).get())
            .single
            .taxonomyId,
        'notes',
      );
      await expectLater(
        database.customStatement(
          "UPDATE taxonomy_entries SET color_value = 42 WHERE id = 'notes'",
        ),
        throwsA(isA<Exception>()),
      );
      await database.customStatement(
        "UPDATE taxonomy_entries SET color_value = 42 WHERE id = 'inventory'",
      );
      expect(
        (await (database.select(
              database.taxonomyEntries,
            )..where((table) => table.id.equals('inventory'))).getSingle())
            .colorValue,
        42,
      );
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('新库仓储清除笔记颜色，数据库拒绝直接写入且仍允许其他模块颜色', () async {
    // 新安装也必须安装同一数据库约束。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    try {
      // 旧调用方带入颜色时由仓储兼容清除，emoji 完整保存。
      final TaxonomyRepository repository = TaxonomyRepository(database);
      await repository.save(
        const TaxonomyDraft(
          module: TaxonomyModule.notes,
          kind: TaxonomyKind.tag,
          name: '新标签',
          colorValue: 42,
          iconEmoji: '🏳️‍🌈',
        ),
      );
      // 只读取本例创建的标签。
      final TaxonomyEntry tag = await database
          .select(database.taxonomyEntries)
          .getSingle();
      expect(tag.colorValue, isNull);
      expect(tag.iconEmoji, '🏳️‍🌈');
      await expectLater(
        database
            .into(database.taxonomyEntries)
            .insert(
              TaxonomyEntriesCompanion.insert(
                id: 'invalid',
                module: 'notes',
                kind: 'tag',
                name: '非法颜色',
                colorValue: const Value(42),
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              ),
            ),
        throwsA(isA<Exception>()),
      );
    } finally {
      await database.close();
    }
  });

  test('所有历史快照只在恢复副本移除笔记颜色，换服保留emoji及其他模块颜色', () {
    for (final int version in [1, 2, 3, 4, 5, 6, 7, 8]) {
      // 原始快照不可被原地改写，否则会破坏其持久摘要。
      final Map<String, List<Map<String, Object?>>> tables = {
        for (final String table in SyncSnapshot.tableNames) table: [],
      };
      for (final String module in [
        'notes',
        'inventory',
        'timeline',
        'membership',
      ]) {
        tables['taxonomy_entries']!.add({
          'id': module,
          'module': module,
          'kind': 'tag',
          'color_value': 42,
          'icon_emoji': '👩🏽‍💻',
        });
      }
      // 使用生产恢复链路验证版本兼容。
      final SyncSnapshot restored = SyncSnapshot.fromJson({
        'version': version,
        'tables': tables,
        'pendingOperations': 0,
      });
      expect(tables['taxonomy_entries']!.first['color_value'], 42);
      expect(restored.tables['taxonomy_entries']!.first['color_value'], isNull);
      expect(
        restored.tables['taxonomy_entries']!.first['icon_emoji'],
        '👩🏽‍💻',
      );
      expect(
        restored.tables['taxonomy_entries']!
            .skip(1)
            .map((row) => row['color_value']),
        everyElement(42),
      );
      expect(
        (restored.operations.first['data']! as Map)['color_value'],
        isNull,
      );
    }
  });
}
