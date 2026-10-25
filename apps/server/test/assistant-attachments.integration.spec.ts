import { Test, type TestingModule } from '@nestjs/testing';
import { ConfigModule, ConfigService } from '@nestjs/config';
import type { INestApplication } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';
import * as sharp from 'sharp';
import * as ExcelJS from 'exceljs';
import type { AuthUser } from '../src/auth/auth.types';
import { PrismaService } from '../src/prisma/prisma.service';
import { withinBusinessTransaction } from '../src/business/business-access';
import { AssistantAttachmentsModule } from '../src/assistant/attachments/assistant-attachments.module';
import { AssistantAttachmentsService } from '../src/assistant/attachments/assistant-attachments.service';
import {
  AttachmentObjectStore,
  ATTACHMENT_BUCKET,
} from '../src/assistant/attachments/attachment-object-store';
import type { AttachmentMetadata } from '../src/assistant/attachments/attachment.types';
import { attachmentPdf } from './assistant-attachment-fixtures';

/// 仅接受任务显式提供的隔离数据库与私有对象存储。
const databaseUrl =
  process.env.OMNI_ASSISTANT_ATTACHMENTS_TEST_DATABASE_URL ??
  process.env.OMNI_ASSISTANT_TEST_DATABASE_URL;
/// 不回退到真实应用MinIO环境变量。
const endpoint =
  process.env.OMNI_ASSISTANT_TEST_MINIO_ENDPOINT ??
  process.env.OMNI_NOTES_TEST_MINIO_ENDPOINT;
/// 凭据仅从测试文件读取，不写入日志。
const credentialsFile =
  process.env.OMNI_ASSISTANT_TEST_MINIO_CREDENTIALS_FILE ??
  process.env.OMNI_NOTES_TEST_MINIO_CREDENTIALS_FILE;
/// 无隔离资源时明确跳过，不能称为真实存储已验证。
const integration =
  databaseUrl && endpoint && credentialsFile ? describe : describe.skip;

integration('助手附件 / 真实HTTP、PostgreSQL、MinIO与解析子进程', () => {
  jest.setTimeout(60000);
  // 空库确认后才允许本套测试清理schema。
  let ownsSchema = false;
  // 测试专用数据库连接。
  let database: Client;
  // 实际Prisma事务与设备记录。
  let prisma: PrismaService;
  // 独立Nest模块与HTTP监听。
  let module: TestingModule;
  // 应用用于真实JWT与multipart路由。
  let application: INestApplication;
  // 实际附件服务没有存储或解析替身。
  let service: AssistantAttachmentsService;
  // 私有S3客户端仅清理本套生成对象。
  let objects: AttachmentObjectStore;
  // 随机端口上的助手API根地址。
  let baseUrl: string;
  // 同owner设备与其他owner用于隔离验证。
  let actor: AuthUser, second: AuthUser, other: AuthUser;
  // 每例使用新会话以隔离草稿额度。
  let conversationId: string;

  /// 签名使用本套生成的临时RSA密钥。
  async function token(identity = actor): Promise<string> {
    return module
      .get(JwtService)
      .signAsync(identity, { audience: 'omni-butler-api', expiresIn: 3600 });
  }

  /// 调用真实multipart上传路由，客户端身份保持不变。
  async function upload(
    name: string,
    bytes: Buffer,
    id: string = randomUUID(),
  ): Promise<{ response: Response; id: string; metadata: AttachmentMetadata }> {
    // 表单只含文件一项。
    const form = new FormData();
    form.append('file', new Blob([Uint8Array.from(bytes)]), name);
    // 请求有界且始终通过JWT守卫。
    const response = await fetch(
      `${baseUrl}/conversations/${conversationId}/attachments/${id}`,
      {
        method: 'PUT',
        headers: { Authorization: `Bearer ${await token()}` },
        body: form,
        signal: AbortSignal.timeout(15000),
      },
    );
    return {
      response,
      id,
      metadata: (await response.json()) as AttachmentMetadata,
    };
  }

  /// 真实消息绑定和附件约束处于同一owner事务。
  async function bind(ids: string[]): Promise<string> {
    return withinBusinessTransaction(prisma, actor, async (transaction) => {
      // 本测试不运行模型，只建立真实用户消息。
      const id = randomUUID();
      await transaction.assistantMessage.create({
        data: {
          id,
          userId: actor.sub,
          conversationId,
          taskId: randomUUID(),
          role: 'user',
          content: '读取附件',
          cards: [],
        },
      });
      await service.bindMessage(transaction, actor, conversationId, id, ids);
      return id;
    });
  }

  beforeAll(async () => {
    // 三重边界避免误用已有或公网实例。
    const url = new URL(databaseUrl!);
    if (
      url.hostname !== '127.0.0.1' ||
      !/^\/[a-zA-Z0-9_]+_test$/.test(url.pathname) ||
      new URL(endpoint!).hostname !== '127.0.0.1' ||
      new URL(endpoint!).protocol !== 'http:'
    )
      throw new Error('附件集成只允许明确的本机_test空库和隔离MinIO');
    database = new Client({ connectionString: databaseUrl });
    await database.connect();
    if (
      (
        await database.query(
          "SELECT 1 FROM pg_tables WHERE schemaname IN ('public','assistant_graph')",
        )
      ).rows.length
    )
      throw new Error('附件集成要求空schema');
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
    // JWT密钥只存在测试进程内。
    const keys = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    });
    // 不读取本地.env或正式密钥。
    const config = {
      DATABASE_URL: databaseUrl,
      SYNC_SECRET: 'isolated-attachments-test',
      JWT_PRIVATE_KEY_BASE64: Buffer.from(keys.privateKey).toString('base64'),
      JWT_PUBLIC_KEY_BASE64: Buffer.from(keys.publicKey).toString('base64'),
      JWT_KEY_ID: 'attachment-test',
      JWT_ISSUER: 'omni-butler',
      JWT_AUDIENCE: 'omni-butler-api',
      REFRESH_TOKEN_TTL_SECONDS: 86400,
      ASSISTANT_ATTACHMENTS_ENABLED: true,
      MINIO_ENDPOINT: endpoint,
      MINIO_CREDENTIALS_FILE: credentialsFile,
    };
    prisma = new PrismaService(new ConfigService(config));
    await prisma.$connect();
    module = await Test.createTestingModule({
      imports: [
        ConfigModule.forRoot({
          isGlobal: true,
          ignoreEnvFile: true,
          load: [(): typeof config => config],
        }),
        AssistantAttachmentsModule,
      ],
    })
      .overrideProvider(PrismaService)
      .useValue(prisma)
      .compile();
    service = module.get(AssistantAttachmentsService);
    objects = module.get(AttachmentObjectStore);
    // 手动tick消除测试驱动和后台扫描的竞争，解析器与存储保持真实。
    jest.spyOn(service, 'onModuleInit').mockImplementation(() => undefined);
    application = module.createNestApplication();
    application.setGlobalPrefix('omni-butler/api/v1');
    await application.listen(0, '127.0.0.1');
    baseUrl = `${await application.getUrl()}/omni-butler/api/v1/assistant`;
    // 设备身份依赖真实数据库行，不伪造授权方法。
    const owner = await prisma.syncOwner.create({ data: { id: randomUUID() } });
    // 新建真实设备会话。
    const makeActor = async (userId: string): Promise<AuthUser> => {
      // 会话有固定短期测试有效期。
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
  });

  beforeEach(async () => {
    conversationId = (
      await prisma.assistantConversation.create({
        data: { id: randomUUID(), userId: actor.sub, title: '隔离附件会话' },
      })
    ).id;
  });

  afterAll(async () => {
    if (prisma && objects) {
      // 先固定本套所有产物与尚未清理对象，再逐键删除；不清桶。
      const rows = await prisma.assistantAttachment.findMany();
      // GC队列包含失败解析和已删除会话留下的对象。
      const jobs = await prisma.assistantAttachmentGc.findMany();
      // 只清理本套空库中记录的精确对象键。
      const keys = new Set([
        ...rows.flatMap((row) => [
          row.objectKey,
          ...(row.manifestKey ? [row.manifestKey] : []),
          ...((row.imageKeys ?? []) as unknown as { key: string }[]).map(
            (image) => image.key,
          ),
        ]),
        ...jobs.flatMap((job) => job.keys as unknown as string[]),
      ]);
      for (const key of keys) await objects.delete(key);
    }
    if (application) await application.close();
    else await module?.close();
    await prisma?.$disconnect();
    if (ownsSchema)
      await database.query(
        'DROP SCHEMA public CASCADE; DROP SCHEMA IF EXISTS assistant_graph CASCADE; CREATE SCHEMA public;',
      );
    await database?.end();
  });

  it('上传身份重放、真实私有存储、解析和消息绑定贯通', async () => {
    // 中文文本经过HTTP上传和子进程提取。
    const bytes = Buffer.from('第一段\n\n第二段');
    // 首次PUT保存原件并进入持久解析队列。
    const first = await upload('notes.txt', bytes);
    expect(first.response.status).toBe(200);
    expect(first.metadata).toMatchObject({
      id: first.id,
      status: 'processing',
    });
    expect((await upload('notes.txt', bytes, first.id)).metadata.id).toBe(
      first.id,
    );
    expect(
      (await upload('notes.txt', Buffer.from('修改内容'), first.id)).response
        .status,
    ).toBe(409);
    await expect(bind([first.id])).rejects.toThrow('尚未就绪');
    await service.tick();
    expect(await service.metadata(actor, first.id)).toMatchObject({
      status: 'ready',
      requiresVision: false,
    });
    // 实际S3桶拒绝匿名读取。
    const row = await prisma.assistantAttachment.findUniqueOrThrow({
      where: { id: first.id },
    });
    expect(
      (await fetch(`${endpoint}/${ATTACHMENT_BUCKET}/${row.objectKey}`)).status,
    ).toBe(403);
    expect(await objects.get(row.objectKey)).toEqual(bytes);
    await bind([first.id]);
    expect(await service.contextManifest(actor, conversationId)).toEqual([
      expect.objectContaining({ id: first.id, chunkCount: 2 }),
    ]);
    expect(await service.read(actor, conversationId, first.id)).toMatchObject({
      chunks: [
        { text: '第一段', paragraph: 1 },
        { text: '第二段', paragraph: 2 },
      ],
    });
    expect(
      await service.search(actor, conversationId, first.id, '第二'),
    ).toMatchObject({ matches: [{ index: 2, paragraph: 2 }] });
    await expect(service.remove(actor, first.id)).rejects.toThrow('已发送');
    // 另一有效设备可访问同owner文件，其他owner与匿名请求失败。
    expect(
      (
        await fetch(`${baseUrl}/attachments/${first.id}`, {
          headers: { Authorization: `Bearer ${await token(second)}` },
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await fetch(`${baseUrl}/attachments/${first.id}`, {
          headers: { Authorization: `Bearer ${await token(other)}` },
        })
      ).status,
    ).toBe(404);
    expect(
      (await fetch(`${baseUrl}/attachments/${first.id}/file`)).status,
    ).toBe(401);
    // 原件下载不产生公开链接。
    const downloaded = await fetch(`${baseUrl}/attachments/${first.id}/file`, {
      headers: { Authorization: `Bearer ${await token()}` },
    });
    expect(downloaded.headers.get('content-disposition')).toContain(
      'attachment;',
    );
    expect(Buffer.from(await downloaded.arrayBuffer())).toEqual(bytes);
  });

  it('原件上传失败后的retry保留重传原因，同UUID重PUT可恢复真实存储与解析', async () => {
    // 仅注入首次外部写入失败，恢复阶段使用真实MinIO。
    const failure = jest
      .spyOn(objects, 'put')
      .mockRejectedValueOnce(new Error('isolated upload interruption'));
    // 固定身份与字节覆盖客户端断线恢复语义。
    const id = randomUUID();
    // 重放的字节保持完全相同。
    const bytes = Buffer.from('recover original bytes');
    try {
      expect(
        (await upload('retry-original.txt', bytes, id)).response.status,
      ).toBe(503);
      expect(await service.metadata(actor, id)).toMatchObject({
        status: 'failed',
        errorCode: 'ATTACHMENT_STORAGE_UNAVAILABLE',
      });
      expect(await service.retry(actor, id)).toMatchObject({
        status: 'failed',
        errorCode: 'ATTACHMENT_STORAGE_UNAVAILABLE',
      });
    } finally {
      failure.mockRestore();
    }
    expect(
      (await upload('retry-original.txt', bytes, id)).metadata,
    ).toMatchObject({ id, status: 'processing' });
    await service.tick();
    expect(await service.metadata(actor, id)).toMatchObject({
      status: 'ready',
    });
    // 实际原件可从私有桶完整读回，不能仅验证状态字段。
    const row = await prisma.assistantAttachment.findUniqueOrThrow({
      where: { id },
    });
    expect(await objects.get(row.objectKey)).toEqual(bytes);
  });

  it('图片与扫描PDF生成私有派生图，只在出站读取时转成品牌图片part', async () => {
    // PNG输入与空白扫描页都由真实解析器处理。
    const picture = await upload(
      'picture.png',
      await sharp({
        create: { width: 20, height: 10, channels: 3, background: 'blue' },
      })
        .png()
        .toBuffer(),
    );
    // 真PDF文件经过独立子进程与原生画布。
    const scan = await upload('scan.pdf', attachmentPdf());
    await service.tick();
    await service.tick();
    expect(await service.metadata(actor, scan.id)).toMatchObject({
      status: 'ready',
      requiresVision: true,
    });
    await bind([picture.id, scan.id]);
    expect(
      await service.read(actor, conversationId, scan.id, { page: 1 }),
    ).toMatchObject({
      chunks: [],
      images: [{ attachmentId: scan.id, page: 1 }],
    });
    // 品牌part短暂持有base64，数据库只含对象键。
    const parts = await service.hydrateImages(actor, conversationId, [
      { attachmentId: picture.id },
      { attachmentId: scan.id, page: 1 },
    ]);
    expect(parts).toHaveLength(2);
    expect(parts[0]).toMatchObject({ type: 'input_image' });
    expect(
      JSON.stringify(
        await prisma.assistantAttachment.findMany({
          where: { conversationId },
        }),
      ),
    ).not.toContain('base64');
    await expect(
      service.read(actor, conversationId, scan.id, { page: 2 }),
    ).rejects.toThrow('没有该读取范围');
  });

  it('解析失败可重试，草稿额度受服务器限制，删除与24小时GC持久回收', async () => {
    // 损坏PDF能保存原件但解析失败，不会误发到模型。
    const bad = await upload('bad.pdf', Buffer.from('broken-pdf'));
    await service.tick();
    expect(await service.metadata(actor, bad.id)).toMatchObject({
      status: 'failed',
      errorCode: 'ATTACHMENT_INVALID_PDF',
    });
    expect(await service.retry(actor, bad.id)).toMatchObject({
      status: 'processing',
    });
    await service.tick();
    expect(await service.metadata(actor, bad.id)).toMatchObject({
      status: 'failed',
    });
    for (let index = 0; index < 4; index++)
      expect(
        (await upload(`draft${index}.txt`, Buffer.from('draft'))).response
          .status,
      ).toBe(200);
    expect(
      (await upload('sixth.txt', Buffer.from('too many'))).response.status,
    ).toBe(400);
    // 删除只登记GC，等待有界在途写入结束后再清理。
    const original = await prisma.assistantAttachment.findUniqueOrThrow({
      where: { id: bad.id },
    });
    await service.remove(actor, bad.id);
    await service.remove(actor, bad.id);
    await prisma.assistantAttachmentGc.updateMany({
      where: { attachmentId: bad.id },
      data: { availableAt: new Date(0) },
    });
    await service.collect();
    await expect(objects.get(original.objectKey)).rejects.toBeDefined();
    // 只推进本例草稿时间，验证24小时未绑定回收。
    await prisma.assistantAttachment.updateMany({
      where: { conversationId, status: { not: 'deleted' } },
      data: { createdAt: new Date(Date.now() - 25 * 3600000) },
    });
    await service.collect();
    expect(
      await prisma.assistantAttachment.count({
        where: { conversationId, status: { not: 'deleted' } },
      }),
    ).toBe(0);
  });

  it('后续工作表定位准确，长中文按16KiB完整JSON预算逐页读完', async () => {
    // 第一工作表超过十块，第二表位于更后的全局编号。
    const workbook = new ExcelJS.Workbook();
    // 每个非空行会生成一个有引用位置的块。
    const first = workbook.addWorksheet('前表');
    for (let row = 1; row <= 12; row++) first.addRow([`前表${row}`]);
    workbook.addWorksheet('后表').addRow(['后表目标']);
    // 真实上传、ZIP预检和Excel解析共同产生全局块身份。
    const uploaded = await upload(
      'locations.xlsx',
      Buffer.from(await workbook.xlsx.writeBuffer()),
    );
    await service.tick();
    await bind([uploaded.id]);
    expect(
      await service.read(actor, conversationId, uploaded.id, { sheet: '后表' }),
    ).toMatchObject({
      start: 13,
      chunks: [{ index: 13, sheet: '后表', text: 'A1: 后表目标' }],
    });
    await expect(
      service.read(actor, conversationId, uploaded.id, { start: 99 }),
    ).rejects.toThrow('没有该读取范围');
    // 真实上传长中文与emoji，验证字节限制并非仅单元测试中的字符串拼装。
    const source = `${'中文🙂'.repeat(7000)}最后一字`;
    // 原件、解析产物与分页读取都使用真实持久服务。
    const document = await upload('large-utf8.txt', Buffer.from(source));
    await service.tick();
    await bind([document.id]);
    // 累计全文只使用实际返回块，不能从原件替代验证。
    let received = '';
    // 后端提供的全局块游标。
    let nextStart = 1;
    // 有界翻页，异常游标不能无限读取。
    let pages = 0;
    while (pages++ < 100) {
      // 返回对象本身连同分页包装必须落在16KiB以内。
      const result = await service.read(actor, conversationId, document.id, {
        start: nextStart,
      });
      expect(
        Buffer.byteLength(JSON.stringify(result), 'utf8'),
      ).toBeLessThanOrEqual(16 * 1024);
      // 每个块独立保留有效Unicode字符。
      const chunks = result.chunks as { index: number; text: string }[];
      expect(chunks.length).toBeGreaterThan(0);
      expect(result.end).toBe(chunks.at(-1)!.index);
      received += chunks.map((chunk) => chunk.text).join('');
      if (!result.truncated) break;
      expect(result.nextStart).toBeGreaterThan(nextStart);
      nextStart = result.nextStart as number;
    }
    expect(pages).toBeGreaterThan(1);
    expect(pages).toBeLessThan(100);
    expect(received).toBe(source);
  });

  it('删除快照持有owner锁时解析发布必须等待，迟到产物仍进入持久GC', async () => {
    // 原件已保存，派生物尚不存在。
    const uploaded = await upload(
      'publication-race.txt',
      Buffer.from('pending artifact'),
    );
    // 删除事务在记录旧快照后暂停，精确制造发布竞争窗口。
    let snapshotReady!: () => void;
    // 测试等待删除已拿到owner锁。
    const snapshot = new Promise<void>((resolve) => {
      snapshotReady = resolve;
    });
    // 仅测试控制事务继续删除，所有数据库操作仍为真实操作。
    let allowDeletion!: () => void;
    // 暂停点保持同一事务和同一owner锁。
    const release = new Promise<void>((resolve) => {
      allowDeletion = resolve;
    });
    // 删除先固定processing状态时的对象清单。
    const deleting = withinBusinessTransaction(
      prisma,
      actor,
      async (transaction) => {
        await service.queueConversationDeletion(
          transaction,
          actor,
          conversationId,
        );
        snapshotReady();
        await release;
        await transaction.assistantConversation.delete({
          where: { id: conversationId },
        });
      },
    );
    await snapshot;
    // 解析运行到发布阶段会与删除的owner锁竞争。
    const parsing = service.tick();
    // 直接从真实MinIO观察生成清单；不替换存储返回或解析结果。
    let manifestKey = '';
    try {
      // 有界轮询只读取本例随机附件的确定代次对象。
      const deadline = Date.now() + 10000;
      while (Date.now() < deadline) {
        // 租约代次固定本次生成键。
        const row = await prisma.assistantAttachment.findUniqueOrThrow({
          where: { id: uploaded.id },
        });
        if (row.leaseToken) {
          // 该键只能属于本例解析，不枚举对象桶。
          const key = `${actor.sub}/${uploaded.id}/${row.leaseToken}/manifest.json`;
          try {
            await objects.get(key);
            manifestKey = key;
            break;
          } catch {
            /* 尚未写入时继续等待有限解析。 */
          }
        }
        await new Promise<void>((resolve) => setTimeout(resolve, 20));
      }
      expect(manifestKey).not.toBe('');
      expect(
        await prisma.assistantAttachment.findUnique({
          where: { id: uploaded.id },
        }),
      ).toMatchObject({ status: 'processing', manifestKey: null });
    } finally {
      allowDeletion();
      await Promise.all([deleting, parsing]);
    }
    expect(
      await prisma.assistantAttachment.count({ where: { id: uploaded.id } }),
    ).toBe(0);
    // 发布失败必须保留记录派生物的兜底任务。
    expect(
      JSON.stringify(
        await prisma.assistantAttachmentGc.findMany({
          where: { attachmentId: uploaded.id },
        }),
      ),
    ).toContain(manifestKey);
    await prisma.assistantAttachmentGc.updateMany({
      where: { attachmentId: uploaded.id },
      data: { availableAt: new Date(0) },
    });
    await service.collect();
    await expect(objects.get(manifestKey)).rejects.toBeDefined();
  });

  it('会话删除先登记持久GC，数据库级联后仍能删除所有原件和派生物', async () => {
    // 就绪附件拥有原件与清单两个真实对象。
    const uploaded = await upload('delete.txt', Buffer.from('remove me'));
    await service.tick();
    await bind([uploaded.id]);
    // 删除前固定对象身份用于实际存储验证。
    const row = await prisma.assistantAttachment.findUniqueOrThrow({
      where: { id: uploaded.id },
    });
    await withinBusinessTransaction(prisma, actor, async (transaction) => {
      await service.queueConversationDeletion(
        transaction,
        actor,
        conversationId,
      );
      await transaction.assistantConversation.delete({
        where: { id: conversationId },
      });
    });
    expect(
      await prisma.assistantAttachment.count({ where: { id: uploaded.id } }),
    ).toBe(0);
    expect(
      await prisma.assistantAttachmentGc.count({
        where: { attachmentId: uploaded.id },
      }),
    ).toBeGreaterThan(0);
    await prisma.assistantAttachmentGc.updateMany({
      where: { attachmentId: uploaded.id },
      data: { availableAt: new Date(0) },
    });
    await service.collect();
    await expect(objects.get(row.objectKey)).rejects.toBeDefined();
    await expect(objects.get(row.manifestKey!)).rejects.toBeDefined();
  });
});
