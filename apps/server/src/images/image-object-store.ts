import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  CreateBucketCommand,
  DeleteObjectCommand,
  GetObjectCommand,
  HeadBucketCommand,
  PutObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { readFile } from 'node:fs/promises';

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
export class MinioImageObjectStore
  extends ImageObjectStore
  implements OnModuleDestroy
{
  /// 首次使用时懒加载初始化任务，失败后允许重试。
  private ready: Promise<S3Client> | undefined;
  /// 生命周期内复用的客户端。
  private client: S3Client | undefined;

  /// 注入应用唯一图片开关。
  constructor(private readonly config: ConfigService) {
    super();
  }

  /// 读取部署自动生成的私有凭证并确保桶存在。
  private async connect(): Promise<S3Client> {
    if (!this.config.get<boolean>('IMAGE_SYNC_ENABLED'))
      throw new Error('图片同步未启用');
    if (!this.ready) {
      this.ready = this.initialize().catch((error: unknown) => {
        this.ready = undefined;
        throw error;
      });
    }
    return this.ready;
  }

  /// 建立内部连接；桶创建冲突可由其他 API 副本先行完成。
  private async initialize(): Promise<S3Client> {
    // 系统生成并持久化在私有卷内的凭证。
    const credentials = JSON.parse(
      await readFile('/app/image-storage/credentials.json', 'utf8'),
    ) as { accessKeyId: string; secretAccessKey: string };
    this.client?.destroy();
    this.client = new S3Client({
      endpoint: 'http://minio:9000',
      region: 'us-east-1',
      forcePathStyle: true,
      credentials,
      maxAttempts: 2,
    });
    try {
      await this.client.send(new HeadBucketCommand({ Bucket: IMAGE_BUCKET }), {
        abortSignal: AbortSignal.timeout(15000),
      });
    } catch {
      try {
        await this.client.send(
          new CreateBucketCommand({ Bucket: IMAGE_BUCKET }),
          { abortSignal: AbortSignal.timeout(15000) },
        );
      } catch {
        await this.client.send(
          new HeadBucketCommand({ Bucket: IMAGE_BUCKET }),
          { abortSignal: AbortSignal.timeout(15000) },
        );
      }
    }
    return this.client;
  }

  /// 写入经校验的原文件，并提供真实 MIME。
  async put(key: string, bytes: Buffer, mime: string): Promise<void> {
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
    // 共享内部连接。
    const client = await this.connect();
    await client.send(
      new DeleteObjectCommand({ Bucket: IMAGE_BUCKET, Key: key }),
      { abortSignal: AbortSignal.timeout(10000) },
    );
  }

  /// 停机时释放连接池。
  onModuleDestroy(): void {
    this.client?.destroy();
  }
}
