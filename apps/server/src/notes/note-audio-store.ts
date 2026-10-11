import { Injectable } from '@nestjs/common';
import { DeleteObjectCommand, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { MinioConnection } from '../storage/minio-connection';

/// 原音独立私有桶，不受图片同步开关影响。
export const NOTE_AUDIO_BUCKET = 'omni-butler-note-audio';

/// 原音存储边界，厂商及HTTP接口不依赖具体对象存储。
export abstract class NoteAudioStore {
  /// 存储完整文件体和经过验证的MIME。
  abstract put(key: string, bytes: Buffer, mime: string): Promise<void>;
  /// 读取授权后的完整文件。
  abstract get(key: string): Promise<Buffer>;
  /// 幂等清理文件。
  abstract delete(key: string): Promise<void>;
}

/// 生产原音始终使用MinIO，失败由上层重试，绝不落入本机目录。
@Injectable()
export class MinioNoteAudioStore extends NoteAudioStore {
  /// 复用部署的私有连接及独立原音桶。
  constructor(private readonly connection: MinioConnection) { super(); }

  /// 只允许后端生成的两个UUID和摘要键，不接受任意对象路径。
  private validateKey(key: string): void {
    if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}\/[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}\/[a-f0-9]{64}$/.test(key)) throw new Error('非法原音对象键');
  }

  /// 原子上传完整对象，不暴露公共访问权限。
  async put(key: string, bytes: Buffer, mime: string): Promise<void> {
    this.validateKey(key);
    // 已初始化为私有访问的共享客户端。
    const client = await this.connection.forBucket(NOTE_AUDIO_BUCKET);
    await client.send(new PutObjectCommand({ Bucket: NOTE_AUDIO_BUCKET, Key: key, Body: bytes, ContentType: mime }), { abortSignal: AbortSignal.timeout(60000) });
  }

  /// 读取受服务端大小限制的原音，Range响应仍由已有HTTP控制器生成。
  async get(key: string): Promise<Buffer> {
    this.validateKey(key);
    // 原音桶的私有连接。
    const client = await this.connection.forBucket(NOTE_AUDIO_BUCKET);
    // S3对象响应必须包含文件体。
    const result = await client.send(new GetObjectCommand({ Bucket: NOTE_AUDIO_BUCKET, Key: key }), { abortSignal: AbortSignal.timeout(60000) });
    if (!result.Body) throw new Error('原音对象为空');
    return Buffer.from(await result.Body.transformToByteArray());
  }

  /// 持久GC回执授权后删除，不存在对象也视为成功。
  async delete(key: string): Promise<void> {
    this.validateKey(key);
    // 使用相同私有桶，不跨入图片对象空间。
    const client = await this.connection.forBucket(NOTE_AUDIO_BUCKET);
    await client.send(new DeleteObjectCommand({ Bucket: NOTE_AUDIO_BUCKET, Key: key }), { abortSignal: AbortSignal.timeout(10000) });
  }
}
