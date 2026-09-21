import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';

/// 验证 v2 本地数据升级为最新 PowerSync 兼容结构且内容不丢失。
void main() {
  test('v2 日期、内置标识、待办象限与父任务字段安全迁移到 v10', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_migration_',
    );
    // 测试数据库文件。
    final File databaseFile = File(
      '${directory.path}${Platform.pathSeparator}migration.sqlite',
    );
    // 先创建完整表，再构造一份包含典型旧数据的 v2 结构。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    await database.customSelect('SELECT 1').get();
    await _downgradeFixtureToV2(database);
    await database.close();

    database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    try {
      // 触发 Drift onUpgrade。
      await database.customSelect('SELECT 1').get();
      // 迁移后的每日名言选择。
      final DailyQuoteSelectionRecord selection = await database
          .select(database.dailyQuoteSelections)
          .getSingle();
      // 迁移后的旧版内置名言。
      final QuoteRecord quote = await database
          .select(database.quotes)
          .getSingle();
      // 迁移后的旧版内置分类。
      final TaxonomyEntry taxonomy = await database
          .select(database.taxonomyEntries)
          .getSingle();
      // 迁移后的待办表字段信息。
      final List<QueryRow> todoColumns = await database
          .customSelect("PRAGMA table_info('todo_items')")
          .get();
      // 迁移后的待办表字段名。
      final List<String> todoColumnNames = todoColumns
          .map((QueryRow row) => row.read<String>('name'))
          .toList(growable: false);
      // 迁移后的优先象限字段默认值。
      final String? priorityQuadrantDefault = todoColumns
          .singleWhere(
            (QueryRow row) => row.read<String>('name') == 'priority_quadrant',
          )
          .readNullable<String>('dflt_value');

      expect(selection.id, matches(_uuidPattern));
      expect(selection.quoteId, quote.id);
      expect(quote.content, '旧版名言');
      expect(
        quote.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1725498000000, isUtc: true),
      );
      expect(taxonomy.id, matches(_uuidPattern));
      expect(taxonomy.normalizedName, '工作');
      expect(todoColumnNames, contains('priority_quadrant'));
      expect(todoColumnNames, contains('parent_id'));
      expect(todoColumnNames, isNot(contains('urgency')));
      expect(todoColumnNames, isNot(contains('notes')));
      expect(priorityQuadrantDefault, '2');
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('v9 待办表升级到 v10 后删除备注且保留其他业务数据', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_todo_notes_migration_',
    );
    // 测试数据库文件。
    final File databaseFile = File(
      '${directory.path}${Platform.pathSeparator}migration.sqlite',
    );
    // 固定测试数据时间。
    final DateTime now = DateTime.utc(2026, 9, 21, 7);
    // 先创建最新结构，再补回 v9 的备注列构造升级夹具。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    await database.customSelect('SELECT 1').get();
    await database
        .into(database.todoItems)
        .insert(
          TodoItemsCompanion.insert(
            id: 'legacy-todo-with-notes',
            title: '保留待办主体',
            description: const Value<String?>('保留描述'),
            scheduledDate: DateTime.utc(2026, 9, 21),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database.customStatement(
      'ALTER TABLE todo_items ADD COLUMN notes TEXT',
    );
    await database.customStatement(
      'UPDATE todo_items SET notes = ? WHERE id = ?',
      <Object?>['应被丢弃的旧备注', 'legacy-todo-with-notes'],
    );
    await database.customStatement('PRAGMA user_version = 9');
    await database.close();

    database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    try {
      // 触发 Drift v9 到 v10 升级。
      await database.customSelect('SELECT 1').get();
      // 升级后的待办表字段信息。
      final List<QueryRow> todoColumns = await database
          .customSelect("PRAGMA table_info('todo_items')")
          .get();
      // 升级后的待办表字段名。
      final List<String> todoColumnNames = todoColumns
          .map((QueryRow row) => row.read<String>('name'))
          .toList(growable: false);
      // 升级后重建的待办索引。
      final List<String> todoIndexNames =
          (await database.customSelect("PRAGMA index_list('todo_items')").get())
              .map((QueryRow row) => row.read<String>('name'))
              .toList();
      // 升级后保留的待办记录。
      final TodoRecord todo = await database
          .select(database.todoItems)
          .getSingle();

      expect(todoColumnNames, isNot(contains('notes')));
      expect(todo.title, '保留待办主体');
      expect(todo.description, '保留描述');
      expect(todoIndexNames, contains('todo_items_parent_sort_idx'));
      expect(todoIndexNames, contains('todo_items_completed_at_idx'));
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('v6 物品表升级到 v8 后删除品牌型号且保留业务数据', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_inventory_migration_',
    );
    // 测试数据库文件。
    final File databaseFile = File(
      '${directory.path}${Platform.pathSeparator}migration.sqlite',
    );
    // 固定测试数据时间。
    final DateTime now = DateTime.utc(2026, 9, 8, 2);
    // 先创建最新结构，再补回 v6 已下线列以构造升级夹具。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    await database.customSelect('SELECT 1').get();
    await database
        .into(database.inventoryItems)
        .insert(
          InventoryItemsCompanion.insert(
            id: 'legacy-inventory-item',
            name: '旧相机',
            notes: const Value<String?>('需要保留的备注'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database.customStatement(
      'ALTER TABLE inventory_items ADD COLUMN brand TEXT',
    );
    await database.customStatement(
      'ALTER TABLE inventory_items ADD COLUMN model TEXT',
    );
    await database.customStatement(
      'UPDATE inventory_items SET brand = ?, model = ? WHERE id = ?',
      <Object?>['旧品牌', '旧型号', 'legacy-inventory-item'],
    );
    await database.customStatement('PRAGMA user_version = 6');
    await database.close();

    database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    try {
      // 触发 Drift v6 到 v7 升级。
      await database.customSelect('SELECT 1').get();
      // 升级后的物品表字段信息。
      final List<QueryRow> inventoryColumns = await database
          .customSelect("PRAGMA table_info('inventory_items')")
          .get();
      // 升级后的物品表字段名。
      final List<String> inventoryColumnNames = inventoryColumns
          .map((QueryRow row) => row.read<String>('name'))
          .toList(growable: false);
      // 升级后保留下来的业务记录。
      final InventoryRecord item = await database
          .select(database.inventoryItems)
          .getSingle();

      expect(inventoryColumnNames, isNot(contains('brand')));
      expect(inventoryColumnNames, isNot(contains('model')));
      expect(item.name, '旧相机');
      expect(item.notes, '需要保留的备注');
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('v7 时间记录升级后回填跨天安全的绝对时间', () async {
    // 本测试独占的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_butler_time_entry_migration_',
    );
    // 测试数据库文件。
    final File databaseFile = File(
      '${directory.path}${Platform.pathSeparator}migration.sqlite',
    );
    // 先创建最新结构，再重建为真实 v7 时间记录表。
    AppDatabase database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    await database.customSelect('SELECT 1').get();
    await database.customStatement('DROP TABLE time_entries');
    await database.customStatement('''
CREATE TABLE time_entries (
  id TEXT NOT NULL PRIMARY KEY,
  entry_date TEXT NOT NULL,
  start_minute INTEGER NOT NULL,
  end_minute INTEGER NOT NULL,
  activity TEXT NOT NULL,
  category TEXT,
  notes TEXT,
  sync_state TEXT NOT NULL DEFAULT 'localSaved',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
)
''');
    await database.customStatement(
      'INSERT INTO time_entries '
      '(id, entry_date, start_minute, end_minute, activity, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        'legacy-sleep',
        '2026-09-09T00:00:00.000',
        23 * 60,
        31 * 60,
        '睡眠',
        '2026-09-09T23:00:00.000',
        '2026-09-10T07:00:00.000',
      ],
    );
    await database.customStatement('PRAGMA user_version = 7');
    await database.close();

    database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    try {
      // 触发 Drift v7 到 v8 升级。
      await database.customSelect('SELECT 1').get();
      // 升级后的时间记录。
      final TimeEntryRecord record = await database
          .select(database.timeEntries)
          .getSingle();
      expect(record.startedAt, DateTime.utc(2026, 9, 9, 23));
      expect(record.endedAt, DateTime.utc(2026, 9, 10, 7));
      expect(record.activity, '睡眠');
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}

/// UUID 文本格式。
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// 将新建数据库改造成足以覆盖迁移分支的 v2 测试夹具。
Future<void> _downgradeFixtureToV2(AppDatabase database) async {
  await database.customStatement('DROP TABLE daily_quote_selections');
  await database.customStatement('''
CREATE TABLE daily_quote_selections (
  day_key TEXT NOT NULL PRIMARY KEY,
  quote_id TEXT NOT NULL,
  is_manual INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
  await database.customStatement('DROP TABLE banner_settings');
  await database.customStatement('''
CREATE TABLE banner_settings (
  key TEXT NOT NULL PRIMARY KEY,
  attachment_id TEXT,
  overlay_strength REAL NOT NULL DEFAULT 0.45,
  text_color_value INTEGER,
  updated_at INTEGER NOT NULL
)
''');
  await database.customStatement(
    'ALTER TABLE taxonomy_entries DROP COLUMN normalized_name',
  );
  await database.customStatement(
    'ALTER TABLE todo_items RENAME COLUMN priority_quadrant TO urgency',
  );
  // 旧版以 Unix 秒保存的固定时间。
  const int legacyTime = 1725498000;
  await database.customStatement(
    'INSERT INTO quotes '
    '(id, content, source, is_enabled, created_at, updated_at, deleted_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      'builtin-quote-quiet',
      '旧版名言',
      'Omni Butler',
      1,
      legacyTime,
      legacyTime,
      null,
    ],
  );
  await database.customStatement(
    'INSERT INTO daily_quote_selections '
    '(day_key, quote_id, is_manual, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?)',
    <Object?>['2026-09-05', 'builtin-quote-quiet', 0, legacyTime, legacyTime],
  );
  await database.customStatement(
    'INSERT INTO taxonomy_entries '
    '(id, module, kind, name, color_value, icon_code_point, sort_order, '
    'is_enabled, created_at, updated_at, deleted_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      'builtin-time-category-0',
      'timeline',
      'category',
      '工作',
      0xFF477087,
      null,
      0,
      1,
      legacyTime,
      legacyTime,
      null,
    ],
  );
  await database.customStatement('PRAGMA user_version = 2');
}
