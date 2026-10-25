import { Injectable } from '@nestjs/common';
import {
  DeleteObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
} from '@aws-sdk/client-s3';
import { MinioConnection } from '../../storage/minio-connection';
import { ATTACHMENT_LIMITS } from './attachment.types';

/// 附件与业务图片分桶隔离，客户端只能经过授权API下载。
export const ATTACHMENT_BUCKET = 'omni-butler-assistant-attachments';

/// 可替换的外部存储边界便于测试事务与清理行为。
export abstract class AttachmentObjectStore {
  /// 保存不可变原件或单次解析产物。
  abstract put(key: string, bytes: Buffer, mimeType: string): Promise<void>;
  /// 获取有界私有对象。
  abstract get(key: string): Promise<Buffer>;
  /// 幂等删除明确对象键。
  abstract delete(key: string): Promise<void>;
}

/// 复用现有凭据、连接与私有桶初始化。
@Injectable()
export class MinioAttachmentObjectStore extends AttachmentObjectStore {
  /// 共享内部MinIO连接，不新增凭据配置。
  constructor(private readonly connection: MinioConnection) {
    super();
  }

  /// 对象键只接受服务器生成的三个UUID和固定产物名。
  private validate(key: string): void {
    // 格式校验阻止路径或任意桶对象访问。
    const uuid =
      '[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}';
    if (
      !new RegExp(
        `^${uuid}/${uuid}/${uuid}/(?:original|manifest\\.json|image-[0-9]{1,3}\\.jpg)$`,
      ).test(key)
    )
      throw new Error('非法附件对象键');
  }

  /// 每次网络操作都有独立时限，不产生无界后台任务。
  async put(key: string, bytes: Buffer, mimeType: string): Promise<void> {
    this.validate(key);
    if (bytes.length > ATTACHMENT_LIMITS.maxFileBytes)
      throw new Error('附件对象超限');
    // 固定桶由连接层确保私有。
    const client = await this.connection.forBucket(ATTACHMENT_BUCKET);
    await client.send(
      new PutObjectCommand({
        Bucket: ATTACHMENT_BUCKET,
        Key: key,
        Body: bytes,
        ContentType: mimeType,
      }),
      { abortSignal: AbortSignal.timeout(15000) },
    );
  }

  /// 流式累计时同步检查上限，不能仅信任ContentLength。
  async get(key: string): Promise<Buffer> {
    this.validate(key);
    // 固定桶连接。
    const client = await this.connection.forBucket(ATTACHMENT_BUCKET);
    // 读取响应只在完成授权后触发。
    const result = await client.send(
      new GetObjectCommand({ Bucket: ATTACHMENT_BUCKET, Key: key }),
      { abortSignal: AbortSignal.timeout(15000) },
    );
    if (
      !result.Body ||
      (result.ContentLength ?? 0) > ATTACHMENT_LIMITS.maxFileBytes
    )
      throw new Error('附件对象无效');
    // 有界读取缓冲。
    const chunks: Buffer[] = [];
    // 实际字节总数。
    let size = 0;
    for await (const chunk of result.Body as AsyncIterable<Uint8Array>) {
      size += chunk.length;
      if (size > ATTACHMENT_LIMITS.maxFileBytes)
        throw new Error('附件对象超限');
      chunks.push(Buffer.from(chunk));
    }
    return Buffer.concat(chunks);
  }

  /// 仅删除持久清理任务里登记的固定键。
  async delete(key: string): Promise<void> {
    this.validate(key);
    // 删除不存在对象也是成功。
    const client = await this.connection.forBucket(ATTACHMENT_BUCKET);
    await client.send(
      new DeleteObjectCommand({ Bucket: ATTACHMENT_BUCKET, Key: key }),
      { abortSignal: AbortSignal.timeout(10000) },
    );
  }
}
