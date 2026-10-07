import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omni_butler/core/auth/auth_models.dart';

/// Omni Butler API 的固定公开路径，用于区分同域名下的其他服务。
const String fixedApiPath = '/omni-butler/api/v1';

/// 当前客户端支持的业务同步结构版本。
const int syncSchemaVersion = 2;

/// 完整设备会话使用同一个安全存储键，避免写入中断造成凭证混搭。
const String _sessionKey = 'sync.device_session';

/// 一次原子保存的设备会话数据。
class _StoredSession {
  /// API 根地址。
  final String baseUrl;

  /// 短期访问凭证。
  final String accessToken;

  /// 固定有效期内保持不变的设备凭证。
  final String refreshToken;

  /// 访问凭证过期时间。
  final DateTime expiresAt;

  /// 所有者身份。
  final SyncIdentity identity;

  /// 创建完整会话快照。
  const _StoredSession({
    required this.baseUrl,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.identity,
  });

  /// 从一条安全存储记录恢复会话。
  factory _StoredSession.fromJson(Map<String, dynamic> value) {
    return _StoredSession(
      baseUrl: value['baseUrl'] as String,
      accessToken: value['accessToken'] as String,
      refreshToken: value['refreshToken'] as String,
      expiresAt: DateTime.parse(value['expiresAt'] as String),
      identity: SyncIdentity.fromJson(
        Map<String, dynamic>.from(value['identity'] as Map),
      ),
    );
  }

  /// 编码完整会话。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'baseUrl': baseUrl,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toIso8601String(),
    'identity': <String, String>{'sub': identity.id},
  };
}

/// 自托管同步服务连接与设备会话仓储。
class AuthRepository {
  /// 系统安全存储。
  final FlutterSecureStorage _storage;

  /// 当前仓储独占的安全存储键，候选会话不覆盖活动会话。
  final String storageKey;

  /// 可选 HTTP 客户端工厂，供测试使用内存传输。
  final Dio Function(String)? clientFactory;

  /// 当前正在进行的刷新，共享给所有并发请求。
  Future<String>? _pendingRefresh;

  /// 本机会话代次，防止断开后旧请求重新写回凭证。
  int _generation = 0;

  /// 当前会话已确认的同步结构代次，切换会话后自然失效。
  int? _verifiedSchemaGeneration;

  /// 安全存储修改顺序，确保断开最终覆盖已经开始的写入。
  Future<void> _storageWrites = Future<void>.value();

  /// 创建同步服务会话仓储。
  AuthRepository(
    this._storage, {
    this.clientFactory,
    this.storageKey = _sessionKey,
  });

  /// 暴露当前代次，供同步连接器拒绝旧请求确认队列。
  int get sessionGeneration => _generation;

  /// 上传开始前也进行握手，避免 SDK 独立调用上传时绕过凭证校验。
  Future<void> ensureSyncSchemaForGeneration(int generation) async {
    if (generation != _generation) throw const ApiFailure('同步会话已变更，请重试');
    if (_verifiedSchemaGeneration == generation) return;
    // 使用现有只读会话接口，无需新增公开路径。
    final Response<Map<String, dynamic>> response =
        await authorizedRequestForGeneration<Map<String, dynamic>>(
          generation,
          'GET',
          '/auth/session',
        );
    _verifySyncSchema(response.data ?? <String, dynamic>{});
    if (generation != _generation) throw const ApiFailure('同步会话已变更，请重试');
    _verifiedSchemaGeneration = generation;
  }

  /// 缺失版本也属于不兼容，不能向旧服务器提交新业务数据。
  void _verifySyncSchema(Map<String, dynamic> response) {
    if (response['syncSchemaVersion'] != syncSchemaVersion) {
      throw const SyncSchemaMismatch();
    }
  }

  /// 同步检查代次后立即开始请求，关闭异步作用域校验与请求发起之间的切换窗口。
  Future<Response<T>> authorizedRequestForGeneration<T>(
    int generation,
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
    bool preserveTransportErrors = false,
  }) {
    if (generation != _generation) {
      throw const ApiFailure('同步会话已变更，请重新建立同步连接');
    }
    return authorizedRequest<T>(
      method,
      path,
      data: data,
      queryParameters: queryParameters,
      responseType: responseType,
      preserveTransportErrors: preserveTransportErrors,
    );
  }

  /// 在固定代次内开始凭证请求，不允许旧连接取得新设备会话的令牌。
  Future<PowerSyncCredential> fetchPowerSyncCredentialForGeneration(
    int generation,
  ) {
    if (generation != _generation) {
      throw const ApiFailure('同步会话已变更，请重新建立同步连接');
    }
    return fetchPowerSyncCredential();
  }

  /// 创建共享传输配置、独立凭证和代次的候选会话仓储。
  AuthRepository forkForSession(String key) {
    if (key.isEmpty || key == storageKey) {
      throw const ApiFailure('候选会话必须使用独立的安全存储键');
    }
    return AuthRepository(
      _storage,
      clientFactory: clientFactory,
      storageKey: key,
    );
  }

  /// 只读取本机会话身份，不发出请求或刷新凭证。
  Future<SyncSession?> loadSession() async {
    // 当前安全存储中的完整会话。
    final _StoredSession? saved = await _readSession();
    if (saved == null) return null;
    return SyncSession(
      identity: saved.identity,
      apiBaseUrl: saved.baseUrl,
      isOffline: true,
    );
  }

  /// 检查目标数据源和迁移能力，不创建或替换设备会话。
  Future<Map<String, dynamic>> previewConnection({
    required String apiBaseUrl,
    required String syncKey,
  }) async {
    // 预检响应用于后续确认和固定 owner。
    final Map<String, dynamic> result = await _migrationRequest(
      apiBaseUrl,
      '/sync/connection-preview',
      <String, Object?>{'syncKey': syncKey},
    );
    _verifySyncSchema(result);
    if (result['protocolVersion'] != 1 || result['snapshotVersion'] != 2) {
      throw const ApiFailure('服务器尚不支持当前迁移协议，请先升级后端');
    }
    return result;
  }

  /// 提交完整快照；调用方必须持久保存迁移 ID 并在未知结果时复用。
  Future<Map<String, dynamic>> replaceServerSnapshot({
    required String apiBaseUrl,
    required String syncKey,
    required String migrationId,
    required String expectedOwnerId,
    required List<Map<String, Object?>> operations,
  }) {
    // 包含同步密钥的完整编码大小才是服务端请求上限的依据。
    final Map<String, Object?> payload = <String, Object?>{
      'syncKey': syncKey,
      'migrationId': migrationId,
      'expectedOwnerId': expectedOwnerId,
      'snapshotVersion': 2,
      'operations': operations,
    };
    if (operations.length > 100000 ||
        utf8.encode(jsonEncode(payload)).length > 32 * 1024 * 1024) {
      throw const ApiFailure('完整快照超过 100000 条或 32 MB，服务器数据未提交替换');
    }
    return _migrationRequest(apiBaseUrl, '/sync/migrations', payload);
  }

  /// 按持久迁移 ID 查询提交结果，查询不到不代表原请求已经失败。
  Future<Map<String, dynamic>> migrationStatus({
    required String apiBaseUrl,
    required String syncKey,
    required String migrationId,
  }) {
    return _migrationRequest(
      apiBaseUrl,
      '/sync/migrations/status',
      <String, Object?>{'syncKey': syncKey, 'migrationId': migrationId},
    );
  }

  /// 迁移协议使用独立密钥及较长超时，不依赖即将失效的设备会话。
  Future<Map<String, dynamic>> _migrationRequest(
    String apiBaseUrl,
    String path,
    Map<String, Object?> payload,
  ) async {
    try {
      // 迁移请求需覆盖六十秒数据库事务及网络传输时间。
      final Response<Map<String, dynamic>> response =
          await _dio(normalizeBaseUrl(apiBaseUrl)).post<Map<String, dynamic>>(
            path,
            data: payload,
            options: Options(
              sendTimeout: const Duration(seconds: 90),
              receiveTimeout: const Duration(seconds: 90),
            ),
          );
      if (response.data == null) throw const ApiFailure('服务器未返回迁移协议响应');
      return response.data!;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        throw const ApiFailure('服务器尚不支持数据迁移，请先升级后端');
      }
      throw ApiFailure(_messageFor(error, fallback: '服务器请求未完成，请保留当前迁移并重试'));
    }
  }

  /// 从安全存储与服务端恢复设备同步会话。
  Future<SyncSession?> restoreSession() async {
    // 已保存的完整会话。
    final _StoredSession? saved = await _readSession();
    if (saved == null) return null;
    // 当前恢复操作所属代次。
    final int generation = _generation;
    try {
      // 可用访问令牌。
      final String token = await ensureAccessToken(baseUrl: saved.baseUrl);
      // 服务端确认的内部身份。
      SyncIdentity identity;
      try {
        identity = await _loadIdentity(saved.baseUrl, token);
      } on DioException catch (error) {
        if (error.response?.statusCode != 401 || generation != _generation) {
          rethrow;
        }
        // 本机时钟可能滞后，访问令牌被拒绝时先验证稳定设备凭证。
        final String refreshed = await _refresh(saved.baseUrl);
        identity = await _loadIdentity(saved.baseUrl, refreshed);
      }
      if (generation != _generation) return null;
      return SyncSession(
        identity: identity,
        apiBaseUrl: saved.baseUrl,
        isOffline: false,
      );
    } on DioException catch (error) {
      if (generation != _generation) return null;
      // 版本错误不可伪装为离线恢复，否则会再次自动启动同步。
      final Object? responseData = error.response?.data;
      if (responseData is Map &&
          responseData['code'] == 'SYNC_SCHEMA_MISMATCH') {
        throw const SyncSchemaMismatch();
      }
      if (error.response?.statusCode == 401) {
        await clearSession();
        return null;
      }
      return SyncSession(
        identity: saved.identity,
        apiBaseUrl: saved.baseUrl,
        isOffline: true,
      );
    } on SyncSchemaMismatch {
      rethrow;
    } on ApiFailure {
      return null;
    }
  }

  /// 使用部署同步密钥建立设备会话，并一次性保存凭证及身份。
  Future<SyncSession> connect({
    required String apiBaseUrl,
    required String syncKey,
    String? expectedOwnerId,
  }) async {
    // 本次连接对应新的本机会话代次。
    final int generation = ++_generation;
    _pendingRefresh = null;
    // 从服务器地址和固定路径生成 API 根地址。
    final String baseUrl = normalizeBaseUrl(apiBaseUrl);
    try {
      // 设备连接响应。
      final Response<Map<String, dynamic>> response = await _dio(baseUrl).post(
        '/auth/connect',
        data: <String, dynamic>{
          'syncKey': syncKey,
          'expectedOwnerId': ?expectedOwnerId,
        },
      );
      // 服务端返回的会话令牌。
      final Map<String, dynamic> tokens = response.data ?? <String, dynamic>{};
      // 返回的访问凭证。
      final String accessToken = tokens['accessToken'] as String? ?? '';
      // 返回的设备凭证。
      final String refreshToken = tokens['refreshToken'] as String? ?? '';
      if (accessToken.isEmpty || refreshToken.isEmpty) {
        throw const ApiFailure('服务器没有返回完整设备会话令牌');
      }
      // 服务端内部身份。
      final SyncIdentity identity = await _loadIdentity(baseUrl, accessToken);
      if (expectedOwnerId != null && identity.id != expectedOwnerId) {
        throw const ApiFailure('服务器数据源已变化，请重新检查服务器');
      }
      await _saveSession(
        _StoredSession(
          baseUrl: baseUrl,
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiresAt: DateTime.now().add(
            Duration(seconds: tokens['expiresIn'] as int? ?? 900),
          ),
          identity: identity,
        ),
        generation,
      );
      return SyncSession(
        identity: identity,
        apiBaseUrl: baseUrl,
        isOffline: false,
      );
    } on DioException catch (error) {
      throw ApiFailure(_messageFor(error, fallback: '连接失败，请检查服务地址、同步密钥和网络'));
    }
  }

  /// 返回可用访问令牌，临近过期时合并所有刷新请求。
  Future<String> ensureAccessToken({String? baseUrl}) async {
    // 完整会话快照。
    final _StoredSession? saved = await _readSession();
    if (saved == null || (baseUrl != null && saved.baseUrl != baseUrl)) {
      throw const ApiFailure('当前设备尚未连接同步服务器');
    }
    if (saved.expiresAt.isAfter(
      DateTime.now().add(const Duration(minutes: 1)),
    )) {
      return saved.accessToken;
    }
    return _refresh(saved.baseUrl);
  }

  /// 获取 PowerSync 短期连接凭证。
  Future<PowerSyncCredential> fetchPowerSyncCredential() async {
    // 复用受保护请求的 401 刷新重试，兼容设备时钟偏差。
    final Response<Map<String, dynamic>> response =
        await authorizedRequest<Map<String, dynamic>>(
          'POST',
          '/auth/powersync-token',
        );
    // PowerSync 返回数据。
    final Map<String, dynamic> data = response.data ?? <String, dynamic>{};
    _verifySyncSchema(data);
    _verifiedSchemaGeneration = _generation;
    return PowerSyncCredential(
      endpoint: data['endpoint'] as String,
      token: data['token'] as String,
      expiresIn: data['expiresIn'] as int,
      userId: data['userId'] as String,
    );
  }

  /// 使用当前设备会话执行受保护请求。
  Future<Response<T>> authorizedRequest<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
    bool preserveTransportErrors = false,
  }) async {
    // 请求从读取会话起就固定所属代次。
    final int generation = _generation;
    // 当前服务器会话。
    final _StoredSession? saved = await _readSession();
    if (saved == null) throw const ApiFailure('当前设备尚未连接同步服务器');
    // 当前可用访问令牌。
    final String token = await ensureAccessToken(baseUrl: saved.baseUrl);
    await _assertUnchangedSession(saved, generation);
    try {
      // 只有原会话仍有效时才将响应交给上传确认逻辑。
      final Response<T> response = await _performAuthorizedRequest<T>(
        baseUrl: saved.baseUrl,
        token: token,
        method: method,
        path: path,
        data: data,
        queryParameters: queryParameters,
        responseType: responseType,
      );
      await _assertUnchangedSession(saved, generation);
      return response;
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        try {
          await _assertUnchangedSession(saved, generation);
          // 已有请求可能刚刚完成刷新，可直接使用其结果。
          final _StoredSession? current = await _readSession();
          if (current == null || current.refreshToken != saved.refreshToken) {
            throw const ApiFailure('同步会话已变更，请重试');
          }
          // 同一旧访问令牌的并发 401 共用一次刷新。
          final String refreshed = current.accessToken == token
              ? await _refresh(saved.baseUrl)
              : current.accessToken;
          await _assertUnchangedSession(saved, generation);
          // 重试也使用原服务器地址和原设备会话的刷新结果。
          final Response<T> response = await _performAuthorizedRequest<T>(
            baseUrl: saved.baseUrl,
            token: refreshed,
            method: method,
            path: path,
            data: data is FormData ? data.clone() : data,
            queryParameters: queryParameters,
            responseType: responseType,
          );
          await _assertUnchangedSession(saved, generation);
          return response;
        } on DioException catch (retryError) {
          if (preserveTransportErrors) rethrow;
          throw ApiFailure(_messageFor(retryError, fallback: '服务器请求失败'));
        }
      }
      if (preserveTransportErrors) rethrow;
      throw ApiFailure(_messageFor(error, fallback: '服务器请求失败'));
    }
  }

  /// 防止在途请求读取新会话、跨服务器重试或确认旧队列。
  Future<void> _assertUnchangedSession(
    _StoredSession saved,
    int generation,
  ) async {
    if (generation != _generation) {
      throw const ApiFailure('同步会话已变更，请重试');
    }
    // 同一安全存储键可能被应用恢复流程重新激活，需同时核对身份和设备凭证。
    final _StoredSession? current = await _readSession();
    if (generation != _generation ||
        current == null ||
        current.baseUrl != saved.baseUrl ||
        current.identity.id != saved.identity.id ||
        current.refreshToken != saved.refreshToken) {
      throw const ApiFailure('同步会话已变更，请重试');
    }
  }

  /// 使用指定令牌执行一次受保护请求。
  Future<Response<T>> _performAuthorizedRequest<T>({
    required String baseUrl,
    required String token,
    required String method,
    required String path,
    Object? data,
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
  }) {
    return _dio(baseUrl).request<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: Options(
        method: method,
        responseType: responseType,
        headers: <String, String>{'Authorization': 'Bearer $token'},
      ),
    );
  }

  /// 断开当前设备，立即阻止旧异步请求重新写入凭证。
  Future<void> disconnect() async {
    // 需要向服务端撤销的原会话。
    final _StoredSession? saved = await _readSession();
    await clearSession();
    if (saved == null) return;
    try {
      await _dio(saved.baseUrl).post(
        '/auth/disconnect',
        data: <String, String>{'refreshToken': saved.refreshToken},
      );
    } on DioException {
      // 网络不可用时本机仍保持断开，服务端会话等待固定到期。
    }
  }

  /// 清除当前设备凭证，并使所有已发出的刷新结果过时。
  Future<void> clearSession() {
    _generation++;
    _pendingRefresh = null;
    return _enqueueStorage(() => _storage.delete(key: storageKey));
  }

  /// 合并同一会话的并发刷新请求。
  Future<String> _refresh(String baseUrl) {
    // 可以共享的刷新请求。
    final Future<String>? pending = _pendingRefresh;
    if (pending != null) return pending;
    // 本次刷新所属代次。
    final int generation = _generation;
    // 共享的异步刷新任务。
    late final Future<String> operation;
    operation = _performRefresh(baseUrl, generation).whenComplete(() {
      if (identical(_pendingRefresh, operation)) _pendingRefresh = null;
    });
    _pendingRefresh = operation;
    return operation;
  }

  /// 刷新访问凭证，保留稳定设备凭证；只有明确的 401 才清理会话。
  Future<String> _performRefresh(String baseUrl, int generation) async {
    // 本次刷新的完整会话快照。
    final _StoredSession? saved = await _readSession();
    if (saved == null ||
        saved.baseUrl != baseUrl ||
        generation != _generation) {
      throw const ApiFailure('同步会话已失效，请重新连接服务器');
    }
    try {
      // 可安全重试的刷新响应。
      final Response<Map<String, dynamic>> response = await _dio(baseUrl).post(
        '/auth/refresh',
        data: <String, String>{'refreshToken': saved.refreshToken},
      );
      // 返回的访问凭证数据。
      final Map<String, dynamic> tokens = response.data ?? <String, dynamic>{};
      // 新短期访问凭证。
      final String accessToken = tokens['accessToken'] as String;
      await _saveSession(
        _StoredSession(
          baseUrl: baseUrl,
          accessToken: accessToken,
          refreshToken: saved.refreshToken,
          expiresAt: DateTime.now().add(
            Duration(seconds: tokens['expiresIn'] as int? ?? 900),
          ),
          identity: saved.identity,
        ),
        generation,
      );
      return accessToken;
    } on DioException catch (error) {
      if (error.response?.statusCode == 401 && generation == _generation) {
        await clearSession();
        throw const ApiFailure('同步会话已失效，请重新连接服务器');
      }
      rethrow;
    }
  }

  /// 读取服务端确认的内部同步身份。
  Future<SyncIdentity> _loadIdentity(String baseUrl, String token) async {
    // 当前会话身份响应。
    final Response<Map<String, dynamic>> response = await _dio(baseUrl).get(
      '/auth/session',
      options: Options(
        headers: <String, String>{'Authorization': 'Bearer $token'},
      ),
    );
    // 旧服务器不能在已有会话恢复路径绕过结构检查。
    final Map<String, dynamic> data = response.data ?? <String, dynamic>{};
    _verifySyncSchema(data);
    return SyncIdentity.fromJson(data);
  }

  /// 读取完整会话；旧格式不迁移，重新连接即可。
  Future<_StoredSession?> _readSession() async {
    await _storageWrites;
    // 原子保存的 JSON 文本。
    final String? value = await _storage.read(key: storageKey);
    if (value == null) return null;
    try {
      return _StoredSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(value) as Map),
      );
    } on Object {
      return null;
    }
  }

  /// 按序保存完整会话，拒绝已断开的异步结果。
  Future<void> _saveSession(_StoredSession session, int generation) {
    return _enqueueStorage(() async {
      if (generation != _generation) throw const ApiFailure('同步会话已变更，请重试');
      await _storage.write(
        key: storageKey,
        value: jsonEncode(session.toJson()),
      );
      if (generation != _generation) throw const ApiFailure('同步会话已变更，请重试');
    });
  }

  /// 串行执行安全存储修改，单次失败不会阻塞之后的清理。
  Future<void> _enqueueStorage(Future<void> Function() action) {
    // 本次持久化操作。
    final Future<void> next = _storageWrites.then((_) => action());
    _storageWrites = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  /// 校验服务器地址并拼接固定的 API 路径。
  String normalizeBaseUrl(String value) {
    // 只清理首尾空格，保留协议分隔符以便识别不完整地址。
    final String normalized = value.trim();
    // 是否明确指定连接协议。
    final bool hasScheme = normalized.contains('://');
    // 先以 HTTP 解析省略协议的地址，随后按主机类型选择协议。
    final Uri? uri = Uri.tryParse(
      hasScheme ? normalized : 'http://$normalized',
    );
    if (uri == null || uri.host.isEmpty || uri.host.contains(RegExp(r'\s'))) {
      throw const ApiFailure('请输入有效的服务器 IP 地址或域名');
    }
    if ((uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw const ApiFailure('服务器地址只需包含 IP 或域名和端口，不要填写路径或其他参数');
    }
    if (uri.port < 1 || uri.port > 65535) {
      throw const ApiFailure('端口必须是 1 到 65535 之间的整数');
    }
    // 是否为仅限本机或局域网的私有地址。
    final bool isPrivateHost = _isPrivateNetworkHost(uri.host);
    // 局域网默认 HTTP，公网默认 HTTPS；显式协议仍遵循原安全限制。
    final String scheme = hasScheme
        ? uri.scheme
        : (isPrivateHost ? 'http' : 'https');
    if (scheme != 'https' && !(isPrivateHost && scheme == 'http')) {
      throw const ApiFailure('公网服务必须使用 HTTPS；本机或局域网 IP 可使用 HTTP');
    }
    // 按最终协议重新解析原始输入，保留显式填写的 80/443 等端口。
    final Uri serverUri = Uri.parse(
      hasScheme ? normalized : '$scheme://$normalized',
    );
    return serverUri.replace(path: fixedApiPath).toString();
  }

  /// 判断主机名是否属于本机或 RFC 1918 私有 IPv4 地址。
  bool _isPrivateNetworkHost(String host) {
    if (host == 'localhost' || host == '127.0.0.1') return true;
    // IPv4 四段数值。
    final List<int>? parts = host.split('.').length == 4
        ? host.split('.').map(int.tryParse).whereType<int>().toList()
        : null;
    if (parts == null ||
        parts.length != 4 ||
        parts.any((int part) => part < 0 || part > 255)) {
      return false;
    }
    return parts[0] == 10 ||
        (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) ||
        (parts[0] == 192 && parts[1] == 168);
  }

  /// 创建带公共超时设置的 HTTP 客户端。
  Dio _dio(String baseUrl) {
    // 测试传输与真实传输统一附带版本头，不改动原有请求体契约。
    final Dio client =
        clientFactory?.call(baseUrl) ??
        Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
            sendTimeout: const Duration(seconds: 15),
            responseType: ResponseType.json,
          ),
        );
    client.options.headers['X-Omni-Sync-Schema'] = syncSchemaVersion.toString();
    return client;
  }

  /// 将服务端错误转换为用户提示。
  String _messageFor(DioException error, {required String fallback}) {
    // 服务端错误响应体。
    final Object? responseData = error.response?.data;
    if (responseData is Map<String, dynamic>) {
      if (responseData['code'] == 'SYNC_SCHEMA_MISMATCH') {
        throw const SyncSchemaMismatch();
      }
      // NestJS 标准错误消息。
      final Object? message = responseData['message'];
      if (message is String && message.isNotEmpty) return message;
      if (message is List && message.isNotEmpty) {
        return message.first.toString();
      }
    }
    return fallback;
  }
}
