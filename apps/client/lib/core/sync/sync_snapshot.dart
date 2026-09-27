import 'package:omni_butler/core/sync/omni_sync_schema.dart';

/// 不携带同步检查点、客户端身份或设备密钥的完整业务快照。
class SyncSnapshot {
  /// 当前快照持久化格式版本。
  static const int version = 1;

  /// 包含所有业务表及本机附件、横幅设置的原始 SQLite 行。
  final Map<String, List<Map<String, Object?>>> tables;

  /// 拍摄快照时未上传的原始操作数量，只用于确认影响。
  final int pendingOperations;

  /// 创建独立业务快照。
  const SyncSnapshot({required this.tables, required this.pendingOperations});

  /// 从迁移控制文件恢复快照，拒绝不支持的格式和未知表。
  factory SyncSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['version'] != version) {
      throw const FormatException('不支持的迁移快照版本');
    }
    // 只接受当前版本固定定义的业务表名。
    final Map<String, dynamic> encoded = Map<String, dynamic>.from(
      json['tables'] as Map,
    );
    if (encoded.keys.any((String table) => !tableNames.contains(table)) ||
        tableNames.any((String table) => !encoded.containsKey(table))) {
      throw const FormatException('迁移快照业务表不完整');
    }
    return SyncSnapshot(
      tables: <String, List<Map<String, Object?>>>{
        for (final String table in tableNames)
          table: (encoded[table] as List)
              .map((dynamic row) => Map<String, Object?>.from(row as Map))
              .toList(growable: false),
      },
      pendingOperations: json['pendingOperations'] as int,
    );
  }

  /// 当前版本可信的业务表清单，不包含 PowerSync 内部状态。
  static List<String> get tableNames => <String>[
    ...omniSyncSchema.rawTables.map((table) => table.name),
    'banner_settings',
    'attachments',
  ];

  /// 按同步白名单生成服务器可接受的完整 PUT 列表。
  List<Map<String, Object?>> get operations => <Map<String, Object?>>[
    for (final table in omniSyncSchema.rawTables)
      for (final Map<String, Object?> row
          in tables[table.name] ?? <Map<String, Object?>>[])
        <String, Object?>{
          'op': 'PUT',
          'table': table.name,
          'id': row['id'],
          'data': <String, Object?>{
            for (final String column in table.schema!.syncedColumns!)
              column: row[column],
          },
        },
  ];

  /// 每张同步表包含软删除在内的总记录数。
  Map<String, int> get counts => <String, int>{
    for (final table in omniSyncSchema.rawTables)
      table.name: tables[table.name]?.length ?? 0,
  };

  /// 全部同步业务记录数，不把本机附件计入服务器清空判断。
  int get totalCount =>
      counts.values.fold(0, (int sum, int count) => sum + count);

  /// 回收站记录总数。
  int get deletedCount => omniSyncSchema.rawTables.fold(
    0,
    (int sum, table) =>
        sum +
        (tables[table.name] ?? <Map<String, Object?>>[])
            .where((Map<String, Object?> row) => row['deleted_at'] != null)
            .length,
  );

  /// 持久化可恢复业务快照，不写入认证凭证。
  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'tables': tables,
    'pendingOperations': pendingOperations,
  };
}
