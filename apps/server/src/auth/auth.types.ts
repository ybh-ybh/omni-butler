/// JWT 中携带的认证主体。
export interface AuthUser {
  /// 内部数据所有者标识。
  sub: string;
  /// 仅供旧数据库结构兼容的内部邮箱。
  email: string;
  /// 仅供现有数据隔离逻辑使用的内部角色。
  role: string;
  /// 令牌用途。
  typ: 'access' | 'refresh' | 'powersync';
  /// 令牌唯一标识。
  jti?: string;
  /// 设备会话令牌版本。
  version: number;
}

/// 设备连接与刷新接口返回的令牌组。
export interface TokenPair {
  /// 短期访问令牌。
  accessToken: string;
  /// 可轮换刷新令牌。
  refreshToken: string;
  /// 访问令牌有效秒数。
  expiresIn: number;
}
