/// 通过设备会话验证后的 API 认证主体。
export interface AuthUser {
  /// 内部数据所有者标识。
  sub: string;
  /// 设备会话标识。
  sid: string;
  /// 令牌用途。
  typ: 'access';
}

/// 设备连接与刷新接口返回的令牌组。
export interface TokenPair {
  /// 短期访问令牌。
  accessToken: string;
  /// 固定有效期内可重复使用的高熵设备凭证。
  refreshToken: string;
  /// 访问令牌有效秒数。
  expiresIn: number;
}
