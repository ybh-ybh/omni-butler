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
  Future<List<RecycleBinItem>> loadItems() async {
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
      visibleTodos.map(
        (TodoRecord record) => RecycleBinItem(
          type: RecycleEntityType.todo,
          id: record.id,
          title: record.title,
          deletedAt: record.deletedAt!,
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
          deletedAt: record.deletedAt!,
        ),
      ),
    );
    // 已删除物品，仅显示顶层物品。
    final List<InventoryRecord> inventory =
        await (_database.select(_database.inventoryItems)..where(
              (InventoryItems table) =>
                  table.deletedAt.isNotNull() & table.parentItemId.isNull(),
            ))
            .get();
    items.addAll(
      inventory.map(
        (InventoryRecord record) => RecycleBinItem(
          type: RecycleEntityType.inventory,
          id: record.id,
          title: record.name,
          deletedAt: record.deletedAt!,
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
          deletedAt: record.deletedAt!,
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
          deletedAt: record.deletedAt!,
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
          deletedAt: record.deletedAt!,
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
  Future<void> restore(RecycleBinItem item) async {
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
                    table.id.equals(item.id) |
                    table.parentItemId.equals(item.id),
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
  }

  /// 永久删除一条顶层业务记录及其从属历史。
  Future<void> permanentlyDelete(RecycleBinItem item) async {
    await _database.transaction(() async {
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
          await (_database.delete(_database.dailyQuoteSelections)..where(
                (DailyQuoteSelections table) => table.quoteId.equals(item.id),
              ))
              .go();
          await (_database.delete(
            _database.quotes,
          )..where((Quotes table) => table.id.equals(item.id))).go();
      }
    });
  }

  /// 清理超过 30 天保留期的记录。
  Future<int> purgeExpired({DateTime? now}) async {
    // 过期边界时间。
    final DateTime cutoff = (now ?? DateTime.now()).subtract(
      const Duration(days: 30),
    );
    // 全部回收站记录。
    final List<RecycleBinItem> items = await loadItems();
    // 已过期记录。
    final List<RecycleBinItem> expired = items
        .where((RecycleBinItem item) => !item.deletedAt.isAfter(cutoff))
        .toList(growable: false);
    for (final RecycleBinItem item in expired) {
      await permanentlyDelete(item);
    }
    return expired.length;
  }
}
