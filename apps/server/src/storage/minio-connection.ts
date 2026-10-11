import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { CreateBucketCommand, DeleteBucketPolicyCommand, HeadBucketCommand, S3Client } from '@aws-sdk/client-s3';
import { readFile } from 'node:fs/promises';

/// 图片与笔记共用懒加载客户端，每个固定桶独立初始化为私有访问。
@Injectable()
export class MinioConnection implements OnModuleDestroy {
  /// 生命周期内唯一连接客户端。
  private client: S3Client | undefined;
  /// 懒加载凭证失败后允许重新读取。
  private ready: Promise<S3Client> | undefined;
  /// 每个桶的初始化任务防止同实例并发重复创建。
  private readonly buckets = new Map<string, Promise<void>>();
  /// 停机后不能重新创建连接池。
  private stopping = false;

  /// 配置只提供内部端点与私有凭证文件路径，不直接携带密钥。
  constructor(private readonly config: ConfigService) {}

  /// 读取部署生成的凭证，关闭图片同步时笔记仍可独立调用。
  private async initialize(): Promise<S3Client> {
    // 私有凭证内容不写入日志、异常消息或HTTP回执。
    let credentials: unknown;
    try { credentials = JSON.parse(await readFile(this.config.get<string>('MINIO_CREDENTIALS_FILE') ?? '/app/image-storage/credentials.json', 'utf8')); }
    catch { throw new Error('MinIO 凭证文件无法读取或解析'); }
    if (!credentials || typeof credentials !== 'object' || !('accessKeyId' in credentials) || !('secretAccessKey' in credentials) || typeof credentials.accessKeyId !== 'string' || !credentials.accessKeyId.trim() || typeof credentials.secretAccessKey !== 'string' || !credentials.secretAccessKey.trim()) throw new Error('MinIO 凭证文件结构无效');
    if (this.stopping) throw new Error('对象存储连接正在关闭');
    this.client = new S3Client({ endpoint: this.config.get<string>('MINIO_ENDPOINT') ?? 'http://minio:9000', region: 'us-east-1', forcePathStyle: true, credentials: { accessKeyId: credentials.accessKeyId, secretAccessKey: credentials.secretAccessKey }, maxAttempts: 2 });
    return this.client;
  }

  /// 确保内部固定桶存在，移除匿名策略后才返回可用连接。
  async forBucket(bucket: string): Promise<S3Client> {
    if (!['omni-butler-images', 'omni-butler-note-audio'].includes(bucket)) throw new Error('不支持的私有存储桶');
    if (this.stopping) throw new Error('对象存储连接正在关闭');
    if (!this.ready) this.ready = this.initialize().catch((error: unknown) => { this.ready = undefined; throw error; });
    // 同一连接由两个领域共享，无需为每个文件读取凭证。
    const client = await this.ready;
    if (!this.buckets.has(bucket)) {
      // 初始化失败不缓存失败状态，下一次使用可恢复连接或建桶。
      const ready = this.ensurePrivateBucket(client, bucket).catch((error: unknown) => { this.buckets.delete(bucket); throw error; });
      this.buckets.set(bucket, ready);
    }
    await this.buckets.get(bucket);
    return client;
  }

  /// 建桶竞争允许其他实例先完成，但无权限或断连不能伪装成成功。
  private async ensurePrivateBucket(client: S3Client, bucket: string): Promise<void> {
    try { await client.send(new HeadBucketCommand({ Bucket: bucket }), { abortSignal: AbortSignal.timeout(15000) }); }
    catch {
      try { await client.send(new CreateBucketCommand({ Bucket: bucket }), { abortSignal: AbortSignal.timeout(15000) }); }
      catch { await client.send(new HeadBucketCommand({ Bucket: bucket }), { abortSignal: AbortSignal.timeout(15000) }); }
    }
    await client.send(new DeleteBucketPolicyCommand({ Bucket: bucket }), { abortSignal: AbortSignal.timeout(15000) });
  }

  /// 应用退出释放共享连接池，各领域不重复销毁客户端。
  onModuleDestroy(): void { if (this.stopping) return; this.stopping = true; this.client?.destroy(); }
}
