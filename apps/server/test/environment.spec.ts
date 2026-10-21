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
    expect(environment.IMAGE_SYNC_ENABLED).toBe(false);
    expect(environment.MINIO_ENDPOINT).toBe('http://minio:9000');
    expect(environment.MINIO_CREDENTIALS_FILE).toBe('/app/image-storage/credentials.json');
    expect(environment).not.toHaveProperty('NOTE_AUDIO_DIR');
    expect(environment.JWT_ISSUER).toBe('omni-butler');
    expect(environment.JWT_AUDIENCE).toBe('omni-butler-api');
    expect(environment.POWERSYNC_AUDIENCE).toBe('omni-butler-powersync');
    expect(environment.REFRESH_TOKEN_TTL_SECONDS).toBe(2592000);
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(true);
  });

  it('MCP可信入口规范化成明确origin，不受PowerSync独立地址影响', () => {
    // 授权入口与同步网关允许分别部署，但只信任显式地址。
    const environment = validateEnvironment({
      ...automaticEnvironment(),
      PUBLIC_BASE_URL: 'https://api.example.com',
      MCP_ALLOWED_ORIGINS: 'https://api.example.com/,http://192.168.1.10:3001',
    });
    expect(environment.PUBLIC_BASE_URL).toBe('https://api.example.com');
    expect(environment.MCP_ALLOWED_ORIGINS).toBe('https://api.example.com,http://192.168.1.10:3001');
  });

  it.each([
    '*', 'https://*.example.com', 'https://user:secret@example.com',
    'https://example.com/path', 'https://example.com?token=secret',
    'https://example.com#fragment', 'ftp://example.com', ' https://example.com',
  ])('MCP非法可信入口拒绝启动且不触碰密钥：%s', (origin) => {
    expect(() => validateEnvironment({ ...automaticEnvironment(), MCP_ALLOWED_ORIGINS: origin })).toThrow('MCP_ALLOWED_ORIGINS');
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
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
  it.each(['', 42, 'ftp://minio/', 'http://user:secret@minio:9000', 'http://minio:9000/bucket', 'http://minio:9000/?token=secret', ' http://minio:9000', 'http://minio:9000/#secret'])('拒绝不安全的MINIO_ENDPOINT配置：%s', (endpoint) => {
    expect(() => validateEnvironment({ ...automaticEnvironment(), MINIO_ENDPOINT: endpoint })).toThrow('MINIO_ENDPOINT');
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
  });
  it.each(['', 42, ' file.json', 'file.json\0'])('拒绝非法MINIO_CREDENTIALS_FILE：%s', (file) => {
    expect(() => validateEnvironment({ ...automaticEnvironment(), MINIO_CREDENTIALS_FILE: file })).toThrow('MINIO_CREDENTIALS_FILE');
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
    expect(environment).not.toHaveProperty('CORS_ORIGINS');
    expect(environment.REFRESH_TOKEN_TTL_SECONDS).toBe(2592000);
  });

  it('接受以斜杠结尾的 PowerSync 反向代理路径', () => {
    // PowerSync SDK 会在该目录下解析自己的同步接口。
    const environment = validateEnvironment({
      ...automaticEnvironment(),
      POWERSYNC_URL: 'https://butler.example.com/omni-butler/powersync/',
    });
    expect(environment.POWERSYNC_URL).toBe(
      'https://butler.example.com/omni-butler/powersync/',
    );
  });

  it.each([
    ['https://butler.example.com', 'https://butler.example.com'],
    ['https://butler.example.com/', 'https://butler.example.com'],
    ['https://butler.example.com:8443/', 'https://butler.example.com:8443'],
  ])('从公网根地址 %s 推导两个固定前缀', (base, origin) => {
    // Compose 未设置独立覆盖时传入空字符串。
    const environment = validateEnvironment({
      ...automaticEnvironment(), PUBLIC_BASE_URL: base,
      POWERSYNC_URL: '', NOTE_ASR_PUBLIC_URL: '',
    });
    expect(environment.POWERSYNC_URL).toBe(`${origin}/omni-butler/powersync/`);
    expect(environment.NOTE_ASR_PUBLIC_URL).toBe(`${origin}/omni-butler/api/v1`);
  });

  it.each([
    ['', '', 'https://butler.example.com/omni-butler/powersync/', 'https://butler.example.com/omni-butler/api/v1'],
    ['', '  ', 'https://butler.example.com/omni-butler/powersync/', 'https://butler.example.com/omni-butler/api/v1'],
    ['http://192.168.1.10:9080', '', 'http://192.168.1.10:9080', 'https://butler.example.com/omni-butler/api/v1'],
    ['', 'https://audio.example.com/omni-butler/api/v1/', 'https://butler.example.com/omni-butler/powersync/', 'https://audio.example.com/omni-butler/api/v1'],
    ['http://192.168.1.10:9080', 'https://audio.example.com/omni-butler/api/v1', 'http://192.168.1.10:9080', 'https://audio.example.com/omni-butler/api/v1'],
  ])('独立覆盖优先且空值使用推导：同步 %s，取音 %s', (sync, audio, expectedSync, expectedAudio) => {
    // 两个业务地址各自解析，不要求使用相同主机或协议。
    const environment = validateEnvironment({
      ...automaticEnvironment(), PUBLIC_BASE_URL: 'https://butler.example.com',
      POWERSYNC_URL: sync, NOTE_ASR_PUBLIC_URL: audio,
    });
    expect(environment.POWERSYNC_URL).toBe(expectedSync);
    expect(environment.NOTE_ASR_PUBLIC_URL).toBe(expectedAudio);
  });

  it('未配置公网根地址时保留局域网 HTTP 端口与内联识别', () => {
    // 旧部署仅配置同步地址，API 可以在另外的端口。
    const environment = validateEnvironment({
      ...automaticEnvironment(), PUBLIC_BASE_URL: '',
      POWERSYNC_URL: 'http://192.168.1.10:9080', NOTE_ASR_PUBLIC_URL: '',
    });
    expect(environment.POWERSYNC_URL).toBe('http://192.168.1.10:9080');
    expect(environment.NOTE_ASR_PUBLIC_URL).toBe('');
  });

  it('没有基础地址或有效同步覆盖时拒绝启动且不生成密钥', () => {
    expect(() => validateEnvironment({ ...automaticEnvironment(), POWERSYNC_URL: '' })).toThrow('POWERSYNC_URL');
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
    expect(existsSync(join(keysDirectory, 'jwt-public.pem'))).toBe(false);
  });

  it.each([
    42, 'http://butler.example.com', 'https://user:pass@butler.example.com',
    'https://@butler.example.com', 'https://butler.example.com/custom',
    'https://butler.example.com/path/../', 'https://butler.example.com//',
    'https://butler.example.com?token=value', 'https://butler.example.com?',
    'https://butler.example.com/#fragment', 'https://butler.example.com#',
    ' https://butler.example.com', 'https://butler.example.com ',
    'https://butler.example.com:invalid', 'https://', 'https://butler.\nexample.com',
  ])('非法基础地址 %s 即使有覆盖仍拒绝且不生成密钥', (base) => {
    expect(() => validateEnvironment({ ...automaticEnvironment(), PUBLIC_BASE_URL: base })).toThrow('PUBLIC_BASE_URL');
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
    expect(existsSync(join(keysDirectory, 'jwt-public.pem'))).toBe(false);
  });

  it.each([
    { POWERSYNC_URL: 'bad-url' }, { POWERSYNC_URL: ' ' }, { POWERSYNC_URL: 42 },
    { NOTE_ASR_PUBLIC_URL: 'bad-url' }, { NOTE_ASR_PUBLIC_URL: 'http://audio.example.com/omni-butler/api/v1' },
    { NOTE_ASR_PUBLIC_URL: '/' },
    { NOTE_ASR_PUBLIC_URL: 'https://audio.example.com/custom' },
    { NOTE_ASR_PUBLIC_URL: 'https://user:pass@audio.example.com/omni-butler/api/v1' },
    { NOTE_ASR_PUBLIC_URL: 'https://audio.example.com/omni-butler/api/v1?token=secret' },
    { NOTE_ASR_PUBLIC_URL: 'https://audio.example.com/omni-butler/api/v1#fragment' },
    { NOTE_ASR_PUBLIC_URL: 42 },
  ])('非法非空独立地址不得回退到基础地址：%j', (override) => {
    expect(() => validateEnvironment({ ...automaticEnvironment(), PUBLIC_BASE_URL: 'https://butler.example.com', ...override })).toThrow(/POWERSYNC_URL|NOTE_ASR_PUBLIC_URL/);
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
    expect(existsSync(join(keysDirectory, 'jwt-public.pem'))).toBe(false);
  });

  it.each([
    'https://butler.example.com/omni-butler/powersync',
    'https://butler.example.com/custom/powersync/',
    'ftp://butler.example.com/',
    'https://user:pass@butler.example.com/',
    'https://butler.example.com/?token=value',
    ' https://butler.example.com/',
  ])('拒绝无法安全解析同步端点的 POWERSYNC_URL：%s', (powerSyncUrl) => {
    expect(() =>
      validateEnvironment({
        ...automaticEnvironment(),
        POWERSYNC_URL: powerSyncUrl,
      }),
    ).toThrow('POWERSYNC_URL');
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

  it('单一图片开关接受true且不要求用户对象存储配置', () => {
    expect(
      validateEnvironment({
        ...automaticEnvironment(),
        IMAGE_SYNC_ENABLED: 'true',
      }).IMAGE_SYNC_ENABLED,
    ).toBe(true);
  });

  it('图片开关拼写错误时拒绝启动且不生成密钥', () => {
    expect(() =>
      validateEnvironment({
        ...automaticEnvironment(),
        IMAGE_SYNC_ENABLED: 'yes',
      }),
    ).toThrow('IMAGE_SYNC_ENABLED');
    expect(existsSync(join(keysDirectory, 'jwt-private.pem'))).toBe(false);
  });
});
