import 'package:omni_butler/core/sync/omni_sync_schema.dart';

/// 不携带同步检查点、客户端身份或设备密钥的完整业务快照。
class SyncSnapshot {
  /// 当前快照持久化格式版本。
  static const int version = 8;

  /// 服务端换服协议独立于本机备份格式，草稿不进入请求。
  static const int migrationProtocolVersion = 3;

  /// 包含所有业务表及本机附件、横幅设置的原始 SQLite 行。
  final Map<String, List<Map<String, Object?>>> tables;

  /// 拍摄快照时未上传的原始操作数量，只用于确认影响。
  final int pendingOperations;

  /// 创建独立业务快照。
  const SyncSnapshot({required this.tables, required this.pendingOperations});

  /// 从迁移控制文件恢复快照，拒绝不支持的格式和未知表。
  factory SyncSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['version'] != version &&
        json['version'] != 7 &&
        json['version'] != 6 &&
        json['version'] != 5 &&
        json['version'] != 4 &&
        json['version'] != 3 &&
        json['version'] != 2 &&
        json['version'] != 1) {
      throw const FormatException('不支持的迁移快照版本');
    }
    // 只接受当前版本固定定义的业务表名。
    final Map<String, dynamic> encoded = Map<String, dynamic>.from(
      json['tables'] as Map,
    );
    if (json['version'] == 1) {
      // 原始持久文件与校验摘要不变，只升级内存中的业务副本。
      encoded.putIfAbsent('todo_progress_steps', () => <dynamic>[]);
      if (encoded['todo_items'] is List) {
        encoded['todo_items'] = (encoded['todo_items'] as List)
            .map((dynamic source) {
              // 旧任务继续按普通任务恢复，不推断新的进度结构。
              final Map<String, dynamic> row = Map<String, dynamic>.from(
                source as Map,
              );
              row.putIfAbsent('task_type', () => 'normal');
              row.putIfAbsent('progress_unit', () => null);
              return row;
            })
            .toList(growable: false);
      }
    }
    if (json['version'] == 1 || json['version'] == 2) {
      // 旧快照没有笔记，补齐空表以维持完整备份白名单。
      for (final String table in <String>[
        'note_entries',
        'note_versions',
        'note_audio_segments',
        'note_audio_local_files',
      ]) {
        encoded.putIfAbsent(table, () => <dynamic>[]);
      }
    }
    if (json['version'] != version) {
      encoded.putIfAbsent('note_images', () => <dynamic>[]);
      encoded.putIfAbsent('note_draft_images', () => <dynamic>[]);
      encoded.putIfAbsent('note_local_drafts', () => <dynamic>[]);
      encoded.putIfAbsent('note_draft_audio_segments', () => <dynamic>[]);
    }
    if (encoded.keys.any((String table) => !tableNames.contains(table)) ||
        tableNames.any((String table) => !encoded.containsKey(table))) {
      throw const FormatException('迁移快照业务表不完整');
    }
    // 只在内存副本移除退休类别，不修改历史备份文件及其摘要。
    final Set<Object?> retiredIds = (encoded['taxonomy_entries'] as List)
        .where(
          (dynamic row) =>
              row['module'] == 'notes' && row['kind'] == 'category',
        )
        .map((dynamic row) => row['id'])
        .toSet();
    encoded['taxonomy_entries'] = (encoded['taxonomy_entries'] as List)
        .where((dynamic row) => !retiredIds.contains(row['id']))
        .toList();
    encoded['record_taxonomy_links'] =
        (encoded['record_taxonomy_links'] as List)
            .where((dynamic row) => !retiredIds.contains(row['taxonomy_id']))
            .toList();
    return SyncSnapshot(
      tables: <String, List<Map<String, Object?>>>{
        for (final String table in tableNames)
          table: (encoded[table] as List)
              .map((dynamic row) {
                // 恢复旧快照时只丢弃已下线的事件说明，保留原文件与其他业务字段。
                final Map<String, Object?> restored = Map<String, Object?>.from(
                  row as Map,
                );
                if (table == 'events') restored.remove('description');
                if (table == 'taxonomy_entries' &&
                    restored['module'] == 'notes' &&
                    restored['kind'] == 'tag') {
                  // 旧备份仅在恢复副本清除退休颜色，其他模块原样保留。
                  restored['color_value'] = null;
                }
                if (table == 'taxonomy_entries' && json['version'] != version) {
                  // SQLite 布尔列在原始快照中使用整数，旧文件仅在内存补默认值。
                  restored.putIfAbsent('is_pinned', () => 0);
                  restored.putIfAbsent('icon_emoji', () => null);
                }
                if (table == 'note_entries') {
                  restored.remove('category_id');
                  restored.remove('category_name');
                  restored.putIfAbsent(
                    'creation_timezone',
                    () => 'legacy:unknown',
                  );
                }
                return restored;
              })
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
    'note_audio_local_files',
    'note_local_drafts',
    'note_draft_audio_segments',
    'note_draft_images',
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
        (<String>{
              'todo_progress_steps',
              'note_versions',
              'note_audio_segments',
              'note_images',
            }.contains(table.name)
            ? 0
            : (tables[table.name] ?? <Map<String, Object?>>[])
                  .where(
                    (Map<String, Object?> row) => row['deleted_at'] != null,
                  )
                  .length),
  );

  /// 持久化可恢复业务快照，不写入认证凭证。
  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'tables': tables,
    'pendingOperations': pendingOperations,
  };
}
