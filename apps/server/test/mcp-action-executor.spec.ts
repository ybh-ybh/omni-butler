import { ConfigService } from '@nestjs/config';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import { BusinessRecycleService } from '../src/business/business-recycle.service';
import { EventsService } from '../src/business/events.service';
import { InventoryService } from '../src/business/inventory.service';
import { MembershipsService } from '../src/business/memberships.service';
import { NotesBusinessService } from '../src/business/notes-business.service';
import { QuotesService } from '../src/business/quotes.service';
import { TimeEntriesService } from '../src/business/time-entries.service';
import { TodosService } from '../src/business/todos.service';
import { ActionExecutor } from '../src/mcp/action-executor';
import type { AssistantActionContext } from '../src/mcp/action-context';
import type { Prisma } from '../src/generated/prisma/client';
import { McpCatalog } from '../src/mcp/mcp-catalog';
import { McpEditTokenService } from '../src/mcp/mcp-edit-token.service';
import { PrismaService } from '../src/prisma/prisma.service';
import { withinBusinessTransaction } from '../src/business/business-access';

describe('共享动作来源身份与助手函数目录', () => {
  // 目录验证不连接真实数据库，也不调用模型或业务服务。
  let executor: ActionExecutor;
  // 模拟的持久层仅返回测试身份，不创建 MCP 连接。
  const store = {
    deviceSession: { findFirst: jest.fn() },
    mcpConnection: { findUnique: jest.fn() },
  };
  // 助手任务范围由后端运行器构造。
  const context: AssistantActionContext = {
    source: 'assistant',
    taskId: randomUUID(),
    runId: randomUUID(),
    actor: { sub: randomUUID(), sid: randomUUID(), typ: 'access' },
    timeZone: 'Asia/Shanghai',
  };

  beforeAll(async () => {
    // 使用真实目录与共享执行器，业务方法未被调用时不产生副作用。
    const module = await Test.createTestingModule({
      providers: [
        ActionExecutor,
        McpCatalog,
        McpEditTokenService,
        { provide: PrismaService, useValue: store },
        { provide: ConfigService, useValue: new ConfigService({}) },
        ...[
          QuotesService,
          TimeEntriesService,
          TodosService,
          InventoryService,
          MembershipsService,
          EventsService,
          NotesBusinessService,
          BusinessRecycleService,
        ].map((provide) => ({ provide, useValue: {} })),
      ],
    }).compile();
    executor = module.get(ActionExecutor);
  });

  beforeEach(() => {
    jest.clearAllMocks();
    store.deviceSession.findFirst.mockResolvedValue({
      id: context.actor.sid,
      expiresAt: new Date(Date.now() + 86400000),
    });
  });

  it('七模块函数目录去除执行控制工具及模型幂等参数', async () => {
    // 名称与 schema 从真实公开目录派生，不能复制为另一份工具实现。
    const tools = await executor.listTools(context);
    expect(tools).toHaveLength(59);
    expect(
      tools.find((tool) => tool.name === 'get_review_context'),
    ).toBeDefined();
    expect(tools.find((tool) => tool.name === 'restore_record')).toBeDefined();
    expect(tools.find((tool) => tool.name === 'create_todo')?.inputSchema.required).toEqual(['title']);
    expect(
      tools.some((tool) =>
        [
          'commit_action',
          'prepare_batch',
          'undo_action',
          'cancel_action',
          'get_action_status',
          'get_capabilities',
        ].includes(tool.name),
      ),
    ).toBe(false);
    for (const tool of tools) {
      expect(tool.name).toBeTruthy();
      expect(tool.description).toBeTruthy();
      expect(tool.inputSchema).toMatchObject({
        type: 'object',
        additionalProperties: false,
      });
      expect(tool.inputSchema.properties).not.toHaveProperty('requestId');
      expect(tool.inputSchema.properties).not.toHaveProperty('owner');
    }
    expect(store.mcpConnection.findUnique).not.toHaveBeenCalled();
    expect(store.deviceSession.findFirst).toHaveBeenCalledWith({
      where: {
        id: context.actor.sid,
        userId: context.actor.sub,
        expiresAt: { gt: expect.any(Date) as Date },
      },
    });
  });

  it('设备会话失效拒绝助手读取及准备，不降级为 MCP 身份', async () => {
    store.deviceSession.findFirst.mockResolvedValue(null);
    await expect(executor.listTools(context)).rejects.toThrow('设备会话已失效');
    await expect(executor.read(context, 'list_quotes', {})).rejects.toThrow(
      '设备会话已失效',
    );
    await expect(
      executor.prepare(context, randomUUID(), [
        { name: 'create_quote', input: { content: '不应写入' } },
      ]),
    ).rejects.toThrow('设备会话已失效');
    expect(store.mcpConnection.findUnique).not.toHaveBeenCalled();
  });

  it.each([
    ['Asia/Shanghai', '2026-10-25'],
    ['America/Los_Angeles', '2026-10-24'],
  ])('仅名称新增按业务时区%s固定默认值，跨日重放仍使用%s', async (timeZone, day) => {
    // 直接覆盖真实输入冻结阶段，不模拟工具Schema或默认值实现。
    const scope = { ...(await executor.scope(context)), timeZone };
    // 新增无需数据库读取，错误访问事务将直接使测试失败。
    const transaction = {} as Prisma.TransactionClient;
    // 同一时刻在上海已是次日，在洛杉矶仍是当天。
    const prepared = await executor['fixedSteps'](transaction, scope, [
      { name: 'create_todo', input: { title: '完成个人网站开发' } },
    ], new Date('2026-10-24T18:00:00Z'));
    expect(prepared).toEqual([{ name: 'create_todo', input: {
      title: '完成个人网站开发', scheduledDate: day, taskType: 'normal', priorityQuadrant: 2,
    } }]);
    // 固定后的动作即使跨日再次进入处理也不能被新默认覆盖。
    expect(await executor['fixedSteps'](transaction, scope, prepared, new Date('2026-10-27T18:00:00Z'))).toEqual(prepared);
  });

  it('MCP未配置时区时不猜设备日期，允许显式时区或日期', async () => {
    // 保留已有MCP时区边界，无配置不能静默使用UTC或宿主本地时区。
    const scope = { ...(await executor.scope(context)), timeZone: null };
    // 冻结默认值不需访问数据库。
    const transaction = {} as Prisma.TransactionClient;
    // 上海次日与UTC当日的边界时刻。
    const now = new Date('2026-10-24T18:00:00Z');
    await expect(executor['fixedSteps'](transaction, scope, [
      { name: 'create_todo', input: { title: '网站' } },
    ], now)).rejects.toThrow('需要有效业务时区');
    expect(await executor['fixedSteps'](transaction, scope, [
      { name: 'create_todo', input: { title: '网站', timeZone: 'Asia/Shanghai' } },
    ], now)).toEqual([{ name: 'create_todo', input: {
      title: '网站', scheduledDate: '2026-10-25', taskType: 'normal', priorityQuadrant: 2,
    } }]);
    expect(await executor['fixedSteps'](transaction, scope, [
      { name: 'create_todo', input: { title: '网站', scheduledDate: '2026-11-01' } },
    ], now)).toEqual([{ name: 'create_todo', input: {
      title: '网站', scheduledDate: '2026-11-01', taskType: 'normal', priorityQuadrant: 2,
    } }]);
  });

  it('明确日期、进度类型及象限0优先，更新不补新增默认值', async () => {
    // 合法助手范围使用任务固定时区。
    const scope = await executor.scope(context);
    // 固定输入无需数据库查询。
    const transaction = {} as Prisma.TransactionClient;
    // 用户明确指定的合法值不能被缺省逻辑覆盖。
    const input = { title: '阅读', scheduledDate: '2026-11-01', taskType: 'progress', priorityQuadrant: 0, steps: [{ name: '第一章' }] };
    // 编辑只包含明确修改项。
    const update = { name: 'update_todo', input: { id: randomUUID(), title: '新标题' } };
    expect(await executor['fixedSteps'](transaction, scope, [
      { name: 'create_todo', input }, update,
    ], new Date('2026-10-24T18:00:00Z'))).toEqual([
      { name: 'create_todo', input },
      { ...update, input: { ...update.input, timeZone: context.timeZone } },
    ]);
  });

  it.each([
    {}, { title: '' }, { title: '   ' }, { title: '任务', scheduledDate: null },
    { title: '任务', scheduledDate: '不确定' }, { title: '任务', taskType: null },
    { title: '任务', priorityQuadrant: 4 }, { title: '任务', owner: '伪造归属' },
  ])('默认规则不掩盖缺失名称、非法参数或越权字段：%j', async (input) => {
    // 严格校验在服务端补默认值之前运行。
    const scope = await executor.scope(context);
    await expect(executor['fixedSteps']({} as Prisma.TransactionClient, scope, [
      { name: 'create_todo', input },
    ], new Date('2026-10-24T18:00:00Z'))).rejects.toThrow();
  });

  it('助手即使有设备身份也不能跳过服务端提交门禁', async () => {
    await expect(executor.commit(context, randomUUID())).rejects.toThrow(
      '助手提交缺少服务端执行门禁',
    );
    expect(store.mcpConnection.findUnique).not.toHaveBeenCalled();
  });

  it('同 owner 嵌套事务只获取一次锁，但每次复验设备会话', async () => {
    // 驱动仅验证事务复用和授权次数，业务数据库集成另行执行。
    const transaction = {
      deviceSession: { findFirst: jest.fn().mockResolvedValue({}) },
      $queryRaw: jest.fn().mockResolvedValue([{ id: context.actor.sub }]),
    };
    // 模拟事务入口，回调始终收到同一个事务身份。
    const start = jest.fn((callback: (value: unknown) => Promise<unknown>) =>
      callback(transaction),
    );
    const prisma = { $transaction: start } as unknown as PrismaService;
    await withinBusinessTransaction(prisma, context.actor, async (outer) => {
      // 同设备正常嵌套调用必须继续通过持久身份校验。
      await withinBusinessTransaction(prisma, context.actor, (inner) => {
        expect(inner).toBe(outer);
        return Promise.resolve(undefined);
      });
      // 同 owner 伪造 sid 也不能借用已授权外层事务。
      transaction.deviceSession.findFirst.mockResolvedValueOnce(null);
      await expect(
        withinBusinessTransaction(
          prisma,
          { ...context.actor, sid: randomUUID() },
          () => Promise.resolve(undefined),
        ),
      ).rejects.toThrow('设备会话已失效');
    });
    expect(start).toHaveBeenCalledTimes(1);
    expect(transaction.$queryRaw).toHaveBeenCalledTimes(1);
    expect(transaction.deviceSession.findFirst).toHaveBeenCalledTimes(3);
  });
});
