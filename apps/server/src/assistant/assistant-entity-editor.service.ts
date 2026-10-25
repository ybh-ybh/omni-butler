import { BadRequestException, ConflictException, Injectable } from '@nestjs/common';
import { z } from 'zod';
import { createHash } from 'node:crypto';
import type { AuthUser } from '../auth/auth.types';
import { businessWrite, requireActive, withinBusinessTransaction } from '../business/business-access';
import { EventsService } from '../business/events.service';
import { InventoryService } from '../business/inventory.service';
import { MembershipsService } from '../business/memberships.service';
import { NotesBusinessService } from '../business/notes-business.service';
import { QuotesService } from '../business/quotes.service';
import { TimeEntriesService } from '../business/time-entries.service';
import { TodosService } from '../business/todos.service';
import type { Prisma } from '../generated/prisma/client';
import { mcpModules, type McpModule } from '../mcp/mcp-catalog';
import { PrismaService } from '../prisma/prisma.service';
import { stableBusinessId } from '../sync/sync-consistency';
import { canonicalize } from '../sync/sync-hash';

/// 原始主项的规范摘要补足毫秒时间戳精度，不包括随时变化的展示装饰。
export function assistantEntityVersion(record: unknown): string {
  // 统一 Date 和 JSON 日期形状，让数据库快照与响应版本稳定。
  const value: unknown = JSON.parse(JSON.stringify(record));
  return createHash('sha256').update(JSON.stringify(canonicalize(value))).digest('hex');
}

/// 内联编辑只开放领域服务已有的普通字段，不接收归属、生命周期或聚合结构。
const editableFields: Record<McpModule, readonly string[]> = {
  todos: ['title', 'description', 'scheduledDate', 'dueAt', 'reminderAt', 'priorityQuadrant', 'progressUnit'],
  inventory: ['name', 'quantity', 'purchasePriceCents', 'purchaseDate', 'warrantyExpiration', 'purchaseUrl', 'purchasePlatform', 'status', 'notes'],
  time: ['activity', 'startedAt', 'endedAt', 'timeZone', 'notes'],
  notes: ['body', 'isPinned', 'dayKey', 'recordTimeSeconds', 'recordUtcOffsetMinutes'],
  quotes: ['content', 'source', 'isEnabled'],
  memberships: ['name', 'provider', 'description', 'websiteUrl', 'purchasePlatform', 'priceCents', 'billingCycle', 'baseStatus', 'purchaseDate', 'expirationDate', 'isPermanent', 'autoRenew', 'renewalDate', 'needsRenewal', 'expirationReminderEnabled', 'expirationReminderDays', 'renewalReminderEnabled', 'renewalReminderDays', 'reminderTimeMinutes', 'cancelGuide', 'notes'],
  events: ['name', 'category', 'intervalValue', 'intervalUnit', 'reminderEnabled', 'reminderDaysBefore', 'reminderTimeMinutes', 'isArchived', 'notes'],
};

/// 人工编辑结果直接复用领域写入，无模型调用，也不会把编辑转成新增。
@Injectable()
export class AssistantEntityEditor {
  /// 各模块固定依赖防止客户端字段转成任意数据库更新。
  constructor(
    private readonly prisma: PrismaService,
    private readonly todos: TodosService,
    private readonly inventory: InventoryService,
    private readonly time: TimeEntriesService,
    private readonly notes: NotesBusinessService,
    private readonly quotes: QuotesService,
    private readonly memberships: MembershipsService,
    private readonly events: EventsService,
  ) {}

  /// 原请求可重放；版本校验和更新、回执在同一个 owner 锁事务内提交。
  async update(actor: AuthUser, module: string, id: string, body: unknown): Promise<Prisma.JsonValue> {
    // 路由仅允许七个正式业务模块及真实身份。
    const target = z.enum(mcpModules).parse(module);
    z.uuid().parse(id);
    // 外层操作身份和基线参与完整摘要，不能同身份替换正文。
    const input = z.strictObject({ operationId: z.uuid(), expectedUpdatedAt: z.iso.datetime({ offset: true }), expectedVersion: z.string().regex(/^[a-f0-9]{64}$/), changes: z.record(z.string(), z.unknown()) }).parse(body);
    // 必须提供至少一项明确编辑，省略字段交由领域层保持原值。
    const fields = Object.keys(input.changes);
    if (!fields.length || fields.some((field) => !editableFields[target].includes(field))) throw new BadRequestException('包含不可编辑字段或没有修改内容');
    return withinBusinessTransaction(this.prisma, actor, () => businessWrite(this.prisma, actor, 'assistant.entity.update', { ...input, module: target, id }, async (transaction) => {
      // 读取和版本比较发生在授权锁内，不允许编辑回收站对象。
      const current = requireActive(await this.read(transaction, actor.sub, target, id));
      if (current.updatedAt.getTime() !== new Date(input.expectedUpdatedAt).getTime() || assistantEntityVersion(current) !== input.expectedVersion) throw new ConflictException({ code: 'ASSISTANT_ENTITY_CONFLICT', message: '记录已在其他位置修改，请刷新后再编辑' });
      // 派生独立领域回执身份，避免嵌套调用占用外层操作身份。
      const changes: Record<string, unknown> = { ...input.changes, id, operationId: stableBusinessId('assistant-entity-update', [actor.sub, target, id, input.operationId]) };
      if (target === 'notes' && Object.hasOwn(input.changes, 'body')) changes.expectedRevision = 'revision' in current ? current.revision : undefined;
      // 重复待办仅编辑当前实例，不能借内联保存扩大到未来系列。
      if (target === 'todos') changes.scope = 'single';
      await this.write(actor, target, changes);
      // 返回实际最新行，保留领域服务派生日期、修订等字段。
      const record = requireActive(await this.read(transaction, actor.sub, target, id));
      // 标签从业务正文产生，不能由客户端伪造。
      const values = record as unknown as Record<string, unknown>;
      // 保持与只读快照相同的简短标题规则。
      const label = [values.name, values.title, values.activity, values.content, values.body].find((value): value is string => typeof value === 'string' && !!value.trim() && !z.uuid().safeParse(value.trim()).success)?.trim().slice(0, 80) ?? '记录';
      return { module: target, id, label, record, editVersion: assistantEntityVersion(record), serverSaved: true };
    }));
  }

  /// 固定查询分支逐一绑定 owner，不进行动态模型访问。
  private read(transaction: Prisma.TransactionClient, userId: string, module: McpModule, id: string): Promise<{ updatedAt: Date; deletedAt: Date | null; revision?: string } | null> {
    // 跨用户对象与不存在对象得到相同的拒绝结果。
    const where = { userId, id };
    switch (module) {
      case 'todos': return transaction.todoItem.findFirst({ where });
      case 'inventory': return transaction.inventoryItem.findFirst({ where });
      case 'time': return transaction.timeEntry.findFirst({ where });
      case 'notes': return transaction.noteEntry.findFirst({ where });
      case 'quotes': return transaction.quote.findFirst({ where });
      case 'memberships': return transaction.membership.findFirst({ where });
      case 'events': return transaction.event.findFirst({ where });
    }
  }

  /// 七模块仍由已有领域服务负责字段校验、关系保护及同步一致性。
  private write(actor: AuthUser, module: McpModule, changes: Record<string, unknown>): Promise<Prisma.JsonValue> {
    switch (module) {
      case 'todos': return this.todos.update(actor, changes);
      case 'inventory': return this.inventory.update(actor, changes);
      case 'time': return this.time.update(actor, changes);
      case 'notes': return this.notes.update(actor, changes);
      case 'quotes': return this.quotes.update(actor, changes);
      case 'memberships': return this.memberships.update(actor, changes);
      case 'events': return this.events.update(actor, changes);
    }
  }
}
