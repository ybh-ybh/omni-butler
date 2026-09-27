import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// 独立于业务库的活动数据库索引和迁移日志；不存任何密钥。
class SyncConnectionStore extends GeneratedDatabase {
  /// 打开应用私有目录中的控制库。
  SyncConnectionStore(File file) : super(NativeDatabase(file));

  /// 控制库版本。
  @override
  int get schemaVersion => 1;

  /// 控制库使用显式 SQL，不生成业务表模型。
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  /// 安装仅保存控制信息的键值表。
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) => customStatement(
      'CREATE TABLE connection_control (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
    ),
    beforeOpen: (OpeningDetails details) async {
      await customStatement('PRAGMA synchronous = FULL');
    },
  );

  /// 读取一项持久控制信息。
  Future<Map<String, dynamic>?> read(String key) async {
    // 当前控制行。
    final QueryRow? row = await customSelect(
      'SELECT payload FROM connection_control WHERE id = ?',
      variables: [Variable<String>(key)],
    ).getSingleOrNull();
    return row == null
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(row.read<String>('payload')) as Map,
          );
  }

  /// 原子写入单项控制信息。
  Future<void> write(String key, Map<String, dynamic> value) => customStatement(
    'INSERT INTO connection_control(id, payload) VALUES (?, ?) '
    'ON CONFLICT(id) DO UPDATE SET payload = excluded.payload',
    [key, jsonEncode(value)],
  );

  /// 移除已经结束的控制信息。
  Future<void> remove(String key) =>
      customStatement('DELETE FROM connection_control WHERE id = ?', [key]);

  /// 将活动库、活动会话引用和迁移完成标记一起提交。
  Future<void> activate({
    required Map<String, dynamic> active,
    required Map<String, dynamic> migration,
    required Map<String, dynamic> backup,
  }) => transaction(() async {
    await write('active', active);
    await write('backup:${migration['id']}', backup);
    await write('migration:${migration['id']}', {
      ...migration,
      'phase': 'completed',
    });
    await remove('pending');
  });

  /// 列出用户可手动清理的历史库，不包含活动库或待完成迁移。
  Future<List<Map<String, dynamic>>> backups() async {
    // 持久备份列表。
    final List<QueryRow> rows = await customSelect(
      "SELECT payload FROM connection_control WHERE id LIKE 'backup:%' ORDER BY id",
    ).get();
    return rows
        .map(
          (QueryRow row) => Map<String, dynamic>.from(
            jsonDecode(row.read<String>('payload')) as Map,
          ),
        )
        .toList();
  }
}
