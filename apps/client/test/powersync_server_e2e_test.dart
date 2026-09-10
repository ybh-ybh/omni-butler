import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_schema.dart';
import 'package:path/path.dart' as path;
import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';

/// 是否显式运行需要本地 Docker 服务的端到端测试。
const bool _runEndToEnd = bool.fromEnvironment('OMNI_SYNC_E2E');

/// 使用固定设备会话完成真实上传和下载的 PowerSync 连接器。
class _EndToEndConnector extends PowerSyncBackendConnector {
  /// 服务端签发的短期连接凭证。
  final PowerSyncCredentials credentials;

  /// 受保护同步写入接口客户端。
  final Dio api;

  /// 当前设备的访问令牌。
  final String accessToken;

  /// 创建端到端连接器。
  _EndToEndConnector({
    required this.credentials,
    required this.api,
    required this.accessToken,
  });

  /// 返回服务端签发的 PowerSync 凭证。
  @override
  Future<PowerSyncCredentials?> fetchCredentials() async => credentials;

  /// 按生产协议把本机 CRUD 队列上传到 NestJS。
  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    while (true) {
      // 当前最多二百条的待上传批次。
      final CrudBatch? batch = await database.getCrudBatch(limit: 200);
      if (batch == null) {
        return;
      }
      // 符合服务端同步接口契约的操作列表。
      final List<Map<String, Object?>> operations = batch.crud
          .map(
            (CrudEntry entry) => <String, Object?>{
              'op': entry.op.toJson(),
              'table': entry.table,
              'id': entry.id,
              if (entry.opData != null) 'data': entry.opData,
            },
          )
          .toList(growable: false);
      await api.post<void>(
        '/sync/operations',
        data: <String, Object?>{'operations': operations},
        options: Options(
          headers: <String, String>{'Authorization': 'Bearer $accessToken'},
        ),
      );
      await batch.complete();
      if (!batch.haveMore) {
        return;
      }
    }
  }
}

/// 在 Raw Table 上安装与生产运行时一致的 CRUD 捕获触发器。
Future<void> _installRawTableTriggers(PowerSyncDatabase database) async {
  for (final RawTable table in omniSyncSchema.rawTables) {
    for (final String operation in <String>['INSERT', 'UPDATE', 'DELETE']) {
      // 仅由受信任表名与操作名组成的触发器名。
      final String triggerName =
          'powersync_${table.name}_${operation.toLowerCase()}';
      await database.execute(
        'SELECT powersync_create_raw_table_crud_trigger(?, ?, ?)',
        <Object?>[jsonEncode(table), triggerName, operation],
      );
    }
  }
}

/// 等待指定客户端的本地上传队列清空。
Future<void> _waitForUpload(PowerSyncDatabase database) async {
  // 上传队列等待截止时间。
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    // 当前上传队列统计。
    final UploadQueueStats stats = await database.getUploadQueueStats();
    if (stats.count == 0) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw TimeoutException('客户端上传队列未在限定时间内清空');
}

/// 自托管服务真实双设备同步测试。
void main() {
  // 本测试有意同时模拟两个独立设备数据库。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  test('设备 A 本地写入可经 PostgreSQL 与 PowerSync 下载到设备 B', () async {
    // 本地 API 客户端。
    final Dio api = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:3000/api/v1'));
    // 设备连接接口返回的会话令牌。
    final Map<String, dynamic> tokens =
        (await api.post<Map<String, dynamic>>(
          '/auth/connect',
          data: <String, String>{'syncKey': 'validation-sync-secret-2026'},
        )).data ??
        <String, dynamic>{};
    // 当前设备访问令牌。
    final String accessToken = tokens['accessToken'] as String;
    // 受保护请求所需的访问令牌头。
    final Options authorized = Options(
      headers: <String, String>{'Authorization': 'Bearer $accessToken'},
    );
    // PowerSync 短期凭证接口响应。
    final Map<String, dynamic> credentialJson =
        (await api.post<Map<String, dynamic>>(
          '/auth/powersync-token',
          options: authorized,
        )).data ??
        <String, dynamic>{};
    // 服务端签发的客户端连接凭证。
    final PowerSyncCredentials credentials = PowerSyncCredentials(
      endpoint: credentialJson['endpoint'] as String,
      token: credentialJson['token'] as String,
      userId: credentialJson['userId'] as String,
      expiresAt: DateTime.now().add(
        Duration(seconds: credentialJson['expiresIn'] as int),
      ),
    );
    // 测试专用临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni-powersync-e2e-',
    );
    // 模拟设备 A 的真实 PowerSync 数据库。
    final PowerSyncDatabase deviceA = PowerSyncDatabase(
      schema: omniSyncSchema,
      path: path.join(directory.path, 'device-a.sqlite'),
    );
    // 模拟设备 B 的真实 PowerSync 数据库。
    final PowerSyncDatabase deviceB = PowerSyncDatabase(
      schema: omniSyncSchema,
      path: path.join(directory.path, 'device-b.sqlite'),
    );
    // 设备 A 的 Drift 类型安全访问层。
    late final AppDatabase driftA;
    // 设备 B 的 Drift 类型安全访问层。
    late final AppDatabase driftB;
    try {
      await deviceA.initialize();
      driftA = AppDatabase.withExecutor(SqliteAsyncDriftConnection(deviceA));
      await driftA.customSelect('SELECT 1').get();
      await _installRawTableTriggers(deviceA);
      await deviceA.connect(
        connector: _EndToEndConnector(
          credentials: credentials,
          api: api,
          accessToken: accessToken,
        ),
      );
      await deviceA.waitForFirstSync().timeout(const Duration(seconds: 30));
      // 设备 A 本地新建的待办标识。
      final String todoId = const Uuid().v7();
      // 设备 A 本地新建待办的时间。
      final String now = DateTime.now().toUtc().toIso8601String();
      await deviceA.execute(
        'INSERT INTO todo_items('
        'id, title, description, scheduled_date, priority_quadrant, is_completed, '
        'sort_order, created_at, updated_at'
        ') VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          todoId,
          'PowerSync 双设备真实验证',
          'device A to device B',
          '2026-09-05',
          1,
          0,
          0,
          now,
          now,
        ],
      );
      await _waitForUpload(deviceA);

      await deviceB.initialize();
      driftB = AppDatabase.withExecutor(SqliteAsyncDriftConnection(deviceB));
      await driftB.customSelect('SELECT 1').get();
      await deviceB.connect(
        connector: _EndToEndConnector(
          credentials: credentials,
          api: api,
          accessToken: accessToken,
        ),
      );
      await deviceB.waitForFirstSync().timeout(const Duration(seconds: 30));
      // 设备 B 从服务端下载到的同一条待办。
      final row = await deviceB.get(
        'SELECT title FROM todo_items WHERE id = ?',
        <Object?>[todoId],
      );
      expect(row['title'], 'PowerSync 双设备真实验证');
    } finally {
      await deviceA.disconnect();
      await deviceB.disconnect();
      await driftA.close();
      await driftB.close();
      await deviceA.close();
      await deviceB.close();
      await directory.delete(recursive: true);
    }
  }, skip: _runEndToEnd ? false : '需要显式启动本地 Docker 同步服务');
}
