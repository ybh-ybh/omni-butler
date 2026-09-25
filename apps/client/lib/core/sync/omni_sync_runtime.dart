import 'dart:convert';

import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_powersync_connector.dart';
import 'package:omni_butler/core/sync/omni_sync_schema.dart';
import 'package:omni_butler/core/sync/sync_client_identity.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';

/// 当前数据库已经绑定另一台服务器身份时抛出的安全异常。
class SyncOwnerMismatch implements Exception {
  /// 本机数据已绑定的服务端身份。
  final String localOwnerId;

  /// 正在尝试连接的服务端身份。
  final String requestedOwnerId;

  /// 创建服务端身份冲突异常。
  const SyncOwnerMismatch({
    required this.localOwnerId,
    required this.requestedOwnerId,
  });

  /// 返回可向用户展示的冲突说明。
  @override
  String toString() => '本机同步数据已绑定另一台服务器，请先断开并清理本机同步数据后再切换。';
}

/// 同时持有 PowerSync 引擎与 Drift 类型安全访问层。
class OmniSyncRuntime {
  /// MVP 中只保存在设备本地、不得进入 PowerSync 队列的表。
  static const List<String> _localOnlyTableNames = <String>[
    'banner_settings',
    'attachments',
  ];

  /// PowerSync 底层数据库。
  final PowerSyncDatabase powerSync;

  /// Drift 业务数据库。
  final AppDatabase database;

  /// 当前后端连接器。
  final OmniPowerSyncConnector _connector;

  /// 当前已发起连接的服务端身份标识。
  String? _connectedUserId;

  /// 创建已初始化的同步运行时。
  OmniSyncRuntime._({
    required this.powerSync,
    required this.database,
    required this._connector,
  });

  /// 在原有 Drift 文件上初始化 PowerSync，并安装 Raw Table 变更触发器。
  static Future<OmniSyncRuntime> open(AuthRepository auth) async {
    // 应用文档目录，与 drift_flutter 默认数据库目录一致。
    final directory = await getApplicationDocumentsDirectory();
    // 保留现有本机数据的数据库路径。
    final String databasePath = path.join(directory.path, 'omni_butler.sqlite');
    return openAtPath(auth, databasePath);
  }

  /// 在指定路径初始化同步运行时，便于集成测试验证真实 SQLite 行为。
  static Future<OmniSyncRuntime> openAtPath(
    AuthRepository auth,
    String databasePath,
  ) async {
    // 唯一的 PowerSync 数据库实例。
    final PowerSyncDatabase powerSync = PowerSyncDatabase(
      schema: omniSyncSchema,
      path: databasePath,
    );
    await powerSync.initialize();
    // 将 PowerSync 的 sqlite_async 连接桥接给 Drift。
    final SqliteAsyncDriftConnection driftConnection =
        SqliteAsyncDriftConnection(powerSync);
    // 复用现有仓储所依赖的 Drift 数据库。
    final AppDatabase database = AppDatabase.withExecutor(driftConnection);
    await database.customSelect('SELECT 1').get();
    // 已创建表结构的同步运行时。
    final OmniSyncRuntime runtime = OmniSyncRuntime._(
      powerSync: powerSync,
      database: database,
      connector: OmniPowerSyncConnector(auth),
    );
    try {
      await runtime._installRawTableTriggers();
      await runtime._removeLocalOnlyTableTriggers();
      await runtime._initializeLocalUploadState();
      return runtime;
    } on Object {
      await runtime.close();
      rethrow;
    }
  }

  /// 为指定服务端身份启动后台同步；同一身份重复调用保持幂等。
  Future<void> connect(String userId) async {
    if (_connectedUserId == userId && powerSync.connected) {
      return;
    }
    // 当前数据库记录的服务端身份归属。
    final String? localOwnerId = await _loadOwnerId();
    if (localOwnerId != null && localOwnerId != userId) {
      throw SyncOwnerMismatch(
        localOwnerId: localOwnerId,
        requestedOwnerId: userId,
      );
    }
    if (localOwnerId == null) {
      await powerSync.execute(
        'INSERT INTO device_sync_metadata(id, value) VALUES(?, ?)',
        <Object?>['owner', userId],
      );
    }
    await powerSync.connect(connector: _connector);
    _connectedUserId = userId;
  }

  /// 停止网络同步但保留全部本机业务数据。
  Future<void> disconnect() async {
    await powerSync.disconnect();
    _connectedUserId = null;
  }

  /// 停止同步并清空业务表、上传队列和服务端身份归属。
  Future<void> disconnectAndClear() async {
    await powerSync.disconnectAndClear(clearLocal: true);
    _connectedUserId = null;
    await _initializeLocalUploadState();
  }

  /// 关闭 Drift 与 PowerSync 持有的数据库资源。
  Future<void> close() async {
    await database.close();
    await powerSync.close();
  }

  /// 读取本机数据库当前绑定的服务端身份。
  Future<String?> _loadOwnerId() async {
    // 本机服务端身份归属元数据。
    final row = await powerSync.getOptional(
      'SELECT value FROM device_sync_metadata WHERE id = ?',
      <Object?>['owner'],
    );
    return row?['value'] as String?;
  }

  /// 首次接入时原子补齐旧业务数据的 PUT，已绑定服务端的数据不重新导入。
  Future<void> _initializeLocalUploadState() async {
    await powerSync.writeTransaction((transaction) async {
      // 初始导入和数据归属标记，只在尚未接入同步的本地库中补建队列。
      final metadata = await transaction.getAll(
        'SELECT id FROM device_sync_metadata WHERE id IN (?, ?)',
        <Object?>['initial_upload', 'owner'],
      );
      if (metadata.any((row) => row['id'] == 'initial_upload')) {
        return;
      }
      if (metadata.isEmpty) {
        // 尚未绑定过服务器的旧操作可折叠为当前快照，避免先上传过时字段或悬空引用。
        // 与快照入队和标记同事务提交，失败时原队列仍然完整保留。
        await transaction.execute('DELETE FROM ps_crud');
        // 按客户端同步白名单生成 PUT，绝不改写原业务行或本机专属字段。
        for (final RawTable table in omniSyncSchema.rawTables) {
          // 当前表中允许上传的字段名来自受信任的静态 schema。
          final List<String> columns = table.schema!.syncedColumns!;
          // SQLite JSON 保留原始数值与空值；虚拟表负责记录事务号。
          final String jsonColumns = columns
              .map((String column) => "'$column', \"$column\"")
              .join(', ');
          await transaction.execute(
            'INSERT INTO powersync_crud(op, id, type, data) '
            "SELECT 'PUT', id, ?, json_object($jsonColumns) FROM \"${table.name}\"",
            <Object?>[table.name],
          );
        }
      }
      await transaction.execute(
        'INSERT INTO device_sync_metadata(id, value) VALUES(?, ?)',
        <Object?>['initial_upload', '1'],
      );
    });
    await ensureSyncClientId(powerSync);
  }

  /// 为全部 Drift Raw Table 安装幂等的本地写入捕获触发器。
  Future<void> _installRawTableTriggers() async {
    for (final RawTable table in omniSyncSchema.rawTables) {
      for (final String operation in <String>['INSERT', 'UPDATE', 'DELETE']) {
        // 只由受信任表名与操作名组成的触发器名。
        final String triggerName =
            'powersync_${table.name}_${operation.toLowerCase()}';
        await powerSync.execute('DROP TRIGGER IF EXISTS "$triggerName"');
        await powerSync.execute(
          'SELECT powersync_create_raw_table_crud_trigger(?, ?, ?)',
          <Object?>[jsonEncode(table), triggerName, operation],
        );
      }
    }
  }

  /// 移除旧版本遗留的附件同步触发器，确保本地图片不会上传元数据。
  Future<void> _removeLocalOnlyTableTriggers() async {
    for (final String tableName in _localOnlyTableNames) {
      for (final String operation in <String>['INSERT', 'UPDATE', 'DELETE']) {
        // 旧版本可能遗留的 PowerSync 触发器名。
        final String triggerName =
            'powersync_${tableName}_${operation.toLowerCase()}';
        await powerSync.execute('DROP TRIGGER IF EXISTS "$triggerName"');
      }
    }
  }
}
