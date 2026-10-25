import type {
  AssistantModelRequest,
  AssistantModelResult,
  AssistantProfileSnapshot,
} from '../src/ai/assistant-model.types';
import { AssistantModelExecutor, assistantModelCallsUsed } from '../src/assistant/assistant-model-executor';
import { AssistantModelFailure } from '../src/ai/assistant-model-failure';
import type { AssistantStore } from '../src/assistant/assistant-store.service';
import type { AssistantModelProvider } from '../src/ai/assistant-model.provider';
import type { AssistantRun } from '../src/generated/prisma/client';

/// 内存账本只模拟存储，恢复策略和供应商调度使用真实实现。
function fixture(): {
  executor: AssistantModelExecutor;
  rows: Array<Record<string, unknown>>;
  provider: {
    complete: jest.Mock<
      Promise<AssistantModelResult>,
      [string, AssistantProfileSnapshot, AssistantModelRequest]
    >;
  };
  run: AssistantRun;
  parent: Record<string, unknown>;
} {
  // 合成运行不访问数据库、密钥或网络。
  const run = {
    id: 'run',
    userId: 'owner',
    sessionId: 'session',
    leaseOwner: 'worker',
    profileSnapshot: {},
  } as AssistantRun;
  // 子请求保持写入顺序，读取返回副本以模拟重新启动。
  const rows: Array<Record<string, unknown>> = [];
  // 逻辑attempt固定身份，只由请求完成事实推进。
  const parent: Record<string, unknown> = {
    id: 'attempt',
    status: 'processing',
  };
  // 实际网络替身只提供固定纯文本结果。
  const provider = {
    complete: jest
      .fn<
        Promise<AssistantModelResult>,
        [string, AssistantProfileSnapshot, AssistantModelRequest]
      >()
      .mockResolvedValue({
        responseId: 'response',
        text: '完成',
        functionCalls: [],
        output: [],
        usage: null,
      }),
  };
  // 事务模型提供本例需要的租约和请求账本操作。
  const database = {
    assistantRun: { findFirst: jest.fn().mockResolvedValue(run) },
    assistantAttempt: {
      findMany: (): Promise<unknown[]> =>
        Promise.resolve([
          { ...parent, requests: rows.map((entry) => ({ id: entry.id })) },
        ]),
      update: ({ data }: { data: Record<string, unknown> }): Promise<unknown> =>
        Promise.resolve(Object.assign(parent, data)),
    },
    assistantAttemptRequest: {
      findMany: (): Promise<unknown[]> =>
        Promise.resolve(structuredClone(rows)),
      create: ({
        data,
      }: {
        data: Record<string, unknown>;
      }): Promise<unknown> => {
        rows.push({ ...data });
        return Promise.resolve(rows.at(-1));
      },
      update: ({
        where,
        data,
      }: {
        where: { id: string };
        data: Record<string, unknown>;
      }): Promise<unknown> =>
        Promise.resolve(
          Object.assign(rows.find((entry) => entry.id === where.id)!, data),
        ),
    },
  };
  // 授权事务在本例无失败写入，隔离数据库另做原子性验证。
  const prisma = {
    ...database,
    $transaction: async (
      operation: (transaction: typeof database) => Promise<unknown>,
    ): Promise<unknown> => operation(database),
  };
  const store = {
    prisma,
    authorized: async (
      _actor: unknown,
      operation: (transaction: typeof database) => Promise<unknown>,
    ): Promise<unknown> => operation(database),
  };
  return {
    executor: new AssistantModelExecutor(
      store as unknown as AssistantStore,
      provider as unknown as AssistantModelProvider,
    ),
    rows,
    provider,
    run,
    parent,
  };
}

/// 普通请求不含文件字节、用户业务资料或真实凭据。
const request = {
  instructions: '固定指令',
  input: [{ role: 'user', content: '测试' }],
  tools: [],
};

describe('模型请求持久恢复', () => {
  it('旧安全重试冻结auto时，工具阶段关闭后不重放原查询', async () => {
    // 恢复请求不可直接改为none，只能拒绝旧计划，由runner创建新的回答轮次。
    const f = fixture();
    f.rows.push({ id: 'planned', index: 0, request: { ...request, toolChoice: 'auto' }, deadlineAt: new Date(Date.now() + 10000), status: 'retryScheduled' });
    await expect(f.executor.execute(f.run, 'attempt', request, { queryLimitReached: true })).rejects.toMatchObject({ code: 'ASSISTANT_TOOL_LIMIT', facts: { submission: 'notSubmitted' } });
    expect(f.provider.complete).not.toHaveBeenCalled();
    expect(f.rows).toHaveLength(1);
    expect(f.rows[0]!.request).toMatchObject({ toolChoice: 'auto' });
  });

  it('旧attempt计一次，当前尚未出站的attempt不重复计数', () => {
    expect(assistantModelCallsUsed([{ id: 'old', requests: [] }, { id: 'new', requests: [] }], 'new')).toBe(1);
    expect(assistantModelCallsUsed([{ id: 'old', requests: [{ id: 'a' }, { id: 'b' }] }])).toBe(2);
  });

  it('纯查询预留第十二次出站资格，最终none回答可以使用', async () => {
    // 十一次已出站记录都属于当前逻辑请求，恢复仍沿用同一账本。
    const f = fixture();
    f.rows.push(...Array.from({ length: 11 }, (_, index) => ({ id: `prior-${index}`, index, request, deadlineAt: new Date(Date.now() + 10000), status: 'retryScheduled' })));
    await expect(f.executor.execute(f.run, 'attempt', request, { reserveFinalAnswer: true })).rejects.toMatchObject({ code: 'ASSISTANT_MODEL_LIMIT', facts: { submission: 'notSubmitted' } });
    expect(f.provider.complete).not.toHaveBeenCalled();
    // 独立最终回答保存自己的none请求，不能改写刚才的冻结恢复请求。
    const final = fixture();
    final.rows.push(...Array.from({ length: 11 }, (_, index) => ({ id: `prior-${index}`, index, request: { ...request, toolChoice: 'none' }, deadlineAt: new Date(Date.now() + 10000), status: 'contextReduced' })));
    await final.executor.execute(final.run, 'attempt', { ...request, toolChoice: 'none' });
    expect(final.provider.complete).toHaveBeenCalledTimes(1);
    expect(final.rows).toHaveLength(12);
  });

  it('安全重试也复验预留名额，不会占用最后一次回答预算', async () => {
    // 当前调用之前有十次实际请求，本次明确拒绝后到十一不再后台重发。
    const f = fixture();
    f.rows.push(...Array.from({ length: 10 }, (_, index) => ({ id: `prior-${index}`, index, request, deadlineAt: new Date(Date.now() + 10000), status: 'contextReduced' })));
    f.provider.complete.mockRejectedValueOnce(new AssistantModelFailure('AI_RATE_LIMITED', { submission: 'rejected', retryable: true }));
    await expect(f.executor.execute(f.run, 'attempt', request, { reserveFinalAnswer: true })).rejects.toMatchObject({ code: 'ASSISTANT_MODEL_LIMIT' });
    expect(f.provider.complete).toHaveBeenCalledTimes(1);
    expect(f.rows).toHaveLength(11);
  });

  it('实际十二次请求后即使最终回答也不能继续出站', async () => {
    // 请求上限依据持久账本，不因使用none而额外放宽。
    const f = fixture();
    f.rows.push(...Array.from({ length: 12 }, (_, index) => ({ id: `prior-${index}`, index, request, deadlineAt: new Date(Date.now() + 10000), status: 'contextReduced' })));
    await expect(f.executor.execute(f.run, 'attempt', { ...request, toolChoice: 'none' })).rejects.toMatchObject({ code: 'ASSISTANT_MODEL_LIMIT' });
    expect(f.provider.complete).not.toHaveBeenCalled();
  });

  it('已确认未提交的短暂失败只重试一次，并沿用截止时间及完整请求', async () => {
    // 两次失败避免测试依赖供应商是否最终成功。
    const f = fixture();
    f.provider.complete.mockRejectedValue(
      new AssistantModelFailure('AI_CONNECT_FAILED', {
        submission: 'notSubmitted',
        retryable: true,
      }),
    );
    await expect(
      f.executor.execute(f.run, 'attempt', request),
    ).rejects.toMatchObject({ code: 'AI_CONNECT_FAILED' });
    expect(f.provider.complete).toHaveBeenCalledTimes(2);
    expect(f.rows).toHaveLength(2);
    expect(f.rows[0]!.deadlineAt).toEqual(f.rows[1]!.deadlineAt);
    expect(f.rows[0]!.requestHash).toEqual(f.rows[1]!.requestHash);
    expect(f.parent.status).toBe('notSubmitted');
  });

  it.each(['unknown', 'rejected'] as const)(
    '结果为%s且无安全重试事实时只发送一次',
    async (submission) => {
      // HTTP永久拒绝和未知出站均不得通过错误码强行重试。
      const f = fixture();
      f.provider.complete.mockRejectedValue(
        new AssistantModelFailure('AI_FAILURE', {
          submission,
          retryable: false,
        }),
      );
      await expect(
        f.executor.execute(f.run, 'attempt', request),
      ).rejects.toMatchObject({ code: 'AI_FAILURE' });
      expect(f.provider.complete).toHaveBeenCalledTimes(1);
      expect(f.parent.status).toBe(
        submission === 'unknown' ? 'submissionUnknown' : 'rejected',
      );
    },
  );

  it('恢复时遇到未完成出站记录，不再次请求供应商', async () => {
    // processing意味着崩溃时可能已提交。
    const f = fixture();
    f.rows.push({
      id: 'old',
      index: 0,
      request,
      deadlineAt: new Date(Date.now() + 10000),
      status: 'processing',
    });
    await expect(
      f.executor.execute(f.run, 'attempt', request),
    ).rejects.toMatchObject({ code: 'AI_SUBMISSION_UNKNOWN' });
    expect(f.provider.complete).not.toHaveBeenCalled();
  });

  it('已落库的等待计划恢复后不重置重试次数或初始输入', async () => {
    // 调用者传来的变化内容不能覆盖已冻结请求。
    const f = fixture();
    f.rows.push({
      id: 'old',
      index: 0,
      request,
      deadlineAt: new Date(Date.now() + 10000),
      retryAt: new Date(Date.now() - 1),
      status: 'retryScheduled',
    });
    await f.executor.execute(f.run, 'attempt', {
      ...request,
      instructions: '新指令不得进入恢复',
    });
    expect(f.provider.complete).toHaveBeenCalledTimes(1);
    expect(f.provider.complete.mock.calls[0]![2].instructions).toBe('固定指令');
    expect(f.rows[1]!.index).toBe(1);
  });

  it('供应商成功后同时保存子请求和完整付费响应，回执不含hydrate图像', async () => {
    // 合成hydrate字段只存在供应商调用参数中。
    const f = fixture();
    await f.executor.execute(f.run, 'attempt', request, {
      prepare: (saved) =>
        Promise.resolve({
          ...saved,
          input: [...saved.input, { image: 'runtime-only' }],
        }),
    });
    expect(f.parent.status).toBe('succeeded');
    expect(f.rows[0]!.status).toBe('succeeded');
    expect(JSON.stringify(f.parent.response)).not.toContain('runtime-only');
    expect(JSON.stringify(f.rows)).not.toContain('runtime-only');
  });

  it('明确上下文超限最多缩减一次，完整旧请求仍可审计', async () => {
    // 新请求使用更短输入而不修改原始请求记录。
    const f = fixture();
    f.provider.complete.mockRejectedValueOnce(
      new AssistantModelFailure('AI_CONTEXT_TOO_LARGE', {
        submission: 'rejected',
        retryable: false,
      }),
    );
    await f.executor.execute(
      f.run,
      'attempt',
      { ...request, input: [{ role: 'user', content: '旧资料'.repeat(100) }] },
      {
        compact: (saved) => Promise.resolve({ ...saved, input: request.input }),
      },
    );
    expect(f.provider.complete).toHaveBeenCalledTimes(2);
    expect(f.rows[0]!.requestHash).not.toBe(f.rows[1]!.requestHash);
    expect(JSON.stringify(f.rows[0]!.request)).toContain('旧资料');
  });
  it('hydrate耗尽截止时间时不再发出模型请求', async () => {
    // 仅替换时钟，真实退避与网络调用次数仍可观察。
    const f = fixture();
    const now = Date.now();
    const clock = jest.spyOn(Date, 'now').mockReturnValue(now);
    try {
      await expect(
        f.executor.execute(f.run, 'attempt', request, {
          prepare: (saved) => {
            clock.mockReturnValue(now + 60001);
            return Promise.resolve(saved);
          },
        }),
      ).rejects.toMatchObject({ code: 'AI_RETRY_BUDGET_EXHAUSTED' });
      expect(f.provider.complete).not.toHaveBeenCalled();
      expect(f.rows[0]!.status).toBe('notSubmitted');
    } finally {
      clock.mockRestore();
    }
  });

  it('压缩与遗忘交错时不重新写入旧上下文或再次出站', async () => {
    // 遗忘先完成，再让压缩回调返回旧资料。
    const f = fixture();
    f.provider.complete.mockRejectedValueOnce(
      new AssistantModelFailure('AI_CONTEXT_TOO_LARGE', {
        submission: 'rejected',
        retryable: false,
      }),
    );
    await expect(
      f.executor.execute(
        f.run,
        'attempt',
        { ...request, instructions: '旧资料'.repeat(100) },
        {
          compact: (saved) => {
            f.run.state = { memoryInvalidated: true };
            f.rows[0]!.request = { invalidated: true };
            return Promise.resolve({ ...saved, instructions: '短资料' });
          },
        },
      ),
    ).rejects.toMatchObject({ code: 'AI_CANCELLED' });
    expect(f.provider.complete).toHaveBeenCalledTimes(1);
    expect(f.rows[0]!.request).toEqual({ invalidated: true });
    expect(f.rows[0]!.nextRequest).toBeUndefined();
  });
});
