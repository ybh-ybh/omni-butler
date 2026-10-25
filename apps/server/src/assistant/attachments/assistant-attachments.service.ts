import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
  OnModuleDestroy,
  OnModuleInit,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, randomUUID } from 'node:crypto';
import { extname } from 'node:path';
import { z } from 'zod';
import type { AuthUser } from '../../auth/auth.types';
import { withinBusinessTransaction } from '../../business/business-access';
import { createAssistantImagePart } from '../../ai/assistant-model-policy';
import type {
  AssistantAttachment,
  Prisma,
} from '../../generated/prisma/client';
import { PrismaService } from '../../prisma/prisma.service';
import { AttachmentObjectStore } from './attachment-object-store';
import { AttachmentProcess } from './attachment-process';
import { attachmentOutputFits } from './attachment-output';
import {
  ATTACHMENT_LIMITS as limits,
  ATTACHMENT_MIMES,
  AttachmentParseError,
  type AttachmentChunk,
  type AttachmentImageReference,
  type AttachmentMetadata,
  type AttachmentReadRange,
} from './attachment.types';

/// 对象存储只保存受控解析结果，不携带原始凭据。
interface StoredManifest {
  /// 固定格式版本。
  version: 1;
  /// 有界、可引用正文。
  chunks: AttachmentChunk[];
}

/// 每张派生图绑定明确页号与不可变对象键。
interface StoredImage {
  /// 普通图片没有页号。
  page?: number;
  /// 私有键永不返回前端或模型。
  key: string;
}

/// 持久上传、隔离解析和会话级读取共用同一附件身份。
@Injectable()
export class AssistantAttachmentsService
  implements OnModuleInit, OnModuleDestroy
{
  /// 后台工作器每实例只处理一个解析任务。
  private timer?: ReturnType<typeof setInterval>;
  /// 停机时等待当前有限工作结束。
  private active?: Promise<void>;
  /// 防止停机后启动下一轮。
  private stopping = false;

  /// 注入持久数据库、私有存储与可替换解析进程。
  constructor(
    private readonly prisma: PrismaService,
    private readonly objects: AttachmentObjectStore,
    private readonly parser: AttachmentProcess,
    private readonly config: ConfigService,
  ) {}

  /// 能力关闭时不创建对象桶或启动解析。
  capabilities(): {
    enabled: boolean;
    maxFiles: number;
    maxFileBytes: number;
    maxTotalBytes: number;
    extensions: string[];
  } {
    return {
      enabled:
        this.config.get<boolean>('ASSISTANT_ATTACHMENTS_ENABLED') === true,
      maxFiles: limits.maxFiles,
      maxFileBytes: limits.maxFileBytes,
      maxTotalBytes: limits.maxTotalBytes,
      extensions: Object.keys(ATTACHMENT_MIMES),
    };
  }

  /// 上传与重解析入口需要服务器明确启用。
  private enabled(): void {
    if (!this.capabilities().enabled)
      throw new ServiceUnavailableException({
        code: 'ATTACHMENTS_DISABLED',
        message: '服务器尚未开启助手附件',
      });
  }

  /// 同一事务里复验真实设备身份，不能只信任已解码JWT。
  private async authorize(
    transaction: Prisma.TransactionClient,
    actor: AuthUser,
  ): Promise<void> {
    if (
      !actor ||
      actor.typ !== 'access' ||
      !z.uuid().safeParse(actor.sub).success ||
      !z.uuid().safeParse(actor.sid).success
    )
      throw new UnauthorizedException('需要有效设备身份');
    if (
      !(await transaction.deviceSession.findFirst({
        where: {
          id: actor.sid,
          userId: actor.sub,
          expiresAt: { gt: new Date() },
        },
      }))
    )
      throw new UnauthorizedException('设备会话已失效');
  }

  /// 会话与附件双重归属过滤，跨会话ID不会泄漏存在性。
  private async conversation(
    transaction: Prisma.TransactionClient,
    actor: AuthUser,
    id: string,
  ): Promise<void> {
    if (
      !z.uuid().safeParse(id).success ||
      !(await transaction.assistantConversation.findFirst({
        where: { id, userId: actor.sub },
      }))
    )
      throw new NotFoundException('会话不存在');
  }

  /// 固定字段投影确保对象键和解析正文不能进入事件。
  private view(row: AssistantAttachment): AttachmentMetadata {
    return {
      id: row.id,
      name: row.name,
      mimeType: row.mimeType,
      size: row.size,
      status: row.status as AttachmentMetadata['status'],
      kind: row.kind as AttachmentMetadata['kind'],
      requiresVision: row.requiresVision,
      ...(row.errorCode ? { errorCode: row.errorCode } : {}),
    };
  }

  /// 清理文件名中的路径与控制字符，并保留用户可辨识名称。
  private fileName(raw: string): string {
    // multipart原名可能包含Windows路径，永远不用于磁盘路径。
    const name = Array.from(raw.replace(/\\/g, '/').split('/').at(-1) ?? '')
      .filter(
        (character) =>
          character.charCodeAt(0) >= 32 && character.charCodeAt(0) !== 127,
      )
      .join('')
      .trim();
    if (!name || name.length > 180)
      throw new BadRequestException('附件名称无效或过长');
    return name;
  }

  /// 首次预留身份与配额，原文件上传成功后进入持久解析队列。
  async upload(
    actor: AuthUser,
    conversationId: string,
    uploadId: string,
    file: { buffer: Buffer; originalname: string },
  ): Promise<AttachmentMetadata> {
    this.enabled();
    if (
      !z.uuid().safeParse(uploadId).success ||
      !file?.buffer?.length ||
      file.buffer.length > limits.maxFileBytes
    )
      throw new BadRequestException({
        code: 'ATTACHMENT_FILE_LIMIT',
        message: '附件身份或大小无效',
      });
    // 规范名称参与幂等校验，防止相同身份换扩展名。
    const name = this.fileName(file.originalname);
    // 只从固定扩展名映射选择解析器。
    const extension = extname(name).slice(1).toLowerCase();
    // MIME由服务器决定，不信任客户端表单MIME。
    const mimeType = ATTACHMENT_MIMES[extension];
    if (!mimeType)
      throw new BadRequestException({
        code: 'ATTACHMENT_UNSUPPORTED_TYPE',
        message: '不支持该文件格式；旧版doc/xls请先转换',
      });
    // 原始内容哈希绑定重放身份。
    const sha256 = createHash('sha256').update(file.buffer).digest('hex');
    // 上传代次防止删除后的迟到写入覆盖后来对象。
    const token = randomUUID();
    // 事务只预留元数据，不在owner锁内等待网络上传。
    const reservation = await withinBusinessTransaction(
      this.prisma,
      actor,
      async (transaction) => {
        await this.conversation(transaction, actor, conversationId);
        // 稳定UUID属于首次owner与会话。
        const existing = await transaction.assistantAttachment.findUnique({
          where: { id: uploadId },
        });
        if (existing) {
          if (
            existing.userId !== actor.sub ||
            existing.conversationId !== conversationId ||
            existing.sha256 !== sha256 ||
            existing.name !== name ||
            existing.status === 'deleted'
          )
            throw new ConflictException('附件上传身份已被使用');
          if (
            existing.status !== 'failed' ||
            ![
              'ATTACHMENT_UPLOAD_INTERRUPTED',
              'ATTACHMENT_STORAGE_UNAVAILABLE',
            ].includes(existing.errorCode ?? '')
          )
            return { row: existing, upload: false };
          // 未完成原件上传可用相同身份和相同字节恢复。
          const row = await transaction.assistantAttachment.update({
            where: { id: uploadId },
            data: {
              status: 'uploading',
              leaseToken: token,
              leaseUntil: new Date(Date.now() + 90000),
              errorCode: null,
            },
          });
          return { row, upload: true };
        }
        // 同会话未发送的附件共同占用草稿额度。
        const pending = await transaction.assistantAttachment.findMany({
          where: {
            userId: actor.sub,
            conversationId,
            status: { not: 'deleted' },
            message: null,
          },
          select: { size: true },
        });
        if (
          pending.length >= limits.maxFiles ||
          pending.reduce((sum, row) => sum + row.size, file.buffer.length) >
            limits.maxTotalBytes
        )
          throw new BadRequestException('每条消息最多5个附件，合计不超过50MiB');
        // 原件对象键包含独立代次，不含用户文件名。
        const objectKey = `${actor.sub}/${uploadId}/${token}/original`;
        // 预留记录在任何外部写入之前存在。
        const row = await transaction.assistantAttachment.create({
          data: {
            id: uploadId,
            userId: actor.sub,
            conversationId,
            sessionId: actor.sid,
            name,
            mimeType,
            size: file.buffer.length,
            sha256,
            kind: mimeType.startsWith('image/') ? 'image' : 'document',
            requiresVision: mimeType.startsWith('image/'),
            status: 'uploading',
            objectKey,
            leaseToken: token,
            leaseUntil: new Date(Date.now() + 90000),
          },
        });
        await this.queueKeys(transaction, row, [objectKey], 24 * 3600000);
        return { row, upload: true };
      },
    );
    if (!reservation.upload) return this.view(reservation.row);
    try {
      await this.objects.put(reservation.row.objectKey, file.buffer, mimeType);
      // 上传后的重新授权阻止删除或撤权后的迟到发布。
      return await withinBusinessTransaction(
        this.prisma,
        actor,
        async (transaction) => {
          // CAS不能复活已移除或已被接管的上传。
          const updated = await transaction.assistantAttachment.updateMany({
            where: {
              id: uploadId,
              userId: actor.sub,
              status: 'uploading',
              leaseToken: token,
            },
            data: { status: 'processing', leaseToken: null, leaseUntil: null },
          });
          if (!updated.count) throw new ConflictException('附件上传已取消');
          return this.view(
            await transaction.assistantAttachment.findUniqueOrThrow({
              where: { id: uploadId },
            }),
          );
        },
      );
    } catch (error) {
      await this.prisma.assistantAttachment.updateMany({
        where: { id: uploadId, status: 'uploading', leaseToken: token },
        data: {
          status: 'failed',
          errorCode: 'ATTACHMENT_STORAGE_UNAVAILABLE',
          leaseToken: null,
          leaseUntil: null,
        },
      });
      if (
        error instanceof UnauthorizedException ||
        error instanceof ConflictException
      )
        throw error;
      throw new ServiceUnavailableException({
        code: 'ATTACHMENT_STORAGE_UNAVAILABLE',
        message: '附件存储暂时不可用，可使用原上传身份重试',
      });
    }
  }

  /// 历史消息可重复读取已绑定附件；发送约束由bindMessage执行。
  async attachmentMetadata(
    transaction: Prisma.TransactionClient,
    actor: AuthUser,
    conversationId: string,
    ids: string[],
  ): Promise<AttachmentMetadata[]> {
    await this.authorize(transaction, actor);
    await this.conversation(transaction, actor, conversationId);
    if (
      !Array.isArray(ids) ||
      ids.length > 100 ||
      ids.some((id) => !z.uuid().safeParse(id).success)
    )
      throw new BadRequestException('附件身份无效');
    // 仅公开当前owner和会话中的有效附件。
    const rows = await transaction.assistantAttachment.findMany({
      where: {
        id: { in: ids },
        userId: actor.sub,
        conversationId,
        status: { not: 'deleted' },
      },
    });
    // 保留原请求顺序以匹配消息卡片。
    const byId = new Map(rows.map((row) => [row.id, row]));
    if (ids.some((id) => !byId.has(id)))
      throw new NotFoundException('附件不存在');
    return ids.map((id) => this.view(byId.get(id)!));
  }

  /// 附件与用户消息同一事务绑定，ready之前拒绝发送。
  async bindMessage(
    transaction: Prisma.TransactionClient,
    actor: AuthUser,
    conversationId: string,
    messageId: string,
    ids: string[],
  ): Promise<AttachmentMetadata[]> {
    if (
      !Array.isArray(ids) ||
      ids.length > limits.maxFiles ||
      new Set(ids).size !== ids.length
    )
      throw new BadRequestException('每条消息最多5个不同附件');
    // 元数据读取同时验证真实设备与会话归属。
    const metadata = await this.attachmentMetadata(
      transaction,
      actor,
      conversationId,
      ids,
    );
    if (metadata.some((row) => row.status !== 'ready'))
      throw new BadRequestException({
        code: 'ATTACHMENT_NOT_READY',
        message: '附件尚未就绪，请等待解析或重试失败附件',
      });
    if (metadata.reduce((sum, row) => sum + row.size, 0) > limits.maxTotalBytes)
      throw new BadRequestException({
        code: 'ATTACHMENT_TOTAL_LIMIT',
        message: '附件合计超过50MiB',
      });
    if (
      !(await transaction.assistantMessage.findFirst({
        where: {
          id: messageId,
          userId: actor.sub,
          conversationId,
          role: 'user',
        },
      }))
    )
      throw new NotFoundException('用户消息不存在');
    for (const id of ids) {
      // 同一上传不能悄悄挪到另一条消息。
      const binding = await transaction.assistantMessageAttachment.findUnique({
        where: { attachmentId: id },
      });
      if (binding && binding.messageId !== messageId)
        throw new ConflictException('附件已绑定其他消息');
      if (!binding)
        await transaction.assistantMessageAttachment.create({
          data: { messageId, attachmentId: id },
        });
    }
    return metadata;
  }

  /// 单附件查询用于解析状态轮询，任意owner设备须有有效会话。
  async metadata(actor: AuthUser, id: string): Promise<AttachmentMetadata> {
    return withinBusinessTransaction(this.prisma, actor, async (transaction) =>
      this.view(await this.owned(transaction, actor, id)),
    );
  }

  /// 所有下载与工具读取共用不可枚举的归属检查。
  private async owned(
    transaction: Prisma.TransactionClient,
    actor: AuthUser,
    id: string,
    conversationId?: string,
    bound = false,
  ): Promise<AssistantAttachment> {
    await this.authorize(transaction, actor);
    if (!z.uuid().safeParse(id).success)
      throw new NotFoundException('附件不存在');
    // 文档工具只能访问已经发送到当前会话的附件。
    const row = await transaction.assistantAttachment.findFirst({
      where: {
        id,
        userId: actor.sub,
        ...(conversationId ? { conversationId } : {}),
        status: { not: 'deleted' },
        ...(bound ? { message: { isNot: null } } : {}),
      },
    });
    if (!row) throw new NotFoundException('附件不存在');
    return row;
  }

  /// 原件由后端代理下载，完成存储读取后再次检查撤权与删除。
  async file(
    actor: AuthUser,
    id: string,
  ): Promise<{ bytes: Buffer; name: string; mimeType: string }> {
    // 仅取当前授权对象键。
    const row = await withinBusinessTransaction(
      this.prisma,
      actor,
      (transaction) => this.owned(transaction, actor, id),
    );
    // 原件不转成公开URL。
    const bytes = await this.objects.get(row.objectKey);
    await this.metadata(actor, id);
    return { bytes, name: row.name, mimeType: row.mimeType };
  }

  /// 解析重试复用原件，不产生模型费用或重新上传身份。
  async retry(actor: AuthUser, id: string): Promise<AttachmentMetadata> {
    this.enabled();
    return withinBusinessTransaction(
      this.prisma,
      actor,
      async (transaction) => {
        // 已就绪或正在处理的重复点击直接重放。
        const row = await this.owned(transaction, actor, id);
        if (row.status !== 'failed') return this.view(row);
        // 原件上传失败必须由客户端以原UUID重传，不能解析缺失对象并抹掉恢复依据。
        if (
          [
            'ATTACHMENT_UPLOAD_INTERRUPTED',
            'ATTACHMENT_STORAGE_UNAVAILABLE',
          ].includes(row.errorCode ?? '')
        )
          return this.view(row);
        return this.view(
          await transaction.assistantAttachment.update({
            where: { id },
            data: {
              status: 'processing',
              errorCode: null,
              leaseToken: null,
              leaseUntil: null,
            },
          }),
        );
      },
    );
  }

  /// 已发送附件由会话生命周期管理，不能单独破坏历史引用。
  async remove(actor: AuthUser, id: string): Promise<{ ok: true }> {
    return withinBusinessTransaction(
      this.prisma,
      actor,
      async (transaction) => {
        // 删除重复请求对当前owner保持幂等。
        const existing = await transaction.assistantAttachment.findFirst({
          where: { id, userId: actor.sub },
        });
        if (!existing || existing.status === 'deleted') return { ok: true };
        if (
          await transaction.assistantMessageAttachment.findUnique({
            where: { attachmentId: id },
          })
        )
          throw new ConflictException('已发送附件请随会话删除');
        await this.queueKeys(transaction, existing, this.keys(existing));
        await transaction.assistantAttachment.update({
          where: { id },
          data: { status: 'deleted', leaseToken: null, leaseUntil: null },
        });
        return { ok: true };
      },
    );
  }

  /// 会话删除必须在原删除事务内调用，清理队列不受级联删除影响。
  async queueConversationDeletion(
    transaction: Prisma.TransactionClient,
    actor: AuthUser,
    conversationId: string,
  ): Promise<void> {
    await this.authorize(transaction, actor);
    await this.conversation(transaction, actor, conversationId);
    // 先固定所有已发布对象键，再允许上层删除会话。
    const rows = await transaction.assistantAttachment.findMany({
      where: { userId: actor.sub, conversationId },
    });
    for (const row of rows)
      await this.queueKeys(transaction, row, this.keys(row));
  }

  /// 图输入只需要有限目录，不把完整附件正文或图片编码塞入状态。
  async contextManifest(
    actor: AuthUser,
    conversationId: string,
    ids?: string[],
  ): Promise<Record<string, unknown>[]> {
    return withinBusinessTransaction(
      this.prisma,
      actor,
      async (transaction) => {
        await this.conversation(transaction, actor, conversationId);
        // 最近五十个已发送附件足够生成目录，指定身份时仍做归属过滤。
        const rows = await transaction.assistantAttachment.findMany({
          where: {
            userId: actor.sub,
            conversationId,
            status: 'ready',
            message: { isNot: null },
            ...(ids ? { id: { in: ids } } : {}),
          },
          orderBy: { createdAt: 'desc' },
          take: 50,
        });
        return rows.map((row) => ({
          ...this.view(row),
          chunkCount: row.chunkCount,
          units: row.units,
          imagePages: this.images(row).map((image) => image.page ?? null),
        }));
      },
    );
  }

  /// 提取JSON只在已绑定和ready状态下读取。
  private async manifest(
    actor: AuthUser,
    conversationId: string,
    id: string,
  ): Promise<{ row: AssistantAttachment; manifest: StoredManifest }> {
    // 当前授权快照只保留确定的产物引用。
    const row = await withinBusinessTransaction(
      this.prisma,
      actor,
      (transaction) => this.owned(transaction, actor, id, conversationId, true),
    );
    if (row.status !== 'ready' || !row.manifestKey)
      throw new ConflictException('附件尚未解析完成');
    // 解析产物由本服务生成，读取时仍检查版本与形状。
    const manifest = JSON.parse(
      (await this.objects.get(row.manifestKey)).toString('utf8'),
    ) as StoredManifest;
    if (
      manifest.version !== 1 ||
      !Array.isArray(manifest.chunks) ||
      manifest.chunks.length > limits.maxChunks
    )
      throw new ServiceUnavailableException('附件解析产物无效');
    await withinBusinessTransaction(this.prisma, actor, (transaction) =>
      this.owned(transaction, actor, id, conversationId, true),
    );
    return { row, manifest };
  }

  /// 只读取有限块并返回来源定位与安全图片引用。
  async read(
    actor: AuthUser,
    conversationId: string,
    id: string,
    range: AttachmentReadRange = {},
  ): Promise<Record<string, unknown>> {
    // 严格范围防止工具一次搬运全部附件。
    const checked = z
      .object({
        start: z.number().int().min(1).optional(),
        end: z.number().int().min(1).optional(),
        page: z.number().int().min(1).optional(),
        sheet: z.string().max(200).optional(),
      })
      .strict()
      .parse(range);
    // 加载经授权的固定解析产物。
    const { row, manifest } = await this.manifest(actor, conversationId, id);
    // 先按来源过滤，页或表定位不会错误受前十个全局块限制。
    const scoped = manifest.chunks.filter(
      (chunk) =>
        (checked.page === undefined || chunk.page === checked.page) &&
        (checked.sheet === undefined || chunk.sheet === checked.sheet),
    );
    // 默认从选定来源的首块开始，显式编号仍为全局引用编号。
    const start = checked.start ?? scoped[0]?.index ?? 1;
    // 单次不超过十块。
    const end = checked.end ?? start + 9;
    if (end < start || end - start >= 10)
      throw new BadRequestException('每次最多读取10个附件块');
    // 请求范围只决定候选块，实际返回还需满足完整JSON字节预算。
    const candidates = scoped.filter(
      (chunk) => chunk.index >= start && chunk.index <= end,
    );
    // 普通图片兼容显式第1页，但引用仍使用无页码身份；PDF保持实际页号。
    const images = this.images(row)
      .filter((image) =>
        row.kind === 'image'
          ? checked.page === undefined || checked.page === 1
          : checked.page !== undefined && image.page === checked.page,
      )
      .map((image) => ({
        attachmentId: id,
        ...(image.page === undefined ? {} : { page: image.page }),
      }));
    if (
      !candidates.length &&
      !images.length &&
      (checked.start !== undefined ||
        checked.end !== undefined ||
        checked.page !== undefined ||
        checked.sheet !== undefined)
    )
      throw new BadRequestException('附件中没有该读取范围');
    // 完整块逐个追加，不截取JSON或丢弃某块尾部。
    const chunks: AttachmentChunk[] = [];
    // 每次试算都包含最终实际范围和分页字段，不能遗漏包装开销。
    const output = (): Record<string, unknown> => {
      // 无文本时不虚构已读取的结束块，例如扫描页仅返回图片引用。
      const actualEnd = chunks.at(-1)?.index ?? null;
      // 下一块在同一页/工作表范围内选择，支持来源筛选后的连续翻页。
      const next = scoped.find(
        (chunk) =>
          chunk.index >= start &&
          (actualEnd === null || chunk.index > actualEnd),
      );
      return {
        attachmentId: id,
        name: row.name,
        start,
        end: actualEnd,
        ...(checked.page === undefined ? {} : { page: checked.page }),
        ...(checked.sheet === undefined ? {} : { sheet: checked.sheet }),
        chunks,
        ...(images.length ? { images } : {}),
        totalChunks: row.chunkCount,
        truncated: next !== undefined,
        ...(next ? { nextStart: next.index } : {}),
        untrusted: true,
      };
    };
    for (const chunk of candidates) {
      chunks.push(chunk);
      if (!attachmentOutputFits(output())) {
        chunks.pop();
        break;
      }
    }
    // 当前解析器单块上限确保至少一块可返回；异常旧产物不能突破出站预算。
    if (
      (!chunks.length && candidates.length) ||
      !attachmentOutputFits(output())
    )
      throw new ServiceUnavailableException(
        '附件单块解析产物超过读取预算，请重新上传',
      );
    return output();
  }

  /// 字面文本搜索无正则执行，并保留最多十个定位摘要。
  async search(
    actor: AuthUser,
    conversationId: string,
    id: string,
    query: string,
  ): Promise<Record<string, unknown>> {
    if (typeof query !== 'string' || !query.trim() || query.length > 200)
      throw new BadRequestException('请输入1至200字符的附件检索词');
    // 检索只基于已提取资料，不调用模型或OCR。
    const { row, manifest } = await this.manifest(actor, conversationId, id);
    // 不区分大小写的字面匹配不会执行用户表达式。
    const needle = query.toLocaleLowerCase();
    // 返回短片段和引用，长正文需显式按范围读取。
    const candidates = manifest.chunks.filter((chunk) =>
      chunk.text.toLocaleLowerCase().includes(needle),
    );
    // 来源定位和短片段也受完整JSON预算约束。
    const matches: AttachmentChunk[] = [];
    // 对未返回匹配给出可供read_attachment使用的下一块编号。
    const output = (): Record<string, unknown> => ({
      attachmentId: id,
      name: row.name,
      matches,
      truncated: matches.length < candidates.length,
      ...(matches.length < candidates.length
        ? { nextStart: candidates[matches.length]!.index }
        : {}),
      totalMatches: candidates.length,
      ...(row.kind === 'image' && !manifest.chunks.length
        ? {
            message:
              '此图片没有可检索的提取文字，空匹配不代表图片没有内容或不支持读图。请调用read_attachment读取图片，实际图像将随下一次模型请求提供。',
          }
        : {}),
      untrusted: true,
    });
    for (const chunk of candidates.slice(0, 10)) {
      // 搜索词周围最多400字符。
      const offset = Math.max(
        0,
        Array.from(
          chunk.text.slice(0, chunk.text.toLocaleLowerCase().indexOf(needle)),
        ).length - 120,
      );
      matches.push({
        ...chunk,
        text: Array.from(chunk.text)
          .slice(offset, offset + 400)
          .join(''),
      });
      if (!attachmentOutputFits(output())) {
        matches.pop();
        break;
      }
    }
    if (!attachmentOutputFits(output()))
      throw new ServiceUnavailableException('附件检索元数据超过读取预算');
    return output();
  }

  /// 仅出站组装阶段读取受限图，返回内存品牌对象且不写入数据库。
  async hydrateImages(
    actor: AuthUser,
    conversationId: string,
    references: AttachmentImageReference[],
  ): Promise<Record<string, unknown>[]> {
    if (!Array.isArray(references) || references.length > 5)
      throw new BadRequestException('单次最多读取5张附件图片');
    // 累计字节与图像数量共同限制模型输入。
    let total = 0;
    // 成品对象保持原引用，不能JSON克隆丢失品牌。
    const parts: Record<string, unknown>[] = [];
    // 重复引用只读一次。
    const seen = new Set<string>();
    for (const reference of references) {
      // 页号只能为有限正整数。
      const checked = z
        .object({
          attachmentId: z.uuid(),
          page: z.number().int().min(1).max(limits.maxPages).optional(),
        })
        .strict()
        .parse(reference);
      // 引用身份包括PDF页号。
      const identity = `${checked.attachmentId}:${checked.page ?? 0}`;
      if (seen.has(identity)) continue;
      seen.add(identity);
      // 当前owner、会话和绑定状态都必须满足。
      const row = await withinBusinessTransaction(
        this.prisma,
        actor,
        (transaction) =>
          this.owned(
            transaction,
            actor,
            checked.attachmentId,
            conversationId,
            true,
          ),
      );
      if (row.status !== 'ready') throw new ConflictException('附件尚未就绪');
      // 禁止普通文档引用任意对象键。
      const image = this.images(row).find((item) => item.page === checked.page);
      if (!image) throw new NotFoundException('附件图片页不存在');
      // 图像数据不会进入图状态或SSE事件。
      const bytes = await this.objects.get(image.key);
      total += bytes.length;
      if (bytes.length > 2 * 1024 * 1024 || total > 12 * 1024 * 1024)
        throw new BadRequestException('附件图片合计超过模型输入预算');
      await withinBusinessTransaction(this.prisma, actor, (transaction) =>
        this.owned(
          transaction,
          actor,
          checked.attachmentId,
          conversationId,
          true,
        ),
      );
      parts.push(
        createAssistantImagePart(
          checked.attachmentId,
          `data:image/jpeg;base64,${bytes.toString('base64')}`,
        ),
      );
    }
    return parts;
  }

  /// 将受控JSON列转换成内部图片引用。
  private images(row: AssistantAttachment): StoredImage[] {
    return Array.isArray(row.imageKeys)
      ? (row.imageKeys as unknown as StoredImage[])
      : [];
  }

  /// 原件和已发布产物共同进入清理队列。
  private keys(row: AssistantAttachment): string[] {
    return [
      row.objectKey,
      ...(row.manifestKey ? [row.manifestKey] : []),
      ...this.images(row).map((image) => image.key),
    ];
  }

  /// 清理任务先持久化，延迟覆盖仍在进行的有界上传。
  private async queueKeys(
    transaction: Prisma.TransactionClient,
    row: Pick<AssistantAttachment, 'id' | 'userId'>,
    keys: string[],
    delayMs = 10 * 60000,
  ): Promise<string> {
    // 每个对象集合独立重试，删除会话后身份仍保留。
    const id = randomUUID();
    await transaction.assistantAttachmentGc.create({
      data: {
        id,
        userId: row.userId,
        attachmentId: row.id,
        keys,
        availableAt: new Date(Date.now() + delayMs),
      },
    });
    return id;
  }

  /// 启动持久解析与垃圾回收，不依赖客户端保持连接。
  onModuleInit(): void {
    if (!this.capabilities().enabled) return;
    this.timer = setInterval(() => {
      if (!this.active && !this.stopping)
        this.active = this.tick()
          .catch(() => undefined)
          .finally(() => {
            this.active = undefined;
          });
    }, 2000);
    this.timer.unref();
  }

  /// 退出不丢弃已经开始的有限解析或对象写入。
  async onModuleDestroy(): Promise<void> {
    this.stopping = true;
    if (this.timer) clearInterval(this.timer);
    await this.active;
  }

  /// 领取一个解析任务，过期租约可以安全重做无副作用解析。
  async tick(): Promise<void> {
    if (this.stopping || !this.capabilities().enabled) return;
    await this.collect();
    await this.prisma.assistantAttachment.updateMany({
      where: { status: 'uploading', leaseUntil: { lt: new Date() } },
      data: {
        status: 'failed',
        errorCode: 'ATTACHMENT_UPLOAD_INTERRUPTED',
        leaseToken: null,
        leaseUntil: null,
      },
    });
    // 多实例只通过CAS领取一个附件。
    const candidate = await this.prisma.assistantAttachment.findFirst({
      where: {
        status: 'processing',
        OR: [{ leaseUntil: null }, { leaseUntil: { lt: new Date() } }],
      },
      orderBy: { createdAt: 'asc' },
    });
    if (!candidate) return;
    // 解析产物和当前租约使用同一不可变代次。
    const token = randomUUID();
    // 原件读取15秒、解析30秒、并行产物写入15秒，总预算留足120秒。
    const claimed = await this.prisma.assistantAttachment.updateMany({
      where: {
        id: candidate.id,
        status: 'processing',
        OR: [{ leaseUntil: null }, { leaseUntil: { lt: new Date() } }],
      },
      data: { leaseToken: token, leaseUntil: new Date(Date.now() + 120000) },
    });
    if (!claimed.count) return;
    try {
      // 解析器仅获得原字节与扩展名，不获得服务凭据。
      const parsed = await this.parser.parse(
        await this.objects.get(candidate.objectKey),
        extname(candidate.name).slice(1).toLowerCase(),
      );
      // 每个解析代次产生新的不可变键，旧worker无法覆盖新结果。
      const prefix = `${candidate.userId}/${candidate.id}/${token}`;
      // 清单只包含有限文字，不包含base64。
      const manifestKey = `${prefix}/manifest.json`;
      // 图片对象分别保存，仅JSON引用进入数据库。
      const images: StoredImage[] = parsed.images.map((image, index) => ({
        ...(image.page === undefined ? {} : { page: image.page }),
        key: `${prefix}/image-${index + 1}.jpg`,
      }));
      // 网络写入之前登记兜底GC，进程崩溃也不会永久遗留产物。
      const gcId = await this.prisma.$transaction((transaction) =>
        this.queueKeys(
          transaction,
          candidate,
          [manifestKey, ...images.map((image) => image.key)],
          10 * 60000,
        ),
      );
      await Promise.all([
        this.objects.put(
          manifestKey,
          Buffer.from(
            JSON.stringify({
              version: 1,
              chunks: parsed.chunks,
            } satisfies StoredManifest),
          ),
          'application/json',
        ),
        ...parsed.images.map((image, index) =>
          this.objects.put(
            images[index]!.key,
            Buffer.from(image.data, 'base64'),
            image.mimeType,
          ),
        ),
      ]);
      await this.prisma.$transaction(async (transaction) => {
        // 与消息绑定、移除和会话删除共用owner锁，清理快照不能漏掉刚发布的产物。
        await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id=${candidate.userId}::uuid FOR UPDATE`;
        // 删除、重试或租约接管后只能留下待GC对象，不能重新发布。
        const updated = await transaction.assistantAttachment.updateMany({
          where: {
            id: candidate.id,
            status: 'processing',
            leaseToken: token,
            leaseUntil: { gt: new Date() },
          },
          data: {
            status: 'ready',
            manifestKey,
            imageKeys: images as unknown as Prisma.InputJsonValue,
            chunkCount: parsed.chunks.length,
            units: parsed.units,
            requiresVision: parsed.requiresVision,
            kind: parsed.kind,
            errorCode: null,
            leaseToken: null,
            leaseUntil: null,
          },
        });
        if (updated.count)
          await transaction.assistantAttachmentGc.deleteMany({
            where: { id: gcId },
          });
      });
    } catch (error) {
      await this.prisma.assistantAttachment.updateMany({
        where: { id: candidate.id, status: 'processing', leaseToken: token },
        data: {
          status: 'failed',
          errorCode:
            error instanceof AttachmentParseError
              ? error.code
              : 'ATTACHMENT_PARSE_FAILED',
          leaseToken: null,
          leaseUntil: null,
        },
      });
    }
  }

  /// 清除24小时未绑定草稿和已登记的孤立对象，失败采用持久退避。
  async collect(): Promise<void> {
    // 每轮有限清理，不能长时间占用工作器。
    const expired = await this.prisma.assistantAttachment.findMany({
      where: {
        status: { not: 'deleted' },
        message: null,
        createdAt: { lt: new Date(Date.now() - 24 * 3600000) },
      },
      take: 20,
    });
    for (const candidate of expired)
      await this.prisma.$transaction(async (transaction) => {
        // 与发送事务争用同owner锁，发送先完成时不能删除附件。
        await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id=${candidate.userId}::uuid FOR UPDATE`;
        // 事务中重新检查绑定事实。
        const row = await transaction.assistantAttachment.findFirst({
          where: {
            id: candidate.id,
            status: { not: 'deleted' },
            message: null,
          },
        });
        if (!row) return;
        await this.queueKeys(transaction, row, this.keys(row));
        await transaction.assistantAttachment.update({
          where: { id: row.id },
          data: { status: 'deleted', leaseToken: null, leaseUntil: null },
        });
      });
    // 任务在对象删除成功前不会移出数据库。
    const jobs = await this.prisma.assistantAttachmentGc.findMany({
      where: { availableAt: { lte: new Date() } },
      orderBy: { availableAt: 'asc' },
      take: 5,
    });
    for (const job of jobs) {
      try {
        // 兜底任务不能删除已经成功发布或仍引用的对象。
        const live = await this.prisma.assistantAttachment.findFirst({
          where: {
            id: job.attachmentId,
            userId: job.userId,
            status: { not: 'deleted' },
          },
        });
        // 当前有效引用均受保护。
        const protectedKeys = new Set(live ? this.keys(live) : []);
        for (const key of job.keys as unknown as string[])
          if (!protectedKeys.has(key)) await this.objects.delete(key);
        await this.prisma.assistantAttachmentGc.deleteMany({
          where: { id: job.id },
        });
      } catch {
        await this.prisma.assistantAttachmentGc.updateMany({
          where: { id: job.id },
          data: {
            attempts: { increment: 1 },
            availableAt: new Date(
              Date.now() +
                Math.min(3600000, 30000 * 2 ** Math.min(job.attempts, 7)),
            ),
          },
        });
      }
    }
  }
}
