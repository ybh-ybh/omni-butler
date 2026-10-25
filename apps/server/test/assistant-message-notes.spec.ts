import { BadRequestException, ConflictException, NotFoundException, UnauthorizedException, type ExecutionContext, type INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import type { Server } from 'node:http';
import { join } from 'node:path';
import { Client } from 'pg';
import { AiService } from '../src/ai/ai.service';
import { AssistantModelProvider } from '../src/ai/assistant-model.provider';
import { AssistantController } from '../src/assistant/assistant.controller';
import { AssistantEntityEditor } from '../src/assistant/assistant-entity-editor.service';
import { AssistantMessageNotes } from '../src/assistant/assistant-message-notes.service';
import { AssistantPresentation } from '../src/assistant/assistant-presentation.service';
import { AssistantStore } from '../src/assistant/assistant-store.service';
import type { AuthUser } from '../src/auth/auth.types';
import { JwtAuthGuard } from '../src/auth/jwt-auth.guard';
import { businessWrite } from '../src/business/business-access';
import { NotesBusinessService } from '../src/business/notes-business.service';
import type { Prisma } from '../src/generated/prisma/client';
import type { ActionExecutor } from '../src/mcp/action-executor';
import { PrismaService } from '../src/prisma/prisma.service';

/// 只模拟数据库边界，保留真实身份派生、授权和回执实现。
function fixture(): {
  actor: AuthUser;
  message: { id: string; userId: string; conversationId: string; taskId: string; role: string; content: string };
  flags: { conversation: boolean; session: boolean; generating: boolean; timeZone: string };
  receipts: Map<string, Record<string, unknown>>;
  records: Record<string, unknown>[];
  transaction: { businessOperationReceipt: { findMany: jest.Mock }; assistantRun: { findFirst: jest.Mock } } & Record<string, unknown>;
  transact: jest.Mock;
  create: jest.Mock;
  service: AssistantMessageNotes;
} {
  // 所有身份为随机合成数据。
  const actor: AuthUser = { sub: randomUUID(), sid: randomUUID(), typ: 'access' };
  // 固定消息正文用于断网重放前后对比。
  const message = { id: randomUUID(), userId: actor.sub, conversationId: randomUUID(), taskId: randomUUID(), role: 'assistant', content: '# 完整回答\n\n- 第一项\n- **第二项**' };
  // 可控状态用于验证删除、撤权及未结束回答。
  const flags = { conversation: true, session: true, generating: false, timeZone: 'Asia/Shanghai' };
  // 回执与业务写入属于同一个模拟事务。
  const receipts = new Map<string, Record<string, unknown>>();
  // 已创建笔记的独立事实。
  const records: Record<string, unknown>[] = [];
  // 归属过滤必须在实际查询参数中存在。
  const transaction = {
    $queryRaw: jest.fn().mockResolvedValue([{ id: actor.sub }]),
    deviceSession: { findFirst: jest.fn(({ where }: { where: { id: string; userId: string } }) => Promise.resolve(flags.session && where.id === actor.sid && where.userId === actor.sub ? { id: actor.sid } : null)) },
    assistantMessage: { findFirst: jest.fn(({ where }: { where: { id: string; userId: string; role: string } }) => Promise.resolve(where.id === message.id && where.userId === message.userId && where.role === message.role ? message : null)) },
    assistantConversation: { findFirst: jest.fn(({ where }: { where: { id: string; userId: string } }) => Promise.resolve(flags.conversation && where.id === message.conversationId && where.userId === actor.sub ? { id: message.conversationId } : null)) },
    assistantRun: { findFirst: jest.fn(() => Promise.resolve(flags.generating ? { id: randomUUID() } : null)) },
    assistantSettings: { findUnique: jest.fn(() => Promise.resolve({ enabled: false, timeZone: flags.timeZone })) },
    businessOperationReceipt: {
      findUnique: jest.fn(({ where }: { where: { userId_operationId: { operationId: string } } }) => Promise.resolve(receipts.get(where.userId_operationId.operationId) ?? null)),
      findMany: jest.fn(({ where }: { where: { userId: string; action: string; operationId: { in: string[] } } }) => Promise.resolve([...receipts.values()].filter((row) => row.userId === where.userId && row.action === where.action && where.operationId.in.includes(row.operationId as string)))),
      create: jest.fn(({ data }: { data: Record<string, unknown> }) => { receipts.set(data.operationId as string, data); return Promise.resolve(data); }),
    },
  };
  // 回滚快照防止模拟测试把中途失败当提交成功。
  const transact = jest.fn(async (callback: (value: Prisma.TransactionClient) => Promise<unknown>) => {
    // 已提交回执的独立副本。
    const beforeReceipts = new Map(receipts);
    // 已提交记录数用来回滚本次模拟写入。
    const beforeCount = records.length;
    try { return await callback(transaction as unknown as Prisma.TransactionClient); }
    catch (error) { receipts.clear(); for (const [key, value] of beforeReceipts) receipts.set(key, value); records.splice(beforeCount); throw error; }
  });
  // 业务上下文必须共享同一个 Prisma 实例。
  const prisma = { $transaction: transact } as unknown as PrismaService;
  // 领域替身只模拟持久存储，仍使用正式业务回执代码。
  const create = jest.fn((owner: AuthUser, input: Record<string, unknown>) => businessWrite(prisma, owner, 'notes.create', input, () => {
    // 首次笔记时间只在实际业务写入时生成。
    const note = { id: randomUUID(), body: input.body, createdAt: new Date().toISOString() };
    records.push(note);
    return Promise.resolve({ status: 'saved', note });
  }));
  // 新服务没有模型、运行调度或会话发送依赖。
  const service = new AssistantMessageNotes(prisma, { create } as unknown as NotesBusinessService);
  return { actor, message, flags, receipts, records, transaction, transact, create, service };
}

describe('助手回答直接保存笔记', () => {
  it('完整 Markdown 原文直接交给领域服务，助手关闭也可保存', async () => {
    // 本例不提供任何模型配置。
    const state = fixture();
    // 对外只返回最小保存事实。
    const saved = await state.service.save(state.actor, state.message.id, undefined);
    expect(saved).toEqual({ noteId: state.records[0]!.id, savedAt: state.records[0]!.createdAt });
    expect(state.create).toHaveBeenCalledWith(state.actor, { operationId: expect.any(String), body: state.message.content, timeZone: 'Asia/Shanghai' });
    expect(state.receipts.size).toBe(2);
    expect(state.transact).toHaveBeenCalledTimes(1);
  });

  it('重复点击和未知结果重试不重复写入，正文和时区变化仍复用原回执', async () => {
    // 首次结果是唯一真实保存事实。
    const state = fixture();
    // 模拟响应丢失前已经提交。
    const saved = await state.service.save(state.actor, state.message.id, {});
    state.message.content = '恢复后的另一段正文';
    state.flags.timeZone = 'America/New_York';
    state.flags.generating = true;
    await expect(state.service.save(state.actor, state.message.id, {})).resolves.toEqual(saved);
    expect(state.create).toHaveBeenCalledTimes(1);
    expect(state.transaction.assistantRun.findFirst).toHaveBeenCalledTimes(1);
  });

  it.each([null, { body: '替换正文' }, { operationId: randomUUID() }, { timeZone: 'UTC' }])('拒绝客户端参数 %j', async (body) => {
    // 路由不能成为任意笔记正文写入口。
    const state = fixture();
    await expect(state.service.save(state.actor, state.message.id, body)).rejects.toThrow();
    expect(state.transact).not.toHaveBeenCalled();
  });

  it.each(['user', 'other-owner', 'deleted-conversation', 'missing-message'])('%s 来源不能保存', async (reason) => {
    // 不存在与越权返回同一不可用错误。
    const state = fixture();
    if (reason === 'user') state.message.role = 'user';
    if (reason === 'other-owner') state.message.userId = randomUUID();
    if (reason === 'deleted-conversation') state.flags.conversation = false;
    await expect(state.service.save(state.actor, reason === 'missing-message' ? randomUUID() : state.message.id, {})).rejects.toBeInstanceOf(NotFoundException);
    expect(state.create).not.toHaveBeenCalled();
  });

  it('保存后删除会话或撤销设备不能读取旧回执', async () => {
    // 回执不绕过来源归属和当前授权。
    const state = fixture();
    await state.service.save(state.actor, state.message.id, {});
    state.flags.conversation = false;
    await expect(state.service.save(state.actor, state.message.id, {})).rejects.toBeInstanceOf(NotFoundException);
    state.flags.conversation = true;
    state.flags.session = false;
    await expect(state.service.save(state.actor, state.message.id, {})).rejects.toBeInstanceOf(UnauthorizedException);
    expect(state.create).toHaveBeenCalledTimes(1);
  });

  it('生成中的回答不保存半段正文', async () => {
    // 查询同时检查未结束状态和有效租约。
    const state = fixture();
    state.flags.generating = true;
    await expect(state.service.save(state.actor, state.message.id, {})).rejects.toBeInstanceOf(ConflictException);
    expect(state.create).not.toHaveBeenCalled();
    expect(state.receipts.size).toBe(0);
  });

  it.each(['', ' \n\t', '文'.repeat(20001)])('空白或超限正文明确失败', async (body) => {
    // 不截断正文后伪装完整保存。
    const state = fixture();
    state.message.content = body;
    await expect(state.service.save(state.actor, state.message.id, {})).rejects.toBeInstanceOf(BadRequestException);
    expect(state.create).not.toHaveBeenCalled();
  });

  it('20000 字符正文允许完整保存', async () => {
    // 直接业务保存不再受旧 AI 指令包装的 19000 限制。
    const state = fixture();
    state.message.content = '文'.repeat(20000);
    await state.service.save(state.actor, state.message.id, {});
    expect(state.records[0]!.body).toBe(state.message.content);
  });

  it('本页保存事实一次批量查询，其他归属和无效来源不返回', async () => {
    // 回执身份映射与单次保存使用同一实现。
    const state = fixture();
    // 首次保存作为历史恢复基线。
    const saved = await state.service.save(state.actor, state.message.id, {});
    expect(await state.service.savedForMessages(state.transaction as unknown as Prisma.TransactionClient, state.actor.sub, [state.message.id, randomUUID(), 'synthetic'])).toEqual(new Map([[state.message.id, saved]]));
    expect(state.transaction.businessOperationReceipt.findMany).toHaveBeenCalledTimes(1);
    expect(await state.service.savedForMessages(state.transaction as unknown as Prisma.TransactionClient, randomUUID(), [state.message.id])).toEqual(new Map());
  });
});

describe('保存回答 HTTP 接线及认证门禁', () => {
  // 实际 Nest 控制器仅监听本机随机端口。
  let application: INestApplication;
  // 业务授权仍由真实服务检查，HTTP 只替换 JWT 解析边界。
  let state: ReturnType<typeof fixture>;

  beforeEach(async () => {
    state = fixture();
    // 其余控制器依赖使用空替身，错误触发它们会直接失败。
    const module = await Test.createTestingModule({
      controllers: [AssistantController],
      providers: [
        { provide: AssistantStore, useValue: {} }, { provide: AiService, useValue: {} },
        { provide: AssistantModelProvider, useValue: {} }, { provide: AssistantPresentation, useValue: {} },
        { provide: AssistantEntityEditor, useValue: {} }, { provide: AssistantMessageNotes, useValue: state.service },
      ],
    }).overrideGuard(JwtAuthGuard).useValue({ canActivate(context: ExecutionContext): boolean {
      // 测试凭证只在当前本机 HTTP 应用有效。
      const request = context.switchToHttp().getRequest<{ headers: Record<string, string>; user?: AuthUser }>();
      if (request.headers['x-test-session'] !== state.actor.sid) return false;
      request.user = state.actor;
      return true;
    } }).compile();
    application = module.createNestApplication();
    await application.listen(0, '127.0.0.1');
  });

  afterEach(async () => {
    // 关闭 fetch keep-alive，避免测试遗留监听端口。
    const server = application.getHttpServer() as Server;
    server.closeAllConnections();
    await application.close();
  });

  it('未认证请求被门禁拒绝，认证后保存与重放返回相同事实', async () => {
    // 路由必须保留类级 JwtAuthGuard。
    const url = `${await application.getUrl()}/assistant/messages/${state.message.id}/note`;
    expect((await fetch(url, { method: 'POST' })).status).toBe(403);
    expect(state.create).not.toHaveBeenCalled();
    // 不提交正文或创建助手消息。
    const first = await fetch(url, { method: 'POST', headers: { 'x-test-session': state.actor.sid } });
    expect(first.status).toBe(201);
    // HTTP 回执必须可以 JSON 读取。
    const saved: unknown = await first.json();
    // 同一消息身份重复提交可确认原保存结果。
    const replay = await fetch(url, { method: 'POST', headers: { 'x-test-session': state.actor.sid } });
    expect(await replay.json()).toEqual(saved);
    expect(state.create).toHaveBeenCalledTimes(1);
  });

  it('严格拒绝外部正文并校验路径 UUID，撤权后的原请求返回 401', async () => {
    // 当前服务只接受消息绑定的人工保存动作。
    const base = await application.getUrl();
    // 合成凭证不包含真实用户密钥。
    const headers = { 'x-test-session': state.actor.sid, 'content-type': 'application/json' };
    expect((await fetch(`${base}/assistant/messages/${state.message.id}/note`, { method: 'POST', headers, body: JSON.stringify({ body: '注入正文' }) })).status).toBe(400);
    expect((await fetch(`${base}/assistant/messages/invalid/note`, { method: 'POST', headers })).status).toBe(400);
    state.flags.session = false;
    expect((await fetch(`${base}/assistant/messages/${state.message.id}/note`, { method: 'POST', headers })).status).toBe(401);
    expect(state.create).not.toHaveBeenCalled();
  });
});

/// 集成测试只读取专用变量，绝不使用应用 DATABASE_URL。
const databaseUrl = process.env.OMNI_ASSISTANT_NOTES_TEST_DATABASE_URL;
/// 未提供新建隔离库时明确跳过真实数据库用例。
const integration = databaseUrl ? describe : describe.skip;

integration('保存回答 / 隔离 PostgreSQL', () => {
  jest.setTimeout(60000);
  // 迁移连接仅用于本次全新空测试库。
  let database: Client;
  // 真实服务共用同一 Prisma 实例。
  let prisma: PrismaService;
  // 原样调用正式领域服务和消息入口。
  let service: AssistantMessageNotes;
  // 每例建立独立归属与消息。
  let actor: AuthUser, messageId: string, conversationId: string, taskId: string;

  beforeAll(async () => {
    // 拒绝任何非本机、非 test 命名、已存在表的数据库。
    const url = new URL(databaseUrl!);
    if (url.hostname !== '127.0.0.1' || !/^\/[A-Za-z0-9_]+_test$/.test(url.pathname)) throw new Error('仅允许本机隔离 test 库');
    database = new Client({ connectionString: databaseUrl });
    await database.connect();
    // 确认连接确实指向本次指定库。
    const actual = await database.query<{ name: string }>('SELECT current_database() AS name');
    if (`/${actual.rows[0]?.name}` !== url.pathname) throw new Error('实际数据库与测试目标不一致');
    if ((await database.query("SELECT tablename FROM pg_tables WHERE schemaname='public'")).rows.length) throw new Error('仅允许全新空测试库');
    for (const migration of readdirSync(join(__dirname, '../prisma/migrations'), { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort()) {
      await database.query(readFileSync(join(__dirname, '../prisma/migrations', migration, 'migration.sql'), 'utf8'));
    }
    prisma = new PrismaService(new ConfigService({ DATABASE_URL: databaseUrl }));
    await prisma.$connect();
    service = new AssistantMessageNotes(prisma, new NotesBusinessService(prisma));
  });

  beforeEach(async () => {
    actor = { sub: randomUUID(), sid: randomUUID(), typ: 'access' };
    messageId = randomUUID(); conversationId = randomUUID(); taskId = randomUUID();
    await prisma.syncOwner.create({ data: { id: actor.sub } });
    await prisma.deviceSession.create({ data: { id: actor.sid, userId: actor.sub, tokenHash: randomUUID(), expiresAt: new Date('2099-01-01T00:00:00Z') } });
    await prisma.assistantSettings.create({ data: { userId: actor.sub, enabled: false, timeZone: 'Asia/Shanghai' } });
    await prisma.assistantConversation.create({ data: { id: conversationId, userId: actor.sub, title: '隔离测试' } });
    await prisma.assistantMessage.create({ data: { id: messageId, userId: actor.sub, conversationId, taskId, role: 'assistant', content: '# 回答\n\n- **原始 Markdown**', cards: [] } });
  });

  afterAll(async () => {
    if (prisma) await prisma.$disconnect();
    if (database) await database.end();
  });

  it('并发点击只创建一篇笔记和首版本，两层回执原子提交', async () => {
    // 两个设备并发请求共享消息身份而不是客户端临时按钮状态。
    const results = await Promise.all([service.save(actor, messageId, {}), service.save(actor, messageId, {})]);
    expect(results[0]).toEqual(results[1]);
    expect(await prisma.noteEntry.count({ where: { userId: actor.sub } })).toBe(1);
    expect(await prisma.noteVersion.count({ where: { userId: actor.sub } })).toBe(1);
    expect(await prisma.businessOperationReceipt.count({ where: { userId: actor.sub } })).toBe(2);
    expect(await prisma.noteEntry.findUnique({ where: { id: results[0].noteId } })).toMatchObject({ body: '# 回答\n\n- **原始 Markdown**', isPinned: false, tags: '[]' });
    expect(await prisma.assistantRun.count({ where: { userId: actor.sub } })).toBe(0);
    expect(await prisma.assistantMessage.count({ where: { userId: actor.sub } })).toBe(1);
  });

  it('未知结果重放保留人工修改和软删除，不再次创建', async () => {
    // 原回执只证明历史已保存，不能恢复或覆盖现在的笔记。
    const saved = await service.save(actor, messageId, {});
    await prisma.noteEntry.update({ where: { id: saved.noteId }, data: { body: '人工修改', deletedAt: new Date() } });
    await prisma.assistantMessage.update({ where: { id: messageId }, data: { content: '恢复后的正文' } });
    await prisma.assistantSettings.update({ where: { userId: actor.sub }, data: { timeZone: 'America/New_York' } });
    await expect(service.save(actor, messageId, {})).resolves.toEqual(saved);
    expect(await prisma.noteEntry.findUnique({ where: { id: saved.noteId } })).toMatchObject({ body: '人工修改', deletedAt: expect.any(Date) });
    expect(await prisma.noteEntry.count({ where: { userId: actor.sub } })).toBe(1);
    expect(await prisma.noteVersion.count({ where: { userId: actor.sub } })).toBe(1);
  });

  it.each(['queued', 'running', 'succeeded-lease'])('%s 阻止首次保存，租约释放后允许', async (status) => {
    // 终态名称不代替工作进程已经完成收尾的事实。
    const run = await prisma.assistantRun.create({ data: { id: randomUUID(), userId: actor.sub, conversationId, taskId, answerMessageId: messageId, sessionId: actor.sid, status: status === 'succeeded-lease' ? 'succeeded' : status, leaseOwner: status === 'succeeded-lease' ? randomUUID() : null, leaseUntil: status === 'succeeded-lease' ? new Date(Date.now() + 60000) : null, profileSnapshot: {}, state: {} } });
    await expect(service.save(actor, messageId, {})).rejects.toBeInstanceOf(ConflictException);
    expect(await prisma.noteEntry.count({ where: { userId: actor.sub } })).toBe(0);
    await prisma.assistantRun.update({ where: { id: run.id }, data: { status: 'succeeded', leaseOwner: null, leaseUntil: null } });
    await expect(service.save(actor, messageId, {})).resolves.toMatchObject({ noteId: expect.any(String) });
  });

  it('真实跨用户、会话删除与会话撤权校验仍在重放前执行', async () => {
    // 第二 owner 具有合法设备，但没有来源消息权限。
    const other: AuthUser = { sub: randomUUID(), sid: randomUUID(), typ: 'access' };
    await prisma.syncOwner.create({ data: { id: other.sub } });
    await prisma.deviceSession.create({ data: { id: other.sid, userId: other.sub, tokenHash: randomUUID(), expiresAt: new Date('2099-01-01T00:00:00Z') } });
    await expect(service.save(other, messageId, {})).rejects.toBeInstanceOf(NotFoundException);
    await service.save(actor, messageId, {});
    await prisma.assistantConversation.delete({ where: { id: conversationId } });
    await expect(service.save(actor, messageId, {})).rejects.toBeInstanceOf(NotFoundException);
    await prisma.deviceSession.delete({ where: { id: actor.sid } });
    await expect(service.save(actor, messageId, {})).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('外层回执故障使笔记、首版本与内层回执一起回滚', async () => {
    // 故障触发器只存在于本次空测试库。
    await database.query("CREATE FUNCTION fail_assistant_note_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.action = 'assistant.message.save-note' THEN RAISE EXCEPTION 'synthetic receipt failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER fail_assistant_note_receipt BEFORE INSERT ON business_operation_receipts FOR EACH ROW EXECUTE FUNCTION fail_assistant_note_receipt();");
    try {
      await expect(service.save(actor, messageId, {})).rejects.toThrow();
      expect(await prisma.noteEntry.count({ where: { userId: actor.sub } })).toBe(0);
      expect(await prisma.noteVersion.count({ where: { userId: actor.sub } })).toBe(0);
      expect(await prisma.businessOperationReceipt.count({ where: { userId: actor.sub } })).toBe(0);
    } finally {
      await database.query('DROP TRIGGER fail_assistant_note_receipt ON business_operation_receipts; DROP FUNCTION fail_assistant_note_receipt();');
    }
  });

  it('历史消息一次读取 savedNote，无回执消息不伪造已保存事实', async () => {
    // 历史页使用正式存储服务，不从客户端局部按钮状态恢复。
    const saved = await service.save(actor, messageId, {});
    // 第二条相同文本仍是不同消息身份。
    const otherMessageId = randomUUID();
    await prisma.assistantMessage.create({ data: { id: otherMessageId, userId: actor.sub, conversationId, taskId, role: 'assistant', content: '未保存', cards: [] } });
    // 此路径没有模型、附件、动作依赖。
    const store = new AssistantStore(prisma, {} as AiService, {} as ActionExecutor, undefined, service);
    // 查询次数证明没有逐消息 N+1。
    const reads = jest.spyOn(service, 'savedForMessages');
    try {
      // 公开历史投影可选增加字段，旧消息保持兼容。
      const page = await store.messages(actor, conversationId) as { items: Array<{ id: string; savedNote?: unknown }> };
      expect(page.items.find((message) => message.id === messageId)?.savedNote).toEqual(saved);
      expect(page.items.find((message) => message.id === otherMessageId)?.savedNote).toBeUndefined();
      expect(reads).toHaveBeenCalledTimes(1);
      expect(reads.mock.calls[0]?.[2]).toEqual(expect.arrayContaining([messageId, otherMessageId]));
    } finally { reads.mockRestore(); }
  });
});
