import { createPublicKey, sign, verify } from 'node:crypto';
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
    JWT_PRIVATE_KEY_BASE64: 'private',
    JWT_PUBLIC_KEY_BASE64: 'public',
    JWT_KEY_ID: 'key-1',
    JWT_ISSUER: 'https://api.example.com',
    JWT_AUDIENCE: 'omni-api',
    POWERSYNC_AUDIENCE: 'omni-sync',
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

  /// 构造与 Compose 留空密钥时一致的环境变量。
  function automaticEnvironment(): Record<string, unknown> {
    return {
      ...validEnvironment(),
      JWT_PRIVATE_KEY_BASE64: '',
      JWT_PUBLIC_KEY_BASE64: '',
      JWT_KEYS_DIR: keysDirectory,
    };
  }

  it('为端口与刷新令牌周期填充安全默认值', () => {
    // 已规范化环境变量。
    const environment = validateEnvironment(validEnvironment());

    expect(environment.PORT).toBe(3000);
    expect(environment.REFRESH_TOKEN_TTL_SECONDS).toBe(2592000);
  });

  it('缺少 JWT 公钥时拒绝启动', () => {
    // 缺少公钥的环境变量。
    const source = validEnvironment();
    delete source.JWT_PUBLIC_KEY_BASE64;

    expect(() => validateEnvironment(source)).toThrow(
      '缺少必填环境变量：JWT_PUBLIC_KEY_BASE64',
    );
  });

  it('同步密钥短于十六个字符时拒绝启动', () => {
    // 使用过短同步密钥的环境变量。
    const source = validEnvironment();
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
    expect(createPublicKey(publicKey).asymmetricKeyDetails?.modulusLength).toBe(
      3072,
    );
    expect(verify('RSA-SHA256', message, publicKey, signature)).toBe(true);
    expect(readFileSync(join(keysDirectory, 'jwt-private.pem'))).toEqual(
      privateKey,
    );
  });

  it('已手工配置密钥时保持原值且不生成文件', () => {
    // 手工配置和自动生成目录同时存在。
    const environment = validateEnvironment({
      ...validEnvironment(),
      JWT_KEYS_DIR: keysDirectory,
    });

    expect(environment.JWT_PRIVATE_KEY_BASE64).toBe('private');
    expect(environment.JWT_PUBLIC_KEY_BASE64).toBe('public');
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
  });

  it.each(['JWT_PRIVATE_KEY_BASE64', 'JWT_PUBLIC_KEY_BASE64'])(
    '只手工配置 %s 时拒绝自动补齐密钥',
    (key) => {
      // 只设置一项的手工密钥。
      const source = automaticEnvironment();
      source[key] = 'manual-key';

      expect(() => validateEnvironment(source)).toThrow(
        '缺少必填环境变量：JWT_',
      );
      expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
    },
  );

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
