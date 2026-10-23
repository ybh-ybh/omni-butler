import { ConfigService } from '@nestjs/config';
import { Test, type TestingModule } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';
import { BusinessModule } from '../src/business/business.module';
import { addDays, localParts } from '../src/business/business-input';
import { TodoRecurrenceService } from '../src/business/todo-recurrence.service';
import { TodosService } from '../src/business/todos.service';
import type { McpConnection, TodoItem } from '../src/generated/prisma/client';
import { PrismaService } from '../src/prisma/prisma.service';
import { stableBusinessId } from '../src/sync/sync-consistency';

/// 只能显式使用独立测试库，不读取开发或部署环境的 DATABASE_URL。
const databaseUrl = process.env.OMNI_TODO_RECURRENCE_TEST_DATABASE_URL;
/// 缺少隔离库时明确跳过，不伪造数据库验证。
const integration = databaseUrl ? describe : describe.skip;

integration('重复待办后台任务真实数据库行为', () => {
  jest.setTimeout(60000);
  // 数据库只在确认空模式并建立本测试数据后才允许清理。
  let ownsSchema = false;
  // 原生连接执行全量迁移和最终清理。
  let database: Client;
  // 实际业务数据库，不使用伪造事务。
  let prisma: PrismaService;
  // Nest 注册检查使用真实 BusinessModule。
  let module: TestingModule;
  // 复用真实重复日历和稳定身份生成。
  let todos: TodosService;
  // 每例使用独立工作器，验证重启恢复时可再构造一份。
  let worker: TodoRecurrenceService;
  // 当前测试专用归属。
  let userId: string;
  // 当前测试显式写连接。
  let connection: McpConnection;
  // 今日以明确连接时区取得，不依赖主机时区。
  let today: string;

  /// 创建有效且独立的 MCP 连接和内部会话。
  async function addConnection(
    timeZone: string | null = 'Asia/Shanghai',
  ): Promise<McpConnection> {
    // 每条连接有单独会话，撤销其中一条不冒用另一条。
    const sessionId = randomUUID();
    await prisma.deviceSession.create({
      data: {
        id: sessionId,
        userId,
        tokenHash: '0'.repeat(64),
        expiresAt: new Date('2099-01-01T00:00:00Z'),
      },
    });
    return prisma.mcpConnection.create({
      data: {
        id: randomUUID(),
        userId,
        sessionId,
        name: '隔离测试',
        tokenHash: randomUUID().replaceAll('-', '').repeat(2),
        readModules: ['todos'],
        writeModules: ['todos'],
        timeZone,
      },
    });
  }

  /// 只建立本测试自己的种子任务，生成逻辑必须由实际工作器完成。
  async function seed(
    daysBeforeToday: number,
    overrides: Partial<TodoItem> = {},
  ): Promise<TodoItem> {
    return prisma.todoItem.create({
      data: {
        id: randomUUID(),
        userId,
        title: '每日练习',
        scheduledDate: new Date(
          `${addDays(today, -daysBeforeToday)}T00:00:00Z`,
        ),
        repeatRule: 'daily',
        repeatSeriesId: randomUUID(),
        ...overrides,
      },
    });
  }

  beforeAll(async () => {
    // 不允许非本机或非测试名数据库，现有表一律拒绝。
    const url = new URL(databaseUrl!);
    if (
      url.hostname !== '127.0.0.1' ||
      !/^\/[A-Za-z0-9_]+_test$/.test(url.pathname)
    )
      throw new Error('重复任务集成只接受本机显式 test 数据库');
    database = new Client({ connectionString: databaseUrl });
    await database.connect();
    // 数据库名称仍需服务端确认，避免连接被重定向。
    const actual = await database.query<{ name: string }>(
      'SELECT current_database() AS name',
    );
    if (`/${actual.rows[0]?.name}` !== url.pathname)
      throw new Error('测试数据库身份不一致');
    // 测试绝不先清理已有数据。
    const tables = await database.query(
      "SELECT tablename FROM pg_tables WHERE schemaname='public'",
    );
    if (tables.rows.length) throw new Error('重复任务集成要求空 schema');
    if (
      (
        await database.query(
          "SELECT 1 FROM pg_namespace WHERE nspname='assistant_graph'",
        )
      ).rows.length
    )
      throw new Error('重复任务集成要求不存在助手私有 schema');
    ownsSchema = true;
    await database.query('CREATE SCHEMA IF NOT EXISTS public');
    for (const migration of readdirSync(
      join(__dirname, '../prisma/migrations'),
      { withFileTypes: true },
    )
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort()) {
      await database.query(
        readFileSync(
          join(__dirname, '../prisma/migrations', migration, 'migration.sql'),
          'utf8',
        ),
      );
    }
    prisma = new PrismaService(
      new ConfigService({ DATABASE_URL: databaseUrl }),
    );
    await prisma.$connect();
    module = await Test.createTestingModule({ imports: [BusinessModule] })
      .overrideProvider(PrismaService)
      .useValue(prisma)
      .compile();
    todos = module.get(TodosService);
    expect(module.get(TodoRecurrenceService)).toBeInstanceOf(
      TodoRecurrenceService,
    );
  });

  beforeEach(async () => {
    userId = randomUUID();
    today = localParts(new Date(), 'Asia/Shanghai').day;
    await prisma.syncOwner.create({ data: { id: userId } });
    connection = await addConnection();
    worker = new TodoRecurrenceService(prisma, todos);
  });

  afterEach(async () => {
    await worker?.onModuleDestroy();
    if (prisma && userId)
      await prisma.syncOwner.deleteMany({ where: { id: userId } });
  });

  afterAll(async () => {
    if (module) await module.close();
    else if (prisma) await prisma.$disconnect();
    if (database) {
      if (ownsSchema)
        await database.query(
          'DROP SCHEMA IF EXISTS assistant_graph CASCADE; DROP SCHEMA public CASCADE; CREATE SCHEMA public;',
        );
      await database.end();
    }
  });

  it('启动钩子主动生成，未执行任何列表或 MCP 查询', async () => {
    await seed(1);
    worker.onModuleInit();
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(2);
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'idle', timeZone: 'Asia/Shanghai' });
  });

  it('长历史每轮最多推进七天，重启与并发扫描持续补齐且不重复', async () => {
    // 三周历史需要至少三轮，不能在一个事务里无限追溯。
    const root = await seed(20);
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(7);
    expect(
      await prisma.todoRecurrenceCursor.findUnique({
        where: { userId_seriesId: { userId, seriesId: root.repeatSeriesId! } },
      }),
    ).toMatchObject({ nextDay: new Date(`${addDays(today, -13)}T00:00:00Z`) });
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'catching_up' });
    await worker.onModuleDestroy();
    worker = new TodoRecurrenceService(prisma, todos);
    // 另一进程式实例共享真实 owner 锁与持久断点。
    const concurrent = new TodoRecurrenceService(prisma, todos);
    await Promise.all([worker.runOnce(), concurrent.runOnce()]);
    await concurrent.onModuleDestroy();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(21);
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(21);
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'idle' });
  });

  it('同日新增系列从自身起始日补齐，不被之前已完成的扫描跳过', async () => {
    await seed(1);
    await worker.runOnce();
    // 第一轮完成后才到达服务器的新系列。
    const later = await seed(3);
    await worker.runOnce();
    expect(
      await prisma.todoItem.count({
        where: { userId, repeatSeriesId: later.repeatSeriesId },
      }),
    ).toBe(4);
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(6);
  });

  it('每轮至多处理四个系列，后续轮次发现未取得预算的系列', async () => {
    // 五个系列各三周，第一轮只能推进其中四个。
    for (let index = 0; index < 5; index++) await seed(20);
    await worker.runOnce();
    expect(await prisma.todoRecurrenceCursor.count({ where: { userId } })).toBe(
      4,
    );
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(29);
    await worker.runOnce();
    expect(await prisma.todoRecurrenceCursor.count({ where: { userId } })).toBe(
      5,
    );
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'catching_up' });
  });

  it('同锚点从每周改为每天会重新检查此前跳过的日期', async () => {
    // 先把本周已扫描完但当天不发生的系列推进到明天。
    const root = await seed(2, { repeatRule: 'weekly' });
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(1);
    const before = await prisma.todoRecurrenceCursor.findUniqueOrThrow({
      where: { userId_seriesId: { userId, seriesId: root.repeatSeriesId! } },
    });
    expect(before.nextDay).toEqual(new Date(`${addDays(today, 1)}T00:00:00Z`));
    // 原始日期不变，只有实际重复规则发生变化。
    await todos.update(
      { sub: userId, sid: connection.sessionId, typ: 'access' },
      {
        operationId: randomUUID(),
        id: root.id,
        repeatRule: 'daily',
        scope: 'future',
      },
    );
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(3);
    const after = await prisma.todoRecurrenceCursor.findUniqueOrThrow({
      where: { userId_seriesId: { userId, seriesId: root.repeatSeriesId! } },
    });
    expect(after.scheduleSignature).not.toBe(before.scheduleSignature);
    // 自动生成的同规则实例不再改变签名或重置已追平的断点。
    await worker.runOnce();
    expect(
      await prisma.todoRecurrenceCursor.findUniqueOrThrow({
        where: { userId_seriesId: { userId, seriesId: root.repeatSeriesId! } },
      }),
    ).toMatchObject({
      scheduleSignature: after.scheduleSignature,
      nextDay: after.nextDay,
    });
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(3);
  });

  it('坏系列单独回滚并退避，不阻塞正常系列且修复后可以重试', async () => {
    // 四个坏系列先占满首轮预算，错误断点不能永久排在正常系列前。
    for (let index = 1; index <= 4; index++)
      await seed(2, {
        priorityQuadrant: 4,
        repeatSeriesId: `00000000-0000-4000-8000-00000000000${index}`,
      });
    const healthy = await seed(2);
    await worker.runOnce();
    expect(
      await prisma.todoRecurrenceCursor.count({
        where: {
          userId,
          errorCode: 'GENERATION_FAILED',
          retryAfter: { not: null },
        },
      }),
    ).toBe(4);
    await worker.runOnce();
    expect(
      await prisma.todoItem.count({
        where: { userId, repeatSeriesId: healthy.repeatSeriesId },
      }),
    ).toBe(3);
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'error', reason: 'GENERATION_FAILED' });
    // 修复数据并模拟已过退避时间，原日期必须能够继续生成。
    await prisma.todoItem.updateMany({
      where: { userId, priorityQuadrant: 4 },
      data: { priorityQuadrant: 2 },
    });
    await prisma.todoRecurrenceCursor.updateMany({
      where: { userId, errorCode: 'GENERATION_FAILED' },
      data: { retryAfter: new Date(0) },
    });
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(15);
    expect(
      await prisma.todoRecurrenceCursor.count({
        where: { userId, errorCode: { not: null } },
      }),
    ).toBe(0);
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'idle', reason: null });
  });

  it('后续实例改变频率后按新的规则段补齐，自动生成不反复重置排程', async () => {
    // 首段每周周期先生成昨天之前的一次实例。
    const root = await seed(9, { repeatRule: 'weekly' });
    await worker.runOnce();
    await worker.runOnce();
    const laterId = stableBusinessId('repeat-todo', [
      root.repeatSeriesId!,
      addDays(today, -2),
    ]);
    expect(
      await prisma.todoItem.findUnique({ where: { id: laterId } }),
    ).not.toBeNull();
    // 保留最早每周锚点，只从后续实例开始改为每天。
    await todos.update(
      { sub: userId, sid: connection.sessionId, typ: 'access' },
      {
        operationId: randomUUID(),
        id: laterId,
        scope: 'future',
        repeatRule: 'daily',
      },
    );
    await worker.runOnce();
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(4);
    const cursor = await prisma.todoRecurrenceCursor.findUniqueOrThrow({
      where: { userId_seriesId: { userId, seriesId: root.repeatSeriesId! } },
    });
    expect(cursor.nextDay).toEqual(new Date(`${addDays(today, 1)}T00:00:00Z`));
    await worker.runOnce();
    expect(
      await prisma.todoRecurrenceCursor.findUniqueOrThrow({
        where: { userId_seriesId: { userId, seriesId: root.repeatSeriesId! } },
      }),
    ).toMatchObject({
      scheduleSignature: cursor.scheduleSignature,
      nextDay: cursor.nextDay,
    });
  });

  it('已经永久删除的坏系列不会留下永久错误状态', async () => {
    // 初次失败确实保存错误，随后删除的系列不能继续让owner报错。
    const root = await seed(2, { priorityQuadrant: 4 });
    await worker.runOnce();
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'error' });
    await prisma.syncTombstone.create({
      data: { userId, tableName: 'todo_items', recordId: root.id },
    });
    await prisma.todoItem.delete({ where: { id: root.id } });
    await worker.runOnce();
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'idle', reason: null });
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(0);
  });

  it('同一轮坏系列失败时仍提交其他健康系列的实例和断点', async () => {
    // 首系列会失败，但第二系列同一 owner 事务仍须完整保存。
    await seed(2, {
      priorityQuadrant: 4,
      repeatSeriesId: '00000000-0000-4000-8000-000000000001',
    });
    const healthy = await seed(2);
    await worker.runOnce();
    expect(
      await prisma.todoItem.count({
        where: { userId, repeatSeriesId: healthy.repeatSeriesId },
      }),
    ).toBe(3);
    expect(
      await prisma.todoRecurrenceCursor.findUniqueOrThrow({
        where: {
          userId_seriesId: { userId, seriesId: healthy.repeatSeriesId! },
        },
      }),
    ).toMatchObject({
      errorCode: null,
      nextDay: new Date(`${addDays(today, 1)}T00:00:00Z`),
    });
  });

  it.each([
    'readonly',
    'revoked',
    'expired',
    'sessionExpired',
    'sessionMissing',
  ] as const)('%s 连接无法驱动后台写入', async (condition) => {
    await seed(2);
    if (condition === 'readonly')
      await prisma.mcpConnection.update({
        where: { id: connection.id },
        data: { writeModules: [] },
      });
    if (condition === 'revoked')
      await prisma.mcpConnection.update({
        where: { id: connection.id },
        data: { revokedAt: new Date() },
      });
    if (condition === 'expired')
      await prisma.mcpConnection.update({
        where: { id: connection.id },
        data: { expiresAt: new Date(0) },
      });
    if (condition === 'sessionExpired')
      await prisma.deviceSession.update({
        where: { id: connection.sessionId },
        data: { expiresAt: new Date(0) },
      });
    if (condition === 'sessionMissing')
      await prisma.deviceSession.delete({
        where: { id: connection.sessionId },
      });
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(1);
    expect(await prisma.todoRecurrenceCursor.count({ where: { userId } })).toBe(
      0,
    );
    if (condition !== 'readonly')
      expect(
        await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
      ).toMatchObject({ status: 'blocked_authorization' });
  });

  it('缺少或冲突时区明确停止，冲突解除后继续原系列', async () => {
    await seed(2);
    await prisma.mcpConnection.update({
      where: { id: connection.id },
      data: { timeZone: null },
    });
    await worker.runOnce();
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({
      status: 'blocked_timezone',
      reason: 'TIME_ZONE_REQUIRED',
    });
    await prisma.mcpConnection.update({
      where: { id: connection.id },
      data: { timeZone: 'Asia/Shanghai' },
    });
    // 第二条有效写连接与第一条有不同日历地区。
    const conflicting = await addConnection('America/New_York');
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(1);
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({
      status: 'blocked_timezone',
      reason: 'CONFLICTING_TIME_ZONES',
    });
    await prisma.mcpConnection.update({
      where: { id: conflicting.id },
      data: { revokedAt: new Date() },
    });
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(3);
  });

  it('只读连接时区不制造写授权冲突，同义时区别名也不冲突', async () => {
    today = localParts(new Date(), 'UTC').day;
    await seed(1);
    await prisma.mcpConnection.update({
      where: { id: connection.id },
      data: { timeZone: 'UTC' },
    });
    await addConnection('Etc/UTC');
    // 只读连接不能改变后台采用的写入时区。
    const readonly = await addConnection('America/New_York');
    await prisma.mcpConnection.update({
      where: { id: readonly.id },
      data: { writeModules: [] },
    });
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(2);
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'idle', timeZone: 'UTC' });
  });

  it('停止、软删除例外和永久墓碑都不会被补齐复活', async () => {
    // 已停止的种子即使在过去也不产生新实例。
    await seed(4, { repeatRule: 'stopped' });
    // 整个系列只有已删除模板时不能继续生成。
    await seed(4, { deletedAt: new Date() });
    // 有效系列中存在明确删除的某一天。
    const root = await seed(3);
    // 昨日实例的软删除是不可自动覆盖的例外。
    const softId = stableBusinessId('repeat-todo', [
      root.repeatSeriesId!,
      addDays(today, -1),
    ]);
    await prisma.todoItem.create({
      data: {
        ...root,
        id: softId,
        scheduledDate: new Date(`${addDays(today, -1)}T00:00:00Z`),
        deletedAt: new Date(),
      },
    });
    // 前日实例即使不存在实体，墓碑仍必须阻止重建。
    const tombstoneId = stableBusinessId('repeat-todo', [
      root.repeatSeriesId!,
      addDays(today, -2),
    ]);
    await prisma.syncTombstone.create({
      data: { userId, tableName: 'todo_items', recordId: tombstoneId },
    });
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(5);
    expect(
      await prisma.todoItem.findUnique({ where: { id: tombstoneId } }),
    ).toBeNull();
    expect(
      (await prisma.todoItem.findUnique({ where: { id: softId } }))?.deletedAt,
    ).not.toBeNull();
  });

  it('稳定身份与既有客户端编辑共存，重扫不会覆盖内容或完成状态', async () => {
    // 真实种子带子任务，验证两种稳定身份。
    const root = await seed(1);
    // 子系列在客户端、后端生成时使用同一身份公式。
    const child = await prisma.todoItem.create({
      data: {
        id: randomUUID(),
        userId,
        parentId: root.id,
        title: '子任务',
        scheduledDate: root.scheduledDate,
        repeatSeriesId: randomUUID(),
      },
    });
    await worker.runOnce();
    // 客户端编辑模拟使用实际已生成身份，不要求重建工作器上下文。
    const generated = stableBusinessId('repeat-todo', [
      root.repeatSeriesId!,
      today,
    ]);
    await prisma.todoItem.update({
      where: { id: generated },
      data: { title: '客户端修改' },
    });
    // 普通主任务完成必须与孩子级联，建立业务合法的客户端完成状态。
    await todos.setCompleted(
      { sub: userId, sid: connection.sessionId, typ: 'access' },
      { operationId: randomUUID(), id: generated, completed: true },
    );
    // 删除的只是服务端断点，故意模拟需要重新扫描的恢复。
    await prisma.todoRecurrenceCursor.deleteMany({ where: { userId } });
    await worker.runOnce();
    expect(
      await prisma.todoItem.findUnique({ where: { id: generated } }),
    ).toMatchObject({ title: '客户端修改', isCompleted: true });
    expect(
      await prisma.todoItem.findUnique({
        where: {
          id: stableBusinessId('repeat-subtask', [
            root.repeatSeriesId!,
            child.repeatSeriesId!,
            today,
          ]),
        },
      }),
    ).not.toBeNull();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(4);
  });

  it('生成失败回滚实例和断点，恢复后从原日期继续', async () => {
    await seed(2);
    // 中途异常必须使前面已写入的日期和断点全部回滚。
    const original = todos.materializeRepeatedDay.bind(todos);
    // 原方法前两天正常，第三天模拟写入失败。
    const failure = jest
      .spyOn(todos, 'materializeRepeatedDay')
      .mockImplementation(async (...args) => {
        if (args[2] === today) throw new Error('TEST_ROLLBACK');
        return original(...args);
      });
    await worker.runOnce();
    failure.mockRestore();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(1);
    expect(
      await prisma.todoRecurrenceCursor.findFirst({ where: { userId } }),
    ).toMatchObject({
      nextDay: new Date(`${addDays(today, -2)}T00:00:00Z`),
      errorCode: 'GENERATION_FAILED',
    });
    expect(
      await prisma.todoRecurrenceState.findUnique({ where: { userId } }),
    ).toMatchObject({ status: 'error', reason: 'GENERATION_FAILED' });
    // 退避结束后重试，不改变尚未完成日期的原断点。
    await prisma.todoRecurrenceCursor.updateMany({
      where: { userId },
      data: { retryAfter: new Date(0) },
    });
    await worker.runOnce();
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(3);
  });

  it('查询待办和统计不会触发生成或推进后台断点', async () => {
    await seed(2);
    // 专用 MCP 会话作为业务只读调用身份。
    const actor = {
      sub: userId,
      sid: connection.sessionId,
      typ: 'access' as const,
    };
    await todos.list(actor, {});
    await todos.statistics(actor, {
      from: `${addDays(today, -4)}T00:00:00+08:00`,
      to: `${addDays(today, 1)}T00:00:00+08:00`,
      timeZone: 'Asia/Shanghai',
    });
    expect(await prisma.todoItem.count({ where: { userId } })).toBe(1);
    expect(await prisma.todoRecurrenceCursor.count({ where: { userId } })).toBe(
      0,
    );
  });
});
