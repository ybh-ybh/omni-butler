import { BadRequestException, ConflictException, Injectable, NotFoundException, OnModuleDestroy, OnModuleInit, ServiceUnavailableException } from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import type { NotePolishJob, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AiKeyStore } from './ai-key-store';
import { AI_POLISH_PROMPT_VERSION, AI_PRESETS, AiProvider, AiProviderError, aiFailure, normalizeAiBaseUrl } from './ai-provider';
import type { AiProfileDto, AiSettingsDto, AiTestDto } from './ai.dto';
import type { AssistantProfileSnapshot } from './assistant-model.types';
import { assistantCompatibility } from './assistant-model-policy';

/// 原文和密钥均不在公共任务响应中回传。
export interface PolishResult {
  /// null 表示旧 ASR 没有建立整理任务。
  id: string | null;
  /// 原始 ASR 稳定身份。
  recognitionId: string;
  /// 该 ASR 创建时固定的开关。
  enabled: boolean;
  /// 客户端按终态处理候选与原文回退。
  status: string;
  /// 仅成功任务对外提供正文，取消不允许迟到采用。
  text: string | null;
  /// 固定无敏感信息的错误码。
  errorCode: string | null;
  /// 与 ASR 输入绑定的 SHA256。
  sourceHash: string | null;
}

/// 后端共享配置与持久整理队列，模型任务不进入业务同步。
@Injectable()
export class AiService implements OnModuleInit, OnModuleDestroy {
  /// 队列扫描周期，数据库保留任务实际状态。
  private timer: ReturnType<typeof setInterval> | undefined;
  /// 单实例防止扫描重叠，跨实例领取使用数据库 CAS。
  private activeTick: Promise<void> | undefined;
  /// 跨实例撤回检查独立于等待模型响应的队列扫描。
  private cancellationTimer: ReturnType<typeof setInterval> | undefined;
  /// 防止撤回检查重叠，不阻塞主队列的请求处理。
  private activeCancellationCheck: Promise<void> | undefined;
  /// 停服后不再领取新的付费任务。
  private stopping = false;
  /// 当前实例进行中的调用用于尽力取消；其他实例通过持久状态拒绝迟到结果。
  private readonly requests = new Map<string, { userId: string; segmentId: string; controller: AbortController }>();
  /// 依赖都可在测试中替换，供应商网络为唯一外部副作用。
  constructor(private readonly prisma: PrismaService, private readonly keys: AiKeyStore, private readonly provider: AiProvider) {}

  /// 定期恢复持久任务，缺少供应商配置不阻止服务启动。
  onModuleInit(): void {
    this.timer = setInterval(() => { if (!this.activeTick) this.activeTick = this.tick().catch(() => undefined).finally(() => { this.activeTick = undefined; }); }, 3000);
    this.timer.unref();
    this.cancellationTimer = setInterval(() => { if (!this.activeCancellationCheck) this.activeCancellationCheck = this.pollCancellations().catch(() => undefined).finally(() => { this.activeCancellationCheck = undefined; }); }, 1000);
    this.cancellationTimer.unref();
  }

  /// 停服中断网络并持久标记未知提交，不等待整批模型超时。
  async onModuleDestroy(): Promise<void> { this.stopping = true; if (this.timer) clearInterval(this.timer); if (this.cancellationTimer) clearInterval(this.cancellationTimer); for (const pending of this.requests.values()) pending.controller.abort(); await this.activeCancellationCheck; await this.activeTick; }

  /// 初次读取原子建立默认关闭的设置。
  async settings(userId: string): Promise<Awaited<ReturnType<AiService['snapshot']>>> {
    return this.prisma.$transaction(async (transaction) => { await this.lock(transaction, userId); return this.snapshot(transaction, userId); });
  }

  /// 版本冲突不能静默覆盖另一设备设置。
  async updateSettings(userId: string, input: AiSettingsDto): Promise<Awaited<ReturnType<AiService['snapshot']>>> {
    return this.prisma.$transaction(async (transaction) => {
      await this.checkRevision(transaction, userId, input.revision);
      if (input.activeProfileId) {
        // 当前配置必须存在于相同归属下。
        const profile = await transaction.aiProfile.findFirst({ where: { id: input.activeProfileId, userId } });
        if (!profile) throw new NotFoundException({ code: 'AI_PROFILE_NOT_FOUND', message: '模型配置不存在，请刷新设置' });
        if (input.notePolishEnabled && !profile.encryptedApiKey) throw new BadRequestException({ code: 'AI_KEY_REQUIRED', message: '请先设置当前模型的 API Key' });
      } else if (input.notePolishEnabled) throw new BadRequestException({ code: 'AI_PROFILE_REQUIRED', message: '请先选择完整的模型配置' });
      await transaction.aiSettings.update({ where: { userId }, data: { activeProfileId: input.activeProfileId, notePolishEnabled: input.notePolishEnabled, revision: { increment: 1 } } });
      if (!input.notePolishEnabled) await this.cancelJobs(transaction, userId);
      return this.snapshot(transaction, userId);
    });
  }

  /// 新建和更新共用安全参数校验，空 Key 只保留已有密钥。
  async saveProfile(userId: string, input: AiProfileDto, id?: string): Promise<Awaited<ReturnType<AiService['snapshot']>>> {
    // 先验证所有普通字段，错误不产生设置写入。
    const baseUrl = normalizeAiBaseUrl(input.baseUrl);
    if (!input.name.trim() || !input.model.trim()) throw new BadRequestException({ code: 'AI_PROFILE_INVALID', message: '配置名称和模型名称不能为空' });
    if (input.removeApiKey && input.apiKey?.trim()) throw new BadRequestException({ code: 'AI_KEY_AMBIGUOUS', message: '删除密钥和替换密钥不能同时执行' });
    if (input.apiKey && /[\r\n\0]/.test(input.apiKey)) throw new BadRequestException({ code: 'AI_KEY_INVALID', message: 'API Key 格式无效' });
    return this.prisma.$transaction(async (transaction) => {
      await this.checkRevision(transaction, userId, input.revision);
      // 既有配置必须通过 owner 校验，不能借 UUID 修改他人密钥。
      const existing = id ? await transaction.aiProfile.findFirst({ where: { id, userId } }) : null;
      if (id && !existing) throw new NotFoundException({ code: 'AI_PROFILE_NOT_FOUND', message: '模型配置不存在' });
      // 只加密新的非空密钥，旧任务自己的密文快照不会被修改。
      const encryptedApiKey = input.removeApiKey ? null : input.apiKey?.trim() ? this.keys.encrypt(input.apiKey.trim()) : existing?.encryptedApiKey ?? null;
      // 必须在更新前比较凭据，防止事务替身或对象引用变化丢失旧值。
      const credentialsChanged = !!existing && encryptedApiKey !== existing.encryptedApiKey;
      // 不完整配置可保存，但不能开启整理。
      const data = { name: input.name.trim(), provider: input.provider, baseUrl, model: input.model.trim(), multimodal: input.multimodal ?? existing?.multimodal ?? false, thinkingEnabled: input.thinkingEnabled ?? existing?.thinkingEnabled ?? false, encryptedApiKey };
      // 保存结果用于在同一事务内选择首个配置，避免客户端另发设置请求。
      const profile = existing
        ? await transaction.aiProfile.update({ where: { id: existing.id }, data: { ...data, revision: { increment: 1 } } })
        : await transaction.aiProfile.create({ data: { ...data, id: randomUUID(), userId } });
      // owner 行锁与总修订号保证并发新增时只有首个配置成为默认选择。
      const isFirstProfile = !existing && await transaction.aiProfile.count({ where: { userId } }) === 1;
      // 删除当前配置的 Key 同时关闭自动整理。
      const settings = await transaction.aiSettings.findUniqueOrThrow({ where: { userId } });
      if (id === settings.activeProfileId && !encryptedApiKey) {
        await transaction.aiSettings.update({ where: { userId }, data: { notePolishEnabled: false } });
        await this.cancelJobs(transaction, userId);
      }
      if (existing && credentialsChanged) await this.invalidateAssistantProfile(transaction, userId, existing.id);
      await transaction.aiSettings.update({ where: { userId }, data: { revision: { increment: 1 }, ...(isFirstProfile ? { activeProfileId: profile.id } : {}) } });
      return this.snapshot(transaction, userId);
    });
  }

  /// 删除配置不删除旧任务快照，进行中的尝试仍有原目标。
  async deleteProfile(userId: string, id: string, revision: number): Promise<Awaited<ReturnType<AiService['snapshot']>>> {
    return this.prisma.$transaction(async (transaction) => {
      await this.checkRevision(transaction, userId, revision);
      // 同归属删除计数明确判断不存在，避免伪成功。
      const deleted = await transaction.aiProfile.deleteMany({ where: { id, userId } });
      if (!deleted.count) throw new NotFoundException({ code: 'AI_PROFILE_NOT_FOUND', message: '模型配置不存在' });
      await this.invalidateAssistantProfile(transaction, userId, id, true);
      // 当前配置删除必须关闭开关，再选择时仍需用户主动开启。
      const settings = await transaction.aiSettings.findUniqueOrThrow({ where: { userId } });
      if (settings.activeProfileId === id) {
        await transaction.aiSettings.update({ where: { userId }, data: { activeProfileId: null, notePolishEnabled: false } });
        await this.cancelJobs(transaction, userId);
      }
      await transaction.aiSettings.update({ where: { userId }, data: { revision: { increment: 1 } } });
      return this.snapshot(transaction, userId);
    });
  }

  /// 测试使用固定短文本，不保存输入也不改变配置版本。
  async test(userId: string, input: AiTestDto): Promise<{ ok: true; message: string }> {
    // 可选配置身份用于只读加载已有加密 Key。
    const profile = input.profileId ? await this.prisma.aiProfile.findFirst({ where: { id: input.profileId, userId } }) : null;
    if (input.profileId && !profile) throw new NotFoundException({ code: 'AI_PROFILE_NOT_FOUND', message: '模型配置不存在' });
    // 留空时才能使用已保存密钥，绝不把密文返回前端。
    const apiKey = input.apiKey?.trim() || (profile?.encryptedApiKey ? this.keys.decrypt(profile.encryptedApiKey) : '');
    if (!apiKey || /[\r\n\0]/.test(apiKey)) throw new BadRequestException({ code: 'AI_KEY_REQUIRED', message: '请填写有效 API Key' });
    try { return await this.provider.test({ ...input, thinkingEnabled: input.thinkingEnabled ?? profile?.thinkingEnabled ?? false, baseUrl: normalizeAiBaseUrl(input.baseUrl), apiKey }); } catch (error: unknown) { if (error instanceof BadRequestException) throw error; throw aiFailure(error); }
  }

  /// 助手独立选取已保存配置，密钥保持密文，不能借配置 UUID 跨归属读取。
  async captureAssistantProfile(userId: string, profileId: string): Promise<AssistantProfileSnapshot> {
    // 仅复制完整的同归属配置，不依赖笔记整理的开关或当前配置。
    const profile = await this.prisma.aiProfile.findFirst({ where: { id: profileId, userId } });
    if (!profile) throw new NotFoundException({ code: 'AI_PROFILE_NOT_FOUND', message: '模型配置不存在，请重新选择' });
    if (!profile.encryptedApiKey || !profile.model.trim()) throw new BadRequestException({ code: 'AI_PROFILE_REQUIRED', message: '请先补全模型名称和 API Key' });
    // 旧测试的容量配置仍按修订取值，图片输入始终由多模态开关决定。
    const tested = profile.assistantCapabilities as { revision?: number; compatibility?: AssistantProfileSnapshot['compatibility'] } | null;
    // 固定到本轮任务快照，后续普通配置编辑不改写已接受任务的目标。
    const compatibility = assistantCompatibility(tested?.revision === profile.revision ? tested.compatibility : undefined);
    return { profileId: profile.id, profileRevision: profile.revision, provider: profile.provider, baseUrl: normalizeAiBaseUrl(profile.baseUrl), model: profile.model, thinkingEnabled: profile.thinkingEnabled === true, encryptedApiKey: profile.encryptedApiKey, compatibility: { ...compatibility, imageInput: profile.multimodal === true ? 'supported' : 'unsupported' } };
  }

  /// 普通编辑不改变任务目标；撤换密钥禁止继续出站，关闭多模态禁止后续图片请求。
  async assertAssistantProfileAvailable(userId: string, snapshot: AssistantProfileSnapshot, requiresMultimodal = false): Promise<void> {
    // 每次请求都重新检查当前配置与同归属密钥事实，不仅在任务创建时检查。
    const profile = await this.prisma.aiProfile.findFirst({ where: { id: snapshot.profileId, userId }, select: { encryptedApiKey: true, multimodal: true } });
    if (!profile?.encryptedApiKey || profile.encryptedApiKey !== snapshot.encryptedApiKey) throw new ConflictException({ code: 'AI_CONFIGURATION_UNAVAILABLE', message: '模型配置或密钥已被删除或替换，请重新开始任务' });
    if (requiresMultimodal && profile.multimodal !== true) throw new AiProviderError('AI_IMAGE_INPUT_UNSUPPORTED');
  }

  /// 凭据撤回与配置保存共享归属锁及事务，不能让待确认计划保留旧执行授权。
  private async invalidateAssistantProfile(transaction: Prisma.TransactionClient, userId: string, profileId: string, removeSelection = false): Promise<void> {
    await transaction.assistantSettings.updateMany({ where: { userId, profileId }, data: { enabled: false, revision: { increment: 1 }, ...(removeSelection ? { profileId: null } : {}) } });
    // 与助手运行器相同的未完成状态集合，历史成功回执保持原状。
    const active = ['queued', 'running', 'waitingConfirmation', 'waitingInput', 'submissionUnknown'];
    // 任务可能在当前配置切换前已启动，须按固定快照查找而非仅按设置关联。
    const runs = await transaction.assistantRun.findMany({ where: { userId, status: { in: active }, profileSnapshot: { path: ['profileId'], equals: profileId } }, select: { id: true, taskId: true } });
    if (!runs.length) return;
    // 一项任务可能具有多个恢复尝试，取消时先合并稳定任务身份。
    const taskIds = [...new Set(runs.map((run) => run.taskId))];
    await transaction.mcpAction.updateMany({ where: { userId, source: 'assistant', sourceId: { in: taskIds }, status: 'pending' }, data: { status: 'cancelled' } });
    await transaction.assistantTask.updateMany({ where: { userId, id: { in: taskIds }, status: { in: active } }, data: { status: 'cancelled', approvedHash: null } });
    await transaction.assistantRun.updateMany({ where: { userId, id: { in: runs.map((run) => run.id) }, status: { in: active } }, data: { status: 'cancelled', leaseOwner: null, leaseUntil: null, errorCode: 'AI_CONFIGURATION_UNAVAILABLE', errorMessage: '模型配置或密钥已被删除或替换，本次任务已停止；已保存的业务操作保留实际结果。' } });
  }

  /// 与新 ASR 建立同一事务，固定当时的开关和配置版本。
  async capture(transaction: Prisma.TransactionClient, input: { id: string; userId: string; segmentId: string }): Promise<void> {
    // 设置不存在代表默认关闭，不扫描任何历史任务。
    const settings = await transaction.aiSettings.findUnique({ where: { userId: input.userId } });
    // 只有启用时读取当前配置，密钥仍维持密文形式。
    const profile = settings?.notePolishEnabled && settings.activeProfileId ? await transaction.aiProfile.findFirst({ where: { id: settings.activeProfileId, userId: input.userId } }) : null;
    // 即使关闭也保存本次 disabled 事实，之后开启不能追溯生效。
    const enabled = !!(profile?.encryptedApiKey && settings?.notePolishEnabled);
    await transaction.notePolishJob.create({ data: { id: randomUUID(), userId: input.userId, segmentId: input.segmentId, recognitionId: input.id, enabled, status: enabled ? 'waiting' : 'disabled', ...(enabled && profile ? { profileId: profile.id, profileRevision: profile.revision, provider: profile.provider, model: profile.model, thinkingEnabled: profile.thinkingEnabled, baseUrl: profile.baseUrl, encryptedApiKey: profile.encryptedApiKey } : {}) } });
  }

  /// ASR 原文提交成功后同事务排队，失败和撤回不产生模型调用。
  async recognized(transaction: Prisma.TransactionClient, recognitionId: string, transcript: string | null, succeeded: boolean): Promise<void> {
    await transaction.notePolishJob.updateMany({ where: { recognitionId, status: 'waiting' }, data: succeeded && transcript?.trim() ? { status: 'queued', sourceHash: this.hash(transcript) } : { status: 'cancelled', errorCode: 'AI_ASR_UNAVAILABLE', encryptedApiKey: null } });
  }

  /// 原音归属和指定 ASR 身份都验证后，只返回最近一次尝试。
  async current(userId: string, segmentId: string, recognitionId: string, operationId?: string): Promise<PolishResult> {
    // recognition 同时验证 owner 和 segment，不能枚举其他任务。
    const recognition = await this.prisma.noteRecognitionJob.findFirst({ where: { id: recognitionId, segmentId, userId }, include: { segment: { include: { note: true } } } });
    if (!recognition) throw new NotFoundException({ code: 'AI_RECOGNITION_NOT_FOUND', message: '语音识别任务不存在' });
    // 初始任务和显式重试共享查询，只取最近尝试。
    const job = await this.prisma.notePolishJob.findFirst({ where: { userId, segmentId, recognitionId, ...(operationId ? { id: operationId } : {}) }, orderBy: { attempt: 'desc' } });
    // 设置关闭或原音删除后不能把迟到结果暴露为可采用成功。
    const settings = await this.prisma.aiSettings.findUnique({ where: { userId } });
    // 取消并持久封存结果，之后重新开启也不会复活已撤销任务。
    const cancelled = !!job?.enabled && (!settings?.notePolishEnabled || recognition.status === 'cancelled' || !!recognition.segment.deletedAt || !!recognition.segment.note.deletedAt);
    if (cancelled && job && job.status !== 'cancelled') await this.prisma.notePolishJob.updateMany({ where: { id: job.id }, data: { status: 'cancelled', encryptedApiKey: null } });
    return this.result(job, recognitionId, cancelled);
  }

  /// 显式重试新尝试使用当前配置，同 operation 重放永久幂等。
  async retry(userId: string, segmentId: string, recognitionId: string, operationId: string): Promise<PolishResult> {
    await this.prisma.$transaction(async (transaction) => {
      await this.lock(transaction, userId);
      // 操作回执不能跨原音、ASR 或 owner 重用。
      const replay = await transaction.notePolishJob.findUnique({ where: { id: operationId } });
      if (replay) { if (replay.userId !== userId || replay.segmentId !== segmentId || replay.recognitionId !== recognitionId) throw new ConflictException({ code: 'AI_OPERATION_CONFLICT', message: '重试身份已被其他任务使用' }); return; }
      // 仅已成功且未删除的原文允许付费整理。
      const recognition = await transaction.noteRecognitionJob.findFirst({ where: { id: recognitionId, segmentId, userId }, include: { segment: { include: { note: true } } } });
      if (!recognition || recognition.status !== 'succeeded' || !recognition.transcript?.trim() || recognition.segment.deletedAt || recognition.segment.note.deletedAt) throw new ConflictException({ code: 'AI_ASR_UNAVAILABLE', message: '原始识别文本不可用或笔记已删除' });
      // 不允许把手动点击重试变成并行重复计费。
      const active = await transaction.notePolishJob.findFirst({ where: { userId, segmentId, recognitionId, status: { in: ['waiting', 'queued', 'processing'] } } });
      if (active) throw new ConflictException({ code: 'AI_ALREADY_PROCESSING', message: '这段文本正在整理，请等待当前任务' });
      // 当前有效配置必须包含密钥，不能依靠历史授权重新收费。
      const settings = await transaction.aiSettings.findUnique({ where: { userId } });
      // 使用当前配置而不是最初失败尝试的旧目标。
      const profile = settings?.activeProfileId && settings.notePolishEnabled ? await transaction.aiProfile.findFirst({ where: { id: settings.activeProfileId, userId } }) : null;
      if (!profile?.encryptedApiKey) throw new BadRequestException({ code: 'AI_DISABLED', message: '请先配置并开启笔记 AI 整理' });
      // 递增尝试序号提供稳定顺序，即使同毫秒连续重试也不依赖 UUID 排序。
      const attempts = await transaction.notePolishJob.aggregate({ where: { recognitionId }, _max: { attempt: true } });
      await transaction.notePolishJob.create({ data: { id: operationId, userId, segmentId, recognitionId, attempt: (attempts._max.attempt ?? -1) + 1, enabled: true, status: 'queued', profileId: profile.id, profileRevision: profile.revision, provider: profile.provider, baseUrl: profile.baseUrl, model: profile.model, thinkingEnabled: profile.thinkingEnabled, encryptedApiKey: profile.encryptedApiKey, sourceHash: this.hash(recognition.transcript) } });
    });
    return this.current(userId, segmentId, recognitionId, operationId);
  }

  /// ASR 撤回即使识别已经完成也必须停止整理和迟到采用。
  async cancelJobs(transaction: Prisma.TransactionClient, userId: string, segmentId?: string): Promise<void> {
    await transaction.notePolishJob.updateMany({ where: { userId, ...(segmentId ? { segmentId } : {}), enabled: true, status: { not: 'cancelled' } }, data: { status: 'cancelled', errorCode: 'AI_CANCELLED', encryptedApiKey: null } });
    // 已发出请求尽力取消，不对供应商已发生的费用作撤销承诺。
    for (const pending of this.requests.values()) if (pending.userId === userId && (!segmentId || pending.segmentId === segmentId)) pending.controller.abort();
  }

  /// 持久 worker 恢复崩溃，不自动重复任何可能计费的调用。
  async tick(): Promise<void> {
    if (this.stopping) return;
    await this.prisma.notePolishJob.updateMany({ where: { status: 'processing', updatedAt: { lt: new Date(Date.now() - 120000) } }, data: { status: 'submissionUnknown', errorCode: 'AI_SUBMISSION_UNKNOWN', encryptedApiKey: null } });
    // ASR 失败不应让客户端永远停留在等待整理。
    await this.prisma.notePolishJob.updateMany({ where: { status: 'waiting', recognition: { status: { in: ['failed', 'cancelled', 'submissionUnknown'] } } }, data: { status: 'cancelled', errorCode: 'AI_ASR_UNAVAILABLE', encryptedApiKey: null } });
    // 软删除后的网络结果无法写入任务成功状态。
    await this.prisma.notePolishJob.updateMany({ where: { status: { in: ['waiting', 'queued', 'processing', 'succeeded'] }, segment: { OR: [{ deletedAt: { not: null } }, { note: { deletedAt: { not: null } } }] } }, data: { status: 'cancelled', errorCode: 'AI_CANCELLED', encryptedApiKey: null } });
    // 有限批次保证服务器保持响应，跨实例通过状态 CAS 唯一领取。
    const jobs = await this.prisma.notePolishJob.findMany({ where: { status: 'queued' }, orderBy: { createdAt: 'asc' }, take: 4 });
    for (const job of jobs) { if (this.stopping) break; await this.process(job); }
  }

  /// 独立轮询让另一实例的关闭、撤回和软删除在请求等待期间仍能生效。
  async pollCancellations(): Promise<void> {
    if (this.stopping) return;
    for (const [id, pending] of this.requests) {
      // 同时读任务、开关与软删除事实，不能等主队列下一轮才取消。
      const current = await this.prisma.notePolishJob.findUnique({ where: { id }, select: { status: true, segment: { select: { deletedAt: true, note: { select: { deletedAt: true } } } }, user: { select: { aiSettings: { select: { notePolishEnabled: true } } } } } });
      if (!current || current.status !== 'processing' || !current.user.aiSettings?.notePolishEnabled || current.segment.deletedAt || current.segment.note.deletedAt) {
        if (current?.status === 'processing') await this.prisma.notePolishJob.updateMany({ where: { id, status: 'processing' }, data: { status: 'cancelled', errorCode: 'AI_CANCELLED', encryptedApiKey: null } });
        pending.controller.abort();
      }
    }
  }

  /// 领取、网络调用和回写分别验证，任何迟到响应都不能复活任务。
  private async process(job: NotePolishJob): Promise<void> {
    // 锁内固定本次允许发送的原文，删除、关闭和领取串行。
    const transcript = await this.prisma.$transaction(async (transaction) => {
      await this.lock(transaction, job.userId);
      // 同步删除与设置写入都使用同一归属锁。
      const settings = await transaction.aiSettings.findUnique({ where: { userId: job.userId } });
      // ASR 原文始终从绑定任务读取，不使用可变化的笔记正文。
      const recognition = await transaction.noteRecognitionJob.findFirst({ where: { id: job.recognitionId, userId: job.userId, status: 'succeeded' }, include: { segment: { include: { note: true } } } });
      if (!settings?.notePolishEnabled || !recognition?.transcript || recognition.segment.deletedAt || recognition.segment.note.deletedAt || this.hash(recognition.transcript) !== job.sourceHash) {
        await transaction.notePolishJob.updateMany({ where: { id: job.id, status: 'queued' }, data: { status: 'cancelled', errorCode: 'AI_SOURCE_UNAVAILABLE', encryptedApiKey: null } });
        return null;
      }
      // 唯一 CAS 领取者才拥有一次付费调用权。
      const claimed = await transaction.notePolishJob.updateMany({ where: { id: job.id, status: 'queued' }, data: { status: 'processing', promptVersion: AI_POLISH_PROMPT_VERSION } });
      return claimed.count === 1 ? recognition.transcript : null;
    });
    if (transcript === null) return;
    // 当前实例记住网络取消句柄，状态事实始终仍在数据库。
    const controller = new AbortController();
    this.requests.set(job.id, { userId: job.userId, segmentId: job.segmentId, controller });
    try {
      if (!job.encryptedApiKey || !job.baseUrl || !job.model || !job.provider) throw new AiProviderError('AI_CONFIGURATION_UNAVAILABLE');
      // 解密只在出站调用前进行，明文不保存到任务。
      const apiKey = this.keys.decrypt(job.encryptedApiKey);
      // 仅当前段 ASR 文本作为模型输入。
      const text = await this.provider.polish({ provider: job.provider, baseUrl: job.baseUrl, model: job.model, thinkingEnabled: job.thinkingEnabled, apiKey }, transcript, controller.signal);
      await this.prisma.$transaction(async (transaction) => {
        await this.lock(transaction, job.userId);
        // 同归属读取当前开关与删除事实，再比较任务仍未被取消。
        const settings = await transaction.aiSettings.findUnique({ where: { userId: job.userId } });
        // 回写时不依赖领取前的旧删除状态。
        const segment = await transaction.noteAudioSegment.findFirst({ where: { id: job.segmentId, userId: job.userId }, include: { note: true } });
        if (!settings?.notePolishEnabled || !segment || segment.deletedAt || segment.note.deletedAt) { await transaction.notePolishJob.updateMany({ where: { id: job.id, status: 'processing' }, data: { status: 'cancelled', errorCode: 'AI_CANCELLED', encryptedApiKey: null } }); return; }
        await transaction.notePolishJob.updateMany({ where: { id: job.id, status: 'processing' }, data: { status: 'succeeded', text, errorCode: null, encryptedApiKey: null } });
      });
    } catch (error: unknown) {
      // 只有确定失败才提供普通失败；超时等未知提交不自动重付费。
      const uncertain = error instanceof AiProviderError && error.uncertain;
      // 本地解密错误仍保留固定错误码，方便用户恢复密钥卷或重新配置。
      const failure = error instanceof ServiceUnavailableException ? error.getResponse() : null;
      // 只允许本地已知密钥错误离开服务边界，不回传任意对象内容。
      const keyCode = failure && typeof failure === 'object' && 'code' in failure && (failure.code === 'AI_KEY_DECRYPTION_FAILED' || failure.code === 'AI_KEY_STORAGE_FAILED') ? failure.code : null;
      await this.prisma.notePolishJob.updateMany({ where: { id: job.id, status: 'processing' }, data: { status: uncertain ? 'submissionUnknown' : 'failed', errorCode: error instanceof AiProviderError ? error.code : keyCode ?? 'AI_SERVICE_UNAVAILABLE', encryptedApiKey: null } });
    } finally { this.requests.delete(job.id); }
  }

  /// 所有共享设置写入与 ASR 提交复用归属行锁。
  private async lock(transaction: Prisma.TransactionClient, userId: string): Promise<void> { await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id = ${userId}::uuid FOR UPDATE`; }

  /// 创建默认行后检查总版本，数据库事务保证只成功一次。
  private async checkRevision(transaction: Prisma.TransactionClient, userId: string, revision: number): Promise<void> {
    await this.lock(transaction, userId);
    // 没有设置时版本从零开始，读取与更新行为一致。
    const settings = await transaction.aiSettings.upsert({ where: { userId }, create: { userId }, update: {} });
    if (settings.revision !== revision) throw new ConflictException({ code: 'AI_SETTINGS_CONFLICT', message: 'AI 设置已在其他设备修改，请刷新后重试' });
  }

  /// 响应只列出密钥是否存在和固定掩码，不解密、不回传长度。
  private async snapshot(transaction: Prisma.TransactionClient, userId: string): Promise<{ revision: number; activeProfileId: string | null; notePolishEnabled: boolean; profiles: { id: string; name: string; provider: string; baseUrl: string; model: string; multimodal: boolean; thinkingEnabled: boolean; hasApiKey: boolean; maskedApiKey: string }[]; presets: typeof AI_PRESETS }> {
    // 默认关闭设置与首次读原子建立。
    const settings = await transaction.aiSettings.upsert({ where: { userId }, create: { userId }, update: {} });
    // 不同设备按相同创建顺序展示。
    const profiles = await transaction.aiProfile.findMany({ where: { userId }, orderBy: [{ createdAt: 'asc' }, { id: 'asc' }] });
    return { revision: settings.revision, activeProfileId: settings.activeProfileId, notePolishEnabled: settings.notePolishEnabled, profiles: profiles.map((profile) => ({ id: profile.id, name: profile.name, provider: profile.provider, baseUrl: profile.baseUrl, model: profile.model, multimodal: profile.multimodal === true, thinkingEnabled: profile.thinkingEnabled === true, hasApiKey: !!profile.encryptedApiKey, maskedApiKey: profile.encryptedApiKey ? '••••••••' : '' })), presets: AI_PRESETS };
  }

  /// 对外终态只给经过取消保护的正文。
  private result(job: NotePolishJob | null, recognitionId: string, cancelled = false): PolishResult { return { id: job?.id ?? null, recognitionId, enabled: job?.enabled ?? false, status: cancelled ? 'cancelled' : job?.status ?? 'disabled', text: !cancelled && job?.status === 'succeeded' ? job.text : null, errorCode: cancelled ? 'AI_CANCELLED' : job?.errorCode ?? null, sourceHash: job?.sourceHash ?? null }; }

  /// 摘要绑定确切输入，不依赖修改后的笔记正文。
  private hash(text: string): string { return createHash('sha256').update(text).digest('hex'); }
}
