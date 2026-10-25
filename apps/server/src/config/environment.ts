import { resolveJwtKeys } from './jwt-keys';

/// Omni Butler PowerSync 的固定公网代理路径。
const POWERSYNC_PUBLIC_PATH = '/omni-butler/powersync/';

/// 笔记签名原音链接使用固定的 API 前缀。
const API_PUBLIC_PATH = '/omni-butler/api/v1';

/// 将可选公网根地址规范为 HTTPS origin，拒绝额外路径及敏感参数。
function resolvePublicBaseUrl(value: unknown): string {
  if (value === undefined || value === '') return '';
  if (typeof value !== 'string' || value !== value.trim()) {
    throw new Error('PUBLIC_BASE_URL 必须为 HTTPS 根地址');
  }
  // URL 解析会规范化点路径，先检查原始输入确实只有域名、端口和可选末尾斜杠。
  if (!/^https:\/\/[^/?#\\@\s]+\/?$/i.test(value)) {
    throw new Error('PUBLIC_BASE_URL 必须为 HTTPS 根地址');
  }
  // 解析后的公网根地址，不在错误中回显输入或凭据。
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error('PUBLIC_BASE_URL 必须为 HTTPS 根地址');
  }
  if (
    parsed.protocol !== 'https:' || parsed.username || parsed.password ||
    parsed.pathname !== '/' || parsed.search || parsed.hash
  ) {
    throw new Error('PUBLIC_BASE_URL 必须为不含凭据、路径或参数的 HTTPS 根地址');
  }
  return parsed.origin;
}

/// 应用启动所需的环境变量结构。
interface EnvironmentVariables {
  /// MCP 的固定部署 Origin，空值仅允许无 Origin 的本机连接。
  MCP_ALLOWED_ORIGINS: string;
  /// 保留规范化公网 Origin，供 MCP 校验代理 Host。
  PUBLIC_BASE_URL: string;
  /// AI 独立加密密钥复用持久卷目录，不复用 JWT 密钥。
  JWT_KEYS_DIR: string;
  /// 云端识别厂商与凭证只存在后端。
  NOTE_ASR_PROVIDER: string;
  NOTE_ASR_MODEL: string;
  NOTE_ASR_PUBLIC_URL: string;
  /// 图片及笔记共享内部MinIO，两个领域使用各自私有桶。
  MINIO_ENDPOINT: string;
  MINIO_CREDENTIALS_FILE: string;
  TENCENT_ASR_APP_ID: string;
  TENCENT_ASR_SECRET_ID: string;
  TENCENT_ASR_SECRET_KEY: string;
  /// 图片同步开关，默认关闭。
  IMAGE_SYNC_ENABLED: boolean;
  ASSISTANT_ATTACHMENTS_ENABLED: boolean;
  /// PostgreSQL 连接地址。
  DATABASE_URL: string;
  /// 运行环境。
  NODE_ENV: string;
  /// HTTP 端口。
  PORT: number;
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
  const requiredKeys = ['DATABASE_URL', 'SYNC_SECRET'] as const;
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
  // 基础地址即使被独立覆盖也需要校验，防止错误配置静默通过。
  const publicBaseUrl = resolvePublicBaseUrl(source.PUBLIC_BASE_URL);
  // 自托管代理/LAN的MCP Host必须显式配置，禁止通配和含凭据URL。
  const mcpOrigins = source.MCP_ALLOWED_ORIGINS ?? '';
  if (typeof mcpOrigins !== 'string') throw new Error('MCP_ALLOWED_ORIGINS 必须为逗号分隔的HTTP(S)根地址');
  // 配置错误在生成密钥之前抛出，且不回显原始URL。
  const normalizedMcpOrigins = mcpOrigins ? mcpOrigins.split(',').map((value) => {
    // 每个值只允许固定origin，不接受路径、凭据、查询或通配符。
    let parsed: URL;
    try { parsed = new URL(value); } catch { throw new Error('MCP_ALLOWED_ORIGINS 包含非法Origin'); }
    if (!/^https?:\/\/[^/?#\\@\s]+\/?$/i.test(value) || value !== value.trim() || !['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash || value.includes('*')) throw new Error('MCP_ALLOWED_ORIGINS 仅允许无凭据的HTTP(S)根地址');
    return parsed.origin;
  }).join(',') : '';
  if (source.POWERSYNC_URL !== undefined && typeof source.POWERSYNC_URL !== 'string') {
    throw new Error('POWERSYNC_URL 必须是有效的 HTTP 或 HTTPS 地址');
  }
  // 带反向代理路径的 PowerSync 地址必须以斜杠结尾，SDK 才会在该路径下追加同步端点。
  const powerSyncUrl = source.POWERSYNC_URL ||
    (publicBaseUrl ? `${publicBaseUrl}${POWERSYNC_PUBLIC_PATH}` : '');
  if (!powerSyncUrl) {
    throw new Error('缺少必填环境变量：POWERSYNC_URL（或配置 PUBLIC_BASE_URL）');
  }
  // 解析后的 PowerSync 公网地址。
  let parsedPowerSyncUrl: URL;
  try {
    parsedPowerSyncUrl = new URL(powerSyncUrl);
  } catch {
    throw new Error('POWERSYNC_URL 必须是有效的 HTTP 或 HTTPS 地址');
  }
  if (
    powerSyncUrl !== powerSyncUrl.trim() ||
    !['http:', 'https:'].includes(parsedPowerSyncUrl.protocol) ||
    parsedPowerSyncUrl.username.length > 0 ||
    parsedPowerSyncUrl.password.length > 0 ||
    parsedPowerSyncUrl.search.length > 0 ||
    parsedPowerSyncUrl.hash.length > 0
  ) {
    throw new Error('POWERSYNC_URL 必须是有效的 HTTP 或 HTTPS 地址');
  }
  if (
    parsedPowerSyncUrl.pathname !== '/' &&
    parsedPowerSyncUrl.pathname !== POWERSYNC_PUBLIC_PATH
  ) {
    throw new Error(
      `POWERSYNC_URL 的公网路径必须固定为 ${POWERSYNC_PUBLIC_PATH}`,
    );
  }
  // Compose 指定卷内目录；本地开发默认保存在已忽略的 .local/keys。
  const keysDirectory =
    typeof source.JWT_KEYS_DIR === 'string' && source.JWT_KEYS_DIR.trim()
      ? source.JWT_KEYS_DIR
      : '.local/keys';
  // 严格接受布尔开关，避免拼写错误导致意外启用。
  // 助手附件独立于业务图片同步，关闭时不连接私有存储。
  const assistantAttachmentsEnabled = source.ASSISTANT_ATTACHMENTS_ENABLED ?? 'false';
  if (!['true', 'false', true, false].includes(assistantAttachmentsEnabled as string)) throw new Error('ASSISTANT_ATTACHMENTS_ENABLED 必须为 true 或 false');
  const imageSyncEnabled = source.IMAGE_SYNC_ENABLED ?? 'false';
  if (!['true', 'false', true, false].includes(imageSyncEnabled as string)) {
    throw new Error('IMAGE_SYNC_ENABLED 必须为 true 或 false');
  }
  // 公网链接必须是可访问的 API 根路径，禁止含账号密码、查询或片段。
  if (source.NOTE_ASR_PUBLIC_URL !== undefined && typeof source.NOTE_ASR_PUBLIC_URL !== 'string') {
    throw new Error('NOTE_ASR_PUBLIC_URL 必须为 HTTPS 的 /omni-butler/api/v1 公网地址');
  }
  // 独立地址保留既有去空白规则，仅空覆盖使用统一根地址派生。
  const notePublicOverride = source.NOTE_ASR_PUBLIC_URL?.trim() || '';
  // 去除末尾斜杠不能将非法非空覆盖误判为未配置。
  const notePublicUrl = notePublicOverride
    ? notePublicOverride.replace(/\/$/, '')
    : (publicBaseUrl ? `${publicBaseUrl}${API_PUBLIC_PATH}` : '');
  if (notePublicOverride || notePublicUrl) {
    // 经过结构验证的公网 API 根地址。
    let parsed: URL;
    try {
      parsed = new URL(notePublicUrl);
    } catch {
      throw new Error('NOTE_ASR_PUBLIC_URL 必须为 HTTPS 的 /omni-butler/api/v1 公网地址');
    }
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash || !parsed.pathname.endsWith('/omni-butler/api/v1')) throw new Error('NOTE_ASR_PUBLIC_URL 必须为 HTTPS 的 /omni-butler/api/v1 公网地址');
  }
  // 严格接受已安装的适配器，关闭时仍支持本地文本和录音。
  const noteProvider = source.NOTE_ASR_PROVIDER ?? 'none';
  if (typeof noteProvider !== 'string' || !['none', 'tencent'].includes(noteProvider)) throw new Error('NOTE_ASR_PROVIDER 必须为 none 或 tencent');
  // 内网端点不能夹带密钥、路径或额外查询参数。
  const minioEndpoint = source.MINIO_ENDPOINT ?? 'http://minio:9000';
  // URL解析失败统一给出配置名称，不回显含敏感内容的输入。
  let parsedMinio: URL;
  try { if (typeof minioEndpoint !== 'string') throw new Error('invalid'); parsedMinio = new URL(minioEndpoint); } catch { throw new Error('MINIO_ENDPOINT 必须为有效的 HTTP 或 HTTPS 根地址'); }
  if (minioEndpoint !== minioEndpoint.trim() || !['http:', 'https:'].includes(parsedMinio.protocol) || parsedMinio.username || parsedMinio.password || parsedMinio.search || parsedMinio.hash || parsedMinio.pathname !== '/') throw new Error('MINIO_ENDPOINT 必须为不含凭据的 HTTP 或 HTTPS 根地址');
  // 本地测试可使用独立凭证文件，生产默认读取部署生成的只读挂载。
  const minioCredentialsFile = source.MINIO_CREDENTIALS_FILE ?? '/app/image-storage/credentials.json';
  if (typeof minioCredentialsFile !== 'string' || !minioCredentialsFile.trim() || minioCredentialsFile !== minioCredentialsFile.trim() || minioCredentialsFile.includes('\0')) throw new Error('MINIO_CREDENTIALS_FILE 必须为非空文件路径');
  // 所有配置校验通过后再读取或生成持久化密钥。
  const keys = resolveJwtKeys(keysDirectory);
  return {
    ...keys,
    MCP_ALLOWED_ORIGINS: normalizedMcpOrigins,
    PUBLIC_BASE_URL: publicBaseUrl,
    JWT_KEYS_DIR: keysDirectory,
    NOTE_ASR_PROVIDER: noteProvider,
    NOTE_ASR_MODEL: typeof source.NOTE_ASR_MODEL === 'string' ? source.NOTE_ASR_MODEL : '16k_zh',
    NOTE_ASR_PUBLIC_URL: notePublicUrl,
    MINIO_ENDPOINT: minioEndpoint,
    MINIO_CREDENTIALS_FILE: minioCredentialsFile,
    TENCENT_ASR_APP_ID: typeof source.TENCENT_ASR_APP_ID === 'string' ? source.TENCENT_ASR_APP_ID : '',
    TENCENT_ASR_SECRET_ID: typeof source.TENCENT_ASR_SECRET_ID === 'string' ? source.TENCENT_ASR_SECRET_ID : '',
    TENCENT_ASR_SECRET_KEY: typeof source.TENCENT_ASR_SECRET_KEY === 'string' ? source.TENCENT_ASR_SECRET_KEY : '',
    ASSISTANT_ATTACHMENTS_ENABLED: assistantAttachmentsEnabled === true || assistantAttachmentsEnabled === 'true',
    IMAGE_SYNC_ENABLED:
      imageSyncEnabled === true || imageSyncEnabled === 'true',
    DATABASE_URL: String(source.DATABASE_URL),
    NODE_ENV:
      typeof source.NODE_ENV === 'string' ? source.NODE_ENV : 'development',
    PORT: 3000,
    JWT_ISSUER: 'omni-butler',
    JWT_AUDIENCE: 'omni-butler-api',
    POWERSYNC_AUDIENCE: 'omni-butler-powersync',
    POWERSYNC_URL: powerSyncUrl,
    SYNC_SECRET: syncSecret,
    REFRESH_TOKEN_TTL_SECONDS: 30 * 24 * 60 * 60,
  };
}
