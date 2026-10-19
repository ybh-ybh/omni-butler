import { Injectable, ServiceUnavailableException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { closeSync, constants, existsSync, fsyncSync, linkSync, mkdirSync, openSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/// 模型密钥单独加密，持久目录与 JWT 共卷但不复用 JWT 私钥。
@Injectable()
export class AiKeyStore {
  /// 当前进程缓存独立加密密钥，避免每次请求读取磁盘。
  private key: Buffer | undefined;
  /// 配置仅决定文件目录，密钥不从请求输入取得。
  constructor(private readonly config: ConfigService) {}

  /// 认证加密同时保护密文完整性，数据库不保存明文 Key。
  encrypt(value: string): string {
    // 每次加密都使用新的随机 nonce。
    const nonce = randomBytes(12);
    // AES-GCM 加密器绑定独立持久密钥。
    const cipher = createCipheriv('aes-256-gcm', this.load(), nonce);
    // 密文与认证标签一起保存，固定版本便于后续迁移。
    const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
    return ['v1', nonce.toString('base64'), cipher.getAuthTag().toString('base64'), encrypted.toString('base64')].join('.');
  }

  /// 密钥丢失或损坏必须明确报错，禁止把解密失败解释为未配置。
  decrypt(value: string): string {
    try {
      // 固定密文结构，异常不回显输入。
      const parts = value.split('.');
      if (parts.length !== 4 || parts[0] !== 'v1') throw new Error('invalid');
      // 必须先验证 GCM 标签，再返回解密后的完整内容。
      const decipher = createDecipheriv('aes-256-gcm', this.load(false), Buffer.from(parts[1]!, 'base64'));
      decipher.setAuthTag(Buffer.from(parts[2]!, 'base64'));
      return Buffer.concat([decipher.update(Buffer.from(parts[3]!, 'base64')), decipher.final()]).toString('utf8');
    } catch {
      throw new ServiceUnavailableException({ code: 'AI_KEY_DECRYPTION_FAILED', message: '模型密钥无法解密，请恢复 api-keys 卷或重新配置 API Key' });
    }
  }

  /// 完整临时文件通过原子硬链接发布，多个实例不会读取半份密钥。
  private load(createIfMissing = true): Buffer {
    if (this.key) return this.key;
    try {
      // 沿用现有部署卷目录，开发使用已忽略目录。
      const directory = this.config.get<string>('JWT_KEYS_DIR') || '.local/keys';
      if (createIfMissing) mkdirSync(directory, { recursive: true, mode: 0o700 });
      // 唯一固定文件名与 JWT 文件明确分开。
      const path = join(directory, 'ai-encryption-key-v1');
      if (!existsSync(path)) {
        // 解密历史密文不能生成替代密钥，必须由用户恢复原卷或主动重新配置。
        if (!createIfMissing) throw new Error('missing');
        // 临时文件只属于当前进程，创建后立即写完再发布。
        const temporary = `${path}.${process.pid}.${randomBytes(8).toString('hex')}.tmp`;
        // 独占方式禁止覆盖任何既有文件。
        const descriptor = openSync(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
        try { writeFileSync(descriptor, randomBytes(32)); fsyncSync(descriptor); } finally { closeSync(descriptor); }
        try { linkSync(temporary, path); } catch (error: unknown) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; } finally { unlinkSync(temporary); }
      }
      // 长度不符意味着损坏，不能静默重新生成造成旧密文不可恢复。
      const key = readFileSync(path);
      if (key.length !== 32) throw new Error('invalid');
      this.key = key;
      return key;
    } catch {
      throw new ServiceUnavailableException({ code: 'AI_KEY_STORAGE_FAILED', message: 'AI 独立加密密钥无法读取，请检查 api-keys 持久卷' });
    }
  }
}
