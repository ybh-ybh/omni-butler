import { BadRequestException, ConflictException, ForbiddenException, Injectable, NotFoundException, OnModuleDestroy, OnModuleInit, ServiceUnavailableException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import type { AuthUser } from '../auth/auth.types';
import { AuthService } from '../auth/auth.service';
import type { NoteAudioStageDto } from './notes.dto';
import type { NoteRecognitionJob } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { NoteAudioStore } from './note-audio-store';
import { SpeechProviderError, SpeechRecognitionProvider } from './speech-provider';
import { AiService } from '../ai/ai.service';

/// 30 分钟单声道 WAV 仍可完整上传，保留余量但不接受无界文件。
export const NOTE_AUDIO_MAX_BYTES = 128 * 1024 * 1024;

/// 对客户端返回统一任务事实，不泄露服务商鉴权或远端身份。
export interface RecognitionResult {
  /// 本系统持久操作身份。
  id: string;
  /// 原音稳定身份。
  segmentId: string;
  /// 当前任务阶段。
  status: string;
  /// 本次任务的完整结果，重新识别时可与原始共享转写不同。
  transcript: string | null;
  /// 已保存的共享原始转写；客户端下行尚未到达时仍以此为准。
  canonicalTranscript: string | null;
  /// 无敏感正文的错误编码。
  errorCode: string | null;
}

/// 原音和持久异步识别领域服务。
@Injectable()
export class NotesService implements OnModuleInit, OnModuleDestroy {
  /// 周期任务只在应用运行时持有，业务状态始终存数据库。
  private timer: ReturnType<typeof setInterval> | undefined;
  /// 本实例防止重叠扫描，跨实例另有数据库 compare-and-set。
  private running = false;
  /// 当前实例是否正在关闭。
  private stopping = false;
  /// 当前扫描任务，在退出时等待其提交状态。
  private activeTick: Promise<void> | undefined;
  /// 注入数据库、私有对象存储与可替换语音适配器。
  constructor(private readonly prisma: PrismaService, private readonly config: ConfigService, private readonly store: NoteAudioStore, private readonly speech: SpeechRecognitionProvider, private readonly auth: AuthService, private readonly ai: AiService) {}

  /// 返回语音与原音能力，配置缺失不影响纯文本笔记。
  capabilities(): { audioUpload: boolean; recognition: boolean; aiPolish: boolean; provider: string; maxBytes: number; maxSegmentDurationMs: number; maxNoteDurationMs: number } {
    return { audioUpload: true, recognition: this.speech.configured(), aiPolish: true, provider: this.speech.name, maxBytes: NOTE_AUDIO_MAX_BYTES, maxSegmentDurationMs: 1800000, maxNoteDurationMs: 3600000 };
  }
  /// 启动持久队列恢复和文件清理，不让缺少 ASR 密钥阻止服务器启动。
  onModuleInit(): void {
    this.timer = setInterval(() => { if (!this.activeTick) { this.activeTick = this.tick().catch(() => undefined).finally(() => { this.activeTick = undefined; }); } }, 5000);
    this.timer.unref();
  }
  /// 退出不撤销服务商已接收的任务，下一实例从持久任务继续轮询。
  async onModuleDestroy(): Promise<void> { this.stopping = true; if (this.timer) clearInterval(this.timer); await this.activeTick; }

  /// 部署密钥验证后暂存完整文件，重放身份不同内容一律拒绝。
  async stage(input: NoteAudioStageDto, bytes: Buffer): Promise<{ migrationId: string; segmentId: string; sha256: string; byteSize: number }> {
    this.auth.verifySyncKey(input.syncKey);
    this.uuid(input.migrationId); this.uuid(input.segmentId);
    if (!bytes.length || bytes.length > NOTE_AUDIO_MAX_BYTES || !this.matchesMime(bytes, input.mime) || createHash('sha256').update(bytes).digest('hex') !== input.sha256) throw new BadRequestException('迁移原音文件校验失败');
    return this.prisma.$transaction(async (transaction) => {
      // 与现有快照提交共用部署级锁，提交期间不能替换暂存内容。
      await transaction.$executeRaw`SELECT pg_advisory_xact_lock(1573090401)`;
      // 已完成或已被后续替换的迁移不接受新的文件。
      const receipt = await transaction.syncMigrationReceipt.findUnique({ where: { migrationId: input.migrationId } });
      if (receipt) {
        // 响应丢失后客户端可重放原stage；只确认已提交资产，绝不再次覆盖。
        const committed = await transaction.noteAudioAsset.findFirst({ where: { userId: receipt.ownerId, segmentId: input.segmentId }, include: { segment: true } });
        if (committed && committed.segment.sha256 === input.sha256 && committed.segment.byteSize === bytes.length && committed.segment.mime === input.mime) return { migrationId: input.migrationId, segmentId: input.segmentId, sha256: input.sha256, byteSize: bytes.length };
        throw new ConflictException('该迁移已提交且原音不匹配，请查询原回执');
      }
      // 迁移身份与音频身份构成不可变的暂存事实。
      const existing = await transaction.noteAudioStaging.findUnique({ where: { migrationId_segmentId: { migrationId: input.migrationId, segmentId: input.segmentId } } });
      if (existing && (existing.sha256 !== input.sha256 || existing.byteSize !== bytes.length || existing.mime !== input.mime)) throw new ConflictException('同一迁移原音身份不能用于不同文件');
      // 暂存路径在提交后直接转成资产引用，无需移动真实字节。
      const objectKey = `${input.migrationId}/${input.segmentId}/${input.sha256}`;
      // 外层事务失败也保留这份独立提交的孤立文件清理租约。
      await this.prepareFile(objectKey);
      await this.store.put(objectKey, bytes, input.mime);
      if (!existing) await transaction.noteAudioStaging.create({ data: { migrationId: input.migrationId, segmentId: input.segmentId, sha256: input.sha256, byteSize: bytes.length, mime: input.mime, objectKey } });
      await transaction.noteAudioGarbage.deleteMany({ where: { objectKey } });
      return { migrationId: input.migrationId, segmentId: input.segmentId, sha256: input.sha256, byteSize: bytes.length };
    }, { timeout: 60000 });
  }

  /// 只允许所有者对已同步的不可变音频元数据上传相同原音。
  async upload(user: AuthUser, segmentId: string, input: { noteId: string; durationMs: number; sha256: string }, bytes: Buffer): Promise<{ segmentId: string; sha256: string; byteSize: number }> {
    this.uuid(segmentId);
    if (!bytes.length || bytes.length > NOTE_AUDIO_MAX_BYTES) throw new BadRequestException('原音文件为空或超过大小限制');
    // 对真实字节计算摘要，不信任表单。
    const digest = createHash('sha256').update(bytes).digest('hex');
    if (digest !== input.sha256) throw new BadRequestException('原音文件摘要不匹配');
    return this.prisma.$transaction(async (transaction) => {
      // 与迁移及文件GC统一排序，旧清理回执不能删掉重新上传的有效文件。
      await transaction.$executeRaw`SELECT pg_advisory_xact_lock(1573090401)`;
      // 与同步删除和快照替换共享归属锁。
      await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id = ${user.sub}::uuid FOR UPDATE`;
      // 原音元数据和所属笔记必须同归属。
      const segment = await transaction.noteAudioSegment.findFirst({ where: { userId: user.sub, id: segmentId }, include: { note: true, asset: true } });
      if (!segment) throw new NotFoundException('请先同步原音元数据');
      if (segment.noteId !== input.noteId || segment.durationMs !== input.durationMs || segment.sha256 !== digest || segment.byteSize !== bytes.length || !this.matchesMime(bytes, segment.mime)) throw new BadRequestException('原音文件与已同步元数据不一致');
      // 每篇累计上限由真实音频元数据再次验证。
      const total = await transaction.noteAudioSegment.aggregate({ where: { userId: user.sub, noteId: segment.noteId, deletedAt: null }, _sum: { durationMs: true } });
      if ((total._sum.durationMs ?? 0) > 3600000) throw new BadRequestException('每篇笔记原音不能超过 60 分钟');
      // 独立归属路径，不允许客户端传入任意对象键。
      const objectKey = segment.asset?.objectKey ?? `${user.sub}/${segment.id}/${digest}`;
      await this.prepareFile(objectKey);
      await this.store.put(objectKey, bytes, segment.mime);
      if (!segment.asset) await transaction.noteAudioAsset.create({ data: { userId: user.sub, segmentId, objectKey } });
      await transaction.noteAudioGarbage.deleteMany({ where: { objectKey } });
      return { segmentId, sha256: digest, byteSize: bytes.length };
    }, { timeout: 60000, maxWait: 30000 });
  }

  /// 下载保留回收站里的原音，只有永久删除才撤销访问。
  async download(userId: string, segmentId: string): Promise<{ bytes: Buffer; mime: string; sha256: string }> {
    this.uuid(segmentId);
    // 每次访问都从数据库确认归属，不能凭已过期路径取文件。
    const segment = await this.prisma.noteAudioSegment.findFirst({ where: { userId, id: segmentId }, include: { asset: true } });
    if (!segment?.asset) throw new NotFoundException('原音尚未上传或已永久删除');
    // 经授权的真实原音文件。
    const bytes = await this.store.get(segment.asset.objectKey).catch(() => { throw new NotFoundException('原音文件暂不可用'); });
    if (bytes.length !== segment.byteSize || createHash('sha256').update(bytes).digest('hex') !== segment.sha256) throw new ServiceUnavailableException('原音文件校验失败');
    return { bytes, mime: segment.mime, sha256: segment.sha256 };
  }

  /// 有效任务重放和并发请求都返回同一任务，不重复收费。
  async recognize(user: AuthUser, segmentId: string, operationId: string, consent: boolean): Promise<RecognitionResult> {
    this.uuid(segmentId); this.uuid(operationId);
    if (!consent) throw new ForbiddenException('需要授权本次云端语音识别');
    if (!this.speech.configured()) throw new ServiceUnavailableException({ code: 'ASR_NOT_CONFIGURED', message: '服务器尚未配置语音识别服务' });
    return this.prisma.$transaction(async (transaction) => {
      await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id = ${user.sub}::uuid FOR UPDATE`;
      // 操作身份的回执不依赖任务是否已经终结。
      const replay = await transaction.noteRecognitionJob.findUnique({ where: { id: operationId }, include: { segment: { select: { transcript: true } } } });
      if (replay) { if (replay.userId !== user.sub || replay.segmentId !== segmentId) throw new ConflictException('识别操作身份被不同原音占用'); return this.result(replay, replay.segment.transcript); }
      // 笔记恢复后可再次授权，已删除期间不能提交。
      const segment = await transaction.noteAudioSegment.findFirst({ where: { id: segmentId, userId: user.sub }, include: { note: true, asset: true } });
      if (!segment?.asset) throw new NotFoundException('请先上传原音文件');
      if (segment.deletedAt || segment.note.deletedAt) throw new ConflictException('回收站笔记不能识别');
      // 服务商未知提交必须保留待排查，不能因客户端换身份自动重复收费。
      const current = await transaction.noteRecognitionJob.findFirst({ where: { userId: user.sub, segmentId, status: { in: ['queued', 'submitting', 'processing', 'submissionUnknown'] } }, orderBy: { createdAt: 'desc' } });
      if (current) return this.result(current, segment.transcript);
      if (segment.byteSize > 5 * 1024 * 1024 && !this.config.get<string>('NOTE_ASR_PUBLIC_URL')) throw new ServiceUnavailableException({ code: 'ASR_PUBLIC_URL_REQUIRED', message: '长录音识别需要配置服务器公网 API 地址' });
      // 完整持久保存厂商和模型，之后部署变更不能改变已提交任务。
      const job = await transaction.noteRecognitionJob.create({ data: { id: operationId, userId: user.sub, segmentId, provider: this.speech.name, model: this.config.get<string>('NOTE_ASR_MODEL') ?? '16k_zh', status: 'queued' } });
      await this.ai.capture(transaction, job);
      return this.result(job, segment.transcript);
    });
  }
  /// 查看当前任务只读取状态，不触发新的计费请求。
  async current(user: AuthUser, segmentId: string): Promise<RecognitionResult | null> {
    this.uuid(segmentId);
    // 原音归属验证避免探测别人的任务。
    const segment = await this.prisma.noteAudioSegment.findFirst({ where: { id: segmentId, userId: user.sub }, select: { id: true } });
    if (!segment) throw new NotFoundException('原音不存在');
    // 最后一次任务是客户端展示的当前状态。
    const job = await this.prisma.noteRecognitionJob.findFirst({ where: { userId: user.sub, segmentId }, orderBy: [{ createdAt: 'desc' }, { id: 'desc' }], include: { segment: { select: { transcript: true } } } });
    return job ? this.result(job, job.segment.transcript) : null;
  }
  /// 撤回未发送工作；已经发送的任务停止结果处理且不宣称撤销厂商费用。
  async cancel(user: AuthUser, segmentId: string): Promise<{ cancelled: boolean; alreadySubmitted: boolean }> {
    this.uuid(segmentId);
    return this.prisma.$transaction(async (transaction) => {
      await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id = ${user.sub}::uuid FOR UPDATE`;
      await this.ai.cancelJobs(transaction, user.sub, segmentId);
      // 当前有效或不确定任务。
      const job = await transaction.noteRecognitionJob.findFirst({ where: { userId: user.sub, segmentId, status: { in: ['queued', 'submitting', 'processing', 'submissionUnknown'] } }, orderBy: { createdAt: 'desc' } });
      if (!job) return { cancelled: false, alreadySubmitted: false };
      if (job.status === 'submissionUnknown') return { cancelled: false, alreadySubmitted: true };
      await transaction.noteRecognitionJob.update({ where: { id: job.id }, data: { status: 'cancelled' } });
      return { cancelled: true, alreadySubmitted: job.status !== 'queued' };
    });
  }

  /// 服务商使用的短期链接，每次访问仍校验活跃任务和未删除笔记。
  async providerDownload(jobId: string, expires: string, signature: string): Promise<{ bytes: Buffer; mime: string; sha256: string }> {
    this.uuid(jobId);
    // 固定长度和数字验证先于恒定时间比对。
    const deadline = Number(expires);
    if (!/^\d{13}$/.test(expires) || !/^[a-f0-9]{64}$/.test(signature) || deadline < Date.now() || deadline > Date.now() + 4 * 3600000) throw new ForbiddenException('原音链接已失效');
    // 与签发时一致的任务绑定摘要。
    const expected = this.signature(jobId, expires);
    if (!timingSafeEqual(Buffer.from(expected, 'hex'), Buffer.from(signature, 'hex'))) throw new ForbiddenException('无效原音链接');
    // 永久删除、撤回和回收站状态都立即撤销服务商取音权限。
    const job = await this.prisma.noteRecognitionJob.findUnique({ where: { id: jobId }, include: { segment: { include: { note: true } } } });
    if (!job || !['submitting', 'processing'].includes(job.status) || job.segment.deletedAt || job.segment.note.deletedAt) throw new ForbiddenException('识别任务已终止');
    return this.download(job.userId, job.segmentId);
  }
  /// 持久队列恢复、领取、轮询与 30 天永久清理。
  async tick(): Promise<void> {
    if (this.running || this.stopping) return;
    this.running = true;
    try {
      // 从提交阶段崩溃恢复时禁止重复 POST 计费。
      await this.prisma.noteRecognitionJob.updateMany({ where: { status: 'submitting', updatedAt: { lt: new Date(Date.now() - 120000) } }, data: { status: 'submissionUnknown', errorCode: 'ASR_SUBMISSION_UNKNOWN' } });
      // 回收站笔记的识别工作停止，但原音继续保留。
      await this.prisma.noteRecognitionJob.updateMany({ where: { status: { in: ['queued', 'processing'] }, segment: { OR: [{ deletedAt: { not: null } }, { note: { deletedAt: { not: null } } }] } }, data: { status: 'cancelled' } });
      // 超出保留期限后连同版本、原音、任务永久删除，触发持久文件清理回执。
      await this.prisma.noteEntry.deleteMany({ where: { deletedAt: { lt: new Date(Date.now() - 30 * 24 * 3600000) } } });
      // 失败迁移24小时后清理未接管的暂存，已提交对象不受影响。
      await this.prisma.$transaction(async (transaction) => { await transaction.$executeRaw`SELECT pg_advisory_xact_lock(1573090401)`; await transaction.noteAudioStaging.deleteMany({ where: { createdAt: { lt: new Date(Date.now() - 24 * 3600000) } } }); });
      if (this.speech.configured()) {
        // 单轮限量，避免一人积压长期占用 CPU 和网络。
        const jobs = await this.prisma.noteRecognitionJob.findMany({ where: { provider: this.speech.name, status: { in: ['queued', 'processing'] }, nextPollAt: { lte: new Date() } }, orderBy: { createdAt: 'asc' }, take: 8 });
        for (const job of jobs) { if (this.stopping) break; await this.process(job); }
      }
      // 即便 ASR 不配置，永久删除文件依然执行。
      const garbage = await this.prisma.noteAudioGarbage.findMany({ where: { dueAt: { lte: new Date() } }, take: 100 });
      for (const entry of garbage) {
        try {
          await this.prisma.$transaction(async (transaction) => {
            // 重新暂存和迁移接管都使用相同锁，选出旧队列不等于取得删除授权。
            await transaction.$executeRaw`SELECT pg_advisory_xact_lock(1573090401)`;
            // 锁内重查租约，已移除或续期的过时扫描结果必须跳过。
            const current = await transaction.noteAudioGarbage.findUnique({ where: { objectKey: entry.objectKey } });
            if (!current || current.dueAt > new Date()) return;
            // 任一有效资产或暂存引用都禁止删除真实文件。
            const asset = await transaction.noteAudioAsset.findUnique({ where: { objectKey: entry.objectKey } });
            // 尚未提交但可被后续快照接管的原音。
            const staged = await transaction.noteAudioStaging.findUnique({ where: { objectKey: entry.objectKey } });
            if (!asset && !staged) await this.store.delete(entry.objectKey);
            await transaction.noteAudioGarbage.delete({ where: { objectKey: entry.objectKey } });
          }, { timeout: 30000 });
        } catch { /* 持久回执保留到下次成功，不记录敏感文件内容。 */ }
      }
    } finally { this.running = false; }
  }
  /// 领取远端提交或轮询；数据库 CAS 防止多个服务实例重复执行。
  private async process(job: NoteRecognitionJob): Promise<void> {
    if (job.status === 'queued') {
      // 从数据库锁内领取，撤回、软删和提交有明确线性顺序。
      const claimed = await this.prisma.$transaction(async (transaction) => {
        await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id = ${job.userId}::uuid FOR UPDATE`;
        // 与领取同时读取删除状态。
        const segment = await transaction.noteAudioSegment.findFirst({ where: { id: job.segmentId, userId: job.userId }, include: { note: true } });
        if (!segment || segment.deletedAt || segment.note.deletedAt) return false;
        // 原子状态变更只允许一个实例提交。
        const result = await transaction.noteRecognitionJob.updateMany({ where: { id: job.id, status: 'queued' }, data: { status: 'submitting' } });
        return result.count === 1;
      });
      if (!claimed) return;
      // 服务商已接收但本地回执保存失败也必须视为收费不确定。
      let submitted = false;
      try {
        // 读取完原音才能判断使用内联还是短期 URL。
        const audio = await this.download(job.userId, job.segmentId);
        // 可选公网 API 地址，仅由部署者配置，不接受客户端 URL。
        const publicUrl = this.config.get<string>('NOTE_ASR_PUBLIC_URL');
        // 短期令牌期限覆盖官方最大三小时队列时间，之后自动失效。
        const expires = String(Date.now() + 4 * 3600000);
        // 使用服务商 URL 时不把设备 bearer token 暴露给腾讯。
        const audioUrl = publicUrl ? `${publicUrl.replace(/\/$/, '')}/notes/audio/provider/${job.id}?expires=${expires}&signature=${this.signature(job.id, expires)}` : undefined;
        // 单次有副作用调用，失败状态由确定性决定。
        const taskId = await this.speech.submit({ model: job.model, audioUrl, ...(audioUrl ? {} : { bytes: audio.bytes }) });
        submitted = true;
        await this.prisma.noteRecognitionJob.updateMany({ where: { id: job.id, status: 'submitting' }, data: { status: 'processing', providerTaskId: taskId, nextPollAt: new Date(Date.now() + 5000) } });
      } catch (error: unknown) {
        // 下载失败发生在服务商调用前，不可误判为收费未知。
        const uncertain = submitted || (error instanceof SpeechProviderError && error.submissionUncertain);
        await this.prisma.noteRecognitionJob.updateMany({ where: { id: job.id, status: 'submitting' }, data: { status: uncertain ? 'submissionUnknown' : 'failed', errorCode: error instanceof SpeechProviderError ? error.code : submitted ? 'ASR_SUBMISSION_UNKNOWN' : 'ASR_AUDIO_UNAVAILABLE' } });
      }
      return;
    }
    // 查询结果24小时过期前留出余量，始终不自动新建任务。
    if (Date.now() - job.createdAt.getTime() > 23 * 3600000) { await this.prisma.noteRecognitionJob.updateMany({ where: { id: job.id, status: 'processing' }, data: { status: 'failed', errorCode: 'ASR_TASK_EXPIRED' } }); return; }
    // 跨实例通过延迟下次轮询时间领取一次只读查询。
    const claimed = await this.prisma.noteRecognitionJob.updateMany({ where: { id: job.id, status: 'processing', nextPollAt: { lte: new Date() } }, data: { nextPollAt: new Date(Date.now() + 15000) } });
    if (!claimed.count || !job.providerTaskId) return;
    try {
      // 轮询是幂等读取，网络失败允许下一轮继续相同 taskId。
      const result = await this.speech.poll(job.providerTaskId);
      if (result.status === 'processing') return;
      await this.prisma.$transaction(async (transaction) => {
        await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id = ${job.userId}::uuid FOR UPDATE`;
        // 结果回写再次检查归属与删除，不复活已删数据。
        const segment = await transaction.noteAudioSegment.findFirst({ where: { id: job.segmentId, userId: job.userId }, include: { note: true } });
        if (!segment || segment.deletedAt || segment.note.deletedAt) return;
        // 撤回或永久删除后的返回不再写入转写。
        const changed = await transaction.noteRecognitionJob.updateMany({ where: { id: job.id, status: 'processing' }, data: { status: result.status, transcript: result.transcript ?? null, errorCode: result.errorCode ?? null } });
        // 同一原音第一次成功的原文不可被重试覆盖，新候选留在任务结果。
        if (changed.count && result.status === 'succeeded' && segment.transcript === null) await transaction.noteAudioSegment.update({ where: { id: segment.id }, data: { transcript: result.transcript ?? '', updatedAt: new Date() } });
        if (changed.count) await this.ai.recognized(transaction, job.id, result.transcript ?? null, result.status === 'succeeded');
      });
    } catch { /* 只读失败不重复提交，保留 taskId 等下一轮查询。 */ }
  }
  /// 令牌只签发给指定持久任务和期限，部署密钥不随链接公开。
  private signature(jobId: string, expires: string): string { return createHmac('sha256', this.config.getOrThrow<string>('SYNC_SECRET')).update(`note-audio-v1:${jobId}:${expires}`).digest('hex'); }
  /// 在真实文件写入前独立提交清理租约，弥补磁盘与数据库不能原子提交的窗口。
  private async prepareFile(objectKey: string): Promise<void> {
    // 留给完整文件事务足够时间，正常提交会删除此租约。
    const dueAt = new Date(Date.now() + 3600000);
    await this.prisma.noteAudioGarbage.upsert({ where: { objectKey }, create: { objectKey, dueAt }, update: { dueAt } });
  }
  /// 去掉仅服务端需要的服务商字段。
  private result(job: NoteRecognitionJob, canonicalTranscript: string | null): RecognitionResult { return { id: job.id, segmentId: job.segmentId, status: job.status, transcript: job.transcript, canonicalTranscript, errorCode: job.errorCode }; }
  /// 路由和服务直接调用均检查稳定 UUID。
  private uuid(value: string): void { if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(value)) throw new BadRequestException('无效笔记原音身份'); }
  /// 校验容器签名，防止通过音频接口上传任意可执行文件。
  private matchesMime(bytes: Buffer, mime: string): boolean {
    if (bytes.length < 12) return false;
    if (mime === 'audio/wav') return bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WAVE';
    if (mime === 'audio/mp4') return bytes.toString('ascii', 4, 8) === 'ftyp';
    if (mime === 'audio/ogg') return bytes.toString('ascii', 0, 4) === 'OggS';
    if (mime === 'audio/flac') return bytes.toString('ascii', 0, 4) === 'fLaC';
    if (mime === 'audio/mpeg') return bytes.toString('ascii', 0, 3) === 'ID3' || (bytes[0] === 255 && (bytes[1]! & 0xe0) === 0xe0);
    if (mime === 'audio/aac') return bytes[0] === 255 && (bytes[1]! & 0xf6) === 0xf0;
    return false;
  }
}
