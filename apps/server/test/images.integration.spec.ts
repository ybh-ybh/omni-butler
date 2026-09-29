import {
  BadRequestException,
  ConflictException,
  NotFoundException,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  CreateBucketCommand,
  DeleteObjectCommand,
  GetObjectCommand,
  HeadBucketCommand,
  PutObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';
// eslint-disable-next-line @typescript-eslint/no-require-imports -- 与生产模块一致地读取 Sharp 的 CommonJS 导出。
import sharp = require('sharp');
import type { AuthUser } from '../src/auth/auth.types';
import { ImageObjectStore } from '../src/images/image-object-store';
import { ImagesService, IMAGE_MAX_BYTES } from '../src/images/images.service';
import type { ImageUploadDto } from '../src/images/image.dto';
import { PrismaService } from '../src/prisma/prisma.service';

/// 测试只接受显式独立库和固定 loopback MinIO，不读取正式 .env。
const databaseUrl = process.env.OMNI_IMAGE_TEST_DATABASE_URL;
/// 必须显式打开外部集成，跳过不算验收成功。
const integration =
  process.env.OMNI_IMAGE_TEST === 'true' ? describe : describe.skip;

/// 测试通过真实 MinIO 存取，同时可注入提交窗口的网络延迟及失败。
class TestMinioStore extends ImageObjectStore {
  /// 待上传时执行一次的故障注入回调。
  afterPut: (() => Promise<void>) | undefined;
  /// 回收故障注入开关。
  failDelete = false;
  /// 测试桶在固定测试实例中独立命名。
  readonly bucket = 'omni-images-integration-test';
  /// 所有上传键只属于本次隔离测试。
  readonly keys = new Set<string>();
  /// 记录上传次数以验证幂等重试没有重复流量。
  puts = 0;

  /// 注入只连接测试实例的 S3 客户端。
  constructor(readonly client: S3Client) {
    super();
  }

  /// 真实写入后注入并发事件。
  async put(key: string, bytes: Buffer, mime: string): Promise<void> {
    this.keys.add(key);
    this.puts++;
    await this.client.send(
      new PutObjectCommand({
        Bucket: this.bucket,
        Key: key,
        Body: bytes,
        ContentType: mime,
      }),
    );
    // 每次仅触发一次，避免并发测试递归。
    const callback = this.afterPut;
    this.afterPut = undefined;
    await callback?.();
  }

  /// 从真实存储读取完整字节。
  async get(key: string): Promise<Buffer> {
    // 真实对象读取响应。
    const result = await this.client.send(
      new GetObjectCommand({ Bucket: this.bucket, Key: key }),
    );
    return Buffer.from(await result.Body!.transformToByteArray());
  }

  /// 删除失败用于验证队列延迟重试。
  async delete(key: string): Promise<void> {
    if (this.failDelete) throw new Error('injected storage outage');
    await this.client.send(
      new DeleteObjectCommand({ Bucket: this.bucket, Key: key }),
    );
    this.keys.delete(key);
  }
}

integration('ImagesService 真实 PostgreSQL + MinIO', () => {
  jest.setTimeout(60000);
  // 测试库管理连接。
  let database: Client;
  // 只属于本轮测试的空 schema 标记。
  let ownsSchema = false;
  // 真实 Prisma 数据访问。
  let prisma: PrismaService;
  // 真实对象存储和可控故障注入。
  let store: TestMinioStore;
  // 当前服务实例。
  let service: ImagesService;
  // 当前设备授权主体。
  let user: AuthUser;
  // 当前物品身份。
  let recordId: string;
  // 测试图片内容。
  let bytes: Buffer;

  beforeAll(async () => {
    if (!databaseUrl) throw new Error('需要 OMNI_IMAGE_TEST_DATABASE_URL');
    // 精确确认本机隔离库，不允许任意生产目标。
    const url = new URL(databaseUrl);
    if (
      url.hostname !== '127.0.0.1' ||
      url.port !== '35539' ||
      url.pathname !== '/omni_images_integration'
    )
      throw new Error('测试只允许 127.0.0.1:35539/omni_images_integration');
    database = new Client({ connectionString: databaseUrl });
    await database.connect();
    // 只有空 schema 才允许应用迁移及最终回收。
    const existing = await database.query(
      "SELECT tablename FROM pg_tables WHERE schemaname='public'",
    );
    if (existing.rows.length) throw new Error('图片集成测试要求空数据库');
    ownsSchema = true;
    // 按真实升级顺序应用全部迁移。
    for (const directory of readdirSync(
      join(__dirname, '../prisma/migrations'),
      { withFileTypes: true },
    )
      .filter((item) => item.isDirectory())
      .map((item) => item.name)
      .sort()) {
      await database.query(
        readFileSync(
          join(__dirname, '../prisma/migrations', directory, 'migration.sql'),
          'utf8',
        ),
      );
    }
    prisma = new PrismaService(
      new ConfigService({ DATABASE_URL: databaseUrl }),
    );
    await prisma.onModuleInit();
    // 只读取名称固定的隔离容器，不输出其自动生成的凭证。
    const credentials = JSON.parse(
      execFileSync(
        'docker',
        [
          'exec',
          'omni-image-test-minio-1',
          'cat',
          '/credentials/credentials.json',
        ],
        { encoding: 'utf8' },
      ),
    ) as { accessKeyId: string; secretAccessKey: string };
    store = new TestMinioStore(
      new S3Client({
        endpoint: 'http://127.0.0.1:35590',
        region: 'us-east-1',
        forcePathStyle: true,
        credentials,
      }),
    );
    try {
      await store.client.send(new HeadBucketCommand({ Bucket: store.bucket }));
    } catch {
      await store.client.send(
        new CreateBucketCommand({ Bucket: store.bucket }),
      );
    }
    bytes = await sharp({
      create: { width: 4, height: 4, channels: 3, background: '#aabbcc' },
    })
      .png()
      .toBuffer();
  });

  beforeEach(async () => {
    if (!ownsSchema) throw new Error('未取得隔离 schema');
    await database.query('TRUNCATE sync_owners CASCADE');
    await prisma.imageObjectGarbage.deleteMany();
    // 每个用例独立的所有者与有效会话。
    const owner = await prisma.syncOwner.create({ data: {} });
    // 稳定设备会话。
    const session = await prisma.deviceSession.create({
      data: {
        id: randomUUID(),
        userId: owner.id,
        tokenHash: 'test',
        expiresAt: new Date(Date.now() + 60000),
      },
    });
    user = { sub: owner.id, sid: session.id, typ: 'access' };
    recordId = randomUUID();
    await prisma.inventoryItem.create({
      data: { id: recordId, userId: owner.id, name: 'test image item' },
    });
    store.afterPut = undefined;
    store.failDelete = false;
    store.puts = 0;
    service = new ImagesService(
      prisma,
      new ConfigService({ IMAGE_SYNC_ENABLED: true }),
      store,
    );
  });

  afterAll(async () => {
    if (store) {
      store.failDelete = false;
      // 仅清理当前测试生成的精确对象键，不批量删除桶内历史对象。
      for (const key of [...store.keys]) await store.delete(key);
      store.client.destroy();
    }
    await prisma?.onModuleDestroy();
    if (ownsSchema)
      await database.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public');
    await database?.end();
  });

  /// 每次上传默认产生新的幂等身份。
  function uploadInput(
    overrides: Partial<ImageUploadDto> = {},
  ): ImageUploadDto {
    return {
      operationId: randomUUID(),
      attachmentId: randomUUID(),
      expectedRevision: '',
      onlyIfMissing: 'false',
      sha256: createHash('sha256').update(bytes).digest('hex'),
      ...overrides,
    };
  }

  it('真实图片上传后清单、MIME、摘要和下载字节一致', async () => {
    // 本次新图。
    const result = await service.upload(
      user,
      'inventoryImage',
      recordId,
      uploadInput(),
      bytes,
    );
    expect(result.status).toBe('applied');
    expect(result.image).toMatchObject({
      mimeType: 'image/png',
      sizeBytes: bytes.length,
    });
    expect(await service.list(user)).toEqual({ items: [result.image] });
    expect(
      await service.download(
        user,
        'inventoryImage',
        recordId,
        result.image.revision,
      ),
    ).toEqual({ bytes, mime: 'image/png' });
    expect(await prisma.imageObjectGarbage.count()).toBe(0);
  });

  it('丢失响应后同请求重试不再上传，同 ID 不同内容拒绝', async () => {
    // 可重试操作。
    const input = uploadInput();
    // 已提交但可视为客户端丢失的响应。
    const first = await service.upload(
      user,
      'inventoryImage',
      recordId,
      input,
      bytes,
    );
    expect(
      await service.upload(user, 'inventoryImage', recordId, input, bytes),
    ).toEqual(first);
    expect(store.puts).toBe(1);
    await expect(
      service.upload(
        user,
        'inventoryImage',
        recordId,
        { ...input, attachmentId: randomUUID() },
        bytes,
      ),
    ).rejects.toBeInstanceOf(ConflictException);
  });

  it('旧操作在新图之后重试返回原回执，不覆盖新图', async () => {
    // 原始操作。
    const input = uploadInput();
    // 第一版本。
    const first = await service.upload(
      user,
      'inventoryImage',
      recordId,
      input,
      bytes,
    );
    // 第二版本。
    const second = await service.upload(
      user,
      'inventoryImage',
      recordId,
      uploadInput({ expectedRevision: first.image.revision }),
      bytes,
    );
    expect(
      await service.upload(user, 'inventoryImage', recordId, input, bytes),
    ).toEqual(first);
    expect((await service.list(user)).items).toEqual([second.image]);
    await expect(
      service.download(user, 'inventoryImage', recordId, first.image.revision),
    ).rejects.toBeInstanceOf(NotFoundException);
  });

  it('历史补传尊重服务端图片与显式移除标记', async () => {
    // 服务端已有图片。
    const first = await service.upload(
      user,
      'inventoryImage',
      recordId,
      uploadInput(),
      bytes,
    );
    expect(
      (
        await service.upload(
          user,
          'inventoryImage',
          recordId,
          uploadInput({ onlyIfMissing: 'true' }),
          bytes,
        )
      ).image,
    ).toEqual(first.image);
    // 明确移除仍保留版本，不能被旧图补传复活。
    const removed = await service.remove(user, 'inventoryImage', recordId, {
      operationId: randomUUID(),
      expectedRevision: first.image.revision,
    });
    expect(removed.image.attachmentId).toBeNull();
    expect(
      await service.upload(
        user,
        'inventoryImage',
        recordId,
        uploadInput({ onlyIfMissing: 'true' }),
        bytes,
      ),
    ).toEqual({ status: 'unchanged', image: removed.image });
    expect(store.puts).toBe(1);
  });

  it('从未上传图片也能显式移除，阻止另一旧设备补传', async () => {
    // 无图片时产生明确的删除意图。
    const removed = await service.remove(user, 'inventoryImage', recordId, {
      operationId: randomUUID(),
      expectedRevision: null,
    });
    expect(
      (
        await service.upload(
          user,
          'inventoryImage',
          recordId,
          uploadInput({ onlyIfMissing: 'true' }),
          bytes,
        )
      ).image,
    ).toEqual(removed.image);
    expect(store.puts).toBe(0);
  });

  it('并发同 operationId 只有一次数据库提交，另一个对象成为可回收暂存', async () => {
    // 两个相同并发请求。
    const input = uploadInput();
    // 真实网络并发返回。
    const results = await Promise.all([
      service.upload(user, 'inventoryImage', recordId, input, bytes),
      service.upload(user, 'inventoryImage', recordId, input, bytes),
    ]);
    expect(results[0]).toEqual(results[1]);
    expect(await prisma.businessImage.count()).toBe(1);
    expect(await prisma.imageOperationReceipt.count()).toBe(1);
  });

  it('网络上传期间有新版本时 CAS 拒绝旧请求', async () => {
    store.afterPut = async (): Promise<void> => {
      await service.remove(user, 'inventoryImage', recordId, {
        operationId: randomUUID(),
        expectedRevision: null,
      });
    };
    await expect(
      service.upload(user, 'inventoryImage', recordId, uploadInput(), bytes),
    ).rejects.toBeInstanceOf(ConflictException);
    expect((await service.list(user)).items[0]?.attachmentId).toBeNull();
    expect(await prisma.imageObjectGarbage.count()).toBe(1);
  });

  it('网络上传期间 owner 被替换，晚到请求不得写入', async () => {
    store.afterPut = async (): Promise<void> => {
      await prisma.syncOwner.delete({ where: { id: user.sub } });
      await prisma.syncOwner.create({ data: {} });
    };
    await expect(
      service.upload(user, 'inventoryImage', recordId, uploadInput(), bytes),
    ).rejects.toBeInstanceOf(UnauthorizedException);
    expect(await prisma.businessImage.count()).toBe(0);
    expect(await prisma.imageObjectGarbage.count()).toBe(1);
  });

  it('网络上传期间会话被撤销，晚到请求不得写入', async () => {
    store.afterPut = async (): Promise<void> => {
      await prisma.deviceSession.delete({ where: { id: user.sid } });
    };
    await expect(
      service.upload(user, 'inventoryImage', recordId, uploadInput(), bytes),
    ).rejects.toBeInstanceOf(UnauthorizedException);
    expect(await prisma.businessImage.count()).toBe(0);
  });

  it('业务尚未上传时404，禁止跨类型和跨owner关联', async () => {
    await expect(
      service.upload(
        user,
        'inventoryImage',
        randomUUID(),
        uploadInput(),
        bytes,
      ),
    ).rejects.toBeInstanceOf(NotFoundException);
    await expect(
      service.upload(user, 'membershipImage', recordId, uploadInput(), bytes),
    ).rejects.toBeInstanceOf(NotFoundException);
    await expect(
      service.upload(user, 'banner', recordId, uploadInput(), bytes),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(store.puts).toBe(0);
  });

  it('软删除保留图片，永久删除级联产生独立对象回收任务', async () => {
    await service.upload(
      user,
      'inventoryImage',
      recordId,
      uploadInput(),
      bytes,
    );
    await prisma.inventoryItem.update({
      where: { id: recordId },
      data: { deletedAt: new Date() },
    });
    expect((await service.list(user)).items).toHaveLength(1);
    await prisma.inventoryItem.delete({ where: { id: recordId } });
    expect((await service.list(user)).items).toHaveLength(0);
    expect(await prisma.imageObjectGarbage.count()).toBe(1);
  });

  it('owner级联删除保留GC任务，真实对象删除失败后可重试', async () => {
    await service.upload(
      user,
      'inventoryImage',
      recordId,
      uploadInput(),
      bytes,
    );
    // 保存真实对象键用于检查删除前后状态。
    const image = await prisma.businessImage.findFirstOrThrow();
    await prisma.syncOwner.delete({ where: { id: user.sub } });
    expect(await prisma.imageObjectGarbage.count()).toBe(1);
    await prisma.imageObjectGarbage.updateMany({
      data: { dueAt: new Date(0) },
    });
    store.failDelete = true;
    await service.collectGarbage();
    expect(await prisma.imageObjectGarbage.count()).toBe(1);
    expect(await store.get(image.objectKey!)).toEqual(bytes);
    store.failDelete = false;
    await prisma.imageObjectGarbage.updateMany({
      data: { dueAt: new Date(0) },
    });
    await service.collectGarbage();
    expect(await prisma.imageObjectGarbage.count()).toBe(0);
    await expect(store.get(image.objectKey!)).rejects.toThrow();
  });

  it('意外暂存队列条目仍不得删除已被业务引用的对象', async () => {
    await service.upload(
      user,
      'inventoryImage',
      recordId,
      uploadInput(),
      bytes,
    );
    // 模拟网络提交结果未知时遗留的队列。
    const image = await prisma.businessImage.findFirstOrThrow();
    await prisma.imageObjectGarbage.create({
      data: { objectKey: image.objectKey!, dueAt: new Date(0) },
    });
    await service.collectGarbage();
    expect(await store.get(image.objectKey!)).toEqual(bytes);
    expect(await prisma.imageObjectGarbage.count()).toBe(0);
  });

  it('开关false拒绝图片操作但保留已有数据和对象', async () => {
    // 先保存一个可持久恢复的图片。
    const result = await service.upload(
      user,
      'inventoryImage',
      recordId,
      uploadInput(),
      bytes,
    );
    // 模拟同数据库重新部署为false。
    const disabled = new ImagesService(
      prisma,
      new ConfigService({ IMAGE_SYNC_ENABLED: false }),
      store,
    );
    expect(disabled.capabilities()).toEqual({
      enabled: false,
      maxBytes: IMAGE_MAX_BYTES,
    });
    await expect(disabled.list(user)).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );
    await expect(
      disabled.upload(user, 'inventoryImage', recordId, uploadInput(), bytes),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
    await expect(
      disabled.download(
        user,
        'inventoryImage',
        recordId,
        result.image.revision,
      ),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
    expect((await service.list(user)).items).toEqual([result.image]);
  });

  it('伪装图片、错误摘要和超限内容在对象上传前拒绝', async () => {
    await expect(
      service.upload(
        user,
        'inventoryImage',
        recordId,
        uploadInput({ sha256: '0'.repeat(64) }),
        bytes,
      ),
    ).rejects.toBeInstanceOf(BadRequestException);
    // 有正确摘要但不是图片的恶意文件。
    const fake = Buffer.from('<svg><script>bad</script></svg>');
    await expect(
      service.upload(
        user,
        'inventoryImage',
        recordId,
        uploadInput({
          sha256: createHash('sha256').update(fake).digest('hex'),
        }),
        fake,
      ),
    ).rejects.toBeInstanceOf(BadRequestException);
    await expect(
      service.upload(
        user,
        'inventoryImage',
        recordId,
        uploadInput(),
        Buffer.alloc(IMAGE_MAX_BYTES + 1),
      ),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(store.puts).toBe(0);
  });

  it('会员图片同样可上传与永久回收', async () => {
    // 独立会员业务记录。
    const membership = await prisma.membership.create({
      data: {
        id: randomUUID(),
        userId: user.sub,
        name: 'membership image',
        purchaseDate: new Date(),
      },
    });
    // 会员图片版本。
    const result = await service.upload(
      user,
      'membershipImage',
      membership.id,
      uploadInput(),
      bytes,
    );
    expect(
      (
        await service.download(
          user,
          'membershipImage',
          membership.id,
          result.image.revision,
        )
      ).bytes,
    ).toEqual(bytes);
    await prisma.membership.delete({ where: { id: membership.id } });
    expect(await prisma.businessImage.count()).toBe(0);
    expect(await prisma.imageObjectGarbage.count()).toBe(1);
  });
});
