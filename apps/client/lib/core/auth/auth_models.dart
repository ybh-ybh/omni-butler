import 'package:flutter/foundation.dart';

/// 服务端内部同步身份，仅用于隔离单人数据。
@immutable
class SyncIdentity {
  /// 服务端内部数据所有者标识。
  final String id;

  /// 创建内部同步身份。
  const SyncIdentity({required this.id});

  /// 从 API JSON 解析内部同步身份。
  factory SyncIdentity.fromJson(Map<String, dynamic> json) {
    return SyncIdentity(id: json['sub'] as String);
  }
}

/// 当前设备恢复出的同步服务会话。
@immutable
class SyncSession {
  /// 服务端内部同步身份。
  final SyncIdentity identity;

  /// 当前 API 根地址。
  final String apiBaseUrl;

  /// 是否因离线而使用缓存资料。
  final bool isOffline;

  /// 创建设备同步会话。
  const SyncSession({
    required this.identity,
    required this.apiBaseUrl,
    required this.isOffline,
  });

  /// 复制并替换离线状态。
  SyncSession copyWith({bool? isOffline}) {
    return SyncSession(
      identity: identity,
      apiBaseUrl: apiBaseUrl,
      isOffline: isOffline ?? this.isOffline,
    );
  }
}

/// PowerSync 短期连接凭证。
@immutable
class PowerSyncCredential {
  /// PowerSync 服务地址。
  final String endpoint;

  /// 最多十五分钟的连接 JWT。
  final String token;

  /// 令牌有效秒数。
  final int expiresIn;

  /// 当前同步用户标识。
  final String userId;

  /// 创建 PowerSync 凭证。
  const PowerSyncCredential({
    required this.endpoint,
    required this.token,
    required this.expiresIn,
    required this.userId,
  });
}

/// 可向用户展示的 API 调用异常。
class ApiFailure implements Exception {
  /// 用户可理解的错误说明。
  final String message;

  /// 创建 API 调用异常。
  const ApiFailure(this.message);

  /// 返回用户可理解的错误说明。
  @override
  String toString() => message;
}
