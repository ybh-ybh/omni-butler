import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:powersync/powersync.dart';

/// 验证 PowerSync Raw Table 与 Drift 业务表共用同一 SQLite 文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('捕获业务写入并排除仅本机字段', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_powersync_',
    );
    // 无需真正读写安全存储的认证仓储。
    const AuthRepository auth = AuthRepository(FlutterSecureStorage());
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
    const AuthRepository auth = AuthRepository(FlutterSecureStorage());
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
    const AuthRepository auth = AuthRepository(FlutterSecureStorage());
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
