import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
} from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/// 从持久化目录加载或生成 RSA 密钥，并从公钥计算稳定标识。
export function resolveJwtKeys(directory: string): {
  /// 公钥摘要标识。
  JWT_KEY_ID: string;
  /// 供签发服务使用的私钥 Base64。
  JWT_PRIVATE_KEY_BASE64: string;
  /// 供验签服务使用的公钥 Base64。
  JWT_PUBLIC_KEY_BASE64: string;
} {
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
  // 从同一个私钥推导的公钥。
  const publicKey = createPublicKey(privateKey);
  // 用于现有签发与验签服务的公钥 PEM。
  const publicKeyPem = publicKey.export({
    type: 'spki',
    format: 'pem',
  });
  // 基于公钥标准 DER 编码计算标识，重启不变、换钥时自动变化。
  const keyId = createHash('sha256')
    .update(publicKey.export({ type: 'spki', format: 'der' }))
    .digest('base64url');
  return {
    JWT_KEY_ID: keyId,
    JWT_PRIVATE_KEY_BASE64: Buffer.from(privateKeyPem).toString('base64'),
    JWT_PUBLIC_KEY_BASE64: Buffer.from(publicKeyPem).toString('base64'),
  };
}
