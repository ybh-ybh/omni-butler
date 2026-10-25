import { Test, type TestingModule } from '@nestjs/testing';
import { ConfigModule, ConfigService } from '@nestjs/config';
import type { INestApplication } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';
import { AssistantModule } from '../src/assistant/assistant.module';
import { AssistantAttachmentsService } from '../src/assistant/attachments/assistant-attachments.service';
import { AssistantStore } from '../src/assistant/assistant-store.service';
import { AssistantRunner } from '../src/assistant/assistant-runner.service';
import { AssistantBatchService } from '../src/assistant/assistant-batch.service';
import { assistantJson } from '../src/assistant/assistant.types';
import { AssistantModelProvider } from '../src/ai/assistant-model.provider';
import { AiService } from '../src/ai/ai.service';
import type { AiKeyStore } from '../src/ai/ai-key-store';
import type { AiProvider } from '../src/ai/ai-provider';
import { assistantCompatibility } from '../src/ai/assistant-model-policy';
import type {
  AssistantModelResult,
  AssistantModelRequest,
  AssistantProfileSnapshot,
} from '../src/ai/assistant-model.types';
import { PrismaService } from '../src/prisma/prisma.service';
import { Prisma } from '../src/generated/prisma/client';
import { TodoRecurrenceService } from '../src/business/todo-recurrence.service';
import type { AuthUser } from '../src/auth/auth.types';
import { ActionExecutor } from '../src/mcp/action-executor';

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
      MINIO_ENDPOINT: process.env.OMNI_ASSISTANT_TEST_MINIO_ENDPOINT,
      MINIO_CREDENTIALS_FILE: process.env.OMNI_ASSISTANT_TEST_MINIO_CREDENTIALS_FILE,
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
          thinkingEnabled: profile.thinkingEnabled,
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

  it('真实迁移默认关闭多模态，保存开关持久生效且旧探测结果不能覆盖', async () => {
    // 此用例使用正式配置服务，仅替换不会调用的密钥和供应商依赖。
    const ai = new AiService(prisma, {} as AiKeyStore, {} as AiProvider);
    // 既有创建语句省略开关，由真实迁移中的数据库默认值决定。
    const profile = await prisma.aiProfile.findUniqueOrThrow({ where: { id: profileId } });
    expect(profile.multimodal).toBe(false);
    // 伪造此前通过的图片探测事实，不能自动给关闭的配置放行。
    await prisma.aiProfile.update({ where: { id: profileId }, data: { assistantCapabilities: { revision: profile.revision, compatibility: { ...assistantCompatibility(), imageInput: 'supported' } } } });
    expect((await ai.captureAssistantProfile(actor.sub, profileId)).compatibility?.imageInput).toBe('unsupported');
    // 保存请求沿用正式设置修订以及当前同归属配置。
    let settings = await ai.settings(actor.sub);
    try {
      // 每次保存都重新读取持久值和助手能力，不能只检查请求体。
      for (const multimodal of [true, false]) {
        settings = await ai.saveProfile(actor.sub, { revision: settings.revision, name: profile.name, provider: profile.provider, model: profile.model, baseUrl: profile.baseUrl, multimodal }, profileId);
        expect(settings.profiles.find((entry) => entry.id === profileId)?.multimodal).toBe(multimodal);
        expect((await prisma.aiProfile.findUniqueOrThrow({ where: { id: profileId } })).multimodal).toBe(multimodal);
        expect((await ai.captureAssistantProfile(actor.sub, profileId)).compatibility?.imageInput).toBe(multimodal ? 'supported' : 'unsupported');
        if (multimodal) await expect(ai.assertAssistantProfileAvailable(actor.sub, { profileId, profileRevision: profile.revision, provider: profile.provider, model: profile.model, baseUrl: profile.baseUrl, encryptedApiKey: profile.encryptedApiKey! }, true)).resolves.toBeUndefined();
        else await expect(ai.assertAssistantProfileAvailable(actor.sub, { profileId, profileRevision: profile.revision, provider: profile.provider, model: profile.model, baseUrl: profile.baseUrl, encryptedApiKey: profile.encryptedApiKey! }, true)).rejects.toMatchObject({ code: 'AI_IMAGE_INPUT_UNSUPPORTED' });
        // 助手设置接口同样从数据库开关投影，不受旧回执影响。
        const assistant = await store.settings(actor) as { profiles: Array<{ id: string; multimodal: boolean; capabilities: { imageInput: string } }> };
        expect(assistant.profiles.find((entry) => entry.id === profileId)).toMatchObject({ multimodal, capabilities: { imageInput: multimodal ? 'supported' : 'unsupported' } });
      }
      await expect(ai.saveProfile(other.sub, { revision: 0, name: profile.name, provider: profile.provider, model: profile.model, baseUrl: profile.baseUrl, multimodal: true }, profileId)).rejects.toMatchObject({ response: { code: 'AI_PROFILE_NOT_FOUND' } });
    } finally {
      await prisma.aiProfile.update({ where: { id: profileId }, data: { multimodal: false, assistantCapabilities: Prisma.JsonNull } });
    }
  });

  it.each([false, true])('旧客户端vision测试参数不会改变多模态%s或执行第三轮图像探测', async (multimodal) => {
    await prisma.aiProfile.update({ where: { id: profileId }, data: { multimodal } });
    model.testCapability.mockReset();
    model.testCapability.mockResolvedValue({ ok: true, message: '文本工具测试成功', capabilities: { version: 1, streaming: true, functionCalling: true, imageInput: 'supported' } });
    try {
      // 真实JWT/HTTP入口兼容旧字段，但只向文本工具测试传两个参数。
      const response = await fetch(`${baseUrl}/test`, { method: 'POST', headers: { authorization: `Bearer ${await token(actor)}`, 'content-type': 'application/json' }, body: JSON.stringify({ profileId, vision: true }) });
      expect(response.status).toBe(201);
      expect(model.testCapability).toHaveBeenCalledTimes(1);
      expect(model.testCapability.mock.calls[0]).toHaveLength(2);
      expect((await prisma.aiProfile.findUniqueOrThrow({ where: { id: profileId } })).multimodal).toBe(multimodal);
      expect((await prisma.aiProfile.findUniqueOrThrow({ where: { id: profileId } })).assistantCapabilities).toBeNull();
    } finally {
      await prisma.aiProfile.update({ where: { id: profileId }, data: { multimodal: false } });
      model.testCapability.mockReset();
    }
  });

  it('真实迁移默认关闭思考，新配置保存及任务快照按明确开关取值', async () => {
    // 正式配置领域服务不启动队列或请求模型。
    const ai = new AiService(prisma, {} as AiKeyStore, {} as AiProvider);
    // 初始SQL创建配置时省略字段，实际数据库默认值必须是false。
    const profile = await prisma.aiProfile.findUniqueOrThrow({ where: { id: profileId } });
    expect(profile.thinkingEnabled).toBe(false);
    // 独立任务表也固定旧任务的关闭默认值，不跟随配置变化。
    const columns = await database.query("SELECT column_default, is_nullable FROM information_schema.columns WHERE table_name='note_polish_jobs' AND column_name='thinking_enabled'");
    expect(columns.rows).toEqual([{ column_default: 'false', is_nullable: 'NO' }]);
    // 模型配置与助手运行快照都必须保存真实的用户选择。
    let settings = await ai.settings(actor.sub);
    try {
      for (const thinkingEnabled of [true, false]) {
        settings = await ai.saveProfile(actor.sub, { revision: settings.revision, name: profile.name, provider: profile.provider, baseUrl: profile.baseUrl, model: profile.model, thinkingEnabled }, profileId);
        expect(settings.profiles.find((item) => item.id === profileId)?.thinkingEnabled).toBe(thinkingEnabled);
        expect((await ai.captureAssistantProfile(actor.sub, profileId)).thinkingEnabled).toBe(thinkingEnabled);
        // 创建后不执行worker，以确认持久任务已经固定该模式且不会计费。
        const task = await send('验证思考快照');
        expect((await prisma.assistantRun.findUniqueOrThrow({ where: { id: task.run.id } })).profileSnapshot).toMatchObject({ thinkingEnabled });
        await store.stop(actor, task.run.id);
      }
    } finally {
      await prisma.aiProfile.update({ where: { id: profileId }, data: { thinkingEnabled: false } });
    }
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

  /// 大步骤和中文正文直接写入独占测试库，避免把写工具限制混入列表回归。
  const createTodoQueryFixture = async (): Promise<{
    query: string;
    heavyId: string;
    expectedIds: string[];
    foreignId: string;
  }> => {
    // 唯一前缀隔离同一套集成测试中的其他待办。
    const query = `待办查询-${randomUUID()}`;
    // 长中文标题按实际 UTF-8 字节触发摘要分页上限。
    const rows = Array.from({ length: 80 }, (_, index) => ({
      id: randomUUID(),
      userId: actor.sub,
      title: `${query}-${index}-${'紧急事项'.repeat(50)}`.slice(0, 200),
      taskType: index === 0 ? 'progress' : 'normal',
      description: index === 0 ? '原始详情'.repeat(25000) : null,
      scheduledDate: new Date('2026-10-24T00:00:00Z'),
      priorityQuadrant: 3,
      sortOrder: index,
      isCompleted: false,
    }));
    await prisma.todoItem.createMany({ data: rows });
    // 排序靠前的其他象限、已完成项及他人记录都不得挤占筛选后的首屏。
    const foreignId = randomUUID();
    await prisma.todoItem.createMany({
      data: [
        ...[0, 1, 2].map((priorityQuadrant) => ({
          id: randomUUID(),
          userId: actor.sub,
          title: `${query}-其他象限${priorityQuadrant}`,
          scheduledDate: new Date('2026-10-01T00:00:00Z'),
          priorityQuadrant,
        })),
        {
          id: randomUUID(),
          userId: actor.sub,
          title: `${query}-已完成`,
          scheduledDate: new Date('2026-10-01T00:00:00Z'),
          priorityQuadrant: 3,
          isCompleted: true,
        },
        {
          id: foreignId,
          userId: other.sub,
          title: `${query}-其他用户`,
          scheduledDate: new Date('2026-10-01T00:00:00Z'),
          priorityQuadrant: 3,
        },
      ],
    });
    await prisma.todoProgressStep.createMany({
      data: Array.from({ length: 1000 }, (_, index) => ({
        id: randomUUID(),
        userId: actor.sub,
        todoId: rows[0]!.id,
        name: `步骤${index}-${'待办执行说明'.repeat(20)}`.slice(0, 200),
        sortOrder: index,
        isCompleted: index < 300,
      })),
    });
    return {
      query,
      heavyId: rows[0]!.id,
      expectedIds: rows.map((row) => row.id),
      foreignId,
    };
  };

  it('千步骤待办经过真实助手入口保持16KiB分页、象限筛选及MCP完整输出兼容', async () => {
    // 业务读取和归属校验使用真实执行器，不替换数据库查询。
    const actions = module.get(ActionExecutor);
    // 相同数据同时覆盖大记录、筛选前分页及外部协议兼容。
    const fixture = await createTodoQueryFixture();
    // 助手读取身份来自已签发设备，与模型参数严格分开。
    const context = {
      source: 'assistant' as const,
      taskId: randomUUID(),
      runId: randomUUID(),
      actor,
      timeZone: 'Asia/Shanghai',
    };
    // 显式结构仅用于验证 JSON 投影与下一页事实。
    type Page = {
      items: Array<{
        id: string;
        title: string;
        priorityQuadrant: number;
        progress: { total: number; completed: number };
        description?: string;
        progressSteps?: unknown[];
        updatedAt?: string;
      }>;
      hasMore: boolean;
      nextOffset: number | null;
      returnedCount: number;
      stepsSummarized: boolean;
      truncated: boolean;
    };
    // 请求大页仍必须根据实际交付数量前进，不越过被预算裁掉的记录。
    const input = {
      query: fixture.query,
      completed: false,
      priorityQuadrant: 3,
      limit: 200,
      offset: 0,
    };
    // 完整遍历检查实际 SQL 筛选后不会漏项、重复或泄露他人记录。
    const ids: string[] = [];
    // 游标仅从上一页实际交付结果推进。
    let offset = 0;
    // 保留硬边界，分页错误不能让测试无限循环。
    let pages = 0;
    do {
      // 每一页都重新通过真实会话授权，不绕过 ActionExecutor。
      const page = (await actions.read(context, 'list_todos', {
        ...input,
        offset,
      })) as unknown as Page;
      expect(Buffer.byteLength(JSON.stringify(page), 'utf8')).toBeLessThanOrEqual(
        16 * 1024,
      );
      expect(page.stepsSummarized).toBe(true);
      expect(page.returnedCount).toBe(page.items.length);
      expect(page.items.length).toBeGreaterThan(0);
      expect(page.items.every((item) => item.priorityQuadrant === 3)).toBe(true);
      expect(
        page.items.every(
          (item) =>
            item.description === undefined &&
            item.progressSteps === undefined &&
            item.updatedAt === undefined,
        ),
      ).toBe(true);
      if (pages === 0) {
        expect(page.truncated).toBe(true);
        expect(page.items[0]).toMatchObject({
          id: fixture.heavyId,
          progress: { total: 1000, completed: 300 },
        });
      }
      ids.push(...page.items.map((item) => item.id));
      pages++;
      expect(pages).toBeLessThan(10);
      expect(page.nextOffset).toBe(
        page.hasMore ? offset + page.items.length : null,
      );
      if (!page.hasMore) break;
      offset = page.nextOffset!;
    } while (pages < 10);
    expect(pages).toBeGreaterThan(1);
    expect(ids).toEqual(fixture.expectedIds);
    expect(new Set(ids).size).toBe(80);
    expect(ids).not.toContain(fixture.foreignId);
    // 换成另一真实设备身份后只可读取其自己的同名资料。
    const foreign = (await actions.read(
      { ...context, actor: other },
      'list_todos',
      input,
    )) as unknown as Page;
    expect(foreign.items.map((item) => item.id)).toEqual([fixture.foreignId]);
    // 外部连接沿用完整详情，新增过滤参数不会改变旧结果字段。
    const connection = await prisma.mcpConnection.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        name: '隔离待办协议兼容连接',
        tokenHash: randomUUID().replaceAll('-', '').padEnd(64, '0'),
        sessionId: actor.sid,
        readModules: ['todos'],
        writeModules: [],
        timeZone: 'Asia/Shanghai',
      },
    });
    // 不带新增参数的旧请求仍返回原始正文和全部步骤。
    const legacy = (await actions.read(connection.id, 'list_todos', {
      query: fixture.query,
      completed: false,
      limit: 200,
    })) as unknown as {
      items: Array<{ id: string; description: string; progressSteps: unknown[] }>;
    };
    expect(legacy.items).toHaveLength(83);
    expect(legacy.items.find((item) => item.id === fixture.heavyId)).toMatchObject({
      description: '原始详情'.repeat(25000),
      progressSteps: expect.any(Array),
    });
    expect(
      legacy.items.find((item) => item.id === fixture.heavyId)?.progressSteps,
    ).toHaveLength(1000);
    expect(JSON.stringify(legacy).length).toBeGreaterThan(80000);
    // 象限零值必须进入数据库条件，不能误当成省略参数。
    const quadrantZero = (await actions.read(context, 'list_todos', {
      query: fixture.query,
      priorityQuadrant: 0,
      limit: 1,
    })) as unknown as Page;
    expect(quadrantZero.items).toHaveLength(1);
    expect(quadrantZero.items[0]!.priorityQuadrant).toBe(0);
    await expect(
      actions.read(context, 'list_todos', { priorityQuadrant: 4 }),
    ).rejects.toThrow();
  }, 30000);

  it('真实查询循环在8次只读上限后回答已读范围，保留分页事实且不产生业务写入', async () => {
    // 大结果真实经过业务读取，模拟供应商只负责复现重复缩页的决策序列。
    const fixture = await createTodoQueryFixture();
    // 记录实际进入供应商的快照，避免后续 state 修改影响证据。
    const requests: Array<{
      toolChoice: AssistantModelRequest['toolChoice'];
      input: Record<string, unknown>[];
    }> = [];
    // 使用截图中的递减页大小和反复第一页模式。
    const limits = [200, 50, 20, 5, 5, 5, 5, 5];
    // 后半段真实读取后续范围，使持久状态包含可核对的 nextOffset。
    const offsets = [0, 0, 0, 0, 5, 10, 15, 20];
    // 仅模型网络模拟，业务执行、任务租约和 checkpoint 都使用实际实现。
    model.complete.mockImplementation(async (_user, _profile, request) => {
      // 序号在加入快照前固定，避免复用变动的调用身份。
      const index = requests.length;
      requests.push({
        toolChoice: request.toolChoice,
        input: structuredClone(request.input),
      });
      if (index >= 8) {
        expect(request.toolChoice).toBe('none');
        expect(JSON.stringify(request.input)).toContain(fixture.heavyId);
        await request.onDelta?.('根据已读取范围，存在重要紧急待办。');
        return reply([], '根据已读取范围，存在重要紧急待办。');
      }
      // 供应商完整 function_call 项与 call_id 成对回传，避免测试隐藏协议错误。
      const call = {
        id: randomUUID(),
        callId: randomUUID(),
        name: 'list_todos',
        arguments: {
          query: fixture.query,
          priorityQuadrant: 3,
          completed: false,
          limit: limits[index],
          offset: offsets[index],
        },
      };
      return {
        ...reply(),
        text: '',
        functionCalls: [call],
        output: [
          {
            type: 'function_call',
            id: call.id,
            call_id: call.callId,
            name: call.name,
            arguments: JSON.stringify(call.arguments),
          },
        ],
      };
    });
    // 前后业务事实完全相同，查询恢复不能偷偷修改记录或步骤。
    const before = {
      todos: await prisma.todoItem.count(),
      steps: await prisma.todoProgressStep.count(),
      quotes: await prisma.quote.count(),
      memories: await prisma.assistantMemory.count(),
    };
    // 任务只要求查询，不能借预算收尾进入写计划。
    const { conversation, run } = await send('帮我看一下重要紧急的任务有哪些');
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({ status: 'succeeded' });
    expect(model.complete).toHaveBeenCalledTimes(9);
    expect(requests.at(-1)?.toolChoice).toBe('none');
    // 数据库状态保留八个已读范围，压缩后的模型资料仍可知道实际查询进度。
    const saved = await prisma.assistantRun.findUniqueOrThrow({
      where: { id: run.id },
    });
    // 这里只断言对外行为所依赖的持久事实，不复制生产查询记录生成逻辑。
    const state = saved.state as unknown as {
      toolCount: number;
      readLimit: string;
      readProgress: Array<{
        filters: { query: string; priorityQuadrant: number; completed: boolean };
        requested: { offset: number; limit: number };
        returnedCount: number;
        nextOffset: number | null;
        items: Array<{ id: string }>;
        itemsOmitted?: boolean;
      }>;
      executionSteps: Array<{ kind: string; status: string; detail?: string }>;
    };
    expect(state.toolCount).toBe(8);
    expect(state.readLimit).toBe('ASSISTANT_TOOL_LIMIT');
    expect(state.readProgress).toHaveLength(8);
    expect(state.readProgress[7]).toMatchObject({
      filters: { query: fixture.query, priorityQuadrant: 3, completed: false },
      requested: { offset: 20, limit: 5 },
      returnedCount: 5,
      nextOffset: 25,
    });
    expect(
      state.readProgress.some((page) =>
        page.items.some((item) => item.id === fixture.heavyId),
      ),
    ).toBe(true);
    expect(state.readProgress.some((page) => page.itemsOmitted)).toBe(true);
    expect(
      state.executionSteps.filter((step) => step.kind === 'tool'),
    ).toHaveLength(8);
    expect(
      state.executionSteps
        .filter((step) => step.kind === 'tool')
        .every(
          (step) =>
            step.status === 'succeeded' &&
            /^已读取\d+条，进度步骤已摘要(?:，仍有后续记录)?$/.test(
              step.detail ?? '',
            ),
        ),
    ).toBe(true);
    // 回答明确已读覆盖，不再把预算用尽显示成业务冲突。
    const messages = (await store.messages(actor, conversation.id)) as {
      items: Array<{ role: string; content: string }>;
    };
    expect(
      messages.items.find((message) => message.role === 'assistant')?.content,
    ).toContain('已读取');
    expect(JSON.stringify(messages)).not.toContain('数据已发生变化');
    expect(await prisma.mcpAction.count({ where: { sourceId: run.taskId } })).toBe(
      0,
    );
    expect({
      todos: await prisma.todoItem.count(),
      steps: await prisma.todoProgressStep.count(),
      quotes: await prisma.quote.count(),
      memories: await prisma.assistantMemory.count(),
    }).toEqual(before);
  }, 30000);

  it('隐藏的六项待办草稿不会当作已交付回答，最终流与持久消息完整一致', async () => {
    // 独立前缀避免受本套测试已有待办影响，日期仅是计划日期。
    const query = `最终交付-${randomUUID()}`;
    // 六条合成记录通过真实SQL查询，查询过程不登记业务动作。
    const items = Array.from({ length: 6 }, (_value, index) => ({ id: randomUUID(), userId: actor.sub, title: `${query}-任务${index + 1}`, priorityQuadrant: 3, scheduledDate: new Date('2026-10-05T00:00:00Z'), dueAt: null, isCompleted: false }));
    await prisma.todoItem.createMany({ data: items });
    // 查询草稿与真正交付文本刻意不同，避免误拼接也能通过测试。
    const draft = `内部草稿：\n${items.map((item) => item.title).join('\n')}`;
    // 最终可见答案由模拟网络返回，真实模型表达效果需另行验收。
    const answer = `找到 6 项重要且紧急的未完成待办：\n${items.map((item) => `- ${item.title}`).join('\n')}`;
    // 记录三次真实调度请求，第一轮工具、第二轮草稿、第三轮最终流式回答。
    const requests: AssistantModelRequest[] = [];
    model.complete.mockImplementation(async (_user, _profile, request) => {
      requests.push({ ...request, input: structuredClone(request.input) });
      await request.onReasoning?.({ text: `公开思考第${requests.length}轮：核对任务并组织回答。` });
      if (requests.length === 1) {
        // 调用身份由供应商完整输出产生，工具结果仍走现有协议配对。
        const call = { id: randomUUID(), callId: randomUUID(), name: 'list_todos', arguments: { query, priorityQuadrant: 3, completed: false } };
        return { ...reply(), text: '', functionCalls: [call], output: [{ type: 'function_call', id: call.id, call_id: call.callId, name: call.name, arguments: JSON.stringify(call.arguments) }] };
      }
      if (requests.length === 2) {
        expect(request.toolChoice).toBe('auto');
        expect(request.onDelta).toBeUndefined();
        for (const item of items) expect(JSON.stringify(request.input)).toContain(item.id);
        return reply([], draft);
      }
      expect(requests).toHaveLength(3);
      expect(request.toolChoice).toBe('none');
      expect(request.instructions).toContain('当前任务查询阶段生成的模型正文尚未向用户展示');
      expect(request.instructions).toContain('必须重新给出用户所问的具体结果');
      expect(request.instructions).not.toContain('明确覆盖范围及推测');
      expect(request.input).toContainEqual({ role: 'assistant', content: draft });
      for (const part of [answer.slice(0, 15), answer.slice(15)]) await request.onDelta?.(part);
      return reply([], answer);
    });
    // 新运行与消息固定身份，后台执行和事件落库都由生产实现完成。
    const { conversation, run } = await send('帮我看一下重要紧急的任务有哪些');
    await runner.tick();
    expect(await store.run(actor, run.id)).toMatchObject({ status: 'succeeded' });
    expect(model.complete).toHaveBeenCalledTimes(3);
    // 终态只有一条助手回答，原始隐藏草稿仍可在付费回执中审计。
    const messages = await prisma.assistantMessage.findMany({ where: { taskId: run.taskId, role: 'assistant' } });
    expect(messages).toHaveLength(1);
    expect(messages[0]!.conversationId).toBe(conversation.id);
    expect(messages[0]!.content).toBe(answer);
    expect(messages[0]!.cards).toEqual([expect.objectContaining({ type: 'references', referencesTruncated: false, entityRefs: expect.any(Array) })]);
    // SSE持久事件与数据库正文完全一致，不能把内部草稿算作已交付。
    const events = await prisma.assistantEvent.findMany({ where: { runId: run.id, type: 'message.delta' }, orderBy: { seq: 'asc' } });
    expect(events.map((event) => (event.data as { text: string }).text).join('')).toBe(answer);
    expect(events.map((event) => JSON.stringify(event.data)).join('')).not.toContain('内部草稿');
    expect(await prisma.assistantAttempt.findUnique({ where: { runId_ordinal: { runId: run.id, ordinal: 2 } } })).toMatchObject({ response: { text: draft } });
    // 真正持久事件、历史消息和工具执行链都包含同一公开思考，而正文仍只有答案。
    const history = await store.messages(actor, conversation.id) as { items: Array<{ role: string; content: string; executionSteps: unknown[] }> };
    expect(JSON.stringify(history.items.find((item) => item.role === 'assistant')?.executionSteps)).toContain('公开思考第1轮');
    expect(JSON.stringify(history.items.find((item) => item.role === 'assistant')?.executionSteps)).toContain('公开思考第3轮');
    expect(JSON.stringify(await store.events(actor, run.id, 0))).toContain('公开思考第1轮');
    expect(history.items.find((item) => item.role === 'assistant')?.content).toBe(answer);
    expect(await prisma.mcpAction.count({ where: { sourceId: run.taskId } })).toBe(0);
    expect(await prisma.todoItem.count({ where: { id: { in: items.map((item) => item.id) } } })).toBe(6);
  }, 30000);

  it('迁移仅从合法旧状态回填稳定回答身份，已遗忘或损坏关联保持未知', async () => {
    // 回填用例运行在本套独占隔离空库，使用实际迁移中的 UPDATE。
    const conversation = (await store.createConversation(actor, {})) as {
      id: string;
    };
    // 唯一合法回答身份作为回填结果证据。
    const answerMessageId = randomUUID();
    // 对照行分别模拟合法、格式损坏及已遗忘的旧状态。
    const runs = [
      { messageId: answerMessageId },
      { messageId: 'invalid-uuid' },
      { memoryInvalidated: true },
    ].map((state) => ({
      id: randomUUID(),
      userId: actor.sub,
      conversationId: conversation.id,
      taskId: randomUUID(),
      sessionId: actor.sid,
      status: 'cancelled',
      profileSnapshot: {},
      state,
    }));
    await prisma.assistantRun.createMany({ data: runs });
    // 取实际迁移语句验证数据修复，不复制另一套回填实现。
    const migration = readFileSync(
      join(
        __dirname,
        '../prisma/migrations/20261023020000_assistant_desktop/migration.sql',
      ),
      'utf8',
    );
    // 此正则只提取受版本管理的固定 SQL，不接收请求输入。
    const backfill = migration.match(/^UPDATE[\s\S]+?;/m)?.[0];
    expect(backfill).toBeDefined();
    await database.query(backfill!);
    expect(
      await prisma.assistantRun.findUnique({ where: { id: runs[0]!.id } }),
    ).toMatchObject({ answerMessageId });
    expect(
      await prisma.assistantRun.findUnique({ where: { id: runs[1]!.id } }),
    ).toMatchObject({ answerMessageId: null });
    expect(
      await prisma.assistantRun.findUnique({ where: { id: runs[2]!.id } }),
    ).toMatchObject({ answerMessageId: null });
  });

  it('正文及标题搜索保持字面匹配、归属隔离、稳定分页和旧接口兼容', async () => {
    // 唯一词避免此前测试数据影响搜索证据。
    const needle = `搜索_${randomUUID()}%\\`;
    // 同毫秒记录强制使用 UUID 作为跨页第二排序键。
    const updatedAt = new Date('2026-10-01T00:00:00Z');
    // 前一项仅标题命中，其余通过正文命中同一查询。
    const conversations = Array.from({ length: 105 }, (_, index) => ({
      id: randomUUID(),
      userId: actor.sub,
      title: index === 0 ? needle : `正文会话 ${index}`,
      updatedAt,
    }));
    await prisma.assistantConversation.createMany({ data: conversations });
    await prisma.assistantMessage.createMany({
      data: conversations.slice(1).flatMap((conversation) =>
        ['user', 'assistant'].map((role) => ({
          id: randomUUID(),
          userId: actor.sub,
          conversationId: conversation.id,
          taskId: randomUUID(),
          role,
          content: `正文包含 ${needle}`,
          cards: [],
        })),
      ),
    });
    // 隐藏角色、其他 owner 的正文及近似通配串都不能制造命中。
    const excluded = await prisma.assistantConversation.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        title: needle.replace('_', 'X').replace('%', 'Y'),
      },
    });
    await prisma.assistantMessage.createMany({
      data: [
        {
          id: randomUUID(),
          userId: actor.sub,
          conversationId: excluded.id,
          taskId: randomUUID(),
          role: 'system',
          content: needle,
          cards: [],
        },
        {
          id: randomUUID(),
          userId: other.sub,
          conversationId: excluded.id,
          taskId: randomUUID(),
          role: 'assistant',
          content: needle,
          cards: [],
        },
      ],
    });
    // 他人相同标题不能泄漏到当前用户搜索。
    const foreign = (await store.createConversation(other, {
      title: needle,
    })) as { id: string };
    // 查询通过真实 HTTP 参数通道传入，而不是测试直接绕过控制器。
    const response = await fetch(
      `${baseUrl}/conversations?query=${encodeURIComponent(` ${needle.toUpperCase()} `)}`,
      {
        headers: { Authorization: `Bearer ${await token(actor)}` },
      },
    );
    expect(response.status).toBe(200);
    // 首屏结果沿用原响应结构并包含置顶默认值。
    const first = (await response.json()) as {
      items: Array<{ id: string; isPinned: boolean }>;
      nextCursor: string;
    };
    expect(first.items).toHaveLength(100);
    expect(first.items.every((item) => item.isPinned === false)).toBe(true);
    // 同一关键词的下一页不能丢失或重复匹配会话。
    const next = (await store.conversations(
      actor,
      first.nextCursor,
      needle,
    )) as { items: Array<{ id: string }>; nextCursor: string | null };
    expect(next.items).toHaveLength(5);
    expect(next.nextCursor).toBeNull();
    expect(
      new Set([...first.items, ...next.items].map((item) => item.id)).size,
    ).toBe(105);
    await expect(
      store.conversations(actor, foreign.id, needle),
    ).rejects.toThrow('游标不存在');
    // 空白搜索与无查询兼容，不改变普通最近会话列表。
    expect(await store.conversations(actor, undefined, '  ')).toEqual(
      await store.conversations(actor),
    );
    // 修改仅置顶保留分页时标，标题更新仍可独立使用。
    expect(
      await store.rename(actor, conversations[0]!.id, { isPinned: true }),
    ).toMatchObject({ isPinned: true, updatedAt });
    expect(
      await store.rename(actor, conversations[0]!.id, {
        title: '改名仍保留置顶',
      }),
    ).toMatchObject({ isPinned: true, title: '改名仍保留置顶' });
    expect(
      await store.rename(actor, conversations[0]!.id, { isPinned: false }),
    ).toMatchObject({ isPinned: false });
  });

  it('一万条消息中的正文搜索返回会话并保留参数化查询边界', async () => {
    // 噪声正文与命中正文放在同会话，避免借助标题直接命中。
    const conversation = (await store.createConversation(actor, {
      title: '大历史搜索测试',
    })) as { id: string };
    // 唯一标记也覆盖单引号不能脱离 SQL 参数边界。
    const needle = `检索'OR 1=1--${randomUUID()}`;
    await prisma.assistantMessage.createMany({
      data: Array.from({ length: 10000 }, (_, index) => ({
        id: randomUUID(),
        userId: actor.sub,
        conversationId: conversation.id,
        taskId: randomUUID(),
        role: 'assistant',
        cards: [],
        content: index === 9999 ? needle : `历史正文 ${index}`,
      })),
    });
    // 测量真实数据库查询，不以测试桩推断吞吐表现。
    const started = Date.now();
    // 有界结果无需传回万条正文。
    const result = (await store.conversations(actor, undefined, needle)) as {
      items: Array<{ id: string }>;
      nextCursor: string | null;
    };
    expect(result.items.map((item) => item.id)).toEqual([conversation.id]);
    expect(result.nextCursor).toBeNull();
    console.info(`助手一万条消息正文搜索耗时 ${Date.now() - started}ms`);
  });

  it('回答完成和等待确认都在最终计时事件后收敛，重新读取保留稳定回答时长', async () => {
    model.complete.mockResolvedValue(reply([], '这是可读回答'));
    // 当前完整任务使用真实 worker 与持久事件。
    const { conversation, run } = await send('只回答一句话');
    // 在 message.completed 发出时观察终态先于 finally 的真实窗口。
    const originalEmit = store.emit.bind(store);
    // 事件中途快照只用于验证尚未结算标志，不改变生产时序。
    let pendingView:
      | {
          activeRun: { timingPending: boolean };
          items: Array<{ role: string; elapsedMs: number | null }>;
        }
      | undefined;
    // 仅观察本例运行，测试结束恢复原始发事件函数。
    const emit = jest
      .spyOn(store, 'emit')
      .mockImplementation(async (id, type, data) => {
        if (id === run.id && type === 'message.completed')
          pendingView = (await store.messages(actor, conversation.id)) as {
            activeRun: { timingPending: boolean };
            items: Array<{ role: string; elapsedMs: number | null }>;
          };
        await originalEmit(id, type, data);
      });
    try {
      await runner.tick();
    } finally {
      emit.mockRestore();
    }
    expect(await store.run(actor, run.id)).toMatchObject({
      status: 'succeeded',
    });
    expect(pendingView?.activeRun.timingPending).toBe(true);
    expect(
      pendingView?.items.find((message) => message.role === 'assistant')
        ?.elapsedMs,
    ).toBeNull();
    // 终态事件在 elapsedMs 累加及租约释放之后产生。
    const view = (await store.run(actor, run.id)) as {
      answerMessageId: string;
      elapsedMs: number;
      timingPending: boolean;
    };
    expect(view.elapsedMs).toBeGreaterThan(0);
    expect(view.timingPending).toBe(false);
    // 历史时长仅从稳定 ID 关联，不再依赖可清理状态。
    await prisma.assistantRun.update({
      where: { id: run.id },
      data: { state: { memoryInvalidated: true } },
    });
    // 已结算运行稳定身份应当保留在消息查询里。
    const history = (await store.messages(actor, conversation.id)) as {
      items: Array<{ id: string; elapsedMs: number | null }>;
    };
    expect(
      history.items.find((message) => message.id === view.answerMessageId)
        ?.elapsedMs,
    ).toBe(view.elapsedMs);
    // 独立批量任务停在等待确认，结算后的事件同样明确结束当前计时段。
    model.complete
      .mockResolvedValueOnce(reply(['计时甲', '计时乙']))
      .mockResolvedValueOnce(reply([], '计划完成'));
    // 确认等待不会被算成模型执行时间。
    const waiting = await send('新增两条名言');
    // 在 gate 已持久暂停但 finally 尚未结算的窗口模拟立即点击确认。
    const originalGate = runner.gate.bind(runner);
    // 记录确实覆盖了易竞态窗口，防止测试因无计划而空通过。
    let observedGate = false;
    // 保持真实 gate 及图中断，只注入过早确认请求。
    const gate = jest.spyOn(runner, 'gate').mockImplementation(async (id) => {
      // 真正的服务器预览由 gate 返回，不由测试重建。
      const pending = (await originalGate(id)) as {
        plan: { id: string; version: number; previewHash: string };
      } | null;
      if (id === waiting.run.id && pending) {
        observedGate = true;
        await expect(
          store.decision(actor, pending.plan.id, {
            decision: 'confirm',
            version: pending.plan.version,
            previewHash: pending.plan.previewHash,
          }),
        ).rejects.toThrow('稍后再确认');
      }
      return pending;
    });
    try {
      await runner.tick();
    } finally {
      gate.mockRestore();
    }
    expect(observedGate).toBe(true);
    expect(await store.run(actor, waiting.run.id)).toMatchObject({
      status: 'waitingConfirmation',
      timingPending: false,
    });
    // 最后一条运行事件必须对应结算后的服务器视图。
    const events = (await store.events(actor, waiting.run.id, 0)) as Array<{
      type: string;
      data: { run?: { timingPending: boolean; elapsedMs: number } };
    }>;
    expect(events.at(-1)).toMatchObject({
      type: 'run.updated',
      data: { run: { timingPending: false } },
    });
    expect(events.at(-1)!.data.run!.elapsedMs).toBeGreaterThan(0);
    // 结算完成后同一个预览可正常确认并累计下一段处理时间。
    const settled = (await store.run(actor, waiting.run.id)) as {
      elapsedMs: number;
      plan: { id: string; version: number; previewHash: string };
    };
    await store.decision(actor, settled.plan.id, {
      decision: 'confirm',
      version: settled.plan.version,
      previewHash: settled.plan.previewHash,
    });
    await runner.tick();
    // 两段之间等待确认的间隔不作为任何执行段加入计时。
    const completed = (await store.run(actor, waiting.run.id)) as {
      status: string;
      elapsedMs: number;
      timingPending: boolean;
    };
    expect(completed).toMatchObject({
      status: 'succeeded',
      timingPending: false,
    });
    expect(completed.elapsedMs).toBeGreaterThan(settled.elapsedMs);
  });

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


  (process.env.OMNI_ASSISTANT_TEST_MINIO_ENDPOINT ? it : it.skip)('真实文件经上传、解析、消息绑定及模型工具读取生成带来源回答', async () => {
    // 仅这一个用例开启独立测试MinIO，不改变其余纯文本回归的配置。
    const config = module.get(ConfigService);
    config.set('ASSISTANT_ATTACHMENTS_ENABLED', true);
    const attachments = module.get(AssistantAttachmentsService);
    const conversation = await store.createConversation(actor, {}) as { id: string };
    try {
      const fileId = randomUUID();
      const form = new FormData();
      form.append('file', new Blob(['附件中记录：本周完成三项任务。']), 'weekly.txt');
      const uploaded = await fetch(`${baseUrl}/conversations/${conversation.id}/attachments/${fileId}`, { method: 'PUT', headers: { Authorization: `Bearer ${await token(actor)}` }, body: form });
      expect(uploaded.status).toBe(200);
      await attachments.tick();
      expect(await attachments.metadata(actor, fileId)).toMatchObject({ status: 'ready' });
      const callId = randomUUID();
      model.complete.mockImplementationOnce((_user, _profile, request) => {
        expect(JSON.stringify(request.input)).toContain(fileId);
        return Promise.resolve({ ...reply(), functionCalls: [{ id: callId, callId, name: 'read_attachment', arguments: { attachmentId: fileId } }], output: [{ type: 'function_call', call_id: callId, id: callId, name: 'read_attachment', arguments: JSON.stringify({ attachmentId: fileId }) }] });
      }).mockImplementationOnce((_user, _profile, request) => {
        expect(JSON.stringify(request.input)).toContain('本周完成三项任务');
        return Promise.resolve(reply([], '文档资料已读'));
      }).mockImplementationOnce(async (_user, _profile, request) => {
        await request.onDelta?.('根据 weekly.txt 第1段，本周完成三项任务。');
        return reply([], '根据 weekly.txt 第1段，本周完成三项任务。');
      });
      const sent = await fetch(`${baseUrl}/conversations/${conversation.id}/messages`, { method: 'POST', headers: { Authorization: `Bearer ${await token(actor)}`, 'content-type': 'application/json' }, body: JSON.stringify({ clientMessageId: randomUUID(), content: '概括附件', attachmentIds: [fileId] }) });
      expect(sent.status).toBe(201);
      const run = await sent.json() as { id: string };
      await runner.tick();
      expect(await store.run(actor, run.id)).toMatchObject({ status: 'succeeded', executionSteps: expect.arrayContaining([expect.objectContaining({ label: '读取文件', detail: 'weekly.txt' })]) });
      expect(await store.messages(actor, conversation.id)).toMatchObject({ items: expect.arrayContaining([expect.objectContaining({ role: 'user', attachments: [expect.objectContaining({ id: fileId })] }), expect.objectContaining({ content: '根据 weekly.txt 第1段，本周完成三项任务。' })]) });
      // 请求账本只保留文字/引用，无图片编码与真实凭据。
      const ledger = await prisma.assistantAttemptRequest.findMany({ where: { attempt: { runId: run.id } } });
      expect(ledger).toHaveLength(3);
      expect(JSON.stringify(ledger)).not.toContain('encryptedApiKey');
    } finally {
      await store.removeConversation(actor, conversation.id);
      await prisma.assistantAttachmentGc.updateMany({ where: { userId: actor.sub }, data: { availableAt: new Date(0) } });
      await attachments.collect();
      config.set('ASSISTANT_ATTACHMENTS_ENABLED', false);
    }
  }, 60000);

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
