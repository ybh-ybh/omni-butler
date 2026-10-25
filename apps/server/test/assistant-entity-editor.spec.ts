import { BadRequestException, ConflictException, NotFoundException, UnauthorizedException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';
import { ConfigService } from '@nestjs/config';
import type { AuthUser } from '../src/auth/auth.types';
import { AssistantEntityEditor, assistantEntityVersion } from '../src/assistant/assistant-entity-editor.service';
import { businessWrite } from '../src/business/business-access';
import { QuotesService } from '../src/business/quotes.service';
import { TodosService } from '../src/business/todos.service';
import { InventoryService } from '../src/business/inventory.service';
import { TimeEntriesService } from '../src/business/time-entries.service';
import { NotesBusinessService } from '../src/business/notes-business.service';
import { MembershipsService } from '../src/business/memberships.service';
import { EventsService } from '../src/business/events.service';
import type { Prisma } from '../src/generated/prisma/client';
import type { McpModule } from '../src/mcp/mcp-catalog';
import { PrismaService } from '../src/prisma/prisma.service';

/// 合成存储保留真实业务授权、嵌套事务和持久回执算法，不访问用户数据库。
function fixture(module: McpModule = 'quotes'): {
  actor: AuthUser; row: Record<string, unknown>; receipts: Map<string, Record<string, unknown>>;
  transaction: Record<string, unknown>; transact: jest.Mock; findFirst: jest.Mock; update: jest.Mock;
  domainUpdate: jest.Mock<Promise<Prisma.JsonValue>, [AuthUser, Record<string, unknown>]>;
  editor: AssistantEntityEditor; body: { operationId: string; expectedUpdatedAt: string; expectedVersion: string; changes: Record<string, unknown> }; revoke: () => void;
} {
  // 所有身份都属于独立合成测试账号。
  const actor: AuthUser = { sub: randomUUID(), sid: randomUUID(), typ: 'access' };
  // 被编辑对象具有稳定版本和不可覆盖的普通字段。
  const row: Record<string, unknown> = { id: randomUUID(), userId: actor.sub, content: '原正文', title: '原任务', name: '原名称', description: '保留描述', source: '保留来源', revision: randomUUID(), updatedAt: new Date('2026-10-25T08:00:00Z'), deletedAt: null };
  // 首次与重放响应均来自当前回执表。
  const receipts = new Map<string, Record<string, unknown>>();
  // 可控会话撤销事实。
  let validSession = true;
  // 固定模块表映射只服务测试，不能暴露为请求参数。
  const tables: Record<McpModule, string> = { todos: 'todoItem', inventory: 'inventoryItem', time: 'timeEntry', notes: 'noteEntry', quotes: 'quote', memberships: 'membership', events: 'event' };
  // 模拟同一真实事务内的 Prisma 调用。
  const transaction: Record<string, unknown> = {
    $queryRaw: jest.fn().mockResolvedValue([{ id: actor.sub }]),
    deviceSession: { findFirst: jest.fn(({ where }: { where: { id: string; userId: string } }) => Promise.resolve(validSession && where.id === actor.sid && where.userId === actor.sub ? { id: actor.sid } : null)) },
    businessOperationReceipt: {
      findUnique: jest.fn(({ where }: { where: { userId_operationId: { operationId: string } } }) => Promise.resolve(receipts.get(where.userId_operationId.operationId) ?? null)),
      create: jest.fn(({ data }: { data: Record<string, unknown> }) => { receipts.set(data.operationId as string, data); return Promise.resolve(data); }),
    },
  };
  // 读取必须匹配 owner 和主键，避免跨归属存在性泄露。
  const findFirst = jest.fn(({ where }: { where: { userId: string; id: string } }) => Promise.resolve(where.userId === row.userId && where.id === row.id ? { ...row } : null));
  // 真实 quotes 服务负责省略字段和参数格式校验。
  const update = jest.fn(({ data }: { data: Record<string, unknown> }) => { Object.assign(row, data, { updatedAt: new Date('2026-10-25T08:01:00Z') }); return Promise.resolve({ ...row }); });
  transaction[tables[module]] = { findFirst, update };
  // 事务失败时模拟回滚，避免测试把失败写入视为已提交。
  const transact = jest.fn(async (action: (value: Prisma.TransactionClient) => Promise<unknown>) => {
    // 原行和回执属于同一回滚快照。
    const before = { ...row };
    // 原回执独立复制，后续写入不能改变回滚基线。
    const previous = new Map(receipts);
    try { return await action(transaction as unknown as Prisma.TransactionClient); }
    catch (error) { for (const key of Object.keys(row)) delete row[key]; Object.assign(row, before); receipts.clear(); for (const [key, value] of previous) receipts.set(key, value); throw error; }
  });
  // 同一实例用于业务上下文身份比较。
  const prisma = { $transaction: transact } as unknown as PrismaService;
  // 非 quotes 模块替身只验证分派和嵌套回执，不冒充领域规则的覆盖。
  const domainUpdate = jest.fn((owner: AuthUser, input: Record<string, unknown>) => businessWrite(prisma, owner, `${module}.update`, input, () => {
    // 操作身份与范围不会存进业务行。
    const changes = Object.fromEntries(Object.entries(input).filter(([field]) => !['operationId', 'id', 'scope', 'expectedRevision'].includes(field)));
    return update({ data: changes });
  }));
  // 依赖顺序与正式构造函数一致，测试只替换具体领域能力。
  const services: unknown[] = Array.from({ length: 7 }, () => ({ update: domainUpdate }));
  services[4] = new QuotesService(prisma);
  // 明确限定依赖转换仅发生在测试容器边界。
  const editor = new AssistantEntityEditor(prisma, ...services as unknown as ConstructorParameters<typeof AssistantEntityEditor> extends [PrismaService, ...infer Rest] ? Rest : never);
  // 每次用户保存都带原始 CAS 版本和稳定操作身份。
  const body = { operationId: randomUUID(), expectedUpdatedAt: (row.updatedAt as Date).toISOString(), expectedVersion: assistantEntityVersion(row), changes: { content: '新正文' } as Record<string, unknown> };
  return { actor, row, receipts, transaction, transact, findFirst, update, domainUpdate, editor, body, revoke: (): void => { validSession = false; } };
}

describe('助手结果原地编辑', () => {
  it('只修改明确字段，快照与领域更新及两层回执共同提交', async () => {
    // 正文编辑不应覆盖来源、创建事实或其他字段。
    const state = fixture();
    await expect(state.editor.update(state.actor, 'quotes', state.row.id as string, state.body)).resolves.toMatchObject({ module: 'quotes', label: '原名称', serverSaved: true, record: { content: '新正文', source: '保留来源', updatedAt: '2026-10-25T08:01:00.000Z' } });
    expect(state.transact).toHaveBeenCalledTimes(1);
    expect(state.receipts.size).toBe(2);
    expect(state.update).toHaveBeenCalledWith({ where: { id: state.row.id }, data: { content: '新正文' } });
  });

  it('响应丢失后原身份重放原快照，不再次更新且不因旧基线报冲突', async () => {
    // 保存后记录即使再次改变，原操作回执也必须保持。
    const state = fixture();
    // 首次真实保存结果作为重放比对基线。
    const saved = await state.editor.update(state.actor, 'quotes', state.row.id as string, state.body);
    state.row.content = '其他设备修改';
    state.row.deletedAt = new Date();
    await expect(state.editor.update(state.actor, 'quotes', state.row.id as string, state.body)).resolves.toEqual(saved);
    expect(state.update).toHaveBeenCalledTimes(1);
  });

  it('同一操作身份不能换内容、模块或目标', async () => {
    // 稳定身份不得用于覆盖另一次用户意图。
    const state = fixture();
    await state.editor.update(state.actor, 'quotes', state.row.id as string, state.body);
    await expect(state.editor.update(state.actor, 'quotes', state.row.id as string, { ...state.body, changes: { content: '另一个值' } })).rejects.toBeInstanceOf(ConflictException);
    await expect(state.editor.update(state.actor, 'quotes', randomUUID(), state.body)).rejects.toBeInstanceOf(ConflictException);
    expect(state.update).toHaveBeenCalledTimes(1);
  });

  it('过期版本在领域服务运行前拒绝', async () => {
    // 真实数据冲突不能被默认覆盖。
    const state = fixture();
    state.row.updatedAt = new Date('2026-10-25T09:00:00Z');
    await expect(state.editor.update(state.actor, 'quotes', state.row.id as string, state.body)).rejects.toMatchObject({ response: { code: 'ASSISTANT_ENTITY_CONFLICT' } });
    expect(state.update).not.toHaveBeenCalled();
    expect(state.receipts.size).toBe(0);
  });

  it('同毫秒已有内容改变也拒绝覆盖，规范行摘要不受键顺序和Date包装影响', async () => {
    // 毫秒时间戳相等不能被当成记录完全未变。
    const state = fixture();
    expect(assistantEntityVersion(state.row)).toBe(assistantEntityVersion(JSON.parse(JSON.stringify(Object.fromEntries(Object.entries(state.row).reverse())))));
    state.row.source = '同毫秒其他设备修改';
    await expect(state.editor.update(state.actor, 'quotes', state.row.id as string, state.body)).rejects.toMatchObject({ response: { code: 'ASSISTANT_ENTITY_CONFLICT' } });
    expect(state.update).not.toHaveBeenCalled();
    expect(state.receipts.size).toBe(0);
  });

  it.each(['other-owner', 'deleted', 'missing'])('%s 对象不可编辑', async (reason) => {
    // 找不到和无归属统一不可用，不转为新增。
    const state = fixture();
    if (reason === 'other-owner') state.row.userId = randomUUID();
    if (reason === 'deleted') state.row.deletedAt = new Date();
    await expect(state.editor.update(state.actor, 'quotes', reason === 'missing' ? randomUUID() : state.row.id as string, state.body)).rejects.toBeInstanceOf(NotFoundException);
    expect(state.update).not.toHaveBeenCalled();
  });

  it('当前会话撤销后即使有回执也不能重放', async () => {
    // JWT 形状正确不能代替设备会话事实。
    const state = fixture();
    await state.editor.update(state.actor, 'quotes', state.row.id as string, state.body);
    state.revoke();
    await expect(state.editor.update(state.actor, 'quotes', state.row.id as string, state.body)).rejects.toBeInstanceOf(UnauthorizedException);
    expect(state.update).toHaveBeenCalledTimes(1);
  });

  it.each([{}, { userId: randomUUID() }, { deletedAt: null }, { taskType: 'progress' }, { parentId: randomUUID() }, { repeatRule: 'daily' }])('拒绝空编辑及受保护字段 %j', async (changes) => {
    // 聚合或身份字段不能从通用表单绕过专门流程。
    const state = fixture('todos');
    await expect(state.editor.update(state.actor, 'todos', state.row.id as string, { ...state.body, changes })).rejects.toBeInstanceOf(BadRequestException);
    expect(state.transact).not.toHaveBeenCalled();
  });

  it('非法业务值交由已有领域规则拒绝，失败不保存回执', async () => {
    // 空正文验证直接来自 QuotesService。
    const state = fixture();
    await expect(state.editor.update(state.actor, 'quotes', state.row.id as string, { ...state.body, changes: { content: '' } })).rejects.toBeInstanceOf(BadRequestException);
    expect(state.row.content).toBe('原正文');
    expect(state.receipts.size).toBe(0);
  });

  it.each<[McpModule, Record<string, unknown>]>([
    ['todos', { title: '新任务' }], ['inventory', { name: '新物品' }], ['time', { activity: '新活动', timeZone: 'Asia/Shanghai' }], ['notes', { body: '新笔记' }], ['memberships', { name: '新会员' }], ['events', { name: '新事件' }],
  ])('%s 只调用对应更新服务，不新建或清空省略字段', async (module, changes) => {
    // 每个模块沿用固定服务分派。
    const state = fixture(module);
    await state.editor.update(state.actor, module, state.row.id as string, { ...state.body, changes });
    expect(state.domainUpdate).toHaveBeenCalledTimes(1);
    expect(state.domainUpdate).toHaveBeenCalledWith(state.actor, expect.objectContaining({ ...changes, id: state.row.id, ...(module === 'todos' ? { scope: 'single' } : {}), ...(module === 'notes' ? { expectedRevision: state.row.revision } : {}) }));
    expect(state.domainUpdate.mock.calls[0]![1].operationId).not.toBe(state.body.operationId);
    expect(state.row.description).toBe('保留描述');
    expect(state.transact).toHaveBeenCalledTimes(1);
    expect(state.receipts.size).toBe(2);
  });
});

/// 真实数据库验证只接受本次明确创建的本机空测试库。
const databaseUrl = process.env.OMNI_ASSISTANT_ENTITY_TEST_DATABASE_URL;
/// 未提供隔离库时明确跳过，不读取应用 DATABASE_URL。
const integration = databaseUrl ? describe : describe.skip;

integration('助手结果编辑 / 隔离 PostgreSQL', () => {
  jest.setTimeout(60000);
  // 本套测试仅管理新建空库的迁移连接。
  let database: Client;
  // 所有领域服务共用同一个真实 Prisma 实例。
  let prisma: PrismaService;
  // 正式内联编辑服务与具体领域服务。
  let editor: AssistantEntityEditor;
  // 创建测试数据沿用真实业务入口。
  let todos: TodosService, inventory: InventoryService, quotes: QuotesService;
  // 每例使用独立归属与设备会话。
  let actor: AuthUser;

  beforeAll(async () => {
    // 阻止误用任何现有业务库，即使环境变量被配置错误。
    const url = new URL(databaseUrl!);
    if (url.hostname !== '127.0.0.1' || !/^\/[A-Za-z0-9_]+_test$/.test(url.pathname)) throw new Error('仅允许本机隔离 test 库');
    database = new Client({ connectionString: databaseUrl });
    await database.connect();
    // 服务实际数据库必须与目标一致且未有表，不清理现有 schema。
    const actual = await database.query<{ name: string }>('SELECT current_database() AS name');
    if (`/${actual.rows[0]?.name}` !== url.pathname) throw new Error('实际数据库与测试目标不一致');
    if ((await database.query("SELECT tablename FROM pg_tables WHERE schemaname='public'")).rows.length) throw new Error('仅允许全新空测试库');
    for (const migration of readdirSync(join(__dirname, '../prisma/migrations'), { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort()) {
      await database.query(readFileSync(join(__dirname, '../prisma/migrations', migration, 'migration.sql'), 'utf8'));
    }
    prisma = new PrismaService(new ConfigService({ DATABASE_URL: databaseUrl }));
    await prisma.$connect();
    todos = new TodosService(prisma);
    inventory = new InventoryService(prisma);
    quotes = new QuotesService(prisma);
    editor = new AssistantEntityEditor(prisma, todos, inventory, new TimeEntriesService(prisma), new NotesBusinessService(prisma), quotes, new MembershipsService(prisma), new EventsService(prisma));
  });

  beforeEach(async () => {
    actor = { sub: randomUUID(), sid: randomUUID(), typ: 'access' };
    await prisma.syncOwner.create({ data: { id: actor.sub } });
    await prisma.deviceSession.create({ data: { id: actor.sid, userId: actor.sub, tokenHash: '0'.repeat(64), expiresAt: new Date('2099-01-01T00:00:00Z') } });
  });

  afterAll(async () => {
    if (prisma) await prisma.$disconnect();
    if (database) await database.end();
  });

  /// 从当前真实快照冻结幂等身份、版本和本次修改。
  function request(record: Record<string, unknown>, changes: Record<string, unknown>): Record<string, unknown> {
    return { operationId: randomUUID(), expectedUpdatedAt: new Date(record.updatedAt as string | Date).toISOString(), expectedVersion: assistantEntityVersion(record), changes };
  }

  it('真实待办与物品保存复用领域更新，原请求重放只保存一次', async () => {
    // 保留描述与进度类型等省略字段。
    const todo = await todos.create(actor, { operationId: randomUUID(), title: '网站开发', description: '保留说明', scheduledDate: '2026-10-25' }) as Prisma.JsonObject;
    // 两层回执应在同一个事务中出现。
    const input = request(await prisma.todoItem.findUniqueOrThrow({ where: { id: todo.id as string } }), { title: '完成网站开发', priorityQuadrant: 3 });
    // 真实服务器响应原样用于未知结果恢复。
    const saved = await editor.update(actor, 'todos', todo.id as string, input);
    await expect(editor.update(actor, 'todos', todo.id as string, input)).resolves.toEqual(saved);
    expect(await prisma.todoItem.findUnique({ where: { id: todo.id as string } })).toMatchObject({ title: '完成网站开发', description: '保留说明', priorityQuadrant: 3, taskType: 'normal' });
    expect(await prisma.businessOperationReceipt.count({ where: { userId: actor.sub } })).toBe(3);
    // 物品只更新名称，数量和价格仍来自原记录。
    const item = await inventory.create(actor, { operationId: randomUUID(), name: '显示器', quantity: 2, purchasePriceCents: 120000 }) as Prisma.JsonObject;
    await editor.update(actor, 'inventory', item.id as string, request(item, { name: '桌面显示器' }));
    expect(await prisma.inventoryItem.findUnique({ where: { id: item.id as string } })).toMatchObject({ name: '桌面显示器', quantity: 2, purchasePriceCents: 120000 });
  });

  it('相同版本并发保存只成功一次，第二次不静默覆盖', async () => {
    // 两个独立用户保存意图拥有不同 operationId，但同一旧版本。
    const quote = await quotes.create(actor, { operationId: randomUUID(), content: '原正文' }) as Prisma.JsonObject;
    // owner 行锁必须串行化版本检查和领域更新。
    const results = await Promise.allSettled([
      editor.update(actor, 'quotes', quote.id as string, request(quote, { content: '第一份' })),
      editor.update(actor, 'quotes', quote.id as string, request(quote, { content: '第二份' })),
    ]);
    expect(results.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
    expect(results.filter((result) => result.status === 'rejected')).toHaveLength(1);
    expect(await prisma.businessOperationReceipt.count({ where: { userId: actor.sub } })).toBe(3);
  });

  it('真实归属与软删除校验不会更新其他对象，撤销会话不能重放', async () => {
    // 同一服务还需防止合法设备访问其他 owner 对象。
    const quote = await quotes.create(actor, { operationId: randomUUID(), content: '私有记录' }) as Prisma.JsonObject;
    // 合法第二用户具有完全独立设备会话。
    const other: AuthUser = { sub: randomUUID(), sid: randomUUID(), typ: 'access' };
    await prisma.syncOwner.create({ data: { id: other.sub } });
    await prisma.deviceSession.create({ data: { id: other.sid, userId: other.sub, tokenHash: '1'.repeat(64), expiresAt: new Date('2099-01-01T00:00:00Z') } });
    await expect(editor.update(other, 'quotes', quote.id as string, request(quote, { content: '越权' }))).rejects.toBeInstanceOf(NotFoundException);
    // 保存完成后，再撤销设备也不能访问旧回执。
    const input = request(quote, { content: '本人保存' });
    await editor.update(actor, 'quotes', quote.id as string, input);
    await prisma.deviceSession.delete({ where: { id: actor.sid } });
    await expect(editor.update(actor, 'quotes', quote.id as string, input)).rejects.toBeInstanceOf(UnauthorizedException);
    // 软删除对象即使版本仍合法也不允许继续编辑。
    const deleted = await prisma.quote.update({ where: { id: quote.id as string }, data: { userId: other.sub, deletedAt: new Date() } });
    await expect(editor.update(other, 'quotes', quote.id as string, request(deleted, { content: '错误恢复' }))).rejects.toBeInstanceOf(NotFoundException);
  });

  it('外层回执提交失败时，领域更新与内层回执一起回滚', async () => {
    // 故障注入仅作用此独立空库，本测试从未连接正式数据库。
    const quote = await quotes.create(actor, { operationId: randomUUID(), content: '未改变' }) as Prisma.JsonObject;
    await database.query("CREATE FUNCTION fail_assistant_editor_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.action = 'assistant.entity.update' THEN RAISE EXCEPTION 'synthetic receipt failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER fail_assistant_editor_receipt BEFORE INSERT ON business_operation_receipts FOR EACH ROW EXECUTE FUNCTION fail_assistant_editor_receipt();");
    try {
      await expect(editor.update(actor, 'quotes', quote.id as string, request(quote, { content: '必须回滚' }))).rejects.toThrow();
      expect(await prisma.quote.findUnique({ where: { id: quote.id as string } })).toMatchObject({ content: '未改变' });
      expect(await prisma.businessOperationReceipt.count({ where: { userId: actor.sub } })).toBe(1);
    } finally {
      await database.query('DROP TRIGGER fail_assistant_editor_receipt ON business_operation_receipts; DROP FUNCTION fail_assistant_editor_receipt();');
    }
  });
});
