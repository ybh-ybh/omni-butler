import { BadRequestException, ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { z } from 'zod';
import type { AuthUser } from '../auth/auth.types';
import { businessWrite, withinBusinessTransaction } from '../business/business-access';
import { NotesBusinessService } from '../business/notes-business.service';
import type { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { NOTE_MAX_BODY_LENGTH } from '../sync/note-sync';
import { stableBusinessId } from '../sync/sync-consistency';

/// 已提交的保存事实不随笔记后续编辑或删除而变化。
export interface SavedAssistantNote {
  /// 首次创建的真实笔记身份。
  noteId: string;
  /// 首次保存成功的服务器时间。
  savedAt: string;
}

/// 外层回执仅绑定来源消息，正文和时区变更不产生第二次保存。
const saveAction = 'assistant.message.save-note';
/// 读取持久回执时只接受可安全公开的最小事实。
const savedNoteSchema = z.strictObject({ noteId: z.uuid(), savedAt: z.iso.datetime({ offset: true }) });

/// 人工保存回答直接调用笔记领域服务，不创建助手任务或调用模型。
@Injectable()
export class AssistantMessageNotes {
  /// 复用现有数据库事务及笔记校验与版本生成逻辑。
  constructor(
    private readonly prisma: PrismaService,
    private readonly notes: NotesBusinessService,
  ) {}

  /// 稳定外层身份使重复点击、断网重试和跨设备保存得到同一笔记。
  private operationId(userId: string, messageId: string): string {
    return stableBusinessId('assistant-message-save-note', [userId, messageId]);
  }

  /// 首次只保存已结束的持久正文；重放在来源授权后优先复用回执。
  async save(actor: AuthUser, messageId: string, body: unknown): Promise<SavedAssistantNote> {
    z.uuid().parse(messageId);
    z.strictObject({}).parse(body === undefined ? {} : body);
    return withinBusinessTransaction(this.prisma, actor, async (transaction) => {
      // 不接受客户端正文，来源身份及内容都从同归属持久消息读取。
      const message = await transaction.assistantMessage.findFirst({ where: { id: messageId, userId: actor.sub, role: 'assistant' } });
      if (!message || !await transaction.assistantConversation.findFirst({ where: { id: message.conversationId, userId: actor.sub } })) throw new NotFoundException('回答不存在或会话已删除');
      // 外层摘要不包含可能跨日变化的正文、时区或客户端时间。
      const result = await businessWrite(this.prisma, actor, saveAction, { operationId: this.operationId(actor.sub, messageId), messageId }, async (locked) => {
        // 有效租约尚未释放时，等待正文收尾，即使公开状态已经改变。
        const generating = await locked.assistantRun.findFirst({
          where: {
            userId: actor.sub,
            conversationId: message.conversationId,
            OR: [{ answerMessageId: messageId }, { answerMessageId: null, taskId: message.taskId }],
            AND: [{ OR: [{ status: { in: ['queued', 'running'] } }, { leaseOwner: { not: null }, leaseUntil: { gt: new Date() } }] }],
          },
          select: { id: true },
        });
        if (generating) throw new ConflictException({ code: 'ASSISTANT_MESSAGE_IN_PROGRESS', message: '回答仍在生成，请完成后再保存' });
        if (!message.content.trim()) throw new BadRequestException('回答正文为空，无法保存为笔记');
        if (message.content.length > NOTE_MAX_BODY_LENGTH) throw new BadRequestException(`回答超过笔记 ${NOTE_MAX_BODY_LENGTH} 字符上限，无法完整保存`);
        // 使用当前真实助手业务时区，旧账号未初始化时沿用设置默认值。
        const settings = await locked.assistantSettings.findUnique({ where: { userId: actor.sub }, select: { timeZone: true } });
        // 内层身份与外层回执分离，首版本、笔记和两个回执共同提交。
        const created = await this.notes.create(actor, {
          operationId: stableBusinessId('assistant-message-note-create', [actor.sub, messageId]),
          body: message.content,
          timeZone: settings?.timeZone ?? 'Asia/Shanghai',
        });
        // 服务端生成的笔记创建事实即为本次保存结果，不复制正文到外层回执。
        const saved = z.object({ note: z.object({ id: z.uuid(), createdAt: z.iso.datetime({ offset: true }) }) }).parse(created);
        return { noteId: saved.note.id, savedAt: saved.note.createdAt };
      });
      return savedNoteSchema.parse(result);
    });
  }

  /// 当前页一次查询恢复保存状态，旧消息没有回执时保持原公开结构。
  async savedForMessages(transaction: Prisma.TransactionClient, userId: string, messageIds: string[]): Promise<Map<string, SavedAssistantNote>> {
    // 虚拟恢复消息可能没有真实 UUID，不作为保存事实的来源。
    const identities = new Map(messageIds.filter((id) => z.uuid().safeParse(id).success).map((id) => [this.operationId(userId, id), id]));
    // 持久结果只供同归属已授权消息页使用。
    const saved = new Map<string, SavedAssistantNote>();
    if (!identities.size) return saved;
    // 同一页最多一百条消息，避免逐消息查回执造成 N+1 请求。
    const receipts = await transaction.businessOperationReceipt.findMany({ where: { userId, action: saveAction, operationId: { in: [...identities.keys()] } }, select: { operationId: true, result: true } });
    for (const receipt of receipts) {
      // 无法识别的旧回执不能伪造已保存状态或阻断整页历史。
      const fact = savedNoteSchema.safeParse(receipt.result);
      // 回执与消息的映射由服务器稳定身份计算。
      const messageId = identities.get(receipt.operationId);
      if (fact.success && messageId) saved.set(messageId, fact.data);
    }
    return saved;
  }
}
