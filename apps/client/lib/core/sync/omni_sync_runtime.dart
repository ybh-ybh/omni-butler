import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show ApplyInterceptorConnection;
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_powersync_connector.dart';
import 'package:omni_butler/core/sync/omni_sync_schema.dart';
import 'package:omni_butler/core/sync/sync_client_identity.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/core/sync/sync_write_gate.dart';
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
  String toString() => '本机数据来自另一台服务器，请选择保留本机数据或使用服务器数据后再连接。';
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

  /// 当前数据库的完整路径，旧库可直接保留为迁移备份。
  final String databasePath;

  /// 当前运行时独占的认证仓储。
  final AuthRepository _auth;

  /// 所有 Drift 业务访问共享的写门禁。
  final SyncWriteGate _writeGate;

  /// 持有原桥接连接，关闭时释放其表更新订阅。
  final SqliteAsyncDriftConnection _driftConnection;

  /// 当前已发起连接的服务端身份标识。
  String? _connectedUserId;

  /// 断开或冻结立即递增，阻止已在等待中的旧连接重新启动。
  int _connectionGeneration = 0;

  /// 创建已初始化的同步运行时。
  OmniSyncRuntime._({
    required this.powerSync,
    required this.database,
    required this.databasePath,
    required this._auth,
    required this._writeGate,
    required this._driftConnection,
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
    String databasePath, {
    bool initializeUpload = true,
  }) async {
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
    final SyncWriteGate writeGate = SyncWriteGate();
    // 保持同一个订阅状态，但将所有业务 SQL 经过写门禁。
    final AppDatabase database = AppDatabase.withExecutor(
      driftConnection.interceptWith(writeGate),
    );
    await database.customSelect('SELECT 1').get();
    // 已创建表结构的同步运行时。
    final OmniSyncRuntime runtime = OmniSyncRuntime._(
      powerSync: powerSync,
      database: database,
      databasePath: databasePath,
      auth: auth,
      writeGate: writeGate,
      driftConnection: driftConnection,
    );
    try {
      await runtime._installRawTableTriggers();
      await runtime._removeLocalOnlyTableTriggers();
      if (initializeUpload) {
        await runtime._initializeLocalUploadState();
      }
      return runtime;
    } on Object {
      await runtime.close();
      rethrow;
    }
  }

  /// 为指定服务端身份启动后台同步；同一身份重复调用保持幂等。
  Future<void> connect(String userId, {SyncSession? session}) async {
    // 将连接准入固定到当前运行时代次，退休引用不能重新连接。
    final int generation = _connectionGeneration;
    _assertConnectionCurrent(generation);
    if (_connectedUserId == userId && powerSync.connected) {
      return;
    }
    // 当前数据库记录的服务端身份归属。
    final String? localOwnerId = await _loadOwnerId();
    _assertConnectionCurrent(generation);
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
    _assertConnectionCurrent(generation);
    await powerSync.connect(
      connector: OmniPowerSyncConnector(_auth, session: session),
      // 已固定 PowerSync 2.4 与支持请求检查点的服务端部署版本。
      // ignore: experimental_member_use
      options: SyncOptions(checkpointMode: CheckpointMode.requests()),
    );
    if (generation != _connectionGeneration || writesFrozen) {
      await powerSync.disconnect();
      throw const SyncWritesFrozen();
    }
    _connectedUserId = userId;
  }

  /// 每个异步边界后重新核对连接是否仍属于活动运行时。
  void _assertConnectionCurrent(int generation) {
    if (generation != _connectionGeneration || writesFrozen) {
      throw const SyncWritesFrozen();
    }
  }

  /// 停止网络同步但保留全部本机业务数据。
  Future<void> disconnect() async {
    _connectionGeneration += 1;
    await powerSync.disconnect();
    _connectedUserId = null;
  }

  /// 停止同步并清空业务表、上传队列和服务端身份归属。
  Future<void> disconnectAndClear() async {
    _connectionGeneration += 1;
    await powerSync.disconnectAndClear(clearLocal: true);
    _connectedUserId = null;
    await _initializeLocalUploadState();
  }

  /// 关闭 Drift 与 PowerSync 持有的数据库资源。
  Future<void> close() async {
    await database.close();
    await _driftConnection.close();
    await powerSync.close();
  }

  /// 当前数据库仍保留的来源身份，与是否存在登录凭证无关。
  Future<String?> get ownerId => _loadOwnerId();

  /// 当前运行时是否禁止业务写入。
  bool get writesFrozen => _writeGate.isFrozen;

  /// 立即阻止新业务写入，等在途事务排空，再停掉旧同步。
  Future<void> freezeWrites() async {
    _connectionGeneration += 1;
    await _writeGate.freeze();
    await disconnect();
  }

  /// 恢复旧数据库写入，仅用于提交前取消迁移。
  void resumeWrites() => _writeGate.resume();

  /// 从可信底层连接拍摄单事务快照，不复制任何 PowerSync 内部状态。
  Future<SyncSnapshot> exportSnapshot() {
    return powerSync.writeTransaction((transaction) async {
      // 按受信任白名单逐表保存物理 SQLite 数据。
      final Map<String, List<Map<String, Object?>>> tables =
          <String, List<Map<String, Object?>>>{};
      for (final String table in SyncSnapshot.tableNames) {
        tables[table] = await transaction.getAll(
          'SELECT * FROM "$table" ORDER BY id',
        );
      }
      // 队列数量只用于迁移前提示，历史操作不导入候选库。
      final Map<String, Object?> pending = await transaction.get(
        'SELECT COUNT(*) AS count FROM ps_crud',
      );
      return SyncSnapshot(
        tables: tables,
        pendingOperations: pending['count']! as int,
      );
    });
  }

  /// 创建全新候选库，独立生成上传身份并按策略准备业务数据。
  static Future<OmniSyncRuntime> createCandidate(
    AuthRepository auth,
    String databasePath,
    SyncSnapshot snapshot,
    String ownerId, {
    required bool mergeInitial,
    required bool useLocalData,
  }) async {
    if (mergeInitial && !useLocalData) {
      throw ArgumentError('首次合并必须保留本机业务数据');
    }
    if (await File(databasePath).exists()) {
      throw StateError('候选数据库已存在，请恢复原迁移或使用新的候选路径');
    }
    // 不为候选库执行普通启动的初始 PUT 补齐逻辑。
    final OmniSyncRuntime runtime = await openAtPath(
      auth,
      databasePath,
      initializeUpload: false,
    );
    try {
      await runtime._seedCandidate(
        snapshot,
        ownerId,
        mergeInitial: mergeInitial,
        useLocalData: useLocalData,
      );
      return runtime;
    } on Object {
      await runtime.close();
      rethrow;
    }
  }

  /// 原子导入业务快照；触发器在导入期间移除，避免重放旧上传历史。
  Future<void> _seedCandidate(
    SyncSnapshot snapshot,
    String ownerId, {
    required bool mergeInitial,
    required bool useLocalData,
  }) async {
    await powerSync.writeTransaction((transaction) async {
      for (final RawTable table in omniSyncSchema.rawTables) {
        for (final String operation in <String>['insert', 'update', 'delete']) {
          await transaction.execute(
            'DROP TRIGGER IF EXISTS "powersync_${table.name}_$operation"',
          );
        }
      }
      for (final String table in SyncSnapshot.tableNames) {
        if (!useLocalData &&
            table != 'banner_settings' &&
            table != 'attachments') {
          continue;
        }
        // 列白名单来自候选库的本地 schema，禁止快照控制 SQL 标识符。
        final Set<String> allowedColumns =
            (await transaction.getAll('PRAGMA table_info("$table")'))
                .map((Map<String, Object?> column) => column['name']! as String)
                .toSet();
        for (final Map<String, Object?> source
            in snapshot.tables[table] ?? <Map<String, Object?>>[]) {
          if (!useLocalData &&
              table == 'attachments' &&
              source['business_type'] != 'quoteBanner') {
            continue;
          }
          // 副本允许重置本机提示状态，不修改持久化的迁移快照。
          final Map<String, Object?> row = Map<String, Object?>.from(source);
          if (row.keys.any(
            (String column) => !allowedColumns.contains(column),
          )) {
            throw FormatException('迁移快照包含当前版本不支持的 $table 字段');
          }
          if (row.containsKey('sync_state')) {
            row['sync_state'] = mergeInitial ? 'localSaved' : 'synced';
          }
          await transaction.execute(
            'INSERT INTO "$table" (${row.keys.map((String column) => '"$column"').join(', ')}) '
            'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
            row.values.toList(growable: false),
          );
        }
      }
      await transaction.execute(
        'INSERT INTO device_sync_metadata(id, value) VALUES(?, ?), (?, ?), (?, ?)',
        <Object?>[
          'owner',
          ownerId,
          'initial_upload',
          '1',
          AppDatabase.suppressDefaultSeedingMetadataId,
          '1',
        ],
      );
      if (mergeInitial) {
        for (final Map<String, Object?> operation in snapshot.operations) {
          await transaction.execute(
            'INSERT INTO powersync_crud(op, id, type, data) VALUES(?, ?, ?, ?)',
            <Object?>[
              'PUT',
              operation['id'],
              operation['table'],
              jsonEncode(operation['data']),
            ],
          );
        }
      }
    });
    await ensureSyncClientId(powerSync);
    await _installRawTableTriggers();
  }

  /// 在完整下行后恢复同业务类型、同记录 ID 的本机图片，不上传附件。
  Future<void> restoreLocalAttachments(
    SyncSnapshot snapshot, {
    required bool matchingOnly,
  }) async {
    await powerSync.writeTransaction((transaction) async {
      // 本机附件类型到拥有图片字段的业务表之间的固定映射。
      const Map<String, String> imageTables = <String, String>{
        'inventoryImage': 'inventory_items',
        'membershipImage': 'memberships',
      };
      // 可写附件列由本地 schema 决定，恢复快照不能注入 SQL。
      final Set<String> attachmentColumns =
          (await transaction.getAll('PRAGMA table_info("attachments")'))
              .map((Map<String, Object?> column) => column['name']! as String)
              .toSet();
      for (final Map<String, Object?> attachment
          in snapshot.tables['attachments'] ?? <Map<String, Object?>>[]) {
        // 只将存在同业务身份的图片恢复到采用服务器数据的候选库。
        final String? table = imageTables[attachment['business_type']];
        if (matchingOnly && attachment['business_type'] != 'quoteBanner') {
          if (table == null ||
              await transaction.getOptional(
                    'SELECT id FROM "$table" WHERE id = ?',
                    <Object?>[attachment['business_id']],
                  ) ==
                  null) {
            continue;
          }
        }
        if (attachment.keys.any(
          (String column) => !attachmentColumns.contains(column),
        )) {
          throw const FormatException('迁移附件包含未知字段');
        }
        await transaction.execute(
          'INSERT OR REPLACE INTO attachments (${attachment.keys.map((String column) => '"$column"').join(', ')}) '
          'VALUES (${List<String>.filled(attachment.length, '?').join(', ')})',
          attachment.values.toList(growable: false),
        );
        if (table != null) {
          // 原库中实际选中的附件才恢复为主图，保留其他历史附件元数据。
          final bool selected =
              (snapshot.tables[table] ?? <Map<String, Object?>>[]).any(
                (Map<String, Object?> row) =>
                    row['id'] == attachment['business_id'] &&
                    row['image_attachment_id'] == attachment['id'],
              );
          if (selected) {
            await transaction.execute(
              'UPDATE "$table" SET image_attachment_id = ?, image_local_path = ? WHERE id = ?',
              <Object?>[
                attachment['id'],
                attachment['local_path'],
                attachment['business_id'],
              ],
            );
          }
        }
      }
    });
  }

  /// 等待上传全部获确认，再请求服务器检查点并等待其完整落入候选库。
  Future<void> catchUp({Duration timeout = const Duration(minutes: 3)}) async {
    // 一个截止时间覆盖上传与下行，避免每阶段各自重置等待上限。
    final DateTime deadline = DateTime.now().add(timeout);
    while (await powerSync.getNextCrudTransaction() != null) {
      if (DateTime.now().isAfter(deadline)) {
        throw const ApiFailure('等待本机快照上传超时，请重试迁移');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // 请求发生在上传回执之后，不能仅依赖曾经完成过首次同步。
    // ignore: experimental_member_use
    final checkpoint = await powerSync.requestCheckpoint().timeout(
      deadline.difference(DateTime.now()),
    );
    // 超时必须取消 SDK 内部状态监听，避免重试后遗留等待者。
    final Completer<void> abort = Completer<void>();
    // 与上传、请求共享同一个总截止时间。
    final Timer timer = Timer(
      deadline.difference(DateTime.now()),
      abort.complete,
    );
    try {
      // ignore: experimental_member_use
      await checkpoint.waitForSync(abortTrigger: abort.future);
    } finally {
      timer.cancel();
    }
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
