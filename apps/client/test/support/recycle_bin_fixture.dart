import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';

/// 为回收站测试创建六类真实业务记录，避免依赖会播种或生成重复项的页面。
Future<void> seedRecycleRecord(
  AppDatabase database,
  RecycleEntityType type,
  String id,
  DateTime? deletedAt, {
  String? parentId,
  String? title,
}) async {
  // 固定创建时间，与保留期测试时钟分离。
  final DateTime createdAt = DateTime(2026, 1, 1);
  // 记录标识保持稳定，预览可以使用真实中文业务标题。
  final String label = title ?? id;
  switch (type) {
    case RecycleEntityType.todo:
      await database
          .into(database.todoItems)
          .insert(
            TodoItemsCompanion.insert(
              id: id,
              title: label,
              scheduledDate: createdAt,
              parentId: Value(parentId),
              createdAt: createdAt,
              updatedAt: createdAt,
              deletedAt: Value(deletedAt),
            ),
          );
    case RecycleEntityType.event:
      await database
          .into(database.events)
          .insert(
            EventsCompanion.insert(
              id: id,
              name: label,
              createdAt: createdAt,
              updatedAt: createdAt,
              deletedAt: Value(deletedAt),
            ),
          );
    case RecycleEntityType.inventory:
      await database
          .into(database.inventoryItems)
          .insert(
            InventoryItemsCompanion.insert(
              id: id,
              name: label,
              parentItemId: Value(parentId),
              createdAt: createdAt,
              updatedAt: createdAt,
              deletedAt: Value(deletedAt),
            ),
          );
    case RecycleEntityType.timeEntry:
      await database
          .into(database.timeEntries)
          .insert(
            TimeEntriesCompanion.insert(
              id: id,
              entryDate: createdAt,
              startMinute: 0,
              endMinute: 1,
              startedAt: createdAt,
              endedAt: Value(createdAt.add(const Duration(minutes: 1))),
              activity: Value(label),
              createdAt: createdAt,
              updatedAt: createdAt,
              deletedAt: Value(deletedAt),
            ),
          );
    case RecycleEntityType.membership:
      await database
          .into(database.memberships)
          .insert(
            MembershipsCompanion.insert(
              id: id,
              name: label,
              purchaseDate: createdAt,
              createdAt: createdAt,
              updatedAt: createdAt,
              deletedAt: Value(deletedAt),
            ),
          );
    case RecycleEntityType.quote:
      await database
          .into(database.quotes)
          .insert(
            QuotesCompanion.insert(
              id: id,
              content: label,
              createdAt: createdAt,
              updatedAt: createdAt,
              deletedAt: Value(deletedAt),
            ),
          );
  }
}
