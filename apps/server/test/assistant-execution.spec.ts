import { BadRequestException, UnauthorizedException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { AssistantRunner } from '../src/assistant/assistant-runner.service';
import {
  assistantExecutionSteps,
  assistantLiveElapsedMs,
  assistantToolDetails,
} from '../src/assistant/assistant-execution';
import type { AssistantState } from '../src/assistant/assistant.types';
import type { AssistantRun } from '../src/generated/prisma/client';
import { AssistantRunFailure } from '../src/assistant/assistant-run-failure';
import type { AssistantModelRequest, AssistantModelResult, AssistantProfileSnapshot } from '../src/ai/assistant-model.types';
import { assistantCompatibility, assertAssistantImageInputs, createAssistantImagePart } from '../src/ai/assistant-model-policy';

/// 测试只使用合成行和内存替身，返回类型推导保留精确的Jest替身签名。
// eslint-disable-next-line @typescript-eslint/explicit-function-return-type
function fixture() {
  // 服务器生成的独立运行身份。
  const id = randomUUID();
  // 最小私有状态用于真实runner节点。
  const state: AssistantState = {
    input: [],
    intents: [],
    calls: [],
    toolCount: 0,
    modelCount: 0,
    messageId: randomUUID(),
    request: '新增一条待办',
    text: '',
    memoryVersion: 0,
  };
  // 租约属于测试worker，所有真实节点仍经过assertLease。
  const run = {
    id,
    taskId: randomUUID(),
    userId: randomUUID(),
    sessionId: randomUUID(),
    conversationId: randomUUID(),
    answerMessageId: state.messageId,
    state,
    status: 'running',
    elapsedMs: 0,
    leaseOwner: 'test-worker',
    leaseUntil: new Date(Date.now() + 150000),
    updatedAt: new Date(),
    createdAt: new Date(),
    profileSnapshot: {},
  } as unknown as AssistantRun;
  // 固定任务对象由提交guard推进committed，模拟真实事务边界。
  const task = {
    id: run.taskId,
    runId: id,
    sessionId: run.sessionId,
    status: 'running',
    committed: false,
    actionId: null as string | null,
    plan: null as Record<string, unknown> | null,
  };
  // 事件保留调用时的JSON快照，后续state修改不能污染过去事件。
  const events: Array<{ type: string; data: Record<string, unknown> }> = [];
  // 付费回执只在内存保存。
  let attempt: Record<string, unknown> | null = null;
  // 保存消息只用于验证message.completed附带执行链。
  let message: Record<string, unknown> | null = null;
  // 单行更新模拟数据库JSON隔离和计时增量。
  const writeRun = (data: Record<string, unknown>): AssistantRun => {
    // 增量更新沿用真实elapsedMs语义。
    const { elapsedMs, ...rest } = data;
    Object.assign(run, structuredClone(rest), { updatedAt: new Date() });
    if (elapsedMs && typeof elapsedMs === 'object')
      run.elapsedMs += Number((elapsedMs as { increment: number }).increment);
    return structuredClone(run);
  };
  // 最小数据库方法不决定业务结果，业务状态由真实runner改变。
  // 每次真实请求的账本与逻辑attempt分开保存。
  const requests: Record<string, unknown>[] = [];
  const prisma = {
    assistantRun: {
      findFirst: jest.fn(() => Promise.resolve({ ...run })),
      findUnique: jest.fn(() => Promise.resolve(structuredClone(run))),
      findUniqueOrThrow: jest.fn(() => Promise.resolve(structuredClone(run))),
      update: jest.fn(({ data }: { data: Record<string, unknown> }) =>
        Promise.resolve(writeRun(data)),
      ),
      updateMany: jest.fn(
        ({
          where,
          data,
        }: {
          where: Record<string, unknown>;
          data: Record<string, unknown>;
        }) =>
          Promise.resolve(
            where.leaseOwner && where.leaseOwner !== run.leaseOwner
              ? { count: 0 }
              : (writeRun(data), { count: 1 }),
          ),
      ),
    },
    assistantTask: {
      findUnique: jest.fn(() => Promise.resolve({ ...task })),
      findUniqueOrThrow: jest.fn(() => Promise.resolve({ ...task })),
      update: jest.fn(({ data }: { data: Record<string, unknown> }) =>
        Promise.resolve(Object.assign(task, data)),
      ),
      updateMany: jest.fn(({ data }: { data: Record<string, unknown> }) => {
        Object.assign(task, data);
        return Promise.resolve({ count: 1 });
      }),
    },
    assistantSettings: {
      findUnique: jest.fn(() => Promise.resolve({ enabled: true })),
    },
    assistantAttemptRequest: {
      findMany: jest.fn(() => Promise.resolve(requests)),
      create: jest.fn(({ data }: { data: Record<string, unknown> }) => { requests.push(data); return Promise.resolve(data); }),
      update: jest.fn(({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => Promise.resolve(Object.assign(requests.find((entry) => entry.id === where.id)!, data))),
    },
    assistantAttempt: {
      updateMany: jest.fn(({ data }: { data: Record<string, unknown> }) => { if (attempt?.status !== 'succeeded') attempt = { ...attempt, ...data }; return Promise.resolve({ count: 1 }); }),
      findMany: jest.fn(() => Promise.resolve(attempt ? [{ ...attempt, requests: requests.map((entry) => ({ id: entry.id })) }] : [])),
      findUnique: jest.fn(() => Promise.resolve(attempt)),
      create: jest.fn(({ data }: { data: Record<string, unknown> }) => {
        attempt = data;
        return Promise.resolve(attempt);
      }),
      update: jest.fn(({ data }: { data: Record<string, unknown> }) => {
        attempt = { ...attempt, ...data };
        return Promise.resolve(attempt);
      }),
    },
    assistantMessage: {
      findFirst: jest.fn(() => Promise.resolve(null)),
      findUnique: jest.fn(() => Promise.resolve(message)),
      upsert: jest.fn(
        ({
          create,
          update,
        }: {
          create: Record<string, unknown>;
          update: Record<string, unknown>;
        }) => {
          message = message ? { ...message, ...update } : create;
          return Promise.resolve(message);
        },
      ),
    },
    assistantConversation: { update: jest.fn(() => Promise.resolve({})) },
    $transaction: jest.fn(
      (action: (db: unknown) => unknown): Promise<unknown> =>
        Promise.resolve(action(prisma)),
    ),
    $queryRaw: jest.fn(() => Promise.resolve([])),
  };
  // 公开快照复用生产安全投影，测试不会将完整state伪装为公开数据。
  const view = (): Record<string, unknown> => ({
    id,
    status: run.status,
    elapsedMs: run.elapsedMs,
    liveElapsedMs: assistantLiveElapsedMs(run),
    executionSteps: assistantExecutionSteps(run),
  });
  // owner事务在内存执行，租约验证仍使用真实runner逻辑。
  const store = {
    prisma,
    authorized: jest.fn((_actor: unknown, action: (db: unknown) => unknown) =>
      Promise.resolve(action(prisma)),
    ),
    run: jest.fn(() => Promise.resolve(view())),
    runView: jest.fn(() => Promise.resolve(view())),
    emit: jest.fn(
      (_id: string, type: string, data: Record<string, unknown>) => {
        events.push({ type, data: structuredClone(data) });
        return Promise.resolve();
      },
    ),
    deleteCheckpoints: jest.fn(() => Promise.resolve()),
  };
  // 工具列表固定模块，模型不能注入摘要标签。
  const actions = {
    listTools: jest.fn(() =>
      Promise.resolve([
        {
          name: 'search_todos',
          module: 'todos',
          write: false,
          inputSchema: {},
          description: '查询',
        },
        {
          name: 'create_todo',
          module: 'todos',
          write: true,
          inputSchema: {},
          description: '登记',
        },
      ]),
    ),
    read: jest.fn((): Promise<unknown> => Promise.resolve({ values: [] })),
    commit: jest.fn(
      async (
        _context: unknown,
        actionId: string,
        guard: (db: unknown, action: unknown) => Promise<void>,
      ) => {
        await guard(prisma, { id: actionId });
        return { status: 'succeeded', result: { values: [] } };
      },
    ),
    status: jest.fn(() =>
      Promise.resolve({ status: 'succeeded', result: { values: [] } }),
    ),
  };
  // 返回完整合成响应，无网络请求。
  const model = {
    complete: jest.fn<Promise<AssistantModelResult>, [string, AssistantProfileSnapshot, AssistantModelRequest]>(() =>
      Promise.resolve({ responseId: randomUUID(), output: [], functionCalls: [], text: '回答', usage: null }),
    ),
  };
  // 来源显示替身只返回真实工具对应的合成引用。
  const presentation = {
    result: jest.fn(() => Promise.resolve({ values: [], entityRefs: [] })),
    readReferences: jest.fn<Promise<Record<string, unknown>[]>, []>(() => Promise.resolve([])),
  };
  // 不执行构造器，避免PostgresSaver建立真实连接。
  const runner = Object.create(AssistantRunner.prototype) as AssistantRunner;
  Object.assign(runner, {
    store,
    model,
    actions,
    reviews: {},
    presentation,
    contexts: {
      build: jest.fn((_run: unknown, current: AssistantState) =>
        Promise.resolve(current.input),
      ),
    },
    workerId: 'test-worker',
    requests: new Map(),
  });
  return {
    run,
    task,
    events,
    store,
    actions,
    model,
    runner,
    presentation,
    setAttempt: (saved: Record<string, unknown> | null): void => {
      attempt = saved;
    },
  };
}

describe('助手执行摘要和执行段快照', () => {
  it.each([false, true])('可读思考进入执行链，正文独立且成功回执恢复=%s不重复计费', async (replay) => {
    // 原协议中的公开摘要可以展示，加密续接字段不能一起投影。
    const response: AssistantModelResult = { responseId: randomUUID(), text: '最终回答', functionCalls: [], usage: null, output: [{ type: 'reasoning', summary: [{ type: 'summary_text', text: '先核对资料，再组织回答。' }], encrypted_content: 'private-cipher' }, { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '最终回答' }] }] };
    // 正式runner/executor持久化状态和发布事件，仅存储及模型网络为替身。
    const test = fixture();
    Object.assign(test.run.state as object, { answerOnly: true });
    if (replay) test.setAttempt({ status: 'succeeded', response });
    else test.model.complete.mockImplementationOnce(async (_owner, _profile, input) => {
      await input.onReasoning?.({ text: '先核对资料' });
      expect(test.events.some((event) => event.type === 'run.updated' && JSON.stringify(event.data).includes('先核对资料'))).toBe(true);
      await input.onDelta?.('最终回答');
      return response;
    });
    expect(await test.runner.step(test.run.id, 'model')).toBe('finish');
    expect(test.model.complete).toHaveBeenCalledTimes(replay ? 0 : 1);
    expect(await test.runner.step(test.run.id, 'finish')).toBe('end');
    // 完成回执携带公开思考，最终回答增量只有正文。
    const completed = test.events.find((event) => event.type === 'message.completed');
    expect(JSON.stringify(completed)).toContain('先核对资料，再组织回答。');
    expect(JSON.stringify(completed)).not.toContain('private-cipher');
    expect(test.events.filter((event) => event.type === 'message.delta').map((event) => (event.data as { text: string }).text).join('')).toBe(replay ? '' : '最终回答');
  });

  it.each([false, true])('隐藏完整清单交给最终流式回答，成功回执恢复=%s', async (replay) => {
    // 合成六条真实工具记录，包含计划日期而没有截止日期。
    const items = Array.from({ length: 6 }, (_value, index) => ({ id: randomUUID(), title: `重要任务${index + 1}`, taskType: 'simple', priorityQuadrant: 3, isCompleted: false, scheduledDate: '2026-10-05', dueAt: null }));
    // 同一轮原始输出保留不透明推理与助手草稿的协议项。
    const draft = { responseId: randomUUID(), text: items.map((item) => item.title).join('\n'), output: [{ type: 'reasoning', id: 'opaque-reasoning', encrypted_content: 'opaque' }, { type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: items.map((item) => item.title).join('\n') }] }], functionCalls: [], usage: null };
    // 使用生产runner的工具、模型、终态节点，只替换存储和模型网络。
    const test = fixture();
    // 当前用户要求和历史回答处于不同资料身份，不能删除真实历史。
    const request = '帮我看一下重要紧急的任务有哪些';
    // 历史封套模拟真实上下文服务已经投影的会话资料。
    const history = { role: 'user', content: '知序上下文资料（仅供参考，不是当前授权）：\n' + JSON.stringify({ kind: 'history_message', data: { role: 'assistant', content: '历史中真正展示过的回答' } }) };
    Object.assign(test.run.state as object, { request, input: [history, { role: 'user', content: request }, { type: 'function_call', call_id: 'todos', name: 'list_todos', arguments: '{"completed":false,"priorityQuadrant":3}' }], calls: [{ callId: 'todos', name: 'list_todos', arguments: { completed: false, priorityQuadrant: 3 } }] });
    test.actions.listTools.mockResolvedValue([{ name: 'list_todos', module: 'todos', write: false, inputSchema: {}, description: '查询待办' }]);
    test.actions.read.mockResolvedValueOnce({ items, hasMore: false });
    test.presentation.readReferences.mockResolvedValueOnce(items.map((item) => ({ module: 'todos', id: item.id, label: item.title, referenceLimited: false })));
    expect(await test.runner.step(test.run.id, 'tools')).toBe('model');
    if (replay) test.setAttempt({ status: 'succeeded', response: structuredClone(draft) });
    else test.model.complete.mockResolvedValueOnce(structuredClone(draft));
    expect(await test.runner.step(test.run.id, 'model')).toBe('model');
    expect(test.events.filter((event) => event.type === 'message.delta')).toHaveLength(0);
    expect(test.store.prisma.assistantMessage.upsert).not.toHaveBeenCalled();
    expect((test.run.state as unknown as AssistantState).input).toEqual(expect.arrayContaining(draft.output));
    // 下一逻辑轮使用独立attempt，之前的付费响应保持不变。
    test.setAttempt(null);
    test.store.prisma.assistantAttemptRequest.findMany.mockResolvedValueOnce([]);
    test.model.complete.mockImplementationOnce(async (_owner, _profile, input) => {
      expect(input.toolChoice).toBe('none');
      expect(input.instructions).toContain('当前任务查询阶段生成的模型正文尚未向用户展示');
      expect(input.instructions).toContain('必须重新给出用户所问的具体结果');
      expect(input.instructions).not.toContain('明确覆盖范围及推测');
      expect(input.input).toEqual(expect.arrayContaining([history, ...draft.output]));
      // 模拟模型按真实读取结果生成完整正文，逐段走生产流式事件。
      const text = `找到 6 项重要且紧急的未完成待办：\n${items.map((item) => `- ${item.title}`).join('\n')}`;
      for (const part of [text.slice(0, 15), text.slice(15)]) await input.onDelta?.(part);
      return { responseId: randomUUID(), text, output: [{ role: 'assistant', content: text }], functionCalls: [], usage: null };
    });
    expect(await test.runner.step(test.run.id, 'model')).toBe('finish');
    expect(await test.runner.step(test.run.id, 'finish')).toBe('end');
    // 最终消息和流式片段必须是同一份完整答案，没有隐藏草稿拼接。
    const completed = test.events.find((event) => event.type === 'message.completed')!;
    // completed正文从持久存储读取，不能仅断言内存state。
    const message = completed.data.message as { content: string; cards: Record<string, unknown>[] };
    expect(test.events.filter((event) => event.type === 'message.delta').map((event) => event.data.text).join('')).toBe(message.content);
    for (const item of items) expect(message.content).toContain(item.title);
    expect(message.content).not.toContain('上一条');
    expect(message.cards).toEqual([expect.objectContaining({ type: 'references', referencesTruncated: false })]);
    expect(test.model.complete).toHaveBeenCalledTimes(replay ? 1 : 2);
    expect(test.actions.read).toHaveBeenCalledTimes(1);
    expect(test.actions.commit).not.toHaveBeenCalled();
  });

  it('多页引用累计超过二十条才标记截断，后续去重不会清除事实', async () => {
    // 独立fixture仅验证引用收集，不声明业务查询是否完整。
    const test = fixture();
    // 两页各十二条，单页都没有截断，但累计引用超过卡片限制。
    const refs = Array.from({ length: 24 }, (_value, index) => ({ module: 'todos', id: randomUUID(), label: `记录${index}`, referenceLimited: false }));
    for (const page of [refs.slice(0, 12), refs.slice(12), refs.slice(0, 1)]) {
      Object.assign(test.run.state as object, { calls: [{ callId: randomUUID(), name: 'search_todos', arguments: {} }] });
      test.presentation.readReferences.mockResolvedValueOnce(page);
      await test.runner.step(test.run.id, 'tools');
    }
    expect(test.run.state).toMatchObject({ referencesTruncated: true, references: refs.slice(0, 20) });
    await test.runner.step(test.run.id, 'finish');
    expect((test.events.find((event) => event.type === 'message.completed')?.data.message as { cards: unknown[] }).cards).toEqual([expect.objectContaining({ referencesTruncated: true })]);
  });

  it('单次工具引用已截断时沿用真实标记，不把二十条误认为完整引用', async () => {
    // 卡片引用由显示服务验证后的实际截断事实提供。
    const test = fixture();
    Object.assign(test.run.state as object, { calls: [{ callId: 'read', name: 'search_todos', arguments: {} }] });
    test.presentation.readReferences.mockResolvedValueOnce([{ id: randomUUID(), module: 'todos', label: '真实记录', referenceLimited: true }]);
    await test.runner.step(test.run.id, 'tools');
    expect(test.run.state).toMatchObject({ referencesTruncated: true });
  });

  it.each(['empty', 'partial', 'committed'] as const)('%s 最终阶段遵循空结果、实际限制或提交回执', async (scenario) => {
    // 阶段来自服务器状态，工具文本不能伪造写入成功或查询完整性。
    const test = fixture();
    Object.assign(test.run.state as object, { request: '查询待办', input: [{ role: 'user', content: '查询待办' }], answerOnly: scenario !== 'committed', ...(scenario === 'partial' ? { readLimit: 'ASSISTANT_TOOL_LIMIT' } : {}), ...(scenario === 'committed' ? { result: { values: [] } } : {}) });
    test.task.committed = scenario === 'committed';
    test.model.complete.mockImplementationOnce((_owner, _profile, input) => {
      expect(input.toolChoice).toBe('none');
      if (scenario === 'committed') {
        expect(input.instructions).toContain('当前阶段：根据服务器实际执行回执');
        expect(input.instructions).not.toContain('只能视为未交付草稿');
      } else if (scenario === 'partial') expect(input.instructions).toContain('查询预算已到上限');
      else {
        expect(input.instructions).toContain('若有效查询无结果');
        expect(input.instructions).not.toContain('查询预算已到上限');
      }
      return Promise.resolve({ responseId: randomUUID(), text: '阶段对应的合成回答', output: [], functionCalls: [], usage: null });
    });
    expect(await test.runner.step(test.run.id, 'model')).toBe('finish');
  });

  it('恢复旧auto重试达到保留额度时先关闭原轮次，不占用最后一次回答请求', async () => {
    // 冻结请求来自可安全恢复的旧计划，不能直接被当前none选项覆盖。
    const test = fixture();
    Object.assign(test.run.state as object, { request: '查询待办' });
    test.setAttempt({ id: 'old-attempt', status: 'retryScheduled', ordinal: 1 });
    // 每项原始账本都已明确失败且计划恢复；本例只验证最后额度门禁。
    const saved = Array.from({ length: 11 }, (_, index) => ({ id: `saved-${index}`, index, status: 'retryScheduled', deadlineAt: new Date(Date.now() + 10000), request: { instructions: '旧固定指令', input: [], tools: [], toolChoice: 'auto' } }));
    test.store.prisma.assistantAttemptRequest.findMany.mockResolvedValueOnce(saved);
    // 测试账本带实际父身份，不能把旧attempt误计为尚未出站的空轮次。
    const ledger = [{ id: 'old-attempt', requests: saved }];
    test.store.prisma.assistantAttempt.findMany.mockResolvedValue(ledger);
    expect(await test.runner.step(test.run.id, 'model')).toBe('model');
    expect(test.model.complete).not.toHaveBeenCalled();
    expect(test.run.state).toMatchObject({ modelCount: 1, answerOnly: true, readLimit: 'ASSISTANT_MODEL_LIMIT' });
    expect(test.store.prisma.assistantAttemptRequest.create).not.toHaveBeenCalled();
  });

  it('最终回答阶段违规返回工具也不执行，且不伪造调用限额原因', async () => {
    // 已成功的旧回执也须经过服务端阶段门禁，不能绕过none的约束。
    const test = fixture();
    Object.assign(test.run.state as object, { request: '查询待办', answerOnly: true });
    test.setAttempt({ status: 'succeeded', response: { requestInput: [], text: '不可信模型文字', output: [{ type: 'function_call', call_id: 'unexpected', name: 'search_todos', arguments: '{}' }], functionCalls: [{ callId: 'unexpected', name: 'search_todos', arguments: {} }] } });
    expect(await test.runner.step(test.run.id, 'model')).toBe('finish');
    expect(test.actions.read).not.toHaveBeenCalled();
    expect(test.actions.commit).not.toHaveBeenCalled();
    expect(test.run.state).toMatchObject({ calls: [], text: expect.stringContaining('该调用未执行') });
    expect((test.run.state as unknown as AssistantState).readLimit).toBeUndefined();
  });

  it('待办结果保持有界摘要并公开准确计数，状态保存真实分页进度', async () => {
    // 真实大步骤列表只用于验证runner边界投影，不访问真实业务数据。
    const test = fixture();
    test.actions.listTools.mockResolvedValueOnce([{ name: 'list_todos', module: 'todos', write: false, inputSchema: {}, description: '查询' }]);
    Object.assign(test.run.state as object, { request: '查询重要紧急待办', calls: [{ callId: 'large-todo', name: 'list_todos', arguments: { priorityQuadrant: 3, completed: false, limit: 200, offset: 20 } }] });
    test.actions.read.mockResolvedValueOnce({ items: [{ id: randomUUID(), title: '重要任务', taskType: 'progress', priorityQuadrant: 3, isCompleted: false, description: '正文'.repeat(20000), progressSteps: Array.from({ length: 1000 }, () => ({ isCompleted: true })) }], hasMore: true });
    expect(await test.runner.step(test.run.id, 'tools')).toBe('model');
    // 权威状态包含的是实际交付记录及真实下一页，不只是工具名。
    const saved = test.run.state as unknown as AssistantState;
    expect(saved.readProgress).toMatchObject([{ filters: { priorityQuadrant: 3, completed: false }, delivered: { offset: 20, endOffset: 21 }, nextOffset: 21, returnedCount: 1 }]);
    expect(Buffer.byteLength(JSON.stringify(saved.input))).toBeLessThan(16384);
    expect(JSON.stringify(saved.input)).not.toContain('progressSteps');
    expect(assistantExecutionSteps(test.run)).toMatchObject([{ status: 'succeeded', detail: '已读取1条，进度步骤已摘要，仍有后续记录' }]);
  });

  it('同一模型响应的九项只读调用仅执行八项，未执行项配对为限额结果', async () => {
    // 即使模型并行提出九项查询，硬限制也不能在第九项执行之后才检查。
    const test = fixture();
    Object.assign(test.run.state as object, { request: '查询待办', calls: Array.from({ length: 9 }, (_, index) => ({ callId: `read-${index}`, name: 'search_todos', arguments: {} })) });
    expect(await test.runner.step(test.run.id, 'tools')).toBe('model');
    // 已成功八项保持成功，最后一项没有被伪造为已执行。
    const saved = test.run.state as unknown as AssistantState;
    expect(test.actions.read).toHaveBeenCalledTimes(8);
    expect(saved).toMatchObject({ toolCount: 8, readLimit: 'ASSISTANT_TOOL_LIMIT', answerOnly: true, calls: [] });
    expect(saved.input.filter((item) => item.type === 'function_call_output')).toHaveLength(9);
    expect(saved.input.find((item) => item.call_id === 'read-8')).toMatchObject({ output: expect.stringContaining('ASSISTANT_TOOL_LIMIT') });
    expect(test.actions.commit).not.toHaveBeenCalled();
  });

  it('纯查询达到八次后只请求一次无工具最终回答，并明确部分覆盖', async () => {
    // 上限由已持久化计数恢复，不能因进程重启重新获得工具预算。
    const test = fixture();
    Object.assign(test.run.state as object, { request: '查询待办', toolCount: 8 });
    expect(await test.runner.step(test.run.id, 'model')).toBe('finish');
    expect(test.model.complete).toHaveBeenCalledTimes(1);
    expect(test.model.complete.mock.calls[0]).toEqual(expect.arrayContaining([expect.objectContaining({ toolChoice: 'none' })]));
    expect(await test.runner.step(test.run.id, 'finish')).toBe('end');
    expect(test.events.find((event) => event.type === 'message.completed')?.data).toMatchObject({ message: { content: expect.stringContaining('未读取部分尚未核实') } });
    expect(test.actions.read).not.toHaveBeenCalled();
    expect(test.actions.commit).not.toHaveBeenCalled();
  });

  it('实际十二次出站预算耗尽时直接保留固定答复，不再付费', async () => {
    // 旧attempt也计入任务硬上限；本例不依赖逻辑modelCount。
    const test = fixture();
    Object.assign(test.run.state as object, { request: '查询待办' });
    test.store.prisma.assistantAttempt.findMany.mockResolvedValueOnce(Array.from({ length: 12 }, () => ({ id: randomUUID(), requests: [] })));
    expect(await test.runner.step(test.run.id, 'model')).toBe('finish');
    expect(test.model.complete).not.toHaveBeenCalled();
    expect(test.run.state).toMatchObject({ readLimit: 'ASSISTANT_MODEL_LIMIT', answerOnly: true, text: expect.stringContaining('没有可直接展示') });
  });

  it.each(['ASSISTANT_TOOL_LIMIT', 'ASSISTANT_DATA_CONFLICT'] as const)('执行终态按真实%s分类，不笼统使用HTTP冲突', async (code) => {
    // 使用真实execute catch与finally检查对外错误投影。
    const test = fixture();
    Object.assign(test.runner, { graph: { getState: () => Promise.resolve({ next: [] }), invoke: () => Promise.reject(new AssistantRunFailure(code)) } });
    await (test.runner as unknown as { execute(id: string): Promise<void> }).execute(test.run.id);
    expect(test.run).toMatchObject({ status: 'failed', errorCode: code });
    expect(test.run.errorMessage?.includes('数据已发生变化')).toBe(code === 'ASSISTANT_DATA_CONFLICT');
  });

  it('真实工具详情保留实际参数和函数名，写工具仅planned且实际提交另记成功', async () => {
    // 两种工具由同一真实节点顺序处理。
    const test = fixture();
    (test.run.state as unknown as AssistantState).calls = [
      {
        callId: 'sensitive-call-id',
        name: 'search_todos',
        arguments: { query: 'private-query', apiKey: 'private-credential' },
      },
      {
        callId: 'write-call',
        name: 'create_todo',
        arguments: { title: 'private-title' },
      },
    ];
    expect(await test.runner.step(test.run.id, 'tools')).toBe('model');
    expect(
      assistantExecutionSteps(test.run).map((step) => [
        step.label,
        step.status,
      ]),
    ).toEqual([
      ['查询待办', 'succeeded'],
      ['登记待办修改计划', 'planned'],
    ]);
    expect(test.actions.commit).not.toHaveBeenCalled();
    expect(assistantExecutionSteps(test.run)[0]!.tool).toEqual({ name: 'search_todos', arguments: { query: 'private-query', apiKey: '[已隐藏]' } });
    expect(assistantExecutionSteps(test.run)[1]!.tool).toEqual({ name: 'create_todo', arguments: { title: 'private-title' } });
    expect(JSON.stringify(test.events)).not.toContain('private-credential');
    expect(JSON.stringify(test.events)).not.toContain('sensitive-call-id');
    test.task.actionId = randomUUID();
    test.task.plan = { targetCount: 1 };
    expect(await test.runner.step(test.run.id, 'commit')).toBe('model');
    expect(test.actions.commit).toHaveBeenCalledTimes(1);
    expect(
      assistantExecutionSteps(test.run).map((step) => step.status),
    ).toEqual(['succeeded', 'planned', 'succeeded']);
    // checkpoint重放只读取回执，不能再提交业务或产生重复步骤。
    expect(await test.runner.step(test.run.id, 'dispatch')).toBe('finish');
    expect(test.actions.commit).toHaveBeenCalledTimes(1);
    expect(assistantExecutionSteps(test.run)).toHaveLength(3);
    await test.runner.step(test.run.id, 'finish');
    expect(
      (
        test.events.find((event) => event.type === 'message.completed')!.data
          .message as Record<string, unknown>
      ).executionSteps,
    ).toHaveLength(3);
  });

  it('工具参数限制嵌套与UTF8字节，敏感字段脱敏并明确标记省略', () => {
    // 标准参数保持JSON结构，不能只返回无来源的摘要字符串。
    expect(assistantToolDetails({ name: 'read_attachment', arguments: { page: 2, filter: { accessToken: 'credential', query: '报告' } } })).toEqual({ name: 'read_attachment', arguments: { page: 2, filter: { accessToken: '[已隐藏]', query: '报告' } } });
    // 极大参数不能扩大事件和缓存体积。
    const result = assistantToolDetails({ name: 'search_todos', arguments: { items: Array.from({ length: 20 }, () => '中'.repeat(4000)) } });
    expect(result?.truncated).toBe(true);
    expect(Buffer.byteLength(JSON.stringify(result))).toBeLessThan(17000);
    expect(assistantToolDetails({ name: 'invalid-name', arguments: {} })).toBeUndefined();
  });

  it('分批已保存范围按真实回执恢复，后批失败不抹掉前批成功', async () => {
    // 两批冻结计划用独立序号生成commit步骤身份。
    const test = fixture();
    // 批次结果在业务事务内落库，图checkpoint允许晚到。
    const batchPlan = {
      completedBatches: 0,
      requestIds: [randomUUID(), randomUUID()],
      results: [] as Array<{ status: string }>,
    };
    test.task.plan = { kind: 'batch', batchPlan };
    // 合成一次真实批次回执，后续调用失败，始终不访问业务数据库。
    const commitNext = jest.fn(() => {
      batchPlan.completedBatches = 1;
      batchPlan.results.push({ status: 'succeeded' });
      return Promise.resolve({
        done: false,
        actionId: randomUUID(),
        result: { completedBatches: 1 },
      });
    });
    Object.assign(test.runner, { batches: { commitNext } });
    expect(await test.runner.step(test.run.id, 'commit')).toBe('commit');
    // 模拟业务回执保存后、摘要完成保存前的崩溃窗口。
    (test.run.state as unknown as AssistantState).executionSteps![0]!.status =
      'running';
    expect(await test.runner.step(test.run.id, 'dispatch')).toBe('gate');
    expect(commitNext).toHaveBeenCalledTimes(1);
    expect(assistantExecutionSteps(test.run)[0]!.status).toBe('succeeded');
    commitNext.mockRejectedValueOnce(new Error('下一批冲突'));
    Object.assign(test.runner, {
      graph: {
        getState: () => Promise.resolve({ next: [] }),
        invoke: () => test.runner.step(test.run.id, 'commit'),
      },
    });
    await (
      test.runner as unknown as { execute(id: string): Promise<void> }
    ).execute(test.run.id);
    expect(
      assistantExecutionSteps(test.run).map((step) => [step.id, step.status]),
    ).toEqual([
      [`${test.run.id}:commit:batch:1`, 'succeeded'],
      [`${test.run.id}:commit:batch:2`, 'failed'],
    ]);
  });

  it('成功付费回执重放保留同一模型轮次，不重新调用供应商', async () => {
    // 成功attempt已落库，但state尚未推进，复现崩溃恢复窗口。
    const test = fixture();
    test.setAttempt({
      status: 'succeeded',
      response: { output: [], functionCalls: [], text: '已观察答案' },
    });
    expect(await test.runner.step(test.run.id, 'model')).toBe('model');
    expect(test.model.complete).not.toHaveBeenCalled();
    expect(assistantExecutionSteps(test.run)).toEqual([
      expect.objectContaining({
        id: `${test.run.id}:model:1`,
        status: 'succeeded',
      }),
    ]);
    expect(
      test.events
        .filter((event) => event.type === 'run.updated')
        .map(
          (event) =>
            (
              (event.data.run as Record<string, unknown>)
                .executionSteps as Array<{ status: string }>
            )[0]!.status,
        ),
    ).toEqual(['running', 'succeeded']);
  });

  it('失败结算保留工具失败摘要并清除执行段，未改变既有elapsedMs增量语义', async () => {
    // 真实execute负责异常状态、最终计时和run.updated。
    const test = fixture();
    (test.run.state as unknown as AssistantState).calls = [
      { callId: 'read', name: 'search_todos', arguments: {} },
    ];
    test.actions.read.mockRejectedValueOnce(new Error('private-error-body'));
    Object.assign(test.runner, {
      graph: {
        getState: () => Promise.resolve({ next: [] }),
        invoke: () => test.runner.step(test.run.id, 'tools'),
      },
    });
    await (
      test.runner as unknown as { execute(id: string): Promise<void> }
    ).execute(test.run.id);
    expect(test.run.status).toBe('failed');
    expect(assistantExecutionSteps(test.run)).toEqual([
      expect.objectContaining({ status: 'failed' }),
    ]);
    expect(
      (test.run.state as unknown as AssistantState).segmentStartedAt,
    ).toBeUndefined();
    expect(test.run.elapsedMs).toBeGreaterThanOrEqual(0);
    expect(test.run.leaseOwner).toBeNull();
    expect(JSON.stringify(test.events)).not.toContain('private-error-body');
  });

  it('取消抢先清除租约与私有状态，finally不能复活旧摘要或资料', async () => {
    // 取消发生在图执行中，模拟用户撤权/遗忘后迟到的finally。
    const test = fixture();
    Object.assign(test.runner, {
      graph: {
        getState: () => Promise.resolve({ next: [] }),
        invoke: () => {
          Object.assign(test.run, {
            status: 'cancelled',
            leaseOwner: null,
            leaseUntil: null,
            state: { memoryInvalidated: true },
          });
          return Promise.resolve();
        },
      },
    });
    await (
      test.runner as unknown as { execute(id: string): Promise<void> }
    ).execute(test.run.id);
    expect(test.run.state).toEqual({ memoryInvalidated: true });
    expect(test.run.elapsedMs).toBe(0);
    expect(test.store.deleteCheckpoints).toHaveBeenCalledTimes(1);
  });

  it.each(['forget', 'undo'])(
    'finally等到owner锁后重读，保留同期%s状态更新',
    async (change) => {
      // 真实完成状态仍持租约，模拟finally取锁前另一事务更新state。
      const test = fixture();
      // 已保存的补偿身份不能被锁前旧副本覆盖。
      const undoRunId = randomUUID();
      Object.assign(test.runner, {
        graph: {
          getState: () => Promise.resolve({ next: [] }),
          invoke: () => {
            test.run.status = 'succeeded';
            test.task.committed = true;
            return Promise.resolve();
          },
        },
      });
      test.store.prisma.$queryRaw.mockImplementationOnce(() => {
        // 遗忘成功任务不会清除现有租约，正是需要锁后重读的窗口。
        test.run.state =
          change === 'forget'
            ? { memoryInvalidated: true }
            : { ...(test.run.state as Record<string, unknown>), undoRunId };
        return Promise.resolve([]);
      });
      await (
        test.runner as unknown as { execute(id: string): Promise<void> }
      ).execute(test.run.id);
      expect(test.store.prisma.$queryRaw).toHaveBeenCalledTimes(1);
      expect(test.run.leaseOwner).toBeNull();
      if (change === 'forget')
        expect(test.run.state).toEqual({ memoryInvalidated: true });
      else expect(test.run.state).toMatchObject({ undoRunId });
    },
  );

  it.each([null, 'old-state', {}, { executionSteps: [null, {}] }])(
    '缺失或损坏的旧摘要安全回退：%p',
    (state) => {
      // 公开投影只接收最小安全元数据。
      const run = {
        id: randomUUID(),
        state,
        status: 'running',
        updatedAt: new Date(),
        elapsedMs: 7,
        leaseOwner: null,
        leaseUntil: null,
      };
      expect(assistantExecutionSteps(run)).toEqual([]);
      expect(assistantLiveElapsedMs(run)).toBe(7);
    },
  );
  it('已知只读参数错误保留前一查询结果并仅允许一次修正', async () => {
    // 两个调用属于同一轮，第一项成功结果不能因第二项错误丢失。
    const test = fixture();
    const state = test.run.state as unknown as AssistantState;
    state.calls = [{ callId: 'first', name: 'search_todos', arguments: {} }, { callId: 'second', name: 'search_todos', arguments: {} }];
    test.actions.read.mockResolvedValueOnce({ values: [] }).mockRejectedValueOnce(new BadRequestException('private query'));
    expect(await test.runner.step(test.run.id, 'tools')).toBe('model');
    // 每次persist都会产生独立快照，断言重新读取的权威状态。
    const saved = test.run.state as unknown as AssistantState;
    expect(saved.input.filter((item) => item.type === 'function_call_output')).toHaveLength(2);
    expect(JSON.stringify(saved.input)).not.toContain('private query');
    expect(saved.readCorrectionUsed).toBe(true);
    saved.calls = [{ callId: 'third', name: 'search_todos', arguments: {} }];
    test.actions.read.mockRejectedValueOnce(new BadRequestException('again'));
    await expect(test.runner.step(test.run.id, 'tools')).rejects.toThrow('again');
  });

  it('只读工具撤权不能降级为普通参数修正', async () => {
    // 安全类错误必须中断整轮。
    const test = fixture();
    (test.run.state as unknown as AssistantState).calls = [{ callId: 'first', name: 'search_todos', arguments: {} }];
    test.actions.read.mockRejectedValueOnce(new UnauthorizedException());
    await expect(test.runner.step(test.run.id, 'tools')).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('同任务逐页读第6张扫描页时滑动保留5图，不限制整份PDF可读页数', async () => {
    // 图片预算属于单次请求，已读来源仍保存在工具观察中。
    const test = fixture();
    const attachmentId = randomUUID();
    Object.assign(test.runner, { attachments: { read: (_actor: unknown, _conversation: string, id: string, range: { page: number }) => Promise.resolve({ name: 'scan.pdf', page: range.page, images: [{ attachmentId: id, page: range.page }] }) } });
    for (let page = 1; page <= 6; page++) {
      const state = test.run.state as unknown as AssistantState;
      state.calls = [{ callId: `page-${page}`, name: 'read_attachment', arguments: { attachmentId, page } }];
      await test.runner.step(test.run.id, 'tools');
    }
    const saved = test.run.state as unknown as AssistantState;
    expect(saved.attachmentImages).toHaveLength(5);
    expect(saved.attachmentImages!.map((image) => image.page)).toEqual([2, 3, 4, 5, 6]);
    expect(saved.input.filter((item) => item.type === 'function_call_output')).toHaveLength(6);
  });

  it('读图后空文字检索不丢图，最终流式回答仍收到图像且私有账本只保存引用', async () => {
    // 使用生产runner和executor，只有数据库与供应商网络为内存替身。
    const test = fixture();
    // 合成文件身份和有效PNG字节不包含任何用户资料。
    const attachmentId = randomUUID();
    // 规范图片经过生产品牌校验，不能用任意JSON模拟有效图像。
    const image = createAssistantImagePart(attachmentId, 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=');
    // 本次新任务明确开启多模态，旧的能力自述只是历史资料。
    const compatibility = { ...assistantCompatibility(), imageInput: 'supported' as const };
    test.run.profileSnapshot = { model: 'GLM-5.3-Flash', compatibility };
    Object.assign(test.run.state as object, {
      request: '这张图片的内容是什么',
      input: [{ role: 'user', content: '历史资料：上次回答声称不支持图片输入。' }, { role: 'user', content: '这张图片的内容是什么' }],
      calls: [{ callId: 'read-image', name: 'read_attachment', arguments: { attachmentId, page: 1 } }],
    });
    // 附件服务只返回已授权引用，实际装载在每次请求出站前执行。
    const attachments = {
      read: jest.fn(() => Promise.resolve({ name: 'diagram.png', chunks: [], images: [{ attachmentId }] })),
      search: jest.fn(() => Promise.resolve({ name: 'diagram.png', matches: [], totalMatches: 0 })),
      contextManifest: jest.fn(() => Promise.resolve([{ id: attachmentId, kind: 'image', requiresVision: true }])),
      hydrateImages: jest.fn(() => Promise.resolve([image])),
    };
    Object.assign(test.runner, { attachments, contexts: {
      build: (_run: unknown, state: AssistantState): Promise<Record<string, unknown>[]> => Promise.resolve(state.input),
      compact: (input: Record<string, unknown>[]): Record<string, unknown>[] => input,
    } });
    expect(await test.runner.step(test.run.id, 'tools')).toBe('model');
    // 每次模型实际收到品牌图片，而不是仅看到附件名或空文字块。
    const verifyImage = (request: AssistantModelRequest): void => {
      expect(assertAssistantImageInputs(request.input, compatibility)).toBe(true);
      expect(request.instructions).toContain('本次模型配置已开启图片输入');
      expect(JSON.stringify(request.input)).toContain('本次请求已附加以下1张实际图像');
      expect(request.input.some((item) => 'assistantAttachmentManifest' in item)).toBe(false);
    };
    test.model.complete.mockImplementationOnce((_owner, _profile, request) => {
      verifyImage(request);
      return Promise.resolve({ responseId: randomUUID(), text: '', usage: null, output: [{ type: 'function_call', call_id: 'search-image', name: 'search_attachment', arguments: JSON.stringify({ attachmentId, query: '图片' }) }], functionCalls: [{ id: 'search-image', callId: 'search-image', name: 'search_attachment', arguments: { attachmentId, query: '图片' } }] });
    });
    expect(await test.runner.step(test.run.id, 'model')).toBe('tools');
    expect(await test.runner.step(test.run.id, 'tools')).toBe('model');
    expect((test.run.state as unknown as AssistantState).attachmentImages).toEqual([{ attachmentId }]);
    // 每个逻辑轮次对应独立attempt，保留之前的请求写入供末尾审计。
    test.setAttempt(null);
    test.store.prisma.assistantAttemptRequest.findMany.mockResolvedValueOnce([]);
    test.model.complete.mockImplementationOnce((_owner, _profile, request) => {
      verifyImage(request);
      return Promise.resolve({ responseId: randomUUID(), text: '图像已读取', usage: null, output: [], functionCalls: [] });
    });
    expect(await test.runner.step(test.run.id, 'model')).toBe('model');
    test.setAttempt(null);
    test.store.prisma.assistantAttemptRequest.findMany.mockResolvedValueOnce([]);
    test.model.complete.mockImplementationOnce(async (_owner, _profile, request) => {
      verifyImage(request);
      expect(request.toolChoice).toBe('none');
      await request.onDelta?.('根据 diagram.png，图像已读取。');
      return { responseId: randomUUID(), text: '根据 diagram.png，图像已读取。', usage: null, output: [], functionCalls: [] };
    });
    expect(await test.runner.step(test.run.id, 'model')).toBe('finish');
    expect(await test.runner.step(test.run.id, 'finish')).toBe('end');
    expect(attachments.hydrateImages).toHaveBeenCalledTimes(3);
    expect(test.events).toEqual(expect.arrayContaining([expect.objectContaining({ type: 'message.delta', data: expect.objectContaining({ text: '根据 diagram.png，图像已读取。' }) })]));
    expect(JSON.stringify(test.run.state)).not.toContain('data:image/');
    expect(JSON.stringify(test.events)).not.toContain('data:image/');
    expect(JSON.stringify(test.store.prisma.assistantAttemptRequest.create.mock.calls)).not.toContain('data:image/');
    expect(JSON.stringify(test.store.prisma.assistantAttempt.update.mock.calls)).not.toContain('data:image/');
    expect(test.actions.commit).not.toHaveBeenCalled();
  });

});
