import { ConflictException, Injectable } from '@nestjs/common';
import type { Prisma } from '../generated/prisma/client';
import { ActionExecutor, mcpHash, type McpStep } from '../mcp/action-executor';
import type { AssistantActionContext } from '../mcp/action-context';
import { localParts } from '../business/business-input';
import { stableBusinessId } from '../sync/sync-consistency';
import { AssistantStore } from './assistant-store.service';
import { assistantJson } from './assistant.types';

/// 多批计划固定全部步骤与预览；实际批次不承诺跨批原子性。
export interface AssistantBatchPlan {
  /// 模型无法填写此种类或自行放行。
  kind: 'batch';
  /// 完整且固定绝对日期的业务步骤。
  steps: McpStep[];
  /// 完整预演包含每批关联影响。
  preview: Record<string, unknown>;
  /// 幂等请求身份先于实际准备持久保存。
  requestIds: string[];
  /// 仅允许自身已提交批次推进基线。
  executionBaseline: string;
  /// 实际完成范围，失败后不能伪装整项成功。
  completedBatches: number;
  /// 每批完整实际回执。
  results: Record<string, unknown>[];
  /// 原生确认卡绑定的预览摘要。
  previewHash: string;
}

/// 整项任务预演后分批提交，批间外部修改会停止而非刷新基线覆盖。
@Injectable()
export class AssistantBatchService {
  /// 共享执行器保持业务规则及持续同步保护单一来源。
  constructor(
    private readonly store: AssistantStore,
    private readonly actions: ActionExecutor,
  ) {}

  /// 全部批次在一个回滚事务中预演，未确认前业务数据不变。
  async prepare(
    context: AssistantActionContext,
    requestId: string,
    steps: McpStep[],
    guard: (transaction: Prisma.TransactionClient) => Promise<void>,
  ): Promise<AssistantBatchPlan> {
    if (steps.length < 9 || steps.length > 64)
      throw new ConflictException('一次分批任务支持9至64步，请缩小范围');
    return this.store.authorized(context.actor, async (transaction) => {
      await guard(transaction);
      // 公共时间参数一次固定，跨午夜提交仍保持已展示日期。
      const fixed = this.freezeTimes(context, steps);
      const baseline = await this.actions.snapshotBaseline(context);
      // 预演回执与业务副作用都在此保存点内，最终全部回滚。
      await transaction.$executeRawUnsafe('SAVEPOINT assistant_full_preview');
      const batches: Record<string, unknown>[] = [];
      const changes: Record<string, unknown>[] = [];
      const requestIds: string[] = [];
      try {
        for (let index = 0; index < fixed.length; index += 8) {
          // 每批稳定身份同时用于正式执行，模拟回执不会持久存在。
          const identity = stableBusinessId('assistant-batch', [
            requestId,
            String(index / 8),
          ]);
          requestIds.push(identity);
          const prepared = await this.actions.prepare(
            context,
            identity,
            fixed.slice(index, index + 8),
          );
          const preview = prepared.preview as Record<string, unknown>;
          batches.push({ index: index / 8 + 1, ...preview });
          changes.push(...(preview.changes as Record<string, unknown>[]));
          // 此内部模拟不写任务放行状态；整个保存点最终必然回滚。
          const simulated = await this.actions.commit(
            context,
            String(prepared.id),
            () => Promise.resolve(),
          );
          if (simulated.status !== 'succeeded')
            throw new ConflictException('分批预演出现冲突，请先处理后续依赖');
        }
      } finally {
        await transaction.$executeRawUnsafe(
          'ROLLBACK TO SAVEPOINT assistant_full_preview',
        );
        await transaction.$executeRawUnsafe(
          'RELEASE SAVEPOINT assistant_full_preview',
        );
      }
      const targetCount = await this.actions.countPlanTargets(
        context,
        fixed,
        changes,
      );
      // 完整清单与关联影响先确认，后续不能临时加步骤。
      const preview = {
        steps: fixed.map((step) => ({ tool: step.name, input: step.input })),
        changes,
        batches,
        targetCount,
        atomic: false,
        batchCount: batches.length,
        warnings: [
          '按展示顺序逐批执行，每批最多8步及200条变化；失败后停止，已完成批次不会自动回滚。',
        ],
      };
      return {
        kind: 'batch',
        steps: fixed,
        preview,
        requestIds,
        executionBaseline: baseline,
        completedBatches: 0,
        results: [],
        previewHash: mcpHash(preview),
      };
    });
  }

  /// 一批的业务副作用、回执、完成范围和新基线必须在同一事务保存。
  async commitNext(
    context: AssistantActionContext,
    guard: (transaction: Prisma.TransactionClient) => Promise<void>,
  ): Promise<{
    done: boolean;
    result: Record<string, unknown>;
    actionId: string;
    conflict?: boolean;
  }> {
    return this.store.authorized(context.actor, async (transaction) => {
      await guard(transaction);
      // 只读数据库里的固定计划，不接收模型重新提供参数。
      const task = await transaction.assistantTask.findUniqueOrThrow({
        where: { id: context.taskId },
      });
      const publicPlan = task.plan as Record<string, unknown>;
      const plan = publicPlan.batchPlan as AssistantBatchPlan;
      if (
        !plan ||
        (Number(publicPlan.targetCount) >= 2 &&
          publicPlan.previewHash !== task.approvedHash)
      )
        throw new ConflictException('完整分批方案尚未确认');
      if (
        typeof publicPlan.expiresAt !== 'string' ||
        new Date(publicPlan.expiresAt) <= new Date()
      )
        throw new ConflictException('分批方案已过期，请重新确认');
      const index = plan.completedBatches;
      if (index >= plan.requestIds.length)
        return {
          done: true,
          result: this.result(plan),
          actionId: task.actionId!,
        };
      // 外部变化不能被下一批准备时读取的最新基线静默接受。
      if (
        (await this.actions.snapshotBaseline(context)) !==
        plan.executionBaseline
      )
        throw new ConflictException(
          '分批期间数据已变化，请核对已完成范围后重新确认',
        );
      const prepared = await this.actions.prepare(
        context,
        plan.requestIds[index]!,
        plan.steps.slice(index * 8, index * 8 + 8),
      );
      const actionId = String(prepared.id);
      const actual = await this.actions.commit(
        context,
        actionId,
        async (inner) => {
          await guard(inner);
          // 再次确认当前批数与固定摘要，不能靠checkpoint声称完成。
          const fresh = await inner.assistantTask.findUniqueOrThrow({
            where: { id: task.id },
          });
          if (
            Number(publicPlan.targetCount) >= 2 &&
            fresh.approvedHash !== publicPlan.previewHash
          )
            throw new ConflictException('分批确认已失效');
        },
      );
      if (!actual.result)
        throw new ConflictException('当前批次未执行，已完成范围保持不变');
      plan.completedBatches++;
      plan.results.push({
        actionId,
        status: actual.status,
        result: actual.result,
      });
      plan.executionBaseline = await this.actions.snapshotBaseline(context);
      const done =
        plan.completedBatches === plan.requestIds.length &&
        actual.status === 'succeeded';
      const combined = this.result(plan);
      await transaction.assistantTask.update({
        where: { id: task.id },
        data: {
          actionId,
          plan: assistantJson({
            ...publicPlan,
            batchPlan: plan,
            completedBatches: plan.completedBatches,
          }),
          committed: done,
        },
      });
      // 业务提交成功但图checkpoint失败仍有整项已完成范围可恢复。
      const run = await transaction.assistantRun.findUniqueOrThrow({
        where: { id: context.runId },
      });
      await transaction.assistantRun.update({
        where: { id: run.id },
        data: {
          state: assistantJson({
            ...(run.state as Record<string, unknown>),
            result: combined,
            actionId,
            ...(actual.status !== 'succeeded' ? { conflict: true } : {}),
          }),
        },
      });
      return {
        done,
        result: combined,
        actionId,
        conflict: actual.status !== 'succeeded',
      };
    });
  }

  /// 汇总仅展示真实回执与明确完成比例。
  private result(plan: AssistantBatchPlan): Record<string, unknown> {
    return {
      values: plan.results.flatMap(
        (batch) =>
          ((batch.result as Record<string, unknown>).values as unknown[]) ?? [],
      ),
      completedBatches: plan.completedBatches,
      totalBatches: plan.requestIds.length,
      atomic: false,
      partial: plan.completedBatches < plan.requestIds.length,
      batchResults: plan.results,
    };
  }

  /// 转为公开参数可再次校验的绝对日期，不把内部临时ID传给下一批。
  private freezeTimes(
    context: AssistantActionContext,
    steps: McpStep[],
  ): McpStep[] {
    const now = new Date();
    return steps.map((step) => {
      const input = { ...step.input };
      const field =
        step.name === 'start_time_entry'
          ? 'startedAt'
          : step.name === 'finish_time_entry'
            ? 'endedAt'
            : step.name === 'complete_event'
              ? 'completedAt'
              : step.name === 'record_membership_payment'
                ? 'paidAt'
                : null;
      if (field && input[field] === undefined) input[field] = now.toISOString();
      if (step.name === 'create_note' && input.recordedAt === undefined) {
        const local = localParts(
          now,
          typeof input.timeZone === 'string'
            ? input.timeZone
            : context.timeZone,
        );
        const hours = String(Math.floor(local.seconds / 3600)).padStart(2, '0');
        const minutes = String(Math.floor(local.seconds / 60) % 60).padStart(
          2,
          '0',
        );
        const seconds = String(local.seconds % 60).padStart(2, '0');
        const offset = `${local.offsetMinutes < 0 ? '-' : '+'}${String(Math.floor(Math.abs(local.offsetMinutes) / 60)).padStart(2, '0')}:${String(Math.abs(local.offsetMinutes) % 60).padStart(2, '0')}`;
        input.recordedAt = `${local.day}T${hours}:${minutes}:${seconds}${offset}`;
      }
      return { name: step.name, input };
    });
  }
}
