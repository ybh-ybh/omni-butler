import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';

/// 用真实数据库和旧快照验证笔记标签置顶的持久边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('置顶仅允许活动笔记标签，改名排序和重开数据库不丢状态', () async {
    // 每例独占文件，重开可验证置顶并非内存状态。
    final Directory directory = await Directory.systemTemp.createTemp(
      'note-pin-',
    );
    // 本例数据库路径。
    final File file = File('${directory.path}/notes.sqlite');
    // 可重开的真实数据库。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(file));
    try {
      // 同一数据库的标签仓储。
      final TaxonomyRepository repository = TaxonomyRepository(database);
      await repository.save(
        const TaxonomyDraft(
          module: TaxonomyModule.notes,
          kind: TaxonomyKind.tag,
          name: '工作',
          colorValue: 0xFF3370FF,
        ),
      );
      // 刚创建的默认未置顶标签。
      final TaxonomyEntry initial =
          (await repository
                  .watch(module: TaxonomyModule.notes, kind: TaxonomyKind.tag)
                  .first)
              .single;
      expect(initial.isPinned, isFalse);
      await repository.setPinned(initial.id, true);
      await repository.save(
        TaxonomyDraft(
          id: initial.id,
          module: TaxonomyModule.notes,
          kind: TaxonomyKind.tag,
          name: '已改名',
          colorValue: initial.colorValue,
        ),
      );
      await repository.reorder([initial.id]);
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      // 重开后的仓储与前一会话完全分离。
      final TaxonomyRepository reopened = TaxonomyRepository(database);
      // 置顶不能被编辑名称或排序重置。
      final TaxonomyEntry pinned =
          (await reopened
                  .watch(module: TaxonomyModule.notes, kind: TaxonomyKind.tag)
                  .first)
              .single;
      expect(pinned.name, '已改名');
      expect(pinned.isPinned, isTrue);
      await reopened.setPinned(initial.id, false);
      expect(
        (await database.select(database.taxonomyEntries).get())
            .singleWhere((entry) => entry.id == initial.id)
            .isPinned,
        isFalse,
      );
      await reopened.delete(initial.id);
      await expectLater(reopened.setPinned(initial.id, true), throwsStateError);
      await expectLater(reopened.setPinned('missing', true), throwsStateError);
      await reopened.save(
        const TaxonomyDraft(
          module: TaxonomyModule.inventory,
          kind: TaxonomyKind.tag,
          name: '其他模块',
          colorValue: 0xFF3370FF,
        ),
      );
      // 其他模块的有效标签也不可借用笔记置顶接口。
      final TaxonomyEntry other =
          (await reopened
                  .watch(
                    module: TaxonomyModule.inventory,
                    kind: TaxonomyKind.tag,
                  )
                  .first)
              .single;
      await expectLater(reopened.setPinned(other.id, true), throwsStateError);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('v20真实文件升级为23，标签及其他字段保留且置顶默认关闭', () async {
    // 隔离旧版数据库，不访问用户数据。
    final Directory directory = await Directory.systemTemp.createTemp(
      'note-pin-v20-',
    );
    // 待升级的真实文件。
    final File file = File('${directory.path}/old.sqlite');
    // 先构造当前库再去掉新增列，得到真实v20表形状。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(file));
    try {
      // 固定旧记录时间以检查迁移不改写业务事实。
      final DateTime now = DateTime(2026, 10, 15);
      await database
          .into(database.taxonomyEntries)
          .insert(
            TaxonomyEntriesCompanion.insert(
              id: 'legacy-tag',
              module: 'notes',
              kind: 'tag',
              name: '旧标签',
              colorValue: const Value(null),
              sortOrder: const Value(7),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database.customStatement(
        'ALTER TABLE taxonomy_entries DROP COLUMN is_pinned',
      );
      await database.customStatement('PRAGMA user_version = 20');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      // 升级后的唯一历史标签。
      final TaxonomyEntry restored =
          (await database.select(database.taxonomyEntries).get()).single;
      expect(restored.name, '旧标签');
      expect(restored.colorValue, isNull);
      expect(restored.sortOrder, 7);
      expect(restored.updatedAt, now);
      expect(restored.isPinned, isFalse);
      expect(
        (await database.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        25,
      );
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('旧快照1到5仅在恢复副本补置顶0，当前快照保留置顶1', () {
    // 每个旧版本独立构造，验证兼容范围完整。
    for (final int version in [1, 2, 3, 4, 5, 6, 7]) {
      // 不共享内部表，避免测试之间互相污染。
      final Map<String, List<Map<String, Object?>>> tables = {
        for (final String table in SyncSnapshot.tableNames) table: [],
      };
      // 当前版本包含已有置顶，历史版本故意缺列。
      final Map<String, Object?> original = {
        'id': 'tag',
        'module': 'notes',
        'kind': 'tag',
        'name': '标签',
        if (version >= 6) 'is_pinned': 1,
      };
      tables['taxonomy_entries']!.add(original);
      // 生产解码路径必须不改变原始文件对应的数据对象。
      final SyncSnapshot restored = SyncSnapshot.fromJson({
        'version': version,
        'tables': tables,
        'pendingOperations': 0,
      });
      expect(
        restored.tables['taxonomy_entries']!.single['is_pinned'],
        version >= 6 ? 1 : 0,
      );
      expect(
        (restored.operations.single['data'] as Map)['is_pinned'],
        version >= 6 ? 1 : 0,
      );
      expect(original.containsKey('is_pinned'), version >= 6);
    }
    expect(SyncSnapshot.migrationProtocolVersion, 3);
  });
}
