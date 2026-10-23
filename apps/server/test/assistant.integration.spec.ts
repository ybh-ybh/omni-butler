import { Test, type TestingModule } from '@nestjs/testing';
import { ConfigModule, ConfigService } from '@nestjs/config';
import type { INestApplication } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';
import { AssistantModule } from '../src/assistant/assistant.module';
import { AssistantStore } from '../src/assistant/assistant-store.service';
import { AssistantRunner } from '../src/assistant/assistant-runner.service';
import { AssistantBatchService } from '../src/assistant/assistant-batch.service';
import { assistantJson } from '../src/assistant/assistant.types';
import { AssistantModelProvider } from '../src/ai/assistant-model.provider';
import { AiService } from '../src/ai/ai.service';
import type {
  AssistantModelResult,
  AssistantModelRequest,
  AssistantProfileSnapshot,
} from '../src/ai/assistant-model.types';
import { PrismaService } from '../src/prisma/prisma.service';
import { TodoRecurrenceService } from '../src/business/todo-recurrence.service';
import type { AuthUser } from '../src/auth/auth.types';

/// 只接受显式隔离空库，不读取真实DATABASE_URL。
const databaseUrl = process.env.OMNI_ASSISTANT_TEST_DATABASE_URL;
/// 无可用隔离库时明确显示未验证。
const integration = databaseUrl ? describe : describe.skip;

integration('应用内助手 / 真实 PostgreSQL 和 LangGraph checkpoint', () => {
  // 数据库清理权仅在确认空库后取得。
  let database: Client,
    prisma: PrismaService,
    module: TestingModule,
    store: AssistantStore,
    runner: AssistantRunner;
  let ownsSchema = false;
  // 同owner两台真实设备和独立他人身份。
  let actor: AuthUser, second: AuthUser, other: AuthUser;
  // 固定测试配置仅模拟模型网络，不模拟业务执行或事务。
  const model = {
    complete: jest.fn<
      Promise<AssistantModelResult>,
      [string, AssistantProfileSnapshot, AssistantModelRequest]
    >(),
    testCapability: jest.fn(),
  };
  let profileId: string;
  // HTTP/SSE 使用真实 JWT 守卫，仍只绑定本机随机端口。
  let application: INestApplication, baseUrl: string;
  // 签名只使用上方临时测试 RSA 密钥。
  const token = (identity: AuthUser): Promise<string> =>
    module.get(JwtService).signAsync(identity, {
      audience: 'omni-butler-api',
      expiresIn: 3600,
    });
  // 客户端取消订阅不等于停止后台运行，所有读取都有界。
  const readEvents = async (
    identity: AuthUser,
    runId: string,
    after = 0,
  ): Promise<
    Array<{
      seq: number;
      type: string;
      data: { run?: { requiresTakeover: boolean; plan: unknown } };
    }>
  > => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch(
        `${baseUrl}/runs/${runId}/events?after=${after}`,
        {
          headers: { Authorization: `Bearer ${await token(identity)}` },
          signal: controller.signal,
        },
      );
      expect(response.status).toBe(200);
      const reader = response.body!.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) throw new Error('尚未接收事件就断开');
        buffer += decoder.decode(chunk.value, { stream: true });
        const frames = buffer.split('\n\n');
        buffer = frames.pop() ?? '';
        const events = frames.flatMap((frame) => {
          const data = frame
            .split('\n')
            .find((line) => line.startsWith('data: '));
          return data
            ? [
                JSON.parse(data.slice(6)) as {
                  seq: number;
                  type: string;
                  data: { run?: { requiresTakeover: boolean; plan: unknown } };
                },
              ]
            : [];
        });
        if (events.length) return events;
      }
    } finally {
      controller.abort();
      clearTimeout(timer);
    }
  };
  // 确定响应形状模拟供应商完整终态。
  const reply = (
    names: string[] = [],
    text = '已完成',
  ): AssistantModelResult => {
    // 协议调用身份仅存在此测试。
    const functionCalls = names.map((content) => ({
      id: randomUUID(),
      callId: randomUUID(),
      name: 'create_quote',
      arguments: { content },
    }));
    return {
      responseId: randomUUID(),
      text: functionCalls.length ? '' : text,
      functionCalls,
      output: functionCalls.length
        ? functionCalls.map((call) => ({
            type: 'function_call',
            id: call.id,
            call_id: call.callId,
            name: call.name,
            arguments: JSON.stringify(call.arguments),
          }))
        : [{ role: 'assistant', content: text }],
      usage: { inputTokens: 10, outputTokens: 10, totalTokens: 20 },
    };
  };

  beforeAll(async () => {
    // 库名、地址及已有schema三重验证，拒绝使用用户业务库。
    const url = new URL(databaseUrl!);
    if (
      url.hostname !== '127.0.0.1' ||
      !/^\/[a-zA-Z0-9_]+_test$/.test(url.pathname)
    )
      throw new Error('助手测试只允许本机_test空库');
    database = new Client({ connectionString: databaseUrl });
    await database.connect();
    if (
      (
        await database.query(
          "SELECT 1 FROM pg_tables WHERE schemaname IN ('public','assistant_graph')",
        )
      ).rows.length
    )
      throw new Error('助手集成测试要求空schema');
    ownsSchema = true;
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
    // 所有认证签名只用本套测试生成的密钥。
    const keys = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    });
    const config = {
      DATABASE_URL: databaseUrl,
      SYNC_SECRET: 'isolated-assistant-test',
      JWT_PRIVATE_KEY_BASE64: Buffer.from(keys.privateKey).toString('base64'),
      JWT_PUBLIC_KEY_BASE64: Buffer.from(keys.publicKey).toString('base64'),
      JWT_KEY_ID: 'assistant-test',
      JWT_ISSUER: 'omni-butler',
      JWT_AUDIENCE: 'omni-butler-api',
      REFRESH_TOKEN_TTL_SECONDS: 86400,
    };
    prisma = new PrismaService(new ConfigService(config));
    await prisma.$connect();
    // 仅替换模型配置读取，所有owner/session/CRUD仍访问真实数据库。
    const ai = {
      captureAssistantProfile: async (
        userId: string,
        id: string,
      ): Promise<AssistantProfileSnapshot> => {
        const profile = await prisma.aiProfile.findFirstOrThrow({
          where: { id, userId },
        });
        if (!profile.encryptedApiKey) throw new Error('测试模型缺少密文配置');
        return {
          profileId: profile.id,
          profileRevision: profile.revision,
          provider: profile.provider,
          baseUrl: profile.baseUrl,
          model: profile.model,
          encryptedApiKey: profile.encryptedApiKey,
        };
      },
    };
    module = await Test.createTestingModule({
      imports: [
        ConfigModule.forRoot({
          isGlobal: true,
          ignoreEnvFile: true,
          load: [(): typeof config => config],
        }),
        AssistantModule,
      ],
    })
      .overrideProvider(PrismaService)
      .useValue(prisma)
      .overrideProvider(TodoRecurrenceService)
      .useValue({})
      .overrideProvider(AiService)
      .useValue(ai)
      .overrideProvider(AssistantModelProvider)
      .useValue(model)
      .compile();
    store = module.get(AssistantStore);
    runner = module.get(AssistantRunner);
    // 设备都使用真实device_sessions记录，测试不会伪造授权成功。
    const owner = await prisma.syncOwner.create({ data: { id: randomUUID() } });
    const makeActor = async (userId: string): Promise<AuthUser> => {
      const session = await prisma.deviceSession.create({
        data: {
          id: randomUUID(),
          userId,
          tokenHash: randomUUID(),
          expiresAt: new Date(Date.now() + 3600000),
        },
      });
      return { sub: userId, sid: session.id, typ: 'access' };
    };
    actor = await makeActor(owner.id);
    second = await makeActor(owner.id);
    other = await makeActor(
      (await prisma.syncOwner.create({ data: { id: randomUUID() } })).id,
    );
    profileId = randomUUID();
    await prisma.aiProfile.create({
      data: {
        id: profileId,
        userId: actor.sub,
        name: '隔离模型',
        provider: 'custom',
        baseUrl: 'https://example.com/v1',
        model: 'test',
        encryptedApiKey: 'test-only-ciphertext',
      },
    });
    await store.settings(actor);
    await store.updateSettings(actor, {
      revision: 0,
      enabled: true,
      profileId,
      memoryReadEnabled: true,
      memoryWriteEnabled: true,
      timeZone: 'Asia/Shanghai',
    });
    // 显式手动 tick 驱动任务，禁止 HTTP 启动时多一套自动扫描造成测试竞争。
    jest.spyOn(runner, 'onModuleInit').mockImplementation(() => undefined);
    application = module.createNestApplication();
    application.setGlobalPrefix('omni-butler/api/v1');
    await application.listen(0, '127.0.0.1');
    baseUrl = `${await application.getUrl()}/omni-butler/api/v1/assistant`;
  }, 60000);

  afterAll(async () => {
    if (application) await application.close();
    else await module?.close();
    await prisma?.$disconnect();
    if (ownsSchema)
      await database.query(
        'DROP SCHEMA public CASCADE; DROP SCHEMA IF EXISTS assistant_graph CASCADE; CREATE SCHEMA public;',
      );
    await database?.end();
  });

  beforeEach(() => {
    model.complete.mockReset();
  });
  // 每个用例独立会话，避免活动任务影响其他用例。
  const send = async (
    content: string,
  ): Promise<{
    conversation: { id: string };
    input: { clientMessageId: string; content: string; timeZone: string };
    run: { id: string; taskId: string };
  }> => {
    const conversation = (await store.createConversation(actor, {})) as {
      id: string;
    };
    const input = {
      clientMessageId: randomUUID(),
      content,
      timeZone: 'Asia/Shanghai',
    };
    const run = (await store.send(actor, conversation.id, input)) as {
      id: string;
      taskId: string;
    };
    return { conversation, input, run };
  };

  it('HTTP 使用真实设备 JWT、严格输入和 owner 隔离，公开接口不泄露密文', async () => {
    expect((await fetch(`${baseUrl}/settings`)).status).toBe(401);
    // 已保存密文只用于服务器请求，设置中也不可见。
    const settings = await fetch(`${baseUrl}/settings`, {
      headers: { Authorization: `Bearer ${await token(actor)}` },
    });
    expect(settings.status).toBe(200);
    expect(await settings.text()).not.toMatch(
      /test-only-ciphertext|encryptedApiKey|profileSnapshot/,
    );
    // 任意 source/owner/confirmed 字段不能越过严格 schema。
    const invalid = await fetch(`${baseUrl}/conversations`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${await token(actor)}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ title: '非法请求', confirmed: true }),
    });
    expect(invalid.status).toBe(400);
    const conversation = (await store.createConversation(actor, {})) as {
      id: string;
    };
    const forbidden = await fetch(
      `${baseUrl}/conversations/${conversation.id}/messages`,
      {
        headers: { Authorization: `Bearer ${await token(other)}` },
      },
    );
    expect(forbidden.status).toBe(404);
    expect(model.complete).not.toHaveBeenCalled();
  });

  it('SSE 断线按序号续接、按订阅设备投影接管状态，取消事件不带旧计划', async () => {
    model.complete
      .mockResolvedValueOnce(reply(['SSE-A', 'SSE-B']))
      .mockResolvedValueOnce(reply([], '完整计划'));
    const { run } = await send('添加两条名言');
    await runner.tick();
    const events = await readEvents(second, run.id);
    expect(events.every((event) => event.seq > 0)).toBe(true);
    expect(
      events
        .filter((event) => event.data.run)
        .every((event) => event.data.run!.requiresTakeover),
    ).toBe(true);
    const prior = await prisma.assistantRun.findUniqueOrThrow({
      where: { id: run.id },
    });
    await store.stop(actor, run.id);
    const resumed = await readEvents(second, run.id, prior.eventSequence);
    expect(resumed.every((event) => event.seq > prior.eventSequence)).toBe(
      true,
    );
    expect(resumed.find((event) => event.type === 'run.updated')).toMatchObject(
      { data: { run: { status: 'cancelled', plan: null } } },
    );
    expect(await store.run(actor, run.id)).toMatchObject({
      status: 'cancelled',
    });
  });

  it('设备授权在排队后失效时不调用模型，旧 JWT 同时失效', async () => {
    // 独立设备避免破坏其他测试共享身份。
    const session = await prisma.deviceSession.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        tokenHash: randomUUID(),
        expiresAt: new Date(Date.now() + 3600000),
      },
    });
    const revoked: AuthUser = { ...actor, sid: session.id };
    const bearer = await token(revoked);
    const conversation = (await store.createConversation(revoked, {})) as {
      id: string;
    };
    const run = (await store.send(revoked, conversation.id, {
      clientMessageId: randomUUID(),
      content: '添加一条名言',
    })) as { id: string; taskId: string };
    await prisma.deviceSession.delete({ where: { id: revoked.sid } });
    await runner.tick();
    expect(model.complete).not.toHaveBeenCalled();
    expect(
      await prisma.mcpAction.count({ where: { sourceId: run.taskId } }),
    ).toBe(0);
    expect(
      (
        await fetch(`${baseUrl}/runs/${run.id}`, {
          headers: { Authorization: `Bearer ${bearer}` },
        })
      ).status,
    ).toBe(401);
  });

  it('单条直接提交，重复消息及轮询不重复新增，回执包含持续同步保护', async () => {
    const content = `单条-${randomUUID()}`;
    model.complete
      .mockResolvedValueOnce(reply([content]))
      .mockResolvedValueOnce(reply([], '计划已收集'))
      .mockResolvedValueOnce(reply([], '实际已保存'));
    const { conversation, input, run } = await send(`添加名言${content}`);
    await runner.tick();
    expect(
      ((await store.run(actor, run.id)) as { status: string }).status,
    ).toBe('succeeded');
    expect(
      await prisma.quote.count({ where: { userId: actor.sub, content } }),
    ).toBe(1);
    expect(
      ((await store.send(actor, conversation.id, input)) as { id: string }).id,
    ).toBe(run.id);
    await runner.tick();
    expect(
      await prisma.quote.count({ where: { userId: actor.sub, content } }),
    ).toBe(1);
    const action = await prisma.mcpAction.findFirstOrThrow({
      where: { source: 'assistant', sourceId: run.taskId },
    });
    expect(action.connectionId).toBeNull();
    expect(
      (action.result as { protectedRecords: unknown[] }).protectedRecords
        .length,
    ).toBeGreaterThan(0);
    await expect(store.run(other, run.id)).rejects.toThrow();
  });

  it('两个模型轮次各提出一条写入，整任务确认前都不保存，另一设备确认后只执行一次', async () => {
    const a = `批量A-${randomUUID()}`,
      b = `批量B-${randomUUID()}`;
    model.complete
      .mockResolvedValueOnce(reply([a]))
      .mockResolvedValueOnce(reply([b]))
      .mockResolvedValueOnce(reply([], '计划完成'))
      .mockResolvedValueOnce(reply([], '两项已保存'));
    const { run } = await send('新增两条名言');
    await runner.tick();
    const paused = (await store.run(actor, run.id)) as {
      status: string;
      plan: {
        id: string;
        version: number;
        previewHash: string;
        targetCount: number;
      };
    };
    expect(paused.status).toBe('waitingConfirmation');
    expect(paused.plan.targetCount).toBe(2);
    expect(
      await prisma.quote.count({ where: { content: { in: [a, b] } } }),
    ).toBe(0);
    await expect(
      store.decision(other, paused.plan.id, {
        version: paused.plan.version,
        previewHash: paused.plan.previewHash,
        decision: 'confirm',
      }),
    ).rejects.toThrow();
    await store.decision(second, paused.plan.id, {
      version: paused.plan.version,
      previewHash: paused.plan.previewHash,
      decision: 'confirm',
    });
    await runner.tick();
    expect(
      ((await store.run(actor, run.id)) as { status: string }).status,
    ).toBe('succeeded');
    expect(
      await prisma.quote.count({ where: { content: { in: [a, b] } } }),
    ).toBe(2);
    await store.decision(second, paused.plan.id, {
      version: paused.plan.version,
      previewHash: paused.plan.previewHash,
      decision: 'confirm',
    });
    await runner.tick();
    expect(
      await prisma.quote.count({ where: { content: { in: [a, b] } } }),
    ).toBe(2);
  });

  it('取消计划后旧卡片不能重新授权', async () => {
    const a = `取消A-${randomUUID()}`,
      b = `取消B-${randomUUID()}`;
    model.complete
      .mockResolvedValueOnce(reply([a, b]))
      .mockResolvedValueOnce(reply([], '待确认'));
    const { run } = await send('新增两项然后取消');
    await runner.tick();
    const paused = (await store.run(actor, run.id)) as {
      plan: { id: string; version: number; previewHash: string };
    };
    await store.decision(actor, paused.plan.id, {
      version: paused.plan.version,
      previewHash: paused.plan.previewHash,
      decision: 'cancel',
    });
    await store.decision(actor, paused.plan.id, {
      version: paused.plan.version,
      previewHash: paused.plan.previewHash,
      decision: 'confirm',
    });
    await runner.tick();
    expect(
      await prisma.quote.count({ where: { content: { in: [a, b] } } }),
    ).toBe(0);
    expect(
      ((await store.run(actor, run.id)) as { status: string }).status,
    ).toBe('cancelled');
  });

  it('删除聊天保留执行回执和protectedRecords，消息事件按连续序号读取', async () => {
    model.complete
      .mockResolvedValueOnce(reply([`保留-${randomUUID()}`]))
      .mockResolvedValueOnce(reply([], '计划'))
      .mockResolvedValueOnce(reply());
    const { conversation, run } = await send('新增单项');
    await runner.tick();
    const events = (await store.events(actor, run.id, 0)) as { seq: number }[];
    expect(events.map((event) => event.seq)).toEqual(
      events.map((_event, index) => index + 1),
    );
    await store.removeConversation(actor, conversation.id);
    expect(
      await prisma.assistantMessage.count({
        where: { conversationId: conversation.id },
      }),
    ).toBe(0);
    expect(
      await prisma.mcpAction.count({
        where: {
          source: 'assistant',
          sourceId: run.taskId,
          status: 'succeeded',
        },
      }),
    ).toBe(1);
  });

  it.each([
    [
      'time',
      'create_time_entry',
      {
        activity: '面试复盘',
        startedAt: '2026-10-23T20:00:00+08:00',
        endedAt: '2026-10-23T21:40:00+08:00',
      },
    ],
    ['inventory', 'create_item', { name: '隔离测试物品' }],
    [
      'memberships',
      'create_membership',
      {
        name: '隔离测试会员',
        purchaseDate: '2026-10-23',
        expirationDate: '2026-11-23',
        billingCycle: 'month',
        priceCents: 1000,
      },
    ],
    ['events', 'create_event', { name: '隔离测试事件' }],
    [
      'todos',
      'create_todo',
      { title: '隔离测试待办', scheduledDate: '2026-10-23' },
    ],
    ['notes', 'create_note', { body: '隔离测试笔记' }],
  ])(
    '%s单对象派生记录不误判批量，直接执行到真实业务表',
    async (_module, name, args) => {
      // 各模块使用真实目录校验及真实事务，不模拟业务输出。
      const call = {
        id: randomUUID(),
        callId: randomUUID(),
        name,
        arguments: args as Record<string, unknown>,
      };
      const first = reply();
      first.functionCalls = [call];
      first.output = [
        {
          type: 'function_call',
          id: call.id,
          call_id: call.callId,
          name: call.name,
          arguments: JSON.stringify(call.arguments),
        },
      ];
      model.complete
        .mockResolvedValueOnce(first)
        .mockResolvedValueOnce(reply([], '计划齐全'))
        .mockResolvedValueOnce(reply([], '实际保存完成'));
      const { run } = await send(`添加一个${_module}`);
      await runner.tick();
      const result = (await store.run(actor, run.id)) as {
        status: string;
        errorCode: string;
        plan?: { targetCount: number };
      };
      expect(result).toMatchObject({ status: 'succeeded' });
      expect(result.plan?.targetCount).toBe(1);
      expect(
        await prisma.mcpAction.count({
          where: { sourceId: run.taskId, status: 'succeeded' },
        }),
      ).toBe(1);
    },
  );

  it('单条新增撤销是幂等软删除补偿，原业务回执保留', async () => {
    const content = `补偿-${randomUUID()}`;
    model.complete
      .mockResolvedValueOnce(reply([content]))
      .mockResolvedValueOnce(reply([], '计划'))
      .mockResolvedValueOnce(reply());
    const { run } = await send('新增一条名言');
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({ canUndo: true });
    const compensation = (await store.undo(actor, run.id)) as { id: string };
    expect(await store.undo(actor, run.id)).toMatchObject({
      id: compensation.id,
    });
    await runner.tick();
    expect(await store.run(actor, compensation.id)).toMatchObject({
      status: 'succeeded',
    });
    expect(
      await prisma.quote.findFirst({ where: { userId: actor.sub, content } }),
    ).toMatchObject({ deletedAt: expect.any(Date) });
    expect(
      await prisma.mcpAction.count({
        where: { sourceId: run.taskId, status: 'succeeded' },
      }),
    ).toBe(2);
  });

  it('完整模型响应前中断不能写业务，重试显式创建新付费尝试', async () => {
    model.complete.mockRejectedValueOnce(
      Object.assign(new Error('stream truncated'), {
        code: 'AI_SUBMISSION_UNKNOWN',
      }),
    );
    const { run } = await send('新增一条名言');
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({
      status: 'submissionUnknown',
    });
    expect(
      await prisma.mcpAction.count({ where: { sourceId: run.taskId } }),
    ).toBe(0);
    await runner.tick();
    expect(model.complete).toHaveBeenCalledTimes(1);
    model.complete
      .mockResolvedValueOnce(reply([`重试-${randomUUID()}`]))
      .mockResolvedValueOnce(reply([], '计划'))
      .mockResolvedValueOnce(reply());
    const retried = (await store.retry(actor, run.id)) as { id: string };
    await runner.tick();
    expect(await store.run(actor, retried.id)).toMatchObject({
      status: 'succeeded',
    });
    expect(
      await prisma.mcpAction.count({
        where: { sourceId: run.taskId, status: 'succeeded' },
      }),
    ).toBe(1);
  });

  it('模型响应已落回执但图状态尚未推进时，优先重放且不再次计费或新增', async () => {
    const content = `回执恢复-${randomUUID()}`;
    const { run } = await send('新增一条名言');
    // 模拟进程恰好在完整付费响应落库后退出；尚无业务动作和图状态推进。
    const saved = {
      ...reply([content]),
      requestInput: [{ role: 'user', content: '原始固定输入' }],
    };
    await prisma.assistantAttempt.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        runId: run.id,
        ordinal: 1,
        inputHash: '0'.repeat(64),
        status: 'succeeded',
        response: assistantJson(saved),
      },
    });
    model.complete
      .mockResolvedValueOnce(reply([], '完整计划'))
      .mockResolvedValueOnce(reply([], '实际已保存'));
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({
      status: 'succeeded',
    });
    expect(model.complete).toHaveBeenCalledTimes(2);
    expect(
      await prisma.quote.count({ where: { userId: actor.sub, content } }),
    ).toBe(1);
    expect(
      await prisma.assistantAttempt.count({
        where: { runId: run.id, ordinal: 1 },
      }),
    ).toBe(1);
  });

  it('业务已经成功时回答失败仍显示真实回执，显式重试不重复保存', async () => {
    const content = `回答失败-${randomUUID()}`;
    model.complete
      .mockResolvedValueOnce(reply([content]))
      .mockResolvedValueOnce(reply([], '完整计划'))
      .mockRejectedValueOnce(
        Object.assign(new Error('lost final response'), {
          code: 'AI_SUBMISSION_UNKNOWN',
        }),
      );
    const { conversation, run } = await send('新增一条名言');
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({
      status: 'submissionUnknown',
    });
    const messages = (await store.messages(actor, conversation.id)) as {
      items: Array<{ cards: Array<{ type: string }> }>;
    };
    expect(
      messages.items.some((message) =>
        message.cards.some((card) => card.type === 'result'),
      ),
    ).toBe(true);
    model.complete.mockResolvedValueOnce(reply([], '已核实保存结果'));
    const retry = (await store.retry(actor, run.id)) as { id: string };
    await runner.tick();
    expect(await store.run(actor, retry.id)).toMatchObject({
      status: 'succeeded',
    });
    expect(
      await prisma.quote.count({ where: { userId: actor.sub, content } }),
    ).toBe(1);
    expect(
      await prisma.mcpAction.count({
        where: { sourceId: run.taskId, status: 'succeeded' },
      }),
    ).toBe(1);
  });

  it('只读任务即使模型返回越权写调用也不能产生业务动作', async () => {
    const content = `注入被拒-${randomUUID()}`;
    model.complete.mockResolvedValueOnce(reply([content]));
    const { run } = await send('查询时间记录并总结');
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({ status: 'failed' });
    expect(
      await prisma.mcpAction.count({ where: { sourceId: run.taskId } }),
    ).toBe(0);
    expect(await prisma.quote.count({ where: { content } })).toBe(0);
    const request = model.complete.mock.calls[0]![2];
    expect(
      request.tools.some((tool) => tool.name === 'create_time_entry'),
    ).toBe(false);
  });

  it('本次用户消息身份固定；修订撤回记忆要求后旧记住指令不能保存', async () => {
    const first = reply();
    first.functionCalls = [
      {
        id: randomUUID(),
        callId: randomUUID(),
        name: 'ask_user',
        arguments: { question: '要记住多久？' },
      },
    ];
    first.output = first.functionCalls.map((call) => ({
      type: 'function_call',
      id: call.id,
      call_id: call.callId,
      name: call.name,
      arguments: JSON.stringify(call.arguments),
    }));
    model.complete.mockResolvedValueOnce(first);
    const { conversation, run } = await send('记住我喜欢简短回答');
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({
      status: 'waitingInput',
    });
    const memory = reply();
    memory.functionCalls = [
      {
        id: randomUUID(),
        callId: randomUUID(),
        name: 'save_memory',
        arguments: { content: '喜欢简短回答' },
      },
    ];
    memory.output = memory.functionCalls.map((call) => ({
      type: 'function_call',
      id: call.id,
      call_id: call.callId,
      name: call.name,
      arguments: JSON.stringify(call.arguments),
    }));
    model.complete.mockResolvedValueOnce(memory);
    const revised = (await store.send(actor, conversation.id, {
      clientMessageId: randomUUID(),
      content: '不要记住，先回答问题即可',
    })) as { id: string };
    const state = (
      await prisma.assistantRun.findUniqueOrThrow({ where: { id: revised.id } })
    ).state as { userMessageId: string };
    expect(
      await prisma.assistantMessage.findUnique({
        where: { id: state.userMessageId },
      }),
    ).toMatchObject({
      content: '不要记住，先回答问题即可',
      taskId: run.taskId,
    });
    await runner.tick();
    expect(await store.run(actor, revised.id)).toMatchObject({
      status: 'failed',
    });
    expect(
      await prisma.assistantMemory.count({
        where: { userId: actor.sub, content: '喜欢简短回答' },
      }),
    ).toBe(0);
    const request = model.complete.mock.calls[1]![2];
    expect(request.tools.some((tool) => tool.name === 'save_memory')).toBe(
      false,
    );
  });

  it('九步任务先完整回滚预演，确认后按八加一执行且不可通用撤销', async () => {
    // 单次登记完整任务，不能以工具次数限制为理由提前保存前八项。
    const contents = Array.from(
      { length: 9 },
      (_unused, index) => `分批${index}-${randomUUID()}`,
    );
    const first = reply();
    const call = {
      id: randomUUID(),
      callId: randomUUID(),
      name: 'stage_changes',
      arguments: {
        steps: contents.map((content) => ({
          name: 'create_quote',
          input: { content },
        })),
      },
    };
    first.functionCalls = [call];
    first.output = [
      {
        type: 'function_call',
        id: call.id,
        call_id: call.callId,
        name: call.name,
        arguments: JSON.stringify(call.arguments),
      },
    ];
    model.complete
      .mockResolvedValueOnce(first)
      .mockResolvedValueOnce(reply([], '完整计划'))
      .mockResolvedValueOnce(reply([], '九项已保存'));
    const { run } = await send('添加九条名言');
    await runner.tick();
    const paused = (await store.run(actor, run.id)) as {
      status: string;
      plan: {
        id: string;
        version: number;
        previewHash: string;
        targetCount: number;
        preview: { batchCount: number };
      };
    };
    expect(paused).toMatchObject({
      status: 'waitingConfirmation',
      plan: { targetCount: 9, preview: { batchCount: 2 } },
    });
    expect(
      await prisma.quote.count({ where: { content: { in: contents } } }),
    ).toBe(0);
    expect(
      await prisma.mcpAction.count({ where: { sourceId: run.taskId } }),
    ).toBe(0);
    await store.decision(actor, paused.plan.id, {
      version: paused.plan.version,
      previewHash: paused.plan.previewHash,
      decision: 'confirm',
    });
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({
      status: 'succeeded',
      canUndo: false,
    });
    expect(
      await prisma.quote.count({ where: { content: { in: contents } } }),
    ).toBe(9);
    expect(
      await prisma.mcpAction.count({
        where: { sourceId: run.taskId, status: 'succeeded' },
      }),
    ).toBe(2);
    const state = (
      await prisma.assistantRun.findUniqueOrThrow({ where: { id: run.id } })
    ).state as { result: { completedBatches: number; totalBatches: number } };
    expect(state.result).toMatchObject({
      completedBatches: 2,
      totalBatches: 2,
    });
  });

  it('分批之间出现外部写入会停止，已经完成的八项不会回滚', async () => {
    const contents = Array.from(
      { length: 9 },
      (_unused, index) => `中断分批${index}-${randomUUID()}`,
    );
    const first = reply();
    const call = {
      id: randomUUID(),
      callId: randomUUID(),
      name: 'stage_changes',
      arguments: {
        steps: contents.map((content) => ({
          name: 'create_quote',
          input: { content },
        })),
      },
    };
    first.functionCalls = [call];
    first.output = [
      {
        type: 'function_call',
        id: call.id,
        call_id: call.callId,
        name: call.name,
        arguments: JSON.stringify(call.arguments),
      },
    ];
    model.complete
      .mockResolvedValueOnce(first)
      .mockResolvedValueOnce(reply([], '完整计划'));
    const { run } = await send('添加九条名言');
    await runner.tick();
    const paused = (await store.run(actor, run.id)) as {
      plan: { id: string; version: number; previewHash: string };
    };
    await store.decision(actor, paused.plan.id, {
      version: paused.plan.version,
      previewHash: paused.plan.previewHash,
      decision: 'confirm',
    });
    // 在真实第一批提交后模拟另一设备修改，不能用下一批的新预览覆盖它。
    const batch = module.get(AssistantBatchService);
    const original = batch.commitNext.bind(batch);
    const spy = jest
      .spyOn(batch, 'commitNext')
      .mockImplementation(async (...args) => {
        const result = await original(...args);
        if (!result.done) {
          const record = await prisma.quote.findFirstOrThrow({
            where: { content: contents[0] },
          });
          await prisma.quote.update({
            where: { id: record.id },
            data: { content: `${contents[0]}-其他设备修改` },
          });
        }
        return result;
      });
    try {
      await runner.tick();
    } finally {
      spy.mockRestore();
    }
    expect(await store.run(actor, run.id)).toMatchObject({ status: 'failed' });
    expect(
      await prisma.quote.count({
        where: { content: { in: contents.slice(1) } },
      }),
    ).toBe(7);
    expect(await prisma.quote.count({ where: { content: contents[8] } })).toBe(
      0,
    );
    expect(
      await prisma.mcpAction.count({
        where: { sourceId: run.taskId, status: 'succeeded' },
      }),
    ).toBe(1);
  });

  it('明确记住可完成整轮回复；删除记忆同时排除真实来源并废弃派生上下文', async () => {
    const content = `回答偏好-${randomUUID()}：喜欢简短回答`;
    const memoryResponse = reply();
    memoryResponse.functionCalls = [
      {
        id: randomUUID(),
        callId: randomUUID(),
        name: 'save_memory',
        arguments: { content, category: 'preference' },
      },
    ];
    memoryResponse.output = memoryResponse.functionCalls.map((call) => ({
      type: 'function_call',
      id: call.id,
      call_id: call.callId,
      name: call.name,
      arguments: JSON.stringify(call.arguments),
    }));
    model.complete
      .mockResolvedValueOnce(memoryResponse)
      .mockResolvedValueOnce(reply([], '已记住'))
      .mockResolvedValueOnce(reply([], '已保存这个回答偏好'));
    const { run } = await send(`记住${content}`);
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({
      status: 'succeeded',
    });
    const savedRun = await prisma.assistantRun.findUniqueOrThrow({
      where: { id: run.id },
    });
    const memory = await prisma.assistantMemory.findFirstOrThrow({
      where: { userId: actor.sub, content },
    });
    expect(memory.sourceMessageId).toBe(
      (savedRun.state as { userMessageId: string }).userMessageId,
    );
    expect(
      await prisma.mcpAction.count({ where: { sourceId: run.taskId } }),
    ).toBe(0);
    await store.deleteMemory(actor, memory.id);
    expect(
      await prisma.assistantMemory.findUnique({ where: { id: memory.id } }),
    ).toBeNull();
    expect(
      await prisma.assistantMessage.findUnique({
        where: { id: memory.sourceMessageId! },
      }),
    ).toMatchObject({ excluded: true });
    expect(
      await prisma.assistantRun.findUnique({ where: { id: run.id } }),
    ).toMatchObject({ state: { memoryInvalidated: true } });
    expect(
      await prisma.assistantAttempt.findMany({ where: { runId: run.id } }),
    ).toEqual(
      expect.arrayContaining([expect.objectContaining({ response: null })]),
    );
  });

  it('完整灾备脚本保留业务和聊天，但关闭助手、旧设备及未执行授权并清空图指针', async () => {
    const { run } = await send('新增一条待恢复后重新确认的名言');
    const counts = {
      business: await prisma.quote.count(),
      messages: await prisma.assistantMessage.count(),
      receipts: await prisma.mcpAction.count({
        where: { status: 'succeeded' },
      }),
    };
    const bearer = await token(actor);
    // 仅在本套拥有清理权的隔离库执行，绝不对真实连接执行恢复脚本。
    await database.query(
      readFileSync(
        join(__dirname, '../../../deploy/assistant-restore-safety.sql'),
        'utf8',
      ),
    );
    expect(
      await prisma.assistantSettings.findUnique({
        where: { userId: actor.sub },
      }),
    ).toMatchObject({ enabled: false });
    expect(
      await prisma.assistantRun.findUnique({ where: { id: run.id } }),
    ).toMatchObject({
      status: 'cancelled',
      errorCode: 'ASSISTANT_RESTORE_INVALIDATED',
    });
    expect(await prisma.deviceSession.count()).toBe(0);
    expect(await prisma.quote.count()).toBe(counts.business);
    expect(await prisma.assistantMessage.count()).toBe(counts.messages);
    expect(
      await prisma.mcpAction.count({ where: { status: 'succeeded' } }),
    ).toBe(counts.receipts);
    expect(
      Number(
        (
          await database.query<{ count: string }>(
            'SELECT COUNT(*) FROM assistant_graph.checkpoints',
          )
        ).rows[0]!.count,
      ),
    ).toBe(0);
    expect(
      (
        await fetch(`${baseUrl}/settings`, {
          headers: { Authorization: `Bearer ${bearer}` },
        })
      ).status,
    ).toBe(401);
  });
});
