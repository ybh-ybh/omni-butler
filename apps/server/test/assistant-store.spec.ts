import { randomUUID } from 'node:crypto';
import { Prisma } from '../src/generated/prisma/client';
import type { PrismaService } from '../src/prisma/prisma.service';
import type { AiService } from '../src/ai/ai.service';
import type { ActionExecutor } from '../src/mcp/action-executor';
import type { AuthUser } from '../src/auth/auth.types';
import { AssistantStore } from '../src/assistant/assistant-store.service';

/// 只模拟数据库 CRUD，所有任务、确认、记忆和来源逻辑使用真实服务。
type Row = Record<string, unknown>;
/// JSONB 包含语义仅用于结果引用查询的驱动边界。
function jsonContains(actual: unknown, expected: unknown): boolean {
  if (Array.isArray(expected))
    return (
      Array.isArray(actual) &&
      expected.every((part) =>
        actual.some((entry: unknown) => jsonContains(entry, part)),
      )
    );
  if (expected && typeof expected === 'object')
    return (
      !!actual &&
      typeof actual === 'object' &&
      Object.entries(expected).every(([key, value]) =>
        jsonContains((actual as Row)[key], value),
      )
    );
  return actual === expected;
}
/// 确定性驱动提供事务回滚，避免将测试桩视为数据库集成证明。
class StoreDatabase {
  /// 每张测试表独立保存记录。
  readonly tables: Record<string, Row[]> = {};
  /// 模拟真实有效设备身份。
  readonly actor: AuthUser = {
    sub: randomUUID(),
    sid: randomUUID(),
    typ: 'access',
  };
  /// 表操作只供服务真实方法调用。
  readonly database: Record<string, unknown> = {};
  /// 检查点删除保留参数证据。
  readonly deletes = jest.fn(() => Promise.resolve(0));

  /// 建立独立内存表，既不加载环境变量也不连接真实数据。
  constructor() {
    for (const name of [
      'deviceSession',
      'aiSettings',
      'aiProfile',
      'assistantSettings',
      'assistantConversation',
      'assistantMessage',
      'assistantTask',
      'assistantRun',
      'assistantEvent',
      'assistantAttempt',
      'assistantMemory',
      'mcpAction',
    ]) {
      // 所有模型复用相同 CRUD，而不复制助手业务判断。
      this.tables[name] = [];
      this.database[name] = this.model(name);
    }
    this.database.$queryRaw = jest.fn(() =>
      Promise.resolve([{ id: this.actor.sub }]),
    );
    this.database.$executeRaw = this.deletes;
    this.database.$transaction = async (
      callback: (transaction: Prisma.TransactionClient) => Promise<unknown>,
    ): Promise<unknown> => {
      // 失败用例也必须回滚，防止桩掩盖先取消后报错的原子性问题。
      const before = structuredClone(this.tables);
      try {
        return await callback(
          this.database as unknown as Prisma.TransactionClient,
        );
      } catch (error) {
        for (const name of Object.keys(this.tables))
          this.tables[name] = before[name]!;
        throw error;
      }
    };
    this.tables.deviceSession!.push({
      id: this.actor.sid,
      userId: this.actor.sub,
      expiresAt: new Date(Date.now() + 86400000),
    });
    this.tables.assistantSettings!.push({
      userId: this.actor.sub,
      enabled: true,
      profileId: randomUUID(),
      timeZone: 'Asia/Shanghai',
      revision: 0,
      memoryVersion: 0,
      memoryReadEnabled: true,
      memoryWriteEnabled: true,
    });
  }

  /// Prisma 仅在驱动边界进行类型适配。
  get prisma(): PrismaService {
    return this.database as unknown as PrismaService;
  }

  /// 固定比较器只实现测试用到的普通查询运算。
  private matches(row: Row, where: Row = {}): boolean {
    return Object.entries(where).every(([key, value]) => {
      if (key === 'OR')
        return (value as Row[]).some((part) => this.matches(row, part));
      if (key === 'AND')
        return (value as Row[]).every((part) => this.matches(row, part));
      if (key === 'userId_clientMessageId')
        return this.matches(row, value as Row);
      if (
        value &&
        typeof value === 'object' &&
        !(value instanceof Date) &&
        !Array.isArray(value)
      ) {
        // 对比表达式支持来源、版本及过期边界的真实 where。
        const expression = value as Row;
        // JSON path 是 Prisma JSONB 筛选的一部分，不在驱动中补授权逻辑。
        const jsonValue = Array.isArray(expression.path)
          ? expression.path.reduce<unknown>(
              (current, part: unknown) =>
                current &&
                typeof current === 'object' &&
                typeof part === 'string'
                  ? (current as Row)[part]
                  : undefined,
              row[key],
            )
          : row[key];
        if (
          'array_contains' in expression &&
          !jsonContains(jsonValue, expression.array_contains)
        )
          return false;
        if (
          'in' in expression &&
          !(expression.in as unknown[]).includes(row[key])
        )
          return false;
        if ('not' in expression && row[key] === expression.not) return false;
        if (
          'gt' in expression &&
          !((row[key] as number) > (expression.gt as number))
        )
          return false;
        if (
          'lt' in expression &&
          !((row[key] as number) < (expression.lt as number))
        )
          return false;
        return true;
      }
      return value instanceof Date
        ? Number(row[key]) === Number(value)
        : row[key] === value;
    });
  }

  /// 数据库原子更新只处理字段赋值和修订自增。
  private write(row: Row, data: Row): Row {
    for (const [key, value] of Object.entries(data)) {
      if (value === undefined) continue;
      if (value === Prisma.DbNull) row[key] = null;
      else if (value && typeof value === 'object' && 'increment' in value)
        row[key] = Number(row[key] ?? 0) + Number((value as Row).increment);
      else row[key] = value;
    }
    return row;
  }

  /// CRUD 驱动不决定任何业务状态，状态只能由 AssistantStore 改变。
  private model(name: string): Row {
    // 查询排序使用时间与身份，覆盖同毫秒游标。
    const find = (
      args: { where?: Row; orderBy?: Row | Row[]; take?: number } = {},
    ): Row[] => {
      // 数组复制防止读取时原地排序改变表内容。
      const rows = this.tables[name]!.filter((row) =>
        this.matches(row, args.where),
      );
      const ordering = args.orderBy
        ? Array.isArray(args.orderBy)
          ? args.orderBy
          : [args.orderBy]
        : [];
      rows.sort((left, right) => {
        for (const order of ordering)
          for (const [key, direction] of Object.entries(order)) {
            // 同一字段相等继续比较稳定身份。
            const a = left[key] as string | number,
              b = right[key] as string | number;
            if (a < b) return direction === 'desc' ? 1 : -1;
            if (a > b) return direction === 'desc' ? -1 : 1;
          }
        return 0;
      });
      return args.take ? rows.slice(0, args.take) : rows;
    };
    // 创建缺省模拟数据库默认值，不生成任何领域事实。
    const create = ({ data }: { data: Row }): Row => {
      const row = {
        id: randomUUID(),
        status: 'queued',
        planVersion: 0,
        planRequestId: null,
        plan: null,
        actionId: null,
        approvedHash: null,
        committed: false,
        excluded: false,
        createdAt: new Date(),
        updatedAt: new Date(),
        cards: [],
        ...data,
      };
      this.tables[name]!.push(row);
      return row;
    };
    return {
      findFirst: jest.fn((args: Row = {}) =>
        Promise.resolve(find(args)[0] ?? null),
      ),
      findUnique: jest.fn((args: Row) =>
        Promise.resolve(find(args)[0] ?? null),
      ),
      findUniqueOrThrow: jest.fn((args: Row) => {
        const row = find(args)[0];
        if (!row) throw new Error('测试记录缺失');
        return Promise.resolve(row);
      }),
      findMany: jest.fn((args: Row = {}) => Promise.resolve(find(args))),
      count: jest.fn((args: Row = {}) => Promise.resolve(find(args).length)),
      create: jest.fn((args: { data: Row }) => Promise.resolve(create(args))),
      update: jest.fn((args: { where: Row; data: Row }) => {
        const row = find(args)[0];
        if (!row) throw new Error('测试记录缺失');
        return Promise.resolve(this.write(row, args.data));
      }),
      updateMany: jest.fn((args: { where: Row; data: Row }) => {
        const rows = find(args);
        for (const row of rows) this.write(row, args.data);
        return Promise.resolve({ count: rows.length });
      }),
      deleteMany: jest.fn((args: { where: Row }) => {
        const rows = find(args);
        this.tables[name] = this.tables[name]!.filter(
          (row) => !rows.includes(row),
        );
        return Promise.resolve({ count: rows.length });
      }),
      upsert: jest.fn((args: { where: Row; create: Row; update: Row }) => {
        const row = find(args)[0];
        return Promise.resolve(
          row ? this.write(row, args.update) : create({ data: args.create }),
        );
      }),
    };
  }
}

describe('应用内助手持久任务与上下文授权', () => {
  // 每例均有独立 owner 及内存数据库。
  let database: StoreDatabase, store: AssistantStore, conversationId: string;
  // 测试只返回固定私有快照，不调用真实模型。
  const ai = {
    captureAssistantProfile: jest.fn(() =>
      Promise.resolve({
        profileId: randomUUID(),
        encryptedApiKey: 'test-ciphertext',
      }),
    ),
  };
  // 补偿能力来自目录，而不是模型输出。
  const actions = {
    catalog: {
      tools: [
        { name: 'create_quote', undoCreate: true },
        { name: 'delete_quote' },
      ],
    },
  };

  beforeEach(() => {
    jest.clearAllMocks();
    database = new StoreDatabase();
    store = new AssistantStore(
      database.prisma,
      ai as unknown as AiService,
      actions as unknown as ActionExecutor,
    );
    conversationId = randomUUID();
    database.tables.assistantConversation!.push({
      id: conversationId,
      userId: database.actor.sub,
      title: '测试会话',
      summary: '',
      createdAt: new Date(),
    });
  });

  /// 用真实发送路径创建首个任务，后续仅安排服务器已经观察到的状态。
  async function initial(
    content = '新增两个测试语录',
  ): Promise<{ id: string; taskId: string }> {
    return (await store.send(database.actor, conversationId, {
      clientMessageId: randomUUID(),
      content,
    })) as { id: string; taskId: string };
  }

  it('稳定消息身份覆盖正文和对象选择，重复请求返回同一个任务', async () => {
    // 客户端生成身份在网络重试中不变。
    const input = {
      clientMessageId: randomUUID(),
      content: '查询本周记录',
      timeZone: 'Asia/Shanghai',
    };
    const first = await store.send(database.actor, conversationId, input);
    expect(await store.send(database.actor, conversationId, input)).toEqual(
      first,
    );
    await expect(
      store.send(database.actor, conversationId, {
        ...input,
        content: '新增记录',
      }),
    ).rejects.toThrow('同一消息身份');
    await expect(
      store.send(database.actor, conversationId, {
        ...input,
        selection: { module: 'notes', id: randomUUID() },
      }),
    ).rejects.toThrow('同一消息身份');
    expect(database.tables.assistantTask).toHaveLength(1);
    expect(database.tables.assistantRun).toHaveLength(1);
    expect(JSON.stringify(first)).not.toContain('test-ciphertext');
    expect(await store.messages(database.actor, conversationId)).toMatchObject({
      items: [{ cards: [] }],
    });
  });

  it('等待澄清的选择在同任务新运行继续，丢弃未配对供应商调用', async () => {
    // 旧运行含未完成的 ask_user，不可直接拿去请求下轮模型。
    const first = await initial('修改我的学习记录');
    const task = database.tables.assistantTask![0]!,
      run = database.tables.assistantRun![0]!;
    const selected = { id: randomUUID(), module: 'time' };
    task.status = run.status = 'waitingInput';
    run.state = {
      ...(run.state as Row),
      input: [{ type: 'function_call', call_id: 'unpaired' }],
      calls: [{ name: 'ask_user' }],
      intents: [{ name: 'update_time_entry' }],
    };
    database.tables.assistantMessage!.push({
      id: randomUUID(),
      userId: database.actor.sub,
      taskId: task.id,
      conversationId,
      role: 'assistant',
      content: '选择哪条记录？',
      cards: [{ type: 'choice', choices: [selected] }],
      createdAt: new Date(Date.now() + 1),
    });
    // 仅允许点击当前任务给出的确切候选。
    await expect(
      store.send(database.actor, conversationId, {
        clientMessageId: randomUUID(),
        content: '这一条',
        selection: { ...selected, id: randomUUID() },
      }),
    ).rejects.toThrow('对象选项已失效');
    const next = (await store.send(database.actor, conversationId, {
      clientMessageId: randomUUID(),
      content: '选择第一条并改为复盘',
      selection: selected,
    })) as { id: string; taskId: string };
    expect(next.taskId).toBe(first.taskId);
    expect(next.id).not.toBe(first.id);
    expect(database.tables.assistantTask).toHaveLength(1);
    expect(
      database.tables.assistantRun!.find((item) => item.id === first.id)
        ?.status,
    ).toBe('cancelled');
    expect(
      database.tables.assistantRun!.find((item) => item.id === next.id)?.state,
    ).toMatchObject({
      input: [],
      intents: [],
      calls: [],
      selection: selected,
      request: expect.stringContaining('修改我的学习记录') as string,
    });
  });

  it('等待确认时修改取消旧动作，保留版本并清空旧批准与请求身份', async () => {
    const first = await initial();
    const task = database.tables.assistantTask![0]!,
      run = database.tables.assistantRun![0]!;
    const actionId = randomUUID();
    task.status = run.status = 'waitingConfirmation';
    Object.assign(task, {
      planVersion: 3,
      planRequestId: randomUUID(),
      actionId,
      approvedHash: 'old',
      plan: { previewHash: 'a'.repeat(64) },
    });
    database.tables.mcpAction!.push({
      id: actionId,
      source: 'assistant',
      sourceId: task.id,
      status: 'pending',
    });
    const next = (await store.send(database.actor, conversationId, {
      clientMessageId: randomUUID(),
      content: '第二条不要新增',
    })) as { id: string; taskId: string };
    expect(next.taskId).toBe(first.taskId);
    expect(database.tables.mcpAction![0]!.status).toBe('cancelled');
    expect(database.tables.assistantTask![0]).toMatchObject({
      planVersion: 3,
      plan: null,
      planRequestId: null,
      approvedHash: null,
      actionId: null,
      runId: next.id,
    });
    await expect(
      store.decision(database.actor, first.taskId, {
        version: 3,
        previewHash: 'a'.repeat(64),
        decision: 'confirm',
      }),
    ).rejects.toThrow('操作计划不存在');
    expect(database.tables.assistantRun![1]!.state).toMatchObject({
      request: expect.stringContaining('第二条不要新增') as string,
      input: [],
      intents: [],
      calls: [],
    });
  });

  it('运行中的第二次发送不能另建任务绕过确认', async () => {
    await initial();
    await expect(
      store.send(database.actor, conversationId, {
        clientMessageId: randomUUID(),
        content: '再加一条',
      }),
    ).rejects.toThrow('请先完成');
    expect(database.tables.assistantTask).toHaveLength(1);
    expect(database.tables.assistantRun).toHaveLength(1);
  });

  it('编辑引用仅接受同会话实际结果卡，任意 UUID 和不同引用重放被拒绝', async () => {
    // 服务器生成的结果卡提供真实对象引用，内容不会拼入用户可见文字。
    const reference = { id: randomUUID(), module: 'quotes' };
    database.tables.assistantMessage!.push({
      id: randomUUID(),
      conversationId,
      userId: database.actor.sub,
      role: 'assistant',
      content: '已保存',
      cards: [{ type: 'result', entityRefs: [reference] }],
      createdAt: new Date(),
    });
    await expect(
      store.send(database.actor, conversationId, {
        clientMessageId: randomUUID(),
        content: '编辑这条',
        reference: { ...reference, id: randomUUID() },
      }),
    ).rejects.toThrow('结果引用已失效');
    // 合法引用写入私有任务状态，与消息身份一起固定。
    const input = {
      clientMessageId: randomUUID(),
      content: '把这条语录改短一点',
      reference,
    };
    const result = await store.send(database.actor, conversationId, input);
    expect(database.tables.assistantRun![0]!.state).toMatchObject({
      reference,
    });
    expect(await store.send(database.actor, conversationId, input)).toEqual(
      result,
    );
    await expect(
      store.send(database.actor, conversationId, {
        ...input,
        reference: { ...reference, id: randomUUID() },
      }),
    ).rejects.toThrow('同一消息身份');
  });

  it('准备身份独立持久化，重启重试不把 requestId 当成 actionId', async () => {
    const first = await initial();
    const request = await store.reservePlanRequest(database.actor, first.id);
    expect(await store.reservePlanRequest(database.actor, first.id)).toBe(
      request,
    );
    expect(database.tables.assistantTask![0]).toMatchObject({
      planRequestId: request,
      actionId: null,
      planVersion: 0,
    });
    await store.stop(database.actor, first.id);
    await expect(
      store.reservePlanRequest(database.actor, first.id),
    ).rejects.toThrow('已停止或被接管');
  });

  it('预演准备身份已落库的失败恢复保留原计划输入，不重新猜测参数', async () => {
    // 准备前已持久化，可能在响应到达前崩溃。
    const first = await initial('新增一句话');
    const requestId = await store.reservePlanRequest(database.actor, first.id);
    // 模拟固定写计划与完成的供应商调用已保存，但动作 ID 尚未落库。
    Object.assign(database.tables.assistantTask![0]!, { status: 'failed' });
    Object.assign(database.tables.assistantRun![0]!, {
      status: 'failed',
      state: {
        ...(database.tables.assistantRun![0]!.state as Row),
        intents: [{ name: 'create_quote', input: { content: '固定文字' } }],
      },
    });
    const resumed = (await store.retry(database.actor, first.id)) as {
      id: string;
    };
    expect(database.tables.assistantTask![0]!.planRequestId).toBe(requestId);
    expect(
      database.tables.assistantRun!.find((run) => run.id === resumed.id)?.state,
    ).toMatchObject({
      intents: [{ name: 'create_quote', input: { content: '固定文字' } }],
    });
  });

  it('消息接口返回最新运行的终态，重开页面能恢复失败与停止状态', async () => {
    const first = await initial();
    database.tables.assistantRun![0]!.status = 'failed';
    database.tables.assistantTask![0]!.status = 'failed';
    expect(await store.messages(database.actor, conversationId)).toMatchObject({
      activeRun: { id: first.id, status: 'failed' },
    });
  });

  it('旧失败任务不能在同会话新任务活动时重试抢占', async () => {
    // 第一项失败后允许用户发起另一项工作。
    const first = await initial('原失败任务');
    database.tables.assistantRun![0]!.status = 'failed';
    database.tables.assistantTask![0]!.status = 'failed';
    await store.send(database.actor, conversationId, {
      clientMessageId: randomUUID(),
      content: '新的活动任务',
    });
    await expect(store.retry(database.actor, first.id)).rejects.toThrow(
      '已有其他活动任务',
    );
    expect(database.tables.assistantRun).toHaveLength(2);
  });

  it('人工记忆管理入口同样拒绝保存凭据且不回显内容', async () => {
    // 校验规则与上下文召回共用，不能只靠模型提示词约束。
    await expect(
      store.saveMemory(database.actor, {
        content: 'API Key: sk-test_secret_1234567890',
      }),
    ).rejects.toThrow('长期记忆不能保存');
    expect(database.tables.assistantMemory).toHaveLength(0);
  });

  it('重复确认只重放，不能清空运行器已经领取的租约', async () => {
    const first = await initial();
    const task = database.tables.assistantTask![0]!,
      run = database.tables.assistantRun![0]!;
    Object.assign(task, {
      status: 'queued',
      approvedHash: 'a'.repeat(64),
      planVersion: 1,
      plan: { previewHash: 'a'.repeat(64) },
    });
    Object.assign(run, {
      status: 'running',
      leaseOwner: 'live-worker',
      leaseUntil: new Date(Date.now() + 100000),
    });
    await store.decision(database.actor, first.taskId, {
      version: 1,
      previewHash: 'a'.repeat(64),
      decision: 'confirm',
    });
    expect(database.tables.assistantRun![0]).toMatchObject({
      status: 'running',
      leaseOwner: 'live-worker',
    });
  });

  it('删除记忆撤销未执行计划、来源和派生上下文，旧失败任务不能复活', async () => {
    const first = await initial('记住我喜欢简短回答');
    const source = database.tables.assistantMessage![0]!;
    const memoryId = randomUUID(),
      actionId = randomUUID();
    Object.assign(database.tables.assistantTask![0]!, {
      status: 'failed',
      approvedHash: 'old',
      actionId,
      plan: { previewHash: 'old' },
    });
    Object.assign(database.tables.assistantRun![0]!, { status: 'failed' });
    database.tables.assistantMemory!.push({
      id: memoryId,
      userId: database.actor.sub,
      sourceMessageId: source.id,
      revision: 0,
    });
    database.tables.assistantMessage!.push({
      id: randomUUID(),
      userId: database.actor.sub,
      role: 'assistant',
      excluded: false,
      content: '我会记住你喜欢简短回答',
    });
    database.tables.mcpAction!.push({
      id: actionId,
      source: 'assistant',
      sourceId: first.taskId,
      status: 'pending',
    });
    await store.deleteMemory(database.actor, memoryId);
    expect(database.tables.assistantSettings![0]!.memoryVersion).toBe(1);
    expect(database.tables.assistantTask![0]).toMatchObject({
      status: 'cancelled',
      approvedHash: null,
      actionId: null,
      plan: null,
    });
    expect(database.tables.assistantRun![0]!.state).toEqual({
      memoryInvalidated: true,
    });
    expect(database.tables.mcpAction![0]!.status).toBe('cancelled');
    expect(
      database.tables.assistantMessage!.every((message) => message.excluded),
    ).toBe(true);
    await expect(store.retry(database.actor, first.id)).rejects.toThrow(
      '上下文已失效',
    );
    expect(database.deletes).toHaveBeenCalledTimes(3);
  });

  it('停止之后的迟到记忆工具不能继续保存或保留旧运行', async () => {
    const first = await initial('记住我的偏好');
    const sourceId = database.tables.assistantMessage![0]!.id as string;
    await store.stop(database.actor, first.id);
    await expect(
      store.saveMemory(
        database.actor,
        { content: '喜欢清晰笔记' },
        undefined,
        sourceId,
        first.id,
      ),
    ).rejects.toThrow('已停止或被接管');
    expect(database.tables.assistantMemory).toHaveLength(0);
  });

  it('明确保存记忆仅保留同任务当前运行，其他在途上下文全部失效', async () => {
    const first = await initial('记住我偏好中文');
    Object.assign(database.tables.assistantTask![0]!, { status: 'running' });
    Object.assign(database.tables.assistantRun![0]!, { status: 'running' });
    const sourceId = database.tables.assistantMessage![0]!.id as string;
    await store.saveMemory(
      database.actor,
      { content: '偏好中文' },
      undefined,
      sourceId,
      first.id,
    );
    expect(database.tables.assistantMemory).toHaveLength(1);
    expect(database.tables.assistantTask![0]!.status).toBe('running');
    expect(
      (database.tables.assistantRun![0]!.state as Row).memoryInvalidated,
    ).toBeUndefined();
  });

  it('原单条新增十分钟内可补偿，重复点击仅创建一次补偿运行', async () => {
    const first = await initial('新增一句话');
    const task = database.tables.assistantTask![0]!,
      run = database.tables.assistantRun![0]!;
    const actionId = randomUUID();
    Object.assign(task, {
      status: 'succeeded',
      actionId,
      committed: true,
      planVersion: 2,
    });
    Object.assign(run, {
      status: 'succeeded',
      state: {
        ...(run.state as Row),
        actionId,
        result: { values: [{ id: randomUUID() }] },
      },
    });
    database.tables.mcpAction!.push({
      id: actionId,
      userId: database.actor.sub,
      source: 'assistant',
      sourceId: first.taskId,
      status: 'succeeded',
      updatedAt: new Date(),
      steps: [{ name: 'create_quote' }],
      result: { values: [] },
    });
    expect(await store.run(database.actor, first.id)).toMatchObject({
      canUndo: true,
    });
    const compensation = (await store.undo(database.actor, first.id)) as {
      id: string;
      taskId: string;
    };
    expect(compensation.taskId).toBe(first.taskId);
    expect(await store.undo(database.actor, first.id)).toEqual(compensation);
    expect(database.tables.assistantRun).toHaveLength(2);
    expect(database.tables.assistantTask![0]).toMatchObject({
      runId: compensation.id,
      planVersion: 2,
      committed: false,
      actionId: null,
      planRequestId: null,
      approvedHash: null,
      plan: null,
    });
    expect(database.tables.assistantRun![1]!.state).toMatchObject({
      undoOf: actionId,
      input: [],
      calls: [],
      intents: [],
    });
    expect(await store.run(database.actor, first.id)).toMatchObject({
      canUndo: false,
    });
  });

  it('同毫秒会话及记忆稳定分页，不截断后续记录或接受其他归属游标', async () => {
    // 固定同毫秒时间让第二排序键真实参与跨页。
    const updatedAt = new Date();
    database.tables.assistantConversation = Array.from({ length: 105 }, () => ({
      id: randomUUID(),
      userId: database.actor.sub,
      updatedAt,
    }));
    // 记忆管理页超过默认页数时必须能够继续读取。
    database.tables.assistantMemory = Array.from({ length: 205 }, () => ({
      id: randomUUID(),
      userId: database.actor.sub,
      updatedAt,
    }));
    const first = (await store.conversations(database.actor)) as {
      items: Array<{ id: string }>;
      nextCursor: string;
    };
    const second = (await store.conversations(
      database.actor,
      first.nextCursor,
    )) as { items: Array<{ id: string }>; nextCursor: string | null };
    expect(first.items).toHaveLength(100);
    expect(second.items).toHaveLength(5);
    expect(
      new Set([...first.items, ...second.items].map((item) => item.id)).size,
    ).toBe(105);
    expect(second.nextCursor).toBeNull();
    // 单页恰好达到上限也不能伪造下一页。
    const memoryFirst = (await store.memories(database.actor)) as {
      items: Array<{ id: string }>;
      nextCursor: string;
    };
    const memorySecond = (await store.memories(
      database.actor,
      memoryFirst.nextCursor,
    )) as { items: Array<{ id: string }>; nextCursor: string | null };
    expect(memoryFirst.items).toHaveLength(200);
    expect(memorySecond.items).toHaveLength(5);
    expect(
      new Set(
        [...memoryFirst.items, ...memorySecond.items].map((item) => item.id),
      ).size,
    ).toBe(205);
    expect(memorySecond.nextCursor).toBeNull();
    await expect(
      store.conversations(database.actor, randomUUID()),
    ).rejects.toThrow('游标不存在');
    await expect(store.memories(database.actor, randomUUID())).rejects.toThrow(
      '游标不存在',
    );
  });

  it('多批任务最后一批的单条新增不能冒充整个任务可撤销', async () => {
    // 最后一批成功动作本身可补偿，但整项任务需要按批次报告。
    const first = await initial('多批新增');
    const task = database.tables.assistantTask![0]!,
      run = database.tables.assistantRun![0]!;
    const actionId = randomUUID();
    Object.assign(task, {
      status: 'succeeded',
      actionId,
      committed: true,
      plan: { kind: 'batch' },
    });
    Object.assign(run, {
      status: 'succeeded',
      state: {
        ...(run.state as Row),
        actionId,
        result: { values: [], totalBatches: 2 },
      },
    });
    database.tables.mcpAction!.push({
      id: actionId,
      userId: database.actor.sub,
      source: 'assistant',
      sourceId: first.taskId,
      status: 'succeeded',
      updatedAt: new Date(),
      steps: [{ name: 'create_quote' }],
      result: { values: [] },
    });
    expect(await store.run(database.actor, first.id)).toMatchObject({
      canUndo: false,
    });
    // 即使当前任务计划被清空，原结果批次数也独立禁止通用撤销。
    task.plan = null;
    expect(await store.run(database.actor, first.id)).toMatchObject({
      canUndo: false,
    });
  });

  it('提交后 state 保存失败仍以真实回执合成稳定结果，读取不写业务或新增消息', async () => {
    // 模拟动作已保存但运行只剩最初状态，回答随后失败。
    const first = await initial('保存一条语录');
    const run = database.tables.assistantRun![0]!,
      task = database.tables.assistantTask![0]!;
    const messageId = (run.state as Row).messageId as string,
      actionId = randomUUID();
    Object.assign(run, { status: 'failed' });
    Object.assign(task, { status: 'failed', committed: true, actionId });
    database.tables.mcpAction!.push({
      id: actionId,
      userId: database.actor.sub,
      source: 'assistant',
      sourceId: first.taskId,
      status: 'succeeded',
      updatedAt: new Date(),
      result: {
        values: [{ id: randomUUID(), content: '实际保存' }],
        afterBaseline: 'private-hash',
      },
    });
    // 不调用原动作或模型，只投影已提交事实。
    const messagesBefore = database.tables.assistantMessage!.length;
    const recovered = (await store.messages(
      database.actor,
      conversationId,
    )) as { items: Array<{ id: string; role: string; cards: Array<Row> }> };
    expect(
      recovered.items.find((message) => message.id === messageId),
    ).toMatchObject({
      role: 'assistant',
      cards: [
        {
          type: 'result',
          result: { values: [{ content: '实际保存' }] },
          syncStatus: 'serverSaved',
        },
      ],
    });
    expect(JSON.stringify(recovered)).not.toContain('private-hash');
    expect(database.tables.assistantMessage).toHaveLength(messagesBefore);
    expect(
      (
        (await store.messages(database.actor, conversationId)) as {
          items: Array<{ id: string }>;
        }
      ).items.map((message) => message.id),
    ).toEqual(recovered.items.map((message) => message.id));
    expect(ai.captureAssistantProfile).toHaveBeenCalledTimes(1);
  });

  it('部分批次保存后停止仍显示已完成范围，恢复首屏不破坏持久消息分页', async () => {
    const first = await initial('分批保存');
    const run = database.tables.assistantRun![0]!;
    const messageId = (run.state as Row).messageId as string;
    Object.assign(run, {
      status: 'cancelled',
      state: {
        ...(run.state as Row),
        result: {
          values: [{ content: '首批已保存' }],
          partial: true,
          completedBatches: 1,
          totalBatches: 2,
          entityRefs: [{ id: randomUUID(), module: 'quotes' }],
        },
      },
    });
    Object.assign(database.tables.assistantTask![0]!, { status: 'cancelled' });
    // 一百零一条已保存消息，恢复副本插入后仍以真实消息身份翻页。
    database.tables.assistantMessage = Array.from(
      { length: 101 },
      (_, index) => ({
        id: randomUUID(),
        userId: database.actor.sub,
        conversationId,
        taskId: first.taskId,
        role: 'user',
        content: `消息${index}`,
        cards: [],
        createdAt: new Date(Date.now() - 10000 - index * 10),
      }),
    );
    const page = (await store.messages(database.actor, conversationId)) as {
      items: Array<{ id: string; content: string; cards: Array<Row> }>;
      nextCursor: string;
    };
    expect(page.items).toHaveLength(100);
    expect(
      page.items.find((message) => message.id === messageId),
    ).toMatchObject({
      content: expect.stringContaining('部分批次已保存') as string,
      cards: [
        { result: { completedBatches: 1, totalBatches: 2, partial: true } },
      ],
    });
    expect(page.nextCursor).not.toBe(messageId);
    const older = (await store.messages(
      database.actor,
      conversationId,
      page.nextCursor,
    )) as { items: Array<{ id: string }>; nextCursor: string | null };
    expect(older.items).toHaveLength(2);
    expect(
      new Set([...page.items, ...older.items].map((message) => message.id))
        .size,
    ).toBe(102);
    expect(older.nextCursor).toBeNull();
    expect(database.tables.assistantMessage).toHaveLength(101);
  });

  it('已有错误说明只补真实候选卡片，保留原聊天文字和错误卡片', async () => {
    await initial('修改笔记');
    const run = database.tables.assistantRun![0]!;
    const messageId = (run.state as Row).messageId as string;
    Object.assign(run, {
      status: 'failed',
      state: {
        ...(run.state as Row),
        conflict: true,
        result: { values: [{ status: 'conflict', candidateId: randomUUID() }] },
      },
    });
    database.tables.assistantMessage!.push({
      id: messageId,
      userId: database.actor.sub,
      conversationId,
      taskId: run.taskId,
      role: 'assistant',
      content: '模型回答中断，请稍后查看结果。',
      cards: [{ type: 'error', message: '回答超时' }],
      createdAt: new Date(),
    });
    const view = (await store.messages(database.actor, conversationId)) as {
      items: Array<{ id: string; content: string; cards: Array<Row> }>;
    };
    const message = view.items.find((item) => item.id === messageId)!;
    expect(message.content).toBe('模型回答中断，请稍后查看结果。');
    expect(message.cards).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ type: 'error', message: '回答超时' }) as Row,
        expect.objectContaining({
          type: 'conflict',
          message: expect.stringContaining('正式正文未采用') as string,
        }) as Row,
      ]),
    );
    expect(
      database.tables.assistantMessage!.find((item) => item.id === messageId)!
        .cards as Row[],
    ).toHaveLength(1);
  });

  it('遗忘和删除会话后不从旧动作回执复活聊天或授权', async () => {
    const first = await initial('保存后遗忘');
    const run = database.tables.assistantRun![0]!;
    Object.assign(run, {
      status: 'cancelled',
      state: {
        ...(run.state as Row),
        memoryInvalidated: true,
        result: { values: [{ content: '旧资料' }] },
      },
    });
    database.tables.mcpAction!.push({
      id: randomUUID(),
      userId: database.actor.sub,
      source: 'assistant',
      sourceId: first.taskId,
      status: 'succeeded',
      updatedAt: new Date(),
      result: { values: [{ content: '旧资料' }] },
    });
    const view = (await store.messages(database.actor, conversationId)) as {
      items: Array<{ role: string }>;
    };
    expect(view.items.some((message) => message.role === 'assistant')).toBe(
      false,
    );
    // 删除后即使底层仍保留审计回执，也必须先被会话归属检查拒绝。
    database.tables.assistantConversation = [];
    await expect(
      store.messages(database.actor, conversationId),
    ).rejects.toThrow('会话不存在');
    expect(database.tables.assistantMessage).toHaveLength(1);
    expect(database.tables.mcpAction).toHaveLength(1);
  });

  it.each(['取消', '不用了', '算了'])(
    '等待期间明确发送%s只取消原任务，不创建修订运行',
    async (content) => {
      const first = await initial('新增两个对象');
      Object.assign(database.tables.assistantTask![0]!, {
        status: 'waitingConfirmation',
      });
      Object.assign(database.tables.assistantRun![0]!, {
        status: 'waitingConfirmation',
      });
      database.tables.mcpAction!.push({
        id: randomUUID(),
        source: 'assistant',
        sourceId: first.taskId,
        status: 'pending',
      });
      // 取消不要求原模型配置仍然有效。
      database.tables.assistantSettings![0]!.profileId = null;
      const input = { clientMessageId: randomUUID(), content };
      expect(
        await store.send(database.actor, conversationId, input),
      ).toMatchObject({ id: first.id, status: 'cancelled' });
      expect(
        await store.send(database.actor, conversationId, input),
      ).toMatchObject({ id: first.id, status: 'cancelled' });
      expect(database.tables.assistantRun).toHaveLength(1);
      expect(database.tables.mcpAction![0]!.status).toBe('cancelled');
      expect(ai.captureAssistantProfile).toHaveBeenCalledTimes(1);
    },
  );

  it('本机运行隐藏接管，其他有效设备只收到布尔提示而不暴露会话身份', async () => {
    const first = await initial();
    // 同归属另一设备可以查看，是否接管必须是明确操作。
    const second: AuthUser = { ...database.actor, sid: randomUUID() };
    database.tables.deviceSession!.push({
      id: second.sid,
      userId: second.sub,
      expiresAt: new Date(Date.now() + 86400000),
    });
    expect(await store.run(database.actor, first.id)).toMatchObject({
      requiresTakeover: false,
    });
    expect(await store.run(second, first.id)).toMatchObject({
      requiresTakeover: true,
    });
    const view = await store.messages(second, conversationId);
    expect(view).toMatchObject({ activeRun: { requiresTakeover: true } });
    expect(JSON.stringify(view)).not.toContain(database.actor.sid);
  });

  it('停止、确认、重试和撤销在控制事务内立即追加可恢复状态事件', async () => {
    const first = await initial('等待确认');
    const task = database.tables.assistantTask![0]!,
      run = database.tables.assistantRun![0]!;
    Object.assign(task, {
      status: 'waitingConfirmation',
      planVersion: 1,
      plan: { previewHash: 'a'.repeat(64), content: '旧偏好资料' },
    });
    Object.assign(run, { status: 'waitingConfirmation' });
    await store.decision(database.actor, first.taskId, {
      version: 1,
      previewHash: 'a'.repeat(64),
      decision: 'confirm',
    });
    expect(database.tables.assistantEvent![0]).toMatchObject({
      runId: first.id,
      seq: 1,
      type: 'run.updated',
      data: { run: { status: 'queued' } },
    });
    await store.stop(database.actor, first.id);
    expect(database.tables.assistantEvent![1]).toMatchObject({
      runId: first.id,
      seq: 2,
      type: 'run.updated',
      data: { run: { status: 'cancelled', plan: null } },
    });
    expect(JSON.stringify(database.tables.assistantEvent![1])).not.toContain(
      '旧偏好资料',
    );
    // 另一个失败运行的显式重试，旧取消与新排队分别进入各自事件流。
    const second = (await store.send(database.actor, conversationId, {
      clientMessageId: randomUUID(),
      content: '第二项',
    })) as { id: string; taskId: string };
    Object.assign(
      database.tables.assistantTask!.find((row) => row.id === second.taskId)!,
      { status: 'failed' },
    );
    Object.assign(
      database.tables.assistantRun!.find((row) => row.id === second.id)!,
      { status: 'failed' },
    );
    const retry = (await store.retry(database.actor, second.id)) as {
      id: string;
    };
    expect(
      database.tables.assistantEvent!.find(
        (event) => event.runId === second.id,
      ),
    ).toMatchObject({ data: { run: { status: 'cancelled' } } });
    expect(
      database.tables.assistantEvent!.find((event) => event.runId === retry.id),
    ).toMatchObject({ data: { run: { status: 'queued' } } });
  });

  it('只读恢复卡的结果引用仍可作为明确新任务目标，遗忘状态不能提供裸 UUID 授权', async () => {
    const first = await initial('已保存');
    const reference = { id: randomUUID(), module: 'quotes' };
    Object.assign(database.tables.assistantTask![0]!, {
      status: 'failed',
      committed: true,
    });
    Object.assign(database.tables.assistantRun![0]!, {
      status: 'failed',
      state: {
        ...(database.tables.assistantRun![0]!.state as Row),
        result: { entityRefs: [reference], values: [] },
      },
    });
    // 结果尚未写入消息表，仍能从同会话后端持久回执引用核验。
    await expect(
      store.send(database.actor, conversationId, {
        clientMessageId: randomUUID(),
        content: '改短一点',
        reference: { ...reference, id: randomUUID() },
      }),
    ).rejects.toThrow('结果引用已失效');
    const next = (await store.send(database.actor, conversationId, {
      clientMessageId: randomUUID(),
      content: '改短一点',
      reference,
    })) as { id: string; taskId: string };
    expect(next.taskId).not.toBe(first.taskId);
    expect(
      database.tables.assistantRun!.find((row) => row.id === next.id)?.state,
    ).toMatchObject({ reference });
  });

  it('显式更新记忆替换来源，先排除旧来源，未来删除还会排除新来源', async () => {
    const first = await initial('记住原偏好');
    const oldSource = database.tables.assistantMessage![0]!.id as string,
      newSource = randomUUID(),
      memoryId = randomUUID();
    Object.assign(database.tables.assistantTask![0]!, { status: 'running' });
    Object.assign(database.tables.assistantRun![0]!, { status: 'running' });
    database.tables.assistantMessage!.push({
      id: newSource,
      userId: database.actor.sub,
      conversationId,
      taskId: first.taskId,
      role: 'user',
      content: '记住新偏好',
      excluded: false,
      cards: [],
      createdAt: new Date(),
    });
    database.tables.assistantMemory!.push({
      id: memoryId,
      userId: database.actor.sub,
      content: '原偏好',
      category: 'preference',
      revision: 0,
      sourceMessageId: oldSource,
    });
    await store.saveMemory(
      database.actor,
      { content: '新偏好', revision: 0 },
      memoryId,
      newSource,
      first.id,
    );
    expect(database.tables.assistantMemory![0]!.sourceMessageId).toBe(
      newSource,
    );
    expect(
      database.tables.assistantMessage!.find(
        (message) => message.id === oldSource,
      )!.excluded,
    ).toBe(true);
    expect(
      database.tables.assistantMessage!.find(
        (message) => message.id === newSource,
      )!.excluded,
    ).toBe(false);
    await store.deleteMemory(database.actor, memoryId);
    expect(
      database.tables.assistantMessage!.find(
        (message) => message.id === newSource,
      )!.excluded,
    ).toBe(true);
  });
});
