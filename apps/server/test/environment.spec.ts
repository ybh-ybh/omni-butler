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
});
