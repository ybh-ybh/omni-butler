import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:uuid/uuid.dart';

/// 物品使用状态。
enum InventoryStatus {
  /// 正在使用。
  inUse,

  /// 暂时闲置。
  idle,

  /// 已经借出。
  lent,

  /// 已经售出。
  sold,

  /// 已经丢弃。
  discarded,
}

/// 物品编辑草稿。
class InventoryDraft {
  /// 可选现有物品标识。
  final String? id;

  /// 物品名称。
  final String name;

  /// 可选分类。
  final String? category;

  /// 物品数量。
  final int quantity;

  /// 可选购买金额分值。
  final int? purchasePriceCents;

  /// 可选购买日期。
  final DateTime? purchaseDate;

  /// 可选购买链接。
  final String? purchaseUrl;

  /// 可选购买平台。
  final String? purchasePlatform;

  /// 可选存放位置。
  final String? location;

  /// 物品使用状态。
  final InventoryStatus status;

  /// 可选保修到期日。
  final DateTime? warrantyExpiration;

  /// 标签集合，保留用于兼容已有数据。
  final List<String> tags;

  /// 已选择的规范分类标识。
  final Set<String> categoryIds;

  /// 已选择的规范位置标识。
  final Set<String> locationIds;

  /// 已选择的规范标签标识，保留用于读取旧调用方。
  @Deprecated('Use categoryIds instead')
  final Set<String> tagIds;

  /// 可选父物品标识。
  final String? parentItemId;

  /// 可选备注。
  final String? notes;

  /// 创建物品草稿。
  const InventoryDraft({
    this.id,
    required this.name,
    this.category,
    required this.quantity,
    this.purchasePriceCents,
    this.purchaseDate,
    this.purchaseUrl,
    this.purchasePlatform,
    this.location,
    this.status = InventoryStatus.inUse,
    this.warrantyExpiration,
    this.tags = const <String>[],
    this.categoryIds = const <String>{},
    this.locationIds = const <String>{},
    @Deprecated('Use categoryIds instead') this.tagIds = const <String>{},
    this.parentItemId,
    this.notes,
  });
}

/// 物品批量迁移结果。
class InventoryMoveResult {
  /// 实际写入新位置的记录数。
  final int movedCount;

  /// 因主物品迁移而自动跟随的配套物品数。
  final int followedCount;

  /// 已经位于目标位置而跳过的记录数。
  final int unchangedCount;

  /// 已删除或不存在而跳过的记录数。
  final int missingCount;

  /// 目标位置名称。
  final String destinationName;

  /// 创建物品批量迁移结果。
  const InventoryMoveResult({
    required this.movedCount,
    required this.followedCount,
    required this.unchangedCount,
    required this.missingCount,
    required this.destinationName,
  });

  /// 返回本次迁移影响的物品总数。
  int get affectedCount => movedCount + followedCount;
}

/// 物品本地优先仓储。
class InventoryRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// UUID 生成器。
  final Uuid _uuid;

  /// 创建物品仓储。
  InventoryRepository(this._database, {this._uuid = const Uuid()});

  /// 监听有效物品并支持名称、分类、位置和标签搜索。
  Stream<List<InventoryRecord>> watchAll({String query = ''}) {
    // 有效物品查询，搜索时同时包含主物品和配套物品。
    final statement = _database.select(_database.inventoryItems)
      ..where((InventoryItems table) => table.deletedAt.isNull())
      ..orderBy(<OrderingTerm Function(InventoryItems)>[
        // 购买日期越晚代表使用时间越短，优先展示；未填写日期由 SQLite 排在最后。
        (InventoryItems table) => OrderingTerm.desc(table.purchaseDate),
        (InventoryItems table) => OrderingTerm.asc(table.name),
      ]);
    return statement.watch().map((List<InventoryRecord> records) {
      // 清理后的搜索词。
      final String keyword = query.trim().toLowerCase();
      // 页面主列表只展示主物品，配套物品命中时回溯到所属主物品。
      final List<InventoryRecord> parents = records
          .where((InventoryRecord item) => item.parentItemId == null)
          .toList(growable: false);
      if (keyword.isEmpty) {
        return parents;
      }
      // 主物品和配套物品的搜索命中标识。
      final Set<String> matchedParentIds = <String>{};
      for (final InventoryRecord item in records) {
        // 当前记录可被搜索的文本。
        final String searchable = <String>[
          item.name,
          item.category ?? '',
          item.location ?? '',
          item.tags ?? '',
          item.status,
          item.purchasePlatform ?? '',
          item.notes ?? '',
        ].join(' ').toLowerCase();
        if (searchable.contains(keyword)) {
          matchedParentIds.add(item.parentItemId ?? item.id);
        }
      }
      return parents
          .where((InventoryRecord item) => matchedParentIds.contains(item.id))
          .toList(growable: false);
    });
  }

  /// 监听物品与规范分类、标签、位置之间的有效关联。
  Stream<Map<String, Set<String>>> watchTaxonomyLinks() {
    // 物品模块的有效关联查询。
    final query = _database.select(_database.recordTaxonomyLinks)
      ..where(
        (RecordTaxonomyLinks table) =>
            table.module.equals('inventory') & table.deletedAt.isNull(),
      );
    return query.watch().map((List<RecordTaxonomyLink> links) {
      // 按物品标识聚合规范分类标识。
      final Map<String, Set<String>> grouped = <String, Set<String>>{};
      for (final RecordTaxonomyLink link in links) {
        grouped
            .putIfAbsent(link.recordId, () => <String>{})
            .add(link.taxonomyId);
      }
      return grouped;
    });
  }

  /// 监听指定主物品的配套物品。
  Stream<List<InventoryRecord>> watchAccessories(String parentItemId) {
    // 配套物品查询。
    final query = _database.select(_database.inventoryItems)
      ..where(
        (InventoryItems table) =>
            table.parentItemId.equals(parentItemId) & table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(InventoryItems)>[
        (InventoryItems table) => OrderingTerm.asc(table.name),
      ]);
    return query.watch();
  }

  /// 监听全部有效配套物品，用于全局统计。
  Stream<List<InventoryRecord>> watchAllAccessories() {
    // 全部配套物品查询。
    final query = _database.select(_database.inventoryItems)
      ..where(
        (InventoryItems table) =>
            table.parentItemId.isNotNull() & table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(InventoryItems)>[
        (InventoryItems table) => OrderingTerm.asc(table.name),
      ]);
    return query.watch();
  }

  /// 保存新增或编辑后的物品。
  Future<String> save(InventoryDraft draft) async {
    // 清理后的物品名称。
    final String name = draft.name.trim();
    if (name.isEmpty) {
      throw const FormatException('物品名称不能为空');
    }
    if (draft.quantity <= 0) {
      throw const FormatException('物品数量必须大于 0');
    }
    if ((draft.purchasePriceCents ?? 0) < 0) {
      throw const FormatException('购买金额不能为负数');
    }
    // 清理后的购买链接。
    final String? purchaseUrl = _cleanOptional(draft.purchaseUrl);
    if (purchaseUrl != null) {
      // 解析后的购买链接。
      final Uri? uri = Uri.tryParse(purchaseUrl);
      if (uri == null ||
          !<String>{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw const FormatException('购买链接必须使用 http 或 https');
      }
    }
    // 清理后的标签文本。
    final String? tags = _normalizeTags(draft.tags);
    // 当前写入时间。
    final DateTime now = DateTime.now();
    // 本次保存使用的稳定标识。
    final String id = draft.id ?? _uuid.v7();
    await _database.transaction(() async {
      if (draft.id == null) {
        await _database
            .into(_database.inventoryItems)
            .insert(
              InventoryItemsCompanion.insert(
                id: id,
                name: name,
                category: Value<String?>(_cleanOptional(draft.category)),
                quantity: Value<int>(draft.quantity),
                purchasePriceCents: Value<int?>(draft.purchasePriceCents),
                purchaseDate: Value<DateTime?>(draft.purchaseDate),
                purchaseUrl: Value<String?>(purchaseUrl),
                purchasePlatform: Value<String?>(
                  _cleanOptional(draft.purchasePlatform),
                ),
                location: Value<String?>(_cleanOptional(draft.location)),
                status: Value<String>(draft.status.name),
                warrantyExpiration: Value<DateTime?>(draft.warrantyExpiration),
                tags: Value<String?>(tags),
                parentItemId: Value<String?>(draft.parentItemId),
                notes: Value<String?>(_cleanOptional(draft.notes)),
                createdAt: now,
                updatedAt: now,
              ),
            );
      } else {
        await (_database.update(
          _database.inventoryItems,
        )..where((InventoryItems table) => table.id.equals(id))).write(
          InventoryItemsCompanion(
            name: Value<String>(name),
            category: Value<String?>(_cleanOptional(draft.category)),
            quantity: Value<int>(draft.quantity),
            purchasePriceCents: Value<int?>(draft.purchasePriceCents),
            purchaseDate: Value<DateTime?>(draft.purchaseDate),
            purchaseUrl: Value<String?>(purchaseUrl),
            purchasePlatform: Value<String?>(
              _cleanOptional(draft.purchasePlatform),
            ),
            location: Value<String?>(_cleanOptional(draft.location)),
            status: Value<String>(draft.status.name),
            warrantyExpiration: Value<DateTime?>(draft.warrantyExpiration),
            tags: Value<String?>(tags),
            parentItemId: Value<String?>(draft.parentItemId),
            notes: Value<String?>(_cleanOptional(draft.notes)),
            updatedAt: Value<DateTime>(now),
            syncState: const Value<String>('localSaved'),
          ),
        );
      }
      await _replaceCategoryLinks(id, <String>{
        ...(draft.categoryIds.isEmpty ? draft.tagIds : draft.categoryIds),
        ...draft.locationIds,
      }, now);
    });
    return id;
  }

  /// 将多条物品记录事务化迁移到同一个规范位置。
  Future<InventoryMoveResult> moveItems({
    required Set<String> itemIds,
    required String destinationLocationId,
  }) async {
    // 清理后的待迁移物品标识。
    final Set<String> normalizedItemIds = itemIds
        .map((String id) => id.trim())
        .where((String id) => id.isNotEmpty)
        .toSet();
    if (normalizedItemIds.isEmpty) {
      throw const FormatException('请先选择需要迁移的物品');
    }
    // 清理后的目标位置标识。
    final String normalizedDestinationId = destinationLocationId.trim();
    if (normalizedDestinationId.isEmpty) {
      throw const FormatException('请选择目标位置');
    }
    return _database.transaction<InventoryMoveResult>(() async {
      // 当前可用的目标位置。
      final TaxonomyEntry? destination =
          await (_database.select(_database.taxonomyEntries)..where(
                (TaxonomyEntries table) =>
                    table.id.equals(normalizedDestinationId) &
                    table.module.equals('inventory') &
                    table.kind.equals('location') &
                    table.isEnabled.equals(true) &
                    table.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (destination == null) {
        throw const FormatException('目标位置不存在或已停用');
      }
      // 当前有效的待迁移物品。
      final List<InventoryRecord> records =
          await (_database.select(_database.inventoryItems)..where(
                (InventoryItems table) =>
                    table.id.isIn(normalizedItemIds) & table.deletedAt.isNull(),
              ))
              .get();
      // 按标识索引的待迁移物品。
      final Map<String, InventoryRecord> recordsById =
          <String, InventoryRecord>{
            for (final InventoryRecord record in records) record.id: record,
          };
      // 物品模块全部位置标识，包含已停用或软删除位置以便清理旧关联。
      final List<String> locationIds =
          await (_database.selectOnly(_database.taxonomyEntries)
                ..addColumns(<Expression<Object>>[_database.taxonomyEntries.id])
                ..where(
                  _database.taxonomyEntries.module.equals('inventory') &
                      _database.taxonomyEntries.kind.equals('location'),
                ))
              .map((TypedResult row) => row.read(_database.taxonomyEntries.id)!)
              .get();
      // 当前选择记录已有的有效位置关联。
      final List<RecordTaxonomyLink> activeLocationLinks =
          await (_database.select(_database.recordTaxonomyLinks)..where(
                (RecordTaxonomyLinks table) =>
                    table.module.equals('inventory') &
                    table.recordId.isIn(recordsById.keys) &
                    table.taxonomyId.isIn(locationIds) &
                    table.deletedAt.isNull(),
              ))
              .get();
      // 按物品标识聚合的现有位置关联。
      final Map<String, List<RecordTaxonomyLink>> linksByRecordId =
          <String, List<RecordTaxonomyLink>>{};
      for (final RecordTaxonomyLink link in activeLocationLinks) {
        linksByRecordId
            .putIfAbsent(link.recordId, () => <RecordTaxonomyLink>[])
            .add(link);
      }
      // 本次批量写入时间。
      final DateTime now = DateTime.now();
      // 实际写入新位置的记录数。
      int movedCount = 0;
      // 自动跟随主物品的配套物品数。
      int followedCount = 0;
      // 已处于目标位置的记录数。
      int unchangedCount = 0;
      for (final InventoryRecord record in records) {
        // 当前记录已有的位置关联。
        final List<RecordTaxonomyLink> currentLinks =
            linksByRecordId[record.id] ?? const <RecordTaxonomyLink>[];
        // 当前记录是否为空位置并随已选主物品存放。
        final bool followsSelectedParent =
            record.parentItemId != null &&
            (record.location?.trim().isEmpty ?? true) &&
            currentLinks.isEmpty &&
            recordsById.containsKey(record.parentItemId);
        if (followsSelectedParent) {
          // 已选中的主物品记录。
          final InventoryRecord parent = recordsById[record.parentItemId]!;
          // 主物品当前的规范位置关联。
          final List<RecordTaxonomyLink> parentLinks =
              linksByRecordId[parent.id] ?? const <RecordTaxonomyLink>[];
          // 主物品是否会被实际迁移。
          final bool parentWillMove =
              parent.location?.trim() != destination.name ||
              parentLinks.length != 1 ||
              parentLinks.single.taxonomyId != destination.id;
          if (parentWillMove) {
            followedCount += 1;
          } else {
            unchangedCount += 1;
          }
          continue;
        }
        // 当前记录是否已经规范地位于目标位置。
        final bool alreadyAtDestination =
            record.location?.trim() == destination.name &&
            currentLinks.length == 1 &&
            currentLinks.single.taxonomyId == destination.id;
        if (alreadyAtDestination) {
          unchangedCount += 1;
          continue;
        }
        await (_database.update(
          _database.inventoryItems,
        )..where((InventoryItems table) => table.id.equals(record.id))).write(
          InventoryItemsCompanion(
            location: Value<String>(destination.name),
            updatedAt: Value<DateTime>(now),
            syncState: const Value<String>('localSaved'),
          ),
        );
        if (currentLinks.isNotEmpty) {
          await (_database.update(_database.recordTaxonomyLinks)..where(
                (RecordTaxonomyLinks table) =>
                    table.id.isIn(
                      currentLinks.map((RecordTaxonomyLink link) => link.id),
                    ) &
                    table.deletedAt.isNull(),
              ))
              .write(
                RecordTaxonomyLinksCompanion(deletedAt: Value<DateTime>(now)),
              );
        }
        await _database
            .into(_database.recordTaxonomyLinks)
            .insert(
              RecordTaxonomyLinksCompanion.insert(
                id: _uuid.v7(),
                module: 'inventory',
                recordId: record.id,
                taxonomyId: destination.id,
                createdAt: now,
              ),
            );
        movedCount += 1;
      }
      // 请求中已失效的物品数量。
      final int missingCount = normalizedItemIds.length - records.length;
      return InventoryMoveResult(
        movedCount: movedCount,
        followedCount: followedCount,
        unchangedCount: unchangedCount,
        missingCount: missingCount,
        destinationName: destination.name,
      );
    });
  }

  /// 将物品移入回收站。
  Future<void> delete(String id) async {
    // 当前删除时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      await (_database.update(_database.inventoryItems)..where(
            (InventoryItems table) =>
                table.id.equals(id) | table.parentItemId.equals(id),
          ))
          .write(
            InventoryItemsCompanion(
              deletedAt: Value<DateTime>(now),
              updatedAt: Value<DateTime>(now),
              syncState: const Value<String>('localSaved'),
            ),
          );
    });
  }

  /// 将标签集合规范化为稳定文本。
  String? _normalizeTags(List<String> tags) {
    // 去重并清理后的标签。
    final Set<String> normalized = tags
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toSet();
    return normalized.isEmpty ? null : normalized.join(',');
  }

  /// 替换一条物品的规范分类关系。
  Future<void> _replaceCategoryLinks(
    String recordId,
    Set<String> categoryIds,
    DateTime now,
  ) async {
    await (_database.update(_database.recordTaxonomyLinks)..where(
          (RecordTaxonomyLinks table) =>
              table.module.equals('inventory') &
              table.recordId.equals(recordId) &
              table.deletedAt.isNull(),
        ))
        .write(RecordTaxonomyLinksCompanion(deletedAt: Value<DateTime>(now)));
    for (final String taxonomyId in categoryIds) {
      await _database
          .into(_database.recordTaxonomyLinks)
          .insert(
            RecordTaxonomyLinksCompanion.insert(
              id: _uuid.v7(),
              module: 'inventory',
              recordId: recordId,
              taxonomyId: taxonomyId,
              createdAt: now,
            ),
          );
    }
  }

  /// 清理可选文本。
  String? _cleanOptional(String? value) {
    // 清理后的文本。
    final String? normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
