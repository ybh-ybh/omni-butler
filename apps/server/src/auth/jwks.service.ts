import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createPublicKey, type JsonWebKey } from 'node:crypto';

/// JSON Web Key Set 返回结构。
interface JsonWebKeySet {
  /// 可用于验签的公开密钥。
  keys: JsonWebKey[];
}

/// 将 RSA 公钥转换为 PowerSync 可读取的 JWKS。
@Injectable()
export class JwksService {
  /// 注入环境配置。
  constructor(private readonly config: ConfigService) {}

  /// 返回当前 RS256 公钥集合。
  getKeys(): JsonWebKeySet {
    // RSA 公钥 PEM。
    const publicKeyPem = Buffer.from(
      this.config.getOrThrow<string>('JWT_PUBLIC_KEY_BASE64'),
      'base64',
    ).toString('utf8');
    // Node.js 导出的公开 JWK。
    const exported = createPublicKey(publicKeyPem).export({ format: 'jwk' });
    // 带算法与用途元数据的公开 JWK。
    const key: JsonWebKey = {
      ...exported,
      kid: this.config.getOrThrow<string>('JWT_KEY_ID'),
      alg: 'RS256',
      use: 'sig',
    };
    return { keys: [key] };
  }
}
