import { createHash, randomUUID } from 'node:crypto';
import type { NotePolishJob, Prisma } from '../src/generated/prisma/client';
import { PrismaService } from '../src/prisma/prisma.service';
import { AiKeyStore } from '../src/ai/ai-key-store';
import { AiProvider, AiProviderError } from '../src/ai/ai-provider';
import { AiService } from '../src/ai/ai.service';

describe('AI 持久 worker 的领取、未知提交和独立撤回', () => {
  /// 全部文本和 Key 均为合成夹具，不调用外部模型。
  const source = '嗯，今天 3 件事还不确定。';
  /// 共享任务状态用于模拟另一个服务器实例的撤回。
  let remoteStatus: string;
  /// 模拟软删除必须在请求等待时被观察到。
  let deletedAt: Date | null;
  /// 是否允许本实例取得数据库 CAS 的唯一调用权。
  let canClaim: boolean;
  /// 固定不可变配置快照和原文摘要。
  let job: NotePolishJob;
  /// 不需要真实 PostgreSQL 的网络生命周期测试边界。
  let service: AiService;
  /// 可观察的付费调用边界。
  const polish = jest.fn<Promise<string>, [unknown, string, AbortSignal?]>();
  /// 所有状态写入仍验证 CAS 条件和不重复提交的行为。
  const updateMany = jest.fn<Promise<{ count: number }>, [{ where: Record<string, unknown>; data: Record<string, unknown> }]>();

  beforeEach(() => {
    remoteStatus = 'processing'; deletedAt = null; canClaim = true;
    job = { id: randomUUID(), userId: randomUUID(), segmentId: randomUUID(), recognitionId: randomUUID(), attempt: 0, enabled: true, status: 'queued', profileId: randomUUID(), profileRevision: 1, provider: 'deepseek', baseUrl: 'https://api.deepseek.com', model: 'unit-model', encryptedApiKey: 'unit-ciphertext', promptVersion: 1, sourceHash: createHash('sha256').update(source).digest('hex'), text: null, errorCode: null, createdAt: new Date(), updatedAt: new Date() };
    polish.mockReset().mockResolvedValue('今天 3 件事还不确定。');
    updateMany.mockReset().mockImplementation((input) => Promise.resolve({ count: input.data.status === 'processing' && !canClaim ? 0 : 1 }));
    // 只模拟持久状态读写，不在 mock 内重复实现队列算法。
    const database = {
      $queryRaw: jest.fn().mockResolvedValue([]),
      $transaction: async (work: (transaction: Prisma.TransactionClient) => Promise<unknown>): Promise<unknown> => work(database as unknown as Prisma.TransactionClient),
      aiSettings: { findUnique: jest.fn().mockResolvedValue({ notePolishEnabled: true }) },
      noteRecognitionJob: { findFirst: jest.fn().mockImplementation(() => Promise.resolve({ transcript: source, segment: { deletedAt, note: { deletedAt } } })) },
      noteAudioSegment: { findFirst: jest.fn().mockImplementation(() => Promise.resolve({ deletedAt, note: { deletedAt } })) },
      notePolishJob: { updateMany, findMany: jest.fn().mockImplementation(() => Promise.resolve([job])), findUnique: jest.fn().mockImplementation(() => Promise.resolve({ status: remoteStatus, segment: { deletedAt, note: { deletedAt } }, user: { aiSettings: { notePolishEnabled: true } } })) },
    };
    service = new AiService(database as unknown as PrismaService, { decrypt: (): string => 'unit-only-key' } as unknown as AiKeyStore, { polish } as unknown as AiProvider);
  });

  it('CAS 未领取时不调用模型，避免跨实例重复付费', async () => {
    canClaim = false;
    await service.tick();
    expect(polish).not.toHaveBeenCalled();
    expect(updateMany).toHaveBeenCalledWith({ where: { id: job.id, status: 'queued' }, data: { status: 'processing', promptVersion: 2 } });
  });

  it('超时标记未知提交并清除终态密钥，不把原文作为成功输出', async () => {
    polish.mockRejectedValueOnce(new AiProviderError('AI_TIMEOUT', true));
    await service.tick();
    expect(polish).toHaveBeenCalledTimes(1);
    expect(updateMany).toHaveBeenCalledWith({ where: { id: job.id, status: 'processing' }, data: { status: 'submissionUnknown', errorCode: 'AI_TIMEOUT', encryptedApiKey: null } });
    expect(updateMany.mock.calls.some(([input]) => input.data.status === 'succeeded')).toBe(false);
  });

  it('成功结果保留原文摘要绑定并清除终态密钥', async () => {
    await service.tick();
    expect(updateMany).toHaveBeenCalledWith({ where: { id: job.id, status: 'queued' }, data: { status: 'processing', promptVersion: 2 } });
    expect(polish).toHaveBeenCalledWith(expect.objectContaining({ model: 'unit-model', apiKey: 'unit-only-key' }), source, expect.any(AbortSignal));
    expect(updateMany).toHaveBeenCalledWith({ where: { id: job.id, status: 'processing' }, data: { status: 'succeeded', text: '今天 3 件事还不确定。', errorCode: null, encryptedApiKey: null } });
  });

  it.each(['remoteCancel', 'softDelete'])('模型请求仍挂起时独立轮询能中止 %s', async (scenario) => {
    // 信号只来自真正进入模型调用的路径，避免通过私有字段伪造在途任务。
    let activeSignal: AbortSignal | undefined;
    // 明确等待付费调用开始，无需时间敏感的 busy polling。
    let markStarted: () => void = (): void => undefined;
    // 该 Promise 不等待模型完成，只确认请求已发出。
    const started = new Promise<void>((resolve) => { markStarted = resolve; });
    polish.mockImplementationOnce((_input, _source, signal) => new Promise<string>((_resolve, reject) => {
      activeSignal = signal;
      signal?.addEventListener('abort', () => reject(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)), { once: true });
      markStarted();
    }));
    // 主扫描会一直等待这次模型调用，撤回检查必须能独立执行。
    const processing = service.tick();
    await started;
    if (scenario === 'remoteCancel') remoteStatus = 'cancelled'; else deletedAt = new Date();
    await service.pollCancellations();
    expect(activeSignal?.aborted).toBe(true);
    await processing;
    expect(updateMany.mock.calls.some(([input]) => input.data.status === 'succeeded')).toBe(false);
    if (scenario === 'softDelete') expect(updateMany).toHaveBeenCalledWith({ where: { id: job.id, status: 'processing' }, data: { status: 'cancelled', errorCode: 'AI_CANCELLED', encryptedApiKey: null } });
  });
});
