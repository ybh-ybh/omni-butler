import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { AuthUser } from '../auth/auth.types';
import {
  Prisma,
  type AssistantRun,
  type AssistantMessage,
  type AssistantTask,
} from '../generated/prisma/client';
import { ActionExecutor } from '../mcp/action-executor';
import { assertAssistantMemoryContent } from './assistant-context.service';
import { withinBusinessTransaction } from '../business/business-access';
import { timeZoneInput } from '../business/business-input';
import { AiService } from '../ai/ai.service';
import { PrismaService } from '../prisma/prisma.service';
import {
  assistantActive,
  assistantDecisionInput,
  assistantJson,
  assistantMemoryInput,
  assistantMessageInput,
  assistantSettingsInput,
  type AssistantState,
} from './assistant.types';

/// 会话、确认和记忆的权威存储，图checkpoint不授予写入权限。
@Injectable()
export class AssistantStore {
  /// 复用设备归属、模型配置及同事务owner锁。
  constructor(
    readonly prisma: PrismaService,
    private readonly ai: AiService,
    private readonly actions: ActionExecutor,
  ) {}

  /// 任意入口都重验设备会话，避免缓存JWT越过撤权。
  async authorized<T>(
    actor: AuthUser,
    action: (transaction: Prisma.TransactionClient) => Promise<T>,
  ): Promise<T> {
    return withinBusinessTransaction(this.prisma, actor, action);
  }

  /// 首次沿用当前模型，但助手开关默认关闭。
  async settings(actor: AuthUser): Promise<unknown> {
    return this.authorized(actor, async (transaction) => {
      // 两种用途共享配置但分别选择。
      const defaults = await transaction.aiSettings.findUnique({
        where: { userId: actor.sub },
      });
      // 设置仅在本归属下初始化。
      const settings = await transaction.assistantSettings.upsert({
        where: { userId: actor.sub },
        create: { userId: actor.sub, profileId: defaults?.activeProfileId },
        update: {},
      });
      // 永远不选择密文列进入返回对象。
      const profiles = await transaction.aiProfile.findMany({
        where: { userId: actor.sub },
        select: {
          id: true,
          name: true,
          provider: true,
          baseUrl: true,
          model: true,
          encryptedApiKey: true,
          revision: true,
        },
      });
      return {
        ...settings,
        profiles: profiles.map(({ encryptedApiKey, ...profile }) => ({
          ...profile,
          hasApiKey: !!encryptedApiKey,
          keyConfigured: !!encryptedApiKey,
        })),
      };
    });
  }

  /// 乐观版本防止两端设置静默覆盖。
  async updateSettings(actor: AuthUser, raw: unknown): Promise<unknown> {
    // 先校验整个输入，不使用默认空表覆盖服务器。
    const input = assistantSettingsInput.parse(raw);
    timeZoneInput(input.timeZone);
    await this.settings(actor);
    if (input.enabled) {
      if (!input.profileId) throw new BadRequestException('请先选择助手模型');
      await this.ai.captureAssistantProfile(actor.sub, input.profileId);
    }
    await this.authorized(actor, async (transaction) => {
      // 同一owner锁保护配置与未执行任务撤销。
      const previous = await transaction.assistantSettings.findUnique({
        where: { userId: actor.sub },
      });
      const changed = await transaction.assistantSettings.updateMany({
        where: { userId: actor.sub, revision: input.revision },
        data: { ...input, revision: { increment: 1 } },
      });
      if (!changed.count)
        throw new ConflictException('助手设置已变更，请刷新后重试');
      if (!input.enabled) await this.cancelAll(transaction, actor.sub);
      // 关闭记忆读取立即废弃已注入的上下文，不能等下一次自然重载。
      if (previous && previous.memoryReadEnabled !== input.memoryReadEnabled)
        await this.invalidateMemories(transaction, actor.sub, []);
    });
    return this.settings(actor);
  }

  /// 会话按更新时间及身份稳定分页，两端共享同一历史。
  async conversations(
    actor: AuthUser,
    cursorId?: string,
    query?: string,
  ): Promise<unknown> {
    if (cursorId) z.uuid().parse(cursorId);
    // 空白查询沿用最近会话列表；正文搜索不接受无界字符串。
    const search = z.string().trim().max(200).optional().parse(query);
    return this.authorized(actor, async (transaction) => {
      // 游标必须来自当前归属，不能作为跨 owner 的时间探针。
      const cursor = cursorId
        ? await transaction.assistantConversation.findFirst({
            where: { id: cursorId, userId: actor.sub },
          })
        : null;
      if (cursorId && !cursor) throw new NotFoundException('会话游标不存在');
      // 明确转义 LIKE 的通配符，反斜杠在自定义转义符下只是普通文字。
      const pattern = search ? `%${search.replace(/[!%_]/g, '!$&')}%` : null;
      // EXISTS 在数据库内去重和分页，不拉取全量消息正文或逐会话查询。
      const matches = pattern
        ? await transaction.$queryRaw<Array<{ id: string }>>(Prisma.sql`
            SELECT conversation.id
            FROM assistant_conversations AS conversation
            WHERE conversation.user_id = ${actor.sub}::uuid
              AND (
                conversation.title ILIKE ${pattern} ESCAPE '!'
                OR EXISTS (
                  SELECT 1 FROM assistant_messages AS message
                  WHERE message.user_id = ${actor.sub}::uuid
                    AND message.conversation_id = conversation.id
                    AND message.role IN ('user', 'assistant')
                    AND message.content ILIKE ${pattern} ESCAPE '!'
                )
              )
              ${
                cursor
                  ? Prisma.sql`AND (conversation.updated_at, conversation.id) < (${cursor.updatedAt}, ${cursor.id}::uuid)`
                  : Prisma.empty
              }
            ORDER BY conversation.updated_at DESC, conversation.id DESC
            LIMIT 101
          `)
        : null;
      // 多取一条只判断是否有下一页，不隐藏第101条之后的会话。
      const rows = await transaction.assistantConversation.findMany({
        where: {
          userId: actor.sub,
          ...(matches ? { id: { in: matches.map((match) => match.id) } } : {}),
          ...(cursor
            ? {
                OR: [
                  { updatedAt: { lt: cursor.updatedAt } },
                  { updatedAt: cursor.updatedAt, id: { lt: cursor.id } },
                ],
              }
            : {}),
        },
        orderBy: [{ updatedAt: 'desc' }, { id: 'desc' }],
        take: 101,
      });
      // 返回的最后一个已展示身份作为后续页游标。
      const items = rows.slice(0, 100);
      return { items, nextCursor: rows.length > 100 ? items.at(-1)!.id : null };
    });
  }

  /// 新建只产生聊天容器，不触发模型计费。
  async createConversation(actor: AuthUser, raw: unknown): Promise<unknown> {
    // 可选标题仅是显示文字。
    const input = z
      .strictObject({ title: z.string().trim().min(1).max(100).optional() })
      .parse(raw);
    return this.authorized(actor, (transaction) =>
      transaction.assistantConversation.create({
        data: {
          id: randomUUID(),
          userId: actor.sub,
          title: input.title ?? '新对话',
        },
      }),
    );
  }

  /// 重命名和置顶只作用于当前归属，不根据裸UUID访问记录。
  async rename(actor: AuthUser, id: string, raw: unknown): Promise<unknown> {
    // 保持旧重命名契约兼容，同时拒绝空更新和未知字段。
    const input = z
      .strictObject({
        title: z.string().trim().min(1).max(100).optional(),
        isPinned: z.boolean().optional(),
      })
      .refine(
        (value) => value.title !== undefined || value.isPinned !== undefined,
      )
      .parse(raw);
    return this.authorized(actor, async (transaction) => {
      await this.conversation(transaction, actor.sub, id);
      // 仅改变置顶时保留活动时间，取消置顶后不会跳到历史列表最前。
      const previous =
        await transaction.assistantConversation.findUniqueOrThrow({
          where: { id },
        });
      return transaction.assistantConversation.update({
        where: { id },
        data: {
          ...input,
          ...(input.title === undefined
            ? { updatedAt: previous.updatedAt }
            : {}),
        },
      });
    });
  }

  /// 删除聊天清理正文及checkpoint，保留业务回执和防覆盖证据。
  async removeConversation(actor: AuthUser, id: string): Promise<unknown> {
    return this.authorized(actor, async (transaction) => {
      await this.conversation(transaction, actor.sub, id);
      // 所有旧运行先失效，迟到结果不能复活聊天。
      const runs = await transaction.assistantRun.findMany({
        where: { userId: actor.sub, conversationId: id },
        select: { id: true },
      });
      await this.cancelAll(transaction, actor.sub, id);
      await this.deleteCheckpoints(
        transaction,
        runs.map((run) => run.id),
      );
      await transaction.assistantEvent.deleteMany({
        where: { userId: actor.sub, runId: { in: runs.map((run) => run.id) } },
      });
      await transaction.assistantAttempt.deleteMany({
        where: { userId: actor.sub, runId: { in: runs.map((run) => run.id) } },
      });
      await transaction.assistantMessage.deleteMany({
        where: { userId: actor.sub, conversationId: id },
      });
      await transaction.assistantRun.deleteMany({
        where: { userId: actor.sub, conversationId: id },
      });
      await transaction.assistantTask.deleteMany({
        where: { userId: actor.sub, conversationId: id },
      });
      await transaction.assistantConversation.delete({ where: { id } });
      return { ok: true };
    });
  }

  /// 消息分页与真实回执只读恢复，不重新调用业务或付费模型。
  async messages(
    actor: AuthUser,
    id: string,
    before?: string,
  ): Promise<unknown> {
    if (before) z.uuid().parse(before);
    return this.authorized(actor, async (transaction) => {
      await this.conversation(transaction, actor.sub, id);
      // 游标必须是本会话已保存的消息，临时恢复卡片不作为分页游标。
      const cursor = before
        ? await transaction.assistantMessage.findFirst({
            where: { id: before, userId: actor.sub, conversationId: id },
          })
        : null;
      if (before && !cursor) throw new NotFoundException('消息游标不存在');
      // 最新运行包括失败和停止状态，保存事实不能随回答失败而消失。
      const active = await transaction.assistantRun.findFirst({
        where: { userId: actor.sub, conversationId: id },
        orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      });
      // 多取一条使恢复卡片挤入首屏时仍能正确计算下一页。
      const rows = await transaction.assistantMessage.findMany({
        where: {
          userId: actor.sub,
          conversationId: id,
          ...(cursor
            ? {
                OR: [
                  { createdAt: { lt: cursor.createdAt } },
                  { createdAt: cursor.createdAt, id: { lt: cursor.id } },
                ],
              }
            : {}),
        },
        orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
        take: 101,
      });
      // 只在首屏合成，历史页保持普通持久消息游标，不重复恢复。
      const recovered =
        !before && active
          ? await this.recoverReceiptMessage(transaction, active)
          : null;
      // 同稳定 messageId 覆盖展示副本，不写回数据库或覆盖已有人工作品。
      const merged = recovered
        ? [...rows.filter((message) => message.id !== recovered.id), recovered]
        : rows;
      merged.sort(
        (left, right) =>
          right.createdAt.getTime() - left.createdAt.getTime() ||
          right.id.localeCompare(left.id),
      );
      // 每页最多一百项，恢复副本不能造成持久消息被跳过。
      const page = merged.slice(0, 100);
      // 游标始终选取当前页最后一条真实持久消息。
      const oldestPersisted = [...page]
        .reverse()
        .find((message) => rows.some((row) => row.id === message.id));
      // 只读取本页回答的计时列，不读取可清理状态或模型密钥。
      const durations = await transaction.assistantRun.findMany({
        where: {
          userId: actor.sub,
          conversationId: id,
          answerMessageId: {
            in: page
              .filter((message) => message.role === 'assistant')
              .map((message) => message.id),
          },
        },
        select: {
          answerMessageId: true,
          elapsedMs: true,
          leaseOwner: true,
          leaseUntil: true,
        },
      });
      // 每个持久运行只累加一次；同一任务的不同回答不会相互借用时长。
      const elapsedByMessage = new Map<string, number>();
      // 正文先落库的回答不展示临时零值或上一执行段的旧时长。
      const pendingMessages = new Set<string>();
      for (const duration of durations) {
        if (duration.answerMessageId) {
          if (this.timingPending(duration))
            pendingMessages.add(duration.answerMessageId);
          elapsedByMessage.set(
            duration.answerMessageId,
            (elapsedByMessage.get(duration.answerMessageId) ?? 0) +
              duration.elapsedMs,
          );
        }
      }
      return {
        items: page.reverse().map((message) => ({
          ...message,
          elapsedMs:
            message.role === 'assistant' && !pendingMessages.has(message.id)
              ? (elapsedByMessage.get(message.id) ?? null)
              : null,
          cards: (message.cards as Array<Record<string, unknown>>).filter(
            (card) => card.type !== 'userInput',
          ),
        })),
        activeRun: active
          ? await this.runView(transaction, active, actor.sid)
          : null,
        nextCursor: merged.length > 100 ? (oldestPersisted?.id ?? null) : null,
      };
    });
  }

  /// 回执是已经保存的事实，合成卡片不会重放工具或恢复执行授权。
  private async recoverReceiptMessage(
    transaction: Prisma.TransactionClient,
    run: AssistantRun,
  ): Promise<AssistantMessage | null> {
    // 遗忘后的运行不再恢复旧状态或旧资料。
    const state = run.state as unknown as Partial<AssistantState>;
    if (state.memoryInvalidated || !z.uuid().safeParse(state.messageId).success)
      return null;
    // 任务归属与会话必须对应，不能跨任务借用成功回执。
    const task = await transaction.assistantTask.findFirst({
      where: {
        id: run.taskId,
        userId: run.userId,
        conversationId: run.conversationId,
      },
    });
    if (!task) return null;
    // 真实结果包括正文冲突候选，未执行或只有预览的动作没有 result。
    const actions = await transaction.mcpAction.findMany({
      where: {
        userId: run.userId,
        source: 'assistant',
        sourceId: run.taskId,
        status: { in: ['succeeded', 'conflict'] },
        result: { not: Prisma.DbNull },
      },
      orderBy: [{ updatedAt: 'asc' }, { id: 'asc' }],
    });
    // 显式动作和批次事实允许来自原运行提交，普通旧动作不能冒充新补偿结果。
    const plan = task.plan as Record<string, unknown> | null;
    // 多批的已执行身份是服务端冻结计划保存的实际回执。
    const batch = plan?.batchPlan as
      | { results?: Array<{ actionId?: string }>; requestIds?: string[] }
      | undefined;
    // 只信任内部持久身份，不从正文或显示文字提取 UUID。
    const actionIds = new Set(
      [
        state.actionId,
        ...(task.runId === run.id && task.actionId ? [task.actionId] : []),
        ...(batch?.results?.map((entry) => entry.actionId) ?? []),
      ].filter((value): value is string => typeof value === 'string'),
    );
    // 同任务重试可能继承原回执；无身份时仅接受本运行开始后的提交。
    const receipts = actions.filter(
      (action) =>
        action.result !== null &&
        (actionIds.has(action.id) ||
          (!state.undoOf && action.updatedAt >= run.createdAt)),
    );
    // 优先使用已丰富引用的持久 state；缺失时只投影真实数据库回执。
    let result =
      state.result &&
      typeof state.result === 'object' &&
      !Array.isArray(state.result)
        ? { ...(state.result as Record<string, unknown>) }
        : null;
    if (!result && receipts.length) {
      // 内部后置摘要不是用户结果，保护证据及业务值保持原样。
      const values = receipts.map((action) => {
        // 复制后移除私有摘要，不修改原数据库回执。
        const value = { ...(action.result as Record<string, unknown>) };
        delete value.afterBaseline;
        return { actionId: action.id, status: action.status, result: value };
      });
      if (plan?.kind === 'batch' || values.length > 1) {
        // 完成比例由实际回执数量及冻结批次计划决定。
        const total = batch?.requestIds?.length ?? values.length;
        result = {
          values: values.flatMap((entry) =>
            Array.isArray(entry.result.values)
              ? (entry.result.values as unknown[])
              : [],
          ),
          completedBatches: values.length,
          totalBatches: total,
          partial: values.length < total,
          atomic: false,
          batchResults: values,
        };
      } else result = values[0]!.result;
    }
    if (!result) return null;
    // 候选已保存不代表正式正文采用，停止也不代表撤销已经成功的批次。
    const conflict =
      state.conflict === true ||
      receipts.some((action) => action.status === 'conflict') ||
      (Array.isArray(result.values) &&
        result.values.some(
          (value) =>
            !!value &&
            typeof value === 'object' &&
            (value as Record<string, unknown>).status === 'conflict',
        ));
    // 部分完成必须明确提示剩余目标没有继续执行。
    const partial =
      result.partial === true ||
      (typeof result.completedBatches === 'number' &&
        typeof result.totalBatches === 'number' &&
        result.completedBatches < result.totalBatches);
    // 说明仅描述实际保存事实，不把失败文字改成成功。
    const message = conflict
      ? '冲突候选已保存，正式正文未采用；实际结果如下。'
      : partial
        ? '部分批次已保存；其余批次尚未完成，停止不会撤销已保存内容。'
        : run.status === 'cancelled'
          ? '任务已停止，停止前已经保存的结果如下；未执行任何额外操作。'
          : run.status === 'succeeded'
            ? '服务器已保存，实际结果如下。'
            : run.status === 'running'
              ? '服务器已经保存这些结果，正在整理回答。'
              : '服务器已经保存这些结果；回答未完成不影响实际保存事实。';
    // 稳定消息身份来自运行创建时，不能生成第二个会话结果。
    const existing = await transaction.assistantMessage.findFirst({
      where: {
        id: state.messageId,
        userId: run.userId,
        conversationId: run.conversationId,
      },
    });
    if (existing && existing.role !== 'assistant') return null;
    // 新引用只使用现有服务器结果，缺少时不猜测业务对象 ID。
    const card: Record<string, unknown> = {
      type: conflict ? 'conflict' : 'result',
      result,
      message,
      syncStatus: 'serverSaved',
      recovered: true,
      ...(Array.isArray(result.entityRefs)
        ? { entityRefs: result.entityRefs }
        : {}),
      ...(state.actionId ? { actionId: state.actionId } : {}),
    };
    // 保留错误、选择等其他卡片和原聊天文字，只补充当前真实结果。
    const cards = existing
      ? (existing.cards as Array<Record<string, unknown>>).filter(
          (entry) => !['result', 'conflict'].includes(String(entry.type)),
        )
      : [];
    cards.push(card);
    // 时间采用真实回执时间，不随每次 GET 改动分页顺序。
    const savedAt = receipts.at(-1)?.updatedAt ?? run.updatedAt;
    return existing
      ? { ...existing, cards: assistantJson(cards) as Prisma.JsonValue }
      : {
          id: state.messageId!,
          userId: run.userId,
          conversationId: run.conversationId,
          taskId: run.taskId,
          clientMessageId: null,
          role: 'assistant',
          content: message,
          cards: assistantJson(cards) as Prisma.JsonValue,
          excluded: false,
          createdAt: savedAt,
        };
  }

  /// 消息与任务续接共用 owner 事务，修订不会另起任务绕过批量确认。
  async send(actor: AuthUser, id: string, raw: unknown): Promise<unknown> {
    // 参数及选择身份先通过严格契约校验。
    const input = assistantMessageInput.parse(raw);
    if (input.timeZone) timeZoneInput(input.timeZone);
    return this.authorized(actor, async (transaction) => {
      await this.conversation(transaction, actor.sub, id);
      // 输入元数据与稳定消息身份绑定，不能重复身份改选目标。
      const metadata = {
        type: 'userInput',
        timeZone: input.timeZone ?? null,
        selection: input.selection ?? null,
        reference: input.reference ?? null,
      };
      // 原消息重放优先返回任务当前真实运行。
      const existing = await transaction.assistantMessage.findUnique({
        where: {
          userId_clientMessageId: {
            userId: actor.sub,
            clientMessageId: input.clientMessageId,
          },
        },
      });
      if (existing) {
        // 本期尚无旧助手客户端，消息元数据必须完全一致。
        const recorded = (
          existing.cards as Array<Record<string, unknown>>
        ).find((card) => card.type === 'userInput');
        if (
          existing.conversationId !== id ||
          existing.content !== input.content ||
          recorded?.timeZone !== metadata.timeZone ||
          (recorded?.selection as { id?: string; module?: string } | null)
            ?.id !== input.selection?.id ||
          (recorded?.selection as { id?: string; module?: string } | null)
            ?.module !== input.selection?.module ||
          (recorded?.reference as { id?: string; module?: string } | null)
            ?.id !== input.reference?.id ||
          (recorded?.reference as { id?: string; module?: string } | null)
            ?.module !== input.reference?.module
        )
          throw new ConflictException('同一消息身份不能提交不同内容或选择');
        // 即使经过接管、修订或补偿也返回同任务当前执行事实。
        const task = await transaction.assistantTask.findUniqueOrThrow({
          where: { id: existing.taskId },
        });
        return this.runView(
          transaction,
          await transaction.assistantRun.findUniqueOrThrow({
            where: { id: task.runId },
          }),
          actor.sid,
        );
      }
      // 当前任务先于模型配置读取，取消不依赖仍有效的供应商配置。
      const active = await transaction.assistantTask.findFirst({
        where: {
          userId: actor.sub,
          conversationId: id,
          status: { in: assistantActive },
        },
      });
      if (
        active &&
        ['waitingInput', 'waitingConfirmation'].includes(active.status) &&
        !input.selection &&
        !input.reference &&
        /^(?:取消|不用了|算了)[。！!]*$/u.test(input.content)
      ) {
        // 记录取消消息身份，响应丢失后仅重放同一已停止运行。
        await transaction.assistantMessage.create({
          data: {
            id: randomUUID(),
            userId: actor.sub,
            conversationId: id,
            taskId: active.id,
            clientMessageId: input.clientMessageId,
            role: 'user',
            content: input.content,
            cards: assistantJson([metadata]),
          },
        });
        await this.cancelTask(transaction, active.id);
        await transaction.assistantConversation.update({
          where: { id },
          data: { updatedAt: new Date() },
        });
        return this.runView(
          transaction,
          await transaction.assistantRun.findUniqueOrThrow({
            where: { id: active.runId },
          }),
          actor.sid,
        );
      }
      // 开关与模型授权在同一事务重新核验，取消不会进入计费路径。
      const settings = await transaction.assistantSettings.findUnique({
        where: { userId: actor.sub },
      });
      if (!settings?.enabled || !settings.profileId)
        throw new BadRequestException('请先在 AI 设置中配置并开启助手');
      if (
        active &&
        !['waitingInput', 'waitingConfirmation'].includes(active.status)
      )
        throw new ConflictException({
          code: 'ASSISTANT_TASK_ACTIVE',
          message: '请先完成、修改或取消当前任务',
        });
      // 复用当前任务的原始要求，模型历史从合法聊天消息重新加载。
      const previous = active
        ? await transaction.assistantRun.findUniqueOrThrow({
            where: { id: active.runId },
          })
        : null;
      // 对象卡片选择必须来自该任务最后一张有效候选卡片。
      if (input.selection) {
        if (!active || active.status !== 'waitingInput')
          throw new ConflictException('当前没有等待选择的对象');
        // 不接受其他任务或旧会话卡片中的身份。
        const question = await transaction.assistantMessage.findFirst({
          where: { userId: actor.sub, taskId: active.id, role: 'assistant' },
          orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
        });
        // 模型提供的候选仍只是资料，实际调用由领域层复核 owner。
        const choices =
          (question?.cards as Array<Record<string, unknown>> | undefined)
            ?.filter((card) => card.type === 'choice')
            .flatMap((card) =>
              Array.isArray(card.choices)
                ? (card.choices as Array<Record<string, unknown>>)
                : [],
            ) ?? [];
        if (
          !choices.some(
            (choice) =>
              choice.id === input.selection!.id &&
              choice.module === input.selection!.module,
          )
        )
          throw new ConflictException('对象选项已失效，请重新查看当前候选');
      }
      if (input.reference) {
        // 只有本会话真实结果卡中的对象可作为编辑引用，不能任意指定 UUID。
        const source = await transaction.assistantMessage.findFirst({
          where: {
            userId: actor.sub,
            conversationId: id,
            role: 'assistant',
            cards: {
              array_contains: assistantJson([
                { type: 'result', entityRefs: [input.reference] },
              ]),
            },
          },
        });
        // 恢复卡没有写回消息，但其引用仍可来自本会话实际持久结果。
        const recovered = !source
          ? await transaction.assistantRun.findFirst({
              where: {
                userId: actor.sub,
                conversationId: id,
                state: {
                  path: ['result', 'entityRefs'],
                  array_contains: assistantJson([input.reference]),
                },
              },
              orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
            })
          : null;
        // 遗忘状态不能作为恢复引用来源，UUID须在服务器真实结果里出现。
        if (
          !source &&
          (!recovered ||
            (recovered.state as Record<string, unknown>).memoryInvalidated ===
              true)
        )
          throw new ConflictException(
            '结果引用已失效，请从本会话实际结果选择对象',
          );
      }
      // 当前密文配置只写私有运行记录。
      const profile = await this.ai.captureAssistantProfile(
        actor.sub,
        settings.profileId,
      );
      // 重复网络请求由消息身份重放，不会重新生成这些身份。
      const taskId = active?.id ?? randomUUID(),
        runId = randomUUID();
      // 在运行状态和消息行中固定同一来源身份，消除同毫秒消息排序歧义。
      const userMessageId = randomUUID();
      // 使用新 run 清空旧供应商调用，避免 ask_user 未配对项进入下一轮。
      const previousState = previous?.state as unknown as
        | Partial<AssistantState>
        | undefined;
      // 累积要求只表达当前任务，修订仍须重新收集完整计划。
      const request = previousState?.request
        ? `${previousState.request}\n\n用户补充或修订：${input.content}`
        : input.content;
      // 选项是固定数据引用，绝不作为执行授权。
      const state: AssistantState = {
        input: [],
        intents: [],
        calls: [],
        toolCount: 0,
        modelCount: 0,
        messageId: randomUUID(),
        request,
        userMessageId,
        originalRequest:
          previousState?.originalRequest ??
          previousState?.request ??
          input.content,
        text: '',
        memoryVersion: settings.memoryVersion,
        timeZone:
          input.timeZone ?? previousState?.timeZone ?? settings.timeZone,
        ...(input.selection ? { selection: input.selection } : {}),
        ...(input.reference ? { reference: input.reference } : {}),
      };
      if (active) {
        // 修订与原提交竞争同一 owner 锁；已提交状态不能走此分支。
        if (active.committed)
          throw new ConflictException('已提交的任务不能修改计划，请发送新任务');
        await this.cancelTask(transaction, active.id);
        // 保留版本递增历史，使旧确认卡片永久失效。
        await transaction.assistantTask.update({
          where: { id: active.id },
          data: {
            runId,
            sessionId: actor.sid,
            status: 'queued',
            plan: Prisma.DbNull,
            approvedHash: null,
            actionId: null,
            planRequestId: null,
            committed: false,
          },
        });
        await this.deleteCheckpoints(
          transaction,
          previous ? [previous.id] : [],
        );
      } else {
        await transaction.assistantTask.create({
          data: {
            id: taskId,
            userId: actor.sub,
            conversationId: id,
            sessionId: actor.sid,
            runId,
          },
        });
      }
      await transaction.assistantMessage.create({
        data: {
          id: userMessageId,
          userId: actor.sub,
          conversationId: id,
          taskId,
          clientMessageId: input.clientMessageId,
          role: 'user',
          content: input.content,
          cards: assistantJson([metadata]),
        },
      });
      await transaction.assistantConversation.update({
        where: { id },
        data: {
          updatedAt: new Date(),
          ...((await transaction.assistantMessage.count({
            where: { conversationId: id },
          })) === 1
            ? { title: input.content.slice(0, 40) }
            : {}),
        },
      });
      // 租约在新运行生成时为空，旧 worker 无法再使用旧 runId。
      const run = await transaction.assistantRun.create({
        data: {
          id: runId,
          userId: actor.sub,
          conversationId: id,
          taskId,
          sessionId: actor.sid,
          answerMessageId: state.messageId,
          profileSnapshot: assistantJson(profile),
          state: assistantJson(state),
        },
      });
      return this.runView(transaction, run, actor.sid);
    });
  }

  /// 真实预演前先保存独立请求身份，不冒用尚不存在的动作 ID。
  async reservePlanRequest(actor: AuthUser, runId: string): Promise<string> {
    return this.authorized(actor, async (transaction) => {
      // 运行与任务必须仍由当前设备拥有，取消或接管后不能预演。
      const run = await this.ownedRun(transaction, actor, runId);
      // 持久任务是运行资格的唯一来源。
      const task = await transaction.assistantTask.findUniqueOrThrow({
        where: { id: run.taskId },
      });
      if (
        task.runId !== runId ||
        task.sessionId !== actor.sid ||
        run.sessionId !== actor.sid ||
        !['queued', 'running'].includes(run.status) ||
        !['queued', 'running'].includes(task.status)
      )
        throw new ConflictException('助手运行已停止或被接管');
      if (task.planRequestId) return task.planRequestId;
      // 同 owner 锁内分配，重启及重复准备均使用原身份。
      const requestId = randomUUID();
      await transaction.assistantTask.update({
        where: { id: task.id },
        data: { planRequestId: requestId },
      });
      return requestId;
    });
  }

  /// 公开任务状态只包含可展示事实。
  async run(actor: AuthUser, id: string): Promise<unknown> {
    return this.authorized(actor, async (transaction) =>
      this.runView(
        transaction,
        await this.ownedRun(transaction, actor, id),
        actor.sid,
      ),
    );
  }

  /// 计划预览以服务端冻结数据为准。
  async plan(actor: AuthUser, id: string): Promise<unknown> {
    return this.authorized(actor, async (transaction) => {
      // 任务主键也是公开计划身份。
      const task = await transaction.assistantTask.findFirst({
        where: { id, userId: actor.sub },
      });
      if (!task?.plan) throw new NotFoundException('操作计划不存在');
      return task.plan;
    });
  }

  /// 用户确认是认证API事实，模型不能伪造confirmed参数。
  async decision(actor: AuthUser, id: string, raw: unknown): Promise<unknown> {
    // 精确计划版本和预览摘要必须同时一致。
    const input = assistantDecisionInput.parse(raw);
    return this.authorized(actor, async (transaction) => {
      // 共享owner锁保证确认、取消、提交只有一个赢家。
      const task = await transaction.assistantTask.findFirst({
        where: { id, userId: actor.sub },
      });
      if (!task?.plan) throw new NotFoundException('操作计划不存在');
      // 不向已完成任务追加执行授权。
      const plan = task.plan as Record<string, unknown>;
      if (
        task.planVersion !== input.version ||
        plan.previewHash !== input.previewHash
      )
        throw new ConflictException('操作计划已改变，请重新查看');
      if (
        task.committed ||
        !['waitingConfirmation', 'queued'].includes(task.status)
      )
        return this.runView(
          transaction,
          await transaction.assistantRun.findUniqueOrThrow({
            where: { id: task.runId },
          }),
          actor.sid,
        );
      if (
        input.decision === 'confirm' &&
        task.approvedHash === input.previewHash
      )
        return this.runView(
          transaction,
          await transaction.assistantRun.findUniqueOrThrow({
            where: { id: task.runId },
          }),
          actor.sid,
        );
      if (input.decision === 'cancel') {
        await this.cancelTask(transaction, task.id);
      } else {
        // 暂停状态可能先于 worker finally 落库，确认不能抢先清租约丢失本轮用时。
        const current = await transaction.assistantRun.findUniqueOrThrow({
          where: { id: task.runId },
        });
        if (this.timingPending(current))
          throw new ConflictException({
            code: 'ASSISTANT_PROCESSING',
            message: '助手正在完成本轮处理，请稍后再确认',
          });
        // 当前确认设备显式接管，旧worker不能再使用原租约。
        await transaction.assistantTask.update({
          where: { id },
          data: {
            approvedHash: input.previewHash,
            status: 'queued',
            sessionId: actor.sid,
          },
        });
        const queued = await transaction.assistantRun.update({
          where: { id: task.runId },
          data: {
            status: 'queued',
            sessionId: actor.sid,
            leaseOwner: null,
            leaseUntil: null,
          },
        });
        await this.appendRunEvent(transaction, queued);
      }
      return this.runView(
        transaction,
        await transaction.assistantRun.findUniqueOrThrow({
          where: { id: task.runId },
        }),
        actor.sid,
      );
    });
  }

  /// 停止不回滚已提交业务，等待中的动作取消后不能复活。
  async stop(actor: AuthUser, id: string): Promise<unknown> {
    return this.authorized(actor, async (transaction) => {
      // 同owner另一设备也可明确停止。
      const run = await this.ownedRun(transaction, actor, id);
      if (assistantActive.includes(run.status))
        await this.cancelTask(transaction, run.taskId);
      return this.runView(
        transaction,
        await transaction.assistantRun.findUniqueOrThrow({ where: { id } }),
        actor.sid,
      );
    });
  }

  /// 显式重试或接管只创建新运行，保持原业务任务及动作身份。
  async retry(actor: AuthUser, id: string, takeover = false): Promise<unknown> {
    return this.authorized(actor, async (transaction) => {
      // 旧运行不可被重复接管成多个新尝试。
      const previous = await this.ownedRun(transaction, actor, id);
      // 任务指向当前运行即为唯一执行权威。
      const task = await transaction.assistantTask.findUniqueOrThrow({
        where: { id: previous.taskId },
      });
      if (task.runId !== id)
        return this.runView(
          transaction,
          await transaction.assistantRun.findUniqueOrThrow({
            where: { id: task.runId },
          }),
          actor.sid,
        );
      if (
        task.status === 'cancelled' ||
        (previous.state as Record<string, unknown>).memoryInvalidated
      )
        throw new ConflictException('该任务上下文已失效，请发送新消息');
      if (
        !takeover &&
        !['failed', 'submissionUnknown'].includes(previous.status)
      )
        throw new ConflictException('当前运行不需要重试');
      if (takeover && !assistantActive.includes(previous.status))
        return this.runView(transaction, previous, actor.sid);
      // 同会话其他任务已开始时，旧失败任务不能再抢占执行资格。
      if (
        await transaction.assistantTask.count({
          where: {
            userId: actor.sub,
            conversationId: previous.conversationId,
            id: { not: task.id },
            status: { in: assistantActive },
          },
        })
      )
        throw new ConflictException('同一会话已有其他活动任务，请先完成或取消');
      // 付费配置在重试时重新获得明确当前授权。
      const settings = await transaction.assistantSettings.findUnique({
        where: { userId: actor.sub },
      });
      if (!settings?.enabled || !settings.profileId)
        throw new BadRequestException('助手未开启');
      // 保留已观察工具结果及稳定写计划，未知模型响应由显式重试重新调用。
      const state = previous.state as unknown as AssistantState;
      if (state.memoryVersion !== settings.memoryVersion)
        throw new ConflictException('记忆上下文已改变，请发送新消息');
      // 未形成固定动作时从聊天重载，避免失败留下未配对函数调用。
      const resumed =
        task.actionId || task.planRequestId || state.undoOf
          ? { ...state, modelCount: 0 }
          : {
              ...state,
              input: [],
              calls: [],
              intents: [],
              toolCount: 0,
              modelCount: 0,
              messageId: randomUUID(),
              text: '',
            };
      // 等待用户状态接管后仍等待，不能隐式启动模型。
      const status = ['waitingInput', 'waitingConfirmation'].includes(
        previous.status,
      )
        ? previous.status
        : 'queued';
      const newId = randomUUID();
      const cancelled = await transaction.assistantRun.update({
        where: { id },
        data: { status: 'cancelled', leaseOwner: null, leaseUntil: null },
      });
      await this.appendRunEvent(transaction, cancelled);
      await transaction.assistantTask.update({
        where: { id: task.id },
        data: { runId: newId, sessionId: actor.sid, status },
      });
      // 私有密文重新捕获，旧JWT不会被存储。
      const profile = await this.ai.captureAssistantProfile(
        actor.sub,
        settings.profileId,
      );
      const run = await transaction.assistantRun.create({
        data: {
          id: newId,
          userId: actor.sub,
          conversationId: previous.conversationId,
          taskId: task.id,
          sessionId: actor.sid,
          answerMessageId: resumed.messageId,
          status,
          state: assistantJson(resumed),
          profileSnapshot: assistantJson(profile),
        },
      });
      await this.appendRunEvent(transaction, run);
      return this.runView(transaction, run, actor.sid);
    });
  }

  /// 事件只对本归属返回，游标上限防止无界恢复请求。
  async events(actor: AuthUser, id: string, after: number): Promise<unknown[]> {
    return this.authorized(actor, async (transaction) => {
      await this.ownedRun(transaction, actor, id);
      return transaction.assistantEvent.findMany({
        where: { userId: actor.sub, runId: id, seq: { gt: after } },
        orderBy: { seq: 'asc' },
        take: 200,
      });
    });
  }

  /// 事件与序号在一个事务落地，断线可安全去重。
  async emit(runId: string, type: string, data: unknown): Promise<void> {
    await this.prisma.$transaction(async (transaction) => {
      // 删除聊天后不允许迟到事件重新建记录。
      const current = await transaction.assistantRun.findUnique({
        where: { id: runId },
      });
      if (
        !current ||
        (current.state as Record<string, unknown>).memoryInvalidated
      )
        return;
      // 同 owner 锁与记忆失效及会话删除竞争，迟到事件不能带回旧上下文。
      await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id=${current.userId}::uuid FOR UPDATE`;
      // 获取锁后重新读取，之前的存在性不能作为写入授权。
      const fresh = await transaction.assistantRun.findUnique({
        where: { id: runId },
      });
      if (
        !fresh ||
        (fresh.state as Record<string, unknown>).memoryInvalidated ||
        (fresh.status === 'cancelled' && type !== 'run.updated')
      )
        return;
      const run = await transaction.assistantRun.update({
        where: { id: runId },
        data: { eventSequence: { increment: 1 } },
      });
      await transaction.assistantEvent.create({
        data: {
          id: randomUUID(),
          userId: run.userId,
          runId,
          seq: run.eventSequence,
          type,
          data: assistantJson(data),
        },
      });
    });
  }

  /// 记忆列表包括停用项，使用稳定游标访问完整集合。
  async memories(actor: AuthUser, cursorId?: string): Promise<unknown> {
    if (cursorId) z.uuid().parse(cursorId);
    return this.authorized(actor, async (transaction) => {
      // 失效或其他归属游标不泄露其存在性。
      const cursor = cursorId
        ? await transaction.assistantMemory.findFirst({
            where: { id: cursorId, userId: actor.sub },
          })
        : null;
      if (cursorId && !cursor) throw new NotFoundException('记忆游标不存在');
      // 保留同毫秒更新记录的确定性身份排序。
      const rows = await transaction.assistantMemory.findMany({
        where: {
          userId: actor.sub,
          ...(cursor
            ? {
                OR: [
                  { updatedAt: { lt: cursor.updatedAt } },
                  { updatedAt: cursor.updatedAt, id: { lt: cursor.id } },
                ],
              }
            : {}),
        },
        orderBy: [{ updatedAt: 'desc' }, { id: 'desc' }],
        take: 201,
      });
      // 无更多数据时显式返回空游标。
      const items = rows.slice(0, 200);
      return { items, nextCursor: rows.length > 200 ? items.at(-1)!.id : null };
    });
  }

  /// 管理页和用户明确授权工具共用记忆更新路径。
  async saveMemory(
    actor: AuthUser,
    raw: unknown,
    id?: string,
    sourceMessageId?: string,
    preserveRunId?: string,
  ): Promise<unknown> {
    // 显式过期时间不能被默认解释为永久删除。
    const input = assistantMemoryInput.parse(raw);
    assertAssistantMemoryContent(input.content);
    return this.authorized(actor, async (transaction) => {
      // 开关控制工具写入，管理页仍可人工编辑。
      const settings = await transaction.assistantSettings.findUnique({
        where: { userId: actor.sub },
      });
      if (
        sourceMessageId &&
        (!settings?.enabled || !settings.memoryWriteEnabled)
      )
        throw new BadRequestException('长期记忆写入已暂停');
      if (sourceMessageId) {
        // 保存来源必须为本归属真实用户消息，不能挪用助手回答。
        const source = await transaction.assistantMessage.findFirst({
          where: {
            id: sourceMessageId,
            userId: actor.sub,
            role: 'user',
            excluded: false,
          },
        });
        if (!source) throw new NotFoundException('记忆来源消息不存在');
        if (preserveRunId) {
          // 停止或接管后，原在途工具不能再写长期记忆。
          const run = await transaction.assistantRun.findFirst({
            where: {
              id: preserveRunId,
              userId: actor.sub,
              taskId: source.taskId,
              sessionId: actor.sid,
              status: 'running',
            },
          });
          const task = run
            ? await transaction.assistantTask.findFirst({
                where: {
                  id: source.taskId,
                  userId: actor.sub,
                  runId: run.id,
                  sessionId: actor.sid,
                  status: 'running',
                },
              })
            : null;
          if (!run || !task)
            throw new ConflictException('助手运行已停止或被接管');
        }
      } else if (preserveRunId)
        throw new BadRequestException('保留运行必须绑定真实用户消息');
      // 更新身份必须属于当前用户。
      const old = id
        ? await transaction.assistantMemory.findFirst({
            where: { id, userId: actor.sub },
          })
        : null;
      if (id && !old) throw new NotFoundException('记忆不存在');
      if (old && input.revision !== old.revision)
        throw new ConflictException('记忆已改变，请刷新');
      // 相同内容重放不产生重复记忆。
      const duplicate = !id
        ? await transaction.assistantMemory.findFirst({
            where: {
              userId: actor.sub,
              content: input.content,
              category: input.category,
            },
          })
        : null;
      if (duplicate) {
        if (!sourceMessageId || duplicate.sourceMessageId === sourceMessageId)
          return duplicate;
        // 再次明确记住同一内容也记录新来源，遗忘时不能留下最新复述重新注入。
        const previous = duplicate.sourceMessageId;
        // 保留原内容、启用状态和期限，只更新来源及修订。
        const remembered = await transaction.assistantMemory.update({
          where: { id: duplicate.id },
          data: { sourceMessageId, revision: { increment: 1 } },
        });
        await this.invalidateMemories(
          transaction,
          actor.sub,
          previous ? [previous] : [],
          preserveRunId,
        );
        return remembered;
      }
      // 更新来源前固定旧来源，未来删除也必须排除新的来源消息。
      const previousSourceId = old?.sourceMessageId ?? null;
      // 数据库只存需要的显式字段。
      const data = {
        content: input.content,
        category: input.category,
        enabled: input.enabled,
        expiresAt: input.expiresAt ? new Date(input.expiresAt) : null,
        ...(sourceMessageId ? { sourceMessageId } : {}),
      };
      const memory = old
        ? await transaction.assistantMemory.update({
            where: { id: old.id },
            data: { ...data, revision: { increment: 1 } },
          })
        : await transaction.assistantMemory.create({
            data: {
              ...data,
              id: randomUUID(),
              userId: actor.sub,
              sourceMessageId,
            },
          });
      await this.invalidateMemories(
        transaction,
        actor.sub,
        previousSourceId ? [previousSourceId] : [],
        preserveRunId,
      );
      return memory;
    });
  }

  /// 删除记忆同时废弃历史摘要和来源输入，防止自动重新注入。
  async deleteMemory(actor: AuthUser, id?: string): Promise<unknown> {
    return this.authorized(actor, async (transaction) => {
      // 清空与单删均由用户管理入口明确发起。
      const memories = await transaction.assistantMemory.findMany({
        where: { userId: actor.sub, ...(id ? { id } : {}) },
      });
      if (id && !memories.length) throw new NotFoundException('记忆不存在');
      await transaction.assistantMemory.deleteMany({
        where: { userId: actor.sub, ...(id ? { id } : {}) },
      });
      if (memories.length)
        await this.invalidateMemories(
          transaction,
          actor.sub,
          memories.flatMap((memory) =>
            memory.sourceMessageId ? [memory.sourceMessageId] : [],
          ),
        );
      return { ok: true };
    });
  }

  /// 返回同归属run，否则保持不可枚举的不存在语义。
  async ownedRun(
    transaction: Prisma.TransactionClient,
    actor: AuthUser,
    id: string,
  ): Promise<AssistantRun> {
    const run = await transaction.assistantRun.findFirst({
      where: { id, userId: actor.sub },
    });
    if (!run) throw new NotFoundException('助手任务不存在');
    return run;
  }

  /// 有效 worker 租约代表当前段尚未结算，过期租约不使界面永久等待。
  private timingPending(
    run: Pick<AssistantRun, 'leaseOwner' | 'leaseUntil'>,
  ): boolean {
    return !!run.leaseOwner && !!run.leaseUntil && run.leaseUntil > new Date();
  }

  /// 公开运行视图只包含展示事实，不暴露模型快照和内部状态。
  async runView(
    transaction: Prisma.TransactionClient,
    run: AssistantRun,
    viewerSessionId?: string,
  ): Promise<unknown> {
    // 任务后来可能被接管或生成补偿，原运行不能借用新的动作身份。
    const task = await transaction.assistantTask.findUnique({
      where: { id: run.taskId },
    });
    return {
      id: run.id,
      taskId: run.taskId,
      conversationId: run.conversationId,
      status: run.status,
      answerMessageId: run.answerMessageId ?? null,
      elapsedMs: run.elapsedMs,
      // 回答可能先于 finally 保存；租约释放前客户端仍应等待计时结算。
      timingPending: this.timingPending(run),
      errorCode: run.errorCode,
      errorMessage: run.errorMessage,
      plan:
        task?.runId === run.id &&
        run.status !== 'cancelled' &&
        !(run.state as Record<string, unknown>).memoryInvalidated
          ? (task.plan ?? null)
          : null,
      canUndo: await this.canUndo(transaction, run, task),
      requiresTakeover: viewerSessionId
        ? run.sessionId !== viewerSessionId
        : false,
      createdAt: run.createdAt,
      updatedAt: run.updatedAt,
    };
  }

  /// 新增补偿明确建立新运行，同一原运行重复请求返回同一补偿。
  async undo(actor: AuthUser, id: string): Promise<unknown> {
    return this.authorized(actor, async (transaction) => {
      // 原运行存在且属于同一 owner。
      const original = await this.ownedRun(transaction, actor, id);
      // 仅保存实际结果的原运行可以提供补偿身份。
      const state = original.state as unknown as Partial<AssistantState>;
      if (state.undoRunId) {
        // 重复点击只重放已建立的补偿运行，不重新准备软删除。
        const repeated = await this.ownedRun(
          transaction,
          actor,
          state.undoRunId,
        );
        return this.runView(transaction, repeated, actor.sid);
      }
      // 同任务原动作及窗口由服务器核实，正式提交还会检查后置基线。
      const task = await transaction.assistantTask.findUniqueOrThrow({
        where: { id: original.taskId },
      });
      if (!(await this.canUndo(transaction, original, task)))
        throw new ConflictException('此操作不可撤销或已超过十分钟窗口');
      if (
        await transaction.assistantTask.count({
          where: {
            userId: actor.sub,
            conversationId: original.conversationId,
            status: { in: assistantActive },
          },
        })
      )
        throw new ConflictException('请先处理当前活动任务');
      // 新增补偿仍须获得当前设备和助手设置授权。
      const settings = await transaction.assistantSettings.findUnique({
        where: { userId: actor.sub },
      });
      if (!settings?.enabled || !settings.profileId)
        throw new BadRequestException('助手未开启');
      // 原运行的真实动作身份在任务变化后仍可追溯。
      const actionId = state.actionId ?? task.actionId!;
      // 独立运行身份在任何业务补偿前持久保存。
      const runId = randomUUID();
      // 新运行不带旧供应商调用或批准事实。
      const next: AssistantState = {
        input: [],
        intents: [],
        calls: [],
        toolCount: 0,
        modelCount: 0,
        messageId: randomUUID(),
        request: '撤销这次新增',
        text: '',
        memoryVersion: settings.memoryVersion,
        undoOf: actionId,
        timeZone: state.timeZone ?? settings.timeZone,
      };
      // 密文配置与原运行隔离，关闭或删除供应商配置会被当前校验拒绝。
      const profile = await this.ai.captureAssistantProfile(
        actor.sub,
        settings.profileId,
      );
      await transaction.assistantRun.update({
        where: { id },
        data: { state: assistantJson({ ...state, undoRunId: runId }) },
      });
      await transaction.assistantTask.update({
        where: { id: task.id },
        data: {
          runId,
          sessionId: actor.sid,
          status: 'queued',
          plan: Prisma.DbNull,
          approvedHash: null,
          actionId: null,
          planRequestId: null,
          committed: false,
        },
      });
      // planVersion保持原数值，补偿准备时继续递增。
      const run = await transaction.assistantRun.create({
        data: {
          id: runId,
          userId: actor.sub,
          conversationId: original.conversationId,
          taskId: task.id,
          sessionId: actor.sid,
          answerMessageId: next.messageId,
          profileSnapshot: assistantJson(profile),
          state: assistantJson(next),
        },
      });
      await this.appendRunEvent(transaction, run);
      return this.runView(transaction, run, actor.sid);
    });
  }

  /// 卡片能力由实际成功动作和目录元数据确定，不能由模型声明。
  private async canUndo(
    transaction: Prisma.TransactionClient,
    run: AssistantRun,
    task: AssistantTask | null,
  ): Promise<boolean> {
    // 已创建补偿、已遗忘或没有实际回执的运行均不再提供按钮。
    const state = run.state as unknown as Partial<AssistantState>;
    if (!state.result || state.undoRunId || state.memoryInvalidated || !task)
      return false;
    // 多批任务的最后一批即使只有单条，也不能伪装成整个任务可撤销。
    const result = state.result as Record<string, unknown>;
    if (
      (task.plan as Record<string, unknown> | null)?.kind === 'batch' ||
      Number(result.totalBatches ?? 0) > 1
    )
      return false;
    // task当前动作只能在run仍是当前运行时作为兼容回退。
    const actionId =
      state.actionId ?? (task.runId === run.id ? task.actionId : null);
    if (!actionId) return false;
    // 查询始终限定来源、归属和稳定任务身份。
    const action = await transaction.mcpAction.findFirst({
      where: {
        id: actionId,
        userId: run.userId,
        source: 'assistant',
        sourceId: run.taskId,
        status: 'succeeded',
      },
    });
    if (!action?.result || Date.now() >= action.updatedAt.getTime() + 600000)
      return false;
    // 真实步骤不能从公开卡片反向信任。
    const steps = action.steps as Array<{ name: string }>;
    return (
      steps.length === 1 &&
      this.actions.catalog.tools.some(
        (tool) => tool.name === steps[0]!.name && tool.undoCreate,
      )
    );
  }

  /// 开关关闭与删除会话共用持久取消，不依赖进程内Abort。
  async cancelAll(
    transaction: Prisma.TransactionClient,
    userId: string,
    conversationId?: string,
  ): Promise<void> {
    const tasks = await transaction.assistantTask.findMany({
      where: {
        userId,
        ...(conversationId ? { conversationId } : {}),
        status: { in: assistantActive },
      },
    });
    for (const task of tasks) await this.cancelTask(transaction, task.id);
  }

  /// 动作取消与提交共用owner事务，成功动作保持真实状态。
  async cancelTask(
    transaction: Prisma.TransactionClient,
    taskId: string,
  ): Promise<void> {
    // 取消和事件使用同一 owner 事务，其他设备无须等订阅超时。
    const activeRuns = await transaction.assistantRun.findMany({
      where: { taskId, status: { in: assistantActive } },
    });
    await transaction.mcpAction.updateMany({
      where: { source: 'assistant', sourceId: taskId, status: 'pending' },
      data: { status: 'cancelled' },
    });
    await transaction.assistantTask.update({
      where: { id: taskId },
      data: { status: 'cancelled', approvedHash: null },
    });
    await transaction.assistantRun.updateMany({
      where: { taskId, status: { in: assistantActive } },
      data: { status: 'cancelled', leaseOwner: null, leaseUntil: null },
    });
    for (const active of activeRuns)
      await this.appendRunEvent(
        transaction,
        await transaction.assistantRun.findUniqueOrThrow({
          where: { id: active.id },
        }),
      );
  }

  /// 控制过渡事件复用当前事务，不调用会另开 owner 锁的 emit。
  private async appendRunEvent(
    transaction: Prisma.TransactionClient,
    run: AssistantRun,
  ): Promise<void> {
    // 更新序号及事件记录原子保存，重复控制请求由各自幂等分支先返回。
    const updated = await transaction.assistantRun.update({
      where: { id: run.id },
      data: { eventSequence: { increment: 1 } },
    });
    // 公开视图不含原始state、模型快照、设备身份或已取消的旧计划。
    const view = await this.runView(transaction, updated);
    await transaction.assistantEvent.create({
      data: {
        id: randomUUID(),
        userId: updated.userId,
        runId: updated.id,
        seq: updated.eventSequence,
        type: 'run.updated',
        data: assistantJson({ run: view }),
      },
    });
  }

  /// 删除图检查点只按服务器产生的运行身份，不接受自由thread_id。
  async deleteCheckpoints(
    transaction: Prisma.TransactionClient,
    runIds: string[],
  ): Promise<void> {
    for (const id of runIds) {
      await transaction.$executeRaw`DELETE FROM assistant_graph.checkpoint_writes WHERE thread_id=${id}`;
      await transaction.$executeRaw`DELETE FROM assistant_graph.checkpoint_blobs WHERE thread_id=${id}`;
      await transaction.$executeRaw`DELETE FROM assistant_graph.checkpoints WHERE thread_id=${id}`;
    }
  }

  /// 遗忘需要废弃所有可能携带旧记忆的派生上下文。
  private async invalidateMemories(
    transaction: Prisma.TransactionClient,
    userId: string,
    sourceIds: string[],
    preserveRunId?: string,
  ): Promise<void> {
    await transaction.assistantSettings.updateMany({
      where: { userId },
      data: { memoryVersion: { increment: 1 } },
    });
    // 先前助手回答也可能复述偏好，全部旧派生回答不再进入模型上下文。
    await transaction.assistantMessage.updateMany({
      where: { userId, OR: [{ id: { in: sourceIds } }, { role: 'assistant' }] },
      data: { excluded: true },
    });
    await transaction.assistantConversation.updateMany({
      where: { userId },
      data: {
        summary: '',
        summaryThrough: null,
        memoryVersion: { increment: 1 },
      },
    });
    // 持久取消先阻断迟到副作用，再删除任何派生状态。
    const tasks = await transaction.assistantTask.findMany({
      where: {
        userId,
        OR: [{ status: { in: assistantActive } }, { committed: false }],
        ...(preserveRunId ? { runId: { not: preserveRunId } } : {}),
      },
    });
    for (const task of tasks) await this.cancelTask(transaction, task.id);
    // 历史失败任务同样不能通过显式重试恢复旧批准或旧记忆。
    const runs = await transaction.assistantRun.findMany({
      where: {
        userId,
        ...(preserveRunId ? { id: { not: preserveRunId } } : {}),
      },
      select: { id: true },
    });
    // checkpoint清理与记忆版本同事务；runner还需清理取消后迟到的图写入。
    await this.deleteCheckpoints(
      transaction,
      runs.map((run) => run.id),
    );
    await transaction.assistantRun.updateMany({
      where: { id: { in: runs.map((run) => run.id) } },
      data: { state: { memoryInvalidated: true } },
    });
    // 已提交业务回执及保护身份保留，未提交计划的批准和引用全部失效。
    await transaction.assistantTask.updateMany({
      where: {
        userId,
        committed: false,
        ...(preserveRunId ? { runId: { not: preserveRunId } } : {}),
      },
      data: {
        status: 'cancelled',
        plan: Prisma.DbNull,
        approvedHash: null,
        actionId: null,
        planRequestId: null,
      },
    });
    await transaction.assistantAttempt.updateMany({
      where: {
        userId,
        ...(preserveRunId ? { runId: { not: preserveRunId } } : {}),
      },
      data: { response: Prisma.DbNull },
    });
  }

  /// 每个会话访问都包含owner过滤。
  private async conversation(
    transaction: Prisma.TransactionClient,
    userId: string,
    id: string,
  ): Promise<void> {
    if (
      !(await transaction.assistantConversation.findFirst({
        where: { id, userId },
      }))
    )
      throw new NotFoundException('会话不存在');
  }
}
