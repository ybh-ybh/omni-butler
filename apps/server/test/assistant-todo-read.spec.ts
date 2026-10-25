import { BadRequestException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../src/auth/auth.types';
import {
  assistantTodoOutput,
  assistantTodoOutputBytes,
} from '../src/assistant/assistant-todo-output';
import { TodosService } from '../src/business/todos.service';
import type { Prisma } from '../src/generated/prisma/client';
import { ActionExecutor } from '../src/mcp/action-executor';
import type { AssistantActionContext } from '../src/mcp/action-context';
import { McpCatalog } from '../src/mcp/mcp-catalog';
import type { McpEditTokenService } from '../src/mcp/mcp-edit-token.service';
import type { PrismaService } from '../src/prisma/prisma.service';

/// 使用真实业务校验和目录，只替换事务存储，不接触用户数据库。
describe('助手待办列表摘要与共享象限筛选', () => {
  // 每例独立身份，跨用户样本不能通过 owner 条件进入结果。
  const actor: AuthUser = {
    sub: randomUUID(),
    sid: randomUUID(),
    typ: 'access',
  };
  // 完整领域样本包含足以压垮旧列表的长正文和一千个步骤。
  const seed = {
    id: randomUUID(),
    userId: actor.sub,
    title: '重要且紧急的项目',
    taskType: 'progress',
    priorityQuadrant: 3,
    scheduledDate: new Date('2026-10-24T00:00:00Z'),
    dueAt: null,
    isCompleted: false,
    parentId: null,
    deletedAt: null,
    description: '私有长描述'.repeat(20000),
    createdAt: new Date('2026-10-23T00:00:00Z'),
    progressSteps: Array.from({ length: 1000 }, (_, index) => ({
      id: randomUUID(),
      name: `完整步骤正文 ${index}`,
      isCompleted: index < 250,
      deletedAt: null,
    })),
  };
  // 当前测试模拟的领域记录。
  let rows: Array<typeof seed>;
  // Prisma 查询参数保留真实 where/select/skip/take，便于检查调用形状。
  const transaction = {
    deviceSession: { findFirst: jest.fn() },
    todoItem: { findMany: jest.fn() },
    todoProgressStep: { groupBy: jest.fn() },
  };
  // 真实 businessRead 仍执行会话授权和只读事务。
  const store = {
    ...transaction,
    mcpConnection: { findUnique: jest.fn() },
    $transaction: jest.fn(
      (read: (value: typeof transaction) => Promise<unknown>) =>
        read(transaction),
    ),
  };
  // 测试中仅将存储接口适配为现有 Prisma 服务。
  const todos = new TodosService(store as unknown as PrismaService);
  // 目录构造不调用未使用的领域服务。
  const services = [
    {},
    {},
    todos,
    {},
    {},
    {},
    {},
    {},
  ] as unknown as ConstructorParameters<typeof McpCatalog>;
  // 授权和 schema 必须来自真实共享目录。
  const catalog = new McpCatalog(...services);
  // 编辑令牌不参与列表读取，不需要签名密钥。
  const executor = new ActionExecutor(
    store as unknown as PrismaService,
    catalog,
    {} as McpEditTokenService,
  );
  // 助手来源由服务端构造，不由工具参数传入。
  const context: AssistantActionContext = {
    source: 'assistant',
    actor,
    taskId: randomUUID(),
    runId: randomUUID(),
    timeZone: 'Asia/Shanghai',
  };

  beforeEach(() => {
    jest.clearAllMocks();
    rows = [{ ...seed }];
    transaction.deviceSession.findFirst.mockResolvedValue({
      id: actor.sid,
      expiresAt: new Date(Date.now() + 60000),
    });
    transaction.todoItem.findMany.mockImplementation(
      (input: {
        where: {
          userId: string;
          deletedAt: null;
          priorityQuadrant?: number;
          isCompleted?: boolean;
        };
        select?: Record<string, boolean>;
        skip: number;
        take: number;
      }) => {
        // 模拟数据库先筛选再分页，验证业务调用未在取页后过滤。
        const selected = rows
          .filter(
            (row) =>
              row.userId === input.where.userId &&
              row.deletedAt === input.where.deletedAt &&
              (input.where.priorityQuadrant === undefined ||
                row.priorityQuadrant === input.where.priorityQuadrant) &&
              (input.where.isCompleted === undefined ||
                row.isCompleted === input.where.isCompleted),
          )
          .slice(input.skip, input.skip + input.take);
        return Promise.resolve(
          input.select
            ? selected.map((row) =>
                Object.fromEntries(
                  Object.keys(input.select!).map((key) => [
                    key,
                    row[key as keyof typeof row],
                  ]),
                ),
              )
            : selected,
        );
      },
    );
    transaction.todoProgressStep.groupBy.mockImplementation(
      (input: {
        where: { userId: string; todoId: { in: string[] }; deletedAt: null };
      }) =>
        Promise.resolve(
          rows
            .filter(
              (row) =>
                row.userId === input.where.userId &&
                input.where.todoId.in.includes(row.id),
            )
            .flatMap((row) =>
              [true, false].map((isCompleted) => ({
                todoId: row.id,
                isCompleted,
                _count: {
                  _all: row.progressSteps.filter(
                    (step) =>
                      step.deletedAt === null &&
                      step.isCompleted === isCompleted,
                  ).length,
                },
              })),
            ),
        ),
    );
  });

  it('一千步骤和长描述只返回计数，完整 UTF-8 JSON 不超过 16KiB', async () => {
    // 从真实助手来源进入，共享授权不能被摘要分支绕过。
    const result = await executor.read(context, 'list_todos', {
      priorityQuadrant: 3,
      completed: false,
    });
    expect(result).toMatchObject({
      items: [
        {
          id: seed.id,
          title: seed.title,
          priorityQuadrant: 3,
          progress: { total: 1000, completed: 250 },
        },
      ],
      hasMore: false,
      nextOffset: null,
      stepsSummarized: true,
      truncated: false,
      returnedCount: 1,
    });
    expect(Buffer.byteLength(JSON.stringify(result))).toBeLessThanOrEqual(
      assistantTodoOutputBytes,
    );
    expect(JSON.stringify(result)).not.toMatch(
      /description|progressSteps|userId|createdAt/,
    );
    expect(transaction.todoItem.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          userId: actor.sub,
          priorityQuadrant: 3,
          isCompleted: false,
          deletedAt: null,
        }),
        select: expect.objectContaining({ id: true, title: true }),
      }),
    );
    expect(transaction.todoItem.findMany).not.toHaveBeenCalledWith(
      expect.objectContaining({ include: expect.anything() }),
    );
    expect(transaction.todoProgressStep.groupBy).toHaveBeenCalledWith(
      expect.objectContaining({
        where: {
          userId: actor.sub,
          todoId: { in: [seed.id] },
          deletedAt: null,
        },
      }),
    );
  });

  it('旧 MCP 请求返回完整记录和步骤，不启用助手投影', async () => {
    // 专用连接继续使用同一领域服务的默认完整返回。
    const connectionId = randomUUID();
    store.mcpConnection.findUnique.mockResolvedValue({
      id: connectionId,
      userId: actor.sub,
      sessionId: actor.sid,
      readModules: ['todos'],
      writeModules: [],
      timeZone: 'Asia/Shanghai',
      expiresAt: null,
      revokedAt: null,
    });
    // 完整结果仍保留既有步正文与描述，新增参数省略时不限制象限。
    const result = (await executor.read(
      connectionId,
      'list_todos',
      {},
    )) as Prisma.JsonObject;
    expect((result.items as Prisma.JsonObject[])[0]).toMatchObject({
      description: seed.description,
      progressSteps: expect.any(Array),
    });
    expect((result.items as Prisma.JsonObject[])[0]!.progressSteps).toHaveLength(
      1000,
    );
    expect(result).not.toHaveProperty('stepsSummarized');
    expect(transaction.todoProgressStep.groupBy).not.toHaveBeenCalled();
  });

  it('象限零值有效，筛选发生在分页前且排除其他归属和软删项', async () => {
    rows = [
      { ...seed, id: randomUUID(), priorityQuadrant: 2 },
      { ...seed, id: randomUUID(), priorityQuadrant: 0 },
      { ...seed, id: randomUUID(), priorityQuadrant: 0, userId: randomUUID() },
      {
        ...seed,
        id: randomUUID(),
        priorityQuadrant: 0,
        deletedAt: new Date(),
      } as unknown as typeof seed,
      { ...seed, id: randomUUID(), priorityQuadrant: 0 },
    ];
    // 偏移是筛选后的第二条，不能先截取原始页再过滤。
    const result = (await todos.list(
      actor,
      { priorityQuadrant: 0, offset: 1, limit: 1 },
      true,
    )) as Prisma.JsonObject;
    expect((result.items as Prisma.JsonObject[]).map((row) => row.id)).toEqual([
      rows[4]!.id,
    ]);
    expect(result.hasMore).toBe(false);
    expect(transaction.todoItem.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({ priorityQuadrant: 0 }),
        skip: 1,
        take: 2,
      }),
    );
  });

  it.each([-1, 4, 1.5, '3', null])(
    '目录和领域都拒绝非法象限 %s',
    (priorityQuadrant) => {
      // 即使绕过目录直接调用业务服务，边界仍相同。
      const tool = catalog.tools.find((entry) => entry.name === 'list_todos')!;
      expect(tool.schema.safeParse({ priorityQuadrant }).success).toBe(false);
      expect(() => todos.list(actor, { priorityQuadrant })).toThrow(
        BadRequestException,
      );
      expect(transaction.todoItem.findMany).not.toHaveBeenCalled();
    },
  );

  it('中文长标题缩页后沿实际 nextOffset 继续，分页不漏项或重复', async () => {
    rows = Array.from({ length: 80 }, (_, index) => ({
      ...seed,
      id: randomUUID(),
      title: `${index}`.padStart(3, '0') + '中文长标题'.repeat(39),
      progressSteps: [],
    }));
    // 逐页读取到服务端明确的结束位置，而非原请求页长。
    const collected: string[] = [];
    // 初始页没有模型自定缩页，字节限制由服务端执行。
    let offset: number | null = 0;
    while (offset !== null) {
      // 每一页仍按业务校验与授权查询。
      const result = (await executor.read(
        context,
        'list_todos',
        { limit: 200, offset },
      )) as Prisma.JsonObject;
      // 完整 JSON 元数据也属于预算。
      const items = result.items as Prisma.JsonObject[];
      expect(items.length).toBeGreaterThan(0);
      expect(Buffer.byteLength(JSON.stringify(result))).toBeLessThanOrEqual(
        assistantTodoOutputBytes,
      );
      collected.push(...items.map((item) => item.id as string));
      if (result.hasMore) expect(result.nextOffset).toBe(offset + items.length);
      offset = result.nextOffset as number | null;
    }
    expect(collected).toEqual(rows.map((row) => row.id));
    expect(transaction.todoItem.findMany.mock.calls.length).toBeGreaterThan(1);
  });

  it('真实空页明确返回零项且不查询步骤，没有伪造后续页', async () => {
    rows = [];
    await expect(
      executor.read(context, 'list_todos', { priorityQuadrant: 3 }),
    ).resolves.toMatchObject({
      items: [],
      hasMore: false,
      nextOffset: null,
      returnedCount: 0,
      truncated: false,
    });
    expect(transaction.todoProgressStep.groupBy).not.toHaveBeenCalled();
  });

  it('设备会话撤销后不读取摘要或计数', async () => {
    transaction.deviceSession.findFirst.mockResolvedValue(null);
    await expect(executor.read(context, 'list_todos', {})).rejects.toThrow(
      '设备会话已失效',
    );
    expect(transaction.todoItem.findMany).not.toHaveBeenCalled();
    expect(transaction.todoProgressStep.groupBy).not.toHaveBeenCalled();
  });

  it('纯投影裁掉旧结果全文，跳过已软删步骤，元数据占用同一预算', () => {
    // 旧结果仍可归一化为与新数据库路径一致的摘要。
    const result = assistantTodoOutput(
      {
        items: [
          {
            ...seed,
            progressSteps: [
              ...seed.progressSteps,
              { id: randomUUID(), deletedAt: new Date(), isCompleted: true },
            ],
          },
        ],
        hasMore: true,
      },
      { offset: 23 },
    ) as Prisma.JsonObject;
    expect(result).toMatchObject({
      items: [{ progress: { total: 1000, completed: 250 } }],
      nextOffset: 24,
      truncated: false,
    });
    expect(JSON.stringify(result)).not.toMatch(
      /description|progressSteps|userId/,
    );
  });

  it('单条超预算和非列表错误不会变成空成功', () => {
    expect(() =>
      assistantTodoOutput({
        items: [{ ...seed, title: '中文'.repeat(20000) }],
        hasMore: false,
      }),
    ).toThrow('单条待办摘要超过读取预算');
    expect(() => assistantTodoOutput({ error: '未交付有效结果' })).toThrow(
      '待办列表结果无效',
    );
  });
});
