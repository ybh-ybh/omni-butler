import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_store.dart';
import 'package:omni_butler/core/sync/sync_write_gate.dart';

/// 构造网络不可达故障，不向真实服务器发送任何请求。
DioException _unavailable(RequestOptions request) => DioException(
  requestOptions: request,
  type: DioExceptionType.connectionError,
  error: '测试注入：响应丢失或设备离线',
);

/// 在真实安全存储测试替身上仅注入临时密钥清理故障。
class _FaultingStorage extends FlutterSecureStorage {
  /// 控制是否拒绝清理迁移临时密钥。
  bool failSecretDeletion = false;

  /// 普通会话存取沿用官方替身，仅模拟系统拒绝临时密钥删除。
  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failSecretDeletion && key.startsWith('sync.migration.')) {
      throw StateError('测试注入：安全存储暂不可写');
    }
    return super.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

/// 真实 SQLite、系统安全存储替身和可控 HTTP 的集成夹具。
class _Fixture {
  /// 当前测试的临时根目录。
  final Directory directory;

  /// 与生产相同安全存储接口的测试替身。
  final _FaultingStorage storage;

  /// 原活动会话仓储。
  final AuthRepository auth;

  /// 独立持久控制库。
  final SyncConnectionStore store;

  /// 原本机 SQLite 运行时。
  final OmniSyncRuntime source;

  /// 生产连接协调器。
  late final SyncConnectionCoordinator coordinator;

  /// 收到的 HTTP 请求，用于证明操作顺序和幂等身份。
  final List<RequestOptions> requests = <RequestOptions>[];

  /// 测试可覆盖的 HTTP 响应函数。
  late Future<Map<String, dynamic>> Function(RequestOptions) respond;

  /// 可控磁盘空间，默认足以准备候选库。
  int availableBytes = 1024 * 1024 * 1024;

  /// 预检服务器身份。
  String remoteOwner = 'owner-b';

  /// 创建已经打开的独立测试夹具。
  _Fixture._(this.directory, this.storage, this.auth, this.store, this.source);

  /// 打开真实数据库并安装内存 HTTP 拦截器。
  static Future<_Fixture> open() async {
    // 每次测试的新文件目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni_connection_coordinator_',
    );
    // 测试使用系统安全存储的官方内存替身。
    final _FaultingStorage storage = _FaultingStorage();
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'sync.device_session': jsonEncode(<String, dynamic>{
        'baseUrl': 'https://a.example.com/omni-butler/api/v1',
        'accessToken': 'old-access',
        'refreshToken': 'old-refresh',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'identity': <String, String>{'sub': 'owner-a'},
      }),
    });
    // 工厂被调用时夹具已经构造完成。
    late _Fixture fixture;
    // 客户端层仍走真实 Dio URL、请求体及认证处理。
    final AuthRepository auth = AuthRepository(
      storage,
      clientFactory: (String url) {
        // 每个 API 客户端仅返回内存响应。
        final Dio client = Dio(BaseOptions(baseUrl: url));
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest:
                (
                  RequestOptions request,
                  RequestInterceptorHandler handler,
                ) async {
                  fixture.requests.add(request);
                  try {
                    handler.resolve(
                      Response<Map<String, dynamic>>(
                        requestOptions: request,
                        statusCode: 200,
                        data: await fixture.respond(request),
                      ),
                    );
                  } on DioException catch (error) {
                    handler.reject(error);
                  } catch (error) {
                    handler.reject(
                      DioException(requestOptions: request, error: error),
                    );
                  }
                },
          ),
        );
        return client;
      },
    );
    // 原库保存不同于 B 的 owner，包含一条尚未上传的当前数据。
    final OmniSyncRuntime source = await OmniSyncRuntime.openAtPath(
      auth,
      '${directory.path}/source.sqlite',
    );
    await source.powerSync.execute(
      'INSERT INTO device_sync_metadata(id,value) VALUES(?,?)',
      <Object?>['owner', 'owner-a'],
    );
    // 独立 SQLite 控制库记录旧活动指针。
    final SyncConnectionStore store = SyncConnectionStore(
      File('${directory.path}/control.sqlite'),
    );
    await store.write('active', <String, dynamic>{
      'databasePath': source.databasePath,
      'sessionKey': auth.storageKey,
      'serverAddress': 'https://a.example.com',
    });
    fixture = _Fixture._(directory, storage, auth, store, source);
    fixture.respond = fixture.defaultResponse;
    fixture.coordinator = SyncConnectionCoordinator(
      store: store,
      secureStorage: storage,
      directory: Directory('${directory.path}/migrations'),
      runtime: source,
      auth: auth,
      freeBytes: (String _) async => fixture.availableBytes,
      catchUpTimeout: const Duration(milliseconds: 200),
    );
    await fixture.coordinator.initialize();
    await fixture.addTodo('original');
    return fixture;
  }

  /// 默认只支持预检、设备认证和断开，其他接口必须显式由测试响应。
  Future<Map<String, dynamic>> defaultResponse(RequestOptions request) async {
    switch (request.path) {
      case '/sync/connection-preview':
        return <String, dynamic>{
          'protocolVersion': 1,
          'snapshotVersion': 1,
          'ownerId': remoteOwner,
          'counts': <String, int>{'todo_items': 7},
          'deletedCount': 2,
          'limits': <String, int>{
            'maxOperations': 100000,
            'maxBytes': 32 * 1024 * 1024,
          },
        };
      case '/auth/connect':
        return <String, dynamic>{
          'accessToken': 'new-access',
          'refreshToken': 'new-refresh',
          'expiresIn': 900,
        };
      case '/auth/session':
        return <String, dynamic>{'sub': remoteOwner};
      case '/auth/disconnect':
        return <String, dynamic>{};
      default:
        throw _unavailable(request);
    }
  }

  /// 通过旧运行时业务层写入，模拟原页面持有的仓储引用。
  Future<void> addTodo(String id) async {
    // 测试业务时间。
    final DateTime now = DateTime.utc(2026, 9, 27);
    await source.database
        .into(source.database.todoItems)
        .insert(
          TodoItemsCompanion.insert(
            id: id,
            title: '离线保留数据',
            scheduledDate: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  /// 获取用于后续策略执行的真实生产预检对象。
  Future<SyncConnectionPreview> preview() => coordinator.preview(
    serverAddress: 'https://b.example.com',
    syncKey: 'test-sync-secret',
  );

  /// 当前测试真实发出的服务器替换请求。
  List<RequestOptions> get replacements => requests
      .where((RequestOptions request) => request.path == '/sync/migrations')
      .toList();

  /// 释放连接后删除该测试独占目录。
  Future<void> close() async {
    await coordinator.close();
    await directory.delete(recursive: true);
  }
}

/// 验证迁移控制状态、故障恢复和活动库切换边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 测试明确使用不同 SQLite 连接完成候选库和旧库的切换。
  final bool previousWarningSetting =
      driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarningSetting;
  });
  // 每个用例使用独立资源，避免状态串扰。
  late _Fixture fixture;
  setUp(() async {
    fixture = await _Fixture.open();
  });
  tearDown(() async {
    await fixture.close();
  });

  test('断开等待图片任务排空后才冻结和清除会话', () async {
    // 人为延迟图片响应，确认维护流程不会抢先关闭数据库。
    final Completer<void> drained = Completer<void>();
    final Completer<void> stopping = Completer<void>();
    final unregister = fixture.coordinator.registerBackgroundStop(() {
      if (!stopping.isCompleted) stopping.complete();
      return drained.future;
    });
    final Future<void> disconnect = fixture.coordinator.disconnect();
    await stopping.future;
    expect(fixture.coordinator.state.maintenance, isTrue);
    expect(fixture.source.writesFrozen, isFalse);
    expect(await fixture.auth.loadSession(), isNotNull);
    drained.complete();
    await disconnect;
    unregister();
    expect(await fixture.auth.loadSession(), isNull);
    expect(fixture.coordinator.state.maintenance, isFalse);
  });

  test('启动从控制库恢复上次迁移缺图报告', () async {
    await fixture.store.write('active', <String, dynamic>{
      'missingImages': <String>['物品：云端相机'],
    });
    await fixture.coordinator.initialize();
    expect(fixture.coordinator.state.missingImages, <String>['物品：云端相机']);
  });

  test('服务器预检只读取数量，不保存会话、不绑定 B、不修改本机队列', () async {
    // 预检前的完整活动会话。
    final Map<String, String> credentials = await fixture.storage.readAll();
    // 预检前活动数据源索引。
    final Map<String, dynamic>? active = await fixture.store.read('active');
    // 生产预检结果。
    final SyncConnectionPreview preview = await fixture.preview();
    expect(preview.ownerId, 'owner-b');
    expect(preview.localOwnerId, 'owner-a');
    expect(preview.sourceAddress, 'https://a.example.com');
    expect(preview.localTotal, 1);
    expect(preview.remoteTotal, 7);
    expect(preview.remoteDeletedCount, 2);
    expect(preview.queuedOperations, 1);
    expect(await fixture.storage.readAll(), credentials);
    expect(await fixture.store.read('active'), active);
    expect(await fixture.store.read('pending'), isNull);
    expect(await fixture.source.ownerId, 'owner-a');
    expect(fixture.source.writesFrozen, isFalse);
    expect(
      fixture.requests.map((RequestOptions request) => request.path),
      <String>['/sync/connection-preview'],
    );
  });

  test('磁盘不足在远端操作之前失败，恢复原库写入并保留会话', () async {
    // 已确认的目标数量。
    final SyncConnectionPreview preview = await fixture.preview();
    // 原活动凭证不会因本机准备失败被清除。
    final Map<String, String> credentials = await fixture.storage.readAll();
    fixture.availableBytes = 0;
    await expectLater(
      fixture.coordinator.start(
        preview: preview,
        syncKey: 'test-sync-secret',
        strategy: SyncConnectionStrategy.replaceServer,
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(fixture.replacements, isEmpty);
    expect(
      fixture.requests.map((RequestOptions request) => request.path),
      <String>['/sync/connection-preview'],
    );
    expect(await fixture.storage.readAll(), credentials);
    expect(await fixture.store.read('pending'), isNull);
    expect(fixture.coordinator.state.maintenance, isFalse);
    expect(fixture.source.writesFrozen, isFalse);
    await fixture.addTodo('after-insufficient-space');
    expect((await fixture.source.exportSnapshot()).totalCount, 2);
  });

  test('候选库准备失败保留原数据，不能提前撤销旧会话或修改 B', () async {
    // 模拟来源库拥有当前候选 schema 不支持的历史字段。
    await fixture.source.powerSync.execute(
      'ALTER TABLE todo_items ADD COLUMN unknown_snapshot_column TEXT',
    );
    // 预览可以读取，但候选导入应严格拒绝未知字段。
    final SyncConnectionPreview preview = await fixture.preview();
    // 本机准备失败不能删除当前会话。
    final Map<String, String> credentials = await fixture.storage.readAll();
    await expectLater(
      fixture.coordinator.start(
        preview: preview,
        syncKey: 'test-sync-secret',
        strategy: SyncConnectionStrategy.replaceServer,
      ),
      throwsFormatException,
    );
    expect(await fixture.storage.readAll(), credentials);
    expect(await fixture.store.read('pending'), isNull);
    expect(fixture.replacements, isEmpty);
    expect(
      fixture.requests.any(
        (RequestOptions request) => request.path == '/auth/disconnect',
      ),
      isFalse,
    );
    expect((await fixture.source.exportSnapshot()).totalCount, 1);
    expect(await fixture.source.ownerId, 'owner-a');
    expect(fixture.source.writesFrozen, isFalse);
  });

  test('提交响应未知必须保留维护锁，重试使用相同迁移 ID 和完整请求', () async {
    fixture.respond = (RequestOptions request) async {
      if (request.path == '/sync/migrations/status') {
        return <String, dynamic>{'status': 'notFound'};
      }
      return fixture.defaultResponse(request);
    };
    // 第一次明确选择以本机替换 B。
    final SyncConnectionPreview preview = await fixture.preview();
    await expectLater(
      fixture.coordinator.start(
        preview: preview,
        syncKey: 'test-sync-secret',
        strategy: SyncConnectionStrategy.replaceServer,
      ),
      throwsA(isA<ApiFailure>()),
    );
    // 响应丢失后 durable submitting 状态不允许另起操作。
    final Map<String, dynamic> journal = (await fixture.store.read('pending'))!;
    expect(journal['phase'], 'submitting');
    expect(fixture.coordinator.state.canCancel, isFalse);
    expect(fixture.coordinator.state.maintenance, isTrue);
    expect(fixture.source.writesFrozen, isTrue);
    await expectLater(fixture.coordinator.cancel(), throwsA(isA<ApiFailure>()));
    await expectLater(fixture.preview(), throwsA(isA<ApiFailure>()));
    await expectLater(
      fixture.coordinator.start(
        preview: preview,
        syncKey: 'test-sync-secret',
        strategy: SyncConnectionStrategy.replaceServer,
      ),
      throwsA(isA<ApiFailure>()),
    );
    await expectLater(fixture.coordinator.resume(), throwsA(isA<ApiFailure>()));
    expect(fixture.replacements, hasLength(2));
    expect(fixture.replacements.first.data, fixture.replacements.last.data);
    expect(
      (fixture.replacements.first.data as Map)['migrationId'],
      journal['id'],
    );
    expect((await fixture.store.read('pending'))!['id'], journal['id']);
    expect((await fixture.source.exportSnapshot()).totalCount, 1);
  });

  test('B 已提交但响应丢失，恢复只查询原回执而不再次清空 B', () async {
    // 模拟服务端独立保存的迁移回执。
    Map<String, dynamic>? receipt;
    fixture.respond = (RequestOptions request) async {
      // A 已经完全下线，本机迁移仍须继续到 B。
      if (request.uri.host == 'a.example.com') throw _unavailable(request);
      if (request.path == '/sync/migrations/status') {
        return receipt ?? <String, dynamic>{'status': 'notFound'};
      }
      if (request.path == '/sync/migrations') {
        receipt = <String, dynamic>{
          'status': 'committed',
          'ownerId': 'owner-b-new',
          'payloadHash': 'canonical-hash',
        };
        throw _unavailable(request);
      }
      // 在进入 PowerSync 之前停在独立的后续认证失败，保留真实编排路径。
      if (request.path == '/auth/connect') throw _unavailable(request);
      return fixture.defaultResponse(request);
    };
    // 生产预检确认的是替换之前的 B 身份。
    final SyncConnectionPreview preview = await fixture.preview();
    await expectLater(
      fixture.coordinator.start(
        preview: preview,
        syncKey: 'test-sync-secret',
        strategy: SyncConnectionStrategy.replaceServer,
      ),
      throwsA(isA<ApiFailure>()),
    );
    // 重启恢复必须沿用的唯一迁移身份。
    final String id = (await fixture.store.read('pending'))!['id'] as String;
    await expectLater(fixture.coordinator.resume(), throwsA(isA<ApiFailure>()));
    await expectLater(fixture.coordinator.resume(), throwsA(isA<ApiFailure>()));
    expect(fixture.replacements, hasLength(1));
    expect((await fixture.store.read('pending'))!['phase'], 'remoteCommitted');
    expect((await fixture.store.read('pending'))!['ownerId'], 'owner-b-new');
    expect((await fixture.store.read('pending'))!['id'], id);
    expect(
      fixture.requests
          .where(
            (RequestOptions request) =>
                request.path == '/sync/migrations/status',
          )
          .every(
            (RequestOptions request) =>
                (request.data as Map)['migrationId'] == id,
          ),
      isTrue,
    );
    expect(
      fixture.requests
          .where((RequestOptions request) => request.path == '/auth/connect')
          .every(
            (RequestOptions request) =>
                (request.data as Map)['expectedOwnerId'] == 'owner-b-new',
          ),
      isTrue,
    );
    expect((await fixture.source.exportSnapshot()).totalCount, 1);
    expect(fixture.coordinator.state.maintenance, isTrue);

    // 已确认提交的回执丢失时，不能将 notFound 解释为需要再清空 B。
    receipt = <String, dynamic>{'status': 'notFound'};
    await expectLater(fixture.coordinator.resume(), throwsA(isA<ApiFailure>()));
    expect(fixture.coordinator.state.error, contains('丢失已提交迁移回执'));
    expect(fixture.replacements, hasLength(1));

    // 后续迁移取代了本次数据源，也必须停止激活旧回执。
    receipt = <String, dynamic>{'status': 'superseded', 'ownerId': 'owner-c'};
    await expectLater(fixture.coordinator.resume(), throwsA(isA<ApiFailure>()));
    expect(fixture.coordinator.state.error, contains('后续服务器迁移取代'));
    expect(fixture.replacements, hasLength(1));
    expect((await fixture.store.read('pending'))!['id'], id);
  });

  test('尚未发出远端修改的 prepared 迁移可以取消，原库重新开放写入', () async {
    // 默认 HTTP 在首次查询迁移回执时失败，尚未发出替换请求。
    final SyncConnectionPreview preview = await fixture.preview();
    await expectLater(
      fixture.coordinator.start(
        preview: preview,
        syncKey: 'test-sync-secret',
        strategy: SyncConnectionStrategy.replaceServer,
      ),
      throwsA(isA<ApiFailure>()),
    );
    // 以持久日志确认取消仍然安全。
    final Map<String, dynamic> journal = (await fixture.store.read('pending'))!;
    expect(journal['phase'], 'prepared');
    expect(fixture.coordinator.state.canCancel, isTrue);
    expect(fixture.source.writesFrozen, isTrue);
    expect(
      await fixture.storage.read(key: 'sync.migration.${journal['id']}.secret'),
      'test-sync-secret',
    );
    await fixture.coordinator.cancel();
    expect(await fixture.store.read('pending'), isNull);
    expect(
      await fixture.storage.read(key: 'sync.migration.${journal['id']}.secret'),
      isNull,
    );
    expect(fixture.coordinator.state.maintenance, isFalse);
    expect(fixture.source.writesFrozen, isFalse);
    expect(await fixture.source.ownerId, 'owner-a');
    expect(fixture.replacements, isEmpty);
    await fixture.addTodo('after-cancel');
    expect((await fixture.source.exportSnapshot()).totalCount, 2);
  });

  test('控制库激活中途失败回滚全部引用，成功后同时保存备份与完成日志', () async {
    // 旧活动索引作为回滚结果基准。
    final Map<String, dynamic>? original = await fixture.store.read('active');
    // 待激活迁移记录。
    final Map<String, dynamic> migration = <String, dynamic>{
      'id': 'activation-test',
      'phase': 'ready',
    };
    await fixture.store.write('pending', migration);
    await fixture.store.customStatement(
      "CREATE TRIGGER reject_completion BEFORE INSERT ON connection_control WHEN NEW.id = 'migration:activation-test' BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
    );
    // 新数据库路径及会话键必须在同一个 SQLite 提交中生效。
    final Map<String, dynamic> active = <String, dynamic>{
      'databasePath': 'new.sqlite',
      'sessionKey': 'candidate-key',
    };
    // 旧库备份索引也必须与活动引用保持原子一致。
    final Map<String, dynamic> backup = <String, dynamic>{
      'id': 'activation-test',
      'databasePath': 'old.sqlite',
    };
    await expectLater(
      fixture.store.activate(
        active: active,
        migration: migration,
        backup: backup,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await fixture.store.read('active'), original);
    expect(await fixture.store.backups(), isEmpty);
    expect(await fixture.store.read('migration:activation-test'), isNull);
    expect(await fixture.store.read('pending'), migration);
    await fixture.store.customStatement('DROP TRIGGER reject_completion');
    await fixture.store.activate(
      active: active,
      migration: migration,
      backup: backup,
    );
    expect(await fixture.store.read('active'), active);
    expect(await fixture.store.backups(), <Map<String, dynamic>>[backup]);
    expect(
      (await fixture.store.read('migration:activation-test'))!['phase'],
      'completed',
    );
    expect(await fixture.store.read('pending'), isNull);
  });

  test('启动恢复先冻结旧引用，快照校验失败不会触达服务器', () async {
    // 有效快照最初写入持久迁移目录。
    final File snapshot = File(
      '${fixture.coordinator.directory.path}/snapshot.json',
    );
    // 日志固定的是原始内容摘要。
    final List<int> original = utf8.encode(
      jsonEncode((await fixture.source.exportSnapshot()).toJson()),
    );
    await snapshot.writeAsBytes(original, flush: true);
    await fixture.store.write('pending', <String, dynamic>{
      'id': 'recovery-test',
      'phase': 'submitting',
      'snapshotPath': snapshot.path,
      'snapshotHash': sha256.convert(original).toString(),
    });
    await fixture.coordinator.initialize();
    expect(fixture.coordinator.state.maintenance, isTrue);
    expect(fixture.source.writesFrozen, isTrue);
    await expectLater(
      fixture.addTodo('late-old-write'),
      throwsA(isA<SyncWritesFrozen>()),
    );
    await snapshot.writeAsString('corrupted snapshot', flush: true);
    await expectLater(fixture.coordinator.resume(), throwsA(isA<ApiFailure>()));
    expect(fixture.requests, isEmpty);
    expect(fixture.coordinator.state.error, contains('校验失败'));
    expect(fixture.coordinator.state.maintenance, isTrue);
    expect((await fixture.source.exportSnapshot()).totalCount, 1);
  });

  test('相同 owner 重连切换运行时，旧引用保持冻结且队列和客户端身份保留', () async {
    fixture.remoteOwner = 'owner-a';
    // 同一身份的不同地址属于普通重连。
    final SyncConnectionPreview preview = await fixture.preview();
    // 原客户端事务身份不能因重连改变。
    final Map<String, Object?> identity = await fixture.source.powerSync.get(
      "SELECT value FROM device_sync_metadata WHERE id='client_id'",
    );
    await fixture.coordinator.reconnect(
      preview: preview,
      syncKey: 'test-sync-secret',
    );
    expect(identical(fixture.coordinator.runtime, fixture.source), isFalse);
    expect(
      fixture.coordinator.runtime.databasePath,
      fixture.source.databasePath,
    );
    expect(fixture.coordinator.state.generation, 1);
    expect(fixture.coordinator.state.maintenance, isFalse);
    expect(fixture.source.writesFrozen, isTrue);
    await expectLater(
      fixture.addTodo('retired-write'),
      throwsA(isA<SyncWritesFrozen>()),
    );
    expect(
      await fixture.coordinator.runtime.powerSync.get(
        "SELECT value FROM device_sync_metadata WHERE id='client_id'",
      ),
      identity,
    );
    expect(
      (await fixture.coordinator.runtime.exportSnapshot()).pendingOperations,
      1,
    );
    expect(
      (await fixture.store.read('active'))!['sessionKey'],
      fixture.coordinator.auth.storageKey,
    );
    expect(
      (await fixture.coordinator.auth.loadSession())!.identity.id,
      'owner-a',
    );
    expect(fixture.replacements, isEmpty);
  });

  test('重连写入活动指针失败时保留原会话和队列，并恢复旧库写门禁', () async {
    fixture.remoteOwner = 'owner-a';
    // 原会话是候选激活失败后的唯一有效本机会话。
    final Map<String, String> credentials = await fixture.storage.readAll();
    // 原活动索引不能部分替换。
    final Map<String, dynamic>? active = await fixture.store.read('active');
    // 同身份重连仍使用独立候选会话。
    final SyncConnectionPreview preview = await fixture.preview();
    await fixture.store.customStatement(
      "CREATE TRIGGER reject_active BEFORE UPDATE ON connection_control WHEN NEW.id = 'active' BEGIN SELECT RAISE(ABORT, 'injected activation failure'); END",
    );
    await expectLater(
      fixture.coordinator.reconnect(
        preview: preview,
        syncKey: 'test-sync-secret',
      ),
      throwsA(isA<Exception>()),
    );
    expect(identical(fixture.coordinator.runtime, fixture.source), isTrue);
    expect(await fixture.store.read('active'), active);
    expect(await fixture.storage.readAll(), credentials);
    expect(fixture.source.writesFrozen, isFalse);
    expect(fixture.coordinator.state.maintenance, isFalse);
    await fixture.addTodo('after-reconnect-failure');
    expect((await fixture.source.exportSnapshot()).totalCount, 2);
    expect((await fixture.source.exportSnapshot()).pendingOperations, 2);
  });

  test('并发恢复和取消只允许一个操作准入，取消完成后门禁正常释放', () async {
    // 先停在未修改服务器的 prepared 阶段。
    final SyncConnectionPreview preview = await fixture.preview();
    await expectLater(
      fixture.coordinator.start(
        preview: preview,
        syncKey: 'test-sync-secret',
        strategy: SyncConnectionStrategy.replaceServer,
      ),
      throwsA(isA<ApiFailure>()),
    );
    // 第一次恢复已经进入网络查询的通知。
    final Completer<void> entered = Completer<void>();
    // 保持第一个恢复运行，制造确定性的按钮重入。
    final Completer<void> release = Completer<void>();
    fixture.respond = (RequestOptions request) async {
      if (request.path == '/sync/migrations/status') {
        entered.complete();
        await release.future;
        throw _unavailable(request);
      }
      return fixture.defaultResponse(request);
    };
    // 立即观察异步错误，避免故障注入成为未处理异常。
    final Future<void> first = expectLater(
      fixture.coordinator.resume(),
      throwsA(isA<ApiFailure>()),
    );
    await expectLater(fixture.coordinator.resume(), throwsA(isA<ApiFailure>()));
    await expectLater(fixture.coordinator.cancel(), throwsA(isA<ApiFailure>()));
    await entered.future;
    release.complete();
    await first;
    expect(fixture.coordinator.state.canCancel, isTrue);
    // 同一个事件循环里连续取消，也只能执行一份状态清理。
    final Future<void> cancellation = fixture.coordinator.cancel();
    await expectLater(fixture.coordinator.cancel(), throwsA(isA<ApiFailure>()));
    await cancellation;
    expect(await fixture.store.read('pending'), isNull);
    expect(fixture.source.writesFrozen, isFalse);
    expect(fixture.replacements, isEmpty);
  });

  test('并发同 owner 重连在第一个 await 之前锁定准入，只建立一个候选会话', () async {
    fixture.remoteOwner = 'owner-a';
    // 两个调用使用同一份已认证预检结果。
    final SyncConnectionPreview preview = await fixture.preview();
    // 认证请求已发出的确定性同步信号。
    final Completer<void> entered = Completer<void>();
    // 测试显式放行第一次认证。
    final Completer<void> release = Completer<void>();
    fixture.respond = (RequestOptions request) async {
      if (request.path == '/auth/connect') {
        entered.complete();
        await release.future;
      }
      return fixture.defaultResponse(request);
    };
    // 第一次重连在等待 HTTP 时持续占用协调器。
    final Future<void> first = fixture.coordinator.reconnect(
      preview: preview,
      syncKey: 'test-sync-secret',
    );
    await expectLater(
      fixture.coordinator.reconnect(
        preview: preview,
        syncKey: 'test-sync-secret',
      ),
      throwsA(isA<ApiFailure>()),
    );
    await entered.future;
    release.complete();
    await first;
    expect(
      fixture.requests.where(
        (RequestOptions request) => request.path == '/auth/connect',
      ),
      hasLength(1),
    );
    expect(fixture.coordinator.state.generation, 1);
    expect(fixture.source.writesFrozen, isTrue);
  });

  test('取消后临时密钥删除失败不使本机永久停留在维护状态', () async {
    // 停在可安全取消的本地准备完成阶段。
    final SyncConnectionPreview preview = await fixture.preview();
    await expectLater(
      fixture.coordinator.start(
        preview: preview,
        syncKey: 'test-sync-secret',
        strategy: SyncConnectionStrategy.replaceServer,
      ),
      throwsA(isA<ApiFailure>()),
    );
    fixture.storage.failSecretDeletion = true;
    await fixture.coordinator.cancel();
    expect(await fixture.store.read('pending'), isNull);
    expect(fixture.coordinator.state.maintenance, isFalse);
    expect(fixture.source.writesFrozen, isFalse);
    await fixture.addTodo('after-secret-delete-failed');
    expect((await fixture.source.exportSnapshot()).totalCount, 2);
  });

  test('清理仅删除已登记旧库及快照，保留活动库、候选库和共享图片', () async {
    // 与生产一致的单次迁移工作目录。
    final Directory work = Directory(
      '${fixture.coordinator.directory.path}/backup-test',
    );
    await work.create();
    // 已关闭的旧库和 SQLite 辅助文件。
    final File old = File('${fixture.directory.path}/old.sqlite');
    for (final String suffix in <String>['', '-wal', '-shm']) {
      await File('${old.path}$suffix').writeAsString('old database');
    }
    // 该迁移独占的业务快照。
    final File snapshot = File('${work.path}/snapshot.json');
    await snapshot.writeAsString('{}');
    // 工作目录内还可能存在候选数据库，清理不能递归删除整个目录。
    final File candidate = File('${work.path}/candidate.sqlite');
    await candidate.writeAsString('candidate must remain');
    // 新旧库共享的本机图片不得按旧库附件列表删除。
    final File image = File('${fixture.directory.path}/shared-image.png');
    await image.writeAsString('local image');
    await fixture.storage.write(key: 'old-session', value: 'old credential');
    await fixture.store.write('backup:backup-test', <String, dynamic>{
      'id': 'backup-test',
      'databasePath': old.path,
      'snapshotPath': snapshot.path,
      'sessionKey': 'old-session',
    });
    await fixture.coordinator.deleteBackup('backup-test');
    for (final String suffix in <String>['', '-wal', '-shm']) {
      expect(await File('${old.path}$suffix').exists(), isFalse);
    }
    expect(await snapshot.exists(), isFalse);
    expect(await candidate.readAsString(), 'candidate must remain');
    expect(await image.readAsString(), 'local image');
    expect(await File(fixture.source.databasePath).exists(), isTrue);
    expect((await fixture.source.exportSnapshot()).totalCount, 1);
    expect(await fixture.store.read('backup:backup-test'), isNull);
    expect(await fixture.storage.read(key: 'old-session'), isNull);
    expect(await fixture.storage.read(key: fixture.auth.storageKey), isNotNull);
  });

  test('拒绝活动库与越界备份路径，并在删除任何文件前校验快照路径', () async {
    // 存在于受信任应用目录内的旧备份。
    final File old = File('${fixture.directory.path}/old.sqlite');
    await old.writeAsString('must remain');
    // 快照位于应用根目录，却不属于迁移独占目录。
    final File wrongSnapshot = File('${fixture.directory.path}/snapshot.json');
    await wrongSnapshot.writeAsString('must remain');
    // 外部目录独立创建并登记清理，绝不使用真实用户文件。
    final Directory external = await Directory.systemTemp.createTemp(
      'omni_external_backup_',
    );
    addTearDown(() async {
      await external.delete(recursive: true);
    });
    // 不能由备份管理删除的外部文件。
    final File outside = File('${external.path}/outside.sqlite');
    await outside.writeAsString('outside must remain');
    for (final Map<String, dynamic> backup in <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'active',
        'databasePath': fixture.source.databasePath,
        'snapshotPath': wrongSnapshot.path,
      },
      <String, dynamic>{
        'id': 'outside',
        'databasePath': outside.path,
        'snapshotPath': wrongSnapshot.path,
      },
      <String, dynamic>{
        'id': 'wrong-snapshot',
        'databasePath': old.path,
        'snapshotPath': wrongSnapshot.path,
      },
    ]) {
      await fixture.store.write('backup:${backup['id']}', backup);
      await expectLater(
        fixture.coordinator.deleteBackup(backup['id'] as String),
        throwsA(isA<ApiFailure>()),
      );
      expect(await fixture.store.read('backup:${backup['id']}'), backup);
    }
    expect(await old.readAsString(), 'must remain');
    expect(await wrongSnapshot.readAsString(), 'must remain');
    expect(await outside.readAsString(), 'outside must remain');
    expect((await fixture.source.exportSnapshot()).totalCount, 1);
  });

  test('备份清理与恢复共享同步准入锁，未登记身份不能删除任意文件', () async {
    // 明确存在但没有登记为备份的文件。
    final File unregistered = File(
      '${fixture.directory.path}/unregistered.sqlite',
    );
    await unregistered.writeAsString('must remain');
    // 第一次清理在读取控制库之前就占用准入。
    final Future<void> deletion = fixture.coordinator.deleteBackup(
      'unregistered',
    );
    await expectLater(fixture.coordinator.resume(), throwsA(isA<ApiFailure>()));
    await expectLater(
      fixture.coordinator.deleteBackup('unregistered'),
      throwsA(isA<ApiFailure>()),
    );
    await deletion;
    expect(await unregistered.readAsString(), 'must remain');
    // 锁释放后继续允许独立清理未登记身份，保持幂等无副作用。
    await fixture.coordinator.deleteBackup('unregistered');
    await fixture.store.write('pending', <String, dynamic>{
      'id': 'pending',
      'phase': 'prepared',
    });
    await fixture.coordinator.initialize();
    await expectLater(
      fixture.coordinator.deleteBackup('unregistered'),
      throwsA(isA<ApiFailure>()),
    );
    expect(await unregistered.readAsString(), 'must remain');
  });
}
