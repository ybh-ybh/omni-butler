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
): EnvironmentVariables {
  // 必填环境变量名称。
  const requiredKeys = [
    'DATABASE_URL',
    'POWERSYNC_URL',
    'SYNC_SECRET',
  ] as const;
  // 逐个检查部署必需的参数。
  for (const key of requiredKeys) {
    if (typeof source[key] !== 'string' || source[key].trim().length === 0) {
      throw new Error(`缺少必填环境变量：${key}`);
    }
  }
  // 用户设置的同步密钥。
  const syncSecret = String(source.SYNC_SECRET);
  if (syncSecret.length < 16) {
    throw new Error('SYNC_SECRET 至少需要 16 个字符');
  }
  // API 前缀使用字面路径，避免通配符、编码字符或斜杠归一化导致各服务地址不一致。
  const apiPrefix = source.API_PREFIX ?? 'api/v1';
  if (
    typeof apiPrefix !== 'string' ||
    apiPrefix !== apiPrefix.trim() ||
    !/^[A-Za-z0-9_-]+(?:\/[A-Za-z0-9_-]+)*$/.test(apiPrefix)
  ) {
    throw new Error(
      'API_PREFIX 必须由字母、数字、下划线、短横线及层级斜杠组成，不能以斜杠开头或结尾',
    );
  }
  // Compose 指定卷内目录；本地开发默认保存在已忽略的 .local/keys。
  const keysDirectory =
    typeof source.JWT_KEYS_DIR === 'string' && source.JWT_KEYS_DIR.trim()
      ? source.JWT_KEYS_DIR
      : '.local/keys';
  // 其他配置校验通过后再读取或生成持久化密钥。
  const keys = resolveJwtKeys(keysDirectory);
  return {
    ...keys,
    DATABASE_URL: String(source.DATABASE_URL),
    NODE_ENV:
      typeof source.NODE_ENV === 'string' ? source.NODE_ENV : 'development',
    PORT: 3000,
    API_PREFIX: apiPrefix,
    JWT_ISSUER: 'omni-butler',
    JWT_AUDIENCE: 'omni-butler-api',
    POWERSYNC_AUDIENCE: 'omni-butler-powersync',
    POWERSYNC_URL: String(source.POWERSYNC_URL),
    SYNC_SECRET: syncSecret,
    REFRESH_TOKEN_TTL_SECONDS: 30 * 24 * 60 * 60,
  };
}
