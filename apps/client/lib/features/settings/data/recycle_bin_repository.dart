import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';

/// 回收站业务类型。
enum RecycleEntityType {
  /// 待办。
  todo,

  /// 周期事件。
  event,

  /// 物品。
  inventory,

  /// 时间记录。
  timeEntry,

  /// 会员。
  membership,

  /// 名言。
  quote,
}

/// 回收站统一展示项。
class RecycleBinItem {
  /// 业务类型。
  final RecycleEntityType type;

  /// 记录标识。
  final String id;

  /// 展示标题。
  final String title;

  /// 删除时间。
  final DateTime deletedAt;

  /// 创建回收站展示项。
  const RecycleBinItem({
    required this.type,
    required this.id,
    required this.title,
    required this.deletedAt,
  });
}

/// 跨模块统一回收站仓储。
class RecycleBinRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// 待办仓储，用于保持任务树恢复与永久删除语义。
  final TodoRepository _todoRepository;

  /// 创建统一回收站仓储。
  const RecycleBinRepository(this._database, this._todoRepository);

  /// 读取全部顶层软删除记录。
  Future<List<RecycleBinItem>> loadItems() => _loadItems(grouped: true);

  /// 监听六张业务表，事务读取保证分组来自同一数据库快照。
  Stream<List<RecycleBinItem>> watchItems() {
    return _database
        .customSelect(
          'SELECT COUNT(*) FROM todo_items UNION ALL '
          'SELECT COUNT(*) FROM events UNION ALL '
          'SELECT COUNT(*) FROM inventory_items UNION ALL '
          'SELECT COUNT(*) FROM time_entries UNION ALL '
          'SELECT COUNT(*) FROM memberships UNION ALL '
          'SELECT COUNT(*) FROM quotes',
          readsFrom: {
            _database.todoItems,
            _database.events,
            _database.inventoryItems,
            _database.timeEntries,
            _database.memberships,
            _database.quotes,
          },
        )
        .watch()
        .asyncMap((_) => _database.transaction(loadItems));
  }

  /// 按展示或清理用途读取软删除记录；清理不隐藏任何子项。
  Future<List<RecycleBinItem>> _loadItems({required bool grouped}) async {
    // 合并后的回收站记录。
    final List<RecycleBinItem> items = <RecycleBinItem>[];
    // 已删除待办。
    final List<TodoRecord> todos = await (_database.select(
      _database.todoItems,
    )..where((TodoItems table) => table.deletedAt.isNotNull())).get();
    // 按标识索引的已删除待办。
    final Map<String, TodoRecord> deletedTodosById = <String, TodoRecord>{
      for (final TodoRecord todo in todos) todo.id: todo,
    };
    // 只展示主任务或被独立删除的子任务，隐藏随主任务同批删除的子项。
    final List<TodoRecord> visibleTodos = todos
        .where((TodoRecord record) {
          // 可选已删除父任务。
          final TodoRecord? parent = record.parentId == null
              ? null
              : deletedTodosById[record.parentId!];
          return parent == null || parent.deletedAt != record.deletedAt;
        })
        .toList(growable: false);
    items.addAll(
      (grouped ? visibleTodos : todos).map(
        (TodoRecord record) => RecycleBinItem(
          type: RecycleEntityType.todo,
          id: record.id,
          title: record.title,
          deletedAt: record.deletedAt!.toLocal(),
        ),
      ),
    );
    // 已删除事件。
    final List<EventRecord> events = await (_database.select(
      _database.events,
    )..where((Events table) => table.deletedAt.isNotNull())).get();
    items.addAll(
      events.map(
        (EventRecord record) => RecycleBinItem(
          type: RecycleEntityType.event,
          id: record.id,
          title: record.name,
          deletedAt: record.deletedAt!.toLocal(),
        ),
      ),
    );
    // 已删除物品及独立删除的配件。
    final List<InventoryRecord> inventory = await (_database.select(
      _database.inventoryItems,
    )..where((InventoryItems table) => table.deletedAt.isNotNull())).get();
    // 已删除物品索引，用于隐藏随主物品同批删除的配件。
    final Map<String, InventoryRecord> deletedInventoryById = {
      for (final InventoryRecord record in inventory) record.id: record,
    };
    items.addAll(
      inventory
          .where((InventoryRecord record) {
            // 当前配件的已删除父物品。
            final InventoryRecord? parent =
                deletedInventoryById[record.parentItemId];
            return !grouped ||
                parent == null ||
                parent.deletedAt != record.deletedAt;
          })
          .map(
            (InventoryRecord record) => RecycleBinItem(
              type: RecycleEntityType.inventory,
              id: record.id,
              title: record.name,
              deletedAt: record.deletedAt!.toLocal(),
            ),
          ),
    );
    // 已删除时间记录。
    final List<TimeEntryRecord> timeEntries = await (_database.select(
      _database.timeEntries,
    )..where((TimeEntries table) => table.deletedAt.isNotNull())).get();
    items.addAll(
      timeEntries.map(
        (TimeEntryRecord record) => RecycleBinItem(
          type: RecycleEntityType.timeEntry,
          id: record.id,
          title: record.activity ?? '未命名记录',
          deletedAt: record.deletedAt!.toLocal(),
        ),
      ),
    );
    // 已删除会员。
    final List<MembershipRecord> memberships = await (_database.select(
      _database.memberships,
    )..where((Memberships table) => table.deletedAt.isNotNull())).get();
    items.addAll(
      memberships.map(
        (MembershipRecord record) => RecycleBinItem(
          type: RecycleEntityType.membership,
          id: record.id,
          title: record.name,
          deletedAt: record.deletedAt!.toLocal(),
        ),
      ),
    );
    // 已删除名言。
    final List<QuoteRecord> quotes = await (_database.select(
      _database.quotes,
    )..where((Quotes table) => table.deletedAt.isNotNull())).get();
    items.addAll(
      quotes.map(
        (QuoteRecord record) => RecycleBinItem(
          type: RecycleEntityType.quote,
          id: record.id,
          title: record.content,
          deletedAt: record.deletedAt!.toLocal(),
        ),
      ),
    );
    items.sort(
      (RecycleBinItem left, RecycleBinItem right) =>
          right.deletedAt.compareTo(left.deletedAt),
    );
    return items;
  }

  /// 恢复一条顶层业务记录。
  Future<void> restore(RecycleBinItem item) => _database.transaction(() async {
    if (!await _isCurrent(item)) return;
    // 当前恢复时间。
    final DateTime now = DateTime.now();
    switch (item.type) {
      case RecycleEntityType.todo:
        await _todoRepository.restore(item.id);
      case RecycleEntityType.event:
        await (_database.update(
          _database.events,
        )..where((Events table) => table.id.equals(item.id))).write(
          EventsCompanion(
            deletedAt: const Value<DateTime?>(null),
            updatedAt: Value<DateTime>(now),
          ),
        );
      case RecycleEntityType.inventory:
        await _database.transaction(() async {
          await (_database.update(_database.inventoryItems)..where(
                (InventoryItems table) =>
                    (table.id.equals(item.id) |
                        table.parentItemId.equals(item.id)) &
                    table.deletedAt.equals(item.deletedAt),
              ))
              .write(
                InventoryItemsCompanion(
                  deletedAt: const Value<DateTime?>(null),
                  updatedAt: Value<DateTime>(now),
                ),
              );
        });
      case RecycleEntityType.timeEntry:
        await (_database.update(
          _database.timeEntries,
        )..where((TimeEntries table) => table.id.equals(item.id))).write(
          TimeEntriesCompanion(
            deletedAt: const Value<DateTime?>(null),
            updatedAt: Value<DateTime>(now),
          ),
        );
      case RecycleEntityType.membership:
        await (_database.update(
          _database.memberships,
        )..where((Memberships table) => table.id.equals(item.id))).write(
          MembershipsCompanion(
            deletedAt: const Value<DateTime?>(null),
            updatedAt: Value<DateTime>(now),
          ),
        );
      case RecycleEntityType.quote:
        await (_database.update(
          _database.quotes,
        )..where((Quotes table) => table.id.equals(item.id))).write(
          QuotesCompanion(
            deletedAt: const Value<DateTime?>(null),
            updatedAt: Value<DateTime>(now),
          ),
        );
    }
  });

  /// 在当前事务中复核软删除时间，防止旧界面操作删除已经恢复的记录。
  Future<bool> _isCurrent(RecycleBinItem item, {DateTime? cutoff}) async {
    // 当前业务记录的删除时间。
    final DateTime? deletedAt = await switch (item.type) {
      RecycleEntityType.todo =>
        (_database.select(_database.todoItems)
              ..where((TodoItems table) => table.id.equals(item.id)))
            .map((TodoRecord record) => record.deletedAt)
            .getSingleOrNull(),
      RecycleEntityType.event =>
        (_database.select(_database.events)
              ..where((Events table) => table.id.equals(item.id)))
            .map((EventRecord record) => record.deletedAt)
            .getSingleOrNull(),
      RecycleEntityType.inventory =>
        (_database.select(_database.inventoryItems)
              ..where((InventoryItems table) => table.id.equals(item.id)))
            .map((InventoryRecord record) => record.deletedAt)
            .getSingleOrNull(),
      RecycleEntityType.timeEntry =>
        (_database.select(_database.timeEntries)
              ..where((TimeEntries table) => table.id.equals(item.id)))
            .map((TimeEntryRecord record) => record.deletedAt)
            .getSingleOrNull(),
      RecycleEntityType.membership =>
        (_database.select(_database.memberships)
              ..where((Memberships table) => table.id.equals(item.id)))
            .map((MembershipRecord record) => record.deletedAt)
            .getSingleOrNull(),
      RecycleEntityType.quote =>
        (_database.select(_database.quotes)
              ..where((Quotes table) => table.id.equals(item.id)))
            .map((QuoteRecord record) => record.deletedAt)
            .getSingleOrNull(),
    };
    return deletedAt != null &&
        deletedAt.isAtSameMomentAs(item.deletedAt) &&
        (cutoff == null || deletedAt.isBefore(cutoff));
  }

  /// 永久删除一条顶层业务记录及其从属历史。
  Future<void> permanentlyDelete(RecycleBinItem item) async {
    await _deleteIfCurrent(item);
  }

  /// 复核后永久删除，返回是否实际处理了这条记录。
  Future<bool> _deleteIfCurrent(RecycleBinItem item, {DateTime? cutoff}) async {
    return _database.transaction(() async {
      if (!await _isCurrent(item, cutoff: cutoff)) return false;
      await _preserveChildren(item, cutoff: cutoff);
      switch (item.type) {
        case RecycleEntityType.todo:
          await _todoRepository.permanentlyDelete(item.id);
        case RecycleEntityType.event:
          await (_database.delete(_database.eventCompletions)..where(
                (EventCompletions table) => table.eventId.equals(item.id),
              ))
              .go();
          await (_database.delete(
            _database.events,
          )..where((Events table) => table.id.equals(item.id))).go();
        case RecycleEntityType.inventory:
          await (_database.delete(_database.inventoryItems)..where(
                (InventoryItems table) =>
                    table.id.equals(item.id) |
                    table.parentItemId.equals(item.id),
              ))
              .go();
        case RecycleEntityType.timeEntry:
          await (_database.delete(
            _database.timeEntries,
          )..where((TimeEntries table) => table.id.equals(item.id))).go();
        case RecycleEntityType.membership:
          await (_database.delete(_database.membershipPayments)..where(
                (MembershipPayments table) =>
                    table.membershipId.equals(item.id),
              ))
              .go();
          await (_database.delete(
            _database.memberships,
          )..where((Memberships table) => table.id.equals(item.id))).go();
        case RecycleEntityType.quote:
          await (_database.update(_database.dailyQuoteSelections)..where(
                (DailyQuoteSelections table) => table.quoteId.equals(item.id),
              ))
              .write(
                DailyQuoteSelectionsCompanion(
                  quoteId: const Value<String?>(null),
                  updatedAt: Value<DateTime>(DateTime.now()),
                ),
              );
          await (_database.delete(
            _database.quotes,
          )..where((Quotes table) => table.id.equals(item.id))).go();
      }
      return true;
    });
  }

  /// 原子清空回收站，不依赖界面是否展示了从属记录。
  Future<int> empty() => _deleteBatch();

  /// 解除仍有效子项的父关联，避免父项级联删除活动或尚未过期的数据。
  Future<void> _preserveChildren(
    RecycleBinItem item, {
    DateTime? cutoff,
  }) async {
    // 本次调整关联的时间。
    final DateTime now = DateTime.now();
    if (item.type == RecycleEntityType.todo) {
      // 被现有待办树永久删除逻辑影响的直属子项。
      final List<TodoRecord> children = await (_database.select(
        _database.todoItems,
      )..where((TodoItems table) => table.parentId.equals(item.id))).get();
      for (final TodoRecord child in children) {
        if (child.deletedAt == null ||
            (cutoff != null && !child.deletedAt!.isBefore(cutoff))) {
          await (_database.update(
            _database.todoItems,
          )..where((TodoItems table) => table.id.equals(child.id))).write(
            TodoItemsCompanion(
              parentId: const Value(null),
              updatedAt: Value(now),
            ),
          );
        }
      }
    } else if (item.type == RecycleEntityType.inventory) {
      // 主物品删除时同样保留活动或尚未过期的配件。
      final List<InventoryRecord> children =
          await (_database.select(_database.inventoryItems)..where(
                (InventoryItems table) => table.parentItemId.equals(item.id),
              ))
              .get();
      for (final InventoryRecord child in children) {
        if (child.deletedAt == null ||
            (cutoff != null && !child.deletedAt!.isBefore(cutoff))) {
          await (_database.update(
            _database.inventoryItems,
          )..where((InventoryItems table) => table.id.equals(child.id))).write(
            InventoryItemsCompanion(
              parentItemId: const Value(null),
              updatedAt: Value(now),
            ),
          );
        }
      }
    }
  }

  /// 在一个事务中读取并复核全部候选记录，失败时整体回滚。
  Future<int> _deleteBatch({DateTime? cutoff}) =>
      _database.transaction(() async {
        // 当前数据库中全部已删除业务记录。
        final List<RecycleBinItem> items = await _loadItems(grouped: false);
        // 实际处理的业务记录数，已由父项级联删除的子项不重复计数。
        int count = 0;
        for (final RecycleBinItem item in items) {
          if (cutoff != null && !item.deletedAt.isBefore(cutoff)) continue;
          if (await _deleteIfCurrent(item, cutoff: cutoff)) count++;
        }
        return count;
      });

  /// 清理超过 30 天保留期的记录。
  Future<int> purgeExpired({DateTime? now}) async {
    // 过期边界时间。
    final DateTime cutoff = (now ?? DateTime.now()).subtract(
      const Duration(days: 30),
    );
    return _deleteBatch(cutoff: cutoff);
  }
}
