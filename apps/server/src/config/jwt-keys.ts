import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
} from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/// 在配置了持久化目录且未手工配置密钥时，加载或生成 RSA 密钥。
export function resolveJwtKeys(
  source: Record<string, unknown>,
): Record<string, unknown> {
  // 手工填写的密钥优先；只填写一项时交由环境校验报错。
  const hasManualKey = [
    source.JWT_PRIVATE_KEY_BASE64,
    source.JWT_PUBLIC_KEY_BASE64,
  ].some((value) => typeof value === 'string' && value.trim().length > 0);
  // 自动生成密钥所用的持久化目录。
  const directory = source.JWT_KEYS_DIR;
  if (hasManualKey || typeof directory !== 'string' || !directory.trim()) {
    return source;
  }

  mkdirSync(directory, { recursive: true, mode: 0o700 });
  // 仅保存私钥，公钥由私钥推导，避免两个文件不一致。
  const privateKeyPath = join(directory, 'jwt-private.pem');
  // 本次启动使用的私钥 PEM。
  let privateKeyPem: string;
  try {
    privateKeyPem = readFileSync(privateKeyPath, 'utf8');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      throw error;
    }
    // 首次启动生成的 RSA 私钥，不写入日志或镜像。
    const { privateKey } = generateKeyPairSync('rsa', {
      modulusLength: 3072,
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    });
    try {
      writeFileSync(privateKeyPath, privateKey, { flag: 'wx', mode: 0o600 });
    } catch (writeError) {
      // 并发启动时沿用已创建的文件，不覆盖另一实例的密钥。
      if ((writeError as NodeJS.ErrnoException).code !== 'EEXIST') {
        throw writeError;
      }
    }
    privateKeyPem = readFileSync(privateKeyPath, 'utf8');
  }
  // 校验磁盘私钥；损坏时停止启动，避免静默换钥。
  const privateKey = createPrivateKey(privateKeyPem);
  if (privateKey.asymmetricKeyType !== 'rsa') {
    throw new Error('持久化 JWT 私钥必须是 RSA 密钥');
  }
  // 从同一个私钥推导的公钥 PEM。
  const publicKeyPem = createPublicKey(privateKey).export({
    type: 'spki',
    format: 'pem',
  });
  return {
    ...source,
    JWT_PRIVATE_KEY_BASE64: Buffer.from(privateKeyPem).toString('base64'),
    JWT_PUBLIC_KEY_BASE64: Buffer.from(publicKeyPem).toString('base64'),
  };
}
