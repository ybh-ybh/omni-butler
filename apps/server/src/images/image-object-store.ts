import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  DeleteObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { MinioConnection } from '../storage/minio-connection';

/// 固定私有桶，只由后端代理访问。
export const IMAGE_BUCKET = 'omni-butler-images';

/// 可替换的对象存储边界，测试无需修改生产环境变量。
export abstract class ImageObjectStore {
  /// 存储不可变对象。
  abstract put(key: string, bytes: Buffer, mime: string): Promise<void>;
  /// 获取已授权对象。
  abstract get(key: string): Promise<Buffer>;
  /// 幂等清理孤立对象。
  abstract delete(key: string): Promise<void>;
}

/// 通过 Docker 内网访问内置 MinIO，关闭时不读取凭证、不连接存储。
@Injectable()
export class MinioImageObjectStore extends ImageObjectStore {
  /// 注入应用唯一图片开关。
  constructor(private readonly config: ConfigService, private readonly connection: MinioConnection) {
    super();
  }

  /// 读取部署自动生成的私有凭证并确保桶存在。
  private async connect(): Promise<S3Client> {
    if (!this.config.get<boolean>('IMAGE_SYNC_ENABLED'))
      throw new Error('图片同步未启用');
    return this.connection.forBucket(IMAGE_BUCKET);
  }
  /// 图片对象仅允许后端生成的归属、操作和对象三个UUID。
  private validateKey(key: string): void {
    if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}(\/[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}){2}$/.test(key)) throw new Error('非法图片对象键');
  }

  /// 写入经校验的原文件，并提供真实 MIME。
  async put(key: string, bytes: Buffer, mime: string): Promise<void> {
    this.validateKey(key);
    // 共享内部连接。
    const client = await this.connect();
    await client.send(
      new PutObjectCommand({
        Bucket: IMAGE_BUCKET,
        Key: key,
        Body: bytes,
        ContentType: mime,
      }),
      { abortSignal: AbortSignal.timeout(60000) },
    );
  }

  /// 将单张受大小限制的图片读入响应缓冲区。
  async get(key: string): Promise<Buffer> {
    this.validateKey(key);
    // 共享内部连接。
    const client = await this.connect();
    // 对象读取结果。
    const result = await client.send(
      new GetObjectCommand({ Bucket: IMAGE_BUCKET, Key: key }),
      { abortSignal: AbortSignal.timeout(60000) },
    );
    if (!result.Body) throw new Error('图片对象为空');
    return Buffer.from(await result.Body.transformToByteArray());
  }

  /// 删除不存在的键也视为成功。
  async delete(key: string): Promise<void> {
    this.validateKey(key);
    // 共享内部连接。
    const client = await this.connect();
    await client.send(
      new DeleteObjectCommand({ Bucket: IMAGE_BUCKET, Key: key }),
      { abortSignal: AbortSignal.timeout(10000) },
    );
  }

}
