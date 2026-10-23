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
