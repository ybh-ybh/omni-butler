import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';

/// 每个测试的原子会话快照。
Map<String, String> _savedSession() => <String, String>{
  'sync.device_session': jsonEncode(<String, dynamic>{
    'baseUrl': 'https://sync.example.com/omni-butler/api/v1',
    'accessToken': 'expired-access',
    'refreshToken': 'stable-device-secret',
    'expiresAt': DateTime.now()
        .subtract(const Duration(hours: 1))
        .toIso8601String(),
    'identity': <String, String>{'sub': 'owner-id'},
  }),
};

/// 构造完全在内存中响应的 HTTP 客户端。
Dio _client(
  String baseUrl,
  Future<Map<String, dynamic>> Function(RequestOptions) respond,
) {
  // 本测试独立的 HTTP 客户端。
  final Dio dio = Dio(BaseOptions(baseUrl: baseUrl));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest:
          (RequestOptions options, RequestInterceptorHandler handler) async {
            try {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'syncSchemaVersion': 2,
                    ...await respond(options),
                  },
                ),
              );
            } on DioException catch (error) {
              handler.reject(error);
            }
          },
    ),
  );
  return dio;
}

/// 按响应状态构造 HTTP 故障。
DioException _httpError(RequestOptions options, int status) => DioException(
  requestOptions: options,
  type: DioExceptionType.badResponse,
  response: Response<dynamic>(requestOptions: options, statusCode: status),
);

/// 覆盖地址、凭证原子保存、并发刷新与故障恢复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 系统安全存储的测试替身入口。
  const FlutterSecureStorage storage = FlutterSecureStorage();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(_savedSession());
  });

  test('旧服务器缺少结构版本时拒绝预检、会话恢复和凭证且保留本地会话', () async {
    // 缓存会话在版本不兼容时不可清除。
    final String original = (await storage.read(key: 'sync.device_session'))!;
    // 确认所有现有接口都附带新的版本头。
    final List<RequestOptions> requests = <RequestOptions>[];
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            requests.add(request);
            if (request.path == '/auth/refresh') {
              return <String, dynamic>{
                'accessToken': 'refreshed',
                'refreshToken': 'stable-device-secret',
                'expiresIn': 900,
              };
            }
            return <String, dynamic>{
              'syncSchemaVersion': null,
              'protocolVersion': 1,
              'snapshotVersion': 1,
              'sub': 'owner-id',
            };
          }),
    );
    await expectLater(
      repository.previewConnection(
        apiBaseUrl: 'https://sync.example.com',
        syncKey: 'test-sync-secret-123',
      ),
      throwsA(isA<SyncSchemaMismatch>()),
    );
    await expectLater(
      repository.restoreSession(),
      throwsA(isA<SyncSchemaMismatch>()),
    );
    await expectLater(
      repository.fetchPowerSyncCredential(),
      throwsA(isA<SyncSchemaMismatch>()),
    );
    expect(await storage.read(key: 'sync.device_session'), isNotNull);
    expect(
      jsonDecode(original)['refreshToken'],
      jsonDecode(
        (await storage.read(key: 'sync.device_session'))!,
      )['refreshToken'],
    );
    expect(
      requests.every(
        (RequestOptions request) =>
            request.headers['X-Omni-Sync-Schema'] == '2',
      ),
      isTrue,
    );
    expect(
      requests.where(
        (RequestOptions request) => request.path == '/sync/operations',
      ),
      isEmpty,
    );
  });

  test('上传握手代次内复用，换会话后重新检查结构', () async {
    // 成功握手只读现有会话接口。
    int sessions = 0;
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            if (request.path == '/auth/refresh') {
              return <String, dynamic>{
                'accessToken': 'refreshed',
                'refreshToken': 'stable-device-secret',
                'expiresIn': 900,
              };
            }
            sessions++;
            return <String, dynamic>{'sub': 'owner-id'};
          }),
    );
    await repository.ensureSyncSchemaForGeneration(
      repository.sessionGeneration,
    );
    await repository.ensureSyncSchemaForGeneration(
      repository.sessionGeneration,
    );
    expect(sessions, 1);
    // 清除会话会使旧上传作用域失效，不能沿用已验证版本。
    final int oldGeneration = repository.sessionGeneration;
    await repository.clearSession();
    await expectLater(
      repository.ensureSyncSchemaForGeneration(oldGeneration),
      throwsA(isA<ApiFailure>()),
    );
  });

  test('候选连接与预检不改变活动会话，候选断开只删除独立键', () async {
    // 原活动会话必须完整保留。
    final String original = (await storage.read(key: 'sync.device_session'))!;
    // 记录独立候选连接发出的预期身份。
    final List<RequestOptions> requests = <RequestOptions>[];
    // 仅内存响应的活动仓储。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            requests.add(request);
            if (request.path == '/sync/connection-preview') {
              return <String, dynamic>{
                'protocolVersion': 1,
                'snapshotVersion': 2,
                'ownerId': 'owner-b',
              };
            }
            if (request.path == '/auth/connect') {
              return <String, dynamic>{
                'accessToken': 'access-b',
                'refreshToken': 'refresh-b',
                'expiresIn': 900,
              };
            }
            return <String, dynamic>{'sub': 'owner-b'};
          }),
    );
    await repository.previewConnection(
      apiBaseUrl: 'https://b.example.com',
      syncKey: 'secret',
    );
    expect(await storage.readAll(), <String, String>{
      'sync.device_session': original,
    });
    // 候选仓储拥有单独的安全存储键和会话代次。
    final AuthRepository candidate = repository.forkForSession(
      'sync.candidate.test',
    );
    await candidate.connect(
      apiBaseUrl: 'https://b.example.com',
      syncKey: 'secret',
      expectedOwnerId: 'owner-b',
    );
    expect(candidate.storageKey, 'sync.candidate.test');
    expect(repository.sessionGeneration, 0);
    expect(candidate.sessionGeneration, 1);
    expect((await candidate.loadSession())?.identity.id, 'owner-b');
    expect(
      (requests
              .firstWhere(
                (RequestOptions value) => value.path == '/auth/connect',
              )
              .data
          as Map)['expectedOwnerId'],
      'owner-b',
    );
    expect(await storage.read(key: 'sync.device_session'), original);
    await candidate.clearSession();
    expect(await storage.readAll(), <String, String>{
      'sync.device_session': original,
    });
  });

  test('连接后核对身份不一致时不保存候选会话', () async {
    // 服务端预检之后被另外一次迁移替换。
    final AuthRepository candidate = AuthRepository(
      storage,
      storageKey: 'sync.candidate.mismatch',
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            return request.path == '/auth/connect'
                ? <String, dynamic>{
                    'accessToken': 'access',
                    'refreshToken': 'refresh',
                    'expiresIn': 900,
                  }
                : <String, dynamic>{'sub': 'changed-owner'};
          }),
    );
    await expectLater(
      candidate.connect(
        apiBaseUrl: 'https://b.example.com',
        syncKey: 'secret',
        expectedOwnerId: 'preview-owner',
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(await storage.read(key: candidate.storageKey), isNull);
  });

  test('迁移请求保持原 ID、使用较长超时，预检旧协议提示升级', () async {
    // 控制是否模拟旧版后端。
    bool oldServer = false;
    // 记录迁移请求以核对完整接口契约。
    final List<RequestOptions> requests = <RequestOptions>[];
    // 独立于当前设备会话的迁移 API。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            requests.add(request);
            if (oldServer) throw _httpError(request, 404);
            return <String, dynamic>{
              'status': 'committed',
              'migrationId': 'migration-1',
              'ownerId': 'new-owner',
            };
          }),
    );
    await repository.replaceServerSnapshot(
      apiBaseUrl: 'https://b.example.com',
      syncKey: 'secret',
      migrationId: 'migration-1',
      expectedOwnerId: 'owner-b',
      operations: <Map<String, Object?>>[],
    );
    expect(requests.single.receiveTimeout, const Duration(seconds: 90));
    expect(requests.single.sendTimeout, const Duration(seconds: 90));
    expect((requests.single.data as Map)['migrationId'], 'migration-1');
    await repository.migrationStatus(
      apiBaseUrl: 'https://b.example.com',
      syncKey: 'secret',
      migrationId: 'migration-1',
    );
    expect((requests.last.data as Map)['migrationId'], 'migration-1');
    oldServer = true;
    await expectLater(
      repository.previewConnection(
        apiBaseUrl: 'https://b.example.com',
        syncKey: 'secret',
      ),
      throwsA(
        isA<ApiFailure>().having(
          (ApiFailure error) => error.message,
          'message',
          contains('升级'),
        ),
      ),
    );
  });

  test('旧服务器成功响应晚到时拒绝交给队列确认', () async {
    // 请求已发出的信号。
    final Completer<void> started = Completer<void>();
    // 在断开后才放行的成功响应。
    final Completer<void> release = Completer<void>();
    // 固定有效凭证，避免测试进入刷新分支。
    final Map<String, dynamic> saved =
        jsonDecode(_savedSession().values.single) as Map<String, dynamic>;
    saved['expiresAt'] = DateTime.now()
        .add(const Duration(hours: 1))
        .toIso8601String();
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'sync.device_session': jsonEncode(saved),
    });
    // 可控制请求完成时机的仓储。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            started.complete();
            await release.future;
            return <String, dynamic>{};
          }),
    );
    // 请求调用方必须收到过期会话错误，即使服务器已经成功响应。
    final Future<void> assertion = expectLater(
      repository.authorizedRequest<void>('POST', '/sync/operations'),
      throwsA(isA<ApiFailure>()),
    );
    await started.future;
    await repository.clearSession();
    release.complete();
    await assertion;
    expect(await storage.readAll(), isEmpty);
  });

  test('服务器地址在内部拼接默认路径，并按主机类型选择默认协议', () {
    // 无网络需求的地址校验仓储。
    final AuthRepository repository = AuthRepository(storage);
    expect(
      repository.normalizeBaseUrl('https://sync.example.com/'),
      'https://sync.example.com/omni-butler/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('127.0.0.1:3000'),
      'http://127.0.0.1:3000/omni-butler/api/v1',
    );
    expect(
      repository.normalizeBaseUrl(' 192.168.1.10:3000 '),
      'http://192.168.1.10:3000/omni-butler/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('http://172.16.0.5:3000/'),
      'http://172.16.0.5:3000/omni-butler/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('sync.example.com'),
      'https://sync.example.com/omni-butler/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('sync.example.com:9443'),
      'https://sync.example.com:9443/omni-butler/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('sync.example.com:80'),
      'https://sync.example.com:80/omni-butler/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('192.168.1.10:443'),
      'http://192.168.1.10:443/omni-butler/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('https://192.168.1.10:9443'),
      'https://192.168.1.10:9443/omni-butler/api/v1',
    );
    expect(
      () => repository.normalizeBaseUrl('http://sync.example.com'),
      throwsA(isA<ApiFailure>()),
    );
  });

  test('拒绝路径、查询、凭证及非法端口，避免重复前缀或错误请求地址', () {
    // 无网络需求的地址校验仓储。
    final AuthRepository repository = AuthRepository(storage);
    // 用户输入中不允许携带的附加信息。
    for (final String address in <String>[
      '',
      'https://',
      'https://sync.example.com/omni-butler/api/v1',
      '192.168.1.10:3000/custom',
      'https://sync.example.com?token=value',
      'https://sync.example.com#fragment',
      'https://user:pass@sync.example.com',
      '192.168.1.10:0',
      '192.168.1.10:65536',
      '192.168.1.10:abc',
      'ftp://sync.example.com',
    ]) {
      expect(
        () => repository.normalizeBaseUrl(address),
        throwsA(isA<ApiFailure>()),
        reason: address,
      );
    }
  });

  test('用户可见的会话地址不展示内部 API 路径', () {
    // 保留完整内部地址的设备会话。
    const SyncSession session = SyncSession(
      identity: SyncIdentity(id: 'owner-id'),
      apiBaseUrl: 'http://192.168.1.10:9000/omni-butler/api/v1',
      isOffline: false,
    );
    expect(session.serverAddress, 'http://192.168.1.10:9000');
  });

  test('并发刷新仅发一个请求且完整凭证只保存到一个键', () async {
    // 统计实际刷新调用次数。
    int refreshes = 0;
    // 控制本测试刷新响应时机。
    final Completer<void> release = Completer<void>();
    // 可观察的认证仓储。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            refreshes++;
            await release.future;
            return <String, dynamic>{
              'accessToken': 'fresh-access',
              'refreshToken': 'stable-device-secret',
              'expiresIn': 900,
            };
          }),
    );
    // 同时请求的三个调用方。
    final List<Future<String>> callers = List<Future<String>>.generate(
      3,
      (_) => repository.ensureAccessToken(),
    );
    release.complete();
    expect(await Future.wait(callers), <String>[
      'fresh-access',
      'fresh-access',
      'fresh-access',
    ]);
    expect(refreshes, 1);
    // 原子存储内容。
    final Map<String, String> saved = await storage.readAll();
    expect(saved.keys, <String>['sync.device_session']);
    // 保存后的完整会话。
    final Map<String, dynamic> session =
        jsonDecode(saved.values.single) as Map<String, dynamic>;
    expect(session['accessToken'], 'fresh-access');
    expect(session['refreshToken'], 'stable-device-secret');
    expect(session['identity'], <String, String>{'sub': 'owner-id'});
  });

  test('刷新响应丢失后仍用同一凭证重试成功', () async {
    // 模拟第一次响应在网络中丢失。
    int attempts = 0;
    // 记录两次发送的设备凭证。
    final List<Object?> credentials = <Object?>[];
    // 网络响应可控制的仓储。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) => _client(url, (
        RequestOptions request,
      ) async {
        credentials.add((request.data as Map<String, String>)['refreshToken']);
        if (++attempts == 1) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return <String, dynamic>{
          'accessToken': 'recovered-access',
          'refreshToken': 'stable-device-secret',
          'expiresIn': 900,
        };
      }),
    );
    await expectLater(
      repository.ensureAccessToken(),
      throwsA(isA<DioException>()),
    );
    expect(await repository.ensureAccessToken(), 'recovered-access');
    expect(credentials, <String>[
      'stable-device-secret',
      'stable-device-secret',
    ]);
  });

  test('服务器 500 保留会话并恢复离线身份', () async {
    // 模拟暂时不可用的服务器。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            throw _httpError(request, 500);
          }),
    );
    // 恢复应保留本地登录状态。
    final SyncSession? session = await repository.restoreSession();
    expect(session?.isOffline, true);
    expect(session?.identity.id, 'owner-id');
    expect(await storage.read(key: 'sync.device_session'), isNotNull);
  });

  test('明确的会话 401 才清理本机凭证', () async {
    // 模拟被服务端撤销的设备会话。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            throw _httpError(request, 401);
          }),
    );
    await expectLater(
      repository.ensureAccessToken(),
      throwsA(isA<ApiFailure>()),
    );
    expect(await storage.readAll(), isEmpty);
  });

  test('断开后迟到的刷新响应不会重新保存凭证', () async {
    // 刷新已到达服务端的通知。
    final Completer<void> started = Completer<void>();
    // 等待断开后才放行的刷新响应。
    final Completer<void> release = Completer<void>();
    // 带可控异步响应的认证仓储。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            started.complete();
            await release.future;
            return <String, dynamic>{
              'accessToken': 'late-access',
              'refreshToken': 'stable-device-secret',
              'expiresIn': 900,
            };
          }),
    );
    // 正在进行的刷新。
    final Future<String> pending = repository.ensureAccessToken();
    // 先订阅预期异常，避免异步未处理错误。
    final Future<void> assertion = expectLater(
      pending,
      throwsA(isA<ApiFailure>()),
    );
    await started.future;
    await repository.clearSession();
    release.complete();
    await assertion;
    expect(await storage.readAll(), isEmpty);
  });

  test('本机时钟滞后导致旧访问令牌被拒绝时先刷新，不清掉设备会话', () async {
    // 本机仍认为有效、服务端已经不接受的访问凭证。
    final Map<String, dynamic> session =
        jsonDecode(_savedSession().values.single) as Map<String, dynamic>;
    session['expiresAt'] = DateTime.now()
        .add(const Duration(hours: 1))
        .toIso8601String();
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'sync.device_session': jsonEncode(session),
    });
    // 记录设备凭证刷新次数。
    int refreshes = 0;
    // 模拟访问凭证到期但设备会话仍有效。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            if (request.path == '/auth/refresh') {
              refreshes++;
              return <String, dynamic>{
                'accessToken': 'fresh-access',
                'expiresIn': 900,
              };
            }
            if (request.headers['Authorization'] == 'Bearer expired-access') {
              throw _httpError(request, 401);
            }
            return <String, dynamic>{'sub': 'owner-id'};
          }),
    );
    expect((await repository.restoreSession())?.isOffline, false);
    expect(refreshes, 1);
    expect(await storage.read(key: 'sync.device_session'), isNotNull);
  });

  test('连接成功将服务器、身份与凭证一起原子保存', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    // 接口响应按路径返回的仓储。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            return request.path == '/auth/connect'
                ? <String, dynamic>{
                    'accessToken': 'initial-access',
                    'refreshToken': 'stable-device-secret',
                    'expiresIn': 900,
                  }
                : <String, dynamic>{'sub': 'new-owner'};
          }),
    );
    await repository.connect(
      apiBaseUrl: 'https://sync.example.com',
      syncKey: 'valid-deployment-secret',
    );
    // 原子写入的全部内容。
    final Map<String, String> saved = await storage.readAll();
    expect(saved.length, 1);
    // 完整会话 JSON。
    final Map<String, dynamic> session =
        jsonDecode(saved.values.single) as Map<String, dynamic>;
    expect(session['baseUrl'], 'https://sync.example.com/omni-butler/api/v1');
    expect(session['identity'], <String, String>{'sub': 'new-owner'});
    expect(session['refreshToken'], 'stable-device-secret');
  });

  test('连接、恢复、同步和断开请求均使用固定前缀', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    // 记录真实 Dio 拼接后的请求地址。
    final List<String> urls = <String>[];
    // 用真实地址拼接流程和内存响应执行完整会话。
    final AuthRepository repository = AuthRepository(
      storage,
      clientFactory: (String url) =>
          _client(url, (RequestOptions request) async {
            urls.add(request.uri.toString());
            if (request.path == '/auth/connect' ||
                request.path == '/auth/refresh') {
              return <String, dynamic>{
                'accessToken': 'access',
                'refreshToken': 'stable-device-secret',
                'expiresIn': 900,
              };
            }
            if (request.path == '/auth/powersync-token') {
              return <String, dynamic>{
                'token': 'sync-token',
                'endpoint': 'http://192.168.1.10:8080',
                'expiresIn': 900,
                'userId': 'owner-id',
              };
            }
            return <String, dynamic>{'sub': 'owner-id'};
          }),
    );
    await repository.connect(
      apiBaseUrl: '192.168.1.10:9000',
      syncKey: 'valid-deployment-secret',
    );
    // 模拟应用重启后访问令牌到期，验证刷新仍使用同一路径。
    final Map<String, dynamic> saved = jsonDecode(
      (await storage.read(key: 'sync.device_session'))!,
    ) as Map<String, dynamic>;
    saved['expiresAt'] = DateTime.now()
        .subtract(const Duration(hours: 1))
        .toIso8601String();
    await storage.write(key: 'sync.device_session', value: jsonEncode(saved));
    expect((await repository.restoreSession())?.isOffline, false);
    await repository.fetchPowerSyncCredential();
    await repository.authorizedRequest<void>(
      'POST',
      '/sync/operations',
      data: <String, Object>{'operations': <Object>[]},
    );
    await repository.disconnect();
    expect(urls, <String>[
      'http://192.168.1.10:9000/omni-butler/api/v1/auth/connect',
      'http://192.168.1.10:9000/omni-butler/api/v1/auth/session',
      'http://192.168.1.10:9000/omni-butler/api/v1/auth/refresh',
      'http://192.168.1.10:9000/omni-butler/api/v1/auth/session',
      'http://192.168.1.10:9000/omni-butler/api/v1/auth/powersync-token',
      'http://192.168.1.10:9000/omni-butler/api/v1/sync/operations',
      'http://192.168.1.10:9000/omni-butler/api/v1/auth/disconnect',
    ]);
  });
}
