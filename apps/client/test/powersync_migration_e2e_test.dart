import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/sync/omni_sync_runtime.dart';
import 'package:omni_butler/core/sync/sync_client_identity.dart';
import 'package:omni_butler/core/sync/sync_connection_coordinator.dart';
import 'package:omni_butler/core/sync/sync_connection_store.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

/// 必须明确开启，默认不连接任何服务器。
const bool _enabled = bool.fromEnvironment('OMNI_MIGRATION_E2E');

/// 专属隔离 Compose 服务地址。
const String _address = String.fromEnvironment(
  'OMNI_MIGRATION_SERVER_URL',
  defaultValue: 'http://127.0.0.1:35430',
);

/// 只用于隔离环境的公开测试密钥。
const String _secret = String.fromEnvironment(
  'OMNI_MIGRATION_SECRET',
  defaultValue: 'migration-e2e-only-secret-2026',
);

/// 测试数据时间。
final DateTime _now = DateTime.utc(2026, 9, 27);

/// 保留插件测试通道，同时允许端到端测试真正发起 HTTP。
class _NetworkTestBinding extends AutomatedTestWidgetsFlutterBinding {
  /// 关闭仅用于组件单测的 HTTP 400 替身。
  @override
  bool get overrideHttpClient => false;
}

/// 真实 HTTP 传输上的一次性响应丢失注入与请求计数。
class _Transport {
  /// 将特定候选设备的下行路由到测试代理，延迟真实同步响应。
  String? powerSyncEndpoint;

  /// 下一次迁移已被服务器提交后丢弃成功响应。
  bool loseMigrationResponse = false;

  /// 已提交的迁移请求身份，验证恢复不重新清库。
  final List<String> migrationIds = <String>[];

  /// 该设备的普通上传次数。
  int uploads = 0;

  /// 创建真正访问隔离 API 的 Dio，仅故障点由测试注入。
  Dio client(String baseUrl) {
    // 当前独立 HTTP 客户端。
    final Dio dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 90),
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
          if (options.path == '/sync/operations') uploads += 1;
          if (options.path == '/sync/migrations') {
            migrationIds.add((options.data as Map)['migrationId'] as String);
          }
          handler.next(options);
        },
        onResponse:
            (Response<dynamic> response, ResponseInterceptorHandler handler) {
              if (response.requestOptions.path == '/auth/powersync-token' &&
                  powerSyncEndpoint != null) {
                (response.data as Map<String, dynamic>)['endpoint'] =
                    powerSyncEndpoint;
              }
              if (response.requestOptions.path == '/sync/migrations' &&
                  loseMigrationResponse) {
                loseMigrationResponse = false;
                handler.reject(
                  DioException(
                    requestOptions: response.requestOptions,
                    type: DioExceptionType.connectionError,
                    error: 'E2E：服务端已提交但响应丢失',
                  ),
                );
                return;
              }
              handler.next(response);
            },
      ),
    );
    return dio;
  }
}

/// 转发真实 PowerSync HTTP，但在允许前不交付同步流字节。
class _DownlinkGate {
  /// 当前只监听回环地址的代理。
  final HttpServer server;

  /// 转发客户端，关闭时取消长连接。
  final HttpClient client = HttpClient();

  /// 已观察到真实下行流请求。
  final Completer<void> streamRequested = Completer<void>();

  /// 测试断言完成之后允许同步字节流入候选库。
  final Completer<void> released = Completer<void>();

  /// 安装代理监听，不替换服务端或 SDK 的检查点实现。
  _DownlinkGate(this.server) {
    client.autoUncompress = false;
    server.listen(_forward);
  }

  /// 暴露供候选连接使用的本机临时地址。
  String get endpoint => 'http://127.0.0.1:${server.port}';

  /// 将 HTTP 请求透传给专属隔离 PowerSync，只延迟流内容。
  Future<void> _forward(HttpRequest request) async {
    try {
      // 固定隔离 PowerSync 地址，不允许代理访问其他服务。
      final Uri upstream = Uri.parse('http://127.0.0.1:35480')
          .resolve(request.uri.toString());
      // 真实 PowerSync 请求。
      final HttpClientRequest outgoing = await client.openUrl(
        request.method,
        upstream,
      );
      request.headers.forEach((String name, List<String> values) {
        if (!<String>[
          'host',
          'content-length',
          'transfer-encoding',
        ].contains(name)) {
          outgoing.headers.set(name, values);
        }
      });
      await outgoing.addStream(request);
      // 真实服务响应，检查点端点直接透传。
      final HttpClientResponse response = await outgoing.close();
      request.response.statusCode = response.statusCode;
      request.response.bufferOutput = false;
      response.headers.forEach((String name, List<String> values) {
        if (!<String>['content-length', 'transfer-encoding'].contains(name)) {
          request.response.headers.set(name, values);
        }
      });
      if (request.uri.path.contains('stream')) {
        if (!streamRequested.isCompleted) streamRequested.complete();
        await request.response.flush();
        await released.future;
      }
      await request.response.addStream(response);
      await request.response.close();
    } on Object {
      // SDK 主动断开长连接时，代理也结束对应响应。
      await request.response.close();
    }
  }

  /// 释放暂缓响应并关闭本测试的代理连接。
  Future<void> close() async {
    if (!released.isCompleted) released.complete();
    client.close(force: true);
    await server.close(force: true);
  }
}

/// 创建完整生产协调器，每设备独立控制库、业务库及凭证键。
Future<SyncConnectionCoordinator> _device(
  Directory root,
  String name,
  _Transport transport,
) async {
  // 当前设备独占目录。
  final Directory directory = Directory(path.join(root.path, name));
  await directory.create();
  // 使用平台测试存储替身；HTTP、API 鉴权、SQLite 和同步均为真实实现。
  const FlutterSecureStorage storage = FlutterSecureStorage();
  // 当前设备独立认证仓储。
  final AuthRepository auth = AuthRepository(
    storage,
    storageKey: 'e2e.$name',
    clientFactory: transport.client,
  );
  // 初始本地运行时。
  final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
    auth,
    path.join(directory.path, 'original.sqlite'),
  );
  // 独立持久迁移控制库。
  final SyncConnectionStore store = SyncConnectionStore(
    File(path.join(directory.path, 'control.sqlite')),
  );
  // 生产迁移协调器。
  final SyncConnectionCoordinator coordinator = SyncConnectionCoordinator(
    store: store,
    secureStorage: storage,
    directory: Directory(path.join(directory.path, 'migration')),
    runtime: runtime,
    auth: auth,
    freeBytes: (String _) async => 1024 * 1024 * 1024,
  );
  await coordinator.initialize();
  return coordinator;
}

/// 模拟进程关闭后仅凭持久控制库与安全存储重新打开活动数据集。
Future<SyncConnectionCoordinator> _coldStart(
  Directory root,
  String name,
  _Transport transport,
) async {
  // 冷启动首先读取独立控制库，不能默认打开已归档的 original.sqlite。
  final Directory directory = Directory(path.join(root.path, name));
  final SyncConnectionStore store = SyncConnectionStore(
    File(path.join(directory.path, 'control.sqlite')),
  );
  // 同一 SQLite 提交持久化的活动数据库和会话键。
  final Map<String, dynamic> active = (await store.read('active'))!;
  // 只读取活动索引指向的安全存储凭证。
  const FlutterSecureStorage storage = FlutterSecureStorage();
  final AuthRepository auth = AuthRepository(
    storage,
    storageKey: active['sessionKey'] as String,
    clientFactory: transport.client,
  );
  // 打开已经完成迁移的活动数据库，复用其正确归属和检查点。
  final OmniSyncRuntime runtime = await OmniSyncRuntime.openAtPath(
    auth,
    active['databasePath'] as String,
  );
  // 初始化维护状态先于恢复任何网络连接。
  final SyncConnectionCoordinator coordinator = SyncConnectionCoordinator(
    store: store,
    secureStorage: storage,
    directory: Directory(path.join(directory.path, 'migration')),
    runtime: runtime,
    auth: auth,
    freeBytes: (String _) async => 1024 * 1024 * 1024,
  );
  await coordinator.initialize();
  return coordinator;
}

/// 新增本地业务行，通过生产触发器进入待上传队列。
Future<void> _quote(OmniSyncRuntime runtime, String id, String content) async {
  await runtime.database
      .into(runtime.database.quotes)
      .insert(
        QuotesCompanion.insert(
          id: id,
          content: content,
          createdAt: _now,
          updatedAt: _now,
        ),
      );
}

/// 真实页面读取空服务器候选时，不得触发默认名言、日签或分类播种。
Future<void> _expectEmptyAfterBusinessReads(OmniSyncRuntime runtime) async {
  expect(await runtime.database.quoteForDay(_now), isNull);
  // 分类页面的生产监听入口会经过默认数据初始化逻辑。
  final TaxonomyRepository taxonomy = TaxonomyRepository(runtime.database);
  for (final TaxonomyModule module in TaxonomyModule.values) {
    for (final TaxonomyKind kind in TaxonomyKind.values) {
      expect(
        await taxonomy
            .watch(module: module, kind: kind)
            .first
            .timeout(const Duration(seconds: 10)),
        isEmpty,
      );
    }
  }
  // 覆盖全部同步表，不能只断言页面当前展示的名言和分类。
  final Map<String, int> counts = (await runtime.exportSnapshot()).counts;
  expect(counts.length, 11);
  expect(counts.values, everyElement(0));
  expect((await runtime.powerSync.getUploadQueueStats()).count, 0);
}

/// 创建本机图片与关联，用于验证相同业务身份恢复及孤立图片仅留备份。
Future<String> _image(
  OmniSyncRuntime runtime,
  Directory root,
  String businessId,
) async {
  // 本机附件身份与文件位置。
  final String id = const Uuid().v4();
  final File image = File(path.join(root.path, '$id.png'));
  await image.writeAsBytes(<int>[137, 80, 78, 71, 13, 10, 26, 10], flush: true);
  await runtime.database
      .into(runtime.database.attachments)
      .insert(
        AttachmentsCompanion.insert(
          id: id,
          businessType: 'inventoryImage',
          businessId: businessId,
          localPath: Value<String?>(image.path),
          createdAt: _now,
          updatedAt: _now,
        ),
      );
  await (runtime.database.update(
    runtime.database.inventoryItems,
  )..where((InventoryItems row) => row.id.equals(businessId))).write(
    InventoryItemsCompanion(
      imageAttachmentId: Value<String?>(id),
      imageLocalPath: Value<String?>(image.path),
    ),
  );
  return id;
}

/// 创建隔离测试 API 客户端。
Dio _api() => Dio(
  BaseOptions(
    baseUrl: '$_address/omni-butler/api/v1',
    receiveTimeout: const Duration(seconds: 90),
  ),
);

/// 以空快照开启目标新一代 owner，测试只允许专属本地端口。
Future<String> _reset(Dio api) async {
  // 已授权的当前目标身份。
  final Response<Map<String, dynamic>> preview = await api.post(
    '/sync/connection-preview',
    data: <String, Object?>{'syncKey': _secret},
  );
  // 独立迁移回执保留每次测试重建结果。
  final Response<Map<String, dynamic>> response = await api.post(
    '/sync/migrations',
    data: <String, Object?>{
      'syncKey': _secret,
      'migrationId': const Uuid().v4(),
      'expectedOwnerId': preview.data!['ownerId'],
      'snapshotVersion': 1,
      'operations': <Object>[],
    },
  );
  return response.data!['ownerId'] as String;
}

/// 通过真实登录取得用于边界断言的管理员设备会话。
Future<String> _token(Dio api) async {
  // 真实设备访问令牌。
  final Response<Map<String, dynamic>> response = await api.post(
    '/auth/connect',
    data: <String, Object?>{'syncKey': _secret},
  );
  return response.data!['accessToken'] as String;
}

/// 向真实服务器写入一个完整普通事务，不参与客户端候选库上传。
Future<void> _upload(
  Dio api,
  String token,
  List<Map<String, Object?>> operations,
) async {
  await api.post(
    '/sync/operations',
    data: <String, Object?>{
      'clientId': const Uuid().v4(),
      'transactionId': const Uuid().v4(),
      'operations': operations,
    },
    options: Options(
      headers: <String, String>{'Authorization': 'Bearer $token'},
    ),
  );
}

/// 构造服务端普通 PUT，用于服务器独有行及墓碑准备。
Map<String, Object?> _putQuote(String id, String text) => <String, Object?>{
  'op': 'PUT',
  'table': 'quotes',
  'id': id,
  'data': <String, Object?>{
    'content': text,
    'created_at': _now.toIso8601String(),
    'updated_at': _now.toIso8601String(),
  },
};

/// 运行真实 API、PowerSync 及三个独立 SQLite 客户端的迁移回归。
void main() {
  _NetworkTestBinding();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  test(
    '三客户端首次合并、保留本机覆盖服务器、采用服务器及丢响应恢复',
    () async {
      // 禁止误将清空测试指向日常服务，即使环境配置错误也立即失败。
      final Uri target = Uri.parse(_address);
      expect(target.host, '127.0.0.1');
      expect(target.port, 35430);
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      // 测试备份保留目录，输出后可检查旧 SQLite 与本机图片。
      final Directory root = await Directory.systemTemp.createTemp(
        'omni-migration-e2e-',
      );
      // 真实目标服务器。
      final Dio api = _api();
      // 所有测试设备在 finally 中统一关闭，但保留文件作为验证证据。
      final List<SyncConnectionCoordinator> devices =
          <SyncConnectionCoordinator>[];
      // 仅在第三设备下载阶段延迟真实下行。
      _DownlinkGate? downlink;
      try {
        await _reset(api);
        // 三台设备均使用独立上传身份和安全存储键。
        final _Transport transportA = _Transport();
        final _Transport transportB = _Transport();
        final _Transport transportC = _Transport();
        final SyncConnectionCoordinator a = await _device(
          root,
          'source-a',
          transportA,
        );
        devices.add(a);
        final SyncConnectionCoordinator b = await _device(
          root,
          'server-b',
          transportB,
        );
        devices.add(b);
        final SyncConnectionCoordinator c = await _device(
          root,
          'old-device-c',
          transportC,
        );
        devices.add(c);
        // 本次运行独立的业务记录身份。
        final String common = const Uuid().v4();
        final String remoteOnly = const Uuid().v4();
        final String localOnly = const Uuid().v4();
        final String inventoryId = const Uuid().v4();
        // 服务器 B 先拥有同身份不同值及一条服务器独有记录。
        await _quote(b.runtime, common, 'server-wins');
        await _quote(b.runtime, remoteOnly, 'remote-only');
        final SyncSession sessionB = await b.auth.connect(
          apiBaseUrl: _address,
          syncKey: _secret,
        );
        await b.runtime.connect(sessionB.identity.id, session: sessionB);
        await b.runtime.catchUp();
        // 首次本地合并保留不同身份行，同身份沿用服务端首次 PUT。
        await _quote(a.runtime, common, 'local-loses');
        await _quote(a.runtime, localOnly, 'local-only');
        await a.runtime.database
            .into(a.runtime.database.inventoryItems)
            .insert(
              InventoryItemsCompanion.insert(
                id: inventoryId,
                name: '同身份图片物品',
                createdAt: _now,
                updatedAt: _now,
              ),
            );
        final String attachmentA = await _image(a.runtime, root, inventoryId);
        final String firstClientId = await ensureSyncClientId(
          a.runtime.powerSync,
        );
        final SyncConnectionPreview first = await a.preview(
          serverAddress: _address,
          syncKey: _secret,
        );
        expect(first.localOwnerId, isNull);
        await a.start(
          preview: first,
          syncKey: _secret,
          strategy: SyncConnectionStrategy.mergeInitial,
        );
        expect(
          await ensureSyncClientId(a.runtime.powerSync),
          isNot(firstClientId),
        );
        expect(
          (await a.runtime.powerSync.get(
            'SELECT content FROM quotes WHERE id = ?',
            <Object?>[common],
          ))['content'],
          'server-wins',
        );
        expect(
          (await a.runtime.powerSync.getAll('SELECT id FROM quotes'))
              .map((Map<String, Object?> row) => row['id']),
          containsAll(<String>[common, remoteOnly, localOnly]),
        );
        expect((await a.runtime.powerSync.getUploadQueueStats()).count, 0);
        // 第三台旧设备下载旧 owner，随后离线形成绝不能上传的新队列。
        final SyncSession sessionC = await c.auth.connect(
          apiBaseUrl: _address,
          syncKey: _secret,
        );
        await c.runtime.connect(sessionC.identity.id, session: sessionC);
        await c.runtime.catchUp();
        await c.disconnect();
        final String staleId = const Uuid().v4();
        await _quote(c.runtime, staleId, 'must-never-upload');
        final String attachmentC = await _image(c.runtime, root, inventoryId);
        final String orphanInventoryId = const Uuid().v4();
        await c.runtime.database
            .into(c.runtime.database.inventoryItems)
            .insert(
              InventoryItemsCompanion.insert(
                id: orphanInventoryId,
                name: '仅旧设备物品',
                createdAt: _now,
                updatedAt: _now,
              ),
            );
        final String orphanAttachment = await _image(
          c.runtime,
          root,
          orphanInventoryId,
        );
        await c.runtime.database
            .into(c.runtime.database.bannerSettings)
            .insert(
              BannerSettingsCompanion.insert(
                id: const Uuid().v4(),
                key: 'e2e-local-setting',
                overlayStrength: const Value<double>(0.72),
                updatedAt: _now,
              ),
            );
        final String oldCPath = c.runtime.databasePath;
        final String oldCClient = await ensureSyncClientId(c.runtime.powerSync);
        // 停止所有旧后台连接；迁移来源 A 自此只使用本机数据。
        await a.disconnect();
        await b.runtime.disconnect();
        await (a.runtime.database.update(
          a.runtime.database.quotes,
        )..where((Quotes row) => row.id.equals(common))).write(
          const QuotesCompanion(content: Value<String>('authoritative-local')),
        );
        final String oldAPath = a.runtime.databasePath;
        final String oldOwner = (await a.runtime.ownerId)!;
        // 重建 B 模拟不同服务器；B 有独有数据及恰好阻止 common PUT 的墓碑。
        final String intermediateOwner = await _reset(api);
        expect(intermediateOwner, isNot(oldOwner));
        final String oldBToken = await _token(api);
        final String unwanted = const Uuid().v4();
        await _upload(api, oldBToken, <Map<String, Object?>>[
          _putQuote(unwanted, 'must-be-cleared'),
          <String, Object?>{'op': 'DELETE', 'table': 'quotes', 'id': common},
        ]);
        // 只在真实服务器确认提交后丢失响应，本机必须保持维护锁和原日志。
        transportA.loseMigrationResponse = true;
        final SyncConnectionPreview replacement = await a.preview(
          serverAddress: _address,
          syncKey: _secret,
        );
        await expectLater(
          a.start(
            preview: replacement,
            syncKey: _secret,
            strategy: SyncConnectionStrategy.replaceServer,
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(a.state.maintenance, isTrue);
        expect(a.runtime.databasePath, oldAPath);
        expect(await File(oldAPath).exists(), isTrue);
        final Map<String, dynamic> pending = (await a.store.read('pending'))!;
        expect(pending['phase'], 'submitting');
        final String migrationId = pending['id'] as String;
        // 原 B 会话已经被替换撤销。
        await expectLater(
          api.get(
            '/auth/session',
            options: Options(
              headers: <String, String>{'Authorization': 'Bearer $oldBToken'},
            ),
          ),
          throwsA(
            isA<DioException>().having(
              (DioException error) => error.response?.statusCode,
              'status',
              401,
            ),
          ),
        );
        // 服务器提交后再写一行，恢复时不得再次覆盖掉它。
        final String marker = const Uuid().v4();
        await _upload(api, await _token(api), <Map<String, Object?>>[
          _putQuote(marker, 'after-commit-survives-resume'),
        ]);
        await a.resume();
        expect(transportA.migrationIds, <String>[migrationId]);
        expect(a.state.maintenance, isFalse);
        expect(await a.store.read('pending'), isNull);
        expect(
          (await a.runtime.powerSync.get(
            'SELECT content FROM quotes WHERE id = ?',
            <Object?>[common],
          ))['content'],
          'authoritative-local',
        );
        expect(
          await a.runtime.powerSync.getOptional(
            'SELECT id FROM quotes WHERE id = ?',
            <Object?>[unwanted],
          ),
          isNull,
        );
        expect(
          await a.runtime.powerSync.getOptional(
            'SELECT id FROM quotes WHERE id = ?',
            <Object?>[marker],
          ),
          isNotNull,
        );
        expect(
          await a.runtime.powerSync.getOptional(
            'SELECT id FROM attachments WHERE id = ?',
            <Object?>[attachmentA],
          ),
          isNotNull,
        );
        expect((await a.runtime.powerSync.getUploadQueueStats()).count, 0);
        // 旧设备选择 B 为准：不发送旧队列，只恢复同业务 ID 图片和本机设置。
        final int uploadsBeforeAdoption = transportC.uploads;
        final SyncConnectionPreview adoption = await c.preview(
          serverAddress: _address,
          syncKey: _secret,
        );
        downlink = _DownlinkGate(
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        );
        transportC.powerSyncEndpoint = downlink.endpoint;
        // 在真实同步流被阻断期间观察是否过早激活本地索引。
        bool adoptionCompleted = false;
        final Future<void> adoptionTask = c
            .start(
              preview: adoption,
              syncKey: _secret,
              strategy: SyncConnectionStrategy.replaceLocal,
            )
            .then((_) {
              adoptionCompleted = true;
            });
        await downlink.streamRequested.future.timeout(
          const Duration(seconds: 20),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(adoptionCompleted, isFalse);
        expect(c.runtime.databasePath, oldCPath);
        expect(c.state.maintenance, isTrue);
        expect(await c.store.read('active'), isNull);
        downlink.released.complete();
        await adoptionTask;
        expect(transportC.uploads, uploadsBeforeAdoption);
        expect(
          await ensureSyncClientId(c.runtime.powerSync),
          isNot(oldCClient),
        );
        expect(
          await c.runtime.powerSync.getOptional(
            'SELECT id FROM quotes WHERE id = ?',
            <Object?>[staleId],
          ),
          isNull,
        );
        expect(
          await c.runtime.powerSync.getOptional(
            'SELECT id FROM inventory_items WHERE id = ?',
            <Object?>[orphanInventoryId],
          ),
          isNull,
        );
        expect(
          await c.runtime.powerSync.getOptional(
            'SELECT id FROM attachments WHERE id = ?',
            <Object?>[orphanAttachment],
          ),
          isNull,
        );
        expect(
          (await c.runtime.powerSync.get(
            'SELECT image_attachment_id FROM inventory_items WHERE id = ?',
            <Object?>[inventoryId],
          ))['image_attachment_id'],
          attachmentC,
        );
        expect(
          (await c.runtime.powerSync.get(
            'SELECT image_local_path FROM inventory_items WHERE id = ?',
            <Object?>[inventoryId],
          ))['image_local_path'],
          path.join(root.path, '$attachmentC.png'),
        );
        expect(
          (await a.runtime.powerSync.get(
            'SELECT image_attachment_id, image_local_path FROM inventory_items WHERE id = ?',
            <Object?>[inventoryId],
          )),
          <String, Object?>{
            'image_attachment_id': attachmentA,
            'image_local_path': path.join(root.path, '$attachmentA.png'),
          },
        );
        expect(
          (await c.runtime.powerSync.get(
            'SELECT overlay_strength FROM banner_settings WHERE key = ?',
            <Object?>['e2e-local-setting'],
          ))['overlay_strength'],
          0.72,
        );
        expect((await c.runtime.powerSync.getUploadQueueStats()).count, 0);
        expect(await File(oldCPath).exists(), isTrue);
        expect(
          await File(path.join(root.path, '$orphanAttachment.png')).exists(),
          isTrue,
        );
        // 核对两台新 owner 设备业务结果完全一致，客户端图片列不参与比较。
        expect(
          await c.runtime.powerSync.getAll(
            'SELECT id, content FROM quotes ORDER BY id',
          ),
          await a.runtime.powerSync.getAll(
            'SELECT id, content FROM quotes ORDER BY id',
          ),
        );
        expect(await c.runtime.ownerId, await a.runtime.ownerId);
        // 彻底关闭旧协调器，模拟再次启动时只能依赖持久索引和凭证。
        final String activeCPath = c.runtime.databasePath;
        final String activeCClientId = await ensureSyncClientId(
          c.runtime.powerSync,
        );
        await c.close();
        devices.remove(c);
        final SyncConnectionCoordinator restarted = await _coldStart(
          root,
          'old-device-c',
          transportC,
        );
        devices.add(restarted);
        expect(restarted.state.maintenance, isFalse);
        expect(restarted.runtime.databasePath, activeCPath);
        expect(restarted.runtime.databasePath, isNot(oldCPath));
        expect(
          await ensureSyncClientId(restarted.runtime.powerSync),
          activeCClientId,
        );
        final SyncSession? restoredSession = await restarted.auth
            .restoreSession();
        expect(restoredSession, isNotNull);
        expect(restoredSession!.isOffline, isFalse);
        expect(restoredSession.identity.id, await a.runtime.ownerId);
        await restarted.runtime.connect(
          restoredSession.identity.id,
          session: restoredSession,
        );
        await restarted.runtime.catchUp();
        expect(transportC.uploads, uploadsBeforeAdoption);
        expect(
          await restarted.runtime.powerSync.getAll(
            'SELECT id, content FROM quotes ORDER BY id',
          ),
          await a.runtime.powerSync.getAll(
            'SELECT id, content FROM quotes ORDER BY id',
          ),
        );
        // 尾部独立采用空服务器场景：先断开旧代全部运行时，防止后台改变基线。
        await a.runtime.disconnect();
        await b.runtime.disconnect();
        await restarted.runtime.disconnect();
        // 清空仅本测试专属目标，新的 owner 模拟另一个空数据源。
        final String emptyOwner = await _reset(api);
        // 采用空 B 仍不得发送任何旧库队列。
        final int uploadsBeforeEmpty = transportC.uploads;
        final SyncConnectionPreview emptyPreview = await restarted.preview(
          serverAddress: _address,
          syncKey: _secret,
        );
        expect(emptyPreview.remoteCounts.values, everyElement(0));
        await restarted.start(
          preview: emptyPreview,
          syncKey: _secret,
          strategy: SyncConnectionStrategy.replaceLocal,
        );
        expect(await restarted.runtime.ownerId, emptyOwner);
        // 关闭网络再触发页面读取，确保意外播种不能被快速上传掩盖为队列零。
        await restarted.runtime.disconnect();
        await _expectEmptyAfterBusinessReads(restarted.runtime);
        // 冷启动必须保留“采用服务器数据”的语义，不因库为空重新播种。
        final String emptyPath = restarted.runtime.databasePath;
        await restarted.close();
        devices.remove(restarted);
        final SyncConnectionCoordinator emptyRestarted = await _coldStart(
          root,
          'old-device-c',
          transportC,
        );
        devices.add(emptyRestarted);
        expect(emptyRestarted.runtime.databasePath, emptyPath);
        expect(await emptyRestarted.runtime.ownerId, emptyOwner);
        await _expectEmptyAfterBusinessReads(emptyRestarted.runtime);
        // 恢复真实网络后再次经过检查点，核对空状态没有上传为默认业务数据。
        final SyncSession? emptySession = await emptyRestarted.auth
            .restoreSession();
        expect(emptySession, isNotNull);
        expect(emptySession!.identity.id, emptyOwner);
        await emptyRestarted.runtime.connect(emptyOwner, session: emptySession);
        await emptyRestarted.runtime.catchUp();
        expect(transportC.uploads, uploadsBeforeEmpty);
        final Map<String, dynamic> emptyRemote = await emptyRestarted.auth
            .previewConnection(apiBaseUrl: _address, syncKey: _secret);
        expect((emptyRemote['counts'] as Map).length, 11);
        expect((emptyRemote['counts'] as Map).values, everyElement(0));
        expect(
          (await emptyRestarted.runtime.exportSnapshot()).counts.values,
          everyElement(0),
        );
        expect(
          (await emptyRestarted.runtime.powerSync.getUploadQueueStats()).count,
          0,
        );
        // 将验证范围与备份位置写入测试专属证据文件，便于主任务检查。
        await File(path.join(root.path, 'result.json')).writeAsString(
          jsonEncode(<String, Object?>{
            'status': 'passed',
            'migrationId': migrationId,
            'ownerId': await a.runtime.ownerId,
            'sourceBackup': oldAPath,
            'adoptBackup': oldCPath,
            'checkpointMode': 'requests',
            'delayedDownlinkKeptOriginalActive': true,
            'coldStartPreservedActiveCatalogAndSession': true,
            'emptyAdoptionOwnerId': emptyOwner,
            'emptyAdoptionAndColdStartBusinessReadsDidNotSeed': true,
            'queueA': (await a.runtime.powerSync.getUploadQueueStats()).count,
            'queueC':
                (await emptyRestarted.runtime.powerSync.getUploadQueueStats())
                    .count,
          }),
          flush: true,
        );
        // ignore: avoid_print
        print('迁移 E2E 证据：${root.path}');
      } finally {
        for (final SyncConnectionCoordinator device in devices.reversed) {
          await device.close();
        }
        await downlink?.close();
        api.close();
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
