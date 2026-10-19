import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';

/// 使用真实持久化边界验证笔记标签名称和图标的原子修改。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('完整组合图标重开保留，名称图标各自修改且不覆盖其他字段', () async {
    // 独占测试目录，不连接用户实际数据库。
    final Directory directory = await Directory.systemTemp.createTemp(
      'note-appearance-',
    );
    // 重开同一文件验证持久化。
    final File file = File('${directory.path}/notes.sqlite');
    // 可重建的数据库实例。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await _insertTag(database);
      // 当前写入仓储。
      final TaxonomyRepository repository = TaxonomyRepository(database);
      expect((await _tag(database)).iconEmoji, isNull);
      await repository.updateNoteTagAppearance(
        'tag',
        name: const Value(' 家庭 '),
        iconEmoji: const Value('👩🏽‍💻'),
      );
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      // 与旧会话完全分离的仓储。
      final TaxonomyRepository reopened = TaxonomyRepository(database);
      // 名称与图标必须一起恢复，同时保留其他业务事实。
      final TaxonomyEntry restored = await _tag(database);
      expect(restored.name, '家庭');
      expect(restored.iconEmoji, '👩🏽‍💻');
      expect(restored.id, 'tag');
      expect(restored.colorValue, isNull);
      expect(restored.sortOrder, 7);
      expect(restored.isPinned, isTrue);
      expect(restored.isEnabled, isFalse);

      await reopened.updateNoteTagAppearance('tag', name: const Value('已改名'));
      expect((await _tag(database)).iconEmoji, '👩🏽‍💻');
      await reopened.updateNoteTagAppearance(
        'tag',
        iconEmoji: const Value('👨‍👩‍👧‍👦'),
      );
      expect((await _tag(database)).name, '已改名');
      await reopened.save(
        const TaxonomyDraft(
          id: 'tag',
          module: TaxonomyModule.notes,
          kind: TaxonomyKind.tag,
          name: '普通入口改名',
          colorValue: 42,
        ),
      );
      await reopened.reorder(['tag']);
      await reopened.setPinned('tag', false);
      expect((await _tag(database)).iconEmoji, '👨‍👩‍👧‍👦');
      await reopened.updateNoteTagAppearance(
        'tag',
        iconEmoji: const Value(null),
      );
      expect((await _tag(database)).iconEmoji, isNull);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('无效名称与失效标签拒绝整次修改，空差量不改更新时间', () async {
    // 每例使用独立内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 生产仓储用于检查事务边界。
    final TaxonomyRepository repository = TaxonomyRepository(database);
    try {
      await _insertTag(database);
      await _insertTag(database, id: 'other', name: 'Work');
      await _insertTag(database, id: 'inventory', module: 'inventory');
      // 保留原始更新时间，失败和空差量不能生成持久写入。
      final TaxonomyEntry original = await _tag(database);
      await repository.updateNoteTagAppearance('tag');
      expect(await _tag(database), original);
      // 同名和空名都必须阻止图标在名称失败时单独保存。
      for (final String invalidName in [' ', ' work ']) {
        await expectLater(
          repository.updateNoteTagAppearance(
            'tag',
            name: Value(invalidName),
            iconEmoji: const Value('😀'),
          ),
          throwsFormatException,
        );
        expect(await _tag(database), original);
      }
      await expectLater(
        repository.updateNoteTagAppearance(
          'missing',
          iconEmoji: const Value('😀'),
        ),
        throwsStateError,
      );
      await expectLater(
        repository.updateNoteTagAppearance(
          'inventory',
          iconEmoji: const Value('😀'),
        ),
        throwsStateError,
      );
      await repository.delete('tag');
      // 已删除标签保留墓碑，旧弹窗不能改名或写入图标。
      final TaxonomyEntry deleted = await _tag(database);
      await expectLater(
        repository.updateNoteTagAppearance(
          'tag',
          name: const Value('迟到名称'),
          iconEmoji: const Value('😀'),
        ),
        throwsStateError,
      );
      expect(await _tag(database), deleted);
    } finally {
      await database.close();
    }
  });

  test('真实v21升级为22补空图标，重复升级保留组合图标与原字段', () async {
    // 只构造测试文件模拟旧数据库形状。
    final Directory directory = await Directory.systemTemp.createTemp(
      'note-appearance-v21-',
    );
    // 待升级的独立文件。
    final File file = File('${directory.path}/old.sqlite');
    // 可重开的实际数据库。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await _insertTag(database);
      // 迁移前的业务事实。
      final TaxonomyEntry original = await _tag(database);
      await database.customStatement(
        'ALTER TABLE taxonomy_entries DROP COLUMN icon_emoji',
      );
      await database.customStatement('PRAGMA user_version = 21');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      expect(await _tag(database), original);
      expect(
        (await database.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        26,
      );
      await TaxonomyRepository(database)
          .updateNoteTagAppearance('tag', iconEmoji: const Value('🏳️‍🌈'));
      // 已存在新列时再进入升级，不能重复加列或清空新值。
      final TaxonomyEntry withIcon = await _tag(database);
      await database.customStatement('PRAGMA user_version = 21');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      expect(await _tag(database), withIcon);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('快照1到6恢复副本补空图标，快照7与换服PUT保留完整图标', () {
    // 逐个验证所有仍受支持的历史格式。
    for (final int version in [1, 2, 3, 4, 5, 6, 7]) {
      // 每个版本独立构造原始表数据。
      final Map<String, List<Map<String, Object?>>> tables = {
        for (final String table in SyncSnapshot.tableNames) table: [],
      };
      // 旧快照缺少图标列，当前快照使用多码点组合字符。
      final Map<String, Object?> original = {
        'id': 'tag',
        'module': 'notes',
        'kind': 'tag',
        'name': '标签',
        if (version >= 6) 'is_pinned': 1,
        if (version == 7) 'icon_emoji': '👩🏽‍💻',
      };
      tables['taxonomy_entries']!.add(original);
      // 使用生产解码与换服转换链路。
      final SyncSnapshot restored = SyncSnapshot.fromJson({
        'version': version,
        'tables': tables,
        'pendingOperations': 0,
      });
      expect(
        restored.tables['taxonomy_entries']!.single['icon_emoji'],
        version == 7 ? '👩🏽‍💻' : null,
      );
      expect(
        restored.tables['taxonomy_entries']!.single.containsKey('icon_emoji'),
        isTrue,
      );
      expect(
        (restored.operations.single['data'] as Map)['icon_emoji'],
        version == 7 ? '👩🏽‍💻' : null,
      );
      expect(original.containsKey('icon_emoji'), version == 7);
      expect(restored.toJson()['version'], 11);
    }
    expect(SyncSnapshot.migrationProtocolVersion, 3);
  });
}

/// 插入带不同状态的标签，便于捕捉外观更新造成的字段覆盖。
Future<void> _insertTag(
  AppDatabase database, {
  String id = 'tag',
  String module = 'notes',
  String name = '原名称',
}) async {
  // 固定原始时间可发现无意改写。
  final DateTime createdAt = DateTime(2026, 10, 15);
  await database
      .into(database.taxonomyEntries)
      .insert(
        TaxonomyEntriesCompanion.insert(
          id: id,
          module: module,
          kind: 'tag',
          name: name,
          colorValue: Value(module == 'notes' ? null : 42),
          sortOrder: const Value(7),
          isPinned: const Value(true),
          isEnabled: const Value(false),
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      );
}

/// 按固定身份读取包含墓碑的标签。
Future<TaxonomyEntry> _tag(AppDatabase database) => (database.select(
  database.taxonomyEntries,
)..where((TaxonomyEntries table) => table.id.equals('tag'))).getSingle();
