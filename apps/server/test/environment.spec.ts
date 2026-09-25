import { createHash, createPublicKey, sign, verify } from 'node:crypto';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { validateEnvironment } from '../src/config/environment';

/// 构造最小有效环境变量。
function validEnvironment(): Record<string, unknown> {
  return {
    DATABASE_URL: 'postgresql://user:pass@localhost:5432/app',
    POWERSYNC_URL: 'https://sync.example.com',
    SYNC_SECRET: 'a-secure-sync-key',
  };
}

/// 启动环境校验测试。
describe('validateEnvironment', () => {
  // 每个测试独立使用临时目录，避免读写实际部署密钥。
  let keysDirectory: string;

  beforeEach(() => {
    keysDirectory = mkdtempSync(join(tmpdir(), 'omni-jwt-test-'));
  });

  afterEach(() => {
    rmSync(keysDirectory, { recursive: true, force: true });
  });

  /// 使用与 Compose 一致的输入，并将密钥隔离到临时目录。
  function automaticEnvironment(): Record<string, unknown> {
    return {
      ...validEnvironment(),
      JWT_KEYS_DIR: keysDirectory,
    };
  }

  it('只提供必要参数即可生成密钥并使用固定的服务约定', () => {
    // 已规范化环境变量。
    const environment = validateEnvironment(automaticEnvironment());

    expect(environment.PORT).toBe(3000);
    expect(environment.API_PREFIX).toBe('api/v1');
    expect(environment.JWT_ISSUER).toBe('omni-butler');
    expect(environment.JWT_AUDIENCE).toBe('omni-butler-api');
    expect(environment.POWERSYNC_AUDIENCE).toBe('omni-butler-powersync');
    expect(environment.REFRESH_TOKEN_TTL_SECONDS).toBe(2592000);
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(true);
  });

  it.each(['DATABASE_URL', 'POWERSYNC_URL', 'SYNC_SECRET'])(
    '缺少 %s 时拒绝启动且不生成密钥',
    (key) => {
      // 缺少一项必要参数的输入。
      const source = automaticEnvironment();
      delete source[key];

      expect(() => validateEnvironment(source)).toThrow(
        `缺少必填环境变量：${key}`,
      );
      expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
    },
  );

  it('同步密钥短于十六个字符时拒绝启动', () => {
    // 使用过短同步密钥的环境变量。
    const source = automaticEnvironment();
    source.SYNC_SECRET = 'too-short';

    expect(() => validateEnvironment(source)).toThrow(
      'SYNC_SECRET 至少需要 16 个字符',
    );
  });

  it('首次生成可用 RSA 密钥，重启后仍能验证先前签名', () => {
    // 首次启动得到的环境配置。
    const first = validateEnvironment(automaticEnvironment());
    // 用于签名的私钥与待签名数据。
    const privateKey = Buffer.from(first.JWT_PRIVATE_KEY_BASE64, 'base64');
    // 模拟令牌签名内容。
    const message = Buffer.from('device-session');
    // 首次启动签发的签名。
    const signature = sign('RSA-SHA256', message, privateKey);
    // 模拟重启后从磁盘恢复配置。
    const restarted = validateEnvironment(automaticEnvironment());
    // 重启后发布给客户端的公钥。
    const publicKey = Buffer.from(restarted.JWT_PUBLIC_KEY_BASE64, 'base64');

    expect(restarted.JWT_PRIVATE_KEY_BASE64).toBe(first.JWT_PRIVATE_KEY_BASE64);
    expect(restarted.JWT_PUBLIC_KEY_BASE64).toBe(first.JWT_PUBLIC_KEY_BASE64);
    expect(restarted.JWT_KEY_ID).toBe(first.JWT_KEY_ID);
    expect(first.JWT_KEY_ID).toBe(
      createHash('sha256')
        .update(
          createPublicKey(publicKey).export({ type: 'spki', format: 'der' }),
        )
        .digest('base64url'),
    );
    expect(createPublicKey(publicKey).asymmetricKeyDetails?.modulusLength).toBe(
      3072,
    );
    expect(verify('RSA-SHA256', message, publicKey, signature)).toBe(true);
    expect(readFileSync(join(keysDirectory, 'jwt-private.pem'))).toEqual(
      privateKey,
    );
  });

  it('不再读取已删除的手工密钥和可调服务参数', () => {
    // 模拟外部仍注入旧参数，不能覆盖当前固定约定和持久化密钥。
    const environment = validateEnvironment({
      ...automaticEnvironment(),
      JWT_PRIVATE_KEY_BASE64: 'private',
      JWT_PUBLIC_KEY_BASE64: 'public',
      JWT_KEY_ID: 'old-key',
      JWT_ISSUER: 'old-issuer',
      JWT_AUDIENCE: 'old-api',
      POWERSYNC_AUDIENCE: 'old-sync',
      PORT: 9000,
      CORS_ORIGINS: '*',
      REFRESH_TOKEN_TTL_SECONDS: 3600,
    });

    expect(environment.JWT_PRIVATE_KEY_BASE64).not.toBe('private');
    expect(environment.JWT_PUBLIC_KEY_BASE64).not.toBe('public');
    expect(environment.JWT_KEY_ID).not.toBe('old-key');
    expect(environment.JWT_ISSUER).toBe('omni-butler');
    expect(environment.JWT_AUDIENCE).toBe('omni-butler-api');
    expect(environment.POWERSYNC_AUDIENCE).toBe('omni-butler-powersync');
    expect(environment.PORT).toBe(3000);
    expect(environment.API_PREFIX).toBe('api/v1');
    expect(environment).not.toHaveProperty('CORS_ORIGINS');
    expect(environment.REFRESH_TOKEN_TTL_SECONDS).toBe(2592000);
  });

  it('采用配置的 API 路径前缀', () => {
    // 自定义多级路径应直接用于路由、文档和健康检查。
    const environment = validateEnvironment({
      ...automaticEnvironment(),
      API_PREFIX: 'butler-api/v2_private',
    });
    expect(environment.API_PREFIX).toBe('butler-api/v2_private');
  });

  it.each([
    '',
    '/api/v2',
    'api/v2/',
    'api//v2',
    '../api',
    'api?x=1',
    'api#x',
    'api/*',
    'api/:id',
    'api/%2f',
    ' api',
    'api/v1\n',
    42,
  ])('拒绝非法 API 前缀 %s，且不生成密钥', (apiPrefix) => {
    expect(() =>
      validateEnvironment({
        ...automaticEnvironment(),
        API_PREFIX: apiPrefix,
      }),
    ).toThrow('API_PREFIX');
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
  });

  it('不同部署生成不同的密钥标识', () => {
    // 首个部署的持久化密钥。
    const first = validateEnvironment(automaticEnvironment());
    // 第二个部署使用独立目录。
    const second = validateEnvironment({
      ...automaticEnvironment(),
      JWT_KEYS_DIR: join(keysDirectory, 'second-deployment'),
    });

    expect(second.JWT_KEY_ID).not.toBe(first.JWT_KEY_ID);
    expect(second.JWT_PUBLIC_KEY_BASE64).not.toBe(first.JWT_PUBLIC_KEY_BASE64);
  });

  it('已有密钥损坏时拒绝启动且不覆盖文件', () => {
    // 模拟损坏或不完整的持久化私钥。
    const keyPath = join(keysDirectory, 'jwt-private.pem');
    writeFileSync(keyPath, 'broken-key');

    expect(() => validateEnvironment(automaticEnvironment())).toThrow();
    expect(readFileSync(keyPath, 'utf8')).toBe('broken-key');
  });

  it('目录不可用时拒绝启动，不回退到临时密钥', () => {
    // 用普通文件模拟无法作为目录使用的存储位置。
    const blockedPath = join(keysDirectory, 'blocked');
    writeFileSync(blockedPath, 'not-a-directory');

    expect(() =>
      validateEnvironment({
        ...automaticEnvironment(),
        JWT_KEYS_DIR: blockedPath,
      }),
    ).toThrow();
  });

  it('其他配置校验失败时不生成密钥', () => {
    expect(() =>
      validateEnvironment({ ...automaticEnvironment(), SYNC_SECRET: 'short' }),
    ).toThrow('SYNC_SECRET 至少需要 16 个字符');
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
  });
});
