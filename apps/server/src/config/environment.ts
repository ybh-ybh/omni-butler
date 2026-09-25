import { resolveJwtKeys } from './jwt-keys';

/// 应用启动所需的环境变量结构。
interface EnvironmentVariables {
  /// PostgreSQL 连接地址。
  DATABASE_URL: string;
  /// 运行环境。
  NODE_ENV: string;
  /// HTTP 端口。
  PORT: number;
  /// API 路径前缀。
  API_PREFIX: string;
  /// 跨域来源列表。
  CORS_ORIGINS: string;
  /// RSA 私钥 Base64。
  JWT_PRIVATE_KEY_BASE64: string;
  /// RSA 公钥 Base64。
  JWT_PUBLIC_KEY_BASE64: string;
  /// JWT 密钥标识。
  JWT_KEY_ID: string;
  /// JWT 签发方。
  JWT_ISSUER: string;
  /// API JWT 受众。
  JWT_AUDIENCE: string;
  /// PowerSync JWT 受众。
  POWERSYNC_AUDIENCE: string;
  /// PowerSync 公网地址。
  POWERSYNC_URL: string;
  /// 用户部署时设置的设备同步密钥。
  SYNC_SECRET: string;
  /// 刷新令牌有效秒数。
  REFRESH_TOKEN_TTL_SECONDS: number;
}

/// 校验并规范化应用环境变量。
export function validateEnvironment(
  source: Record<string, unknown>,
): EnvironmentVariables & Record<string, unknown> {
  // 必填环境变量名称。
  const requiredKeys = [
    'DATABASE_URL',
    'JWT_KEY_ID',
    'JWT_ISSUER',
    'JWT_AUDIENCE',
    'POWERSYNC_AUDIENCE',
    'POWERSYNC_URL',
    'SYNC_SECRET',
  ] as const;
  for (const key of requiredKeys) {
    if (typeof source[key] !== 'string' || source[key].trim().length === 0) {
      throw new Error(`缺少必填环境变量：${key}`);
    }
  }
  // 规范化后的端口。
  const port = Number(source.PORT ?? 3000);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error('PORT 必须是 1 到 65535 之间的整数');
  }
  // 刷新令牌有效秒数。
  const refreshTokenSeconds = Number(
    source.REFRESH_TOKEN_TTL_SECONDS ?? 2592000,
  );
  if (!Number.isInteger(refreshTokenSeconds) || refreshTokenSeconds < 3600) {
    throw new Error('REFRESH_TOKEN_TTL_SECONDS 必须是不小于 3600 的整数');
  }
  // 用户设置的同步密钥。
  const syncSecret = String(source.SYNC_SECRET);
  if (syncSecret.length < 16) {
    throw new Error('SYNC_SECRET 至少需要 16 个字符');
  }
  // 其他配置校验通过后再读取或生成持久化密钥。
  source = resolveJwtKeys(source);
  // RSA 公私钥必须成对存在。
  for (const key of ['JWT_PRIVATE_KEY_BASE64', 'JWT_PUBLIC_KEY_BASE64']) {
    if (typeof source[key] !== 'string' || source[key].trim().length === 0) {
      throw new Error(`缺少必填环境变量：${key}`);
    }
  }
  // 安全读取可选字符串配置。
  const optionalString = (key: string, fallback: string): string =>
    typeof source[key] === 'string' ? source[key] : fallback;
  return {
    ...source,
    DATABASE_URL: String(source.DATABASE_URL),
    NODE_ENV: optionalString('NODE_ENV', 'development'),
    PORT: port,
    API_PREFIX: optionalString('API_PREFIX', 'api/v1'),
    CORS_ORIGINS: optionalString('CORS_ORIGINS', 'http://127.0.0.1:4173'),
    JWT_PRIVATE_KEY_BASE64: String(source.JWT_PRIVATE_KEY_BASE64),
    JWT_PUBLIC_KEY_BASE64: String(source.JWT_PUBLIC_KEY_BASE64),
    JWT_KEY_ID: String(source.JWT_KEY_ID),
    JWT_ISSUER: String(source.JWT_ISSUER),
    JWT_AUDIENCE: String(source.JWT_AUDIENCE),
    POWERSYNC_AUDIENCE: String(source.POWERSYNC_AUDIENCE),
    POWERSYNC_URL: String(source.POWERSYNC_URL),
    SYNC_SECRET: syncSecret,
    REFRESH_TOKEN_TTL_SECONDS: refreshTokenSeconds,
  };
}
