import { ConflictException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AiProfile, AiSettings, Prisma } from '../src/generated/prisma/client';
import { PrismaService } from '../src/prisma/prisma.service';
import { AiKeyStore } from '../src/ai/ai-key-store';
import { AiProvider } from '../src/ai/ai-provider';
import { AiProfileDto } from '../src/ai/ai.dto';
import { validate } from 'class-validator';
import { assistantCompatibility } from '../src/ai/assistant-model-policy';
import { AiService } from '../src/ai/ai.service';

/// 配置选择通过正式领域服务验证，不访问真实数据库或模型供应商。
describe('AI 首个模型配置默认选择', () => {
  // 当前测试的独立数据归属。
  const userId = randomUUID();
  // 全部配置数据均为合成夹具。
  let profiles: AiProfile[];
  // 数据库当前设置行。
  let settings: AiSettings;
  // 需要保留的配置写入边界。
  let create: jest.Mock;
  // 正式配置领域服务。
  let service: AiService;
  // 连接测试仅记录模式与已有密钥选择，不建立真实外部请求。
  let testConnection: jest.Mock;
  // 合成保存输入，不携带真实密钥。
  const input: AiProfileDto = { revision: 0, name: '测试模型', provider: 'custom', baseUrl: 'https://model.example.com/v1', model: 'test-model', apiKey: 'unit-key' };

  beforeEach(() => {
    profiles = [];
    settings = { userId, revision: 0, activeProfileId: null, notePolishEnabled: false };
    create = jest.fn(({ data }: { data: Omit<AiProfile, 'revision' | 'createdAt'> }): Promise<AiProfile> => {
      // 仅模拟数据库生成默认字段，不实现业务选择规则。
      const profile: AiProfile = { ...data, revision: 1, createdAt: new Date() };
      profiles.push(profile);
      return Promise.resolve(profile);
    });
    // 只替换事务存储边界，默认选择、修订校验均执行生产实现。
    const database = {
      $queryRaw: jest.fn().mockResolvedValue([]),
      $transaction: async (work: (transaction: Prisma.TransactionClient) => Promise<unknown>): Promise<unknown> => work(database as unknown as Prisma.TransactionClient),
      aiSettings: {
        upsert: (): Promise<AiSettings> => Promise.resolve(settings),
        findUniqueOrThrow: (): Promise<AiSettings> => Promise.resolve(settings),
        update: ({ data }: { data: Partial<Omit<AiSettings, 'revision'>> & { revision?: { increment: number } } }): Promise<AiSettings> => {
          settings = { ...settings, ...data, revision: settings.revision + (data.revision?.increment ?? 0) };
          return Promise.resolve(settings);
        },
      },
      aiProfile: {
        create,
        count: ({ where }: { where: { userId: string } }): Promise<number> => Promise.resolve(profiles.filter((profile) => profile.userId === where.userId).length),
        findMany: ({ where }: { where: { userId: string } }): Promise<AiProfile[]> => Promise.resolve(profiles.filter((profile) => profile.userId === where.userId)),
        findFirst: ({ where }: { where: { id: string; userId: string } }): Promise<AiProfile | null> => Promise.resolve(profiles.find((profile) => profile.id === where.id && profile.userId === where.userId) ?? null),
        update: ({ where, data }: { where: { id: string }; data: Partial<Omit<AiProfile, 'revision'>> & { revision: { increment: number } } }): Promise<AiProfile> => {
          // 该边界只模拟数据库更新，不改变活动配置。
          const current = profiles.find((profile) => profile.id === where.id)!;
          Object.assign(current, { ...data, revision: current.revision + data.revision.increment });
          return Promise.resolve(current);
        },
      },
    };
    testConnection = jest.fn().mockResolvedValue({ ok: true, message: '连接成功' });
    service = new AiService(database as unknown as PrismaService, { encrypt: (): string => 'unit-ciphertext', decrypt: (): string => 'unit-only-key' } as unknown as AiKeyStore, { test: testConnection } as unknown as AiProvider);
  });

  it('从零新增首个配置时返回当前使用且不自动开启整理', async () => {
    // 保存和默认选择共用一次修订提交。
    const result = await service.saveProfile(userId, input);
    expect(result.profiles).toHaveLength(1);
    expect(result.activeProfileId).toBe(result.profiles[0]!.id);
    expect(result.notePolishEnabled).toBe(false);
    expect(result.revision).toBe(1);
  });

  it.each([false, true])('已有配置后新增不改变选择或整理开关（原开关%s）', async (enabled) => {
    // 首个配置由正式服务建立，第二次保存使用最新修订号。
    const first = await service.saveProfile(userId, input);
    settings.notePolishEnabled = enabled;
    // 后续新增返回包含两套配置的共享快照。
    const result = await service.saveProfile(userId, { ...input, revision: first.revision, name: '第二套' });
    expect(result.profiles).toHaveLength(2);
    expect(result.activeProfileId).toBe(first.activeProfileId);
    expect(result.notePolishEnabled).toBe(enabled);
  });

  it('已有配置但用户未选择时，编辑和后续新增均不抢占当前选择', async () => {
    // 既有唯一配置并不代表本次是从零新增。
    const first = await service.saveProfile(userId, input);
    settings.activeProfileId = null;
    // 单配置编辑仍保留用户的未选择状态。
    const edited = await service.saveProfile(userId, { ...input, revision: first.revision }, first.profiles[0]!.id);
    expect(edited.activeProfileId).toBeNull();
    // 新增第二套同样不能自动切换。
    const added = await service.saveProfile(userId, { ...input, revision: edited.revision });
    expect(added.activeProfileId).toBeNull();
  });

  it('其他归属的配置不影响当前归属首个配置的默认选择', async () => {
    // 无关配置必须在数据库计数和响应中被归属过滤。
    profiles.push({ id: randomUUID(), userId: randomUUID(), name: '其他归属', provider: 'custom', baseUrl: input.baseUrl, model: input.model, thinkingEnabled: false, multimodal: false, encryptedApiKey: null, assistantCapabilities: null, revision: 1, createdAt: new Date() });
    // 只为当前归属返回新建配置及默认选择。
    const result = await service.saveProfile(userId, input);
    expect(result.profiles).toHaveLength(1);
    expect(result.activeProfileId).toBe(result.profiles[0]!.id);
  });

  it('旧修订号不能新增配置或覆盖已选模型', async () => {
    // 另一设备仍持有新增首个配置前的版本。
    const first = await service.saveProfile(userId, input);
    await expect(service.saveProfile(userId, input)).rejects.toBeInstanceOf(ConflictException);
    expect(create).toHaveBeenCalledTimes(1);
    expect(settings.activeProfileId).toBe(first.activeProfileId);
  });

  it('新增默认关闭，开启和关闭均持久保存，旧客户端省略不会误关已开启配置', async () => {
    // 同一配置依次覆盖新建、开启、旧客户端编辑以及显式关闭。
    let result = await service.saveProfile(userId, input);
    expect(result.profiles[0]!.multimodal).toBe(false);
    // 使用服务端返回的配置身份，不猜测UUID。
    const id = result.profiles[0]!.id;
    result = await service.saveProfile(userId, { ...input, revision: result.revision, multimodal: true }, id);
    expect(result.profiles[0]!.multimodal).toBe(true);
    expect((await service.captureAssistantProfile(userId, id)).compatibility?.imageInput).toBe('supported');
    result = await service.saveProfile(userId, { ...input, revision: result.revision, name: '旧客户端编辑' }, id);
    expect(result.profiles[0]!.multimodal).toBe(true);
    result = await service.saveProfile(userId, { ...input, revision: result.revision, multimodal: false }, id);
    expect(result.profiles[0]!.multimodal).toBe(false);
    expect((await service.captureAssistantProfile(userId, id)).compatibility?.imageInput).toBe('unsupported');
  });

  it.each([false, true])('旧图片探测结果不能覆盖多模态开关%s，快照固定本次声明', async (multimodal) => {
    // 故意设置相反的历史探测结果，确保只有用户开关决定图片能力。
    const result = await service.saveProfile(userId, { ...input, multimodal });
    profiles[0]!.assistantCapabilities = { revision: profiles[0]!.revision, compatibility: { ...assistantCompatibility(), imageInput: multimodal ? 'unsupported' : 'supported' } };
    expect((await service.captureAssistantProfile(userId, result.profiles[0]!.id)).compatibility?.imageInput).toBe(multimodal ? 'supported' : 'unsupported');
  });

  it.each([null, 'true', 1])('多模态拒绝非布尔输入%s，不通过字符串隐式开启', async (multimodal) => {
    // 真正DTO校验必须拒绝null及可被误转换的字符串/数字。
    const errors = await validate(Object.assign(new AiProfileDto(), input, { multimodal }));
    expect(errors.some((error) => error.property === 'multimodal')).toBe(true);
  });
  it('思考模式新增默认关闭，开启、旧客户端编辑及显式关闭按修订保存', async () => {
    // 同一真实领域服务覆盖开关所有保存路径。
    let result = await service.saveProfile(userId, input);
    expect(result.profiles[0]!.thinkingEnabled).toBe(false);
    // 目标身份来自服务端回执。
    const id = result.profiles[0]!.id;
    result = await service.saveProfile(userId, { ...input, revision: result.revision, thinkingEnabled: true }, id);
    expect(result.profiles[0]!.thinkingEnabled).toBe(true);
    expect((await service.captureAssistantProfile(userId, id)).thinkingEnabled).toBe(true);
    result = await service.saveProfile(userId, { ...input, revision: result.revision }, id);
    expect(result.profiles[0]!.thinkingEnabled).toBe(true);
    result = await service.saveProfile(userId, { ...input, revision: result.revision, thinkingEnabled: false }, id);
    expect(result.profiles[0]!.thinkingEnabled).toBe(false);
    expect((await service.captureAssistantProfile(userId, id)).thinkingEnabled).toBe(false);
  });

  it.each([null, 'true', 1])('思考开关拒绝非布尔输入%s', async (thinkingEnabled) => {
    // 参数校验不允许隐式布尔转换。
    const errors = await validate(Object.assign(new AiProfileDto(), input, { thinkingEnabled }));
    expect(errors.some((error) => error.property === 'thinkingEnabled')).toBe(true);
  });

  it('草稿连接测试可临时关闭思考，省略时沿用保存值且不写配置', async () => {
    // 已保存配置开启思考，测试草稿可以明确设为false。
    const result = await service.saveProfile(userId, { ...input, thinkingEnabled: true });
    await service.test(userId, { profileId: result.profiles[0]!.id, provider: input.provider, baseUrl: input.baseUrl, model: input.model, thinkingEnabled: false });
    expect(testConnection).toHaveBeenLastCalledWith(expect.objectContaining({ thinkingEnabled: false, apiKey: 'unit-only-key' }));
    await service.test(userId, { profileId: result.profiles[0]!.id, provider: input.provider, baseUrl: input.baseUrl, model: input.model });
    expect(testConnection).toHaveBeenLastCalledWith(expect.objectContaining({ thinkingEnabled: true }));
    expect(profiles[0]!.thinkingEnabled).toBe(true);
    expect(settings.revision).toBe(result.revision);
  });

  it('ASR捕获时把思考模式复制到笔记任务，之后修改配置不改变任务快照', async () => {
    // 只模拟事务的配置和任务写入边界，不复制领域判断。
    const createJob = jest.fn().mockResolvedValue({});
    // 可变配置用来证明任务写入的是布尔快照而非引用。
    const profile = { id: randomUUID(), revision: 1, provider: input.provider, model: input.model, baseUrl: input.baseUrl, encryptedApiKey: 'unit-ciphertext', thinkingEnabled: true };
    // 当前ASR绑定任务的最小事务。
    const transaction = { aiSettings: { findUnique: jest.fn().mockResolvedValue({ notePolishEnabled: true, activeProfileId: profile.id }) }, aiProfile: { findFirst: jest.fn().mockResolvedValue(profile) }, notePolishJob: { create: createJob } } as unknown as Prisma.TransactionClient;
    await service.capture(transaction, { id: randomUUID(), userId, segmentId: randomUUID() });
    profile.thinkingEnabled = false;
    expect(createJob).toHaveBeenCalledWith({ data: expect.objectContaining({ thinkingEnabled: true, profileId: profile.id }) });
  });
});
