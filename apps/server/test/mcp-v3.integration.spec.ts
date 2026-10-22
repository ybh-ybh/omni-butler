import { Test, type TestingModule } from '@nestjs/testing';
import { ConfigModule, ConfigService } from '@nestjs/config';
import type { INestApplication } from '@nestjs/common';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Client as Database } from 'pg';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { PrismaService } from '../src/prisma/prisma.service';
import { McpModule } from '../src/mcp/mcp.module';
import { McpService } from '../src/mcp/mcp.service';
import type { AuthUser } from '../src/auth/auth.types';
import { mcpModules } from '../src/mcp/mcp-catalog';
import { TodoRecurrenceService } from '../src/business/todo-recurrence.service';

/// 新协议使用独立显式测试库，不读取开发或部署数据库配置。
const databaseUrl = process.env.OMNI_MCP_V3_TEST_DATABASE_URL;
/// 未提供隔离测试库时保留明确跳过状态。
const integration = databaseUrl ? describe : describe.skip;

integration('MCP v3 精简契约真实 SDK 与 PostgreSQL', () => {
  jest.setTimeout(60000);
  // 当前测试独占迁移数据库。
  let database: Database;
  // 确认空库并建立本测试模式后才能清理。
  let ownsSchema = false;
  // 真实 Nest 模块及 HTTP 应用。
  let module: TestingModule, app: INestApplication;
  // 真实数据库和连接管理服务。
  let prisma: PrismaService, mcp: McpService;
  // 每例的独立所有者，避免统计被其他测试污染。
  let actor: AuthUser;
  // 标准协议客户端使用随机端口。
  let client: Client, base: string;
  // 当前连接用于回执数量和身份边界检查。
  let connectionId: string;

  /// 通过真实 MCP HTTP 建立新的连接，可用于跨连接凭据拒绝测试。
  async function connect(): Promise<{ client: Client; connectionId: string }> {
    // 连接令牌只来自当前测试身份创建的配置。
    const created = await mcp.createConnection(actor, {
      name: 'MCP v3 独立验证',
      readModules: [...mcpModules],
      writeModules: [...mcpModules],
      timeZone: 'Asia/Shanghai',
    });
    // 客户端不直接调用业务服务来模拟协议结果。
    const connected = new Client({ name: 'mcp-v3-test', version: '1.0' });
    await connected.connect(
      new StreamableHTTPClientTransport(
        new URL(`${base}/omni-butler/api/v1/mcp`),
        {
          requestInit: {
            headers: { Authorization: `Bearer ${String(created.token)}` },
          },
        },
      ),
    );
    return {
      client: connected,
      connectionId: String((created.connection as { id: string }).id),
    };
  }

  /// 结构化错误转为拒绝，测试不得把失败回执当作业务成功。
  async function call(
    name: string,
    args: Record<string, unknown> = {},
    using: Client = client,
  ): Promise<Record<string, unknown>> {
    // SDK 校验标准 MCP 响应，服务器仍校验实际业务 Schema。
    const result = await using.callTool({ name, arguments: args });
    if (result.isError)
      throw new Error(
        JSON.stringify(result.structuredContent ?? result.content),
      );
    return result.structuredContent as Record<string, unknown>;
  }

  /// 对外直接写工具每个新操作生成唯一请求身份。
  function execute(
    name: string,
    args: Record<string, unknown>,
    using: Client = client,
  ): Promise<Record<string, unknown>> {
    return call(name, { requestId: randomUUID(), ...args }, using);
  }

  /// 从实际提交回执读取首个领域结果，不使用预演生成的临时身份。
  function valueOf(receipt: Record<string, unknown>): Record<string, unknown> {
    return (receipt.result as { values: Array<Record<string, unknown>> })
      .values[0]!;
  }

  /// 笔记领域结果额外包装正式笔记，其他模块直接返回实体。
  function recordOf(receipt: Record<string, unknown>): Record<string, unknown> {
    // 兼容的是实际模块回执形状，不修改业务输入契约。
    const value = valueOf(receipt);
    return (value.note ?? value) as Record<string, unknown>;
  }

  /// 只读详情统一取控制器 data 包装。
  async function read(
    name: string,
    args: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    return (await call(name, args)).data as Record<string, unknown>;
  }

  /// 模拟客户端已同步的大步骤结构，不绕过 MCP 的批量写入限制来创建。
  async function seedProgressSteps(count: number): Promise<string> {
    // fixture 只属于当前测试 owner，真实读取和编辑仍使用标准 SDK。
    const id = randomUUID();
    await prisma.todoItem.create({
      data: {
        id,
        userId: actor.sub,
        title: '大步骤结构',
        taskType: 'progress',
        scheduledDate: new Date('2026-10-01T00:00:00Z'),
      },
    });
    await prisma.todoProgressStep.createMany({
      data: Array.from({ length: count }, (_, index) => ({
        id: randomUUID(),
        userId: actor.sub,
        todoId: id,
        name: `${'长'.repeat(196)}${String(index).padStart(4, '0')}`,
        sortOrder: (index + 1) * 1024,
      })),
    });
    return id;
  }

  beforeAll(async () => {
    // 严格限制本机显式 *_test 库，绝不清理现有用户模式。
    const url = new URL(databaseUrl!);
    if (
      url.hostname !== '127.0.0.1' ||
      !/^\/[A-Za-z0-9_]+_test$/.test(url.pathname)
    )
      throw new Error('v3 集成只接受本机显式 test 数据库');
    database = new Database({ connectionString: databaseUrl });
    await database.connect();
    // 连接后再次确认数据库身份。
    const actual = await database.query<{ name: string }>(
      'SELECT current_database() AS name',
    );
    if (`/${actual.rows[0]?.name}` !== url.pathname)
      throw new Error('实际数据库与请求目标不符');
    // 空模式是执行测试迁移的必要条件。
    const tables = await database.query(
      "SELECT tablename FROM pg_tables WHERE schemaname='public'",
    );
    if (tables.rows.length)
      throw new Error('v3 集成要求空 schema，不删除已有表');
    ownsSchema = true;
    await database.query('CREATE SCHEMA IF NOT EXISTS public');
    for (const migration of readdirSync(
      join(__dirname, '../prisma/migrations'),
      { withFileTypes: true },
    )
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort())
      await database.query(
        readFileSync(
          join(__dirname, '../prisma/migrations', migration, 'migration.sql'),
          'utf8',
        ),
      );
    // 密钥只存在测试内存，不读取真实持久卷。
    const keys = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    // 独立签名上下文供真实编辑凭据生成与验证。
    const config = {
      DATABASE_URL: databaseUrl,
      SYNC_SECRET: 'mcp-v3-isolated-secret',
      JWT_PRIVATE_KEY_BASE64: Buffer.from(keys.privateKey).toString('base64'),
      JWT_PUBLIC_KEY_BASE64: Buffer.from(keys.publicKey).toString('base64'),
      JWT_KEY_ID: 'mcp-v3-test',
      JWT_ISSUER: 'omni-butler',
      JWT_AUDIENCE: 'omni-butler-api',
      REFRESH_TOKEN_TTL_SECONDS: 86400,
    };
    prisma = new PrismaService(new ConfigService(config));
    await prisma.$connect();
    module = await Test.createTestingModule({
      imports: [
        ConfigModule.forRoot({
          isGlobal: true,
          ignoreEnvFile: true,
          load: [(): typeof config => config],
        }),
        McpModule,
      ],
    })
      .overrideProvider(PrismaService)
      .useValue(prisma)
      .overrideProvider(TodoRecurrenceService)
      .useValue({})
      .compile();
    mcp = module.get(McpService);
    app = module.createNestApplication();
    app.setGlobalPrefix('omni-butler/api/v1');
    await app.listen(0, '127.0.0.1');
    base = await app.getUrl();
  });

  beforeEach(async () => {
    actor = { sub: randomUUID(), sid: randomUUID(), typ: 'access' };
    await prisma.syncOwner.create({ data: { id: actor.sub } });
    await prisma.deviceSession.create({
      data: {
        id: actor.sid,
        userId: actor.sub,
        tokenHash: 'isolated-device',
        expiresAt: new Date('2099-01-01T00:00:00Z'),
      },
    });
    // 每例使用全新连接，权限和幂等回执不会继承。
    const connected = await connect();
    client = connected.client;
    connectionId = connected.connectionId;
  });

  afterEach(async () => {
    await client?.close();
    if (prisma && actor)
      await prisma.syncOwner.deleteMany({ where: { id: actor.sub } });
  });

  afterAll(async () => {
    await app?.close();
    await prisma?.$disconnect();
    if (database) {
      if (ownsSchema) await database.query('DROP SCHEMA public CASCADE');
      await database.end();
    }
  });

  it('直接新增、修改、删除、统一恢复返回真实结果，相同请求重放且改参拒绝', async () => {
    // 并发重试模拟响应丢失，同一请求只能留下一个物品。
    const requestId = randomUUID();
    // 参数原样复用，不能在失败后生成第二个业务身份。
    const args = { requestId, name: '测试耳机', purchasePriceCents: 12000 };
    // 两条真实 HTTP 请求同时提交。
    const [created, replay] = await Promise.all([
      call('create_item', args),
      call('create_item', args),
    ]);
    expect(created.status).toBe('succeeded');
    expect(replay.id).toBe(created.id);
    expect(replay.result).toEqual(created.result);
    expect(
      await prisma.inventoryItem.count({ where: { userId: actor.sub } }),
    ).toBe(1);
    expect(
      await prisma.mcpAction.count({ where: { connectionId, requestId } }),
    ).toBe(1);
    await expect(
      call('create_item', { ...args, name: '不同参数' }),
    ).rejects.toThrow();
    // 只用实际回执正式身份进行后续修改。
    const id = String(recordOf(created).id);
    // 修改和软删除也必须能够重放已经提交的真实回执。
    const updateArgs = { id, name: '降噪耳机', requestId: randomUUID() };
    const updated = await call('update_item', updateArgs);
    expect(updated.status).toBe('succeeded');
    expect((await call('update_item', updateArgs)).result).toEqual(
      updated.result,
    );
    expect((await read('get_item', { id })).name).toBe('降噪耳机');
    const deleteArgs = { id, requestId: randomUUID() };
    const deleted = await call('delete_item', deleteArgs);
    expect(deleted.status).toBe('succeeded');
    expect((await call('delete_item', deleteArgs)).result).toEqual(
      deleted.result,
    );
    // 统一回收站必须返回同一个软删除记录。
    const recycle = await read('list_recycle_bin', { module: 'inventory' });
    expect(recycle.items).toEqual(
      expect.arrayContaining([expect.objectContaining({ id })]),
    );
    // 恢复支持原请求重放且保留修改后的数据。
    const restoreId = randomUUID();
    const restored = await call('restore_record', {
      module: 'inventory',
      id,
      requestId: restoreId,
    });
    expect(restored.status).toBe('succeeded');
    expect(
      (
        await call('restore_record', {
          module: 'inventory',
          id,
          requestId: restoreId,
        })
      ).result,
    ).toEqual(restored.result);
    expect((await read('get_item', { id })).name).toBe('降噪耳机');
  });

  it('追加笔记直接保存，原 requestId 重试及并发提交只追加一次', async () => {
    // 新建正文由正式回执取得身份。
    const note = recordOf(await execute('create_note', { body: '原文' }));
    // 编辑凭据来自实际详情读取。
    const detail = await read('get_note', { id: note.id });
    // 两个并发请求复用同一凭据、请求身份和追加内容。
    const args = {
      id: note.id,
      text: '追加内容',
      editToken: detail.editToken,
      requestId: randomUUID(),
    };
    const [first, second] = await Promise.all([
      call('append_note', args),
      call('append_note', args),
    ]);
    expect(first.status).toBe('succeeded');
    expect(second.result).toEqual(first.result);
    expect((await read('get_note', { id: note.id })).body).toBe(
      '原文\n\n追加内容',
    );
    expect(
      await prisma.noteVersion.count({
        where: { userId: actor.sub, noteId: String(note.id) },
      }),
    ).toBe(2);
  });

  it.each([
    ['2026-10-01T00:15:19+05:30', '2026-10-01', 919, 330],
    ['2026-10-01T23:45:19-07:00', '2026-10-01', 85519, -420],
  ] as const)(
    'recordedAt %s 保留输入日历、钟点和偏移',
    async (recordedAt, dayKey, recordTimeSeconds, recordUtcOffsetMinutes) => {
      // 输入偏移与连接默认时区故意不同。
      const note = recordOf(
        await execute('create_note', { body: '跨时区笔记', recordedAt }),
      );
      expect(note).toMatchObject({
        dayKey,
        recordTimeSeconds,
        recordUtcOffsetMinutes,
      });
      // 编辑正文但省略记录时间时，必须完整保留原偏移。
      const detail = await read('get_note', { id: note.id });
      await execute('update_note', {
        id: note.id,
        editToken: detail.editToken,
        body: '更新正文',
      });
      expect(await read('get_note', { id: note.id })).toMatchObject({
        dayKey,
        recordTimeSeconds,
        recordUtcOffsetMinutes,
      });
      // 显式修改记录时间同样按输入墙钟保存，不转换成连接时区。
      const current = await read('get_note', { id: note.id });
      await execute('update_note', {
        id: note.id,
        editToken: current.editToken,
        recordedAt: '2026-10-03T01:02:03-03:30',
      });
      expect(await read('get_note', { id: note.id })).toMatchObject({
        body: '更新正文',
        dayKey: '2026-10-03',
        recordTimeSeconds: 3723,
        recordUtcOffsetMinutes: -210,
      });
      await expect(
        execute('update_note', {
          id: note.id,
          editToken: detail.editToken,
          dayKey: '2026-10-03',
        }),
      ).rejects.toThrow();
    },
  );

  it('单一计费周期支持永久和周期双向转换，转永久时清除旧到期日', async () => {
    // 首购仍通过真实领域动作，不能因合并参数产生两笔付款。
    const member = recordOf(
      await execute('create_membership', {
        name: '阅读会员',
        purchaseDate: '2026-10-01',
        billingCycle: 'permanent',
        priceCents: 9900,
      }),
    );
    expect(member).toMatchObject({
      billingCycle: 'permanent',
      isPermanent: true,
      expirationDate: null,
    });
    expect(
      recordOf(
        await execute('update_membership', {
          id: member.id,
          billingCycle: 'month',
          expirationDate: '2026-11-01',
        }),
      ),
    ).toMatchObject({
      billingCycle: 'month',
      isPermanent: false,
      expirationDate: '2026-11-01T00:00:00.000Z',
    });
    expect(
      recordOf(
        await execute('update_membership', {
          id: member.id,
          billingCycle: 'permanent',
        }),
      ),
    ).toMatchObject({
      billingCycle: 'permanent',
      isPermanent: true,
      expirationDate: null,
    });
    await expect(
      execute('update_membership', { id: member.id, billingCycle: 'month' }),
    ).rejects.toThrow();
    await expect(
      execute('update_membership', { id: member.id, isPermanent: false }),
    ).rejects.toThrow();
    await expect(
      execute('update_membership', {
        id: member.id,
        timeZone: 'Asia/Shanghai',
      }),
    ).rejects.toThrow();
    expect(
      await prisma.membershipPayment.count({ where: { userId: actor.sub } }),
    ).toBe(1);
  });

  it('旧正文 editToken 形成可查询冲突候选，正式正文不被覆盖', async () => {
    // 两次编辑都持有同一次读取的原基线。
    const note = recordOf(await execute('create_note', { body: '第一版' }));
    const detail = await read('get_note', { id: note.id });
    await execute('update_note', {
      id: note.id,
      body: '已保存第二版',
      editToken: detail.editToken,
    });
    // 旧版本修改不能自动刷新凭据后覆盖第二版。
    const conflict = await execute('update_note', {
      id: note.id,
      body: '旧视角候选',
      editToken: detail.editToken,
    });
    expect(conflict.status).toBe('conflict');
    expect(valueOf(conflict).candidateRevision).toEqual(expect.any(String));
    expect((await read('get_note', { id: note.id })).body).toBe('已保存第二版');
    expect(
      await prisma.noteVersion.findFirst({
        where: {
          userId: actor.sub,
          revision: String(valueOf(conflict).candidateRevision),
        },
      }),
    ).toMatchObject({ body: '旧视角候选', baseRevision: detail.revision });
    expect(
      (await call('get_action_status', { actionId: conflict.id })).result,
    ).toEqual(conflict.result);
  });

  it('旧标签 editToken 只撤回已读标签，保留并发新增', async () => {
    // 两个有效标签由本测试创建，业务写入仍走 SDK。
    const tags = await Promise.all(
      ['旧标签', '并发标签'].map((name) =>
        prisma.taxonomyEntry.create({
          data: {
            id: randomUUID(),
            userId: actor.sub,
            module: 'notes',
            kind: 'tag',
            name,
          },
        }),
      ),
    );
    const note = recordOf(
      await execute('create_note', { body: '正文', tags: [tags[0]!.id] }),
    );
    const detail = await read('get_note', { id: note.id });
    await execute('update_note', {
      id: note.id,
      editToken: detail.editToken,
      tags: tags.map((tag) => tag.id),
    });
    await execute('update_note', {
      id: note.id,
      editToken: detail.editToken,
      tags: [],
    });
    expect(
      JSON.parse(String((await read('get_note', { id: note.id })).tags)),
    ).toEqual([tags[1]!.id]);
  });

  it('编辑凭据拒绝跨记录、跨连接及跨业务类型使用', async () => {
    // 两篇同 owner 笔记仍具有不同凭据作用域。
    const first = recordOf(await execute('create_note', { body: '第一篇' }));
    const second = recordOf(await execute('create_note', { body: '第二篇' }));
    const detail = await read('get_note', { id: first.id });
    await expect(
      execute('update_note', {
        id: second.id,
        body: '越界',
        editToken: detail.editToken,
      }),
    ).rejects.toThrow();
    // 另一条相同 owner 的全权限连接也不能挪用读取凭据。
    const other = await connect();
    try {
      await expect(
        execute(
          'update_note',
          { id: first.id, body: '跨连接', editToken: detail.editToken },
          other.client,
        ),
      ).rejects.toThrow();
    } finally {
      await other.client.close();
    }
    const todo = recordOf(
      await execute('create_todo', {
        title: '步骤',
        taskType: 'progress',
        scheduledDate: '2026-10-01',
        steps: [{ name: '第一步' }],
      }),
    );
    await expect(
      execute('replace_todo_steps', {
        todoId: todo.id,
        steps: [{ name: '替换' }],
        editToken: detail.editToken,
      }),
    ).rejects.toThrow();
    expect((await read('get_note', { id: first.id })).body).toBe('第一篇');
  });

  it('步骤凭据按 sortOrder/createdAt/id 排序，保留读取后完成事实并拒绝结构冲突', async () => {
    // 多个相同 sortOrder 模拟不同客户端合并后的合法结构。
    const todo = recordOf(
      await execute('create_todo', {
        title: '进度',
        taskType: 'progress',
        scheduledDate: '2026-10-01',
        steps: [{ name: 'A' }, { name: 'B' }],
      }),
    );
    const stored = await prisma.todoProgressStep.findMany({
      where: { userId: actor.sub, todoId: String(todo.id) },
      orderBy: { id: 'asc' },
    });
    await prisma.todoProgressStep.update({
      where: { id: stored[0]!.id },
      data: { sortOrder: 1024, createdAt: new Date('2026-10-01T02:00:00Z') },
    });
    await prisma.todoProgressStep.update({
      where: { id: stored[1]!.id },
      data: { sortOrder: 1024, createdAt: new Date('2026-10-01T01:00:00Z') },
    });
    const detail = await read('get_todo', { id: todo.id });
    const steps = detail.progressSteps as Array<{
      id: string;
      name: string | null;
    }>;
    expect(steps.map((step) => step.id)).toEqual([
      stored[1]!.id,
      stored[0]!.id,
    ]);
    await execute('set_todo_steps', {
      todoId: todo.id,
      stepIds: [steps[0]!.id],
      completed: true,
    });
    expect(
      (
        await execute('replace_todo_steps', {
          todoId: todo.id,
          editToken: detail.editToken,
          steps: steps.map((step) => ({
            id: step.id,
            name: `${step.name}修改`,
          })),
        })
      ).status,
    ).toBe('succeeded');
    expect(
      await prisma.todoProgressStep.findUnique({ where: { id: steps[0]!.id } }),
    ).toMatchObject({ isCompleted: true });
    await expect(
      execute('replace_todo_steps', {
        todoId: todo.id,
        editToken: detail.editToken,
        steps: [{ name: '旧结构覆盖' }],
      }),
    ).rejects.toThrow();
    expect(
      await prisma.todoProgressStep.count({
        where: { userId: actor.sub, todoId: String(todo.id), deletedAt: null },
      }),
    ).toBe(2);
    await expect(
      execute('update_todo', { id: todo.id, taskType: 'normal' }),
    ).rejects.toThrow();
  });

  it('一千个两百字步骤仍返回有界凭据，不把全部结构塞入凭据', async () => {
    // 正文很长的历史结构也应可以读取，不能因凭据大小拒绝详情。
    const id = await seedProgressSteps(1000);
    const detail = await read('get_todo', { id });
    expect(detail.progressSteps).toHaveLength(1000);
    expect(typeof detail.editToken).toBe('string');
    expect(String(detail.editToken).length).toBeLessThan(2000);
    // 凭据仅保留结构摘要，步骤名称仍在明确的详情字段中。
    const payload = Buffer.from(
      String(detail.editToken).split('.')[0]!,
      'base64url',
    ).toString('utf8');
    expect(payload).not.toContain('长长长');
  });

  it('较大步骤结构可安全减少，未改变的步骤不产生无意义更新', async () => {
    // 一百二十项长名称保持请求和真实变化均在既有上限内。
    const id = await seedProgressSteps(120);
    const detail = await read('get_todo', { id });
    const before = await prisma.todoProgressStep.findMany({
      where: { userId: actor.sub, todoId: id },
      orderBy: { sortOrder: 'asc' },
    });
    // 仅删除末项，保留部分的名称和顺序完全不变。
    const retained = before
      .slice(0, -1)
      .map((step) => ({ id: step.id, name: step.name }));
    const result = await execute('replace_todo_steps', {
      todoId: id,
      editToken: detail.editToken,
      steps: retained,
    });
    expect(result.status).toBe('succeeded');
    expect(
      await prisma.todoProgressStep.count({
        where: { userId: actor.sub, todoId: id, deletedAt: null },
      }),
    ).toBe(119);
    expect(
      await prisma.todoProgressStep.findUnique({
        where: { id: before[0]!.id },
      }),
    ).toMatchObject({ updatedAt: before[0]!.updatedAt });
    await expect(
      execute('replace_todo_steps', {
        todoId: id,
        editToken: detail.editToken,
        steps: retained,
      }),
    ).rejects.toThrow();
  });

  it.each([
    [
      'quotes',
      'create_quote',
      'delete_quote',
      'get_quote',
      { content: '恢复名言' },
    ],
    [
      'time',
      'create_time_entry',
      'delete_time_entry',
      'get_time_entry',
      {
        activity: '恢复记录',
        startedAt: '2026-10-01T20:00:00+08:00',
        endedAt: '2026-10-01T21:00:00+08:00',
      },
    ],
    [
      'todos',
      'create_todo',
      'delete_todo',
      'get_todo',
      { title: '恢复待办', scheduledDate: '2026-10-01' },
    ],
    [
      'inventory',
      'create_item',
      'delete_item',
      'get_item',
      { name: '恢复物品' },
    ],
    [
      'memberships',
      'create_membership',
      'delete_membership',
      'get_membership',
      {
        name: '恢复会员',
        purchaseDate: '2026-10-01',
        billingCycle: 'permanent',
      },
    ],
    [
      'events',
      'create_event',
      'delete_event',
      'get_event',
      { name: '恢复事务' },
    ],
    ['notes', 'create_note', 'delete_note', 'get_note', { body: '恢复笔记' }],
  ] as const)(
    '%s 使用统一回收站和恢复入口准确路由',
    async (target, create, remove, get, args) => {
      // 每个模块各自生成真实正式身份，不混用同一UUID探测自由表。
      const record = recordOf(await execute(create, args));
      const id = String(record.id);
      await execute(remove, { id });
      expect(
        (await read('list_recycle_bin', { module: target })).items,
      ).toEqual(expect.arrayContaining([expect.objectContaining({ id })]));
      expect(
        (await execute('restore_record', { module: target, id })).status,
      ).toBe('succeeded');
      expect(await read(get, { id })).toMatchObject({ id, deletedAt: null });
    },
  );

  it('统一统计覆盖七模块，review 的前期比较使用对应完整口径', async () => {
    // 只保存有明确历史日期的业务事实，统计不会依赖客户端分页。
    await execute('create_time_entry', {
      activity: '复习',
      startedAt: '2026-10-01T20:00:00+08:00',
      endedAt: '2026-10-01T21:00:00+08:00',
    });
    await execute('create_note', {
      body: '统计笔记',
      recordedAt: '2026-10-01T20:00:00+08:00',
    });
    await execute('create_item', {
      name: '书',
      purchaseDate: '2026-10-01',
      purchasePriceCents: 1000,
    });
    await execute('create_membership', {
      name: '学习会员',
      purchaseDate: '2026-10-01',
      billingCycle: 'permanent',
      priceCents: 2000,
    });
    await execute('create_todo', {
      title: '复习任务',
      scheduledDate: '2026-10-01',
    });
    await execute('create_event', {
      name: '运动',
      initialCompletedAt: '2026-10-01T19:00:00+08:00',
    });
    await execute('create_quote', { content: '学习记录' });
    const range = {
      from: '2026-10-01T00:00:00+08:00',
      to: '2026-10-02T00:00:00+08:00',
    };
    // 七种模块都通过同一个公开入口读取真实业务统计。
    for (const target of mcpModules)
      expect(
        await read('get_statistics', { module: target, ...range }),
      ).toMatchObject({ complete: true });
    const review = await call('get_review_context', {
      period: 'custom',
      ...range,
      asOf: '2026-10-02T00:00:00+08:00',
      modules: [...mcpModules],
      comparePrevious: true,
    });
    expect(Object.keys(review.summaries as object).sort()).toEqual(
      [...mcpModules].sort(),
    );
    expect(Object.keys(review.comparison as object).sort()).toEqual(
      [...mcpModules].sort(),
    );
    expect((review.comparison as Record<string, unknown>).time).toMatchObject({
      values: {
        totalSeconds: {
          current: 3600,
          previous: 0,
          difference: 3600,
          percentChange: null,
        },
      },
    });
    expect((review.summaries as Record<string, unknown>).notes).toMatchObject({
      count: 1,
    });
    expect(review.references).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ module: 'time', tool: 'get_statistics' }),
      ]),
    );
  });

  it('库存无窗口保持全量和配件选项，不适用 asOf 或跨模块选项明确拒绝', async () => {
    // 无购买日的现有物品也必须进入全量统计。
    const root = recordOf(
      await execute('create_item', { name: '电脑', purchasePriceCents: 10000 }),
    );
    await execute('create_item', {
      name: '配件',
      parentItemId: root.id,
      purchasePriceCents: 500,
    });
    expect(await read('get_statistics', { module: 'inventory' })).toMatchObject(
      { count: 1, purchasePriceCents: 10000 },
    );
    expect(
      await read('get_statistics', {
        module: 'inventory',
        includeAccessories: true,
      }),
    ).toMatchObject({ count: 2, purchasePriceCents: 10500 });
    for (const target of ['quotes', 'notes', 'inventory'])
      await expect(
        call('get_statistics', {
          module: target,
          from: '2026-10-01T00:00:00Z',
          to: '2026-10-02T00:00:00Z',
          asOf: '2026-10-02T00:00:00Z',
        }),
      ).rejects.toThrow();
    await expect(
      call('get_statistics', {
        module: 'time',
        from: '2026-10-01T00:00:00Z',
        to: '2026-10-02T00:00:00Z',
        includeAccessories: true,
      }),
    ).rejects.toThrow();
  });

  it('时间状态筛选不要求窗口，拒绝已移除的无效时间参数', async () => {
    await execute('start_time_entry', {
      activity: '跨日未结束',
      startedAt: '2026-09-01T00:00:00+08:00',
    });
    expect(
      (await read('list_time_entries', { status: 'ongoing' })).items,
    ).toHaveLength(1);
    expect(
      (await read('list_time_entries', { status: 'finished' })).items,
    ).toHaveLength(0);
    await expect(
      call('list_time_entries', {
        status: 'ongoing',
        timeZone: 'Asia/Shanghai',
      }),
    ).rejects.toThrow();
    await expect(
      call('list_time_entries', {
        status: 'ongoing',
        asOf: '2026-10-02T00:00:00Z',
      }),
    ).rejects.toThrow();
  });

  it('隐藏旧工具既不发布也不能直接或经 prepare_batch 偷渡', async () => {
    // 目录检查不够，还需实际发起工具调用证明服务端拒绝。
    const names = (await client.listTools()).tools.map((tool) => tool.name);
    const hidden = [
      'prepare_create_item',
      'get_note_summary',
      'get_inventory_summary',
      'list_ongoing_time_entries',
      'list_notes_recycle_bin',
      'restore_notes',
      'materialize_repeated_todos',
    ];
    for (const name of hidden) {
      expect(names).not.toContain(name);
      await expect(call(name, {})).rejects.toThrow();
      await expect(
        call('prepare_batch', {
          requestId: randomUUID(),
          actions: [{ tool: name, arguments: {} }],
        }),
      ).rejects.toThrow();
    }
    expect(await prisma.mcpAction.count({ where: { connectionId } })).toBe(0);
    expect(await prisma.todoItem.count({ where: { userId: actor.sub } })).toBe(
      0,
    );
  });
});
