import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';

/// 独立验证排序事务，界面拖动不能绕过模块和字段边界。
void main() {
  /// 每个场景独立持有真实SQLite。
  late AppDatabase database;

  /// 当前数据库的仓储。
  late TaxonomyRepository repository;
  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TaxonomyRepository(database);
    // 固定时间便于比较不应改变的字段。
    final DateTime now = DateTime(2026, 10, 17);
    for (final (String, String) item in [
      ('a', 'notes'),
      ('b', 'notes'),
      ('c', 'notes'),
      ('other', 'inventory'),
    ]) {
      await database
          .into(database.taxonomyEntries)
          .insert(
            TaxonomyEntriesCompanion.insert(
              id: item.$1,
              module: item.$2,
              kind: 'tag',
              name: item.$1,
              iconEmoji: const Value('😀'),
              isPinned: const Value(true),
              sortOrder: Value(item.$1.codeUnitAt(0)),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  });
  tearDown(() => database.close());

  test('笔记排序只修改有效标签顺序，不覆盖名称图标置顶和其他模块', () async {
    // 保存前完整快照。
    final List<TaxonomyEntry> before = await database
        .select(database.taxonomyEntries)
        .get();
    await repository.reorderNoteTags(['c', 'a', 'b']);
    // 保存后仍使用同一身份比较字段。
    final List<TaxonomyEntry> after = await database
        .select(database.taxonomyEntries)
        .get();
    for (final TaxonomyEntry tag in before) {
      // 当前记录对应的保存后事实。
      final TaxonomyEntry current = after.singleWhere(
        (item) => item.id == tag.id,
      );
      expect(current.name, tag.name);
      expect(current.iconEmoji, tag.iconEmoji);
      expect(current.isPinned, tag.isPinned);
      expect(current.createdAt, tag.createdAt);
      if (tag.module == 'inventory') expect(current, tag);
    }
    expect(
      (after.where((tag) => tag.module == 'notes').toList()
            ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
          .map((tag) => tag.id),
      ['c', 'a', 'b'],
    );
  });
  test('笔记排序协调删除和新增，不复活墓碑，新标签追加末尾', () async {
    await (database.update(database.taxonomyEntries)
          ..where((table) => table.id.equals('a')))
        .write(TaxonomyEntriesCompanion(deletedAt: Value(DateTime.now())));
    await repository.reorderNoteTags(['b', 'a']);
    // 原删除记录不参与排序和复活。
    final List<TaxonomyEntry> all = await database
        .select(database.taxonomyEntries)
        .get();
    expect(all.singleWhere((tag) => tag.id == 'a').deletedAt, isNotNull);
    expect(all.singleWhere((tag) => tag.id == 'b').sortOrder, 0);
    expect(all.singleWhere((tag) => tag.id == 'c').sortOrder, 1);
  });
  test('笔记排序拒绝跨模块ID及重复项，失败不部分提交', () async {
    await expectLater(
      repository.reorderNoteTags(['a', 'other']),
      throwsFormatException,
    );
    await expectLater(
      repository.reorderNoteTags(['a', 'a']),
      throwsFormatException,
    );
    // 原排列完整保留。
    final List<TaxonomyEntry> all = await database
        .select(database.taxonomyEntries)
        .get();
    expect(
      all.singleWhere((tag) => tag.id == 'a').sortOrder,
      'a'.codeUnitAt(0),
    );
  });
  test('笔记排序中途SQL失败整批回滚，重试使用相同排列成功', () async {
    await database.customStatement(
      "CREATE TRIGGER fail_tag_sort BEFORE UPDATE ON taxonomy_entries WHEN OLD.id='a' BEGIN SELECT RAISE(FAIL, '模拟排序失败'); END",
    );
    await expectLater(
      repository.reorderNoteTags(['b', 'a', 'c']),
      throwsA(isA<Exception>()),
    );
    expect(
      (await (database.select(
        database.taxonomyEntries,
      )..where((table) => table.id.equals('b'))).getSingle()).sortOrder,
      'b'.codeUnitAt(0),
    );
    await database.customStatement('DROP TRIGGER fail_tag_sort');
    await repository.reorderNoteTags(['b', 'a', 'c']);
    expect(
      (await (database.select(
        database.taxonomyEntries,
      )..where((table) => table.id.equals('b'))).getSingle()).sortOrder,
      0,
    );
  });
}
