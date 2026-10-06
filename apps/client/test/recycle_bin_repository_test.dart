import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';

import 'support/recycle_bin_fixture.dart';

/// 验证真实数据库的清空、保留期、状态复核和PowerSync刷新。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 每个实例均使用独立数据库连接。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // 每个测试的独立内存数据库。
  late AppDatabase database;
  // 与生产相同的跨业务回收站仓储。
  late RecycleBinRepository repository;
  // 固定保留期时钟，UTC与本地表示相同绝对时刻。
  final DateTime now = DateTime.utc(2026, 10, 6, 8);

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = RecycleBinRepository(database, TodoRepository(database));
  });
  tearDown(() => database.close());

  test('清空六类业务及历史，保留活动记录与每日名言槽位', () async {
    for (final RecycleEntityType type in RecycleEntityType.values) {
      await seedRecycleRecord(database, type, type.name, now);
      await seedRecycleRecord(database, type, '${type.name}-active', null);
    }
    await database
        .into(database.eventCompletions)
        .insert(
          EventCompletionsCompanion.insert(
            id: 'history',
            eventId: 'event',
            completedAt: now,
            createdAt: now,
          ),
        );
    await database
        .into(database.membershipPayments)
        .insert(
          MembershipPaymentsCompanion.insert(
            id: 'payment',
            membershipId: 'membership',
            amountCents: 100,
            paidAt: now,
            createdAt: now,
          ),
        );
    await database
        .into(database.dailyQuoteSelections)
        .insert(
          DailyQuoteSelectionsCompanion.insert(
            id: 'slot',
            dayKey: '2026-10-06',
            quoteId: const Value('quote'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    expect(await repository.empty(), 6);
    expect(await repository.loadItems(), isEmpty);
    expect(await database.select(database.eventCompletions).get(), isEmpty);
    expect(await database.select(database.membershipPayments).get(), isEmpty);
    expect(
      (await database.select(database.dailyQuoteSelections).getSingle())
          .quoteId,
      isNull,
    );
    for (final TableInfo table in [
      database.todoItems,
      database.events,
      database.inventoryItems,
      database.timeEntries,
      database.memberships,
      database.quotes,
    ]) {
      expect(await database.select(table).get(), hasLength(1));
    }
    expect(await repository.empty(), 0);
  });

  test('独立子项可见，同批子项归并；恢复不会复活独立删除的配件', () async {
    for (final RecycleEntityType type in [
      RecycleEntityType.todo,
      RecycleEntityType.inventory,
    ]) {
      await seedRecycleRecord(database, type, '${type.name}-parent', now);
      await seedRecycleRecord(
        database,
        type,
        '${type.name}-same',
        now,
        parentId: '${type.name}-parent',
      );
      await seedRecycleRecord(
        database,
        type,
        '${type.name}-independent',
        now.subtract(const Duration(days: 1)),
        parentId: '${type.name}-parent',
      );
    }
    // 展示层只显示两个父项及两个独立删除的子项。
    final List<RecycleBinItem> items = await repository.loadItems();
    expect(items, hasLength(4));
    expect(
      items.map((RecycleBinItem item) => item.id),
      isNot(contains('inventory-same')),
    );
    await repository.restore(
      items.singleWhere((RecycleBinItem item) => item.id == 'inventory-parent'),
    );
    expect(
      (await database.select(database.inventoryItems).get())
          .where((InventoryRecord record) => record.deletedAt == null)
          .length,
      2,
    );
    await repository.empty();
    expect(await repository.loadItems(), isEmpty);
    expect(await database.select(database.todoItems).get(), isEmpty);
    expect(
      (await database.select(database.inventoryItems).get()).map(
        (InventoryRecord record) => record.id,
      ),
      containsAll(['inventory-parent', 'inventory-same']),
    );
  });

  test('六类业务严格超过30天才清理，UTC与本地边界等价', () async {
    for (final RecycleEntityType type in RecycleEntityType.values) {
      await seedRecycleRecord(
        database,
        type,
        '${type.name}-expired',
        now.subtract(const Duration(days: 30, seconds: 1)).toLocal(),
      );
      await seedRecycleRecord(
        database,
        type,
        '${type.name}-boundary',
        now.subtract(const Duration(days: 30)),
      );
      await seedRecycleRecord(
        database,
        type,
        '${type.name}-recent',
        now.subtract(const Duration(days: 29)),
      );
    }
    expect(await repository.purgeExpired(now: now.toLocal()), 6);
    expect(await repository.loadItems(), hasLength(12));
    expect(
      await repository.purgeExpired(now: now.add(const Duration(seconds: 1))),
      6,
    );
    expect(await repository.loadItems(), hasLength(6));
  });

  test('删除前复核，已恢复或重新删除的记录不接受旧界面操作', () async {
    for (final RecycleEntityType type in RecycleEntityType.values) {
      await seedRecycleRecord(
        database,
        type,
        type.name,
        now.subtract(const Duration(days: 31)),
      );
    }
    // 保存旧页面快照，随后恢复所有记录。
    final List<RecycleBinItem> stale = await repository.loadItems();
    for (final RecycleBinItem item in stale) {
      await repository.restore(item);
    }
    for (final RecycleBinItem item in stale) {
      await repository.permanentlyDelete(item);
    }
    expect(await database.select(database.quotes).get(), hasLength(1));
    await database
        .update(database.quotes)
        .write(QuotesCompanion(deletedAt: Value(now)));
    await repository.permanentlyDelete(
      stale.singleWhere(
        (RecycleBinItem item) => item.type == RecycleEntityType.quote,
      ),
    );
    await repository.restore(
      stale.singleWhere(
        (RecycleBinItem item) => item.type == RecycleEntityType.quote,
      ),
    );
    expect(
      (await database.select(database.quotes).getSingle()).deletedAt!
          .isAtSameMomentAs(now),
      isTrue,
    );
    expect(await repository.purgeExpired(now: now), 0);
  });

  test('清空中途数据库错误会回滚已删除记录及历史', () async {
    await seedRecycleRecord(database, RecycleEntityType.event, 'event', now);
    await seedRecycleRecord(
      database,
      RecycleEntityType.quote,
      'quote',
      now.subtract(const Duration(seconds: 1)),
    );
    await database
        .into(database.eventCompletions)
        .insert(
          EventCompletionsCompanion.insert(
            id: 'history',
            eventId: 'event',
            completedAt: now,
            createdAt: now,
          ),
        );
    await database.customStatement(
      "CREATE TRIGGER fail_delete BEFORE DELETE ON quotes BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    await expectLater(repository.empty(), throwsA(anything));
    expect(await repository.loadItems(), hasLength(2));
    expect(
      await database.select(database.eventCompletions).get(),
      hasLength(1),
    );
    await database.customStatement('DROP TRIGGER fail_delete');
    expect(await repository.empty(), 2);
  });

  test('独立删除的配件自动过期，活动父物品不受影响', () async {
    await seedRecycleRecord(
      database,
      RecycleEntityType.inventory,
      'parent',
      null,
    );
    await seedRecycleRecord(
      database,
      RecycleEntityType.inventory,
      'accessory',
      now.subtract(const Duration(days: 31)),
      parentId: 'parent',
    );
    expect(await repository.purgeExpired(now: now), 1);
    expect(
      (await database.select(database.inventoryItems).getSingle()).id,
      'parent',
    );
  });

  test('父项过期不带走已恢复或尚未过期的子项', () async {
    for (final RecycleEntityType type in [
      RecycleEntityType.todo,
      RecycleEntityType.inventory,
    ]) {
      await seedRecycleRecord(
        database,
        type,
        '${type.name}-parent',
        now.subtract(const Duration(days: 31)),
      );
      await seedRecycleRecord(
        database,
        type,
        '${type.name}-active',
        null,
        parentId: '${type.name}-parent',
      );
      await seedRecycleRecord(
        database,
        type,
        '${type.name}-recent',
        now,
        parentId: '${type.name}-parent',
      );
    }
    expect(await repository.purgeExpired(now: now), 2);
    expect(await repository.loadItems(), hasLength(2));
    expect(
      (await database.select(database.todoItems).get()).every(
        (TodoRecord row) => row.parentId == null,
      ),
      isTrue,
    );
    expect(
      (await database.select(database.inventoryItems).get()).every(
        (InventoryRecord row) => row.parentItemId == null,
      ),
      isTrue,
    );
    await repository.empty();
    expect(
      (await database.select(database.todoItems).getSingle()).id,
      'todo-active',
    );
    expect(
      (await database.select(database.inventoryItems).getSingle()).id,
      'inventory-active',
    );
  });

  test('数据库变化自动推送恢复和清空后的列表', () async {
    // 阻塞迭代器能验证每次写入确实唤醒当前订阅。
    final StreamIterator<List<RecycleBinItem>> changes = StreamIterator(
      repository.watchItems(),
    );
    try {
      expect(await changes.moveNext(), isTrue);
      expect(changes.current, isEmpty);
      await seedRecycleRecord(database, RecycleEntityType.quote, 'quote', now);
      expect(
        await changes.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(changes.current.single.id, 'quote');
      await repository.restore(changes.current.single);
      expect(
        await changes.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(changes.current, isEmpty);
    } finally {
      await changes.cancel();
    }
  });

  test('真实PowerSync写入刷新回收站，清空进入DELETE上传队列', () async {
    // 测试独占的临时目录，只删除明确创建的目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_recycle_',
    );
    // 与正式客户端相同的PowerSync/Drift桥接运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      AuthRepository(const FlutterSecureStorage()),
      '${directory.path}/runtime.sqlite',
      initializeUpload: false,
    );
    // 针对真实数据库的仓储及监听。
    final RecycleBinRepository real = RecycleBinRepository(
      runtime.database,
      TodoRepository(runtime.database),
    );
    // 长期订阅真实PowerSync数据库的变化。
    final StreamIterator<List<RecycleBinItem>> changes = StreamIterator(
      real.watchItems(),
    );
    try {
      await changes.moveNext();
      await seedRecycleRecord(
        runtime.database,
        RecycleEntityType.quote,
        'quote',
        now,
      );
      await changes.moveNext().timeout(const Duration(seconds: 5));
      expect(changes.current.single.id, 'quote');
      // 模拟同步引擎直接落库，绕过Drift写入仍应唤醒订阅。
      await runtime.powerSync.execute(
        'UPDATE quotes SET deleted_at = NULL WHERE id = ?',
        ['quote'],
      );
      await changes.moveNext().timeout(const Duration(seconds: 5));
      expect(changes.current, isEmpty);
      await runtime.database
          .update(runtime.database.quotes)
          .write(QuotesCompanion(deletedAt: Value(now)));
      await changes.moveNext().timeout(const Duration(seconds: 5));
      await real.empty();
      await changes.moveNext().timeout(const Duration(seconds: 5));
      expect(changes.current, isEmpty);
      // 队列原始操作中必须出现永久DELETE，继续沿用同步墓碑链路。
      final List<Map<String, Object?>> queue = await runtime.powerSync.getAll(
        'SELECT data FROM ps_crud',
      );
      expect(
        queue.any(
          (Map<String, Object?> row) =>
              row['data'].toString().contains('DELETE'),
        ),
        isTrue,
      );
    } finally {
      await changes.cancel();
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });
}
