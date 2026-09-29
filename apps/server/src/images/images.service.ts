import {
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  NotFoundException,
  OnModuleDestroy,
  OnModuleInit,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, randomUUID } from 'node:crypto';
// eslint-disable-next-line @typescript-eslint/no-require-imports -- 当前编译模式未启用 esModuleInterop，Sharp 使用 CommonJS 导出。
import sharp = require('sharp');
import type { AuthUser } from '../auth/auth.types';
import type { BusinessImage, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { ImageObjectStore } from './image-object-store';
import type { ImageRemoveDto, ImageUploadDto } from './image.dto';

/// 单张图片的明确上限。
export const IMAGE_MAX_BYTES = 20 * 1024 * 1024;
/// 客户端能够同步的业务图片类型。
export type ImageBusinessType = 'inventoryImage' | 'membershipImage';
/// 不暴露内部对象键的图片元数据。
export type ImageMetadata = Omit<BusinessImage, 'userId' | 'objectKey'>;
/// 图片变更的稳定回执。
export interface ImageResult {
  /// 历史补传遭遇服务端记录时保持原状态。
  status: 'applied' | 'unchanged';
  /// 已应用或已有的图片，包括显式移除标记。
  image: ImageMetadata;
}

/// 图片文件传输、版本并发控制和可重试对象回收。
@Injectable()
export class ImagesService implements OnModuleInit, OnModuleDestroy {
  /// 日志仅记录清理失败，不输出凭证或对象内容。
  private readonly logger = new Logger(ImagesService.name);
  /// 关闭功能时不会创建后台任务。
  private timer: ReturnType<typeof setInterval> | undefined;
  /// 防止单实例回收任务重叠。
  private collecting = false;

  /// 注入数据库、唯一功能开关和内部对象存储。
  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
    private readonly storage: ImageObjectStore,
  ) {}

  /// 提供无需额外客户端配置的能力发现。
  capabilities(): { enabled: boolean; maxBytes: number } {
    return {
      enabled: this.config.get<boolean>('IMAGE_SYNC_ENABLED') === true,
      maxBytes: IMAGE_MAX_BYTES,
    };
  }

  /// 禁用时拒绝文件访问和元数据修改，保留数据库及存储卷。
  private requireEnabled(): void {
    if (!this.capabilities().enabled)
      throw new ServiceUnavailableException({
        code: 'IMAGE_SYNC_DISABLED',
        message: '服务器未启用图片同步',
      });
  }

  /// 限定业务类型和身份，避免任意表访问或无效 UUID。
  private validateTarget(
    type: string,
    id: string,
  ): asserts type is ImageBusinessType {
    if (
      !['inventoryImage', 'membershipImage'].includes(type) ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        id,
      )
    )
      throw new BadRequestException('图片业务类型或记录身份无效');
  }

  /// 所有业务写入使用同一 owner 锁，阻止迁移或晚到的失效会话写入。
  private async lockOwner(
    transaction: Prisma.TransactionClient,
    user: AuthUser,
  ): Promise<void> {
    // owner 可能已在等待锁时被其他迁移删除。
    const owners = await transaction.$queryRaw<
      { id: string }[]
    >`SELECT id FROM sync_owners WHERE id = ${user.sub}::uuid FOR UPDATE`;
    if (!owners.length) throw new UnauthorizedException('数据归属已失效');
    // 共享锁保证当前事务内设备会话不会被撤销。
    const sessions = await transaction.$queryRaw<
      { id: string }[]
    >`SELECT id FROM device_sessions WHERE id = ${user.sid}::uuid AND user_id = ${user.sub}::uuid AND expires_at > now() FOR SHARE`;
    if (!sessions.length) throw new UnauthorizedException('设备同步会话已失效');
  }

  /// 图片操作必须对应服务端已收到的业务记录；404 可等待业务上传后重试。
  private async lockBusiness(
    transaction: Prisma.TransactionClient,
    user: AuthUser,
    type: ImageBusinessType,
    id: string,
  ): Promise<void> {
    // 固定两种参数化 SQL，不拼接客户端表名。
    const rows =
      type === 'inventoryImage'
        ? await transaction.$queryRaw<
            { id: string }[]
          >`SELECT id FROM inventory_items WHERE user_id = ${user.sub}::uuid AND id = ${id}::uuid FOR UPDATE`
        : await transaction.$queryRaw<
            { id: string }[]
          >`SELECT id FROM memberships WHERE user_id = ${user.sub}::uuid AND id = ${id}::uuid FOR UPDATE`;
    if (!rows.length)
      throw new NotFoundException({
        code: 'IMAGE_RECORD_NOT_FOUND',
        message: '业务记录尚未同步或已永久删除',
      });
  }

  /// 清单包含软删除业务及显式移除标记；物理删除由触发器清理。
  async list(user: AuthUser): Promise<{ items: ImageMetadata[] }> {
    this.requireEnabled();
    return this.prisma.$transaction(async (transaction) => {
      await this.lockOwner(transaction, user);
      // 一次读取与当前 owner 一致的完整图片状态。
      const rows = await transaction.businessImage.findMany({
        where: { userId: user.sub },
        orderBy: [{ businessType: 'asc' }, { businessId: 'asc' }],
      });
      return { items: rows.map((row) => this.metadata(row)) };
    });
  }

  /// 上传前校验文件内容、真实格式和完整摘要。
  private async inspect(
    bytes: Buffer,
    expectedHash: string,
  ): Promise<{ sha256: string; mime: string }> {
    if (!bytes.length || bytes.length > IMAGE_MAX_BYTES)
      throw new BadRequestException('图片大小必须在 1 字节至 20 MB 之间');
    // 客户端摘要只用来核对，权威摘要由服务端重新计算。
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    if (sha256 !== expectedHash)
      throw new BadRequestException('图片摘要不一致');
    try {
      // 完整解码校验限制像素数量，拒绝伪装图片和解压炸弹。
      const image = sharp(bytes, {
        limitInputPixels: 40000000,
        failOn: 'warning',
      });
      // 文件头解码出的真实格式。
      const info = await image.metadata();
      // 只接受客户端支持的四种栅格图片格式。
      const mimes: Record<string, string> = {
        jpeg: 'image/jpeg',
        png: 'image/png',
        webp: 'image/webp',
        gif: 'image/gif',
      };
      // 真实内容对应的 MIME。
      const mime = info.format ? mimes[info.format] : undefined;
      if (!mime) throw new Error('unsupported');
      await image.stats();
      return { sha256, mime };
    } catch {
      throw new BadRequestException(
        '文件不是完整有效的 PNG、JPEG、WebP 或 GIF 图片，或超过 4000 万像素',
      );
    }
  }

  /// 统一稳定序列的操作摘要，文件名和不可信 MIME 不参与语义。
  private digest(
    type: string,
    id: string,
    input: ImageUploadDto | ImageRemoveDto,
  ): string {
    return createHash('sha256')
      .update(
        JSON.stringify({
          type,
          id,
          operationId: input.operationId,
          expectedRevision: input.expectedRevision || null,
          attachmentId: 'attachmentId' in input ? input.attachmentId : null,
          onlyIfMissing: 'onlyIfMissing' in input ? input.onlyIfMissing : null,
          sha256: 'sha256' in input ? input.sha256 : null,
        }),
      )
      .digest('hex');
  }

  /// 已提交操作返回原回执，重试不得把新版本覆盖回旧版本。
  private async previous(
    transaction: Prisma.TransactionClient,
    user: AuthUser,
    operationId: string,
    payloadHash: string,
  ): Promise<ImageResult | undefined> {
    // 同 owner 下唯一的操作身份。
    const receipt = await transaction.imageOperationReceipt.findUnique({
      where: { userId_operationId: { userId: user.sub, operationId } },
    });
    if (!receipt) return undefined;
    if (receipt.payloadHash !== payloadHash)
      throw new ConflictException({
        code: 'IMAGE_OPERATION_REUSED',
        message: '同一图片操作身份不能用于不同内容',
      });
    return receipt.result as unknown as ImageResult;
  }

  /// 保存与业务修改原子提交的稳定回执。
  private async receipt(
    transaction: Prisma.TransactionClient,
    user: AuthUser,
    operationId: string,
    payloadHash: string,
    result: ImageResult,
  ): Promise<ImageResult> {
    await transaction.imageOperationReceipt.create({
      data: {
        userId: user.sub,
        operationId,
        payloadHash,
        result: result as unknown as Prisma.InputJsonValue,
      },
    });
    return result;
  }

  /// 在数据库事务之外上传，短事务中完成所有权复核、CAS 和回执提交。
  async upload(
    user: AuthUser,
    type: string,
    id: string,
    input: ImageUploadDto,
    bytes: Buffer,
  ): Promise<ImageResult> {
    this.requireEnabled();
    this.validateTarget(type, id);
    // 可信文件属性。
    const inspected = await this.inspect(bytes, input.sha256);
    // 操作规范化摘要。
    const payloadHash = this.digest(type, id, input);
    // 上传前处理重复请求和历史补传，避免无意义对象流量。
    const early = await this.prisma.$transaction(async (transaction) => {
      await this.lockOwner(transaction, user);
      // 原回执优先，返回后不会再次写入。
      const previous = await this.previous(
        transaction,
        user,
        input.operationId,
        payloadHash,
      );
      if (previous) return previous;
      await this.lockBusiness(transaction, user, type, id);
      // 任意现有标记均优先于历史补传，包括显式清空。
      const current = await transaction.businessImage.findUnique({
        where: {
          userId_businessType_businessId: {
            userId: user.sub,
            businessType: type,
            businessId: id,
          },
        },
      });
      if (input.onlyIfMissing === 'true' && current)
        return this.receipt(transaction, user, input.operationId, payloadHash, {
          status: 'unchanged',
          image: this.metadata(current),
        });
      this.compareRevision(current, input.expectedRevision || null);
      return undefined;
    });
    if (early) return early;
    // 每次尝试使用唯一对象键，避免重试与回收任务竞争同一键。
    const objectKey = `${user.sub}/${input.operationId}/${randomUUID()}`;
    // 先记录暂存对象，崩溃或未知提交结果也不会永久泄漏。
    await this.prisma.imageObjectGarbage.create({
      data: { objectKey, dueAt: new Date(Date.now() + 24 * 60 * 60 * 1000) },
    });
    try {
      await this.storage.put(objectKey, bytes, inspected.mime);
    } catch {
      throw new ServiceUnavailableException({
        code: 'IMAGE_STORAGE_UNAVAILABLE',
        message: '图片存储暂不可用，请稍后重试',
      });
    }
    return this.prisma.$transaction(async (transaction) => {
      await this.lockOwner(transaction, user);
      // 上传过程中另一个同 ID 请求可能已成功。
      const previous = await this.previous(
        transaction,
        user,
        input.operationId,
        payloadHash,
      );
      if (previous) return previous;
      await this.lockBusiness(transaction, user, type, id);
      // 上传前后都需检查版本，不能覆盖中间产生的新修改。
      const current = await transaction.businessImage.findUnique({
        where: {
          userId_businessType_businessId: {
            userId: user.sub,
            businessType: type,
            businessId: id,
          },
        },
      });
      if (input.onlyIfMissing === 'true' && current)
        return this.receipt(transaction, user, input.operationId, payloadHash, {
          status: 'unchanged',
          image: this.metadata(current),
        });
      this.compareRevision(current, input.expectedRevision || null);
      // 对象存在后才允许提交可被其他客户端看到的引用。
      const data = {
        userId: user.sub,
        businessType: type,
        businessId: id,
        attachmentId: input.attachmentId,
        revision: randomUUID(),
        objectKey,
        sha256: inspected.sha256,
        mimeType: inspected.mime,
        sizeBytes: bytes.length,
      };
      // 新图片版本，旧对象通过数据库触发器入回收队列。
      const image = await transaction.businessImage.upsert({
        where: {
          userId_businessType_businessId: {
            userId: user.sub,
            businessType: type,
            businessId: id,
          },
        },
        create: data,
        update: data,
      });
      await transaction.imageObjectGarbage.delete({ where: { objectKey } });
      return this.receipt(transaction, user, input.operationId, payloadHash, {
        status: 'applied',
        image: this.metadata(image),
      });
    });
  }

  /// 显式移除保留空图片标记，使旧设备不能重新补传旧图。
  async remove(
    user: AuthUser,
    type: string,
    id: string,
    input: ImageRemoveDto,
  ): Promise<ImageResult> {
    this.requireEnabled();
    this.validateTarget(type, id);
    // 与上传使用相同幂等规则。
    const payloadHash = this.digest(type, id, input);
    return this.prisma.$transaction(async (transaction) => {
      await this.lockOwner(transaction, user);
      // 已提交删除可以安全重试。
      const previous = await this.previous(
        transaction,
        user,
        input.operationId,
        payloadHash,
      );
      if (previous) return previous;
      await this.lockBusiness(transaction, user, type, id);
      // 当前图片或移除标记。
      const current = await transaction.businessImage.findUnique({
        where: {
          userId_businessType_businessId: {
            userId: user.sub,
            businessType: type,
            businessId: id,
          },
        },
      });
      this.compareRevision(current, input.expectedRevision || null);
      // 全空附件字段代表明确的远端移除，而非尚未同步。
      const data = {
        userId: user.sub,
        businessType: type,
        businessId: id,
        revision: randomUUID(),
        attachmentId: null,
        objectKey: null,
        sha256: null,
        mimeType: null,
        sizeBytes: null,
      };
      // 持久删除标记。
      const image = await transaction.businessImage.upsert({
        where: {
          userId_businessType_businessId: {
            userId: user.sub,
            businessType: type,
            businessId: id,
          },
        },
        create: data,
        update: data,
      });
      return this.receipt(transaction, user, input.operationId, payloadHash, {
        status: 'applied',
        image: this.metadata(image),
      });
    });
  }

  /// null 仅能匹配从未存在的图片状态。
  private compareRevision(
    current: BusinessImage | null,
    expected: string | null,
  ): void {
    if ((current?.revision ?? null) !== expected)
      throw new ConflictException({
        code: 'IMAGE_CONFLICT',
        message: '图片已在其他设备修改，请刷新后重试',
      });
  }

  /// 剥离服务端存储位置和数据归属字段。
  private metadata(image: BusinessImage): ImageMetadata {
    return {
      businessType: image.businessType,
      businessId: image.businessId,
      attachmentId: image.attachmentId,
      revision: image.revision,
      sha256: image.sha256,
      mimeType: image.mimeType,
      sizeBytes: image.sizeBytes,
    };
  }

  /// 下载前后复核版本和会话，避免迟到请求读到已迁移的数据源。
  async download(
    user: AuthUser,
    type: string,
    id: string,
    revision: string,
  ): Promise<{ bytes: Buffer; mime: string }> {
    this.requireEnabled();
    this.validateTarget(type, id);
    // 下载对象对应的当前授权图片。
    const image = await this.prisma.$transaction(async (transaction) => {
      await this.lockOwner(transaction, user);
      // 仅当前业务记录的当前版本可读。
      const current = await transaction.businessImage.findUnique({
        where: {
          userId_businessType_businessId: {
            userId: user.sub,
            businessType: type,
            businessId: id,
          },
        },
      });
      if (!current?.objectKey || current.revision !== revision)
        throw new NotFoundException('图片版本已不存在');
      return current;
    });
    // 经服务端代理读取的私有对象。
    let bytes: Buffer;
    try {
      bytes = await this.storage.get(image.objectKey!);
    } catch {
      throw new ServiceUnavailableException({
        code: 'IMAGE_STORAGE_UNAVAILABLE',
        message: '图片文件暂不可用，请稍后重试',
      });
    }
    await this.prisma.$transaction(async (transaction) => {
      await this.lockOwner(transaction, user);
      // 网络读取期间图片或 owner 可能已经替换。
      const current = await transaction.businessImage.findUnique({
        where: {
          userId_businessType_businessId: {
            userId: user.sub,
            businessType: type,
            businessId: id,
          },
        },
      });
      if (!current || current.revision !== revision)
        throw new NotFoundException('图片版本已不存在');
    });
    return { bytes, mime: image.mimeType! };
  }

  /// 每分钟处理有限数量，未开启功能时完全停用。
  onModuleInit(): void {
    if (!this.capabilities().enabled) return;
    this.timer = setInterval(() => {
      void this.collectGarbage().catch(() =>
        this.logger.warn('图片对象清理暂时失败，将自动重试'),
      );
    }, 60000);
    this.timer.unref();
  }

  /// 关闭后台任务；已进入事务的工作仍由 Prisma 关闭流程等待。
  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /// 持久清理队列与行锁允许多实例幂等重试，不删除仍有引用的对象。
  async collectGarbage(): Promise<void> {
    if (!this.capabilities().enabled || this.collecting) return;
    this.collecting = true;
    try {
      // 限制每轮清理量，失败条目延后避免饿死其他任务。
      for (let index = 0; index < 20; index++) {
        // 独立事务锁定任务，避免多副本同时删除。
        const found = await this.prisma.$transaction(
          async (transaction) => {
            // SKIP LOCKED 避免等待其他清理进程。
            const rows = await transaction.$queryRaw<
              { object_key: string }[]
            >`SELECT object_key FROM image_object_garbage WHERE due_at <= now() ORDER BY due_at LIMIT 1 FOR UPDATE SKIP LOCKED`;
            // 待回收的确切对象键。
            const key = rows[0]?.object_key;
            if (!key) return false;
            // 防御性校验，持久业务引用优先。
            const referenced = await transaction.businessImage.findUnique({
              where: { objectKey: key },
            });
            if (!referenced) {
              try {
                await this.storage.delete(key);
              } catch {
                await transaction.imageObjectGarbage.update({
                  where: { objectKey: key },
                  data: { dueAt: new Date(Date.now() + 5 * 60000) },
                });
                return true;
              }
            }
            await transaction.imageObjectGarbage.delete({
              where: { objectKey: key },
            });
            return true;
          },
          { timeout: 20000 },
        );
        if (!found) break;
      }
    } finally {
      this.collecting = false;
    }
  }
}
