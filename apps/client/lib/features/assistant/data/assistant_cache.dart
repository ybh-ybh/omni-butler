import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';

/// 独立助手缓存，不参与业务快照和 PowerSync。
class AssistantCache extends GeneratedDatabase {
  /// 打开独立的本机缓存文件。
  AssistantCache() : super(driftDatabase(name: 'assistant_cache'));

  /// 使用内存执行器验证，不访问真实用户目录。
  AssistantCache.forTesting(super.executor);

  /// 首版缓存版本。
  @override
  int get schemaVersion => 1;

  /// 自定义表不生成业务表接口。
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      const <TableInfo<Table, Object?>>[];

  /// 独立表由迁移集中创建。
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      const <DatabaseSchemaEntity>[];

  /// 每个数据源一行原子快照，包含草稿、请求身份和事件游标。
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) async {
      await customStatement(
        'CREATE TABLE assistant_cache (scope TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at INTEGER NOT NULL)',
      );
    },
  );

  /// 根据完整服务器地址与 owner 隔离缓存。
  static String scopeFor(String baseUrl, String ownerId) =>
      jsonEncode(<String>[baseUrl, ownerId]);

  /// 读取指定数据源；断开时可读取最近缓存，但只能展示。
  Future<Map<String, dynamic>> readScope(String? scope) async {
    // 断开时不丢失最近一次输入和可读历史。
    final QueryRow? row = await customSelect(
      scope == null
          ? 'SELECT scope, payload FROM assistant_cache ORDER BY updated_at DESC LIMIT 1'
          : 'SELECT scope, payload FROM assistant_cache WHERE scope = ?',
      variables: scope == null
          ? const <Variable<Object>>[]
          : <Variable<Object>>[Variable<String>(scope)],
    ).getSingleOrNull();
    if (row == null) return <String, dynamic>{};
    return <String, dynamic>{
      ...assistantMap(jsonDecode(row.read<String>('payload'))),
      'scope': row.read<String>('scope'),
    };
  }

  /// 消息与游标在同一事务中落盘，重启后不会重复拼接文本。
  Future<void> save(String scope, Map<String, dynamic> snapshot) =>
      transaction(() async {
        await customStatement(
          'INSERT INTO assistant_cache(scope,payload,updated_at) VALUES(?,?,?) ON CONFLICT(scope) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at',
          <Object?>[
            scope,
            jsonEncode(snapshot),
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      });
}

/// 缓存生命周期独立于认证，旧历史仅供只读查看。
final Provider<AssistantCache> assistantCacheProvider =
    Provider<AssistantCache>((Ref ref) {
      // 不打开业务数据库，也不缓存供应商密钥。
      final AssistantCache cache = AssistantCache();
      ref.onDispose(cache.close);
      return cache;
    });
