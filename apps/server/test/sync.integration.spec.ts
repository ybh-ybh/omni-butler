import { BadRequestException, ConflictException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';
import { PrismaService } from '../src/prisma/prisma.service';
import type { SyncBatchDto } from '../src/sync/dto/sync-batch.dto';
import type { SyncOperationDto } from '../src/sync/dto/sync-operation.dto';
import { SyncService } from '../src/sync/sync.service';
import type { AuthService } from '../src/auth/auth.service';
import { SyncMigrationService } from '../src/sync/sync-migration.service';
import type { SyncMigrationDto } from '../src/sync/dto/sync-migration.dto';
import type {
  DeviceSession,
  Prisma,
  Quote,
  SyncMigrationReceipt,
  SyncOwner,
  SyncReceipt,
} from '../src/generated/prisma/client';

/// 仅显式配置隔离测试库时运行，不读取应用 DATABASE_URL 或 .env。
const databaseUrl = process.env.OMNI_TEST_DATABASE_URL;
/// 默认单元测试跳过数据库集成测试。
const integration = databaseUrl ? describe : describe.skip;
/// 固定的客户端业务时间。
const timestamp = '2026-09-25T08:00:00.000Z';
/// 含 updated_at 非空列的业务表。
const updatedTables = new Set([
  'todo_items',
  'todo_progress_steps',
  'quotes',
  'daily_quote_selections',
  'taxonomy_entries',
  'events',
  'inventory_items',
  'time_entries',
  'memberships',
]);

/// 构造包含必要时间字段的完整行上传。
function put(
  table: string,
  data: Record<string, unknown>,
  id: string = randomUUID(),
): SyncOperationDto {
  return {
    op: 'PUT',
    table,
    id,
    data: {
      created_at: timestamp,
      ...(updatedTables.has(table) ? { updated_at: timestamp } : {}),
      ...data,
    },
  };
}

/// 构造客户端事务，默认每次调用具有独立安装身份和事务号。
function batch(
  operations: SyncOperationDto[],
  clientId: string = randomUUID(),
  transactionId: string = randomUUID(),
): SyncBatchDto {
  return { clientId, transactionId, operations };
}

/// 按客户端 UUIDv5 URL 业务命名规则生成自动任务身份。
function businessId(kind: string, parts: string[]): string {
  // URL 命名空间与规范化业务名称。
  const namespace = Buffer.from('6ba7b8119dad11d180b400c04fd430c8', 'hex');
  // 待散列的业务名称。
  const name = `https://omni-butler.local/${kind}/${parts.map(encodeURIComponent).join('/')}`;
  // UUIDv5 的二进制内容。
  const bytes = createHash('sha1')
    .update(namespace)
    .update(name)
    .digest()
    .subarray(0, 16);
  bytes[6] = (bytes[6]! & 15) | 80;
  bytes[8] = (bytes[8]! & 63) | 128;
  // 可用于 PostgreSQL UUID 列的标准文本。
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/// 对真实迁移和 PostgreSQL 约束执行多设备同步回归。
integration('SyncService PostgreSQL 集成', () => {
  jest.setTimeout(60000);
  // 只连接显式隔离库的管理连接。
  let database: Client | undefined;
  // 实际应用数据访问服务。
  let prisma: PrismaService | undefined;
  // 实际同步服务。
  let service: SyncService;
  // 当前真实快照替换服务，仅密钥验证使用独立替身。
  let migrations: SyncMigrationService;
  // 当前用例独立所有者。
  let ownerId: string;
  // 只有确认空 schema 后才允许清理由此测试创建的对象。
  let ownsSchema = false;
  // 第四份迁移是否原样保留前三份迁移已存入的旧随机日签。
  let preservedLegacySelection = false;
  // 进度任务增量迁移是否原样保留普通任务和子任务。
  let preservedLegacyTodos = false;

  beforeAll(async () => {
    // 解析显式提供的测试连接字符串。
    const url = new URL(databaseUrl!);
    // 数据库名称必须明确声明其测试用途。
    const databaseName = decodeURIComponent(url.pathname.slice(1));
    if (!/^[A-Za-z0-9_]+_(?:test|integration)$/.test(databaseName)) {
      throw new Error(
        'OMNI_TEST_DATABASE_URL 库名必须以 _test 或 _integration 结尾',
      );
    }
    database = new Client({ connectionString: databaseUrl });
    await database.connect();
    // 再次通过数据库确认连接目标，避免代理/连接参数改写目标。
    const actual = await database.query<{ name: string }>(
      'SELECT current_database() AS name',
    );
    if (actual.rows[0]?.name !== databaseName)
      throw new Error('实际数据库与测试目标不一致');
    // 不清理已有数据库；测试只接受空的 public schema。
    const existing = await database.query<{ name: string }>(
      "SELECT tablename AS name FROM pg_tables WHERE schemaname = 'public'",
    );
    if (existing.rows.length > 0)
      throw new Error('集成测试要求空数据库，拒绝清理已有 public 表');
    ownsSchema = true;
    // 按生产发布顺序应用真实迁移。
    for (const migration of readdirSync(
      join(__dirname, '../prisma/migrations'),
      { withFileTypes: true },
    )
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort()) {
      // 模拟已经部署前三份迁移且存有旧随机身份的真实升级。
      const upgradingAliases =
        migration === '20260925000300_daily_quote_selection_aliases';
      // 升级前的完整业务行，用于逐字段验证迁移没有改写数据。
      let legacySelection: Record<string, unknown> | undefined;
      // 新类型上线前的完整普通任务快照。
      let legacyTodos: Record<string, unknown>[] | undefined;
      if (upgradingAliases) {
        // 此数据仅属于当前显式空测试库，首个用例前会正常清理。
        const seeded = await database.query<{ row: Record<string, unknown> }>(
          `WITH owner AS (
             INSERT INTO sync_owners (id) VALUES ($1) RETURNING id
           ), quote AS (
             INSERT INTO quotes (id, user_id, content, updated_at)
             SELECT $2, id, 'legacy deployed quote', $4 FROM owner RETURNING id, user_id
           ), selection AS (
             INSERT INTO daily_quote_selections (id, user_id, day_key, quote_id, updated_at)
             SELECT $3, user_id, '2026-09-23', id, $4 FROM quote RETURNING *
           ) SELECT to_jsonb(selection) AS row FROM selection`,
          [randomUUID(), randomUUID(), randomUUID(), timestamp],
        );
        legacySelection = seeded.rows[0]!.row;
      }
      if (migration === '20261007000000_todo_progress') {
        // 在新增列前创建已完成父任务和子任务，验证真实增量升级。
        const seeded = await database.query<{ row: Record<string, unknown> }>(
          `WITH owner AS (
             INSERT INTO sync_owners (id) VALUES ($1) RETURNING id
           ), parent AS (
             INSERT INTO todo_items (id, user_id, title, scheduled_date, is_completed, completed_at, updated_at)
             SELECT $2, id, 'legacy root', '2026-09-25', true, $4, $4 FROM owner RETURNING *
           ), child AS (
             INSERT INTO todo_items (id, user_id, parent_id, title, scheduled_date, is_completed, completed_at, updated_at)
             SELECT $3, user_id, id, 'legacy child', '2026-09-25', true, $4, $4 FROM parent RETURNING *
           ) SELECT to_jsonb(parent) AS row FROM parent
             UNION ALL SELECT to_jsonb(child) AS row FROM child`,
          [randomUUID(), randomUUID(), randomUUID(), timestamp],
        );
        legacyTodos = seeded.rows.map((row) => row.row);
      }
      await database.query(
        readFileSync(
          join(__dirname, '../prisma/migrations', migration, 'migration.sql'),
          'utf8',
        ),
      );
      if (legacySelection) {
        // 新映射表只能增量创建，旧记录的 ID、归属、文案和时间均保持原样。
        const after = await database.query<{ row: Record<string, unknown> }>(
          'SELECT to_jsonb(selection) AS row FROM daily_quote_selections selection WHERE id = $1',
          [legacySelection.id],
        );
        expect(after.rows[0]?.row).toEqual(legacySelection);
        preservedLegacySelection = true;
      }
      if (legacyTodos) {
        // 每条旧记录只增加默认类型和空单位，其余业务字段保持不变。
        for (const legacyTodo of legacyTodos) {
          // 迁移后的真实数据库行。
          const after = await database.query<{ row: Record<string, unknown> }>(
            'SELECT to_jsonb(todo) AS row FROM todo_items todo WHERE id = $1',
            [legacyTodo.id],
          );
          expect(after.rows[0]?.row).toEqual({
            ...legacyTodo,
            task_type: 'normal',
            progress_unit: null,
          });
        }
        preservedLegacyTodos = true;
      }
    }
    prisma = new PrismaService(
      new ConfigService({ DATABASE_URL: databaseUrl }),
    );
    await prisma.onModuleInit();
    service = new SyncService(prisma);
    migrations = new SyncMigrationService(prisma, {
      verifySyncKey: jest.fn(),
    } as unknown as AuthService);
  });

  it('第四份迁移原样保留已部署版本的旧随机日签记录', () => {
    expect(preservedLegacySelection).toBe(true);
  });

  it('进度任务增量迁移原样保留旧任务完成状态及父子关系', () => {
    expect(preservedLegacyTodos).toBe(true);
  });

  beforeEach(async () => {
    if (!ownsSchema) throw new Error('数据库初始化未完成，禁止修改数据');
    await database!.query('TRUNCATE sync_owners CASCADE');
    await database!.query('TRUNCATE sync_migration_receipts');
    // 每条测试的内部身份均独立随机生成。
    const owner = await prisma!.syncOwner.create({ data: {} });
    ownerId = owner.id;
  });

  /// 创建包含 nullable 列的严格完整名言快照。
  function snapshotQuote(
    content = '迁移名言',
    id: string = randomUUID(),
  ): SyncOperationDto {
    return put(
      'quotes',
      { content, source: null, is_enabled: true, deleted_at: null },
      id,
    );
  }

  /// 使用当前预检 owner 构造持久迁移请求。
  function migration(operations: SyncOperationDto[]): SyncMigrationDto {
    return {
      syncKey: 'migration-test-key',
      migrationId: randomUUID(),
      expectedOwnerId: ownerId,
      snapshotVersion: 2,
      operations,
    };
  }

  /// 保存替换前可观察状态，失败后逐字段核对归属、业务与会话回执。
  async function migrationState(): Promise<{
    owners: SyncOwner[];
    quotes: Quote[];
    sessions: DeviceSession[];
    receipts: SyncReceipt[];
    migrations: SyncMigrationReceipt[];
  }> {
    return {
      owners: await prisma!.syncOwner.findMany(),
      quotes: await prisma!.quote.findMany(),
      sessions: await prisma!.deviceSession.findMany(),
      receipts: await prisma!.syncReceipt.findMany(),
      migrations: await prisma!.syncMigrationReceipt.findMany(),
    };
  }

  it('100001 条快照及超过 32 MB 的完整请求均拒绝，旧 owner、业务和回执不变', async () => {
    await service.applyBatch(ownerId, batch([snapshotQuote('原数据必须保留')]));
    await prisma!.deviceSession.create({
      data: {
        id: randomUUID(),
        userId: ownerId,
        tokenHash: 'c'.repeat(64),
        expiresAt: new Date(Date.now() + 60000),
      },
    });
    await prisma!.syncMigrationReceipt.create({
      data: {
        migrationId: randomUUID(),
        expectedOwnerId: randomUUID(),
        ownerId,
        payloadHash: 'd'.repeat(64),
      },
    });
    // 包括已有回执，避免测试仅验证空表仍为空。
    const before = await migrationState();
    // 完整合法记录保持独立 ID，请求字节数仍未超过上限，单独验证行数限制。
    const tooMany = migration(
      Array.from({ length: 100001 }, () => snapshotQuote('x')),
    );
    expect(
      Buffer.byteLength(JSON.stringify(tooMany), 'utf8'),
    ).toBeLessThanOrEqual(32 * 1024 * 1024);
    await expect(migrations.replace(tooMany)).rejects.toMatchObject({
      response: { code: 'SNAPSHOT_LIMIT_EXCEEDED' },
    });
    expect(await migrationState()).toEqual(before);
    expect(await migrations.status(tooMany)).toEqual({
      status: 'notFound',
      migrationId: tooMany.migrationId,
    });
    // 一条记录足以验证完整 JSON 请求上限，正文自身恰为 32 MB，编码封装使其超限。
    const tooLarge = migration([snapshotQuote('x'.repeat(32 * 1024 * 1024))]);
    expect(tooLarge.operations).toHaveLength(1);
    expect(Buffer.byteLength(JSON.stringify(tooLarge), 'utf8')).toBeGreaterThan(
      32 * 1024 * 1024,
    );
    await expect(migrations.replace(tooLarge)).rejects.toMatchObject({
      response: { code: 'SNAPSHOT_LIMIT_EXCEEDED' },
    });
    expect(await migrationState()).toEqual(before);
    expect(await migrations.status(tooLarge)).toEqual({
      status: 'notFound',
      migrationId: tooLarge.migrationId,
    });
  });

  it('真实 PostgreSQL 插入阻塞触发事务超时，owner、旧会话和业务全部回滚且不产生迁移回执', async () => {
    await service.applyBatch(ownerId, batch([snapshotQuote('超时前原业务')]));
    await prisma!.deviceSession.create({
      data: {
        id: randomUUID(),
        userId: ownerId,
        tokenHash: 'e'.repeat(64),
        expiresAt: new Date(Date.now() + 60000),
      },
    });
    // 序列递增不会随事务回滚，用于证明真实数据库触发器已执行到睡眠语句。
    await database!.query(`
      CREATE SEQUENCE migration_timeout_probe;
      CREATE FUNCTION migration_timeout_sleep() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.content = 'timeout-probe' THEN
          PERFORM nextval('migration_timeout_probe');
          PERFORM pg_sleep(0.6);
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER migration_timeout_sleep BEFORE INSERT ON quotes
      FOR EACH ROW EXECUTE FUNCTION migration_timeout_sleep();
    `);
    try {
      // 仅缩短测试事务的等待时间，其余服务逻辑、Prisma 和 PostgreSQL 均使用真实实现。
      const timeoutPrisma = {
        $transaction<T>(
          action: (transaction: Prisma.TransactionClient) => Promise<T>,
          options: { maxWait: number; timeout: number },
        ): Promise<T> {
          expect(options.timeout).toBe(60000);
          return prisma!.$transaction(action, { ...options, timeout: 200 });
        },
      } as unknown as PrismaService;
      // 和生产完全相同的替换服务，只注入事务超时边界。
      const timedMigrations = new SyncMigrationService(timeoutPrisma, {
        verifySyncKey: jest.fn(),
      } as unknown as AuthService);
      // 首条插入已完成后，第二条才在 PostgreSQL 触发器里超时。
      const input = migration([
        snapshotQuote('部分新数据必须回滚'),
        snapshotQuote('timeout-probe'),
      ]);
      // 保存真实旧会话和增量回执，覆盖 owner 级联删除后的恢复。
      const before = await migrationState();
      await expect(timedMigrations.replace(input)).rejects.toMatchObject({
        code: 'P2028',
      });
      // 已进入数据库执行的证明，不依赖 JavaScript 主动抛错模拟。
      const probe = await database!.query<{ is_called: boolean }>(
        'SELECT is_called FROM migration_timeout_probe',
      );
      expect(probe.rows[0]?.is_called).toBe(true);
      expect(await migrationState()).toEqual(before);
      expect(await migrations.status(input)).toEqual({
        status: 'notFound',
        migrationId: input.migrationId,
      });
    } finally {
      await database!.query(`
        DROP TRIGGER IF EXISTS migration_timeout_sleep ON quotes;
        DROP FUNCTION IF EXISTS migration_timeout_sleep();
        DROP SEQUENCE IF EXISTS migration_timeout_probe;
      `);
    }
  });

  it('快照替换清理旧会话、回执、墓碑与同身份旧记录，丢响应重试不再覆盖', async () => {
    // 同一业务身份的旧值与目标值。
    const record = snapshotQuote('旧值');
    await service.applyBatch(ownerId, batch([record]));
    await prisma!.deviceSession.create({
      data: {
        id: randomUUID(),
        userId: ownerId,
        tokenHash: 'a'.repeat(64),
        expiresAt: new Date(Date.now() + 60000),
      },
    });
    await service.applyBatch(
      ownerId,
      batch([{ op: 'DELETE', table: 'quotes', id: record.id }]),
    );
    // 目标快照可以恢复旧 B 墓碑下的相同 ID。
    const input = migration([snapshotQuote('快照值', record.id)]);
    // 首次持久提交结果。
    const result = await migrations.replace(input);
    expect(result.status).toBe('committed');
    expect(result.ownerId).not.toBe(ownerId);
    expect(await prisma!.deviceSession.count()).toBe(0);
    expect(await prisma!.syncReceipt.count()).toBe(0);
    expect(await prisma!.syncTombstone.count()).toBe(0);
    await service.applyBatch(
      result.ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'quotes',
          id: record.id,
          data: { content: '提交后的编辑' },
        },
      ]),
    );
    expect(await migrations.replace(input)).toEqual(result);
    expect(
      (await prisma!.quote.findUnique({ where: { id: record.id } }))!.content,
    ).toBe('提交后的编辑');
    expect(await migrations.status(input)).toEqual(result);
    await expect(
      service.applyBatch(ownerId, batch([snapshotQuote()])),
    ).rejects.toBeInstanceOf(ConflictException);
  });

  it('并发同身份迁移共用回执；身份复用不同内容和旧目标覆盖均拒绝', async () => {
    // 两个并发网络请求持有同一持久迁移身份。
    const input = migration([snapshotQuote()]);
    // 加锁前同时到达的重复请求。
    const results = await Promise.all([
      migrations.replace(input),
      migrations.replace(input),
    ]);
    expect(results[0]).toEqual(results[1]);
    expect(await prisma!.syncMigrationReceipt.count()).toBe(1);
    await expect(
      migrations.replace({ ...input, operations: [] }),
    ).rejects.toBeInstanceOf(ConflictException);
    await expect(migrations.replace(migration([]))).rejects.toBeInstanceOf(
      ConflictException,
    );
  });

  it('后续空快照替换使旧回执 superseded，旧请求不能再次清库', async () => {
    // 首次快照及回执。
    const input = migration([snapshotQuote()]);
    const first = await migrations.replace(input);
    // 第二次明确以空本机库替换。
    const second = await migrations.replace({
      ...migration([]),
      expectedOwnerId: first.ownerId,
    });
    expect(second.status).toBe('committed');
    expect(await prisma!.quote.count()).toBe(0);
    expect((await migrations.replace(input)).status).toBe('superseded');
    expect((await migrations.status(input)).status).toBe('superseded');
    expect((await prisma!.syncOwner.findFirst())!.id).toBe(second.ownerId);
  });

  it('迁移与旧会话普通上传并发时，旧数据不能进入新 owner', async () => {
    // 两种请求都必须等待同一个旧 owner 行锁。
    await database!.query('BEGIN');
    await database!.query(
      'SELECT id FROM sync_owners WHERE id = $1::uuid FOR UPDATE',
      [ownerId],
    );
    // 目标完整快照与迟到的普通上传使用不同记录身份。
    const target = snapshotQuote('迁移后的唯一记录');
    const late = snapshotQuote('旧设备迟到上传');
    // 两个已经发起但被行锁阻挡的请求。
    const replacing = migrations.replace(migration([target]));
    const uploading = service.applyBatch(ownerId, batch([late]));
    await database!.query('COMMIT');
    // 不强制调度顺序；上传可以在替换之前成功，也可以在替换之后被拒绝。
    const results = await Promise.allSettled([replacing, uploading]);
    expect(results[0].status).toBe('fulfilled');
    expect((await prisma!.quote.findMany()).map((row) => row.id)).toEqual([
      target.id,
    ]);
    if (results[1].status === 'rejected')
      expect(results[1].reason).toBeInstanceOf(ConflictException);
  });

  it('快照数据库校验失败回滚 owner、会话及业务，不产生完成回执', async () => {
    await service.applyBatch(ownerId, batch([snapshotQuote('原服务器数据')]));
    // 失败回滚必须同时保留原有设备授权。
    const sessionId = randomUUID();
    await prisma!.deviceSession.create({
      data: {
        id: sessionId,
        userId: ownerId,
        tokenHash: 'a'.repeat(64),
        expiresAt: new Date(Date.now() + 60000),
      },
    });
    // 完整列存在但 NOT NULL 事实值非法，只能由真实数据库最终验证。
    const invalid = snapshotQuote();
    invalid.data!.content = null;
    // 错误出现在成功插入第一行之后，覆盖整个事务回滚。
    const input = migration([snapshotQuote(), invalid]);
    await expect(migrations.replace(input)).rejects.toThrow();
    expect((await prisma!.syncOwner.findFirst())!.id).toBe(ownerId);
    expect((await prisma!.quote.findMany()).map((row) => row.content)).toEqual([
      '原服务器数据',
    ]);
    expect(await migrations.status(input)).toEqual({
      status: 'notFound',
      migrationId: input.migrationId,
    });
    expect(
      await prisma!.deviceSession.findUnique({ where: { id: sessionId } }),
    ).not.toBeNull();
    // 布尔值和日期值交由 PostgreSQL 的实际列类型校验，失败仍整体回滚。
    for (const data of [
      { is_enabled: 'not-a-boolean' },
      { created_at: 'not-a-date' },
    ]) {
      // 每个请求使用独立身份，不能误命中旧回执。
      const invalidType = snapshotQuote();
      invalidType.data = { ...invalidType.data, ...data };
      await expect(
        migrations.replace(migration([invalidType])),
      ).rejects.toThrow();
      expect((await prisma!.syncOwner.findFirst())!.id).toBe(ownerId);
    }
  });

  it('快照预检拒绝遗漏列、未知列、重复身份、非PUT和悬空引用', async () => {
    // 快照完整行基线。
    const row = snapshotQuote();
    // 缺少 nullable 列也不是完整快照。
    const missing = snapshotQuote();
    delete missing.data!.source;
    // 完整日签引用快照之外的名言。
    const dangling = put('daily_quote_selections', {
      day_key: '2026-09-27',
      quote_id: randomUUID(),
    });
    // 多态引用不受 PostgreSQL 外键保护，服务必须主动验证。
    const taxonomy = put('taxonomy_entries', {
      module: 'inventory',
      kind: 'tag',
      name: '迁移标签',
      color_value: null,
      sort_order: 0,
      is_enabled: true,
      deleted_at: null,
    });
    const orphanLink = put('record_taxonomy_links', {
      module: 'inventory',
      record_id: randomUUID(),
      taxonomy_id: taxonomy.id,
      deleted_at: null,
    });
    // 各失败输入均不能清除 owner 或创建回执。
    const invalidSnapshots = [
      [missing],
      [{ ...row, data: { ...row.data, user_id: ownerId } }],
      [row, row],
      [{ ...row, op: 'PATCH' as const }],
      [dangling],
      [taxonomy, orphanLink],
    ];
    for (const operations of invalidSnapshots)
      await expect(
        migrations.replace(migration(operations)),
      ).rejects.toBeInstanceOf(BadRequestException);
    expect((await prisma!.syncOwner.findFirst())!.id).toBe(ownerId);
    expect(await prisma!.syncMigrationReceipt.count()).toBe(0);
  });

  it('连接预检返回所有表数量并包含回收站记录', async () => {
    await service.applyBatch(
      ownerId,
      batch([
        snapshotQuote(),
        {
          ...snapshotQuote(),
          data: { ...snapshotQuote().data, deleted_at: timestamp },
        },
      ]),
    );
    // 目标归属与业务数量使用同一加锁视图。
    const preview = await migrations.preview('migration-test-key');
    expect(preview).toMatchObject({
      ownerId,
      protocolVersion: 1,
      snapshotVersion: 2,
      deletedCount: 1,
      counts: { quotes: 2 },
      limits: { maxOperations: 100000, maxBytes: 33554432 },
    });
    expect(Object.keys(preview.counts)).toHaveLength(12);
  });

  afterAll(async () => {
    if (prisma) await prisma.onModuleDestroy();
    try {
      if (database && ownsSchema) {
        await database.query(
          'DROP PUBLICATION IF EXISTS powersync; DROP SCHEMA public CASCADE; CREATE SCHEMA public',
        );
      }
    } finally {
      if (database) await database.end();
    }
  });

  it('复制发布只包含业务表，不发布凭证、回执或墓碑', async () => {
    // 真实迁移创建的发布成员。
    const publication = await database!.query<{ tablename: string }>(
      "SELECT tablename FROM pg_publication_tables WHERE pubname = 'powersync' ORDER BY tablename",
    );
    expect(publication.rows.map((row) => row.tablename)).toEqual([
      'daily_quote_selections',
      'event_completions',
      'events',
      'inventory_items',
      'membership_payments',
      'memberships',
      'quotes',
      'record_taxonomy_links',
      'taxonomy_entries',
      'time_entries',
      'todo_items',
      'todo_progress_steps',
    ]);
  });

  it('ARGB 大整数可保存，同名分类不会被旧唯一约束堵塞', async () => {
    // 两台设备分别创建的同名分类。
    const first = put('taxonomy_entries', {
      module: 'todo',
      kind: 'tag',
      name: '重要',
      color_value: 4294967295,
    });
    // 同名但不同身份的另一分类。
    const second = put('taxonomy_entries', {
      module: 'todo',
      kind: 'tag',
      name: '重要',
      color_value: 4280391411,
    });
    await service.applyBatch(ownerId, batch([first]));
    await service.applyBatch(ownerId, batch([second]));
    expect(await prisma!.taxonomyEntry.count()).toBe(2);
    expect(
      (
        await prisma!.taxonomyEntry.findUniqueOrThrow({
          where: { id: first.id },
        })
      ).colorValue,
    ).toBe(4294967295n);
  });

  it('同日稳定身份只保留首次创建，第二设备批次继续提交', async () => {
    // 两端离线选择的不同文案。
    const quoteA = put('quotes', { content: '第一端' });
    // 第二端候选文案。
    const quoteB = put('quotes', { content: '第二端' });
    await service.applyBatch(ownerId, batch([quoteA, quoteB]));
    // 同一自然日的稳定实体标识。
    const dailyId = businessId('daily-quote', ['2026-09-25']);
    await service.applyBatch(
      ownerId,
      batch([
        put(
          'daily_quote_selections',
          { day_key: '2026-09-25', quote_id: quoteA.id },
          dailyId,
        ),
      ]),
    );
    // 重复实体后仍需成功保存的普通记录。
    const tail = put('quotes', { content: '不能被重复日签阻塞' });
    // 第二端上传处理结果。
    const result = await service.applyBatch(
      ownerId,
      batch([
        put(
          'daily_quote_selections',
          { day_key: '2026-09-25', quote_id: quoteB.id },
          dailyId,
        ),
        tail,
      ]),
    );
    expect(result).toMatchObject({ applied: 1, ignored: 1 });
    expect(
      (
        await prisma!.dailyQuoteSelection.findUniqueOrThrow({
          where: { id: dailyId },
        })
      ).quoteId,
    ).toBe(quoteA.id);
    expect(
      await prisma!.quote.findUnique({ where: { id: tail.id } }),
    ).not.toBeNull();
  });

  it('同日旧随机身份持久合并，同事务和后续事务 PATCH 均命中现有槽位', async () => {
    // 已部署桌面端最先选择的文案。
    const firstQuote = put('quotes', { content: 'desktop' });
    // 安卓端随后手动选择的文案。
    const secondQuote = put('quotes', { content: 'android' });
    // 桌面端已有的随机日签身份。
    const canonical = put('daily_quote_selections', {
      day_key: '2026-09-23',
      quote_id: firstQuote.id,
    });
    await service.applyBatch(
      ownerId,
      batch([firstQuote, secondQuote, canonical]),
    );
    // 安卓端相同日期使用不同随机身份的初始导入。
    const legacy = put('daily_quote_selections', {
      day_key: '2026-09-23',
      quote_id: secondQuote.id,
    });
    // 冲突记录后的普通业务操作不能再被唯一约束堵塞。
    const tail = put('quotes', { content: 'must upload' });
    expect(
      await service.applyBatch(ownerId, batch([legacy, tail])),
    ).toMatchObject({ applied: 1, ignored: 1 });
    expect(
      (
        await prisma!.dailyQuoteSelection.findUniqueOrThrow({
          where: { id: canonical.id },
        })
      ).quoteId,
    ).toBe(firstQuote.id);
    expect(await prisma!.dailyQuoteSelection.count()).toBe(1);
    expect(
      await prisma!.dailyQuoteSelectionAlias.findUniqueOrThrow({
        where: { userId_recordId: { userId: ownerId, recordId: legacy.id } },
      }),
    ).toMatchObject({ selectionId: canonical.id });
    // 服务重新实例化后仍需解析跨事务的原始身份。
    const restartedService = new SyncService(prisma!);
    await restartedService.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: legacy.table,
          id: legacy.id,
          data: { quote_id: secondQuote.id },
        },
      ]),
    );
    expect(
      (
        await prisma!.dailyQuoteSelection.findUniqueOrThrow({
          where: { id: canonical.id },
        })
      ).quoteId,
    ).toBe(secondQuote.id);
    // 第三台旧设备在同一个事务中先 PUT 再 PATCH。
    const third = put('daily_quote_selections', {
      day_key: '2026-09-23',
      quote_id: secondQuote.id,
    });
    // 模拟第一次响应丢失，需要原样重试的事务。
    const pending = batch([
      third,
      {
        op: 'PATCH',
        table: third.table,
        id: third.id,
        data: { quote_id: firstQuote.id },
      },
    ]);
    expect(await restartedService.applyBatch(ownerId, pending)).toMatchObject({
      applied: 1,
      ignored: 1,
    });
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: canonical.table,
          id: canonical.id,
          data: { quote_id: secondQuote.id },
        },
      ]),
    );
    expect((await restartedService.applyBatch(ownerId, pending)).replayed).toBe(
      true,
    );
    expect(
      (
        await prisma!.dailyQuoteSelection.findUniqueOrThrow({
          where: { id: canonical.id },
        })
      ).quoteId,
    ).toBe(secondQuote.id);
    expect(await prisma!.dailyQuoteSelectionAlias.count()).toBe(2);
    await expect(
      service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: legacy.table,
            id: legacy.id,
            data: { day_key: '2026-09-24' },
          },
        ]),
      ),
    ).rejects.toBeInstanceOf(ConflictException);
  });

  it('旧日签 DELETE 只取消选择，原始身份和合并身份都可再次选择', async () => {
    // 取消后仍然可选的文案。
    const quote = put('quotes', { content: 'select again' });
    // 已有日期槽位。
    const canonical = put('daily_quote_selections', {
      day_key: '2026-09-24',
      quote_id: quote.id,
    });
    // 已合并的离线设备身份。
    const legacy = put('daily_quote_selections', {
      day_key: '2026-09-24',
      quote_id: quote.id,
    });
    await service.applyBatch(ownerId, batch([quote, canonical, legacy]));
    // 两种身份的删除都必须保留日期槽位及映射。
    for (const selection of [legacy, canonical]) {
      await service.applyBatch(
        ownerId,
        batch([{ op: 'DELETE', table: selection.table, id: selection.id }]),
      );
      expect(
        (
          await prisma!.dailyQuoteSelection.findUniqueOrThrow({
            where: { id: canonical.id },
          })
        ).quoteId,
      ).toBeNull();
      expect(await prisma!.syncTombstone.count()).toBe(0);
      expect(await prisma!.dailyQuoteSelectionAlias.count()).toBe(1);
      await service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: legacy.table,
            id: legacy.id,
            data: { quote_id: quote.id },
          },
        ]),
      );
      expect(
        (
          await prisma!.dailyQuoteSelection.findUniqueOrThrow({
            where: { id: canonical.id },
          })
        ).quoteId,
      ).toBe(quote.id);
    }
    // 尚未上传就删除的身份不产生无法解除的日签墓碑。
    const missing = put('daily_quote_selections', {
      day_key: '2026-09-25',
      quote_id: quote.id,
    });
    expect(
      (
        await service.applyBatch(
          ownerId,
          batch([{ op: 'DELETE', table: missing.table, id: missing.id }]),
        )
      ).ignored,
    ).toBe(1);
    await service.applyBatch(ownerId, batch([missing]));
    expect(await prisma!.dailyQuoteSelection.count()).toBe(2);
  });

  it('日签别名按所有者隔离，失败事务中的别名和业务写入一起回滚', async () => {
    // 第二个独立数据归属。
    const otherOwner = await prisma!.syncOwner.create({ data: {} });
    // 两个归属各自的合法文案。
    const firstQuote = put('quotes', { content: 'owner one' });
    // 第二个归属的文案不能被第一个归属改写。
    const secondQuote = put('quotes', { content: 'owner two' });
    // 两边的规范日签身份独立。
    const first = put('daily_quote_selections', {
      day_key: '2026-09-23',
      quote_id: firstQuote.id,
    });
    // 第二个归属相同自然日的槽位。
    const second = put('daily_quote_selections', {
      day_key: '2026-09-23',
      quote_id: secondQuote.id,
    });
    await service.applyBatch(ownerId, batch([firstQuote, first]));
    await service.applyBatch(otherOwner.id, batch([secondQuote, second]));
    // 相同原始别名可在两个归属内分别解析，不泄漏或覆盖另一边。
    const sharedId = randomUUID();
    await service.applyBatch(
      ownerId,
      batch([put(first.table, first.data!, sharedId)]),
    );
    await service.applyBatch(
      otherOwner.id,
      batch([put(second.table, second.data!, sharedId)]),
    );
    await service.applyBatch(
      ownerId,
      batch([{ op: 'DELETE', table: first.table, id: sharedId }]),
    );
    expect(
      (
        await prisma!.dailyQuoteSelection.findUniqueOrThrow({
          where: { id: second.id },
        })
      ).quoteId,
    ).toBe(secondQuote.id);
    await expect(
      service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: second.table,
            id: second.id,
            data: { quote_id: null },
          },
        ]),
      ),
    ).rejects.toMatchObject({ response: { code: 'SYNC_RECORD_MISSING' } });
    await expect(
      prisma!.dailyQuoteSelectionAlias.create({
        data: {
          userId: ownerId,
          recordId: randomUUID(),
          selectionId: second.id,
        },
      }),
    ).rejects.toThrow();
    // 后续非法写入必须回滚本次刚创建的身份映射。
    const failedAliasId = randomUUID();
    await expect(
      service.applyBatch(
        ownerId,
        batch([
          put(first.table, first.data!, failedAliasId),
          put('quotes', { content: null }),
        ]),
      ),
    ).rejects.toThrow();
    expect(
      await prisma!.dailyQuoteSelectionAlias.findUnique({
        where: {
          userId_recordId: { userId: ownerId, recordId: failedAliasId },
        },
      }),
    ).toBeNull();
  });

  it('回执重放不覆盖另一端的新修改，复用事务号改变内容返回 409', async () => {
    // 已同步的普通记录。
    const quote = put('quotes', { content: 'initial' });
    await service.applyBatch(ownerId, batch([quote]));
    // 第一端修改事务，第一次响应视为丢失。
    const first = batch([
      {
        op: 'PATCH',
        table: 'quotes',
        id: quote.id,
        data: { content: 'device A' },
      },
    ]);
    await service.applyBatch(ownerId, first);
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'quotes',
          id: quote.id,
          data: { content: 'device B' },
        },
      ]),
    );
    expect((await service.applyBatch(ownerId, first)).replayed).toBe(true);
    expect(
      (await prisma!.quote.findUniqueOrThrow({ where: { id: quote.id } }))
        .content,
    ).toBe('device B');
    await expect(
      service.applyBatch(ownerId, {
        ...first,
        operations: [
          { ...first.operations[0]!, data: { content: 'changed payload' } },
        ],
      }),
    ).rejects.toBeInstanceOf(ConflictException);
  });

  it('不存在 PATCH 返回 409 且不提交回执，修复后相同事务可以重试', async () => {
    // 尚未到达服务端的记录。
    const missingId = randomUUID();
    // 客户端必须保留以供重试的事务。
    const pending = batch([
      {
        op: 'PATCH',
        table: 'quotes',
        id: missingId,
        data: { content: 'later edit' },
      },
    ]);
    await expect(service.applyBatch(ownerId, pending)).rejects.toMatchObject({
      response: { code: 'SYNC_RECORD_MISSING' },
    });
    expect(await prisma!.syncReceipt.count()).toBe(0);
    await service.applyBatch(
      ownerId,
      batch([put('quotes', { content: 'restored full record' }, missingId)]),
    );
    expect((await service.applyBatch(ownerId, pending)).applied).toBe(1);
  });

  it('201 个操作完整原子提交，中间 SQL 失败全部回滚且不保存回执', async () => {
    // 原先超过分页边界的完整客户端事务。
    const operations = Array.from({ length: 201 }, (_, index) =>
      put('quotes', { content: `record-${index}` }),
    );
    expect((await service.applyBatch(ownerId, batch(operations))).applied).toBe(
      201,
    );
    expect(await prisma!.quote.count()).toBe(201);
    // 故意在中间触发真实 NOT NULL 约束错误。
    const invalidOperations = Array.from({ length: 201 }, (_, index) =>
      put('quotes', { content: index === 100 ? null : `rollback-${index}` }),
    );
    // 应当整个保留在客户端的失败事务身份。
    const failed = batch(invalidOperations);
    await expect(service.applyBatch(ownerId, failed)).rejects.toThrow();
    expect(await prisma!.quote.count()).toBe(201);
    expect(
      await prisma!.syncReceipt.findUnique({
        where: {
          userId_clientId_transactionId: {
            userId: ownerId,
            clientId: failed.clientId,
            transactionId: failed.transactionId,
          },
        },
      }),
    ).toBeNull();
  });

  it('子行先于父行上传，由事务末尾的延迟外键保证一致性', async () => {
    // 稍后才写入的父文案。
    const parent = put('quotes', { content: 'late parent' });
    // 先上传的日签子行。
    const child = put('daily_quote_selections', {
      day_key: '2026-09-25',
      quote_id: parent.id,
    });
    expect(
      (await service.applyBatch(ownerId, batch([child, parent]))).applied,
    ).toBe(2);
    expect(await prisma!.dailyQuoteSelection.count()).toBe(1);
  });

  it('重试 DELETE 及旧 PUT 不会复活记录，级联子记录同样留下墓碑', async () => {
    // 会触发跨表级联删除的父记录。
    const parent = put('events', { name: 'parent' });
    // 被级联删除的子记录。
    const child = put('event_completions', {
      event_id: parent.id,
      completed_at: timestamp,
    });
    await service.applyBatch(ownerId, batch([parent, child]));
    // 可重复提交的删除事务。
    const deletion = batch([{ op: 'DELETE', table: 'events', id: parent.id }]);
    await service.applyBatch(ownerId, deletion);
    expect((await service.applyBatch(ownerId, deletion)).replayed).toBe(true);
    expect(await prisma!.eventCompletion.count()).toBe(0);
    expect(await prisma!.syncTombstone.count()).toBe(2);
    expect(
      (await service.applyBatch(ownerId, batch([parent, child]))).ignored,
    ).toBe(2);
    expect(await prisma!.event.count()).toBe(0);
  });

  it('现有任务改绑到已永久删除的父任务时，删除本行及级联孩子', async () => {
    // 已被另一端删除且从未上传的父身份。
    const deletedParentId = randomUUID();
    // 当前仍可见的主任务。
    const parent = put('todo_items', {
      title: 'existing root',
      scheduled_date: '2026-09-25',
    });
    // 必须随主任务一起删除且留下墓碑的孩子。
    const child = put('todo_items', {
      title: 'existing child',
      scheduled_date: '2026-09-25',
      parent_id: parent.id,
    });
    await service.applyBatch(ownerId, batch([parent, child]));
    await service.applyBatch(
      ownerId,
      batch([{ op: 'DELETE', table: 'todo_items', id: deletedParentId }]),
    );
    expect(
      await service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: 'todo_items',
            id: parent.id,
            data: { parent_id: deletedParentId },
          },
        ]),
      ),
    ).toMatchObject({ applied: 0, ignored: 1 });
    expect(await prisma!.todoItem.count()).toBe(0);
    expect(await prisma!.syncTombstone.count()).toBe(3);
    expect(
      (await service.applyBatch(ownerId, batch([parent, child]))).ignored,
    ).toBe(2);
    expect(await prisma!.todoItem.count()).toBe(0);
  });

  it('完成历史改绑到已删除事件时，删除历史并重算原事件汇总', async () => {
    // 仍存在且需要重新计算汇总的原事件。
    const event = put('events', { name: 'existing event' });
    // 显式重新绑定的已删除目标。
    const deletedEventId = randomUUID();
    // 保留下来的较早完成历史。
    const older = put('event_completions', {
      event_id: event.id,
      completed_at: '2026-09-20T08:00:00.000Z',
    });
    // 因目标事件已删除而需要删除的当前历史。
    const newest = put('event_completions', {
      event_id: event.id,
      completed_at: timestamp,
    });
    await service.applyBatch(ownerId, batch([event, older, newest]));
    await service.applyBatch(
      ownerId,
      batch([{ op: 'DELETE', table: 'events', id: deletedEventId }]),
    );
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'event_completions',
          id: newest.id,
          data: { event_id: deletedEventId },
        },
      ]),
    );
    expect(
      await prisma!.eventCompletion.findUnique({ where: { id: newest.id } }),
    ).toBeNull();
    expect(await prisma!.syncTombstone.count()).toBe(2);
    expect(
      (
        await prisma!.event.findUniqueOrThrow({ where: { id: event.id } })
      ).lastCompletedAt?.toISOString(),
    ).toBe('2026-09-20T08:00:00.000Z');
  });

  it('永久删除文案保留日签槽位，迟到旧关联不会阻止后续重新选择', async () => {
    // 最初选中且随后被永久删除的文案。
    const deletedQuote = put('quotes', { content: 'deleted quote' });
    // 后续重新选择的有效文案。
    const availableQuote = put('quotes', { content: 'available quote' });
    // 已经上传的稳定日签槽位。
    const daily = put(
      'daily_quote_selections',
      { day_key: '2026-09-25', quote_id: deletedQuote.id },
      businessId('daily-quote', ['2026-09-25']),
    );
    await service.applyBatch(
      ownerId,
      batch([deletedQuote, availableQuote, daily]),
    );
    await service.applyBatch(
      ownerId,
      batch([{ op: 'DELETE', table: 'quotes', id: deletedQuote.id }]),
    );
    expect(
      await prisma!.dailyQuoteSelection.findUniqueOrThrow({
        where: { id: daily.id },
      }),
    ).toMatchObject({ userId: ownerId, quoteId: null });
    expect(await prisma!.syncTombstone.count()).toBe(1);
    // 另一端首次上传的未来日签仍引用被删除文案。
    const lateDaily = put(
      'daily_quote_selections',
      { day_key: '2026-09-26', quote_id: deletedQuote.id },
      businessId('daily-quote', ['2026-09-26']),
    );
    expect(
      (await service.applyBatch(ownerId, batch([daily, lateDaily]))).applied,
    ).toBe(1);
    // 两个槽位均可显式重新选择，同一身份不会被永久墓碑封锁。
    for (const selection of [daily, lateDaily]) {
      await service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: selection.table,
            id: selection.id,
            data: { quote_id: availableQuote.id },
          },
        ]),
      );
      // 迟到的旧 PUT 不能覆盖已经有效的选择。
      await service.applyBatch(ownerId, batch([selection]));
      expect(
        (
          await prisma!.dailyQuoteSelection.findUniqueOrThrow({
            where: { id: selection.id },
          })
        ).quoteId,
      ).toBe(availableQuote.id);
      // 迟到的显式旧关联 PATCH 只清空引用，仍允许再次选择。
      await service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: selection.table,
            id: selection.id,
            data: { quote_id: deletedQuote.id },
          },
        ]),
      );
      expect(
        (
          await prisma!.dailyQuoteSelection.findUniqueOrThrow({
            where: { id: selection.id },
          })
        ).quoteId,
      ).toBeNull();
      await service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: selection.table,
            id: selection.id,
            data: { quote_id: availableQuote.id },
          },
        ]),
      );
      expect(
        (
          await prisma!.dailyQuoteSelection.findUniqueOrThrow({
            where: { id: selection.id },
          })
        ).quoteId,
      ).toBe(availableQuote.id);
    }
    expect(await prisma!.syncTombstone.count()).toBe(1);
  });

  it('永久删除不存在的父行后，迟到父子上传都不能创建', async () => {
    // 尚未上传就已永久删除的父事件。
    const parent = put('events', { name: 'late event' });
    await service.applyBatch(
      ownerId,
      batch([{ op: 'DELETE', table: 'events', id: parent.id }]),
    );
    // 离线设备迟到的历史记录。
    const history = put('event_completions', {
      event_id: parent.id,
      completed_at: timestamp,
    });
    expect(
      (await service.applyBatch(ownerId, batch([history, parent]))).ignored,
    ).toBe(2);
    expect(await prisma!.eventCompletion.count()).toBe(0);
  });

  it('较旧完成记录和旧汇总 PATCH 不能回退事件，撤销后重算最新有效时间', async () => {
    // 需要派生汇总的事件。
    const event = put('events', { name: 'event' });
    await service.applyBatch(ownerId, batch([event]));
    // 较晚到来的真实完成时间。
    const newest = put('event_completions', {
      event_id: event.id,
      completed_at: '2026-09-25T08:00:00.000Z',
    });
    await service.applyBatch(ownerId, batch([newest]));
    // 另一端迟到的旧完成记录。
    const older = put('event_completions', {
      event_id: event.id,
      completed_at: '2026-09-20T08:00:00.000Z',
    });
    await service.applyBatch(
      ownerId,
      batch([
        older,
        {
          op: 'PATCH',
          table: 'events',
          id: event.id,
          data: { last_completed_at: '2026-09-20T08:00:00.000Z' },
        },
      ]),
    );
    expect(
      (
        await prisma!.event.findUniqueOrThrow({ where: { id: event.id } })
      ).lastCompletedAt?.toISOString(),
    ).toBe('2026-09-25T08:00:00.000Z');
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'event_completions',
          id: newest.id,
          data: { is_revoked: true },
        },
      ]),
    );
    expect(
      (
        await prisma!.event.findUniqueOrThrow({ where: { id: event.id } })
      ).lastCompletedAt?.toISOString(),
    ).toBe('2026-09-20T08:00:00.000Z');
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'event_completions',
          id: older.id,
          data: { is_revoked: true },
        },
      ]),
    );
    expect(
      (await prisma!.event.findUniqueOrThrow({ where: { id: event.id } }))
        .lastCompletedAt,
    ).toBeNull();
  });

  it('初始事件完成时间转成稳定历史且重复初始上传不产生重复记录', async () => {
    // 初始本地导入仅包含汇总时间的事件。
    const event = put('events', {
      name: 'imported',
      last_completed_at: timestamp,
    });
    await service.applyBatch(ownerId, batch([event]));
    expect(await prisma!.eventCompletion.count()).toBe(1);
    expect((await prisma!.eventCompletion.findFirstOrThrow()).id).toBe(
      businessId('event-initial', [event.id]),
    );
    await service.applyBatch(ownerId, batch([event]));
    expect(await prisma!.eventCompletion.count()).toBe(1);
    expect(
      (
        await prisma!.event.findUniqueOrThrow({ where: { id: event.id } })
      ).lastCompletedAt?.toISOString(),
    ).toBe(timestamp);
  });

  it('跨端完成全部子任务后等待手动完成父任务，重开子任务仍撤销父完成', async () => {
    // 主任务。
    const parent = put('todo_items', {
      title: 'root',
      scheduled_date: '2026-09-25',
    });
    // 第一端操作的子任务。
    const first = put('todo_items', {
      title: 'first',
      scheduled_date: '2026-09-25',
      parent_id: parent.id,
    });
    // 第二端操作的子任务。
    const second = put('todo_items', {
      title: 'second',
      scheduled_date: '2026-09-25',
      parent_id: parent.id,
    });
    await service.applyBatch(ownerId, batch([first, second, parent]));
    await Promise.all(
      [first, second].map((child) =>
        service.applyBatch(
          ownerId,
          batch([
            {
              op: 'PATCH',
              table: 'todo_items',
              id: child.id,
              data: { is_completed: true, completed_at: timestamp },
            },
          ]),
        ),
      ),
    );
    // 子任务全部完成不能改变父任务的手动状态。
    const pendingParent = await prisma!.todoItem.findUniqueOrThrow({
      where: { id: parent.id },
    });
    expect(pendingParent.isCompleted).toBe(false);
    expect(pendingParent.completedAt).toBeNull();
    // 父任务手动确认的时间应独立于子任务完成时间。
    const confirmedAt = '2026-09-25T09:00:00.000Z';
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'todo_items',
          id: parent.id,
          data: { is_completed: true, completed_at: confirmedAt },
        },
      ]),
    );
    // 再次同步子任务也不能重写父任务确认时间。
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'todo_items',
          id: second.id,
          data: { title: 'second updated' },
        },
      ]),
    );
    // 同步后的父任务保留用户手动完成状态。
    const confirmedParent = await prisma!.todoItem.findUniqueOrThrow({
      where: { id: parent.id },
    });
    expect(confirmedParent.isCompleted).toBe(true);
    expect(confirmedParent.completedAt?.toISOString()).toBe(confirmedAt);

    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'todo_items',
          id: first.id,
          data: { is_completed: false, completed_at: null },
        },
      ]),
    );
    expect(
      (
        await prisma!.todoItem.findUniqueOrThrow({
          where: { id: parent.id },
        })
      ).isCompleted,
    ).toBe(false);
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'todo_items',
          id: first.id,
          data: { is_completed: true, completed_at: timestamp },
        },
      ]),
    );
    expect(
      (
        await prisma!.todoItem.findUniqueOrThrow({
          where: { id: parent.id },
        })
      ).isCompleted,
    ).toBe(false);
  });

  it('软删除父任务后新增孩子继承软删除，两者显式恢复后正常显示', async () => {
    // 已被设备 A 软删除的主任务。
    const parent = put('todo_items', {
      title: 'deleted root',
      scheduled_date: '2026-09-25',
      deleted_at: timestamp,
    });
    await service.applyBatch(ownerId, batch([parent]));
    // 设备 B 离线时新增的子任务。
    const child = put('todo_items', {
      title: 'late child',
      scheduled_date: '2026-09-25',
      parent_id: parent.id,
    });
    await service.applyBatch(ownerId, batch([child]));
    expect(
      (
        await prisma!.todoItem.findUniqueOrThrow({ where: { id: child.id } })
      ).deletedAt?.toISOString(),
    ).toBe(timestamp);
    expect(await prisma!.syncTombstone.count()).toBe(0);
    await service.applyBatch(
      ownerId,
      batch(
        [parent, child].map((row) => ({
          op: 'PATCH',
          table: 'todo_items',
          id: row.id,
          data: { deleted_at: null },
        })),
      ),
    );
    expect(await prisma!.todoItem.count({ where: { deletedAt: null } })).toBe(
      2,
    );
  });

  it('循环任务关系拒绝整个事务且不保存回执', async () => {
    // 第一条环中的任务。
    const firstId = randomUUID();
    // 第二条环中的任务。
    const secondId = randomUUID();
    // 两条外键均存在但形成循环的完整事务。
    const cyclic = batch([
      put(
        'todo_items',
        { title: 'a', scheduled_date: '2026-09-25', parent_id: secondId },
        firstId,
      ),
      put(
        'todo_items',
        { title: 'b', scheduled_date: '2026-09-25', parent_id: firstId },
        secondId,
      ),
    ]);
    await expect(service.applyBatch(ownerId, cyclic)).rejects.toBeInstanceOf(
      BadRequestException,
    );
    expect(await prisma!.todoItem.count()).toBe(0);
    expect(await prisma!.syncReceipt.count()).toBe(0);
  });

  /// 构造可直接用于严格快照的进度任务和步骤。
  function progressFixture(count = 3, completed = false): SyncOperationDto[] {
    // 包含全部同步字段的根任务。
    const todo = put('todo_items', {
      parent_id: null,
      title: '阅读书籍',
      task_type: 'progress',
      progress_unit: '章',
      description: null,
      scheduled_date: '2026-10-07',
      due_at: null,
      priority_quadrant: 2,
      is_completed: completed,
      completed_at: completed ? timestamp : null,
      reminder_at: null,
      repeat_rule: null,
      repeat_series_id: null,
      sort_order: 0,
      deleted_at: null,
    });
    return [
      todo,
      ...Array.from({ length: count }, (_, index) =>
        put('todo_progress_steps', {
          todo_id: todo.id,
          name: null,
          sort_order: index,
          is_completed: completed,
          completed_at: completed ? timestamp : null,
          deleted_at: null,
        }),
      ),
    ];
  }

  /// 构造步骤目标状态，重试不得变成再次反转。
  function stepState(
    step: SyncOperationDto,
    completed: boolean,
  ): SyncOperationDto {
    return {
      op: 'PATCH',
      table: step.table,
      id: step.id,
      data: {
        is_completed: completed,
        completed_at: completed ? timestamp : null,
      },
    };
  }

  it('进度支持跳序记录，满进度手动确认，重新打开保留所有步骤', async () => {
    // 十二章与根任务一次上传。
    const [todo, ...steps] = progressFixture(12);
    await service.applyBatch(ownerId, batch([todo!, ...steps]));
    await service.applyBatch(
      ownerId,
      batch([0, 2, 7].map((index) => stepState(steps[index]!, true))),
    );
    expect(
      (
        await prisma!.todoProgressStep.findMany({
          where: { isCompleted: true },
          orderBy: { sortOrder: 'asc' },
        })
      ).map((step) => step.sortOrder),
    ).toEqual([0, 2, 7]);
    // 未满时离线确认被纠正，但事务正常确认，不阻塞后续队列。
    const confirm = batch([
      {
        op: 'PATCH',
        table: 'todo_items',
        id: todo!.id,
        data: { is_completed: true, completed_at: timestamp },
      },
    ]);
    await expect(service.applyBatch(ownerId, confirm)).resolves.toMatchObject({
      applied: 1,
      replayed: false,
    });
    expect(
      await prisma!.todoItem.findUnique({ where: { id: todo!.id } }),
    ).toMatchObject({ isCompleted: false, completedAt: null });
    await service.applyBatch(
      ownerId,
      batch(steps.map((step) => stepState(step, true))),
    );
    expect(
      (await prisma!.todoItem.findUniqueOrThrow({ where: { id: todo!.id } }))
        .isCompleted,
    ).toBe(false);
    await service.applyBatch(ownerId, batch(confirm.operations));
    expect(
      (await prisma!.todoItem.findUniqueOrThrow({ where: { id: todo!.id } }))
        .isCompleted,
    ).toBe(true);
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'todo_items',
          id: todo!.id,
          data: { is_completed: false, completed_at: null },
        },
      ]),
    );
    expect(
      await prisma!.todoProgressStep.count({ where: { isCompleted: true } }),
    ).toBe(12);
  });

  it('两端记录不同步骤可合并，幂等重试不覆盖之后的进度，改名排序不覆盖完成', async () => {
    // 两端共享初始未完成快照。
    const [todo, ...steps] = progressFixture();
    await service.applyBatch(ownerId, batch([todo!, ...steps]));
    // 设备 A 的一次已完成操作，之后将原事务完整重试。
    const first = batch([stepState(steps[0]!, true)]);
    await Promise.all([
      service.applyBatch(ownerId, first),
      service.applyBatch(ownerId, batch([stepState(steps[1]!, true)])),
    ]);
    await service.applyBatch(ownerId, batch([stepState(steps[0]!, false)]));
    await expect(service.applyBatch(ownerId, first)).resolves.toMatchObject({
      replayed: true,
    });
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'todo_progress_steps',
          id: steps[1]!.id,
          data: { name: '  重复名称  ', sort_order: 8 },
        },
      ]),
    );
    expect(
      await prisma!.todoProgressStep.findUnique({
        where: { id: steps[0]!.id },
      }),
    ).toMatchObject({ isCompleted: false });
    expect(
      await prisma!.todoProgressStep.findUnique({
        where: { id: steps[1]!.id },
      }),
    ).toMatchObject({ name: '重复名称', sortOrder: 8, isCompleted: true });
  });

  it('已确认任务改名排序及删掉已完成步骤保持确认，新增未完成步骤自动重开', async () => {
    // 已完成快照可在同一事务导入，不能被逐操作协调提前重开。
    const [todo, ...steps] = progressFixture(3, true);
    await service.applyBatch(ownerId, batch([todo!, ...steps]));
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'todo_progress_steps',
          id: steps[0]!.id,
          data: { name: '引言', sort_order: 5 },
        },
        {
          op: 'PATCH',
          table: 'todo_progress_steps',
          id: steps[1]!.id,
          data: { deleted_at: timestamp },
        },
      ]),
    );
    expect(
      await prisma!.todoItem.findUnique({ where: { id: todo!.id } }),
    ).toMatchObject({ isCompleted: true, completedAt: new Date(timestamp) });
    await service.applyBatch(
      ownerId,
      batch([put('todo_progress_steps', { todo_id: todo!.id, sort_order: 6 })]),
    );
    expect(
      await prisma!.todoItem.findUnique({ where: { id: todo!.id } }),
    ).toMatchObject({ isCompleted: false, completedAt: null });
  });

  it.each([true, false])(
    '确认与取消步骤并发无论应用顺序均以最终步骤为准（确认先=%s）',
    async (confirmFirst) => {
      // 初始步骤全满，任务保持待确认。
      const [todo, ...steps] = progressFixture(1, true);
      todo!.data!.is_completed = false;
      todo!.data!.completed_at = null;
      await service.applyBatch(ownerId, batch([todo!, ...steps]));
      // 一端确认任务，另一端撤销同一步。
      const confirm = batch([
        {
          op: 'PATCH',
          table: 'todo_items',
          id: todo!.id,
          data: { is_completed: true, completed_at: timestamp },
        },
      ]);
      // 撤销必须保留明确目标状态。
      const cancel = batch([stepState(steps[0]!, false)]);
      await service.applyBatch(ownerId, confirmFirst ? confirm : cancel);
      await service.applyBatch(ownerId, confirmFirst ? cancel : confirm);
      expect(
        await prisma!.todoItem.findUnique({ where: { id: todo!.id } }),
      ).toMatchObject({ isCompleted: false, completedAt: null });
      expect(await prisma!.syncReceipt.count()).toBe(3);
    },
  );

  it('并发删至零步不删除任务且不能确认，合并超过1000步保留全部数据', async () => {
    // 两台设备分别删除最后两个步骤。
    const [todo, ...steps] = progressFixture(2, true);
    await service.applyBatch(ownerId, batch([todo!, ...steps]));
    await Promise.all(
      steps.map((step) =>
        service.applyBatch(
          ownerId,
          batch([
            {
              op: 'PATCH',
              table: step.table,
              id: step.id,
              data: { deleted_at: timestamp },
            },
          ]),
        ),
      ),
    );
    expect(
      await prisma!.todoItem.findUnique({ where: { id: todo!.id } }),
    ).toMatchObject({ isCompleted: false });
    // 服务端不强加本地添加上限，以免跨设备合并导致数据丢失或堵队列。
    const added = Array.from({ length: 1001 }, (_, index) =>
      put('todo_progress_steps', { todo_id: todo!.id, sort_order: index }),
    );
    await service.applyBatch(ownerId, batch(added));
    expect(
      await prisma!.todoProgressStep.count({ where: { deletedAt: null } }),
    ).toBe(1001);
  });

  it('父任务软删除和恢复保留步骤自身删除标记，永久删除级联墓碑阻止迟到重建', async () => {
    // 一个步骤提前独立删除，另一个仍有效。
    const [todo, ...steps] = progressFixture(2);
    steps[0]!.data!.deleted_at = timestamp;
    await service.applyBatch(ownerId, batch([todo!, ...steps]));
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'todo_items',
          id: todo!.id,
          data: { deleted_at: timestamp },
        },
      ]),
    );
    expect((await migrations.preview('migration-test-key')).deletedCount).toBe(
      1,
    );
    expect(
      await prisma!.todoProgressStep.findUnique({
        where: { id: steps[1]!.id },
      }),
    ).toMatchObject({ deletedAt: null });
    await service.applyBatch(
      ownerId,
      batch([
        {
          op: 'PATCH',
          table: 'todo_items',
          id: todo!.id,
          data: { deleted_at: null },
        },
      ]),
    );
    expect(
      await prisma!.todoProgressStep.count({ where: { deletedAt: null } }),
    ).toBe(1);
    await service.applyBatch(
      ownerId,
      batch([{ op: 'DELETE', table: 'todo_items', id: todo!.id }]),
    );
    expect(await prisma!.todoProgressStep.count()).toBe(0);
    expect(
      await prisma!.syncTombstone.count({
        where: { tableName: 'todo_progress_steps' },
      }),
    ).toBe(2);
    await expect(
      service.applyBatch(
        ownerId,
        batch([steps[1]!, put('todo_progress_steps', { todo_id: todo!.id })]),
      ),
    ).resolves.toMatchObject({ ignored: 2 });
    expect(await prisma!.todoProgressStep.count()).toBe(0);
  });

  it('拒绝普通任务挂步骤、进度任务挂子任务及保存后转换类型', async () => {
    // 普通任务不能通过新增步骤伪装成进度任务。
    const normal = put('todo_items', {
      title: '普通任务',
      scheduled_date: '2026-10-07',
    });
    await service.applyBatch(ownerId, batch([normal]));
    await expect(
      service.applyBatch(
        ownerId,
        batch([put('todo_progress_steps', { todo_id: normal.id })]),
      ),
    ).rejects.toBeInstanceOf(BadRequestException);
    await expect(
      service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: 'todo_items',
            id: normal.id,
            data: { task_type: 'progress' },
          },
        ]),
      ),
    ).rejects.toBeInstanceOf(BadRequestException);
    // 进度任务同样不能出现在普通父子树中。
    const [todo, ...steps] = progressFixture(1);
    await service.applyBatch(ownerId, batch([todo!, ...steps]));
    await expect(
      service.applyBatch(
        ownerId,
        batch([
          put('todo_items', {
            title: '非法子任务',
            scheduled_date: '2026-10-07',
            parent_id: todo!.id,
          }),
        ]),
      ),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(await prisma!.todoItem.count()).toBe(2);
  });

  it('步骤不能跨owner引用任务或在保存后转移任务，重复任务结构由数据库拒绝', async () => {
    // 另一归属的任务仍不允许本 owner 访问。
    const other = await prisma!.syncOwner.create({ data: {} });
    // 另一用户的真实任务及步骤。
    const [todo, ...steps] = progressFixture(1);
    await service.applyBatch(other.id, batch([todo!, ...steps]));
    await expect(
      service.applyBatch(
        ownerId,
        batch([put('todo_progress_steps', { todo_id: todo!.id })]),
      ),
    ).rejects.toBeDefined();
    // 当前用户的另一组任务。
    const local = progressFixture(1);
    await service.applyBatch(ownerId, batch(local));
    await expect(
      service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: 'todo_progress_steps',
            id: local[1]!.id,
            data: { todo_id: todo!.id },
          },
        ]),
      ),
    ).rejects.toBeInstanceOf(BadRequestException);
    await expect(
      service.applyBatch(
        ownerId,
        batch([
          {
            op: 'PATCH',
            table: 'todo_items',
            id: local[0]!.id,
            data: { repeat_rule: 'daily' },
          },
        ]),
      ),
    ).rejects.toBeDefined();
    expect(await prisma!.todoProgressStep.count()).toBe(2);
  });

  it('v2严格快照导入完整进度后保留合法确认，缺父步骤快照拒绝且旧回执仍可查询', async () => {
    // 已完成任务和步骤以完整快照替换服务器。
    const operations = progressFixture(3, true);
    // 需要保留的既有手动完成结果。
    const result = await migrations.replace(migration(operations));
    expect(
      await prisma!.todoItem.findUnique({ where: { id: operations[0]!.id } }),
    ).toMatchObject({ isCompleted: true, completedAt: new Date(timestamp) });
    expect(await prisma!.todoProgressStep.count()).toBe(3);
    expect(
      await migrations.status({
        syncKey: 'migration-test-key',
        migrationId: result.migrationId,
      }),
    ).toEqual(result);
    await expect(
      migrations.replace({
        ...migration(operations.slice(1)),
        expectedOwnerId: result.ownerId,
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    // 升级前已提交的迁移回执不含版本字段，status继续返回原hash以供安全恢复。
    const legacy = await prisma!.syncMigrationReceipt.create({
      data: {
        migrationId: randomUUID(),
        expectedOwnerId: ownerId,
        ownerId: result.ownerId,
        payloadHash: '1'.repeat(64),
      },
    });
    expect(
      await migrations.status({
        syncKey: 'migration-test-key',
        migrationId: legacy.migrationId,
      }),
    ).toMatchObject({ status: 'committed', payloadHash: legacy.payloadHash });
  });

  it('同一自动续费账期只收费一次，迟到设备不会回退会员账期', async () => {
    // 当前已推进到较晚账期的会员。
    const membership = put('memberships', {
      name: 'membership',
      purchase_date: '2026-01-01',
      expiration_date: '2026-12-01',
      renewal_date: '2026-12-01',
      auto_renew: true,
    });
    await service.applyBatch(ownerId, batch([membership]));
    // 同一业务账期在两端的稳定标识。
    const paymentId = businessId('auto-renewal', [membership.id, '2026-09-01']);
    // 设备 A 的自动续费事务。
    const first = batch([
      put(
        'membership_payments',
        {
          membership_id: membership.id,
          amount_cents: 1000,
          paid_at: timestamp,
          valid_from: '2026-09-01',
          valid_until: '2026-10-01',
        },
        paymentId,
      ),
      {
        op: 'PATCH',
        table: 'memberships',
        id: membership.id,
        data: { expiration_date: '2026-10-01', renewal_date: '2026-10-01' },
      },
    ]);
    await service.applyBatch(ownerId, first);
    // 设备 B 同账期但金额不同的迟到事务。
    const second = batch(
      first.operations.map((operation) =>
        operation.table === 'membership_payments'
          ? { ...operation, data: { ...operation.data, amount_cents: 9999 } }
          : operation,
      ),
    );
    await service.applyBatch(ownerId, second);
    expect(await prisma!.membershipPayment.count()).toBe(1);
    expect(
      (
        await prisma!.membershipPayment.findUniqueOrThrow({
          where: { id: paymentId },
        })
      ).amountCents,
    ).toBe(1000);
    // 较晚日期必须保持不变。
    const saved = await prisma!.membership.findUniqueOrThrow({
      where: { id: membership.id },
    });
    expect(saved.expirationDate?.toISOString().slice(0, 10)).toBe('2026-12-01');
    expect(saved.renewalDate?.toISOString().slice(0, 10)).toBe('2026-12-01');
  });
});
