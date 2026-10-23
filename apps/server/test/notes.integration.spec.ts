import { ConfigModule, ConfigService } from '@nestjs/config';
import { Test } from '@nestjs/testing';
import { type INestApplication, ValidationPipe } from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Client } from 'pg';
import { AuthModule } from '../src/auth/auth.module';
import { AuthService } from '../src/auth/auth.service';
import type { AuthUser, TokenPair } from '../src/auth/auth.types';
import { validateEnvironment } from '../src/config/environment';
import { NotesModule } from '../src/notes/notes.module';
import { MinioNoteAudioStore, NoteAudioStore } from '../src/notes/note-audio-store';
import { MinioConnection } from '../src/storage/minio-connection';
import { DiskTestNoteAudioStore } from './helpers/disk-note-audio-store';
import { NotesService } from '../src/notes/notes.service';
import { SpeechProviderError, SpeechRecognitionProvider } from '../src/notes/speech-provider';
import { PrismaModule } from '../src/prisma/prisma.module';
import { PrismaService } from '../src/prisma/prisma.service';
import { SyncModule } from '../src/sync/sync.module';
import { canonicalize, SyncService } from '../src/sync/sync.service';
import { syncSchemaVersion } from '../src/sync/sync-schema';
import { AiService } from '../src/ai/ai.service';
import { AiProvider, AiProviderError } from '../src/ai/ai-provider';
import type { SyncOperationDto } from '../src/sync/dto/sync-operation.dto';

/// 只读取显式隔离数据库，默认测试不能接触用户数据。
const databaseUrl = process.env.OMNI_NOTES_TEST_DATABASE_URL;
/// 无数据库时明确跳过，不将跳过当作通过。
const integration = databaseUrl ? describe : describe.skip;
/// 固定测试部署密钥，与正式配置无关。
const syncKey = 'notes-integration-only-sync-key';

/// 实际存储只在上传和删除处支持故障注入，恢复后仍执行真实文件体读写。
class TestAudioStore extends NoteAudioStore {
  /// 测试显式选择磁盘辅助存储或实际MinIO，生产没有fallback。
  constructor(private readonly inner: NoteAudioStore) { super(); }
  /// 验证失败时持久清理回执保留。
  failDelete = false;
  /// 上传失败时验证HTTP及数据库不会误报完整资产。
  failPut = false;
  /// 故障注入不会影响写入和读取的真实字节。
  override async delete(key: string): Promise<void> { if (this.failDelete) throw new Error('test storage unavailable'); await this.inner.delete(key); }
  /// 原音字节和MIME转交真实存储实现。
  async put(key: string, bytes: Buffer, mime: string): Promise<void> { if (this.failPut) throw new Error('test upload storage unavailable'); await this.inner.put(key, bytes, mime); }
  /// 所有校验仍读取真实原音文件体。
  async get(key: string): Promise<Buffer> { return this.inner.get(key); }
}

integration('笔记真实 PostgreSQL + 私有文件 + JWT HTTP', () => {
  jest.setTimeout(60000);
  // 独立数据库管理连接。
  let database: Client;
  // 只有确认空 schema 才允许最终清理。
  let ownsSchema = false;
  // 当前真实 Nest HTTP 应用。
  let app: INestApplication;
  // 动态本机端口。
  let baseUrl: string;
  // 从统一公网配置推导的厂商取音地址。
  let publicAudioUrl: string;
  // 临时私有原音/密钥目录。
  let directory: string;
  // 实际数据访问和领域服务。
  let prisma: PrismaService;
  // 当前笔记领域实例。
  let notes: NotesService;
  // 真正同步服务。
  let sync: SyncService;
  // 实际磁盘存储。
  let store: TestAudioStore;
  // 显式MinIO集成时持有的共享连接，测试退出需要释放。
  let minio: MinioConnection | undefined;
  // 当前 HTTP 设备会话。
  let tokens: TokenPair;
  // 当前真实数据归属。
  let user: AuthUser;
  // 唯一被模拟的外部服务商网络，避免 CI 重复计费。
  const submit = jest.fn<Promise<string>, [{ model: string; bytes?: Buffer; audioUrl?: string }]>().mockResolvedValue('12345');
  // 持久相同 taskId 的查询结果。
  const poll = jest.fn().mockResolvedValue({ status: 'succeeded', transcript: '今天写了日报。' });
  // 唯一替换的模型网络，测试不会对真实供应商产生费用。
  const polish = jest.fn<Promise<string>, unknown[]>().mockResolvedValue('今天完成日报。');
  // 连接测试始终使用独立短文本边界，不需要真实密钥。
  const testModel = jest.fn().mockResolvedValue({ ok: true, message: '模型服务连接成功' });

  beforeAll(async () => {
    // 测试目标只允许本机显式 test 库，绝不清理已有 schema。
    const url = new URL(databaseUrl!);
    if (url.hostname !== '127.0.0.1' || !/^\/[A-Za-z0-9_]+_test$/.test(url.pathname)) throw new Error('笔记集成只允许本机独立 test 库');
    database = new Client({ connectionString: databaseUrl }); await database.connect();
    // 确认既有数据不存在。
    const tables = await database.query("SELECT tablename FROM pg_tables WHERE schemaname='public'");
    if (tables.rows.length) throw new Error('笔记集成要求空 schema，不清理既有数据库');
    if ((await database.query("SELECT 1 FROM pg_namespace WHERE nspname='assistant_graph'")).rows.length) throw new Error('笔记集成要求不存在助手私有 schema');
    ownsSchema = true;
    for (const migration of readdirSync(join(__dirname, '../prisma/migrations'), { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort()) await database.query(readFileSync(join(__dirname, '../prisma/migrations', migration, 'migration.sql'), 'utf8'));
    directory = mkdtempSync(join(tmpdir(), 'omni-notes-test-'));
    // 使用真实 RSA 认证与数据归属；不依赖正式 env 文件。
    const config = validateEnvironment({ DATABASE_URL: databaseUrl, SYNC_SECRET: syncKey, PUBLIC_BASE_URL: 'https://butler.example.test:8443/', JWT_KEYS_DIR: join(directory, 'keys'), ...(process.env.OMNI_NOTES_TEST_MINIO_ENDPOINT ? { MINIO_ENDPOINT: process.env.OMNI_NOTES_TEST_MINIO_ENDPOINT, MINIO_CREDENTIALS_FILE: process.env.OMNI_NOTES_TEST_MINIO_CREDENTIALS_FILE } : {}) });
    publicAudioUrl = config.NOTE_ASR_PUBLIC_URL;
    if (process.env.OMNI_NOTES_TEST_MINIO_ENDPOINT) {
      if (!process.env.OMNI_NOTES_TEST_MINIO_CREDENTIALS_FILE || new URL(config.MINIO_ENDPOINT).hostname !== '127.0.0.1') throw new Error('MinIO集成要求显式本机端点与测试凭证文件');
      minio = new MinioConnection(new ConfigService(config));
      store = new TestAudioStore(new MinioNoteAudioStore(minio));
    } else store = new TestAudioStore(new DiskTestNoteAudioStore(join(directory, 'audio')));
    // 实际模块保留控制器、DTO、数据库、鉴权和文件实现。
    const module = await Test.createTestingModule({ imports: [ConfigModule.forRoot({ isGlobal: true, ignoreEnvFile: true, load: [(): typeof config => config] }), PrismaModule, AuthModule, NotesModule, SyncModule] }).overrideProvider(SpeechRecognitionProvider).useValue({ name: 'tencent', configured: (): boolean => true, submit, poll }).overrideProvider(NoteAudioStore).useValue(store).overrideProvider(AiProvider).useValue({ polish, test: testModel }).compile();
    app = module.createNestApplication(); app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
    await app.listen(0, '127.0.0.1'); baseUrl = await app.getUrl();
    prisma = app.get(PrismaService); notes = app.get(NotesService); sync = app.get(SyncService);
  });
  beforeEach(async () => {
    if (!ownsSchema) throw new Error('测试库未初始化');
    await database.query('TRUNCATE sync_owners CASCADE'); await database.query('TRUNCATE sync_migration_receipts, note_audio_staging, note_audio_garbage');
    submit.mockReset().mockResolvedValue('12345'); poll.mockReset().mockResolvedValue({ status: 'succeeded', transcript: '今天写了日报。' }); store.failDelete = false; store.failPut = false;
      polish.mockReset().mockResolvedValue('今天完成日报。'); testModel.mockClear();
    app.get(ConfigService).set('NOTE_ASR_PUBLIC_URL', '');
    await prisma.syncOwner.create({ data: {} });
    tokens = await app.get(AuthService).connect(syncKey);
    // 从已建立的真实会话中读取数据归属。
    const response = await request('/auth/session'); user = await response.json() as AuthUser;
  });
  afterAll(async () => {
    if (minio && ownsSchema) {
      // 留下一份隔离桶真实对象事实供父任务复核；不含凭证或会话令牌。
      const fixture = await prisma.noteAudioAsset.findFirst({ include: { segment: true } });
      if (fixture) {
        mkdirSync(join(process.cwd(), '.local/notes-test'), { recursive: true });
        writeFileSync(join(process.cwd(), '.local/notes-test/minio-fixture.json'), JSON.stringify({ bucket: 'omni-butler-note-audio', objectKey: fixture.objectKey, sha256: fixture.segment.sha256, byteSize: fixture.segment.byteSize, mime: fixture.segment.mime }));
      }
    }
    await app?.close();
    minio?.onModuleDestroy();
    if (ownsSchema) { await database.query('DROP PUBLICATION IF EXISTS powersync'); await database.query('DROP SCHEMA IF EXISTS assistant_graph CASCADE; DROP SCHEMA public CASCADE; CREATE SCHEMA public'); }
    await database?.end();
    if (directory) rmSync(directory, { recursive: true, force: true });
  });

  it('两设备图片增删按独立身份合并，正文保存和迟到写入不丢图或复活', async () => {
    // 完整笔记主体不要求存在图片文件即可先同步业务身份。
    const sample = await seed();
    await sync.applyBatch(user.sub, batch([sample.operations[0]!]));
    // 第二设备拥有相同owner和独立有效会话。
    const deviceB = await app.get(AuthService).connect(syncKey);
    // 并发图片各自携带独立UUID。
    const imageIds = [randomUUID(), randomUUID()];
    // 稳定元数据不参与正文revision变更。
    const timestamp = new Date().toISOString();
    // 两台设备各自新增，不提交整篇图片数组。
    const additions: SyncOperationDto[] = imageIds.map((id) => ({ op: 'PUT', table: 'note_images', id, data: { note_id: sample.noteId, sort_order: 0, created_at: timestamp, updated_at: timestamp, deleted_at: null } }));
    expect((await request('/sync/operations', 'POST', batch([additions[0]!]))).status).toBe(200);
    expect((await request('/sync/operations', 'POST', batch([additions[1]!]), deviceB.accessToken)).status).toBe(200);
    expect(await prisma.noteImage.count({ where: { noteId: sample.noteId } })).toBe(2);
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { updated_at: timestamp } }]));
    expect(await prisma.noteImage.count({ where: { noteId: sample.noteId } })).toBe(2);
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_images', id: imageIds[0]!, data: { note_id: randomUUID() } }]))).status).toBe(400);
    await sync.applyBatch(user.sub, batch([{ op: 'DELETE', table: 'note_images', id: imageIds[0]! }]));
    expect(await prisma.noteImage.findMany({ where: { noteId: sample.noteId }, select: { id: true } })).toEqual([{ id: imageIds[1] }]);
    await sync.applyBatch(user.sub, batch([{ op: 'DELETE', table: 'note_entries', id: sample.noteId }]));
    expect(await prisma.noteImage.count({ where: { noteId: sample.noteId } })).toBe(0);
    expect((await sync.applyBatch(user.sub, batch([additions[1]!]))).ignored).toBe(1);
    expect(await prisma.noteImage.count({ where: { noteId: sample.noteId } })).toBe(0);
  });

  /// 用实际 token 请求 HTTP，undefined JSON 不添加无关 body。
  async function request(path: string, method = 'GET', body?: unknown, token: string | null = tokens.accessToken): Promise<Response> { return fetch(`${baseUrl}${path}`, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'X-Omni-Sync-Schema': String(syncSchemaVersion), ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }); }
  /// 构造稳定真实同步操作。
  function batch(operations: SyncOperationDto[]): { clientId: string; transactionId: string; operations: SyncOperationDto[] } { return { clientId: randomUUID(), transactionId: randomUUID(), operations }; }
  /// 构造可回听的测试 WAV，仅测试存储不向厂商发送此合成文件。
  function wav(): Buffer {
    // 一秒钟标准 PCM 静音容器，用于字节不丢失验证。
    const bytes = Buffer.alloc(32044); bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8); bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22); bytes.writeUInt32LE(16000, 24); bytes.writeUInt32LE(32000, 28); bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34); bytes.write('data', 36); bytes.writeUInt32LE(32000, 40); return bytes;
  }
  /// 准备严格完整的正文和原音快照行。
  async function seed(): Promise<{ noteId: string; segmentId: string; revision: string; bytes: Buffer; sha256: string; operations: SyncOperationDto[] }> {
    // 每个测试随机生成独立业务身份。
    const noteId = randomUUID();
    // 原音身份。
    const segmentId = randomUUID();
    // 首次正文修订。
    const revision = randomUUID();
    // 完整实际原音字节。
    const bytes = wav();
    // 内容摘要。
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    // 固定时刻只用于业务事实。
    const timestamp = new Date().toISOString();
    // 两个完整业务行符合迁移严格列协议。
    const operations: SyncOperationDto[] = [{ op: 'PUT', table: 'note_entries', id: noteId, data: { body: '用户已经编辑的正文', day_key: '2026-10-11', creation_timezone: 'Asia/Shanghai|+08:00', tags: '[]', revision, created_at: timestamp, updated_at: timestamp, deleted_at: null } }, { op: 'PUT', table: 'note_audio_segments', id: segmentId, data: { note_id: noteId, sort_order: 0, duration_ms: 1000, mime: 'audio/wav', sha256, byte_size: bytes.length, transcript: null, created_at: timestamp, updated_at: timestamp, deleted_at: null } }];
    await sync.applyBatch(user.sub, batch(operations)); return { noteId, segmentId, revision, bytes, sha256, operations };
  }
  /// 发真实 multipart 原音。
  async function upload(sample: Awaited<ReturnType<typeof seed>>): Promise<Response> {
    // multipart 字段顺序不要求客户端特殊处理。
    const form = new FormData(); form.set('noteId', sample.noteId); form.set('durationMs', '1000'); form.set('sha256', sample.sha256); form.set('file', new Blob([new Uint8Array(sample.bytes)], { type: 'audio/wav' }), 'note.wav');
    return fetch(`${baseUrl}/notes/audio/${sample.segmentId}`, { method: 'PUT', headers: { Authorization: `Bearer ${tokens.accessToken}` }, body: form });
  }
  /// 发真实迁移原音，密钥不进入 URL 和测试日志。
  async function stage(sample: Awaited<ReturnType<typeof seed>>, migrationId: string, key = syncKey): Promise<Response> {
    // 部署密钥使用表单正文，避免代理访问日志泄露。
    const form = new FormData(); form.set('syncKey', key); form.set('migrationId', migrationId); form.set('segmentId', sample.segmentId); form.set('sha256', sample.sha256); form.set('mime', 'audio/wav'); form.set('file', new Blob([new Uint8Array(sample.bytes)], { type: 'audio/wav' }), 'note.wav');
    return fetch(`${baseUrl}/notes/audio/migration/stage`, { method: 'PUT', body: form });
  }
  /// 创建真实笔记标签，后续合并仍需经过归属与类型验证。
  async function seedTags(count: number): Promise<string[]> {
    // 每个标签都有独立合法身份。
    const ids = Array.from({ length: count }, () => randomUUID());
    // 标签同步遵循同一创建时刻。
    const timestamp = new Date().toISOString();
    expect((await request('/sync/operations', 'POST', batch(ids.map((id, index) => ({ op: 'PUT', table: 'taxonomy_entries', id, data: { module: 'notes', kind: 'tag', name: `标签${index}`, sort_order: index, is_enabled: true, created_at: timestamp, updated_at: timestamp } }))))).status).toBe(200);
    return ids;
  }
  it('真实JWT拒绝无令牌，原音上传重放/摘要/范围回听正确且不跨归属', async () => {
    expect((await request('/notes/audio/capabilities', 'GET', undefined, null)).status).toBe(401);
    // 正常业务行和真实原音。
    const sample = await seed();
    expect((await upload(sample)).status).toBe(200); expect((await upload(sample)).status).toBe(200);
    // 已授权的完整下载。
    const downloaded = await request(`/notes/audio/${sample.segmentId}/file`); expect(downloaded.status).toBe(200); expect(Buffer.from(await downloaded.arrayBuffer())).toEqual(sample.bytes); expect(downloaded.headers.get('x-content-sha256')).toBe(sample.sha256);
    // Range 回听与错误范围。
    const range = await fetch(`${baseUrl}/notes/audio/${sample.segmentId}/file`, { headers: { Authorization: `Bearer ${tokens.accessToken}`, Range: 'bytes=0-11' } }); expect(range.status).toBe(206); expect(Buffer.from(await range.arrayBuffer())).toEqual(sample.bytes.subarray(0, 12));
    await expect(notes.download(randomUUID(), sample.segmentId)).rejects.toMatchObject({ status: 404 });
    expect((await upload({ ...sample, bytes: Buffer.from(sample.bytes).fill(1, 100, 101) })).status).toBe(400);
    expect(await prisma.noteAudioAsset.count()).toBe(1);
  });
  it('真实JWT上传存储失败不提交资产或成功回执，恢复同身份重试完整写入并清理租约', async () => {
    // 元数据已同步，但尚未存在任何有效存储资产。
    const sample = await seed();
    store.failPut = true;
    // 真实multipart请求经历鉴权、摘要校验、独立GC租约和失败事务回滚。
    const failed = await upload(sample);
    expect(failed.status).toBeGreaterThanOrEqual(400);
    expect(await failed.json()).not.toHaveProperty('segmentId');
    expect(await prisma.noteAudioAsset.count()).toBe(0);
    expect(await prisma.noteRecognitionJob.count()).toBe(0);
    expect(submit).not.toHaveBeenCalled();
    // 外围业务事务失败仍保留独立提交的孤立对象清理租约。
    const lease = await prisma.noteAudioGarbage.findFirstOrThrow();
    expect(lease.objectKey).toBe(`${user.sub}/${sample.segmentId}/${sample.sha256}`);
    expect(lease.dueAt.getTime()).toBeGreaterThan(Date.now());
    expect((await request(`/notes/audio/${sample.segmentId}/file`)).status).toBe(404);
    store.failPut = false;
    // 恢复后使用完全相同原音身份和真实MinIO，不能靠创建新段掩盖失败。
    const recovered = await upload(sample);
    expect(recovered.status).toBe(200);
    expect(await recovered.json()).toEqual({ segmentId: sample.segmentId, sha256: sample.sha256, byteSize: sample.bytes.length });
    expect(await prisma.noteAudioAsset.count()).toBe(1);
    expect(await prisma.noteAudioGarbage.count()).toBe(0);
    // 最终回执必须对应可下载且摘要正确的实际字节。
    const downloaded = await request(`/notes/audio/${sample.segmentId}/file`);
    expect(downloaded.status).toBe(200);
    expect(Buffer.from(await downloaded.arrayBuffer())).toEqual(sample.bytes);
    expect(downloaded.headers.get('x-content-sha256')).toBe(sample.sha256);
    expect(await prisma.noteRecognitionJob.count()).toBe(0);
    expect(submit).not.toHaveBeenCalled();
  });
  it('创建时区原样持久化并不可修改，旧行明确未知且空值被拒绝', async () => {
    // 客户端保存的地区名称与当时偏移是独立创建事实。
    const sample = await seed();
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).creationTimezone).toBe('Asia/Shanghai|+08:00');
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { creation_timezone: 'Europe/London|+01:00' } }]))).status).toBe(400);
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { creation_timezone: 'Asia/Shanghai|+08:00', day_key: '2026-10-12' } }]))).status).toBe(200);
    // 数据库级约束也保护绕过同步服务的更新。
    await expect(prisma.noteEntry.update({ where: { id: sample.noteId }, data: { creationTimezone: 'changed' } })).rejects.toThrow();
    // 旧版完整行没有时区，保留诚实的未知状态，不从服务器位置补猜。
    const legacy = { ...sample.operations[0]!, id: randomUUID(), data: { ...sample.operations[0]!.data } };
    delete legacy.data.creation_timezone;
    await sync.applyBatch(user.sub, batch([legacy]));
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: legacy.id } })).creationTimezone).toBe('legacy:unknown');
    for (const creation_timezone of ['', ' ', null, 'x'.repeat(129)]) {
      expect((await request('/sync/operations', 'POST', batch([{ ...legacy, id: randomUUID(), data: { ...legacy.data, creation_timezone } }]))).status).toBe(400);
    }
  });
  it('创建时区增量迁移保留升级前正文和时间，不猜测旧设备地区', async () => {
    // 本例独立schema只在已确认隔离的测试数据库中创建。
    const schema = `notes_timezone_${randomUUID().replaceAll('-', '')}`;
    // 独立连接的search_path不能影响应用Prisma连接池。
    const upgrade = new Client({ connectionString: databaseUrl }); await upgrade.connect();
    try {
      await upgrade.query(`CREATE SCHEMA ${schema}`); await upgrade.query(`SET search_path TO ${schema},public`);
      // 原始迁移中的完整旧表定义，模拟用户已经录入数据的升级。
      const original = readFileSync(join(__dirname, '../prisma/migrations/20261011010000_notes/migration.sql'), 'utf8');
      // 只取旧表定义，不重新创建发布订阅及其他已有模块。
      const start = original.indexOf('CREATE TABLE note_entries (');
      await upgrade.query(original.slice(start, original.indexOf('\n);', start) + 3));
      // 升级前不可恢复原时区的实际笔记事实。
      const id = randomUUID();
      await upgrade.query("INSERT INTO note_entries(id,user_id,body,day_key,revision,created_at,updated_at) VALUES($1,$2,'升级前正文','2026-10-11',$3,'2026-10-11T09:00:00+08:00','2026-10-11T09:00:00+08:00')", [id, user.sub, randomUUID()]);
      await upgrade.query(readFileSync(join(__dirname, '../prisma/migrations/20261011020000_note_creation_timezone/migration.sql'), 'utf8'));
      // UTC瞬间和原始文字均与升级前相同，来源地区明确未知。
      const row = await upgrade.query<{ body: string; created_at: Date; creation_timezone: string }>('SELECT body,created_at,creation_timezone FROM note_entries WHERE id=$1', [id]);
      expect(row.rows[0]!.body).toBe('升级前正文'); expect(row.rows[0]!.created_at.toISOString()).toBe('2026-10-11T01:00:00.000Z'); expect(row.rows[0]!.creation_timezone).toBe('legacy:unknown');
    } finally {
      await upgrade.query('SET search_path TO public'); await upgrade.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`); await upgrade.end();
    }
  });
  it('两端置顶按接收顺序生效，重放不覆盖新状态且旧正文编辑保留置顶', async () => {
    // 历史创建负载缺少置顶字段，由数据库默认为 false。
    const sample = await seed();
    // 正文与创建事实用于验证置顶差量不会产生额外版本。
    const original = await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } });
    expect(original.isPinned).toBe(false);
    // 两端时钟反序，置顶仍按服务端事务接收顺序采用。
    const pin = batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { is_pinned: true, updated_at: '2026-10-19T10:00:00Z' } }]);
    // 明确的取消置顶独立于正文草稿。
    const unpin = batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { is_pinned: false, updated_at: '2026-10-18T10:00:00Z' } }]);
    expect((await request('/sync/operations', 'POST', pin)).status).toBe(200);
    expect((await request('/sync/operations', 'POST', unpin)).status).toBe(200);
    expect(await (await request('/sync/operations', 'POST', pin)).json()).toMatchObject({ replayed: true });
    expect(await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).toMatchObject({ isPinned: false, body: original.body, revision: original.revision, createdAt: original.createdAt });
    expect(await prisma.noteVersion.count({ where: { noteId: sample.noteId } })).toBe(0);
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { is_pinned: true } }]));
    // 旧设备正文保存不含置顶字段，不能把缓存的未置顶状态覆盖回去。
    const revision = randomUUID();
    await sync.applyBatch(user.sub, batch([
      { op: 'PUT', table: 'note_versions', id: randomUUID(), data: { note_id: sample.noteId, body: '旧草稿正文', base_revision: sample.revision, revision, created_at: new Date().toISOString(), deleted_at: null } },
      { op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { body: '旧草稿正文', revision } },
    ]));
    expect(await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).toMatchObject({ isPinned: true, body: '旧草稿正文', revision });
    expect(await prisma.noteVersion.count({ where: { noteId: sample.noteId } })).toBe(1);
    for (const isPinned of [0, 1, 'true', null]) {
      expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { is_pinned: isPinned } }]))).status).toBe(400);
    }
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).isPinned).toBe(true);
  });
  it('笔记置顶迁移保留旧事实并默认为未置顶', async () => {
    // 仅在显式隔离测试库内验证 PostgreSQL 增量迁移。
    const schema = `notes_pinning_${randomUUID().replaceAll('-', '')}`;
    // 独立连接避免改变应用连接池的 search_path。
    const upgrade = new Client({ connectionString: databaseUrl }); await upgrade.connect();
    try {
      await upgrade.query(`CREATE SCHEMA ${schema}`); await upgrade.query(`SET search_path TO ${schema},public`);
      await upgrade.query('CREATE TABLE note_entries (id uuid PRIMARY KEY, body text NOT NULL, updated_at timestamptz NOT NULL)');
      // 升级前真实正文与时间必须逐字段保留。
      const id = randomUUID();
      await upgrade.query("INSERT INTO note_entries VALUES($1,'旧正文','2020-01-01T00:00:01Z')", [id]);
      // 迁移不改旧数据，也不能引入可空置顶状态。
      const before = (await upgrade.query<Record<string, unknown>>('SELECT * FROM note_entries WHERE id=$1', [id])).rows[0]!;
      await upgrade.query(readFileSync(join(__dirname, '../prisma/migrations/20261019010000_note_pinning/migration.sql'), 'utf8'));
      expect((await upgrade.query('SELECT * FROM note_entries WHERE id=$1', [id])).rows[0]).toEqual({ ...before, is_pinned: false });
      await expect(upgrade.query('UPDATE note_entries SET is_pinned=NULL WHERE id=$1', [id])).rejects.toThrow();
      await upgrade.query('UPDATE note_entries SET is_pinned=true WHERE id=$1', [id]);
    } finally {
      await upgrade.query('SET search_path TO public'); await upgrade.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`); await upgrade.end();
    }
  });
  it.each([undefined, true, false])('wire v3 换服快照兼容新旧置顶字段：%s', async (isPinned) => {
    // 旧版种子故意缺少新元数据字段。
    const sample = await seed();
    // 新版置顶快照显式带值，旧版缺失则由数据库默认 false。
    const operations = sample.operations.map((operation): SyncOperationDto => operation.table === 'note_entries' && isPinned !== undefined ? { ...operation, data: { ...operation.data, is_pinned: isPinned } } : operation);
    // wire 仍为 v3，原音缺失必须按既有协议显式声明。
    const input = { syncKey, migrationId: randomUUID(), expectedOwnerId: user.sub, snapshotVersion: 3, omittedAudioIds: [sample.segmentId], operations };
    expect((await request('/sync/migrations', 'POST', input, null)).status).toBe(200);
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).isPinned).toBe(isPinned ?? false);
  });
  it('两端主动记录时间按接收顺序整组生效，重放不覆盖后来修改且不产生正文版本', async () => {
    // 首次创建保留旧格式，验证新增字段为空的真实存量记录。
    const sample = await seed();
    // 修改前完整记录用于核验正文、创建事实和版本身份不变。
    const original = await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } });
    // 两端时钟反序，接收顺序仍是唯一覆盖依据。
    const first = batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { day_key: '2024-02-29', record_time_seconds: 86399, record_utc_offset_minutes: 480, updated_at: '2026-10-19T10:00:00Z' } }]);
    // 第二设备的时间、偏移必须整体替换第一设备选择。
    const second = batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { day_key: '2020-01-02', record_time_seconds: 3661, record_utc_offset_minutes: -300, updated_at: '2026-10-18T10:00:00Z' } }]);
    expect((await request('/sync/operations', 'POST', first)).status).toBe(200);
    expect((await request('/sync/operations', 'POST', second)).status).toBe(200);
    expect(await (await request('/sync/operations', 'POST', first)).json()).toMatchObject({ replayed: true });
    // 旧正文编辑只提交正文相关差量，不应带回缓存中的记录日期。
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { updated_at: new Date().toISOString() } }]));
    expect(await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).toMatchObject({ dayKey: '2020-01-02', recordTimeSeconds: 3661, recordUtcOffsetMinutes: -300, body: original.body, revision: original.revision, createdAt: original.createdAt, creationTimezone: original.creationTimezone });
    expect(await prisma.noteVersion.count({ where: { noteId: sample.noteId } })).toBe(0);
  });
  it('旧仅日期队列补全当前时间且不改变原始回执摘要，非法新时间整事务回滚', async () => {
    // 真实存量时间为空，首次旧日期差量必须按创建偏移稳定补全。
    const sample = await seed();
    // 使用已保存创建事实计算期望值，不受测试机当前地区影响。
    const original = await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } });
    // 创建自然时刻只用于校验兼容默认。
    const wallTime = new Date(original.createdAt.getTime() + 480 * 60000);
    // 秒精度舍弃毫秒。
    const seconds = wallTime.getUTCHours() * 3600 + wallTime.getUTCMinutes() * 60 + wallTime.getUTCSeconds();
    // 原始请求不包含新字段，重放必须仍匹配同一摘要。
    const legacy = batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { day_key: '2024-01-01' } }]);
    expect((await request('/sync/operations', 'POST', legacy)).status).toBe(200);
    expect(legacy.operations[0]!.data).toEqual({ day_key: '2024-01-01' });
    expect(await (await request('/sync/operations', 'POST', legacy)).json()).toMatchObject({ replayed: true });
    expect(await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).toMatchObject({ dayKey: '2024-01-01', recordTimeSeconds: seconds, recordUtcOffsetMinutes: 480 });
    // 先发生的合法差量也必须随未来时间错误回滚。
    const invalid = batch([
      { op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { day_key: '2024-02-02' } },
      { op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { day_key: '2999-01-01', record_time_seconds: 1, record_utc_offset_minutes: 0 } },
    ]);
    expect((await request('/sync/operations', 'POST', invalid)).status).toBe(400);
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).dayKey).toBe('2024-01-01');
    // 数据库约束防止任何绕过同步协议的半组更新。
    await expect(prisma.noteEntry.update({ where: { id: sample.noteId }, data: { recordTimeSeconds: null } })).rejects.toThrow();
  });
  it('记录时间迁移保留旧行所有事实，新增两列为空并限制非法时间组', async () => {
    // 仅在已确认隔离的测试库内创建独立 schema。
    const schema = `notes_record_time_${randomUUID().replaceAll('-', '')}`;
    // 独立连接的 search_path 不影响应用连接池。
    const upgrade = new Client({ connectionString: databaseUrl }); await upgrade.connect();
    try {
      await upgrade.query(`CREATE SCHEMA ${schema}`); await upgrade.query(`SET search_path TO ${schema},public`);
      // 仅复现升级前最小真实列；本迁移不依赖其他业务表。
      await upgrade.query('CREATE TABLE note_entries (id uuid PRIMARY KEY, body text NOT NULL, day_key text NOT NULL, created_at timestamptz NOT NULL)');
      // 老用户曾有未来归档日期，迁移不能据当前选择范围丢弃它。
      const id = randomUUID();
      await upgrade.query("INSERT INTO note_entries VALUES($1,'旧正文','2999-12-31','2020-01-01T00:00:01Z')", [id]);
      // 升级前完整数据库行用于逐字段保留验证。
      const before = (await upgrade.query<Record<string, unknown>>('SELECT * FROM note_entries WHERE id=$1', [id])).rows[0]!;
      await upgrade.query(readFileSync(join(__dirname, '../prisma/migrations/20261019000000_note_record_time/migration.sql'), 'utf8'));
      expect((await upgrade.query('SELECT * FROM note_entries WHERE id=$1', [id])).rows[0]).toEqual({ ...before, record_time_seconds: null, record_utc_offset_minutes: null });
      await expect(upgrade.query('UPDATE note_entries SET record_time_seconds=0 WHERE id=$1', [id])).rejects.toThrow();
      await expect(upgrade.query('UPDATE note_entries SET record_time_seconds=86400,record_utc_offset_minutes=0 WHERE id=$1', [id])).rejects.toThrow();
      await upgrade.query('UPDATE note_entries SET record_time_seconds=86399,record_utc_offset_minutes=-840 WHERE id=$1', [id]);
    } finally {
      await upgrade.query('SET search_path TO public'); await upgrade.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`); await upgrade.end();
    }
  });
  it('v3 完整换服快照往返记录时间，不把历史归档日期重新判成主动选择', async () => {
    // 历史快照包含原音元数据，明确省略缺失文件。
    const sample = await seed();
    // 新增字段只写入对应的笔记行，其他表保持完整事实。
    const operations = sample.operations.map((operation): SyncOperationDto => operation.table === 'note_entries' ? { ...operation, data: { ...operation.data, day_key: '2999-12-31', record_time_seconds: 86399, record_utc_offset_minutes: 840 } } : operation);
    // wire 协议仍为 v3，不因本机快照升级而改变幂等内容定义。
    const input = { syncKey, migrationId: randomUUID(), expectedOwnerId: user.sub, snapshotVersion: 3, omittedAudioIds: [sample.segmentId], operations };
    // 迁移成功后旧 JWT 被撤销，直接检验新归属数据。
    const response = await request('/sync/migrations', 'POST', input, null);
    expect(response.status).toBe(200);
    expect(await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).toMatchObject({ dayKey: '2999-12-31', recordTimeSeconds: 86399, recordUtcOffsetMinutes: 840 });
  });
  it('并发识别只持久创建/提交一次，结果保留原文且不覆盖用户正文', async () => {
    // 已上传的原音。
    const sample = await seed(); await upload(sample);
    // 同一原音同时来自两台设备的不同操作身份。
    const [first, second] = await Promise.all([notes.recognize(user, sample.segmentId, randomUUID(), true), notes.recognize(user, sample.segmentId, randomUUID(), true)]);
    expect(first.id).toBe(second.id); expect(await prisma.noteRecognitionJob.count()).toBe(1);
    await notes.tick(); expect(submit).toHaveBeenCalledTimes(1);
    await prisma.noteRecognitionJob.update({ where: { id: first.id }, data: { nextPollAt: new Date(0) } }); await notes.tick();
    expect((await notes.current(user, sample.segmentId))?.status).toBe('succeeded'); expect((await prisma.noteAudioSegment.findUnique({ where: { id: sample.segmentId } }))?.transcript).toBe('今天写了日报。');
    expect((await prisma.noteEntry.findUnique({ where: { id: sample.noteId } }))?.body).toBe('用户已经编辑的正文');
    expect((await notes.recognize(user, sample.segmentId, first.id, true)).id).toBe(first.id); expect(submit).toHaveBeenCalledTimes(1);
  });
  it('双设备真实JWT重新识别分别返回任务候选与共享原文，下行未到达也不能覆盖原文', async () => {
    // A设备先完成第一次转写，B设备本机是否已下行不影响接口原始事实。
    const sample = await seed(); await upload(sample);
    // 首次持久任务身份。
    const firstId = randomUUID();
    // B持有独立设备会话但属于同一同步空间。
    const deviceB = await app.get(AuthService).connect(syncKey);
    expect(deviceB.accessToken).not.toBe(tokens.accessToken);
    expect(await (await request('/auth/session', 'GET', undefined, deviceB.accessToken)).json()).toMatchObject({ sub: user.sub });
    expect(await notes.current(user, sample.segmentId)).toBeNull();
    expect(await (await request(`/notes/audio/${sample.segmentId}/recognitions`, 'POST', { operationId: firstId, consent: true })).json()).toMatchObject({ id: firstId, status: 'queued', transcript: null, canonicalTranscript: null });
    await notes.tick(); await prisma.noteRecognitionJob.update({ where: { id: firstId }, data: { nextPollAt: new Date(0) } }); await notes.tick();
    expect(await (await request(`/notes/audio/${sample.segmentId}/recognitions/current`)).json()).toMatchObject({ transcript: '今天写了日报。', canonicalTranscript: '今天写了日报。' });
    // B重新授权时服务端已知原文，排队状态也带原始共享字段。
    const secondId = randomUUID();
    expect(await (await request(`/notes/audio/${sample.segmentId}/recognitions`, 'POST', { operationId: secondId, consent: true }, deviceB.accessToken)).json()).toMatchObject({ id: secondId, status: 'queued', transcript: null, canonicalTranscript: '今天写了日报。' });
    expect(await (await request(`/notes/audio/${sample.segmentId}/recognitions`, 'POST', { operationId: randomUUID(), consent: true })).json()).toMatchObject({ id: secondId, canonicalTranscript: '今天写了日报。' });
    poll.mockResolvedValueOnce({ status: 'succeeded', transcript: '第二次识别的新候选。' });
    await notes.tick(); await prisma.noteRecognitionJob.update({ where: { id: secondId }, data: { nextPollAt: new Date(0) } }); await notes.tick();
    // 最新GET和准确操作POST回执均同时给出候选与原文，不能借本机null状态误写候选。
    for (const [response, status] of [
      [await request(`/notes/audio/${sample.segmentId}/recognitions/current`, 'GET', undefined, deviceB.accessToken), 200],
      [await request(`/notes/audio/${sample.segmentId}/recognitions`, 'POST', { operationId: secondId, consent: true }, deviceB.accessToken), 201],
    ] as const) {
      expect(response.status).toBe(status);
      expect(await response.json()).toEqual({ id: secondId, segmentId: sample.segmentId, status: 'succeeded', transcript: '第二次识别的新候选。', canonicalTranscript: '今天写了日报。', errorCode: null });
    }
    expect(await (await request(`/notes/audio/${sample.segmentId}/recognitions`, 'POST', { operationId: firstId, consent: true }, deviceB.accessToken)).json()).toMatchObject({ id: firstId, transcript: '今天写了日报。', canonicalTranscript: '今天写了日报。' });
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_audio_segments', id: sample.segmentId, data: { transcript: '第二次识别的新候选。' } }]), deviceB.accessToken)).status).toBe(400);
    expect((await prisma.noteAudioSegment.findUniqueOrThrow({ where: { id: sample.segmentId } })).transcript).toBe('今天写了日报。');
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).body).toBe('用户已经编辑的正文');
    expect(submit).toHaveBeenCalledTimes(2); expect(await prisma.noteRecognitionJob.count()).toBe(2);
  });
  it('提交响应丢失及提交阶段重启都不自动重复计费；撤回未知任务也不允许新建', async () => {
    // 用明确网络不确定故障验证任务恢复。
    const sample = await seed(); await upload(sample); submit.mockRejectedValueOnce(new SpeechProviderError('ASR_NETWORK_ERROR', true));
    // 首次持久任务。
    const job = await notes.recognize(user, sample.segmentId, randomUUID(), true); await notes.tick();
    expect((await notes.current(user, sample.segmentId))?.status).toBe('submissionUnknown'); await notes.tick(); await notes.cancel(user, sample.segmentId);
    expect((await notes.recognize(user, sample.segmentId, randomUUID(), true)).id).toBe(job.id); expect(submit).toHaveBeenCalledTimes(1);
    await prisma.noteRecognitionJob.update({ where: { id: job.id }, data: { status: 'submitting', updatedAt: new Date(Date.now() - 180000) } }); await notes.tick();
    expect((await notes.current(user, sample.segmentId))?.status).toBe('submissionUnknown'); expect(submit).toHaveBeenCalledTimes(1);
  });
  it('未提交撤回/回收站停止识别，恢复原音可回听，永久删除事务提交后可靠清理', async () => {
    // 完整原音和已授权任务。
    const sample = await seed(); await upload(sample); await notes.recognize(user, sample.segmentId, randomUUID(), true); await notes.cancel(user, sample.segmentId); await notes.tick(); expect(submit).not.toHaveBeenCalled();
    // 软删仍保留原音。
    const deletedAt = new Date().toISOString(); await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { deleted_at: deletedAt, updated_at: deletedAt } }]));
    await expect(notes.recognize(user, sample.segmentId, randomUUID(), true)).rejects.toMatchObject({ status: 409 }); expect((await request(`/notes/audio/${sample.segmentId}/file`)).status).toBe(200);
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { deleted_at: null, updated_at: new Date().toISOString() } }]));
    // 原音真实路径仅服务端使用。
    const asset = await prisma.noteAudioAsset.findUniqueOrThrow({ where: { segmentId: sample.segmentId } });
    store.failDelete = true; await sync.applyBatch(user.sub, batch([{ op: 'DELETE', table: 'note_entries', id: sample.noteId }]));
    expect(await prisma.noteAudioSegment.count()).toBe(0); expect(await prisma.noteRecognitionJob.count()).toBe(0); expect(await prisma.noteAudioGarbage.count()).toBe(1); expect((await store.get(asset.objectKey)).length).toBe(sample.bytes.length);
    await notes.tick(); expect(await prisma.noteAudioGarbage.count()).toBe(1); store.failDelete = false; await notes.tick(); expect(await prisma.noteAudioGarbage.count()).toBe(0); await expect(store.get(asset.objectKey)).rejects.toThrow();
    await sync.applyBatch(user.sub, batch(sample.operations)); expect(await prisma.noteEntry.count()).toBe(0); expect(await prisma.noteAudioSegment.count()).toBe(0);
  });
  it('离线并发正文保留完整候选且删除优先于迟到普通编辑', async () => {
    // 相同编辑起点的两份正文。
    const sample = await seed();
    // 分别提交候选和正文，先到修订采用、后到候选完整保留。
    for (const body of ['设备A完成内容', '设备B离线内容']) {
      // 新修订身份不能复用旧候选。
      const revision = randomUUID();
      await sync.applyBatch(user.sub, batch([{ op: 'PUT', table: 'note_versions', id: randomUUID(), data: { note_id: sample.noteId, body, base_revision: sample.revision, revision, created_at: new Date().toISOString(), deleted_at: null } }, { op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { body, revision, updated_at: new Date().toISOString() } }]));
    }
    expect((await prisma.noteEntry.findUnique({ where: { id: sample.noteId } }))?.body).toBe('设备A完成内容'); expect(await prisma.noteVersion.count()).toBe(2);
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { deleted_at: new Date().toISOString() } }]));
    // 回收站里的普通元数据编辑不恢复原行。
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { day_key: '2026-10-10' } }]));
    expect((await prisma.noteEntry.findUnique({ where: { id: sample.noteId } }))?.dayKey).toBe('2026-10-11');
  });
  it('旧笔记类别退休后标签继续有效，候选正文随整篇删除与恢复', async () => {
    // 完整业务事实和首版候选正文。
    const sample = await seed();
    // 候选身份与分类身份相互独立。
    const versionId = randomUUID();
    // 笔记模块内的分类。
    const categoryId = randomUUID();
    // 笔记模块内的标签。
    const tagId = randomUUID();
    // 业务写入使用相同可追溯时刻。
    const timestamp = new Date().toISOString();
    await sync.applyBatch(user.sub, batch([
      { op: 'PUT', table: 'note_versions', id: versionId, data: { note_id: sample.noteId, body: '用户已经编辑的正文', base_revision: sample.revision, revision: sample.revision, created_at: timestamp, deleted_at: null } },
      ...[categoryId, tagId].map((id, index): SyncOperationDto => ({ op: 'PUT', table: 'taxonomy_entries', id, data: { module: 'notes', kind: index ? 'tag' : 'category', name: index ? '日常' : '日报', color_value: null, sort_order: index, is_enabled: true, created_at: timestamp, updated_at: timestamp, deleted_at: null } })),
      { op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { category_id: categoryId, category_name: '日报', tags: JSON.stringify([tagId]), tags_base: '[]' } },
    ]));
    expect(await prisma.taxonomyEntry.findUnique({ where: { id: categoryId } })).toBeNull();
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).tags).toBe(JSON.stringify([tagId]));
    // 不允许以同步 PATCH 改掉任何原始版本事实。
    for (const data of [{ body: '篡改正文' }, { base_revision: randomUUID() }, { revision: randomUUID() }, { note_id: randomUUID() }, { created_at: timestamp }]) {
      expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_versions', id: versionId, data }]))).status).toBe(400);
    }
    // 整篇回收站生命周期允许候选跟随，正文事实保持原样。
    for (const deletedAt of [timestamp, null]) {
      expect((await request('/sync/operations', 'POST', batch([
        { op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { deleted_at: deletedAt } },
        { op: 'PATCH', table: 'note_versions', id: versionId, data: { deleted_at: deletedAt } },
        { op: 'PATCH', table: 'note_audio_segments', id: sample.segmentId, data: { deleted_at: deletedAt } },
      ]))).status).toBe(200);
      expect((await prisma.noteVersion.findUniqueOrThrow({ where: { id: versionId } })).deletedAt?.toISOString() ?? null).toBe(deletedAt);
    }
    expect((await prisma.noteVersion.findUniqueOrThrow({ where: { id: versionId } })).body).toBe('用户已经编辑的正文');
    // 迟到类别操作仅保留旧队列意图，不能复活退休类别。
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { category_id: null } }]));
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'taxonomy_entries', id: categoryId, data: { module: 'todo' } }]));
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { category_id: categoryId } }]))).status).toBe(200);
  });
  it('类别增量迁移删列及类别关联，保留笔记事实、标签、其他模块和删除墓碑', async () => {
    // 本例只在当前隔离测试库中创建专属旧结构。
    const schema = `notes_categories_${randomUUID().replaceAll('-', '')}`;
    // 独立连接避免影响应用连接池的默认schema。
    const upgrade = new Client({ connectionString: databaseUrl });
    await upgrade.connect();
    try {
      await upgrade.query(`CREATE SCHEMA ${schema}`);
      await upgrade.query(`SET search_path TO ${schema},public`);
      await upgrade.query('CREATE TABLE taxonomy_entries (LIKE public.taxonomy_entries INCLUDING ALL)');
      await upgrade.query('ALTER TABLE taxonomy_entries DROP CONSTRAINT taxonomy_notes_category_retired');
      // LIKE 当前表也复制了后续颜色退休约束，旧结构夹具需一并移除。
      await upgrade.query('ALTER TABLE taxonomy_entries DROP CONSTRAINT note_tags_have_no_color');
      await upgrade.query('CREATE TABLE record_taxonomy_links (LIKE public.record_taxonomy_links INCLUDING ALL)');
      await upgrade.query('ALTER TABLE record_taxonomy_links ADD FOREIGN KEY(user_id,taxonomy_id) REFERENCES taxonomy_entries(user_id,id) ON DELETE CASCADE');
      await upgrade.query('CREATE TABLE note_entries (LIKE public.note_entries INCLUDING ALL)');
      await upgrade.query('ALTER TABLE note_entries ADD category_id UUID, ADD category_name VARCHAR(80)');
      await upgrade.query('CREATE TABLE sync_tombstones (LIKE public.sync_tombstones INCLUDING ALL)');
      // 与正式数据库相同的删除触发器同时覆盖外键级联。
      for (const table of ['taxonomy_entries', 'record_taxonomy_links']) {
        await upgrade.query(`CREATE TRIGGER sync_deletion_tombstone AFTER DELETE ON ${table} FOR EACH ROW EXECUTE FUNCTION public.remember_sync_deletion()`);
      }
      // 活动类别、已删类别、笔记标签和三个其他模块类别各有独立身份。
      const ids = Array.from({ length: 6 }, () => randomUUID());
      // 各身份对应的原业务模块及种类。
      const kinds = [['notes', 'category'], ['notes', 'category'], ['notes', 'tag'], ['inventory', 'category'], ['membership', 'category'], ['timeline', 'category']];
      for (let index = 0; index < ids.length; index += 1) {
        await upgrade.query('INSERT INTO taxonomy_entries(id,user_id,module,kind,name,color_value,sort_order,is_enabled,created_at,updated_at,deleted_at) VALUES($1,$2,$3,$4,$5,123,0,true,now(),now(),$6)', [ids[index], user.sub, kinds[index]![0], kinds[index]![1], `保留或退休${index}`, index === 1 ? new Date() : null]);
      }
      // 笔记主体及关联在迁移前完整存在。
      const noteId = randomUUID();
      await upgrade.query("INSERT INTO note_entries(id,user_id,body,day_key,tags,revision,created_at,updated_at,category_id,category_name) VALUES($1,$2,'保留正文','2026-10-12',$3,$4,now(),now(),$5,'退休名称')", [noteId, user.sub, JSON.stringify([ids[2]]), randomUUID(), ids[0]]);
      // 一条旧类别关联和一条有效标签关联用于验证精确级联。
      const links = [randomUUID(), randomUUID()];
      for (let index = 0; index < links.length; index += 1) {
        await upgrade.query("INSERT INTO record_taxonomy_links(id,user_id,module,record_id,taxonomy_id,created_at) VALUES($1,$2,'notes',$3,$4,now())", [links[index], user.sub, noteId, ids[index === 0 ? 0 : 2]]);
      }
      // 迁移前已排除退休字段的笔记事实必须逐字段保持一致。
      const beforeNote = await upgrade.query("SELECT to_jsonb(note_entries)-'category_id'-'category_name' AS data FROM note_entries");
      // 当前仍有效的分类标签必须逐字段保持一致。
      const beforeTaxonomy = await upgrade.query("SELECT * FROM taxonomy_entries WHERE NOT(module='notes' AND kind='category') ORDER BY id");
      await upgrade.query(readFileSync(join(__dirname, '../prisma/migrations/20261012000000_remove_note_categories/migration.sql'), 'utf8'));
      expect((await upgrade.query('SELECT to_jsonb(note_entries) AS data FROM note_entries')).rows).toEqual(beforeNote.rows);
      expect((await upgrade.query('SELECT * FROM taxonomy_entries ORDER BY id')).rows).toEqual(beforeTaxonomy.rows);
      expect((await upgrade.query('SELECT id FROM record_taxonomy_links')).rows).toEqual([{ id: links[1] }]);
      expect((await upgrade.query('SELECT record_id FROM sync_tombstones ORDER BY record_id')).rows.map((row: { record_id: string }) => row.record_id)).toEqual([ids[0], ids[1], links[0]].sort());
      await expect(upgrade.query("INSERT INTO taxonomy_entries(id,user_id,module,kind,name,color_value,created_at,updated_at) VALUES($1,$2,'notes','category','拒绝',123,now(),now())", [randomUUID(), user.sub])).rejects.toThrow();
    } finally {
      await upgrade.query('SET search_path TO public');
      await upgrade.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
      await upgrade.end();
    }
  });
  it('旧离线类别队列写墓碑，迟到局部更新和关联不复活且其他模块继续同步', async () => {
    // 正式笔记和有效标签保持现有正文、版本和原音。
    const sample = await seed();
    // 一条退休类别、一条旧类别关联及一条有效物品类别。
    const [categoryId, linkId, inventoryCategoryId] = [randomUUID(), randomUUID(), randomUUID()];
    // 有效笔记标签必须经过原有基线合并协议。
    const [tagId] = await seedTags(1);
    // 原始混合事务在重试前后保持完全相同。
    const pending = batch([
      { op: 'PUT', table: 'taxonomy_entries', id: categoryId, data: { module: 'notes', kind: 'category', name: '离线类别' } },
      { op: 'PATCH', table: 'taxonomy_entries', id: categoryId, data: { name: '离线重命名' } },
      { op: 'PUT', table: 'record_taxonomy_links', id: linkId, data: { module: 'notes', record_id: sample.noteId, taxonomy_id: categoryId, created_at: new Date().toISOString() } },
      { op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { category_id: categoryId, category_name: '离线重命名', tags: JSON.stringify([tagId]), tags_base: '[]' } },
      { op: 'PUT', table: 'taxonomy_entries', id: inventoryCategoryId, data: { module: 'inventory', kind: 'category', name: '保留物品类别', color_value: 123, created_at: new Date().toISOString(), updated_at: new Date().toISOString() } },
    ]);
    // 首次真实HTTP上传后的负载仍与调用前一致。
    const original = JSON.stringify(pending);
    expect((await request('/sync/operations', 'POST', pending)).status).toBe(200);
    expect(JSON.stringify(pending)).toBe(original);
    expect(await (await request('/sync/operations', 'POST', pending)).json()).toMatchObject({ replayed: true });
    expect(await prisma.taxonomyEntry.findUnique({ where: { id: categoryId } })).toBeNull();
    expect(await prisma.recordTaxonomyLink.findUnique({ where: { id: linkId } })).toBeNull();
    expect(await prisma.syncTombstone.count({ where: { userId: user.sub, recordId: { in: [categoryId, linkId] } } })).toBe(2);
    expect((await prisma.taxonomyEntry.findUniqueOrThrow({ where: { id: inventoryCategoryId } })).name).toBe('保留物品类别');
    expect(await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).toMatchObject({ body: '用户已经编辑的正文', tags: JSON.stringify([tagId]) });
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { category_id: categoryId, category_name: '仅退休字段' } }]))).status).toBe(200);
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'taxonomy_entries', id: categoryId, data: { name: '迟到更新' } }, { op: 'PATCH', table: 'record_taxonomy_links', id: linkId, data: { deleted_at: null } }]))).status).toBe(200);
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PUT', table: 'taxonomy_entries', id: tagId!, data: { module: 'notes', kind: 'category', name: '身份碰撞' } }]))).status).toBe(409);
    expect((await prisma.taxonomyEntry.findUniqueOrThrow({ where: { id: tagId } })).kind).toBe('tag');
  });
  it('跨升级重放旧服务端回执沿用原始摘要且不重新执行退休事务', async () => {
    // 当前笔记已经代表服务器升级后的完整有效状态。
    const sample = await seed();
    // 该事务在旧服务器已提交，客户端尚未收到确认。
    const legacy = batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { category_id: randomUUID(), category_name: '旧服务端已保存的类别' } }]);
    await prisma.syncReceipt.create({ data: { userId: user.sub, clientId: legacy.clientId, transactionId: legacy.transactionId, payloadHash: createHash('sha256').update(JSON.stringify(canonicalize(legacy.operations))).digest('hex'), applied: 1, ignored: 0 } });
    expect(await (await request('/sync/operations', 'POST', legacy)).json()).toEqual({ applied: 1, ignored: 0, replayed: true });
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).body).toBe('用户已经编辑的正文');
    // 相同事务身份改变类别旧内容仍必须拒绝，不能削弱原幂等协议。
    const changed = { ...legacy, operations: [{ ...legacy.operations[0]!, data: { category_name: '不同旧内容' } }] };
    expect((await request('/sync/operations', 'POST', changed)).status).toBe(409);
  });
  it('离线双设备标签按基线增删合并，保留并发新增和移除且回执重放不再次应用', async () => {
    // 同一笔记与三个同归属标签。
    const sample = await seed();
    // x是编辑前已有标签，y/z分别由两台设备新增。
    const [x, y, z] = await seedTags(3);
    // B真实独立JWT与A共享数据归属。
    const deviceB = await app.get(AuthService).connect(syncKey);
    // 构造独立离线事务，基线明确来自客户端当时看到的状态。
    const change = (incoming: string[], base: string[]): ReturnType<typeof batch> => batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { tags: JSON.stringify(incoming), tags_base: JSON.stringify(base) } }]);
    expect((await request('/sync/operations', 'POST', change([x!], []))).status).toBe(200);
    // A的请求在B上传前已经确定，不能借最新服务器状态伪造基线。
    const offlineA = change([x!, z!], [x!]);
    expect((await request('/sync/operations', 'POST', change([x!, y!], [x!]), deviceB.accessToken)).status).toBe(200);
    expect((await request('/sync/operations', 'POST', offlineA)).status).toBe(200);
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).tags).toBe(JSON.stringify([x, y, z].sort()));
    expect(await (await request('/sync/operations', 'POST', offlineA)).json()).toMatchObject({ replayed: true });
    // 两端从相同xyz基线各移除不同标签，旧incoming不能复活已被另一端移除的标签。
    expect((await request('/sync/operations', 'POST', change([y!, z!], [x!, y!, z!]), deviceB.accessToken)).status).toBe(200);
    expect((await request('/sync/operations', 'POST', change([x!, z!], [x!, y!, z!]))).status).toBe(200);
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).tags).toBe(JSON.stringify([z]));
    expect((await request('/sync/operations', 'POST', change([], [z!]), deviceB.accessToken)).status).toBe(200);
    // 已提交的早期新增事务重放不能把后来删除的z复活。
    expect(await (await request('/sync/operations', 'POST', offlineA)).json()).toMatchObject({ replayed: true });
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).tags).toBe('[]');
    // 同一回执身份不能换基线；原始辅助字段仍参与幂等摘要。
    expect((await request('/sync/operations', 'POST', { ...offlineA, operations: [{ ...offlineA.operations[0], data: { tags: JSON.stringify([x!, z!]), tags_base: '[]' } }] })).status).toBe(409);
  });
  it('标签基线协议拒绝缺失、非JSON、非法UUID、重复、PUT辅助字段且不改当前行', async () => {
    // 空标签笔记和一个可用身份。
    const sample = await seed();
    // 合法标签用于隔离语法错误与归属错误。
    const [tag] = await seedTags(1);
    for (const data of [
      { tags: JSON.stringify([tag]) }, { tags_base: '[]' },
      { tags: '[]', tags_base: null }, { tags: '[]', tags_base: [] },
      { tags: '[]', tags_base: 'invalid' }, { tags: '[]', tags_base: '{}' },
      { tags: '[]', tags_base: '[1]' }, { tags: '[]', tags_base: '["not-uuid"]' },
      { tags: '[]', tags_base: JSON.stringify([tag, tag]) },
      { tags: JSON.stringify([tag, tag]), tags_base: '[]' },
    ]) expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data }]))).status).toBe(400);
    expect((await request('/sync/operations', 'POST', batch([{ ...sample.operations[0]!, id: randomUUID(), data: { ...sample.operations[0]!.data, tags_base: '[]' } }]))).status).toBe(400);
    // UUID有效但跨归属/类型不合法的新增仍由最终事务检查拒绝。
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { tags: JSON.stringify([randomUUID()]), tags_base: '[]' } }]))).status).toBe(400);
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).tags).toBe('[]');
  });
  it('并发合并超过十标签时整事务拒绝，合法十个保持完整且PUT和基线同样限额', async () => {
    // 九标签基线允许两端各加一个，最终并集十一必须拒绝而非静默截断。
    const sample = await seed();
    // 全部标签真实存在，限额失败不能归因于缺少taxonomy。
    const tags = await seedTags(11);
    // 离线共同起点。
    const base = tags.slice(0, 9);
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { tags: JSON.stringify(base), tags_base: '[]' } }]))).status).toBe(200);
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { tags: JSON.stringify(tags.slice(0, 10)), tags_base: JSON.stringify(base) } }]))).status).toBe(200);
    // 同一失败事务中的其他字段也必须回滚。
    expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { day_key: '2026-10-10' } }, { op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { tags: JSON.stringify([...base, tags[10]]), tags_base: JSON.stringify(base) } }]))).status).toBe(400);
    for (const data of [{ tags: JSON.stringify(tags), tags_base: '[]' }, { tags: '[]', tags_base: JSON.stringify(tags) }]) expect((await request('/sync/operations', 'POST', batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data }]))).status).toBe(400);
    expect((await request('/sync/operations', 'POST', batch([{ ...sample.operations[0]!, id: randomUUID(), data: { ...sample.operations[0]!.data, tags: JSON.stringify(tags) } }]))).status).toBe(400);
    expect(await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).toMatchObject({ tags: JSON.stringify(tags.slice(0, 10).sort()), dayKey: '2026-10-11' });
    expect(await prisma.noteEntry.count()).toBe(1);
    // 完整快照绕过单行归一化时仍限制十标签，不能删除现有归属后接受十一。
    const timestamp = new Date().toISOString();
    // 元数据完整且明确省略未上传原音，标签超限是唯一失败原因。
    const snapshot = { syncKey, migrationId: randomUUID(), expectedOwnerId: user.sub, snapshotVersion: 3, omittedAudioIds: [sample.segmentId], operations: [
      ...tags.map((id, index): SyncOperationDto => ({ op: 'PUT', table: 'taxonomy_entries', id, data: { module: 'notes', kind: 'tag', name: `迁移标签${index}`, sort_order: index, is_pinned: false, is_enabled: true, created_at: timestamp, updated_at: timestamp, deleted_at: null, color_value: null, icon_emoji: null } })),
      { ...sample.operations[0]!, data: { ...sample.operations[0]!.data, tags: JSON.stringify(tags) } }, sample.operations[1]!,
    ] };
    expect((await request('/sync/migrations', 'POST', snapshot, null)).status).toBe(400);
    expect((await prisma.syncOwner.findFirst())?.id).toBe(user.sub);
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).tags).toBe(JSON.stringify(tags.slice(0, 10).sort()));
  });
  it('真实 Flutter PowerSync 队列逐批通过 JWT HTTP，创建编辑分类原音删除恢复不阻塞', async () => {
    // 由真实仓储、SQLite 队列和生产上传连接器捕获，保留原始字段及事务顺序。
    const fixture = JSON.parse(readFileSync(join(__dirname, 'fixtures/notes-client-operations.json'), 'utf8').replace(/^\uFEFF/, '')) as { noteId: string; segmentId: string; categoryId: string; tagId: string; audioSha256: string; audioByteSize: number; transactions: Array<{ clientId: string; transactionId: string; operations: SyncOperationDto[] }>; expected: { body: string; revision: string; categoryName: string; tags: string[]; versionCount: number } };
    // 客户端 fixture 使用相同单声道十六位 PCM 容器。
    const bytes = wav();
    expect(createHash('sha256').update(bytes).digest('hex')).toBe(fixture.audioSha256); expect(bytes.length).toBe(fixture.audioByteSize);
    for (const transaction of fixture.transactions) {
      // 真实 HTTP 路径验证 DTO、设备鉴权、事务幂等与 PostgreSQL 类型转换。
      const response = await request('/sync/operations', 'POST', transaction);
      // 失败保留具体事务和响应，不能将同步队列受阻伪装成通过。
      const result = await response.json() as { applied: number; ignored: number; replayed: boolean; message?: string };
      expect({ transactionId: transaction.transactionId, status: response.status, error: result.message }).toEqual({ transactionId: transaction.transactionId, status: 200, error: undefined });
      expect(result.applied + result.ignored).toBe(transaction.operations.length);
      expect(await (await request('/sync/operations', 'POST', transaction)).json()).toMatchObject({ replayed: true });
      if (transaction.operations.some((operation) => operation.table === 'note_audio_segments' && operation.op === 'PUT')) {
        // 附件元数据提交之后才能上传私有文件。
        expect((await upload({ noteId: fixture.noteId, segmentId: fixture.segmentId, revision: fixture.expected.revision, bytes, sha256: fixture.audioSha256, operations: [] })).status).toBe(200);
      }
      if (transaction.operations.some((operation) => operation.table === 'note_entries' && operation.data?.deleted_at !== undefined)) {
        // 删除和恢复均同步所有版本，原音始终可回听。
        const deletedAt = transaction.operations.find((operation) => operation.table === 'note_entries')!.data!.deleted_at;
        expect(await prisma.noteVersion.count({ where: { noteId: fixture.noteId, deletedAt: deletedAt === null ? null : { not: null } } })).toBe(fixture.expected.versionCount);
        expect((await request(`/notes/audio/${fixture.segmentId}/file`)).status).toBe(200);
      }
    }
    expect(await prisma.noteEntry.findUniqueOrThrow({ where: { id: fixture.noteId } })).toMatchObject({ body: fixture.expected.body, revision: fixture.expected.revision, tags: JSON.stringify(fixture.expected.tags), deletedAt: null });
    expect(await prisma.noteAudioSegment.count()).toBe(1); expect(await prisma.noteVersion.count()).toBe(fixture.expected.versionCount);
    expect((await notes.download(user.sub, fixture.segmentId)).bytes).toEqual(bytes);
  });
  it('真实multipart暂存后原子迁移原音，缺文件拒绝且原快照不变，重放不重复覆盖', async () => {
    // 原服务器已有完整可读资产。
    const sample = await seed(); await upload(sample);
    // 客户端持久迁移身份。
    const migrationId = randomUUID();
    // 完整快照，包括原音真实字节的契约引用。
    const input = { syncKey, migrationId, expectedOwnerId: user.sub, snapshotVersion: 3, omittedAudioIds: [], operations: sample.operations };
    expect((await request('/sync/migrations', 'POST', input, null)).status).toBe(400); expect((await prisma.syncOwner.findFirst())?.id).toBe(user.sub);
    expect((await stage(sample, migrationId, 'wrong-key-at-least16')).status).toBe(401); expect((await stage(sample, migrationId)).status).toBe(200);
    // replace 不要求将要被撤销的旧设备JWT。
    const replaced = await request('/sync/migrations', 'POST', input, null); expect(replaced.status).toBe(200);
    // 原音完整转到新归属。
    const result = await replaced.json() as { ownerId: string; status: string }; expect(result.status).toBe('committed'); expect(result.ownerId).not.toBe(user.sub); expect((await notes.download(result.ownerId, sample.segmentId)).bytes).toEqual(sample.bytes);
    expect((await request('/auth/session')).status).toBe(401); expect(await prisma.noteAudioStaging.count()).toBe(0);
    expect((await stage(sample, migrationId)).status).toBe(200); expect((await request('/sync/migrations', 'POST', input, null)).status).toBe(200);
    await notes.tick(); expect((await notes.download(result.ownerId, sample.segmentId)).bytes).toEqual(sample.bytes);
  });
  it('只有显式确认省略原音才允许不完整迁移，元数据不伪装成可下载文件', async () => {
    // 元数据完整但未上传文件的笔记。
    const sample = await seed();
    // 明确、完整且无重复的缺失原音清单。
    const input = { syncKey, migrationId: randomUUID(), expectedOwnerId: user.sub, snapshotVersion: 3, omittedAudioIds: [sample.segmentId], operations: sample.operations };
    expect((await request('/sync/migrations', 'POST', { ...input, omittedAudioIds: [randomUUID()] }, null)).status).toBe(400);
    // 显式接受缺失后服务器保留音频事实但无资产引用。
    const response = await request('/sync/migrations', 'POST', input, null); expect(response.status).toBe(200);
    // 新归属仍能查到不可用音频，下载明确404。
    const result = await response.json() as { ownerId: string }; expect(await prisma.noteAudioSegment.count()).toBe(1); await expect(notes.download(result.ownerId, sample.segmentId)).rejects.toMatchObject({ status: 404 });
  });
  it('离线录音已整篇软删后首次联网仍能补传同一原音，恢复后完整回听', async () => {
    // 首次同步只上传含已删除状态的稳定事实。
    const sample = await seed();
    // 从未提交过真实文件的笔记先进入回收站。
    const deletedAt = new Date().toISOString();
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { deleted_at: deletedAt } }, { op: 'PATCH', table: 'note_audio_segments', id: sample.segmentId, data: { deleted_at: deletedAt } }]));
    expect((await upload(sample)).status).toBe(200); expect((await notes.download(user.sub, sample.segmentId)).bytes).toEqual(sample.bytes);
    await expect(notes.recognize(user, sample.segmentId, randomUUID(), true)).rejects.toMatchObject({ status: 409 });
    await sync.applyBatch(user.sub, batch([{ op: 'PATCH', table: 'note_entries', id: sample.noteId, data: { deleted_at: null } }, { op: 'PATCH', table: 'note_audio_segments', id: sample.segmentId, data: { deleted_at: null } }]));
    expect((await request(`/notes/audio/${sample.segmentId}/file`)).status).toBe(200);
  });
  it('旧GC回执不能删除重新暂存或已接管资产，覆盖前再次核验真实原音', async () => {
    // 已有可观察正文，不允许损坏暂存导致丢失原快照。
    const sample = await seed();
    // 当前完整迁移身份。
    const migrationId = randomUUID();
    await stage(sample, migrationId);
    // 同一个对象曾经被过期暂存加入清理列表。
    const staged = await prisma.noteAudioStaging.findUniqueOrThrow({ where: { migrationId_segmentId: { migrationId, segmentId: sample.segmentId } } });
    await prisma.noteAudioGarbage.create({ data: { objectKey: staged.objectKey } });
    await notes.tick(); expect((await store.get(staged.objectKey)).length).toBe(sample.bytes.length); expect(await prisma.noteAudioGarbage.count()).toBe(0);
    // 文件丢失或损坏，DB回执不能代替真实原音。
    const input = { syncKey, migrationId, expectedOwnerId: user.sub, snapshotVersion: 3, omittedAudioIds: [], operations: sample.operations };
    await store.put(staged.objectKey, Buffer.alloc(12), 'audio/wav');
    expect((await request('/sync/migrations', 'POST', input, null)).status).toBe(400); expect((await prisma.syncOwner.findFirst())?.id).toBe(user.sub);
    await stage(sample, migrationId); expect((await request('/sync/migrations', 'POST', input, null)).status).toBe(200);
    // 接管以后出现旧GC扫描也必须再次检查资产引用。
    await prisma.noteAudioGarbage.create({ data: { objectKey: staged.objectKey } }); await notes.tick(); expect((await store.get(staged.objectKey)).length).toBe(sample.bytes.length);
  });
  /// 真实设置接口创建并开启当前测试模型，所有密钥均为测试夹具。
  async function enableAi(): Promise<Awaited<ReturnType<AiService['settings']>>> {
    expect((await request('/ai/profiles', 'POST', { revision: 0, name: '集成模型', provider: 'deepseek', baseUrl: 'https://api.deepseek.com', model: 'test-original-model', apiKey: 'integration-only-key' })).status).toBe(201);
    // 读取固定掩码后的配置身份，不从响应获取 Key。
    const snapshot = await app.get(AiService).settings(user.sub);
    return app.get(AiService).updateSettings(user.sub, { revision: snapshot.revision, activeProfileId: snapshot.profiles[0]!.id, notePolishEnabled: true });
  }

  /// 完成 ASR 的真实数据库链路，只替换厂商网络。
  async function finishAsr(sample: Awaited<ReturnType<typeof seed>>, operationId = randomUUID()): Promise<string> {
    await upload(sample); await notes.recognize(user, sample.segmentId, operationId, true); await notes.tick();
    await prisma.noteRecognitionJob.update({ where: { id: operationId }, data: { nextPollAt: new Date(0) } });
    await notes.tick();
    expect((await prisma.noteRecognitionJob.findUniqueOrThrow({ where: { id: operationId } })).status).toBe('succeeded');
    return operationId;
  }

  it('AI 配置跨设备共享、总版本冲突、密钥不回传且删除当前配置关闭整理', async () => {
    // 两台设备共用数据归属和设置，凭据本身保持独立。
    const deviceB = await app.get(AuthService).connect(syncKey);
    expect((await request('/ai/settings', 'GET', undefined, null)).status).toBe(401);
    // 默认版本从零开始且整理关闭。
    expect(await (await request('/ai/settings')).json()).toMatchObject({ revision: 0, notePolishEnabled: false, profiles: [] });
    // 创建并开启后，另一设备只得到掩码。
    const snapshot = await enableAi();
    // 加密密文既不等于明文，也不出现在任何响应。
    const stored = await prisma.aiProfile.findFirstOrThrow({ where: { userId: user.sub } });
    expect(stored.encryptedApiKey).not.toContain('integration-only-key');
    // 两设备共享读取相同总版本。
    const shared = await (await request('/ai/settings', 'GET', undefined, deviceB.accessToken)).json() as typeof snapshot;
    expect(shared).toEqual(snapshot); expect(shared.profiles[0]).toMatchObject({ hasApiKey: true, maskedApiKey: '••••••••' });
    expect(JSON.stringify(shared)).not.toContain('integration-only-key'); expect(JSON.stringify(shared)).not.toContain(stored.encryptedApiKey!);
    expect((await request('/ai/settings', 'PUT', { revision: 0, activeProfileId: stored.id, notePolishEnabled: false })).status).toBe(409);
    // 留空保留 Key，测试连接不增加配置版本。
    expect((await request('/ai/profiles/' + stored.id, 'PUT', { revision: snapshot.revision, name: stored.name, provider: stored.provider, baseUrl: stored.baseUrl, model: stored.model, apiKey: '' })).status).toBe(200);
    expect((await prisma.aiProfile.findUniqueOrThrow({ where: { id: stored.id } })).encryptedApiKey).toBe(stored.encryptedApiKey);
    expect((await request('/ai/test', 'POST', { profileId: stored.id, provider: stored.provider, baseUrl: stored.baseUrl, model: stored.model, apiKey: '' })).status).toBe(201);
    expect(testModel).toHaveBeenCalledWith(expect.objectContaining({ apiKey: 'integration-only-key' }));
    // 删除后开关和选择一次关闭，不能静默选择另一个模型。
    const latest = await app.get(AiService).settings(user.sub);
    expect((await request('/ai/profiles/' + stored.id, 'DELETE', { revision: latest.revision })).status).toBe(200);
    expect(await app.get(AiService).settings(user.sub)).toMatchObject({ activeProfileId: null, notePolishEnabled: false, profiles: [] });
  });

  it('ASR 固定 AI 配置快照，整理保留原文且不直接修改用户正文', async () => {
    // 识别任务创建时固定原模型与加密 Key。
    const snapshot = await enableAi();
    // 已同步并上传的实际原音。
    const sample = await seed(); await upload(sample);
    // 新任务身份在供应商真正提交前已持久。
    const recognitionId = randomUUID();
    await notes.recognize(user, sample.segmentId, recognitionId, true);
    expect(await app.get(AiService).current(user.sub, sample.segmentId, recognitionId)).toMatchObject({ enabled: true, status: 'waiting' });
    // 编辑配置后旧任务仍调用原模型，不能被新目标改写。
    await app.get(AiService).saveProfile(user.sub, { revision: snapshot.revision, name: '已修改', provider: 'deepseek', baseUrl: 'https://api.deepseek.com', model: 'test-new-model', apiKey: 'replacement-test-key' }, snapshot.activeProfileId!);
    await notes.tick(); await prisma.noteRecognitionJob.update({ where: { id: recognitionId }, data: { nextPollAt: new Date(0) } }); await notes.tick();
    await app.get(AiService).tick();
    expect(polish).toHaveBeenCalledTimes(1); expect(polish).toHaveBeenCalledWith(expect.objectContaining({ model: 'test-original-model', apiKey: 'integration-only-key' }), '今天写了日报。', expect.any(AbortSignal));
    expect(await app.get(AiService).current(user.sub, sample.segmentId, recognitionId)).toMatchObject({ status: 'succeeded', text: '今天完成日报。', sourceHash: createHash('sha256').update('今天写了日报。').digest('hex') });
    expect((await prisma.notePolishJob.findFirstOrThrow({ where: { recognitionId } })).encryptedApiKey).toBeNull();
    expect((await prisma.noteAudioSegment.findUniqueOrThrow({ where: { id: sample.segmentId } })).transcript).toBe('今天写了日报。');
    expect((await prisma.noteEntry.findUniqueOrThrow({ where: { id: sample.noteId } })).body).toBe('用户已经编辑的正文');
  });

  it('关闭时创建的 ASR 永远 disabled，之后开启不追溯处理', async () => {
    // 关闭情况下正常完成原始识别。
    const sample = await seed();
    // 整理任务 disabled 事实和 ASR 同时持久。
    const recognitionId = await finishAsr(sample);
    await enableAi(); await app.get(AiService).tick();
    expect(await app.get(AiService).current(user.sub, sample.segmentId, recognitionId)).toMatchObject({ enabled: false, status: 'disabled', text: null });
    expect(polish).not.toHaveBeenCalled();
  });

  it('整理超时和处理中崩溃不自动重付费，显式 retry 重放只调用一次', async () => {
    await enableAi();
    // 原始 ASR 成功后整理收到超时未知提交。
    const sample = await seed();
    // 固定本次 ASR 和之后的新整理尝试身份。
    const recognitionId = await finishAsr(sample);
    polish.mockRejectedValueOnce(new AiProviderError('AI_TIMEOUT', true));
    await app.get(AiService).tick(); await app.get(AiService).tick();
    expect(polish).toHaveBeenCalledTimes(1);
    expect(await app.get(AiService).current(user.sub, sample.segmentId, recognitionId)).toMatchObject({ status: 'submissionUnknown', errorCode: 'AI_TIMEOUT', text: null });
    expect((await prisma.notePolishJob.findFirstOrThrow({ where: { recognitionId } })).encryptedApiKey).toBeNull();
    // 一次显式 retry 的 HTTP 重放不会重复新增任务或再次识别音频。
    const operationId = randomUUID();
    expect((await request(`/notes/audio/${sample.segmentId}/polish`, 'POST', { operationId, recognitionId })).status).toBe(201);
    expect((await request(`/notes/audio/${sample.segmentId}/polish`, 'POST', { operationId, recognitionId })).status).toBe(201);
    await app.get(AiService).tick();
    expect(polish).toHaveBeenCalledTimes(2); expect(submit).toHaveBeenCalledTimes(1);
    expect(await app.get(AiService).retry(user.sub, sample.segmentId, recognitionId, operationId)).toMatchObject({ id: operationId, status: 'succeeded' });
    // 模拟进程在已提交状态崩溃，恢复只能标记未知，不再调用。
    await prisma.notePolishJob.update({ where: { id: operationId }, data: { status: 'processing', updatedAt: new Date(Date.now() - 180000) } });
    await app.get(AiService).tick();
    expect(polish).toHaveBeenCalledTimes(2);
    expect(await app.get(AiService).current(user.sub, sample.segmentId, recognitionId)).toMatchObject({ status: 'submissionUnknown' });
  });

  it('关闭和撤回识别阻止未提交任务及迟到成功结果重新出现', async () => {
    // 开启并正常取得成功结果。
    const settings = await enableAi();
    // 原文和成功整理持久保存。
    const sample = await seed();
    // 整理成功后的身份仍可由客户端继续轮询。
    const recognitionId = await finishAsr(sample);
    await app.get(AiService).tick();
    expect(await app.get(AiService).current(user.sub, sample.segmentId, recognitionId)).toMatchObject({ status: 'succeeded' });
    await app.get(AiService).updateSettings(user.sub, { revision: settings.revision, activeProfileId: settings.activeProfileId, notePolishEnabled: false });
    expect(await app.get(AiService).current(user.sub, sample.segmentId, recognitionId)).toMatchObject({ status: 'cancelled', text: null });
    // 再开启也不会把以前的成功结果恢复成可自动采用。
    const latest = await app.get(AiService).settings(user.sub);
    await app.get(AiService).updateSettings(user.sub, { revision: latest.revision, activeProfileId: latest.activeProfileId, notePolishEnabled: true });
    expect(await app.get(AiService).current(user.sub, sample.segmentId, recognitionId)).toMatchObject({ status: 'cancelled', text: null });
    // 显式重试创建后撤回识别，即使 ASR 已成功也要取消整理。
    await app.get(AiService).retry(user.sub, sample.segmentId, recognitionId, randomUUID());
    await notes.cancel(user, sample.segmentId); await app.get(AiService).tick();
    expect(polish).toHaveBeenCalledTimes(1);
    expect(await app.get(AiService).current(user.sub, sample.segmentId, recognitionId)).toMatchObject({ status: 'cancelled', text: null });
  });

  it('云端临时链接绑定任务与期限，无JWT可取有效原音，撤回或签名篡改立即失效', async () => {
    // 使用大文件URL路径时不暴露设备Token。
    const sample = await seed(); await upload(sample); app.get(ConfigService).set('NOTE_ASR_PUBLIC_URL', publicAudioUrl);
    // 真实凭证接口返回配置推导的完整同步端点。
    const credentials = await request('/auth/powersync-token', 'POST');
    expect(credentials.status).toBe(200);
    expect(await credentials.json()).toMatchObject({ endpoint: 'https://butler.example.test:8443/omni-butler/powersync/' });
    await notes.recognize(user, sample.segmentId, randomUUID(), true); await notes.tick();
    // 从实际厂商提交参数取得短期链接。
    const url = new URL(submit.mock.calls[0]![0].audioUrl!);
    expect(url.origin).toBe('https://butler.example.test:8443');
    expect(url.pathname).toMatch(/^\/omni-butler\/api\/v1\/notes\/audio\/provider\/[0-9a-f-]+$/);
    expect(url.searchParams.has('expires')).toBe(true);
    expect(url.searchParams.get('signature')).toMatch(/^[0-9a-f]{64}$/);
    // 测试应用没有全局代理前缀，只剥离该前缀后在本机验证原签名。
    const localPath = url.pathname.slice('/omni-butler/api/v1'.length);
    expect((await fetch(`${baseUrl}${localPath}${url.search}`)).status).toBe(200);
    url.searchParams.set('signature', 'a'.repeat(64)); expect((await fetch(`${baseUrl}${localPath}${url.search}`)).status).toBe(403);
    // 取回实际原签名，撤回后任务不能再取音。
    const original = new URL(submit.mock.calls[0]![0].audioUrl!); await notes.cancel(user, sample.segmentId); expect((await fetch(`${baseUrl}${localPath}${original.search}`)).status).toBe(403);
  });
});
