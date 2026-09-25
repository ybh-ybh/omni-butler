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

/// 仅显式配置隔离测试库时运行，不读取应用 DATABASE_URL 或 .env。
const databaseUrl = process.env.OMNI_TEST_DATABASE_URL;
/// 默认单元测试跳过数据库集成测试。
const integration = databaseUrl ? describe : describe.skip;
/// 固定的客户端业务时间。
const timestamp = '2026-09-25T08:00:00.000Z';
/// 含 updated_at 非空列的业务表。
const updatedTables = new Set([
  'todo_items',
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
  // 当前用例独立所有者。
  let ownerId: string;
  // 只有确认空 schema 后才允许清理由此测试创建的对象。
  let ownsSchema = false;
  // 第四份迁移是否原样保留前三份迁移已存入的旧随机日签。
  let preservedLegacySelection = false;

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
    }
    prisma = new PrismaService(
      new ConfigService({ DATABASE_URL: databaseUrl }),
    );
    await prisma.onModuleInit();
    service = new SyncService(prisma);
  });

  it('第四份迁移原样保留已部署版本的旧随机日签记录', () => {
    expect(preservedLegacySelection).toBe(true);
  });

  beforeEach(async () => {
    if (!ownsSchema) throw new Error('数据库初始化未完成，禁止修改数据');
    await database!.query('TRUNCATE sync_owners CASCADE');
    // 每条测试的内部身份均独立随机生成。
    const owner = await prisma!.syncOwner.create({ data: {} });
    ownerId = owner.id;
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

  it('两个设备分别完成两个孩子后，父任务根据最终状态完成', async () => {
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
    expect(
      (await prisma!.todoItem.findUniqueOrThrow({ where: { id: parent.id } }))
        .isCompleted,
    ).toBe(true);
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
