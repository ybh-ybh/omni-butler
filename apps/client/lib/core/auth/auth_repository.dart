import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omni_butler/core/auth/auth_models.dart';

/// 安全存储中的 API 根地址键。
const String _baseUrlKey = 'sync.api_base_url';

/// 安全存储中的访问令牌键。
const String _accessTokenKey = 'sync.access_token';

/// 安全存储中的刷新令牌键。
const String _refreshTokenKey = 'sync.refresh_token';

/// 安全存储中的访问令牌过期时间键。
const String _accessExpiresAtKey = 'sync.access_expires_at';

/// 安全存储中的内部同步身份键。
const String _identityKey = 'sync.identity';

/// 自托管同步服务连接与设备会话仓储。
class AuthRepository {
  /// Windows 系统安全存储。
  final FlutterSecureStorage _storage;

  /// 创建同步服务会话仓储。
  const AuthRepository(this._storage);

  /// 从安全存储与服务端恢复设备同步会话。
  Future<SyncSession?> restoreSession() async {
    // 已保存 API 根地址。
    final String? baseUrl = await _storage.read(key: _baseUrlKey);
    // 已保存访问令牌。
    final String? accessToken = await _storage.read(key: _accessTokenKey);
    // 已保存刷新令牌。
    final String? refreshToken = await _storage.read(key: _refreshTokenKey);
    // 已缓存内部同步身份。
    final SyncIdentity? cachedIdentity = await _readCachedIdentity();
    if (baseUrl == null ||
        accessToken == null ||
        refreshToken == null ||
        cachedIdentity == null) {
      return null;
    }
    try {
      // 可用访问令牌。
      final String token = await ensureAccessToken(baseUrl: baseUrl);
      // 服务端最新内部同步身份。
      final SyncIdentity identity = await _loadIdentity(baseUrl, token);
      await _writeIdentity(identity);
      return SyncSession(
        identity: identity,
        apiBaseUrl: baseUrl,
        isOffline: false,
      );
    } on DioException catch (error) {
      if (_isNetworkFailure(error)) {
        return SyncSession(
          identity: cachedIdentity,
          apiBaseUrl: baseUrl,
          isOffline: true,
        );
      }
      await clearSession();
      return null;
    } on ApiFailure {
      await clearSession();
      return null;
    }
  }

  /// 使用用户部署时设置的同步密钥建立设备会话。
  Future<SyncSession> connect({
    required String apiBaseUrl,
    required String syncKey,
  }) async {
    // 规范化后的 API 根地址。
    final String baseUrl = normalizeBaseUrl(apiBaseUrl);
    // 未携带认证的 API 客户端。
    final Dio dio = _dio(baseUrl);
    try {
      // 设备连接接口响应。
      final Response<Map<String, dynamic>> response = await dio.post(
        '/auth/connect',
        data: <String, dynamic>{'syncKey': syncKey},
      );
      // 设备会话令牌数据。
      final Map<String, dynamic> tokens = response.data ?? <String, dynamic>{};
      // 访问令牌。
      final String accessToken = tokens['accessToken'] as String? ?? '';
      // 刷新令牌。
      final String refreshToken = tokens['refreshToken'] as String? ?? '';
      // 访问令牌有效秒数。
      final int expiresIn = tokens['expiresIn'] as int? ?? 900;
      if (accessToken.isEmpty || refreshToken.isEmpty) {
        throw const ApiFailure('服务器没有返回完整设备会话令牌');
      }
      // 服务端内部同步身份。
      final SyncIdentity identity = await _loadIdentity(baseUrl, accessToken);
      await _writeTokens(
        baseUrl: baseUrl,
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: expiresIn,
      );
      await _writeIdentity(identity);
      return SyncSession(
        identity: identity,
        apiBaseUrl: baseUrl,
        isOffline: false,
      );
    } on DioException catch (error) {
      throw ApiFailure(_messageFor(error, fallback: '连接失败，请检查服务地址、同步密钥和网络'));
    }
  }

  /// 返回可用访问令牌，临近过期时自动轮换。
  Future<String> ensureAccessToken({String? baseUrl}) async {
    // 已保存 API 根地址。
    final String? storedBaseUrl =
        baseUrl ?? await _storage.read(key: _baseUrlKey);
    // 已保存访问令牌。
    final String? accessToken = await _storage.read(key: _accessTokenKey);
    // 已保存访问令牌过期时间。
    final String? expiresAtText = await _storage.read(key: _accessExpiresAtKey);
    // 解析后的过期时间。
    final DateTime? expiresAt = DateTime.tryParse(expiresAtText ?? '');
    if (storedBaseUrl == null || accessToken == null) {
      throw const ApiFailure('当前设备尚未连接同步服务器');
    }
    if (expiresAt != null &&
        expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return accessToken;
    }
    return _refresh(storedBaseUrl);
  }

  /// 获取 PowerSync 短期连接凭证。
  Future<PowerSyncCredential> fetchPowerSyncCredential() async {
    // 当前 API 根地址。
    final String? baseUrl = await _storage.read(key: _baseUrlKey);
    if (baseUrl == null) {
      throw const ApiFailure('当前设备尚未连接同步服务器');
    }
    // 可用访问令牌。
    final String accessToken = await ensureAccessToken(baseUrl: baseUrl);
    try {
      // PowerSync 凭证响应。
      final Response<Map<String, dynamic>> response = await _dio(baseUrl).post(
        '/auth/powersync-token',
        options: Options(
          headers: <String, String>{'Authorization': 'Bearer $accessToken'},
        ),
      );
      // PowerSync 凭证数据。
      final Map<String, dynamic> data = response.data ?? <String, dynamic>{};
      return PowerSyncCredential(
        endpoint: data['endpoint'] as String,
        token: data['token'] as String,
        expiresIn: data['expiresIn'] as int,
        userId: data['userId'] as String,
      );
    } on DioException catch (error) {
      throw ApiFailure(_messageFor(error, fallback: '无法获取同步凭证'));
    }
  }

  /// 使用当前访问令牌执行受保护请求。
  Future<Response<T>> authorizedRequest<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
  }) async {
    // 当前 API 根地址。
    final String? baseUrl = await _storage.read(key: _baseUrlKey);
    if (baseUrl == null) {
      throw const ApiFailure('当前设备尚未连接同步服务器');
    }
    // 可用访问令牌。
    final String token = await ensureAccessToken(baseUrl: baseUrl);
    try {
      return await _performAuthorizedRequest<T>(
        baseUrl: baseUrl,
        token: token,
        method: method,
        path: path,
        data: data,
        queryParameters: queryParameters,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        try {
          // 服务端拒绝旧令牌后强制轮换一次，覆盖客户端时钟漂移场景。
          final String refreshedToken = await _refresh(baseUrl);
          return await _performAuthorizedRequest<T>(
            baseUrl: baseUrl,
            token: refreshedToken,
            method: method,
            path: path,
            data: data,
            queryParameters: queryParameters,
          );
        } on DioException catch (retryError) {
          throw ApiFailure(_messageFor(retryError, fallback: '服务器请求失败'));
        }
      }
      throw ApiFailure(_messageFor(error, fallback: '服务器请求失败'));
    }
  }

  /// 使用指定访问令牌执行一次受保护请求。
  Future<Response<T>> _performAuthorizedRequest<T>({
    required String baseUrl,
    required String token,
    required String method,
    required String path,
    Object? data,
    Map<String, dynamic>? queryParameters,
  }) {
    return _dio(baseUrl).request<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: Options(
        method: method,
        headers: <String, String>{'Authorization': 'Bearer $token'},
      ),
    );
  }

  /// 断开当前同步服务器并保留本机业务数据。
  Future<void> disconnect() async {
    // 已保存 API 根地址。
    final String? baseUrl = await _storage.read(key: _baseUrlKey);
    // 已保存刷新令牌。
    final String? refreshToken = await _storage.read(key: _refreshTokenKey);
    if (baseUrl != null && refreshToken != null) {
      try {
        await _dio(baseUrl).post(
          '/auth/disconnect',
          data: <String, String>{'refreshToken': refreshToken},
        );
      } on DioException {
        // 断网时仍清理本机令牌，服务端令牌等待自然过期。
      }
    }
    await clearSession();
  }

  /// 清除本机设备会话令牌与内部同步身份。
  Future<void> clearSession() async {
    for (final String key in <String>[
      _baseUrlKey,
      _accessTokenKey,
      _refreshTokenKey,
      _accessExpiresAtKey,
      _identityKey,
    ]) {
      await _storage.delete(key: key);
    }
  }

  /// 校验并规范化 API 根地址。
  String normalizeBaseUrl(String value) {
    // 清理尾部斜杠后的地址。
    final String normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    // 解析后的 API 地址。
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) {
      throw const ApiFailure('请输入完整的 API 服务地址');
    }
    // 是否为仅限本机或局域网的私有地址。
    final bool isPrivateHost = _isPrivateNetworkHost(uri.host);
    if (uri.scheme != 'https' && !(isPrivateHost && uri.scheme == 'http')) {
      throw const ApiFailure('公网服务必须使用 HTTPS；本机或局域网 IP 可使用 HTTP');
    }
    return normalized;
  }

  /// 判断主机名是否属于本机或 RFC 1918 私有 IPv4 地址。
  bool _isPrivateNetworkHost(String host) {
    if (host == 'localhost' || host == '127.0.0.1') {
      return true;
    }
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

  /// 轮换访问与刷新令牌。
  Future<String> _refresh(String baseUrl) async {
    // 当前刷新令牌。
    final String? refreshToken = await _storage.read(key: _refreshTokenKey);
    if (refreshToken == null) {
      throw const ApiFailure('同步会话已失效，请重新连接服务器');
    }
    try {
      // 刷新接口响应。
      final Response<Map<String, dynamic>> response = await _dio(baseUrl).post(
        '/auth/refresh',
        data: <String, String>{'refreshToken': refreshToken},
      );
      // 新令牌数据。
      final Map<String, dynamic> tokens = response.data ?? <String, dynamic>{};
      // 新访问令牌。
      final String accessToken = tokens['accessToken'] as String;
      await _writeTokens(
        baseUrl: baseUrl,
        accessToken: accessToken,
        refreshToken: tokens['refreshToken'] as String,
        expiresIn: tokens['expiresIn'] as int? ?? 900,
      );
      return accessToken;
    } on DioException catch (error) {
      if (_isNetworkFailure(error)) {
        rethrow;
      }
      await clearSession();
      throw const ApiFailure('同步会话已失效，请重新连接服务器');
    }
  }

  /// 从服务端读取内部同步身份。
  Future<SyncIdentity> _loadIdentity(String baseUrl, String token) async {
    try {
      // 当前设备会话接口响应。
      final Response<Map<String, dynamic>> response = await _dio(baseUrl).get(
        '/auth/session',
        options: Options(
          headers: <String, String>{'Authorization': 'Bearer $token'},
        ),
      );
      return SyncIdentity.fromJson(response.data ?? <String, dynamic>{});
    } on DioException catch (error) {
      if (_isNetworkFailure(error)) {
        rethrow;
      }
      throw ApiFailure(_messageFor(error, fallback: '无法读取设备同步会话'));
    }
  }

  /// 安全保存一组轮换后的令牌。
  Future<void> _writeTokens({
    required String baseUrl,
    required String accessToken,
    required String refreshToken,
    required int expiresIn,
  }) async {
    // 提前三十秒记录的访问令牌过期时间。
    final DateTime expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    await _storage.write(key: _baseUrlKey, value: baseUrl);
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
    await _storage.write(
      key: _accessExpiresAtKey,
      value: expiresAt.toIso8601String(),
    );
  }

  /// 安全缓存服务端内部同步身份。
  Future<void> _writeIdentity(SyncIdentity identity) async {
    await _storage.write(
      key: _identityKey,
      value: jsonEncode(<String, String>{'sub': identity.id}),
    );
  }

  /// 从安全存储读取缓存的内部同步身份。
  Future<SyncIdentity?> _readCachedIdentity() async {
    // 缓存同步身份 JSON 文本。
    final String? text = await _storage.read(key: _identityKey);
    if (text == null) {
      return null;
    }
    try {
      return SyncIdentity.fromJson(
        Map<String, dynamic>.from(jsonDecode(text) as Map),
      );
    } on Object {
      return null;
    }
  }

  /// 创建带公共超时设置的 Dio 客户端。
  Dio _dio(String baseUrl) {
    return Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        responseType: ResponseType.json,
      ),
    );
  }

  /// 判断 Dio 异常是否属于无法访问网络。
  bool _isNetworkFailure(DioException error) {
    return <DioExceptionType>{
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.unknown,
    }.contains(error.type);
  }

  /// 将服务端错误转换为不暴露敏感信息的用户提示。
  String _messageFor(DioException error, {required String fallback}) {
    // 服务端错误响应体。
    final Object? responseData = error.response?.data;
    if (responseData is Map<String, dynamic>) {
      // NestJS 标准错误消息。
      final Object? message = responseData['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
      if (message is List && message.isNotEmpty) {
        return message.first.toString();
      }
    }
    return fallback;
  }
}
