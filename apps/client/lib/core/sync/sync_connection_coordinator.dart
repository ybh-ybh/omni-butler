import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_connection_models.dart';
import 'package:omni_butler/core/sync/sync_connection_store.dart';
import 'package:omni_butler/core/sync/sync_disk_space.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:omni_butler/core/sync/sync_image_report.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

export 'sync_connection_models.dart';

/// 统一协调候选会话、独立数据库、迁移回执和可恢复的本地激活。
class SyncConnectionCoordinator {
  /// 注入磁盘/网络边界，生产和故障注入测试共用相同编排。
  SyncConnectionCoordinator({
    required this.store,
    required this.secureStorage,
    required this.directory,
    required OmniSyncRuntime runtime,
    required AuthRepository auth,
    this.freeBytes = migrationFreeBytes,
    this.catchUpTimeout = const Duration(minutes: 3),
    // 保持公共参数命名，同时不暴露可写活动运行时。
    // ignore: prefer_initializing_formals
  }) : _runtime = runtime,
       // ignore: prefer_initializing_formals
       _auth = auth;

  /// 独立于业务数据生命周期的控制库。
  final SyncConnectionStore store;

  /// 候选密钥及会话仅进入系统安全存储。
  final FlutterSecureStorage secureStorage;

  /// 应用私有迁移目录。
  final Directory directory;

  /// 可注入的本机可用空间检查。
  final Future<int> Function(String) freeBytes;

  /// 单次同步等待上限，超时保留原操作供重试。
  final Duration catchUpTimeout;

  /// 当前活动运行时。
  OmniSyncRuntime _runtime;

  /// 当前活动会话仓储。
  AuthRepository _auth;

  /// 本次尚未激活的候选运行时。
  OmniSyncRuntime? _candidate;

  /// 等待应用依赖切换后释放的冻结运行时。
  final List<OmniSyncRuntime> _retired = [];

  /// 供所有窗口和应用依赖订阅的状态流。
  final StreamController<SyncConnectionState> _changes =
      StreamController.broadcast();

  /// 当前已公开状态。
  SyncConnectionState _state = const SyncConnectionState();

  /// 所有变更入口在第一个 await 前同步取得的互斥准入。
  bool _operationActive = false;

  /// 数据库冻结前必须排空的后台传输器。
  final Set<Future<void> Function()> _backgroundStops = {};

  /// 注册共享数据库的后台任务，并返回注销方法。
  void Function() registerBackgroundStop(Future<void> Function() stop) {
    _backgroundStops.add(stop);
    return () => _backgroundStops.remove(stop);
  }

  /// 先排空图片网络响应，再获取一致业务快照。
  Future<void> _stopBackgroundTasks() async {
    await Future.wait(List.of(_backgroundStops).map((stop) => stop()));
  }

  /// 活动运行时只在持久激活成功后变化。
  OmniSyncRuntime get runtime => _runtime;

  /// 活动认证仓储与活动数据库同时发布。
  AuthRepository get auth => _auth;

  /// 当前维护状态。
  SyncConnectionState get state => _state;

  /// 维护步骤和活动代次变化。
  Stream<SyncConnectionState> get changes => _changes.stream;

  /// 在启动业务 Provider 前恢复持久维护门禁，不自动连接旧服务器。
  Future<void> initialize() async {
    await directory.create(recursive: true);
    // 已完成迁移的缺图报告与活动数据库引用一起持久化。
    final Map<String, dynamic>? active = await store.read('active');
    _publish(
      missingImages: List<String>.from(
        active?['missingImages'] as List? ?? const <String>[],
      ),
    );
    // 上次尚未完成的迁移日志。
    final Map<String, dynamic>? pending = await store.read('pending');
    if (pending != null) {
      await runtime.freezeWrites();
      _publish(
        maintenance: true,
        message: '检测到未完成的数据迁移',
        error: '本机旧数据完整保留。请继续同一次迁移。',
        canCancel: pending['phase'] == 'prepared',
      );
    }
  }

  /// 只读检查服务器和双方数量，不保存目标会话。
  Future<SyncConnectionPreview> preview({
    required String serverAddress,
    required String syncKey,
  }) async {
    _requireIdle();
    // 已认证的目标能力及记录摘要。
    final Map<String, dynamic> remote = await auth.previewConnection(
      apiBaseUrl: serverAddress,
      syncKey: syncKey,
    );
    // 当前本机逻辑快照仅用于确认，执行时会重新冻结并获取。
    final SyncSnapshot local = await runtime.exportSnapshot();
    // 本地活动索引可以保留已断开的来源地址。
    final Map<String, dynamic>? active = await store.read('active');
    // 历史版本从尚存的会话补充来源地址。
    final SyncSession? session = await auth.loadSession();
    // 来源以数据库绑定为准，历史失败连接可能保存了另一台服务器会话。
    final String? localOwner = await runtime.ownerId;
    // 服务端协商的容量上限。
    final Map<String, dynamic> limits = Map<String, dynamic>.from(
      remote['limits'] as Map,
    );
    return SyncConnectionPreview(
      serverAddress: serverAddress,
      ownerId: remote['ownerId'] as String,
      localOwnerId: localOwner,
      sourceAddress:
          active?['serverAddress'] as String? ??
          (session?.identity.id == localOwner ? session?.serverAddress : null),
      localCounts: local.counts,
      remoteCounts: (remote['counts'] as Map).map(
        (dynamic key, dynamic value) =>
            MapEntry(key as String, (value as num).toInt()),
      ),
      localDeletedCount: local.deletedCount,
      remoteDeletedCount: (remote['deletedCount'] as num).toInt(),
      queuedOperations: local.pendingOperations,
      maxOperations: (limits['maxOperations'] as num).toInt(),
      maxBytes: (limits['maxBytes'] as num).toInt(),
      missingImages: await findMissingMigrationImages(local),
    );
  }

  /// 在本地完整准备候选库后开始选定策略，所有远端重试复用日志 ID。
  Future<void> start({
    required SyncConnectionPreview preview,
    required String syncKey,
    required SyncConnectionStrategy strategy,
  }) async {
    _requireIdle();
    if (preview.isReconnect) throw const ApiFailure('同一数据源请使用继续同步');
    if ((preview.localOwnerId == null) !=
        (strategy == SyncConnectionStrategy.mergeInitial)) {
      throw const ApiFailure('数据来源已变化，请重新检查服务器并选择策略');
    }
    _operationActive = true;
    _publish(maintenance: true, busy: true, message: '正在保留本机数据并准备新数据库');
    try {
      await _stopBackgroundTasks();
      await runtime.disconnect();
      await runtime.freezeWrites();
      if (await runtime.ownerId != preview.localOwnerId) {
        throw const ApiFailure('本机数据来源已变化，请重新检查');
      }
      // 冻结后的完整本机快照，包括本机图片关联。
      final SyncSnapshot snapshot = await runtime.exportSnapshot();
      // 只有采用本机数据的策略需要把旧主图携带到目标服务器。
      final List<String> missingImages =
          strategy == SyncConnectionStrategy.replaceLocal
          ? const <String>[]
          : await findMissingMigrationImages(snapshot);
      // 整个操作生命周期固定使用同一迁移身份。
      final String id = const Uuid().v4();
      // 预检完整请求而非只计算行数据大小。
      final int uploadBytes = utf8
          .encode(
            jsonEncode({
              'syncKey': syncKey,
              'migrationId': id,
              'expectedOwnerId': preview.ownerId,
              'snapshotVersion': 2,
              'operations': snapshot.operations,
            }),
          )
          .length;
      if (strategy != SyncConnectionStrategy.replaceLocal &&
          (snapshot.operations.length > preview.maxOperations ||
              uploadBytes > preview.maxBytes)) {
        throw const ApiFailure('完整快照超过服务器允许的记录数或请求大小，尚未修改服务器');
      }
      // 快照文件也保留原始本机字段，不保存密钥。
      final List<int> snapshotBytes = utf8.encode(
        jsonEncode(snapshot.toJson()),
      );
      // 为快照、候选数据和 SQLite 日志留出额外空间；实际写入仍须成功。
      final int needed = snapshotBytes.length * 4 + 64 * 1024 * 1024;
      if (await freeBytes(directory.path) < needed) {
        throw const ApiFailure('本机剩余空间不足，无法安全保存迁移备份');
      }
      // 每次迁移独立目录，候选文件永不覆盖原数据库。
      final Directory work = Directory(path.join(directory.path, id));
      await work.create();
      // 持久化的逻辑快照。
      final String snapshotPath = path.join(work.path, 'snapshot.json');
      await File(snapshotPath).writeAsBytes(snapshotBytes, flush: true);
      // 预先构建候选库以验证字段、可写空间和初始化模式。
      final String candidatePath = path.join(work.path, 'candidate.sqlite');
      // 独立的候选安全存储键。
      final String sessionKey = 'sync.candidate.$id';
      _candidate = await OmniSyncRuntime.createCandidate(
        auth.forkForSession(sessionKey),
        candidatePath,
        snapshot,
        preview.ownerId,
        mergeInitial: strategy == SyncConnectionStrategy.mergeInitial,
        useLocalData: strategy != SyncConnectionStrategy.replaceLocal,
      );
      await _candidate!.close();
      _candidate = null;
      await secureStorage.write(
        key: 'sync.migration.$id.secret',
        value: syncKey,
      );
      // 日志提交之后才允许发送任何可能改变 B 的操作。
      final Map<String, dynamic> journal = {
        'id': id,
        'phase': 'prepared',
        'strategy': strategy.name,
        'serverAddress': preview.serverAddress,
        'expectedOwnerId': preview.ownerId,
        'sourcePath': runtime.databasePath,
        'sourceSessionKey': auth.storageKey,
        'candidatePath': candidatePath,
        'candidateSessionKey': sessionKey,
        'snapshotPath': snapshotPath,
        'snapshotHash': sha256.convert(snapshotBytes).toString(),
        'missingImages': missingImages,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      };
      await store.write('pending', journal);
      // 原会话撤销失败不影响本机断开；候选仍不作为活动会话发布。
      await auth.disconnect();
      await _run(journal, snapshot, syncKey);
    } catch (error) {
      await _failed(error);
      rethrow;
    } finally {
      _operationActive = false;
    }
  }

  /// 继续持久迁移，校验快照完整性并复用原请求身份。
  Future<void> resume() async {
    if (_operationActive || state.busy) {
      throw const ApiFailure('迁移正在进行，请等待当前操作结束');
    }
    _operationActive = true;
    _publish(maintenance: true, busy: true, message: '正在恢复上次迁移');
    try {
      // 未完成的原始迁移日志。
      final Map<String, dynamic>? journal = await store.read('pending');
      if (journal == null) {
        runtime.resumeWrites();
        _publish();
        return;
      }
      await _stopBackgroundTasks();
      await runtime.disconnect();
      await runtime.freezeWrites();
      // 只接受应用迁移目录中登记过的文件。
      final String snapshotPath = _ownedPath(journal['snapshotPath'] as String);
      // 持久快照原始字节，用于发现损坏或意外改写。
      final List<int> bytes = await File(snapshotPath).readAsBytes();
      if (sha256.convert(bytes).toString() != journal['snapshotHash']) {
        throw const ApiFailure('迁移快照校验失败，原本机数据库仍然保留，请勿删除备份');
      }
      // 上次确认时保存的同步密钥。
      final String? secret = await secureStorage.read(
        key: 'sync.migration.${journal['id']}.secret',
      );
      if (secret == null) throw const ApiFailure('迁移密钥不可用，请恢复系统安全存储后重试');
      await _run(
        journal,
        SyncSnapshot.fromJson(
          Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map),
        ),
        secret,
      );
    } catch (error) {
      await _failed(error);
      rethrow;
    } finally {
      _operationActive = false;
    }
  }

  /// 执行远端事务和候选同步；只有活动索引事务成功才向业务层发布新库。
  Future<void> _run(
    Map<String, dynamic> journal,
    SyncSnapshot snapshot,
    String secret,
  ) async {
    // 原始策略在恢复时不可改变。
    final SyncConnectionStrategy strategy = SyncConnectionStrategy.values
        .byName(journal['strategy'] as String);
    // 原操作身份。
    final String id = journal['id'] as String;
    // 固定目标地址。
    final String address = journal['serverAddress'] as String;
    // 原目标身份，覆盖成功后会由回执替换。
    String owner = journal['expectedOwnerId'] as String;
    if (strategy == SyncConnectionStrategy.replaceServer) {
      _publish(maintenance: true, busy: true, message: '正在确认服务器迁移回执');
      // 即使首次执行也先查询；notFound 不代表之前的请求已经回滚。
      Map<String, dynamic> result = await auth.migrationStatus(
        apiBaseUrl: address,
        syncKey: secret,
        migrationId: id,
      );
      if (result['status'] == 'notFound') {
        if (journal['phase'] == 'remoteCommitted' ||
            journal['phase'] == 'syncing' ||
            journal['phase'] == 'ready') {
          throw const ApiFailure('服务器丢失已提交迁移回执，已停止自动操作以保护现有数据');
        }
        journal['phase'] = 'submitting';
        await store.write('pending', journal);
        _publish(maintenance: true, busy: true, message: '正在原子替换目标服务器数据');
        result = await auth.replaceServerSnapshot(
          apiBaseUrl: address,
          syncKey: secret,
          migrationId: id,
          expectedOwnerId: owner,
          operations: snapshot.operations,
        );
      }
      if (result['status'] != 'committed') {
        throw const ApiFailure('此迁移已被后续服务器迁移取代，不能激活旧的数据源');
      }
      owner = result['ownerId'] as String;
      journal['ownerId'] = owner;
      journal['payloadHash'] = result['payloadHash'];
      journal['phase'] = 'remoteCommitted';
      await store.write('pending', journal);
    }
    // 凭证写入独立键，旧运行时永远不能读到候选凭证。
    final AuthRepository candidateAuth = auth.forkForSession(
      journal['candidateSessionKey'] as String,
    );
    // 重试前撤销此前候选会话，避免无限积累设备 session。
    await candidateAuth.disconnect();
    // 服务端事务核对 owner，避免预检后数据源被再次替换。
    final SyncSession session = await candidateAuth.connect(
      apiBaseUrl: address,
      syncKey: secret,
      expectedOwnerId: owner,
    );
    // 先移除引用，关闭或重新打开失败时不能再次使用已关闭对象。
    final OmniSyncRuntime? previousCandidate = _candidate;
    _candidate = null;
    await previousCandidate?.close();
    _candidate = await OmniSyncRuntime.openAtPath(
      candidateAuth,
      _ownedPath(journal['candidatePath'] as String),
      initializeUpload: false,
    );
    // 候选库已完成准备，不能把意外缺失/损坏的文件当成空库继续。
    final initial = await _candidate!.powerSync.getOptional(
      'SELECT value FROM device_sync_metadata WHERE id = ?',
      ['initial_upload'],
    );
    if (initial == null) throw const ApiFailure('候选数据库准备状态丢失，原数据仍保留');
    await _candidate!.powerSync.writeTransaction((transaction) async {
      await transaction.execute(
        'DELETE FROM device_sync_metadata WHERE id = ?',
        ['owner'],
      );
      await transaction.execute(
        'INSERT INTO device_sync_metadata(id,value) VALUES(?,?)',
        ['owner', owner],
      );
    });
    journal['phase'] = 'syncing';
    journal['ownerId'] = owner;
    await store.write('pending', journal);
    _publish(
      maintenance: true,
      busy: true,
      message: strategy == SyncConnectionStrategy.mergeInitial
          ? '正在合并本机数据并等待服务器确认'
          : '正在下载完整数据并验证同步检查点',
    );
    await _candidate!.connect(owner, session: session);
    await _candidate!.catchUp(timeout: catchUpTimeout);
    await _candidate!.restoreLocalAttachments(snapshot, matchingOnly: true);
    // 检查点后再次验证当前 API 身份，旧 PowerSync JWT 不能作为身份有效凭据。
    final SyncSession? checked = await candidateAuth.restoreSession();
    if (checked == null || checked.isOffline || checked.identity.id != owner) {
      throw const ApiFailure('目标服务器身份验证未完成，请重试原迁移');
    }
    if (strategy == SyncConnectionStrategy.replaceServer) {
      // 检查是否在候选下载期间发生了后续替换。
      final Map<String, dynamic> result = await candidateAuth.migrationStatus(
        apiBaseUrl: address,
        syncKey: secret,
        migrationId: id,
      );
      if (result['status'] != 'committed' || result['ownerId'] != owner) {
        throw const ApiFailure('目标服务器已发生后续迁移，不能激活旧数据');
      }
    }
    journal['phase'] = 'ready';
    await store.write('pending', journal);
    await store.activate(
      active: {
        'databasePath': _candidate!.databasePath,
        'sessionKey': candidateAuth.storageKey,
        'serverAddress': address,
        'missingImages': journal['missingImages'] ?? const <String>[],
      },
      migration: journal,
      backup: {
        'id': id,
        'databasePath': journal['sourcePath'],
        'snapshotPath': journal['snapshotPath'],
        'sessionKey': journal['sourceSessionKey'],
        'createdAt': journal['createdAt'],
        'strategy': strategy.name,
        'missingImages': journal['missingImages'] ?? const <String>[],
      },
    );
    _retired.add(_runtime);
    _runtime = _candidate!;
    _candidate = null;
    _auth = candidateAuth;
    _publish(
      message: '服务器连接完成，业务数据已同步；本机图片将在目标支持时继续补传',
      generation: state.generation + 1,
      missingImages: List<String>.from(
        journal['missingImages'] as List? ?? const <String>[],
      ),
    );
    // 激活已完成，清理临时密钥失败也不能把成功迁移重新标成待提交。
    try {
      await secureStorage.delete(key: 'sync.migration.$id.secret');
    } catch (_) {
      /* 启动后可重试清理，不回退活动索引。 */
    }
  }

  /// 相同 owner 只更换会话，不重建队列或 clientId。
  Future<void> reconnect({
    required SyncConnectionPreview preview,
    required String syncKey,
  }) async {
    _requireIdle();
    _operationActive = true;
    _publish(maintenance: true, busy: true, message: '正在恢复原数据源连接');
    // 新会话仍保存在独立键，认证失败不污染原会话。
    final AuthRepository next = auth.forkForSession(
      'sync.session.${const Uuid().v4()}',
    );
    // 活动指针提交前由当前方法负责释放的候选运行时。
    OmniSyncRuntime? reopened;
    try {
      if (!preview.isReconnect || await runtime.ownerId != preview.ownerId) {
        throw const ApiFailure('数据来源已变化，请重新检查服务器');
      }
      await next.connect(
        apiBaseUrl: preview.serverAddress,
        syncKey: syncKey,
        expectedOwnerId: preview.ownerId,
      );
      await _stopBackgroundTasks();
      await runtime.disconnect();
      await runtime.freezeWrites();
      // 新运行时复用原库中的队列及检查点。
      reopened = await OmniSyncRuntime.openAtPath(
        next,
        runtime.databasePath,
        initializeUpload: false,
      );
      await store.write('active', {
        'databasePath': reopened.databasePath,
        'sessionKey': next.storageKey,
        'serverAddress': preview.serverAddress,
        'missingImages': state.missingImages,
      });
      _retired.add(_runtime);
      _runtime = reopened;
      reopened = null;
      _auth = next;
      _publish(message: '已恢复原数据源连接', generation: state.generation + 1);
    } catch (error) {
      try {
        await reopened?.close();
      } finally {
        try {
          await next.disconnect();
        } catch (_) {
          /* 不让撤销失败覆盖原始错误。 */
        }
        runtime.resumeWrites();
        _publish(error: error.toString(), generation: state.generation + 1);
      }
      rethrow;
    } finally {
      _operationActive = false;
    }
  }

  /// 明确断开时先停止网络，再清除凭证；不会因清库触发自动重连。
  Future<void> disconnect({bool clearLocal = false}) async {
    _requireIdle();
    _operationActive = true;
    _publish(maintenance: true, busy: true, message: '正在断开服务器');
    try {
      await _stopBackgroundTasks();
      await runtime.disconnect();
      await runtime.freezeWrites();
      await auth.disconnect();
      if (clearLocal) await runtime.disconnectAndClear();
    } finally {
      runtime.resumeWrites();
      _publish(generation: state.generation + 1);
      _operationActive = false;
    }
  }

  /// 仅在尚未发出远端写入时取消；未知提交结果必须查询原回执。
  Future<void> cancel() async {
    if (_operationActive || state.busy) throw const ApiFailure('请等待当前操作结束');
    _operationActive = true;
    try {
      // 持久状态而非 UI 内存决定是否允许取消。
      final Map<String, dynamic>? journal = await store.read('pending');
      if (journal == null || journal['phase'] != 'prepared') {
        throw const ApiFailure('服务器操作可能已提交，请继续原迁移');
      }
      // 关闭前取走字段引用，失败也不会遗留已关闭实例。
      final OmniSyncRuntime? candidate = _candidate;
      _candidate = null;
      await candidate?.close();
      await store.remove('pending');
      runtime.resumeWrites();
      _publish(message: '已取消迁移，本机数据仍保留', generation: state.generation + 1);
      try {
        await secureStorage.delete(
          key: 'sync.migration.${journal['id']}.secret',
        );
      } catch (_) {
        /* 取消已生效，临时密钥清理不阻塞本机使用。 */
      }
    } finally {
      _operationActive = false;
    }
  }

  /// 业务依赖切换后释放旧连接，文件继续作为备份保留。
  Future<void> releaseRetired() async {
    // 从队列中取出本批已冻结运行时。
    final List<OmniSyncRuntime> retired = List.of(_retired);
    _retired.clear();
    for (final OmniSyncRuntime old in retired) {
      await old.close();
    }
  }

  /// 仅清理用户选中的非活动数据库和快照，图片可能仍被当前数据引用而保持不动。
  Future<void> deleteBackup(String id) async {
    _requireIdle();
    _operationActive = true;
    try {
      // 只接受控制库已经登记的备份，不接受界面传入任意文件路径。
      final Map<String, dynamic>? backup = await store.read('backup:$id');
      if (backup == null) return;
      // 原安装的数据库可能在迁移目录之外，但必须仍位于应用文档目录。
      final String database = path.normalize(
        path.absolute(backup['databasePath'] as String),
      );
      if (!path.isWithin(path.absolute(directory.parent.path), database) ||
          path.equals(database, path.absolute(runtime.databasePath))) {
        throw const ApiFailure('不能删除活动数据库或应用目录之外的文件');
      }
      // 所有目标先完成校验，不能在发现第二个目标越界前已经删除旧库。
      final String snapshotPath = _ownedPath(backup['snapshotPath'] as String);
      if (path.basename(snapshotPath) != 'snapshot.json' ||
          path.basename(path.dirname(snapshotPath)) != id) {
        throw const ApiFailure('备份快照路径与迁移身份不一致');
      }
      // 在旧连接全部关闭后才清理其 SQLite 文件。
      await releaseRetired();
      for (final String suffix in ['', '-wal', '-shm']) {
        // 当前备份的明确 SQLite 文件及辅助文件。
        final File file = File('$database$suffix');
        if (await file.exists()) await file.delete();
      }
      // 快照路径同样必须属于当前应用迁移目录。
      final File snapshot = File(snapshotPath);
      if (await snapshot.exists()) await snapshot.delete();
      await store.remove('backup:$id');
      // 旧凭证不可误删当前活动会话。
      final String? oldKey = backup['sessionKey'] as String?;
      if (oldKey != null && oldKey != auth.storageKey) {
        try {
          await secureStorage.delete(key: oldKey);
        } catch (_) {
          /* 文件清理已完成，旧凭证删除可独立重试。 */
        }
      }
    } finally {
      _operationActive = false;
    }
  }

  /// 根据持久阶段保持失败后的维护锁；未提交日志前可安全恢复本机使用。
  Future<void> _failed(Object error) async {
    try {
      await _candidate?.disconnect();
    } catch (_) {
      /* 清理错误不能遮蔽原始错误或遗留 busy 状态。 */
    }
    // 即使响应丢失，已记录 submitting 的请求仍保持唯一身份。
    final Map<String, dynamic>? journal = await store.read('pending');
    if (journal == null) runtime.resumeWrites();
    _publish(
      maintenance: journal != null,
      error: error.toString(),
      message: journal == null ? '连接尚未完成，本机数据仍保留' : '迁移已暂停，本机原数据完整保留',
      canCancel: journal?['phase'] == 'prepared',
      generation: journal == null ? state.generation + 1 : state.generation,
    );
  }

  /// 校验内部文件不能越出应用迁移目录。
  String _ownedPath(String value) {
    // 规范化后进行目录边界比较。
    final String resolved = path.normalize(path.absolute(value));
    if (!path.isWithin(path.absolute(directory.path), resolved)) {
      throw const ApiFailure('迁移文件路径不属于当前应用目录');
    }
    return resolved;
  }

  /// 禁止并发连接及在未完成迁移上启动另一次替换。
  void _requireIdle() {
    if (_operationActive || state.busy || state.maintenance) {
      throw const ApiFailure('请先完成或取消当前迁移');
    }
  }

  /// 原子发布供所有 Provider 和窗口使用的运行状态。
  void _publish({
    bool maintenance = false,
    bool busy = false,
    String message = '',
    String? error,
    bool canCancel = false,
    int? generation,
    List<String>? missingImages,
  }) {
    _state = SyncConnectionState(
      generation: generation ?? state.generation,
      maintenance: maintenance,
      busy: busy,
      message: message,
      error: error,
      canCancel: canCancel,
      missingImages: missingImages ?? state.missingImages,
    );
    _changes.add(_state);
  }

  /// 测试和应用退出时释放所有连接。
  Future<void> close() async {
    await _stopBackgroundTasks();
    await _candidate?.close();
    await releaseRetired();
    await runtime.close();
    await store.close();
    await _changes.close();
  }
}
