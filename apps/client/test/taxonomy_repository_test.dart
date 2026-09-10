import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';

/// 验证分类标签的直接编辑、排序和删除恢复规则。
void main() {
  /// 每个测试使用的内存数据库。
  late AppDatabase database;

  /// 每个测试使用的分类标签仓储。
  late TaxonomyRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TaxonomyRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('未删除标签始终可见且排序在一次操作后生效', () async {
    await repository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.tag,
        name: '工作',
        colorValue: 0xFF3370FF,
        sortOrder: 0,
      ),
    );
    await repository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.inventory,
        kind: TaxonomyKind.tag,
        name: '数码',
        colorValue: 0xFF1EA7A1,
        sortOrder: 1,
      ),
    );
    // 初始标签列表。
    final List<TaxonomyEntry> initial = await repository
        .watch(module: TaxonomyModule.inventory, kind: TaxonomyKind.tag)
        .first;
    // 模拟旧版本中曾被停用的标签标识。
    final String legacyDisabledId = initial.first.id;
    await (database.update(database.taxonomyEntries)
          ..where((TaxonomyEntries table) => table.id.equals(legacyDisabledId)))
        .write(const TaxonomyEntriesCompanion(isEnabled: Value<bool>(false)));

    // 不再按历史启停字段过滤的列表。
    final List<TaxonomyEntry> visible = await repository
        .watch(module: TaxonomyModule.inventory, kind: TaxonomyKind.tag)
        .first;
    expect(visible, hasLength(2));

    await repository.reorder(<String>[visible.last.id, visible.first.id]);
    // 重排后的标签列表。
    final List<TaxonomyEntry> reordered = await repository
        .watch(module: TaxonomyModule.inventory, kind: TaxonomyKind.tag)
        .first;
    expect(reordered.map((TaxonomyEntry entry) => entry.name), <String>[
      '数码',
      '工作',
    ]);
  });

  test('删除后从清单消失并可恢复', () async {
    await repository.save(
      const TaxonomyDraft(
        module: TaxonomyModule.membership,
        kind: TaxonomyKind.category,
        name: '办公工具',
        colorValue: 0xFF8E5CD9,
      ),
    );
    // 新建的会员分类。
    final TaxonomyEntry entry =
        (await repository
                .watch(
                  module: TaxonomyModule.membership,
                  kind: TaxonomyKind.category,
                )
                .first)
            .single;

    await repository.delete(entry.id);
    expect(
      await repository
          .watch(module: TaxonomyModule.membership, kind: TaxonomyKind.category)
          .first,
      isEmpty,
    );

    await repository.restore(entry.id);
    // 恢复后的会员分类。
    final List<TaxonomyEntry> restored = await repository
        .watch(module: TaxonomyModule.membership, kind: TaxonomyKind.category)
        .first;
    expect(restored.single.name, '办公工具');
  });
}
