import { ConflictException, Injectable } from '@nestjs/common';
import { z } from 'zod';
import { randomUUID } from 'node:crypto';
import { setTimeout as wait } from 'node:timers/promises';
import { AiProviderError } from '../ai/ai-provider';
import { AssistantModelProvider } from '../ai/assistant-model.provider';
import type {
  AssistantModelRequest,
  AssistantModelResult,
  AssistantProfileSnapshot,
} from '../ai/assistant-model.types';
import {
  AssistantModelFailure,
  assistantRetryDecision,
  normalizeAssistantFailure,
} from '../ai/assistant-model-policy';
import type { AssistantRun } from '../generated/prisma/client';
import { mcpHash } from '../mcp/action-executor';
import { AssistantStore } from './assistant-store.service';
import { assistantJson } from './assistant.types';

/// 持久请求中只保留模型输入引用，不保留取消信号或运行时回调。
type SavedRequest = Pick<
  AssistantModelRequest,
  'instructions' | 'input' | 'tools' | 'toolChoice' | 'maxOutputTokens'
>;
/// 持久请求属于外部数据边界，恢复前重新校验而非强制类型断言。
const savedRequestSchema = z.strictObject({
  instructions: z.string(),
  input: z.array(z.record(z.string(), z.unknown())),
  tools: z.array(
    z.object({
      type: z.literal('function'),
      name: z.string(),
      description: z.string(),
      parameters: z.record(z.string(), z.unknown()),
      strict: z.literal(false).optional(),
    }),
  ),
  toolChoice: z
    .union([
      z.literal('auto'),
      z.literal('none'),
      z.object({ type: z.literal('function'), name: z.string() }),
    ])
    .optional(),
  maxOutputTokens: z.number().int().min(1).max(32768).optional(),
});
/// 恢复动作由运行器提供，保持业务授权和上下文策略在原归属中。
export interface AssistantRequestHooks {
  /// 纯查询阶段保留最后一次出站资格供不带工具的最终回答使用。
  reserveFinalAnswer?: boolean;
  /// 旧等待计划也受当前工具阶段门禁约束，不能重放冻结的auto查询。
  queryLimitReached?: boolean;
  /// 图像仅在出站前装载，不写进付费回执或请求记录。
  prepare?: (request: SavedRequest) => Promise<SavedRequest>;
  /// 明确超限时只允许一次有实质缩减的确定性压缩。
  compact?: (request: SavedRequest) => Promise<SavedRequest>;
  /// 等待前发布已持久化的恢复计划。
  onRetry?: (retryAt: Date, index: number) => Promise<void>;
}

/// 兼容旧attempt与新子请求账本，不把刚创建但未出站的当前attempt重复计费。
export function assistantModelCallsUsed(attempts: Array<{ id: string; requests: Array<{ id: string }> }>, currentAttemptId?: string): number {
  return attempts.reduce((sum, entry) => sum + Math.max(entry.id === currentAttemptId ? 0 : 1, entry.requests.length), 0);
}

/// 付费请求的有限恢复账本；任何未知出站都禁止后台重发。
@Injectable()
export class AssistantModelExecutor {
  /// 复用owner事务、真实供应商和既有逻辑attempt。
  constructor(
    private readonly store: AssistantStore,
    private readonly provider: AssistantModelProvider,
  ) {}

  /// 同一逻辑请求的重试共享截止时间，重启不重新获得预算。
  async execute(
    run: AssistantRun,
    attemptId: string,
    input: AssistantModelRequest,
    hooks: AssistantRequestHooks = {},
  ): Promise<
    AssistantModelResult & { requestInput: Record<string, unknown>[] }
  > {
    // 每次调度前重新验证活动租约及遗忘状态，图片加载不能消耗完预算后再出站。
    const assertCurrent = async (): Promise<void> => {
      await this.store.authorized(
        { sub: run.userId, sid: run.sessionId, typ: 'access' },
        async (transaction) => {
          const current = await transaction.assistantRun.findFirst({
            where: {
              id: run.id,
              status: 'running',
              leaseOwner: run.leaseOwner,
              leaseUntil: { gt: new Date() },
            },
          });
          if (
            !current ||
            (current.state as { memoryInvalidated?: boolean } | null)
              ?.memoryInvalidated
          )
            throw new AssistantModelFailure('AI_CANCELLED', {
              submission: 'notSubmitted',
              retryable: false,
            });
        },
      );
    };
    // 历史记录顺序也是恢复顺序，未完成processing只能显式继续。
    const records = await this.store.prisma.assistantAttemptRequest.findMany({
      where: { attemptId },
      orderBy: { index: 'asc' },
    });
    // 完整冻结的初次请求不会因系统时间变化而改变重试内容。
    let request: SavedRequest = records.length
      ? savedRequestSchema.parse(
          records[records.length - 1]!.nextRequest ??
            records[records.length - 1]!.request,
        )
      : {
          instructions: input.instructions,
          input: input.input,
          tools: input.tools,
          toolChoice: input.toolChoice,
          maxOutputTokens: input.maxOutputTokens,
        };
    // 供应商总时限包含退避及DNS，不在每次尝试重置。
    const deadline = records[0]?.deadlineAt ?? new Date(Date.now() + 60000);
    // 崩溃后只允许重放已落库的等待计划。
    let index = records.length;
    // 网络重试和上下文恢复各自最多一次，总请求仍受任务硬上限。
    let transientRetries = records.filter(
      (entry) => entry.status === 'retryScheduled',
    ).length;
    let compacted = records.some((entry) => entry.status === 'contextReduced');
    // 最新记录决定可恢复性，而非靠内存中是否收到响应判断。
    const last = records.at(-1);
    if (last?.status === 'processing' || last?.status === 'unknown')
      throw new AiProviderError('AI_SUBMISSION_UNKNOWN', true);
    if (last && !['retryScheduled', 'contextReduced'].includes(last.status))
      throw new ConflictException('模型请求已经结束，请显式重试');
    if (last?.retryAt)
      await wait(Math.max(0, last.retryAt.getTime() - Date.now()), undefined, {
        signal: input.signal,
      });
    for (;;) {
      if (input.signal?.aborted) throw new AiProviderError('AI_CANCELLED');
      if (Date.now() >= deadline.getTime())
        throw new AiProviderError('AI_RETRY_BUDGET_EXHAUSTED');
      // 在同owner锁内检查租约、总次数并登记这次可能出站的请求。
      const record = await this.store.authorized(
        { sub: run.userId, sid: run.sessionId, typ: 'access' },
        async (transaction) => {
          // 取消、接管和过期租约均不能创建新的出站资格。
          const current = await transaction.assistantRun.findFirst({
            where: {
              id: run.id,
              status: 'running',
              leaseOwner: run.leaseOwner,
              leaseUntil: { gt: new Date() },
            },
          });
          if (!current) throw new ConflictException('助手运行已停止或租约失效');
          // 旧版本没有子请求记录的attempt也按一次实际调用计算。
          const attempts = await transaction.assistantAttempt.findMany({
            where: { runId: run.id },
            include: { requests: { select: { id: true } } },
          });
          const used = assistantModelCallsUsed(attempts, attemptId);
          // 每一次安全重试也复验预留名额，不能在executor内部吃掉最终回答预算。
          const limit = hooks.reserveFinalAnswer && request.toolChoice !== 'none' ? 11 : 12;
          if (used >= limit) {
            throw new AssistantModelFailure('ASSISTANT_MODEL_LIMIT', { submission: 'notSubmitted', retryable: false });
          }
          if (request.toolChoice !== 'none' && (hooks.queryLimitReached || input.toolChoice === 'none'))
            throw new AssistantModelFailure('ASSISTANT_TOOL_LIMIT', { submission: 'notSubmitted', retryable: false });
          await transaction.assistantAttempt.update({
            where: { id: attemptId },
            data: { status: 'processing' },
          });
          return transaction.assistantAttemptRequest.create({
            data: {
              id: randomUUID(),
              attemptId,
              index,
              requestHash: mcpHash(request),
              request: assistantJson(request),
              status: 'processing',
              deadlineAt: deadline,
            },
          });
        },
      );
      // 预处理未完成就失败可明确判定没有调用模型。
      let enteredProvider = false;
      try {
        // 临时图像部分仅存在内存；响应回执保留原始引用输入。
        const prepared = hooks.prepare ? await hooks.prepare(request) : request;
        await assertCurrent();
        if (input.signal?.aborted)
          throw new AssistantModelFailure('AI_CANCELLED', {
            submission: 'notSubmitted',
            retryable: false,
          });
        if (Date.now() >= deadline.getTime())
          throw new AssistantModelFailure('AI_RETRY_BUDGET_EXHAUSTED', {
            submission: 'notSubmitted',
            retryable: false,
          });
        enteredProvider = true;
        const result = await this.provider.complete(
          run.userId,
          run.profileSnapshot as unknown as AssistantProfileSnapshot,
          {
            ...prepared,
            signal: AbortSignal.any([
              ...(input.signal ? [input.signal] : []),
              AbortSignal.timeout(Math.max(1, deadline.getTime() - Date.now())),
            ]),
            timeoutMs: Math.max(1, deadline.getTime() - Date.now()),
            onDelta: input.onDelta,
            onReasoning: input.onReasoning,
          },
        );
        // 停止后的迟到响应不会获得新的业务执行权。
        await this.store.authorized(
          { sub: run.userId, sid: run.sessionId, typ: 'access' },
          async (transaction) => {
            const current = await transaction.assistantRun.findFirst({
              where: {
                id: run.id,
                status: 'running',
                leaseOwner: run.leaseOwner,
                leaseUntil: { gt: new Date() },
              },
            });
            if (!current)
              throw new AiProviderError('AI_SUBMISSION_UNKNOWN', true);
            await transaction.assistantAttemptRequest.update({
              where: { id: record.id },
              data: { status: 'succeeded' },
            });
            await transaction.assistantAttempt.update({
              where: { id: attemptId },
              data: {
                status: 'succeeded',
                response: assistantJson({
                  ...result,
                  requestInput: request.input,
                }),
                usage: result.usage ? assistantJson(result.usage) : undefined,
              },
            });
          },
        );
        return { ...result, requestInput: request.input };
      } catch (error: unknown) {
        // 统一提交事实同时驱动run、attempt和传输尝试状态。
        const failure =
          enteredProvider || error instanceof AssistantModelFailure
            ? normalizeAssistantFailure(error)
            : new AssistantModelFailure('ASSISTANT_ATTACHMENT_UNAVAILABLE', {
                submission: 'notSubmitted',
                retryable: false,
              });
        const facts = failure.facts;
        // 明确上下文拒绝且没有可见输出，才能使用新摘要发起一次请求。
        if (
          !compacted &&
          failure.code === 'AI_CONTEXT_TOO_LARGE' &&
          facts.submission === 'rejected' &&
          hooks.compact
        ) {
          // 无法进一步压缩时按原拒绝结束，不把本地压缩异常当作未知出站。
          const reduced = await hooks.compact(request).catch(() => request);
          if (
            Buffer.byteLength(JSON.stringify(reduced)) <
            Buffer.byteLength(JSON.stringify(request))
          ) {
            request = reduced;
            compacted = true;
            await this.store.authorized(
              { sub: run.userId, sid: run.sessionId, typ: 'access' },
              async (transaction) => {
                const current = await transaction.assistantRun.findFirst({
                  where: {
                    id: run.id,
                    status: 'running',
                    leaseOwner: run.leaseOwner,
                    leaseUntil: { gt: new Date() },
                  },
                });
                if (
                  !current ||
                  (current.state as { memoryInvalidated?: boolean } | null)
                    ?.memoryInvalidated
                )
                  throw new AiProviderError('AI_CANCELLED');
                await transaction.assistantAttemptRequest.update({
                  where: { id: record.id },
                  data: {
                    status: 'contextReduced',
                    nextRequest: assistantJson(request),
                    failure: assistantJson({ ...facts, code: failure.code }),
                  },
                });
                await transaction.assistantAttempt.update({
                  where: { id: attemptId },
                  data: { status: 'retryScheduled' },
                });
              },
            );
            index++;
            continue;
          }
        }
        // 策略拒绝未知计费、永久失败、过长Retry-After和耗尽预算。
        const decision = assistantRetryDecision({
          failure,
          retriesUsed: transientRetries,
          random: Math.random(),
          elapsedMs: 60000 - (deadline.getTime() - Date.now()),
        });
        if (decision.retry && !input.signal?.aborted) {
          const retryAt = new Date(Date.now() + decision.delayMs);
          await this.store.authorized(
            { sub: run.userId, sid: run.sessionId, typ: 'access' },
            async (transaction) => {
              const current = await transaction.assistantRun.findFirst({
                where: {
                  id: run.id,
                  status: 'running',
                  leaseOwner: run.leaseOwner,
                  leaseUntil: { gt: new Date() },
                },
              });
              if (
                !current ||
                (current.state as { memoryInvalidated?: boolean } | null)
                  ?.memoryInvalidated
              )
                throw new AiProviderError('AI_CANCELLED');
              await transaction.assistantAttemptRequest.update({
                where: { id: record.id },
                data: {
                  status: 'retryScheduled',
                  failure: assistantJson({ ...facts, code: failure.code }),
                  retryAt,
                },
              });
              await transaction.assistantAttempt.update({
                where: { id: attemptId },
                data: { status: 'retryScheduled' },
              });
            },
          );
          transientRetries++;
          await hooks.onRetry?.(retryAt, transientRetries);
          await wait(decision.delayMs, undefined, { signal: input.signal });
          index++;
          continue;
        }
        await this.store.prisma.$transaction(async (transaction) => {
          await transaction.assistantAttemptRequest.update({
            where: { id: record.id },
            data: {
              status: facts.submission,
              failure: assistantJson({ ...facts, code: failure.code }),
            },
          });
          await transaction.assistantAttempt.update({
            where: { id: attemptId },
            data: {
              status:
                facts.submission === 'unknown'
                  ? 'submissionUnknown'
                  : facts.submission,
              usage: facts.usage ? assistantJson(facts.usage) : undefined,
            },
          });
        });
        throw failure;
      }
    }
  }
}
