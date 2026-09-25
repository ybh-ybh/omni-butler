import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/omni_sync_schema.dart';
import 'package:powersync/powersync.dart';

/// 验证 PowerSync Raw Table 与 Drift 业务表共用同一 SQLite 文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('每日选择下行 SQL 归并旧身份且旧身份删除不影响后续正常上传', () async {
    // 当前用例独占的真实 SQLite 文件目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_daily_downlink_',
    );
    // SQL 归并和后续真实运行时共用的文件。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}runtime.sqlite';
    // 下行 SQL 先在没有业务写入触发器的真实 SQLite 上验证。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    // 后续安装生产 CRUD 触发器，验证普通编辑仍可上传。
    OmniSyncRuntime? runtime;
    // 生产每日选择映射，保留 inferred schema 供初始化和触发器使用。
    final RawTable table = omniSyncSchema.rawTables.singleWhere(
      (RawTable table) => table.name == 'daily_quote_selections',
    );
    // 服务端时间仍使用 ISO 文本，交由 Drift 正常解析。
    final DateTime createdAt = DateTime.utc(2099, 1, 1, 2, 3);
    // 服务端最后更新时间。
    final DateTime updatedAt = DateTime.utc(2099, 1, 1, 4, 5);
    try {
      expect(table.schema!.syncedColumns, <String>[
        'day_key',
        'quote_id',
        'created_at',
        'updated_at',
      ]);
      try {
        await fixture
            .into(fixture.quotes)
            .insert(
              QuotesCompanion.insert(
                id: 'quote',
                content: '每日选择回归',
                createdAt: createdAt,
                updatedAt: createdAt,
              ),
            );
        await fixture
            .into(fixture.dailyQuoteSelections)
            .insert(
              DailyQuoteSelectionsCompanion.insert(
                id: 'legacy',
                dayKey: '2099-01-01',
                quoteId: const Value<String?>('quote'),
                createdAt: createdAt,
                updatedAt: createdAt,
              ),
            );
        // 直接验证 SQL 约束和日期映射；同步上下文的触发器抑制另由 E2E 覆盖。
        await fixture.customStatement(table.put!.sql, <Object?>[
          'canonical',
          '2099-01-01',
          null,
          createdAt.toIso8601String(),
          updatedAt.toIso8601String(),
        ]);
        // 相同主键的后续下行更新也应保持单行。
        await fixture.customStatement(table.put!.sql, <Object?>[
          'canonical',
          '2099-01-01',
          'quote',
          createdAt.toIso8601String(),
          updatedAt.toIso8601String(),
        ]);
        await fixture.customStatement(table.delete!.sql, <Object?>['legacy']);
      } finally {
        await fixture.close();
      }
      runtime = await OmniSyncRuntime.openAtPath(
        AuthRepository(const FlutterSecureStorage()),
        databasePath,
      );
      // 归并后的唯一业务记录。
      final DailyQuoteSelectionRecord selection = await runtime.database
          .select(runtime.database.dailyQuoteSelections)
          .getSingle();
      expect(selection.id, 'canonical');
      expect(selection.quoteId, 'quote');
      expect(selection.createdAt, createdAt);
      expect(selection.updatedAt, updatedAt);
      // 先确认运行时首次导入的完整 PUT 队列。
      final CrudBatch? fixtureBatch = await runtime.powerSync.getCrudBatch();
      expect(
        fixtureBatch!.crud
            .where((CrudEntry entry) => entry.table == 'daily_quote_selections')
            .single
            .id,
        'canonical',
      );
      await fixtureBatch.complete();
      await (runtime.database.update(
        runtime.database.dailyQuoteSelections,
      )..where((DailyQuoteSelections row) => row.id.equals('canonical'))).write(
        const DailyQuoteSelectionsCompanion(quoteId: Value<String?>(null)),
      );
      // 身份归并后正常业务修改必须仍由原有触发器捕获为 PATCH。
      final CrudBatch? localEdit = await runtime.powerSync.getCrudBatch();
      expect(localEdit!.crud, hasLength(1));
      expect(localEdit.crud.single.op, UpdateType.patch);
      expect(localEdit.crud.single.id, 'canonical');
      expect(localEdit.crud.single.opData, containsPair('quote_id', null));
    } finally {
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('v11 会员闲置字段删除后保留计费周期和支付有效期并生成兼容 PUT', () async {
    // 当前测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_membership_v12_',
    );
    // 真实 PowerSync 与 Drift 共用的数据库路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}db.sqlite';
    // 用当前结构补回旧字段构造 v11 夹具。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    // 固定业务日期。
    final DateTime now = DateTime.utc(2026, 9, 25);
    // 当前打开的运行时。
    OmniSyncRuntime? runtime;
    try {
      try {
        await fixture
            .into(fixture.memberships)
            .insert(
              MembershipsCompanion.insert(
                id: '01990000-7000-8002-8000-000000000111',
                name: '保留的月费会员',
                billingCycle: const Value<String>('month'),
                purchaseDate: now,
                createdAt: now,
                updatedAt: now,
              ),
            );
        await fixture
            .into(fixture.membershipPayments)
            .insert(
              MembershipPaymentsCompanion.insert(
                id: '01990000-7000-8002-8000-000000000112',
                membershipId: '01990000-7000-8002-8000-000000000111',
                amountCents: 2000,
                paidAt: now,
                validFrom: Value<DateTime>(now),
                validUntil: Value<DateTime>(DateTime.utc(2026, 10, 25)),
                createdAt: now,
              ),
            );
        await fixture.customStatement(
          'ALTER TABLE memberships ADD COLUMN payment_method TEXT',
        );
        await fixture.customStatement(
          'ALTER TABLE memberships ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
        );
        await fixture.customStatement(
          'ALTER TABLE membership_payments ADD COLUMN billing_cycle TEXT',
        );
        await fixture.customStatement('PRAGMA user_version = 11');
      } finally {
        await fixture.close();
      }
      runtime = await OmniSyncRuntime.openAtPath(
        AuthRepository(const FlutterSecureStorage()),
        databasePath,
      );
      // 升级后保留的会员主记录。
      final MembershipRecord membership = await runtime.database
          .select(runtime.database.memberships)
          .getSingle();
      // 升级后保留的支付记录。
      final MembershipPaymentRecord payment = await runtime.database
          .select(runtime.database.membershipPayments)
          .getSingle();
      expect(membership.billingCycle, 'month');
      expect(payment.amountCents, 2000);
      expect(payment.validUntil, DateTime.utc(2026, 10, 25));
      // 会员表物理列名。
      final List<Map<String, Object?>> memberColumns = await runtime.powerSync
          .getAll("PRAGMA table_info('memberships')");
      // 支付表物理列名。
      final List<Map<String, Object?>> paymentColumns = await runtime.powerSync
          .getAll("PRAGMA table_info('membership_payments')");
      expect(
        memberColumns.map((row) => row['name']),
        isNot(contains('payment_method')),
      );
      expect(
        memberColumns.map((row) => row['name']),
        isNot(contains('is_favorite')),
      );
      expect(
        paymentColumns.map((row) => row['name']),
        isNot(contains('billing_cycle')),
      );
      // 初次同步导入的完整事务。
      final CrudTransaction? imported = await runtime.powerSync
          .getNextCrudTransaction();
      expect(imported!.crud, hasLength(2));
      expect(imported.crud.first.opData!['billing_cycle'], 'month');
      expect(imported.crud.first.opData, isNot(contains('payment_method')));
      expect(imported.crud.first.opData, isNot(contains('is_favorite')));
      expect(imported.crud.last.opData, isNot(contains('billing_cycle')));
    } finally {
      await runtime?.close();
      await directory.delete(recursive: true);
    }
  });

  test('捕获业务写入并排除仅本机字段', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_powersync_',
    );
    // 无需真正读写安全存储的认证仓储。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 使用真实 PowerSync SQLite 引擎的测试运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}${Platform.pathSeparator}runtime.sqlite',
    );
    try {
      // 当前 PowerSync 物品表字段信息。
      final List<Map<String, Object?>> inventoryColumns = await runtime
          .powerSync
          .getAll("PRAGMA table_info('inventory_items')");
      // 当前 PowerSync 物品表字段名。
      final List<String> inventoryColumnNames = inventoryColumns
          .map((Map<String, Object?> row) => row['name']! as String)
          .toList(growable: false);
      expect(inventoryColumnNames, isNot(contains('brand')));
      expect(inventoryColumnNames, isNot(contains('model')));

      // 固定业务创建时间。
      final DateTime now = DateTime.utc(2026, 9, 5, 1, 2, 3);
      await runtime.database
          .into(runtime.database.todoItems)
          .insert(
            TodoItemsCompanion.insert(
              id: '01990000-7000-8002-8000-000000000001',
              title: '验证离线队列',
              scheduledDate: DateTime.utc(2026, 9, 5),
              syncState: const Value<String>('localSaved'),
              createdAt: now,
              updatedAt: now,
            ),
          );

      // 捕获到的第一批 PowerSync 操作。
      final CrudBatch? batch = await runtime.powerSync.getCrudBatch();
      expect(batch, isNotNull);
      expect(batch!.crud, hasLength(1));
      // 待办新增操作。
      final CrudEntry operation = batch.crud.single;
      expect(operation.table, 'todo_items');
      expect(operation.op, UpdateType.put);
      expect(operation.opData?['title'], '验证离线队列');
      expect(operation.opData?['created_at'], isA<String>());
      expect(operation.opData, isNot(contains('sync_state')));
      await batch.complete();

      await (runtime.database.update(runtime.database.todoItems)
            ..where((TodoItems table) => table.id.equals(operation.id)))
          .write(const TodoItemsCompanion(syncState: Value<String>('synced')));
      // 只改本机同步提示不应形成新的云端写入。
      final CrudBatch? localOnlyBatch = await runtime.powerSync.getCrudBatch();
      expect(localOnlyBatch, isNull);

      await runtime.powerSync.execute(
        'INSERT INTO device_sync_metadata(id, value) VALUES(?, ?)',
        <Object?>['owner', '01990000-7000-8002-8000-000000000099'],
      );
      await runtime.disconnectAndClear();
      // 用户明确删除本机数据后，业务行与服务端身份归属都被清空。
      final List<TodoRecord> remainingTodos = await runtime.database
          .select(runtime.database.todoItems)
          .get();
      // 清空后的本机服务端身份归属元数据。
      final owner = await runtime.powerSync.getOptional(
        'SELECT value FROM device_sync_metadata WHERE id = ?',
        <Object?>['owner'],
      );
      expect(remainingTodos, isEmpty);
      expect(owner, isNull);
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('旧待办紧急程度字段可经真实 PowerSync 运行时升级为优先象限', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_powersync_migration_',
    );
    // 真实 PowerSync 与 Drift 共用的 SQLite 文件路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}migration.sqlite';
    // 用最新结构创建后回退字段名的 v4 测试夹具。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    await fixture.customSelect('SELECT 1').get();
    await fixture.customStatement(
      'ALTER TABLE todo_items RENAME COLUMN priority_quadrant TO urgency',
    );
    await fixture.customStatement('PRAGMA user_version = 4');
    await fixture.close();

    // 无需真正读写安全存储的认证仓储。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 从旧结构打开的新同步运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
    );
    try {
      // 新运行时中的待办表字段信息。
      final List<Map<String, Object?>> columns = await runtime.powerSync.getAll(
        "PRAGMA table_info('todo_items')",
      );
      // 新运行时中的待办表字段名。
      final List<String> columnNames = columns
          .map((Map<String, Object?> row) => row['name']! as String)
          .toList(growable: false);
      expect(columnNames, contains('priority_quadrant'));
      expect(columnNames, isNot(contains('urgency')));
      expect(columnNames, isNot(contains('notes')));
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });

  test('旧物品品牌型号字段可经真实 PowerSync 运行时安全删除', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_powersync_inventory_migration_',
    );
    // 真实 PowerSync 与 Drift 共用的 SQLite 文件路径。
    final String databasePath =
        '${directory.path}${Platform.pathSeparator}migration.sqlite';
    // 固定测试数据时间。
    final DateTime now = DateTime.utc(2026, 9, 8, 2);
    // 用最新结构创建后补回品牌型号列，构造 v6 测试夹具。
    final AppDatabase fixture = AppDatabase.forTesting(
      NativeDatabase(File(databasePath)),
    );
    await fixture.customSelect('SELECT 1').get();
    await fixture
        .into(fixture.inventoryItems)
        .insert(
          InventoryItemsCompanion.insert(
            id: 'legacy-powersync-inventory-item',
            name: '旧同步相机',
            notes: const Value<String?>('保留同步备注'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await fixture.customStatement(
      'ALTER TABLE inventory_items ADD COLUMN brand TEXT',
    );
    await fixture.customStatement(
      'ALTER TABLE inventory_items ADD COLUMN model TEXT',
    );
    await fixture.customStatement('PRAGMA user_version = 6');
    await fixture.close();

    // 无需真正读写安全存储的认证仓储。
    final AuthRepository auth = AuthRepository(const FlutterSecureStorage());
    // 从旧结构打开的新同步运行时。
    final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
      auth,
      databasePath,
    );
    try {
      // 新运行时中的物品表字段信息。
      final List<Map<String, Object?>> columns = await runtime.powerSync.getAll(
        "PRAGMA table_info('inventory_items')",
      );
      // 新运行时中的物品表字段名。
      final List<String> columnNames = columns
          .map((Map<String, Object?> row) => row['name']! as String)
          .toList(growable: false);
      // 升级后保留下来的物品记录。
      final InventoryRecord item = await runtime.database
          .select(runtime.database.inventoryItems)
          .getSingle();

      expect(columnNames, isNot(contains('brand')));
      expect(columnNames, isNot(contains('model')));
      expect(item.name, '旧同步相机');
      expect(item.notes, '保留同步备注');
    } finally {
      await runtime.close();
      await directory.delete(recursive: true);
    }
  });
}
