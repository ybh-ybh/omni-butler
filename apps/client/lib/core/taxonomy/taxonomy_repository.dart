import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:uuid/uuid.dart';

/// 支持分类标签的业务模块。
enum TaxonomyModule {
  /// 物品模块。
  inventory,

  /// 时间记录模块。
  timeline,

  /// 会员模块。
  membership,
}

/// 分类标签类型。
enum TaxonomyKind {
  /// 分类。
  category,

  /// 标签。
  tag,

  /// 位置。
  location,
}

/// 分类标签编辑草稿。
class TaxonomyDraft {
  /// 可选现有记录标识。
  final String? id;

  /// 所属模块。
  final TaxonomyModule module;

  /// 分类标签类型。
  final TaxonomyKind kind;

  /// 显示名称。
  final String name;

  /// ARGB 颜色值。
  final int colorValue;

  /// 可选 Material 图标码点。
  final int? iconCodePoint;

  /// 用户排序值。
  final int sortOrder;

  /// 创建分类标签草稿。
  const TaxonomyDraft({
    this.id,
    required this.module,
    required this.kind,
    required this.name,
    required this.colorValue,
    this.iconCodePoint,
    this.sortOrder = 0,
  });
}

/// 模块内分类标签仓储。
class TaxonomyRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// UUID 生成器。
  final Uuid _uuid;

  /// 创建分类标签仓储。
  TaxonomyRepository(this._database, {this._uuid = const Uuid()});

  /// 监听指定模块的分类或标签。
  Stream<List<TaxonomyEntry>> watch({
    required TaxonomyModule module,
    required TaxonomyKind kind,
  }) async* {
    await _ensureDefaults();
    // 分类标签查询。
    final query = _database.select(_database.taxonomyEntries)
      ..where(
        (TaxonomyEntries table) =>
            table.module.equals(module.name) &
            table.kind.equals(kind.name) &
            table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(TaxonomyEntries)>[
        (TaxonomyEntries table) => OrderingTerm.asc(table.sortOrder),
        (TaxonomyEntries table) => OrderingTerm.asc(table.name),
      ]);
    yield* query.watch();
  }

  /// 保存新增或编辑后的分类标签。
  Future<void> save(TaxonomyDraft draft) async {
    // 清理后的名称。
    final String name = draft.name.trim();
    if (name.isEmpty) {
      throw const FormatException('名称不能为空');
    }
    // 同模块同类型全部现有记录。
    final List<TaxonomyEntry> existing =
        await (_database.select(_database.taxonomyEntries)..where(
              (TaxonomyEntries table) =>
                  table.module.equals(draft.module.name) &
                  table.kind.equals(draft.kind.name) &
                  table.deletedAt.isNull(),
            ))
            .get();
    // 是否存在忽略空格和大小写后的同名记录。
    final bool duplicated = existing.any(
      (TaxonomyEntry item) =>
          item.id != draft.id &&
          item.name.trim().toLowerCase() == name.toLowerCase(),
    );
    if (duplicated) {
      throw const FormatException('同一模块内不能使用重复名称');
    }
    // 当前写入时间。
    final DateTime now = DateTime.now();
    if (draft.id == null) {
      await _database
          .into(_database.taxonomyEntries)
          .insert(
            TaxonomyEntriesCompanion.insert(
              id: _uuid.v7(),
              module: draft.module.name,
              kind: draft.kind.name,
              name: name,
              normalizedName: name.toLowerCase(),
              colorValue: draft.colorValue,
              iconCodePoint: Value<int?>(draft.iconCodePoint),
              sortOrder: Value<int>(draft.sortOrder),
              isEnabled: const Value<bool>(true),
              createdAt: now,
              updatedAt: now,
            ),
          );
      return;
    }
    // 重命名前的 taxonomy 条目。
    final TaxonomyEntry? previousEntry = existing
        .where((TaxonomyEntry item) => item.id == draft.id)
        .firstOrNull;
    await _database.transaction(() async {
      await (_database.update(
        _database.taxonomyEntries,
      )..where((TaxonomyEntries table) => table.id.equals(draft.id!))).write(
        TaxonomyEntriesCompanion(
          name: Value<String>(name),
          normalizedName: Value<String>(name.toLowerCase()),
          colorValue: Value<int>(draft.colorValue),
          iconCodePoint: Value<int?>(draft.iconCodePoint),
          sortOrder: Value<int>(draft.sortOrder),
          isEnabled: const Value<bool>(true),
          updatedAt: Value<DateTime>(now),
        ),
      );
      if (previousEntry != null && previousEntry.name != name) {
        await _syncRenamedReferences(
          draft: draft,
          oldName: previousEntry.name,
          newName: name,
          now: now,
        );
      }
    });
  }

  /// 将 taxonomy 重命名同步到业务表中的冗余展示字段。
  Future<void> _syncRenamedReferences({
    required TaxonomyDraft draft,
    required String oldName,
    required String newName,
    required DateTime now,
  }) async {
    // 当前 taxonomy 已建立的业务记录关联。
    final List<RecordTaxonomyLink> links =
        await (_database.select(_database.recordTaxonomyLinks)..where(
              (RecordTaxonomyLinks table) =>
                  table.module.equals(draft.module.name) &
                  table.taxonomyId.equals(draft.id!) &
                  table.deletedAt.isNull(),
            ))
            .get();
    // 当前已通过 ID 关联的记录标识。
    final Set<String> linkedRecordIds = links
        .map((RecordTaxonomyLink link) => link.recordId)
        .toSet();
    switch ((draft.module, draft.kind)) {
      case (TaxonomyModule.inventory, TaxonomyKind.category):
        await _syncInventoryCategory(
          linkedRecordIds,
          oldName,
          newName,
          now,
          draft.id!,
        );
      case (TaxonomyModule.inventory, TaxonomyKind.location):
        await _syncInventoryLocation(
          linkedRecordIds,
          oldName,
          newName,
          now,
          draft.id!,
        );
      case (TaxonomyModule.inventory, TaxonomyKind.tag):
        await _syncInventoryTags(
          linkedRecordIds,
          oldName,
          newName,
          now,
          draft.id!,
        );
      case (TaxonomyModule.membership, TaxonomyKind.category):
        await _syncMembershipCategory(
          linkedRecordIds,
          oldName,
          newName,
          now,
          draft.id!,
        );
      case _:
        break;
    }
  }

  /// 同步物品分类名称并迁移旧文本记录。
  Future<void> _syncInventoryCategory(
    Set<String> linkedRecordIds,
    String oldName,
    String newName,
    DateTime now,
    String taxonomyId,
  ) async {
    // 当前有效物品。
    final List<InventoryRecord> records = await (_database.select(
      _database.inventoryItems,
    )..where((InventoryItems table) => table.deletedAt.isNull())).get();
    for (final InventoryRecord record in records) {
      // 是否通过 ID 或旧文本命中该分类。
      final bool matched =
          linkedRecordIds.contains(record.id) ||
          record.category?.trim() == oldName;
      if (!matched) {
        continue;
      }
      await (_database.update(
        _database.inventoryItems,
      )..where((InventoryItems table) => table.id.equals(record.id))).write(
        InventoryItemsCompanion(
          category: Value<String>(newName),
          updatedAt: Value<DateTime>(now),
          syncState: const Value<String>('localSaved'),
        ),
      );
      if (!linkedRecordIds.contains(record.id)) {
        await _insertReference('inventory', record.id, taxonomyId, now);
      }
    }
  }

  /// 同步物品位置名称并迁移旧文本记录。
  Future<void> _syncInventoryLocation(
    Set<String> linkedRecordIds,
    String oldName,
    String newName,
    DateTime now,
    String taxonomyId,
  ) async {
    // 当前有效物品。
    final List<InventoryRecord> records = await (_database.select(
      _database.inventoryItems,
    )..where((InventoryItems table) => table.deletedAt.isNull())).get();
    for (final InventoryRecord record in records) {
      // 是否通过 ID 或旧文本命中该位置。
      final bool matched =
          linkedRecordIds.contains(record.id) ||
          record.location?.trim() == oldName;
      if (!matched) {
        continue;
      }
      await (_database.update(
        _database.inventoryItems,
      )..where((InventoryItems table) => table.id.equals(record.id))).write(
        InventoryItemsCompanion(
          location: Value<String>(newName),
          updatedAt: Value<DateTime>(now),
          syncState: const Value<String>('localSaved'),
        ),
      );
      if (!linkedRecordIds.contains(record.id)) {
        await _insertReference('inventory', record.id, taxonomyId, now);
      }
    }
  }

  /// 同步物品标签文本并迁移旧文本记录。
  Future<void> _syncInventoryTags(
    Set<String> linkedRecordIds,
    String oldName,
    String newName,
    DateTime now,
    String taxonomyId,
  ) async {
    // 当前有效物品。
    final List<InventoryRecord> records = await (_database.select(
      _database.inventoryItems,
    )..where((InventoryItems table) => table.deletedAt.isNull())).get();
    for (final InventoryRecord record in records) {
      // 去重后的标签文本。
      final List<String> tags = (record.tags ?? '')
          .split(',')
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList();
      // 是否通过 ID 或旧文本命中该标签。
      final bool matched =
          linkedRecordIds.contains(record.id) || tags.contains(oldName);
      if (!matched) {
        continue;
      }
      final List<String> renamedTags = tags
          .map((String value) => value == oldName ? newName : value)
          .toSet()
          .toList();
      await (_database.update(
        _database.inventoryItems,
      )..where((InventoryItems table) => table.id.equals(record.id))).write(
        InventoryItemsCompanion(
          tags: Value<String?>(
            renamedTags.isEmpty ? null : renamedTags.join(','),
          ),
          updatedAt: Value<DateTime>(now),
          syncState: const Value<String>('localSaved'),
        ),
      );
      if (!linkedRecordIds.contains(record.id)) {
        await _insertReference('inventory', record.id, taxonomyId, now);
      }
    }
  }

  /// 同步会员分类名称并迁移旧文本记录。
  Future<void> _syncMembershipCategory(
    Set<String> linkedRecordIds,
    String oldName,
    String newName,
    DateTime now,
    String taxonomyId,
  ) async {
    // 当前有效会员。
    final List<MembershipRecord> records = await (_database.select(
      _database.memberships,
    )..where((Memberships table) => table.deletedAt.isNull())).get();
    for (final MembershipRecord record in records) {
      // 是否通过 ID 或旧文本命中该分类。
      final bool matched =
          linkedRecordIds.contains(record.id) ||
          record.category?.trim() == oldName;
      if (!matched) {
        continue;
      }
      await (_database.update(
        _database.memberships,
      )..where((Memberships table) => table.id.equals(record.id))).write(
        MembershipsCompanion(
          category: Value<String>(newName),
          updatedAt: Value<DateTime>(now),
          syncState: const Value<String>('localSaved'),
        ),
      );
      if (!linkedRecordIds.contains(record.id)) {
        await _insertReference('membership', record.id, taxonomyId, now);
      }
    }
  }

  /// 为旧文本记录补建 taxonomy ID 关联。
  Future<void> _insertReference(
    String module,
    String recordId,
    String taxonomyId,
    DateTime now,
  ) async {
    // 新增的业务关联。
    await _database
        .into(_database.recordTaxonomyLinks)
        .insert(
          RecordTaxonomyLinksCompanion.insert(
            id: _uuid.v7(),
            module: module,
            recordId: recordId,
            taxonomyId: taxonomyId,
            createdAt: now,
          ),
        );
  }

  /// 按给定标识顺序一次性保存分类标签排序。
  Future<void> reorder(List<String> orderedIds) async {
    // 当前写入时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      for (int index = 0; index < orderedIds.length; index += 1) {
        // 当前分类标签标识。
        final String id = orderedIds[index];
        await (_database.update(
          _database.taxonomyEntries,
        )..where((TaxonomyEntries table) => table.id.equals(id))).write(
          TaxonomyEntriesCompanion(
            sortOrder: Value<int>(index),
            updatedAt: Value<DateTime>(now),
          ),
        );
      }
    });
  }

  /// 将分类标签移入回收状态。
  Future<void> delete(String id) async {
    // 当前删除时间。
    final DateTime now = DateTime.now();
    await (_database.update(
      _database.taxonomyEntries,
    )..where((TaxonomyEntries table) => table.id.equals(id))).write(
      TaxonomyEntriesCompanion(
        deletedAt: Value<DateTime>(now),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  /// 恢复刚删除的分类标签。
  Future<void> restore(String id) async {
    await (_database.update(
      _database.taxonomyEntries,
    )..where((TaxonomyEntries table) => table.id.equals(id))).write(
      TaxonomyEntriesCompanion(
        deletedAt: const Value<DateTime?>(null),
        updatedAt: Value<DateTime>(DateTime.now()),
      ),
    );
  }

  /// 用新的标签集合替换记录的现有标签关系。
  Future<void> setRecordTags({
    required TaxonomyModule module,
    required String recordId,
    required Set<String> taxonomyIds,
  }) async {
    // 当前写入时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      await (_database.update(_database.recordTaxonomyLinks)..where(
            (RecordTaxonomyLinks table) =>
                table.module.equals(module.name) &
                table.recordId.equals(recordId) &
                table.deletedAt.isNull(),
          ))
          .write(RecordTaxonomyLinksCompanion(deletedAt: Value<DateTime>(now)));
      for (final String taxonomyId in taxonomyIds) {
        await _database
            .into(_database.recordTaxonomyLinks)
            .insert(
              RecordTaxonomyLinksCompanion.insert(
                id: _uuid.v7(),
                module: module.name,
                recordId: recordId,
                taxonomyId: taxonomyId,
                createdAt: now,
              ),
            );
      }
    });
  }

  /// 读取一条业务记录当前关联的标签。
  Future<List<TaxonomyEntry>> loadRecordTags({
    required TaxonomyModule module,
    required String recordId,
    TaxonomyKind? kind,
  }) async {
    // 当前有效关联。
    final List<RecordTaxonomyLink> links =
        await (_database.select(_database.recordTaxonomyLinks)..where(
              (RecordTaxonomyLinks table) =>
                  table.module.equals(module.name) &
                  table.recordId.equals(recordId) &
                  table.deletedAt.isNull(),
            ))
            .get();
    if (links.isEmpty) {
      return const <TaxonomyEntry>[];
    }
    // 关联的标签标识。
    final Set<String> ids = links
        .map((RecordTaxonomyLink link) => link.taxonomyId)
        .toSet();
    final List<TaxonomyEntry> entries =
        await (_database.select(_database.taxonomyEntries)..where(
              (TaxonomyEntries table) =>
                  table.id.isIn(ids) & table.deletedAt.isNull(),
            ))
            .get();
    if (kind == null) {
      return entries;
    }
    return entries
        .where((TaxonomyEntry entry) => entry.kind == kind.name)
        .toList(growable: false);
  }

  /// 确保内置时间类别存在。
  Future<void> _ensureDefaults() async {
    // 已有时间类别数量。
    final int count =
        await (_database.selectOnly(_database.taxonomyEntries)
              ..addColumns(<Expression<Object>>[
                _database.taxonomyEntries.id.count(),
              ])
              ..where(
                _database.taxonomyEntries.module.equals(
                      TaxonomyModule.timeline.name,
                    ) &
                    _database.taxonomyEntries.kind.equals(
                      TaxonomyKind.category.name,
                    ) &
                    _database.taxonomyEntries.deletedAt.isNull(),
              ))
            .map(
              (TypedResult row) =>
                  row.read(_database.taxonomyEntries.id.count()) ?? 0,
            )
            .getSingle();
    if (count > 0) {
      return;
    }
    // 内置时间类别。
    final List<(String, Color, IconData)> defaults =
        <(String, Color, IconData)>[
          ('工作', const Color(0xFF477087), Icons.work_outline_rounded),
          ('学习', const Color(0xFF5A67A5), Icons.school_outlined),
          ('运动', const Color(0xFF397966), Icons.directions_run_rounded),
          ('休息', const Color(0xFF75628E), Icons.bedtime_outlined),
          ('娱乐', const Color(0xFFA96266), Icons.sports_esports_outlined),
          ('其他', const Color(0xFF67717D), Icons.more_horiz_rounded),
        ];
    // 当前创建时间。
    final DateTime now = DateTime.now();
    await _database.batch((Batch batch) {
      batch.insertAll(_database.taxonomyEntries, <TaxonomyEntriesCompanion>[
        for (int index = 0; index < defaults.length; index += 1)
          TaxonomyEntriesCompanion.insert(
            id: const Uuid().v7(),
            module: TaxonomyModule.timeline.name,
            kind: TaxonomyKind.category.name,
            name: defaults[index].$1,
            normalizedName: defaults[index].$1.toLowerCase(),
            colorValue: defaults[index].$2.toARGB32(),
            iconCodePoint: Value<int>(defaults[index].$3.codePoint),
            sortOrder: Value<int>(index),
            createdAt: now.add(Duration(milliseconds: index)),
            updatedAt: now.add(Duration(milliseconds: index)),
          ),
      ]);
    });
  }
}
