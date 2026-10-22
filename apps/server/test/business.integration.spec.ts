import {
  BadRequestException,
  ConflictException,
  NotFoundException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Test, type TestingModule } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';
import type { AuthUser } from '../src/auth/auth.types';
import { BusinessModule } from '../src/business/business.module';
import { EventsService } from '../src/business/events.service';
import { InventoryService } from '../src/business/inventory.service';
import { MembershipsService } from '../src/business/memberships.service';
import { NotesBusinessService } from '../src/business/notes-business.service';
import { QuotesService } from '../src/business/quotes.service';
import { TimeEntriesService } from '../src/business/time-entries.service';
import { TodosService } from '../src/business/todos.service';
import { protectRecurringTodo } from '../src/business/todo-recurrence-protection';
import type { Prisma, TimeEntry } from '../src/generated/prisma/client';
import { PrismaService } from '../src/prisma/prisma.service';
import { stableBusinessId } from '../src/sync/sync-consistency';
import { SyncService } from '../src/sync/sync.service';

/// 只接受显式隔离测试库，不读取应用 DATABASE_URL。
const databaseUrl = process.env.OMNI_BUSINESS_TEST_DATABASE_URL;
/// 无专用测试库时保留明确跳过状态。
const integration = databaseUrl ? describe : describe.skip;

/// 读取结构化结果中的服务器实体身份。
function idOf(value: Prisma.JsonValue, nested?: string): string {
  // 测试辅助只解析服务端结果，不生成任何业务状态。
  const object = value as Prisma.JsonObject;
  if (nested) return idOf(object[nested]!);
  if (typeof object.id !== 'string') throw new Error('返回结果缺少实体身份');
  return object.id;
}

/// 从笔记返回值取得当前正式修订身份。
function revisionOf(value: Prisma.JsonValue): string {
  // create/update 的正文结果有明确 note 字段。
  const note = (value as Prisma.JsonObject).note as Prisma.JsonObject;
  if (typeof note.revision !== 'string') throw new Error('缺少正式正文修订');
  return note.revision;
}

integration('七模块后端真实数据库能力', () => {
  jest.setTimeout(60000);
  // 由本测试创建的独立模式才允许清理。
  let ownsSchema = false;
  // 迁移管理连接只针对已验证的空测试库。
  let database: Client;
  // 实际 Prisma 与服务依赖。
  let prisma: PrismaService;
  // 验证 Nest 模块真实注册和导出，而非手工替身服务。
  let module: TestingModule;
  // 每个测试独立的已授权调用身份。
  let actor: AuthUser;
  // 另一归属用于引用和授权隔离。
  let other: AuthUser;
  // 七个实际服务实例。
  let quotes: QuotesService,
    time: TimeEntriesService,
    todos: TodosService,
    inventory: InventoryService,
    memberships: MembershipsService,
    events: EventsService,
    notes: NotesBusinessService;
  // 同步入口必须与在线入口共同作用真实表。
  let sync: SyncService;
  // 升级前准备的孤立关系与软删仍有效关系。
  const orphanId = randomUUID(),
    retainedLinkId = randomUUID(),
    upgradeOwner = randomUUID();

  beforeAll(async () => {
    // 拒绝远程目标、现有表和实际库名不符。
    const url = new URL(databaseUrl!);
    if (
      url.hostname !== '127.0.0.1' ||
      !/^\/[A-Za-z0-9_]+_test$/.test(url.pathname)
    )
      throw new Error('业务集成仅允许显式本机 test 库');
    database = new Client({ connectionString: databaseUrl });
    await database.connect();
    // 防止连接参数被代理重定向到其他库。
    const actual = await database.query<{ name: string }>(
      'SELECT current_database() AS name',
    );
    if (`/${actual.rows[0]?.name}` !== url.pathname)
      throw new Error('实际测试库与目标不一致');
    // 不清理任何已有数据，要求从空库应用真实迁移。
    const tables = await database.query(
      "SELECT tablename FROM pg_tables WHERE schemaname='public'",
    );
    if (tables.rows.length)
      throw new Error('业务集成要求空 schema，不清理已有表');
    ownsSchema = true;
    for (const migration of readdirSync(
      join(__dirname, '../prisma/migrations'),
      { withFileTypes: true },
    )
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort()) {
      if (migration === '20261020010000_business_operations') {
        // 升级前真实数据：缺失业务记录的链接应删除，软删除父项的链接必须保留。
        const taxonomyId = randomUUID(),
          retainedItemId = randomUUID();
        await database.query('INSERT INTO sync_owners(id) VALUES ($1)', [
          upgradeOwner,
        ]);
        await database.query(
          "INSERT INTO taxonomy_entries(id,user_id,module,kind,name,color_value,updated_at) VALUES($1,$2,'inventory','category','升级分类',0,now())",
          [taxonomyId, upgradeOwner],
        );
        await database.query(
          "INSERT INTO inventory_items(id,user_id,name,updated_at,deleted_at) VALUES($1,$2,'软删但可恢复',now(),now())",
          [retainedItemId, upgradeOwner],
        );
        await database.query(
          "INSERT INTO record_taxonomy_links(id,user_id,module,record_id,taxonomy_id) VALUES($1,$2,'inventory',$3,$4),($5,$2,'inventory',$6,$4)",
          [
            orphanId,
            upgradeOwner,
            randomUUID(),
            taxonomyId,
            retainedLinkId,
            retainedItemId,
          ],
        );
      }
      await database.query(
        readFileSync(
          join(__dirname, '../prisma/migrations', migration, 'migration.sql'),
          'utf8',
        ),
      );
    }
    prisma = new PrismaService(
      new ConfigService({ DATABASE_URL: databaseUrl }),
    );
    await prisma.$connect();
    module = await Test.createTestingModule({ imports: [BusinessModule] })
      .overrideProvider(PrismaService)
      .useValue(prisma)
      .compile();
    quotes = module.get(QuotesService);
    time = module.get(TimeEntriesService);
    todos = module.get(TodosService);
    inventory = module.get(InventoryService);
    memberships = module.get(MembershipsService);
    events = module.get(EventsService);
    notes = module.get(NotesBusinessService);
    sync = new SyncService(prisma);
  });

  beforeEach(async () => {
    // 两份独立 owner 与固定会话到期日，不借用正式凭据。
    actor = { sub: randomUUID(), sid: randomUUID(), typ: 'access' };
    other = { sub: randomUUID(), sid: randomUUID(), typ: 'access' };
    for (const identity of [actor, other]) {
      await prisma.syncOwner.create({ data: { id: identity.sub } });
      await prisma.deviceSession.create({
        data: {
          id: identity.sid,
          userId: identity.sub,
          tokenHash: '0'.repeat(64),
          expiresAt: new Date('2099-01-01T00:00:00Z'),
        },
      });
    }
  });

  afterEach(async () => {
    if (prisma)
      await prisma.syncOwner.deleteMany({
        where: {
          id: {
            in: [actor?.sub, other?.sub].filter((id): id is string => !!id),
          },
        },
      });
  });

  afterAll(async () => {
    if (module) await module.close();
    else if (prisma) await prisma.$disconnect();
    if (database) {
      if (ownsSchema) await database.query('DROP SCHEMA public CASCADE');
      await database.end();
    }
  });

  it('增量迁移清理孤立关联、保留可恢复关系，回执不进入PowerSync发布', async () => {
    expect(
      await prisma.recordTaxonomyLink.findUnique({ where: { id: orphanId } }),
    ).toBeNull();
    expect(
      await prisma.recordTaxonomyLink.findUnique({
        where: { id: retainedLinkId },
      }),
    ).not.toBeNull();
    expect(
      await prisma.syncTombstone.findUnique({
        where: {
          userId_tableName_recordId: {
            userId: upgradeOwner,
            tableName: 'record_taxonomy_links',
            recordId: orphanId,
          },
        },
      }),
    ).not.toBeNull();
    // 迁移仅新增内部表，没有扩大同步发布。
    const published = await database.query(
      "SELECT tablename FROM pg_publication_tables WHERE pubname='powersync'",
    );
    expect(
      published.rows.map((row: { tablename: string }) => row.tablename),
    ).not.toContain('business_operation_receipts');
  });

  /// 基本CRUD仍由每个模块真实服务执行，覆盖全部七模块。
  const cases = [
    {
      name: '名言',
      create: (): Promise<Prisma.JsonValue> =>
        quotes.create(actor, { operationId: randomUUID(), content: '原名言' }),
      update: (id: string): Promise<Prisma.JsonValue> =>
        quotes.update(actor, {
          operationId: randomUUID(),
          id,
          content: '新名言',
        }),
      get: (identity: AuthUser, id: string): Promise<Prisma.JsonValue> =>
        quotes.get(identity, id),
      trash: (id: string): Promise<Prisma.JsonValue> =>
        quotes.trash(actor, { operationId: randomUUID(), id }),
    },
    {
      name: '时间',
      create: (): Promise<Prisma.JsonValue> =>
        time.create(actor, {
          operationId: randomUUID(),
          startedAt: '2026-01-01T08:00:00Z',
          endedAt: '2026-01-01T09:00:00Z',
          activity: '原活动',
          timeZone: 'Asia/Shanghai',
        }),
      update: (id: string): Promise<Prisma.JsonValue> =>
        time.update(actor, {
          operationId: randomUUID(),
          id,
          activity: '新活动',
          timeZone: 'Asia/Shanghai',
        }),
      get: (identity: AuthUser, id: string): Promise<Prisma.JsonValue> =>
        time.get(identity, id),
      trash: (id: string): Promise<Prisma.JsonValue> =>
        time.trash(actor, { operationId: randomUUID(), id }),
    },
    {
      name: '待办',
      create: (): Promise<Prisma.JsonValue> =>
        todos.create(actor, {
          operationId: randomUUID(),
          title: '原待办',
          scheduledDate: '2026-01-01',
        }),
      update: (id: string): Promise<Prisma.JsonValue> =>
        todos.update(actor, { operationId: randomUUID(), id, title: '新待办' }),
      get: (identity: AuthUser, id: string): Promise<Prisma.JsonValue> =>
        todos.get(identity, id),
      trash: (id: string): Promise<Prisma.JsonValue> =>
        todos.trash(actor, { operationId: randomUUID(), id }),
    },
    {
      name: '物品',
      create: (): Promise<Prisma.JsonValue> =>
        inventory.create(actor, { operationId: randomUUID(), name: '原物品' }),
      update: (id: string): Promise<Prisma.JsonValue> =>
        inventory.update(actor, {
          operationId: randomUUID(),
          id,
          name: '新物品',
        }),
      get: (identity: AuthUser, id: string): Promise<Prisma.JsonValue> =>
        inventory.get(identity, id),
      trash: (id: string): Promise<Prisma.JsonValue> =>
        inventory.trash(actor, { operationId: randomUUID(), id }),
    },
    {
      name: '会员',
      create: (): Promise<Prisma.JsonValue> =>
        memberships.create(actor, {
          operationId: randomUUID(),
          name: '原会员',
          purchaseDate: '2026-01-01',
          expirationDate: '2027-01-01',
          timeZone: 'Asia/Shanghai',
        }),
      update: (id: string): Promise<Prisma.JsonValue> =>
        memberships.update(actor, {
          operationId: randomUUID(),
          id,
          name: '新会员',
        }),
      get: (identity: AuthUser, id: string): Promise<Prisma.JsonValue> =>
        memberships.get(identity, id),
      trash: (id: string): Promise<Prisma.JsonValue> =>
        memberships.trash(actor, { operationId: randomUUID(), id }),
    },
    {
      name: '事件',
      create: (): Promise<Prisma.JsonValue> =>
        events.create(actor, { operationId: randomUUID(), name: '原事件' }),
      update: (id: string): Promise<Prisma.JsonValue> =>
        events.update(actor, { operationId: randomUUID(), id, name: '新事件' }),
      get: (identity: AuthUser, id: string): Promise<Prisma.JsonValue> =>
        events.get(identity, id),
      trash: (id: string): Promise<Prisma.JsonValue> =>
        events.trash(actor, { operationId: randomUUID(), id }),
    },
    {
      name: '笔记',
      create: (): Promise<Prisma.JsonValue> =>
        notes.create(actor, {
          operationId: randomUUID(),
          body: '原笔记',
          timeZone: 'Asia/Shanghai',
        }),
      update: (
        id: string,
        original: Prisma.JsonValue,
      ): Promise<Prisma.JsonValue> =>
        notes.update(actor, {
          operationId: randomUUID(),
          id,
          body: '新笔记',
          expectedRevision: revisionOf(original),
        }),
      get: (identity: AuthUser, id: string): Promise<Prisma.JsonValue> =>
        notes.get(identity, id),
      trash: (id: string): Promise<Prisma.JsonValue> =>
        notes.trash(actor, { operationId: randomUUID(), id }),
      nested: 'note',
    },
  ];

  it.each(cases)(
    '$name：同一业务入口完成CRUD、拒绝其他owner并保持删除优先',
    async (item) => {
      // 正式数据由实际业务方法创建。
      const created = await item.create();
      // 笔记结果另带冲突状态，实体在 note 字段。
      const id = idOf(created, item.nested);
      await expect(item.get(other, id)).rejects.toBeInstanceOf(
        NotFoundException,
      );
      await item.update(id, created);
      // 再读取持久值，不能只以方法返回或实体仍存在证明修改成功。
      const expected = (
        {
          名言: { content: '新名言' },
          时间: { activity: '新活动' },
          待办: { title: '新待办' },
          物品: { name: '新物品' },
          会员: { name: '新会员' },
          事件: { name: '新事件' },
          笔记: { body: '新笔记' },
        } as Record<string, Record<string, string>>
      )[item.name]!;
      expect(await item.get(actor, id)).toEqual(
        expect.objectContaining({ id, ...expected }),
      );
      await item.trash(id);
      await expect(item.get(actor, id)).rejects.toBeInstanceOf(
        NotFoundException,
      );
      await expect(item.update(id, created)).rejects.toBeInstanceOf(
        NotFoundException,
      );
    },
  );

  it('并发重复请求只提交一次，返回原结果而非重新执行，并拒绝异内容复用身份', async () => {
    // 同一次动作在请求丢失后保留操作身份。
    const input = { operationId: randomUUID(), content: '只新增一次' };
    // 两个实际数据库事务竞争相同owner锁。
    const [first, replay] = await Promise.all([
      quotes.create(actor, input),
      quotes.create(actor, input),
    ]);
    expect(replay).toEqual(first);
    expect(await prisma.quote.count({ where: { userId: actor.sub } })).toBe(1);
    await expect(
      quotes.create(actor, { ...input, content: '不同内容' }),
    ).rejects.toBeInstanceOf(ConflictException);
    await quotes.update(actor, {
      operationId: randomUUID(),
      id: idOf(first),
      content: '后续编辑',
    });
    expect(await quotes.create(actor, input)).toEqual(first);
    expect(await quotes.get(actor, idOf(first))).toEqual(
      expect.objectContaining({ content: '后续编辑' }),
    );
  });

  it('撤销会话后既有回执也不能重新授权，方法参数拒绝夹带owner', async () => {
    // 成功回执不替代后续请求的身份校验。
    const input = { operationId: randomUUID(), content: '会话测试' };
    await quotes.create(actor, input);
    await prisma.deviceSession.delete({ where: { id: actor.sid } });
    await expect(quotes.create(actor, input)).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
    expect(() =>
      inventory.create(other, {
        operationId: randomUUID(),
        name: '非法参数',
        userId: actor.sub,
      }),
    ).toThrow(BadRequestException);
  });

  it('纯查询不创建日签、重复实例或默认分类，分页不假装返回完整列表', async () => {
    await expect(quotes.daily(actor, { day: '2026-01-01' })).resolves.toEqual({
      day: '2026-01-01',
      selectionId: null,
      quote: null,
    });
    await todos.list(actor, { fromDay: '2026-01-01', toDay: '2026-02-01' });
    expect(
      await prisma.dailyQuoteSelection.count({ where: { userId: actor.sub } }),
    ).toBe(0);
    expect(
      await prisma.taxonomyEntry.count({ where: { userId: actor.sub } }),
    ).toBe(0);
    for (const content of ['甲', '乙', '丙'])
      await quotes.create(actor, { operationId: randomUUID(), content });
    expect(await quotes.list(actor, { limit: 1 })).toEqual(
      expect.objectContaining({ hasMore: true, nextOffset: 1 }),
    );
    expect(await quotes.list(actor, { limit: 1, offset: 2 })).toEqual(
      expect.objectContaining({ hasMore: false, nextOffset: null }),
    );
  });

  it.each(['inventory', 'membership'] as const)(
    '%s分类名称与ID始终同步，缺省保留、清空和旧文字解除旧关联',
    async (moduleName) => {
      // 两模块复用相同真实领域规则，但各自仅能引用本模块的分类。
      const first = await prisma.taxonomyEntry.create({
        data: {
          id: randomUUID(),
          userId: actor.sub,
          module: moduleName,
          kind: 'category',
          name: '原分类',
        },
      });
      // 名称路径必须解析成此真实分类，而非仅覆盖兼容文字。
      const second = await prisma.taxonomyEntry.create({
        data: {
          id: randomUUID(),
          userId: actor.sub,
          module: moduleName,
          kind: 'category',
          name: '新分类',
        },
      });
      // 独立标签用于确保只修改分类不影响其他类型。
      const tag = await prisma.taxonomyEntry.create({
        data: {
          id: randomUUID(),
          userId: actor.sub,
          module: moduleName,
          kind: 'tag',
          name: '保留标签',
        },
      });
      // 新增使用各自原有业务入口，会员构造不涉及真实费用的永久类型。
      const create = (
        fields: Record<string, unknown>,
      ): Promise<Prisma.JsonValue> =>
        moduleName === 'inventory'
          ? inventory.create(actor, {
              operationId: randomUUID(),
              name: '分类一致性物品',
              ...fields,
            })
          : memberships.create(actor, {
              operationId: randomUUID(),
              name: '分类一致性会员',
              purchaseDate: '2026-10-21',
              isPermanent: true,
              timeZone: 'Asia/Shanghai',
              ...fields,
            });
      // 创建时的规范分类与名称必须一致。
      const created = await create({
        categoryIds: [first.id],
        ...(moduleName === 'membership' ? { tagIds: [tag.id] } : {}),
      });
      // 后续编辑只传明确变化的字段。
      const edit = (
        fields: Record<string, unknown>,
      ): Promise<Prisma.JsonValue> =>
        moduleName === 'inventory'
          ? inventory.update(actor, {
              operationId: randomUUID(),
              id: idOf(created),
              ...fields,
            })
          : memberships.update(actor, {
              operationId: randomUUID(),
              id: idOf(created),
              ...fields,
            });
      // 客户端实际使用的活跃分类关系必须与名称同步。
      const categoryIds = async (): Promise<string[]> =>
        (
          await prisma.recordTaxonomyLink.findMany({
            where: {
              userId: actor.sub,
              recordId: idOf(created),
              deletedAt: null,
              taxonomy: { kind: 'category' },
            },
          })
        ).map((link) => link.taxonomyId);
      expect(created).toMatchObject({ category: '原分类' });
      expect(await edit({ category: ' 新分类 ' })).toMatchObject({
        category: '新分类',
      });
      expect(await categoryIds()).toEqual([second.id]);
      expect(await edit({ notes: '只改备注' })).toMatchObject({
        category: '新分类',
      });
      expect(await categoryIds()).toEqual([second.id]);
      expect(await edit({ category: '历史未建分类' })).toMatchObject({
        category: '历史未建分类',
      });
      expect(await categoryIds()).toEqual([]);
      expect(
        await prisma.taxonomyEntry.count({
          where: { userId: actor.sub, name: '历史未建分类' },
        }),
      ).toBe(0);
      await edit({ categoryIds: [second.id] });
      expect(await edit({ category: null })).toMatchObject({ category: null });
      expect(await categoryIds()).toEqual([]);
      await edit({ category: '原分类' });
      expect(await edit({ categoryIds: [] })).toMatchObject({ category: null });
      expect(await categoryIds()).toEqual([]);
      if (moduleName === 'membership')
        expect(
          await prisma.recordTaxonomyLink.count({
            where: {
              recordId: idOf(created),
              taxonomyId: tag.id,
              deletedAt: null,
            },
          }),
        ).toBe(1);
    },
  );

  it('物品位置名称更新同步关联，不影响分类，名称与ID互斥及重名失败均无副作用', async () => {
    // 正确分类和两个位置构成已有真实关系。
    const category = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'category',
        name: '数码',
      },
    });
    // 初始位置用于确认旧关系被替换。
    const oldLocation = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'location',
        name: '书房',
      },
    });
    // 新位置从兼容文字解析到规范身份。
    const newLocation = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'location',
        name: '客厅',
      },
    });
    // 创建本体与关系仍然原子保存。
    const created = await inventory.create(actor, {
      operationId: randomUUID(),
      name: '位置一致性',
      categoryIds: [category.id],
      locationIds: [oldLocation.id],
    });
    // 编辑真实目标，不借用任何测试替身。
    const edit = (fields: Record<string, unknown>): Promise<Prisma.JsonValue> =>
      inventory.update(actor, {
        operationId: randomUUID(),
        id: idOf(created),
        ...fields,
      });
    expect(await edit({ location: '客厅' })).toMatchObject({
      category: '数码',
      location: '客厅',
    });
    expect(
      (
        await prisma.recordTaxonomyLink.findMany({
          where: { recordId: idOf(created), deletedAt: null },
        })
      )
        .map((link) => link.taxonomyId)
        .sort(),
    ).toEqual([category.id, newLocation.id].sort());
    await expect(
      edit({ category: '数码', categoryIds: [category.id] }),
    ).rejects.toBeInstanceOf(BadRequestException);
    await expect(
      edit({ location: null, locationIds: [] }),
    ).rejects.toBeInstanceOf(BadRequestException);
    await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'location',
        name: '客厅',
      },
    });
    await expect(edit({ location: '客厅' })).rejects.toBeInstanceOf(
      ConflictException,
    );
    expect(await inventory.get(actor, idOf(created))).toMatchObject({
      category: '数码',
      location: '客厅',
    });
    expect(
      await prisma.recordTaxonomyLink.count({
        where: { recordId: idOf(created), deletedAt: null },
      }),
    ).toBe(2);
  });

  it('物品及会员拒绝UUID名称和互相矛盾的字段，普通文字标签仍可用', async () => {
    // 同时覆盖单个UUID及逗号列表中混入的UUID。
    const uuid = randomUUID();
    for (const fields of [
      { category: uuid },
      { location: uuid },
      { tags: [uuid] },
      { category: `文字,${uuid}` },
      { tags: [`文字,${uuid}`] },
      { category: null, categoryIds: [] },
      { location: '书房', locationIds: [] },
    ])
      await expect(async () =>
        inventory.create(actor, {
          operationId: randomUUID(),
          name: '不得误存',
          ...fields,
        }),
      ).rejects.toBeInstanceOf(BadRequestException);
    for (const fields of [
      { category: uuid },
      { category: `文字,${uuid}` },
      { category: '视频', categoryIds: [] },
    ])
      await expect(async () =>
        memberships.create(actor, {
          operationId: randomUUID(),
          name: '不得误存',
          purchaseDate: '2026-10-21',
          isPermanent: true,
          timeZone: 'Asia/Shanghai',
          ...fields,
        }),
      ).rejects.toBeInstanceOf(BadRequestException);
    expect(
      await prisma.inventoryItem.count({ where: { userId: actor.sub } }),
    ).toBe(0);
    expect(
      await prisma.membership.count({ where: { userId: actor.sub } }),
    ).toBe(0);
    expect(
      await inventory.create(actor, {
        operationId: randomUUID(),
        name: '正常标签',
        tags: ['常用', '随身'],
      }),
    ).toMatchObject({ tags: '常用,随身' });
  });

  it.each([0, 1, 2, 3])(
    '待办象限%s可新增、编辑和整树移动，编号沿用客户端',
    async (quadrant) => {
      // 合法四象限不能再漏掉0，不能重新映射1至3的含义。
      const created = await todos.create(actor, {
        operationId: randomUUID(),
        title: '象限一致性',
        scheduledDate: '2026-10-21',
        priorityQuadrant: quadrant,
      });
      expect(created).toMatchObject({ priorityQuadrant: quadrant });
      // 先移到其他象限，再通过编辑设置当前编号。
      const another = (quadrant + 1) % 4;
      await todos.update(actor, {
        operationId: randomUUID(),
        id: idOf(created),
        priorityQuadrant: another,
      });
      expect(
        await todos.update(actor, {
          operationId: randomUUID(),
          id: idOf(created),
          priorityQuadrant: quadrant,
        }),
      ).toMatchObject({ priorityQuadrant: quadrant });
      // 子任务移动必须连同根节点，不破坏已有聚合规则。
      const child = await todos.create(actor, {
        operationId: randomUUID(),
        title: '象限孩子',
        scheduledDate: '2026-10-21',
        parentId: idOf(created),
      });
      await todos.setQuadrant(actor, {
        operationId: randomUUID(),
        id: idOf(child),
        priorityQuadrant: another,
      });
      await todos.setQuadrant(actor, {
        operationId: randomUUID(),
        id: idOf(child),
        priorityQuadrant: quadrant,
      });
      expect(await todos.get(actor, idOf(created))).toMatchObject({
        priorityQuadrant: quadrant,
      });
      expect(await todos.get(actor, idOf(child))).toMatchObject({
        priorityQuadrant: quadrant,
      });
    },
  );

  it('待办拒绝非法象限，既存4保留原事实并允许用户明确改正', async () => {
    // 通过正常入口建立目标，非法变更不产生半条记录。
    const created = await todos.create(actor, {
      operationId: randomUUID(),
      title: '保留异常待办',
      scheduledDate: '2026-10-21',
    });
    for (const priorityQuadrant of [-1, 4, 5]) {
      await expect(async () =>
        todos.create(actor, {
          operationId: randomUUID(),
          title: '不得保存',
          scheduledDate: '2026-10-21',
          priorityQuadrant,
        }),
      ).rejects.toBeInstanceOf(BadRequestException);
      await expect(async () =>
        todos.update(actor, {
          operationId: randomUUID(),
          id: idOf(created),
          priorityQuadrant,
        }),
      ).rejects.toBeInstanceOf(BadRequestException);
      await expect(async () =>
        todos.setQuadrant(actor, {
          operationId: randomUUID(),
          id: idOf(created),
          priorityQuadrant,
        }),
      ).rejects.toBeInstanceOf(BadRequestException);
    }
    await prisma.todoItem.update({
      where: { id: idOf(created) },
      data: { priorityQuadrant: 4 },
    });
    expect(await todos.get(actor, idOf(created))).toMatchObject({
      priorityQuadrant: 4,
    });
    await expect(
      todos.create(actor, {
        operationId: randomUUID(),
        title: '不得继承四',
        scheduledDate: '2026-10-21',
        parentId: idOf(created),
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    // 旧错误系列也不能通过显式物化继续生成新的象限4实例。
    const seed = await todos.create(actor, {
      operationId: randomUUID(),
      title: '不得传播四',
      scheduledDate: '2026-10-21',
      repeatRule: 'daily',
    });
    await prisma.todoItem.update({
      where: { id: idOf(seed) },
      data: { priorityQuadrant: 4 },
    });
    await expect(
      todos.ensureRepeatedInstances(actor, {
        operationId: randomUUID(),
        day: '2026-10-22',
        timeZone: 'Asia/Shanghai',
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(
      await prisma.todoItem.count({
        where: { userId: actor.sub, title: '不得传播四' },
      }),
    ).toBe(1);
    await todos.setQuadrant(actor, {
      operationId: randomUUID(),
      id: idOf(seed),
      priorityQuadrant: 0,
    });
    await todos.setQuadrant(actor, {
      operationId: randomUUID(),
      id: idOf(created),
      priorityQuadrant: 3,
    });
    expect(await todos.get(actor, idOf(created))).toMatchObject({
      priorityQuadrant: 3,
    });
  });

  it('分类修复迁移补齐可确认UUID名称与关系，保留歧义、无效引用和旧象限4且可重复执行', async () => {
    // 有效目标分别属于真实模块和类型，禁止跨字段复用同一假分类。
    const itemCategory = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'category',
        name: '数码',
      },
    });
    // 旧位置UUID可以安全恢复为名称和规范关联。
    const location = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'location',
        name: '书房',
      },
    });
    // 会员分类不能被当作物品类别。
    const memberCategory = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'membership',
        kind: 'category',
        name: '视频',
      },
    });
    // 已有相反关联的记录无法确定文字和关系哪个才是用户意图。
    const another = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'category',
        name: '办公',
      },
    });
    // 被禁用或跨归属的分类不能由迁移重新启用或绑定。
    const disabled = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'category',
        name: '停用',
        isEnabled: false,
      },
    });
    // 外部归属独立于当前owner。
    const foreign = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: other.sub,
        module: 'inventory',
        kind: 'category',
        name: '其他人',
      },
    });
    // 只对实际修复的行推进游标，避免重复迁移反复触发同步。
    const oldTime = new Date('2020-01-01T00:00:00Z');
    // 两个文字字段和标签文字都误填UUID的原始记录。
    const item = await prisma.inventoryItem.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        name: '旧UUID物品',
        category: ` ${itemCategory.id.toUpperCase()} `,
        location: location.id,
        tags: `常用,${itemCategory.id}`,
        notes: '原备注',
        updatedAt: oldTime,
      },
    });
    // 会员保留原有效期事实及金额，不由修复生成首购。
    const member = await prisma.membership.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        name: '旧UUID会员',
        purchaseDate: oldTime,
        isPermanent: true,
        category: memberCategory.id,
        updatedAt: oldTime,
      },
    });
    // 这些记录都必须原样保留，不能在迁移中猜测归属或意图。
    const skipped = await prisma.inventoryItem.createManyAndReturn({
      data: [
        {
          id: randomUUID(),
          userId: actor.sub,
          name: '歧义',
          category: itemCategory.id,
          updatedAt: oldTime,
        },
        {
          id: randomUUID(),
          userId: actor.sub,
          name: '停用',
          category: disabled.id,
          updatedAt: oldTime,
        },
        {
          id: randomUUID(),
          userId: actor.sub,
          name: '跨用户',
          category: foreign.id,
          updatedAt: oldTime,
        },
        {
          id: randomUUID(),
          userId: actor.sub,
          name: '错模块',
          category: memberCategory.id,
          updatedAt: oldTime,
        },
        {
          id: randomUUID(),
          userId: actor.sub,
          name: '未知',
          category: randomUUID(),
          updatedAt: oldTime,
        },
        {
          id: randomUUID(),
          userId: actor.sub,
          name: '名称分叉',
          category: '另一个文字名称',
          updatedAt: oldTime,
        },
      ],
    });
    for (const record of skipped.filter(
      (row) => row.name === '歧义' || row.name === '名称分叉',
    ))
      await prisma.recordTaxonomyLink.create({
        data: {
          id: randomUUID(),
          userId: actor.sub,
          module: 'inventory',
          recordId: record.id,
          taxonomyId: another.id,
        },
      });
    // 旧象限4无法安全自动推断成0或3。
    const todo = await prisma.todoItem.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        title: '旧象限待核对',
        scheduledDate: oldTime,
        priorityQuadrant: 4,
      },
    });
    // 直接执行将部署的真实SQL。
    const migration = readFileSync(
      join(
        __dirname,
        '../prisma/migrations/20261021020000_named_taxonomy_repairs/migration.sql',
      ),
      'utf8',
    );
    await database.query(migration);
    // 正式身份、备注等业务事实保持，只有可确认字段与游标变化。
    const repaired = await prisma.inventoryItem.findUniqueOrThrow({
      where: { id: item.id },
    });
    expect(repaired).toEqual({
      ...item,
      category: '数码',
      location: '书房',
      tags: '常用,数码',
      updatedAt: expect.any(Date),
    });
    expect(repaired.updatedAt.getTime()).toBeGreaterThan(oldTime.getTime());
    expect(
      await prisma.membership.findUniqueOrThrow({ where: { id: member.id } }),
    ).toEqual({ ...member, category: '视频', updatedAt: expect.any(Date) });
    expect(
      await prisma.membershipPayment.count({
        where: { membershipId: member.id },
      }),
    ).toBe(0);
    expect(
      (
        await prisma.recordTaxonomyLink.findMany({
          where: { recordId: item.id, deletedAt: null },
        })
      )
        .map((link) => link.taxonomyId)
        .sort(),
    ).toEqual([itemCategory.id, location.id].sort());
    expect(
      await prisma.recordTaxonomyLink.count({
        where: {
          recordId: member.id,
          taxonomyId: memberCategory.id,
          deletedAt: null,
        },
      }),
    ).toBe(1);
    for (const record of skipped)
      expect(
        await prisma.inventoryItem.findUniqueOrThrow({
          where: { id: record.id },
        }),
      ).toEqual(record);
    expect(
      await prisma.todoItem.findUniqueOrThrow({ where: { id: todo.id } }),
    ).toEqual(todo);
    await database.query(migration);
    expect(
      await prisma.inventoryItem.findUniqueOrThrow({ where: { id: item.id } }),
    ).toEqual(repaired);
    expect(
      await prisma.recordTaxonomyLink.count({
        where: { recordId: item.id, deletedAt: null },
      }),
    ).toBe(2);
  });

  it('时间分类ID在补记、开始、编辑和结束中解析为名称，省略保留且null清空', async () => {
    // 分类由真实用户数据提供，不借用固定默认ID。
    const category = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'timeline',
        kind: 'category',
        name: '学习',
      },
    });
    // 用户示例在上海时区对应20:00至21:40。
    const created = await time.create(actor, {
      operationId: randomUUID(),
      timeZone: 'Asia/Shanghai',
      startedAt: '2026-10-21T12:00:00Z',
      endedAt: '2026-10-21T13:40:00Z',
      activity: '源哥面试复盘',
      categoryId: category.id.toUpperCase(),
    });
    expect(created).toEqual(expect.objectContaining({ category: '学习' }));
    expect(
      await time.statistics(actor, {
        from: '2026-10-21T12:00:00Z',
        to: '2026-10-21T13:40:00Z',
        asOf: '2026-10-21T13:40:00Z',
        timeZone: 'Asia/Shanghai',
      }),
    ).toEqual(
      expect.objectContaining({
        categories: { 学习: 6000 },
        totalSeconds: 6000,
      }),
    );
    expect(
      await time.update(actor, {
        operationId: randomUUID(),
        id: idOf(created),
        timeZone: 'Asia/Shanghai',
        notes: '保留分类',
      }),
    ).toEqual(expect.objectContaining({ category: '学习' }));
    expect(
      await time.update(actor, {
        operationId: randomUUID(),
        id: idOf(created),
        timeZone: 'Asia/Shanghai',
        categoryId: null,
      }),
    ).toEqual(expect.objectContaining({ category: null }));
    expect(
      await time.update(actor, {
        operationId: randomUUID(),
        id: idOf(created),
        timeZone: 'Asia/Shanghai',
        categoryId: category.id,
      }),
    ).toEqual(expect.objectContaining({ category: '学习' }));
    // 开始和结束也使用同一分类解析，结束仍保持已有区间保护。
    const ongoing = await time.start(actor, {
      operationId: randomUUID(),
      timeZone: 'Asia/Shanghai',
      startedAt: '2026-10-22T12:00:00Z',
      categoryId: category.id,
    });
    expect(ongoing).toEqual(expect.objectContaining({ category: '学习' }));
    expect(
      await time.finish(actor, {
        operationId: randomUUID(),
        id: idOf(ongoing),
        timeZone: 'Asia/Shanghai',
        endedAt: '2026-10-22T13:00:00Z',
        activity: '结束学习',
        categoryId: null,
      }),
    ).toEqual(expect.objectContaining({ category: null }));
    expect(
      await time.update(actor, {
        operationId: randomUUID(),
        id: idOf(created),
        timeZone: 'Asia/Shanghai',
        category: '兼容旧分类名称',
      }),
    ).toEqual(expect.objectContaining({ category: '兼容旧分类名称' }));
  });

  it.each([
    'missing',
    'foreign',
    'module',
    'kind',
    'disabled',
    'deleted',
  ] as const)('时间分类拒绝%s引用且不产生记录或幂等回执', async (variant) => {
    // 每种错误引用分别验证owner、模块、类型与有效状态。
    const id = randomUUID();
    if (variant !== 'missing')
      await prisma.taxonomyEntry.create({
        data: {
          id,
          userId: variant === 'foreign' ? other.sub : actor.sub,
          module: variant === 'module' ? 'inventory' : 'timeline',
          kind: variant === 'kind' ? 'tag' : 'category',
          name: '不可绑定',
          isEnabled: variant !== 'disabled',
          deletedAt: variant === 'deleted' ? new Date() : null,
        },
      });
    await expect(
      time.create(actor, {
        operationId: randomUUID(),
        timeZone: 'Asia/Shanghai',
        startedAt: '2026-10-21T12:00:00Z',
        endedAt: '2026-10-21T13:40:00Z',
        activity: '不得保存',
        categoryId: id,
      }),
    ).rejects.toBeInstanceOf(ConflictException);
    expect(await prisma.timeEntry.count({ where: { userId: actor.sub } })).toBe(
      0,
    );
    expect(
      await prisma.businessOperationReceipt.count({
        where: { userId: actor.sub },
      }),
    ).toBe(0);
  });

  it('UUID误填名称、非法分类ID及同时传ID与名称均被明确拒绝', async () => {
    // 所有错误都在写入前拒绝，不能先创建记录再返回参数错误。
    for (const fields of [
      { category: ` ${randomUUID()} ` },
      { categoryId: '学习' },
      { categoryId: null, category: '学习' },
      { categoryId: randomUUID(), category: null },
    ])
      await expect(async () =>
        time.create(actor, {
          operationId: randomUUID(),
          timeZone: 'Asia/Shanghai',
          startedAt: '2026-10-21T12:00:00Z',
          endedAt: '2026-10-21T13:40:00Z',
          activity: '不得保存',
          ...fields,
        }),
      ).rejects.toBeInstanceOf(BadRequestException);
    expect(await prisma.timeEntry.count({ where: { userId: actor.sub } })).toBe(
      0,
    );
  });

  it('时间分类数据迁移只修正同归属有效类别，保留未知值及原时间正文且重复运行不改游标', async () => {
    // 独立构造已存在的误写记录，覆盖不能被猜测修复的边界。
    const variants = [
      'valid',
      'foreign',
      'module',
      'kind',
      'disabled',
      'deleted',
      'unknown',
      'name',
    ] as const;
    // 固定旧游标用于证明仅实际修复行进入同步下行。
    const oldTime = new Date('2020-01-01T00:00:00Z');
    // 保存每个场景原记录用于精确比对非目标字段。
    const records: TimeEntry[] = [];
    for (const variant of variants) {
      // 只有valid分类属于当前owner的有效timeline/category。
      const id = randomUUID();
      if (variant !== 'unknown' && variant !== 'name')
        await prisma.taxonomyEntry.create({
          data: {
            id,
            userId: variant === 'foreign' ? other.sub : actor.sub,
            module: variant === 'module' ? 'inventory' : 'timeline',
            kind: variant === 'kind' ? 'tag' : 'category',
            name: '学习',
            isEnabled: variant !== 'disabled',
            deletedAt: variant === 'deleted' ? oldTime : null,
          },
        });
      records.push(
        await prisma.timeEntry.create({
          data: {
            id: randomUUID(),
            userId: actor.sub,
            entryDate: oldTime,
            startMinute: 1200,
            endMinute: 1300,
            startedAt: new Date('2020-01-01T12:00:00Z'),
            endedAt: new Date('2020-01-01T13:40:00Z'),
            activity: '源哥面试复盘',
            notes: '原备注',
            category:
              variant === 'name'
                ? '学习'
                : variant === 'valid'
                  ? ` ${id.toUpperCase()} `
                  : id,
            updatedAt: oldTime,
          },
        }),
      );
    }
    // 执行真实迁移SQL，不能用测试中的同款更新冒充验证。
    const migration = readFileSync(
      join(
        __dirname,
        '../prisma/migrations/20261021010000_time_category_names/migration.sql',
      ),
      'utf8',
    );
    await database.query(migration);
    // 修复结果保留正式记录身份、时间、活动和备注。
    const repaired = await prisma.timeEntry.findUniqueOrThrow({
      where: { id: records[0]!.id },
    });
    expect(repaired).toEqual({
      ...records[0],
      category: '学习',
      updatedAt: expect.any(Date),
    });
    expect(repaired.updatedAt.getTime()).toBeGreaterThan(oldTime.getTime());
    for (const record of records.slice(1))
      expect(
        await prisma.timeEntry.findUniqueOrThrow({ where: { id: record.id } }),
      ).toEqual(record);
    await database.query(migration);
    expect(
      await prisma.timeEntry.findUniqueOrThrow({ where: { id: repaired.id } }),
    ).toEqual(repaired);
  });

  it('时间区间互斥、跨日DST统计正确，历史多进行中仍可逐条收尾', async () => {
    await time.create(actor, {
      operationId: randomUUID(),
      startedAt: '2026-03-08T05:00:00Z',
      endedAt: '2026-03-09T04:00:00Z',
      activity: '夏令时整日',
      category: '__proto__',
      timeZone: 'America/New_York',
    });
    await expect(
      time.start(actor, {
        operationId: randomUUID(),
        startedAt: '2026-03-08T07:00:00Z',
        timeZone: 'America/New_York',
      }),
    ).rejects.toBeInstanceOf(ConflictException);
    expect(
      await time.statistics(actor, {
        from: '2026-03-08T05:00:00Z',
        to: '2026-03-09T04:00:00Z',
        asOf: '2026-03-09T04:00:00Z',
        timeZone: 'America/New_York',
      }),
    ).toEqual(
      expect.objectContaining({
        totalSeconds: 23 * 3600,
        days: { '2026-03-08': 23 * 3600 },
      }),
    );
    // 模拟旧设备已存在的两个重叠进行中记录，不要求用户先解冲突才能结束。
    const rows = await Promise.all(
      [0, 1].map((index) =>
        prisma.timeEntry.create({
          data: {
            id: randomUUID(),
            userId: actor.sub,
            activity: '旧记录',
            entryDate: new Date('2026-04-01T00:00:00Z'),
            startMinute: index,
            endMinute: index,
            startedAt: new Date(`2026-04-01T0${index}:00:00Z`),
          },
        }),
      ),
    );
    await time.finish(actor, {
      operationId: randomUUID(),
      id: rows[0]!.id,
      endedAt: '2026-04-01T02:00:00Z',
      activity: '已结束',
      timeZone: 'UTC',
    });
    expect(
      (await prisma.timeEntry.findUniqueOrThrow({ where: { id: rows[0]!.id } }))
        .endedAt,
    ).not.toBeNull();
  });

  it('会员主表、首购和分类失败一起回滚；记账、重放及撤销期限一致', async () => {
    // 跨owner分类不能落入新会员，失败后不留首购或回执。
    const foreign = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: other.sub,
        module: 'membership',
        kind: 'category',
        name: '他人分类',
        colorValue: 0,
      },
    });
    await expect(
      memberships.create(actor, {
        operationId: randomUUID(),
        name: '不能部分保存',
        purchaseDate: '2026-01-01',
        expirationDate: '2026-01-31',
        priceCents: 100,
        categoryIds: [foreign.id],
        timeZone: 'Asia/Shanghai',
      }),
    ).rejects.toBeInstanceOf(ConflictException);
    expect(
      await prisma.membership.count({ where: { userId: actor.sub } }),
    ).toBe(0);
    expect(
      await prisma.membershipPayment.count({ where: { userId: actor.sub } }),
    ).toBe(0);
    // 标准续费在已有月底日期后叠加。
    const member = await memberships.create(actor, {
      operationId: randomUUID(),
      name: '订阅',
      purchaseDate: '2026-01-01',
      expirationDate: '2026-01-31',
      billingCycle: 'month',
      timeZone: 'Asia/Shanghai',
    });
    // 账目身份在两次重试中保持。
    const paymentInput = {
      operationId: randomUUID(),
      membershipId: idOf(member),
      amountCents: 1000,
      paidAt: '2026-02-02T01:00:00+08:00',
      timeZone: 'Asia/Shanghai',
    };
    // 真实结果同时包括账目与到期日。
    const payment = await memberships.recordPayment(actor, paymentInput);
    expect(await memberships.recordPayment(actor, paymentInput)).toEqual(
      payment,
    );
    expect(
      (
        await prisma.membership.findUniqueOrThrow({
          where: { id: idOf(member) },
        })
      ).expirationDate?.toISOString(),
    ).toBe('2026-02-28T00:00:00.000Z');
    await memberships.deletePayment(actor, {
      operationId: randomUUID(),
      membershipId: idOf(member),
      paymentId: idOf(payment, 'payment'),
      timeZone: 'Asia/Shanghai',
    });
    expect(
      (
        await prisma.membership.findUniqueOrThrow({
          where: { id: idOf(member) },
        })
      ).expirationDate?.toISOString(),
    ).toBe('2026-01-31T00:00:00.000Z');
  });

  it('事件历史及派生最近完成值共用同步规则，撤销后统计排除', async () => {
    // 初始历史与手工历史均保留独立身份。
    const event = await events.create(actor, {
      operationId: randomUUID(),
      name: '保养',
      initialCompletedAt: '2026-01-01T00:00:00Z',
    });
    // 显式记录在同一事务内重算。
    const completion = await events.complete(actor, {
      operationId: randomUUID(),
      eventId: idOf(event),
      completedAt: '2026-02-01T00:00:00Z',
    });
    expect(await events.get(actor, idOf(event))).toEqual(
      expect.objectContaining({ lastCompletedAt: '2026-02-01T00:00:00.000Z' }),
    );
    await events.undoCompletion(actor, {
      operationId: randomUUID(),
      eventId: idOf(event),
      completionId: idOf(completion, 'completion'),
    });
    expect(await events.get(actor, idOf(event))).toEqual(
      expect.objectContaining({ lastCompletedAt: '2026-01-01T00:00:00.000Z' }),
    );
    expect(
      await events.statistics(actor, {
        from: '2026-02-01T00:00:00Z',
        to: '2026-03-01T00:00:00Z',
        asOf: '2026-03-01T00:00:00Z',
        timeZone: 'UTC',
      }),
    ).toEqual(expect.objectContaining({ completionCount: 0, complete: true }));
  });

  it('物品拒绝循环和跨模块引用，搬家保留跟随配件，金额不重复乘数量', async () => {
    // 主项与配件有不同金额口径。
    const parent = await inventory.create(actor, {
      operationId: randomUUID(),
      name: '相机',
      quantity: 3,
      purchasePriceCents: 6000,
    });
    // 空位置的配件应跟随选中的主物品。
    const child = await inventory.create(actor, {
      operationId: randomUUID(),
      name: '镜头',
      parentItemId: idOf(parent),
      purchasePriceCents: 1000,
    });
    await expect(
      inventory.update(actor, {
        operationId: randomUUID(),
        id: idOf(parent),
        parentItemId: idOf(child),
      }),
    ).rejects.toBeInstanceOf(ConflictException);
    // 真实规范位置无需构造虚拟 taxonomy 框架。
    const location = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'location',
        name: '书柜',
        colorValue: 0,
      },
    });
    expect(
      await inventory.move(actor, {
        operationId: randomUUID(),
        ids: [idOf(parent), idOf(child)],
        destinationLocationId: location.id,
      }),
    ).toEqual(
      expect.objectContaining({
        moved: [idOf(parent)],
        followed: [idOf(child)],
      }),
    );
    expect(await inventory.statistics(actor)).toEqual(
      expect.objectContaining({
        quantity: 3,
        purchasePriceCents: 6000,
        count: 1,
      }),
    );
    expect(
      await inventory.statistics(actor, { includeAccessories: true }),
    ).toEqual(expect.objectContaining({ purchasePriceCents: 7000, count: 2 }));
  });

  it('待办父子完成对称，进度满格需确认，陈旧撤销不会覆盖后续变化', async () => {
    // 普通父子通过真实创建入口建立。
    const parent = await todos.create(actor, {
      operationId: randomUUID(),
      title: '父任务',
      scheduledDate: '2026-01-01',
    });
    // 孩子继承主任务日期和象限。
    const child = await todos.create(actor, {
      operationId: randomUUID(),
      title: '子任务',
      parentId: idOf(parent),
      scheduledDate: '2026-02-01',
    });
    await todos.setCompleted(actor, {
      operationId: randomUUID(),
      id: idOf(parent),
      completed: true,
    });
    expect(await todos.get(actor, idOf(child))).toEqual(
      expect.objectContaining({ isCompleted: true }),
    );
    await todos.setCompleted(actor, {
      operationId: randomUUID(),
      id: idOf(child),
      completed: false,
    });
    expect(await todos.get(actor, idOf(parent))).toEqual(
      expect.objectContaining({ isCompleted: false }),
    );
    // 进度任务步骤保存在独立表。
    const progress = await todos.create(actor, {
      operationId: randomUUID(),
      title: '进度',
      taskType: 'progress',
      scheduledDate: '2026-01-01',
      steps: [{ name: '一步' }],
    });
    // 选择当前实际步骤，不猜测随机身份。
    const step = await prisma.todoProgressStep.findFirstOrThrow({
      where: { userId: actor.sub, todoId: idOf(progress) },
    });
    // 原操作身份用于条件撤销。
    const operationId = randomUUID();
    await todos.setStepsCompleted(actor, {
      operationId,
      todoId: idOf(progress),
      stepIds: [step.id],
      completed: true,
    });
    expect(await todos.get(actor, idOf(progress))).toEqual(
      expect.objectContaining({ isCompleted: false }),
    );
    await todos.setCompleted(actor, {
      operationId: randomUUID(),
      id: idOf(progress),
      completed: true,
    });
    expect(
      await todos.undoSteps(actor, {
        operationId: randomUUID(),
        changeOperationId: operationId,
      }),
    ).toEqual(expect.objectContaining({ undone: false }));
  });

  it('重复实例稳定合并，单次永久删除和未来停止不被再次物化复活', async () => {
    // 月底系列的最早实例锚定后续日历。
    const root = await todos.create(actor, {
      operationId: randomUUID(),
      title: '月底整理',
      scheduledDate: '2026-01-31',
      repeatRule: 'monthly',
    });
    // 只读列表没有生成目标日。
    expect(
      await todos.list(actor, { fromDay: '2026-02-28', toDay: '2026-03-01' }),
    ).toEqual(expect.objectContaining({ items: [] }));
    await todos.ensureRepeatedInstances(actor, {
      operationId: randomUUID(),
      day: '2026-02-28',
      timeZone: 'UTC',
    });
    // 使用真实稳定身份与客户端一致。
    const source = await prisma.todoItem.findUniqueOrThrow({
      where: { id: idOf(root) },
    });
    // 目标实例身份可通过领域公式验证。
    const repeatedId = stableBusinessId('repeat-todo', [
      source.repeatSeriesId!,
      '2026-02-28',
    ]);
    await prisma.todoItem.delete({ where: { id: repeatedId } });
    await todos.ensureRepeatedInstances(actor, {
      operationId: randomUUID(),
      day: '2026-02-28',
      timeZone: 'UTC',
    });
    expect(
      await prisma.todoItem.findUnique({ where: { id: repeatedId } }),
    ).toBeNull();
    await todos.trash(actor, {
      operationId: randomUUID(),
      id: idOf(root),
      scope: 'future',
    });
    await todos.ensureRepeatedInstances(actor, {
      operationId: randomUUID(),
      day: '2026-03-31',
      timeZone: 'UTC',
    });
    expect(
      await prisma.todoItem.count({
        where: {
          userId: actor.sub,
          scheduledDate: new Date('2026-03-31T00:00:00Z'),
        },
      }),
    ).toBe(0);
  });

  it('笔记陈旧编辑保存候选；追加重放不重复，离线旧修订不能覆盖在线新正文', async () => {
    // 笔记初始正式版本。
    const created = await notes.create(actor, {
      operationId: randomUUID(),
      body: '原文',
      timeZone: 'Asia/Shanghai',
    });
    // 一次追加的固定操作身份。
    const appendInput = {
      operationId: randomUUID(),
      id: idOf(created, 'note'),
      text: '追加',
      expectedRevision: revisionOf(created),
    };
    // 正式追加完成后的版本。
    const appended = await notes.append(actor, appendInput);
    expect(await notes.append(actor, appendInput)).toEqual(appended);
    // 基于旧版的人工编辑保留为候选。
    const conflict = await notes.update(actor, {
      operationId: randomUUID(),
      id: idOf(created, 'note'),
      body: '陈旧编辑',
      expectedRevision: revisionOf(created),
    });
    expect(conflict).toEqual(expect.objectContaining({ status: 'conflict' }));
    expect(await notes.get(actor, idOf(created, 'note'))).toEqual(
      expect.objectContaining({ body: '原文\n\n追加' }),
    );
    // 真正离线协议仍保存旧候选，再由同步归一化阻止覆盖当前正文。
    const revision = randomUUID();
    await sync.applyBatch(actor.sub, {
      clientId: randomUUID(),
      transactionId: randomUUID(),
      operations: [
        {
          op: 'PUT',
          table: 'note_versions',
          id: revision,
          data: {
            note_id: idOf(created, 'note'),
            body: '旧设备正文',
            base_revision: revisionOf(created),
            revision,
            created_at: new Date().toISOString(),
            deleted_at: null,
          },
        },
        {
          op: 'PATCH',
          table: 'note_entries',
          id: idOf(created, 'note'),
          data: {
            body: '旧设备正文',
            revision,
            updated_at: new Date().toISOString(),
          },
        },
      ],
    });
    expect(await notes.get(actor, idOf(created, 'note'))).toEqual(
      expect.objectContaining({ body: '原文\n\n追加' }),
    );
    expect(
      await prisma.noteVersion.count({
        where: { userId: actor.sub, noteId: idOf(created, 'note') },
      }),
    ).toBe(4);
  });

  it('永久删除的关联通过实际同步事务清理，并给关联留下墓碑', async () => {
    // 正式位置关系由业务方法产生。
    const category = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'category',
        name: '数码',
        colorValue: 0,
      },
    });
    // 整体保存引用。
    const item = await inventory.create(actor, {
      operationId: randomUUID(),
      name: '待删除',
      categoryIds: [category.id],
    });
    // 当前活动关联身份。
    const link = await prisma.recordTaxonomyLink.findFirstOrThrow({
      where: { userId: actor.sub, recordId: idOf(item) },
    });
    await sync.applyBatch(actor.sub, {
      clientId: randomUUID(),
      transactionId: randomUUID(),
      operations: [{ op: 'DELETE', table: 'inventory_items', id: idOf(item) }],
    });
    expect(
      await prisma.recordTaxonomyLink.findUnique({ where: { id: link.id } }),
    ).toBeNull();
    expect(
      await prisma.syncTombstone.findUnique({
        where: {
          userId_tableName_recordId: {
            userId: actor.sub,
            tableName: 'record_taxonomy_links',
            recordId: link.id,
          },
        },
      }),
    ).not.toBeNull();
    // 新链接身份也不能绕过业务父项的永久墓碑。
    const lateId = randomUUID();
    await sync.applyBatch(actor.sub, {
      clientId: randomUUID(),
      transactionId: randomUUID(),
      operations: [
        {
          op: 'PUT',
          table: 'record_taxonomy_links',
          id: lateId,
          data: {
            module: 'inventory',
            record_id: idOf(item),
            taxonomy_id: category.id,
            created_at: new Date().toISOString(),
            deleted_at: null,
          },
        },
      ],
    });
    expect(
      await prisma.recordTaxonomyLink.findUnique({ where: { id: lateId } }),
    ).toBeNull();
  });

  it('分类链接先于父行上传仍合法，缺失目标及跨模块引用原子拒绝', async () => {
    // 父子顺序可由离线队列任意安排。
    const category = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'inventory',
        kind: 'category',
        name: '类别',
        colorValue: 0,
      },
    });
    // 完整父行身份及链接身份。
    const itemId = randomUUID(),
      linkId = randomUUID();
    await sync.applyBatch(actor.sub, {
      clientId: randomUUID(),
      transactionId: randomUUID(),
      operations: [
        {
          op: 'PUT',
          table: 'record_taxonomy_links',
          id: linkId,
          data: {
            module: 'inventory',
            record_id: itemId,
            taxonomy_id: category.id,
            created_at: new Date().toISOString(),
          },
        },
        {
          op: 'PUT',
          table: 'inventory_items',
          id: itemId,
          data: {
            name: '顺序无关',
            created_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
          },
        },
      ],
    });
    expect(
      await prisma.recordTaxonomyLink.findUnique({ where: { id: linkId } }),
    ).not.toBeNull();
    await expect(
      sync.applyBatch(actor.sub, {
        clientId: randomUUID(),
        transactionId: randomUUID(),
        operations: [
          {
            op: 'PUT',
            table: 'record_taxonomy_links',
            id: randomUUID(),
            data: {
              module: 'inventory',
              record_id: randomUUID(),
              taxonomy_id: category.id,
              created_at: new Date().toISOString(),
            },
          },
        ],
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    // 链接先PUT、父项后DELETE且父项尚不存在，仍按永久删除优先处理。
    const missingId = randomUUID(),
      lateLink = randomUUID();
    await sync.applyBatch(actor.sub, {
      clientId: randomUUID(),
      transactionId: randomUUID(),
      operations: [
        {
          op: 'PUT',
          table: 'record_taxonomy_links',
          id: lateLink,
          data: {
            module: 'inventory',
            record_id: missingId,
            taxonomy_id: category.id,
            created_at: new Date().toISOString(),
          },
        },
        { op: 'DELETE', table: 'inventory_items', id: missingId },
      ],
    });
    expect(
      await prisma.recordTaxonomyLink.findUnique({ where: { id: lateLink } }),
    ).toBeNull();
  });

  it('并发开始串行检查，只有一条进行中记录成功', async () => {
    // 两次不同意图身份也不能绕过当前进行中约束。
    const results = await Promise.allSettled([
      time.start(actor, {
        operationId: randomUUID(),
        startedAt: '2026-07-01T00:00:00Z',
        timeZone: 'UTC',
      }),
      time.start(actor, {
        operationId: randomUUID(),
        startedAt: '2026-07-01T01:00:00Z',
        timeZone: 'UTC',
      }),
    ]);
    expect(
      results.filter((result) => result.status === 'fulfilled'),
    ).toHaveLength(1);
    expect(
      await prisma.timeEntry.count({
        where: { userId: actor.sub, endedAt: null },
      }),
    ).toBe(1);
    expect(
      await prisma.businessOperationReceipt.count({
        where: { userId: actor.sub },
      }),
    ).toBe(1);
  });

  it('跨时区会员账目归入业务自然月，其他归属和回收站不计入', async () => {
    // 本月支付的UTC时间仍属于上个月，validFrom决定业务月。
    const member = await memberships.create(actor, {
      operationId: randomUUID(),
      name: '跨月订阅',
      purchaseDate: '2026-01-01',
      expirationDate: '2026-01-31',
      billingCycle: 'month',
      timeZone: 'Asia/Shanghai',
    });
    await memberships.recordPayment(actor, {
      operationId: randomUUID(),
      membershipId: idOf(member),
      amountCents: 1234,
      paidAt: '2026-01-31T16:30:00Z',
      timeZone: 'Asia/Shanghai',
    });
    expect(
      await memberships.statistics(actor, {
        from: '2026-01-31T16:00:00Z',
        to: '2026-02-28T16:00:00Z',
        asOf: '2026-03-02T00:00:00Z',
        timeZone: 'Asia/Shanghai',
      }),
    ).toEqual(
      expect.objectContaining({
        amountCents: 1234,
        paymentCount: 1,
        unit: 'cents',
        complete: true,
      }),
    );
    await memberships.trash(actor, {
      operationId: randomUUID(),
      id: idOf(member),
    });
    expect(
      await memberships.statistics(actor, {
        from: '2026-01-31T16:00:00Z',
        to: '2026-02-28T16:00:00Z',
        timeZone: 'Asia/Shanghai',
      }),
    ).toEqual(expect.objectContaining({ amountCents: 0, paymentCount: 0 }));
  });

  it('完整统计不受笔记分页限制，字数保持受限Markdown与字素口径', async () => {
    // 使用真实表批量准备大于一页的数据，统计必须读取完整范围。
    const now = new Date();
    await prisma.noteEntry.createMany({
      data: Array.from({ length: 205 }, () => ({
        id: randomUUID(),
        userId: actor.sub,
        body: '**字**👨‍👩‍👧',
        dayKey: '2026-01-01',
        creationTimezone: 'UTC|+00:00',
        revision: randomUUID(),
        createdAt: now,
        updatedAt: now,
      })),
    });
    expect(await notes.list(actor, { limit: 1 })).toEqual(
      expect.objectContaining({ hasMore: true }),
    );
    expect(
      await notes.statistics(actor, {
        from: '2026-01-01T00:00:00Z',
        to: '2026-01-02T00:00:00Z',
        timeZone: 'UTC',
      }),
    ).toEqual(
      expect.objectContaining({
        count: 205,
        words: 410,
        days: 1,
        complete: true,
        sourcesTruncated: true,
      }),
    );
  });

  it('笔记标签相对基线合并并在十个边界拒绝溢出，失败不部分改变正文', async () => {
    // 当前有效标签均属本笔记模块。
    const tags = await Promise.all(
      Array.from({ length: 11 }, (_, index) =>
        prisma.taxonomyEntry.create({
          data: {
            id: randomUUID(),
            userId: actor.sub,
            module: 'notes',
            kind: 'tag',
            name: `标签${index}`,
            colorValue: null,
          },
        }),
      ),
    );
    // 初始十个标签合法。
    const created = await notes.create(actor, {
      operationId: randomUUID(),
      body: '十标签正文',
      timeZone: 'UTC',
      tags: tags.slice(0, 10).map((tag) => tag.id),
    });
    // 另一入口基于空标签集合新增第十一个，应保留既有十个并整体拒绝。
    await expect(
      notes.update(actor, {
        operationId: randomUUID(),
        id: idOf(created, 'note'),
        body: '不能部分提交',
        expectedRevision: revisionOf(created),
        tags: [tags[10]!.id],
        tagsBase: [],
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(await notes.get(actor, idOf(created, 'note'))).toEqual(
      expect.objectContaining({ body: '十标签正文' }),
    );
    expect(
      await prisma.noteVersion.count({
        where: { userId: actor.sub, noteId: idOf(created, 'note') },
      }),
    ).toBe(1);
  });

  it('步骤结构基线与状态分离，重命名保留完成状态，陈旧结构拒绝', async () => {
    // 两个实际步骤的任务。
    const progress = await todos.create(actor, {
      operationId: randomUUID(),
      title: '结构测试',
      taskType: 'progress',
      scheduledDate: '2026-01-01',
      steps: [{ name: '甲' }, { name: '乙' }],
    });
    // 当前结构基线只包含身份、顺序和名称。
    const initial = await prisma.todoProgressStep.findMany({
      where: { userId: actor.sub, todoId: idOf(progress) },
      orderBy: { sortOrder: 'asc' },
    });
    // 单个步骤先完成，不确认任务。
    const changeOperationId = randomUUID();
    await todos.setStepsCompleted(actor, {
      operationId: changeOperationId,
      todoId: idOf(progress),
      stepIds: [initial[0]!.id],
      completed: true,
    });
    await todos.replaceSteps(actor, {
      operationId: randomUUID(),
      todoId: idOf(progress),
      baseline: initial.map((step) => ({ id: step.id, name: step.name })),
      steps: [
        { id: initial[0]!.id, name: '改名' },
        { id: initial[1]!.id, name: '乙' },
      ],
    });
    expect(
      (
        await prisma.todoProgressStep.findUniqueOrThrow({
          where: { id: initial[0]!.id },
        })
      ).isCompleted,
    ).toBe(true);
    await expect(
      todos.replaceSteps(actor, {
        operationId: randomUUID(),
        todoId: idOf(progress),
        baseline: initial.map((step) => ({ id: step.id, name: step.name })),
        steps: [{ id: initial[0]!.id, name: '陈旧改名' }],
      }),
    ).rejects.toBeInstanceOf(ConflictException);
    expect(
      await todos.undoSteps(actor, {
        operationId: randomUUID(),
        changeOperationId,
      }),
    ).toEqual(expect.objectContaining({ undone: false }));
  });

  it('待办统计分开计划日和完成日，事件及名言范围查询保持只读完整结果', async () => {
    // 计划在窗口外而实际完成在窗口内，也属于完成统计。
    const task = await todos.create(actor, {
      operationId: randomUUID(),
      title: '跨日完成',
      scheduledDate: '2026-01-01',
    });
    await prisma.todoItem.update({
      where: { id: idOf(task) },
      data: {
        isCompleted: true,
        completedAt: new Date('2026-02-15T12:00:00Z'),
      },
    });
    expect(
      await todos.statistics(actor, {
        from: '2026-02-01T00:00:00Z',
        to: '2026-03-01T00:00:00Z',
        asOf: '2026-03-01T00:00:00Z',
        timeZone: 'UTC',
      }),
    ).toEqual(
      expect.objectContaining({
        plannedCount: 0,
        completedCount: 1,
        complete: true,
        includesUnmaterializedRecurring: false,
      }),
    );
    expect(
      await quotes.statistics(actor, {
        from: '2026-02-01T00:00:00Z',
        to: '2026-03-01T00:00:00Z',
        timeZone: 'UTC',
      }),
    ).toEqual(
      expect.objectContaining({
        dailyCount: 0,
        missingDaysGenerated: false,
        complete: true,
      }),
    );
    expect(
      await prisma.dailyQuoteSelection.count({ where: { userId: actor.sub } }),
    ).toBe(0);
    // 归档事件仍计入有效历史，但撤销不计入。
    const event = await events.create(actor, {
      operationId: randomUUID(),
      name: '归档统计',
      isArchived: true,
      initialCompletedAt: '2026-02-01T10:00:00Z',
    });
    expect(
      await events.statistics(actor, {
        from: '2026-02-01T00:00:00Z',
        to: '2026-03-01T00:00:00Z',
        asOf: '2026-03-01T00:00:00Z',
        timeZone: 'UTC',
      }),
    ).toEqual(
      expect.objectContaining({
        completionCount: 1,
        eventCount: 1,
        includesArchived: true,
      }),
    );
    expect(
      await events.list(actor, { isArchived: true, timeZone: 'UTC' }),
    ).toEqual(
      expect.objectContaining({
        items: expect.arrayContaining([
          expect.objectContaining({ id: idOf(event), isArchived: true }),
        ]),
      }),
    );
  });

  it('旧事件只有完成汇总时保留初始事实，撤销新完成能回到旧值', async () => {
    // 模拟旧版没有独立历史行的合法既有记录。
    const legacy = await prisma.event.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        name: '旧事件',
        lastCompletedAt: new Date('2026-01-01T00:00:00Z'),
      },
    });
    // 新记录在已有初始事实上推进。
    const completed = await events.complete(actor, {
      operationId: randomUUID(),
      eventId: legacy.id,
      completedAt: '2026-02-01T00:00:00Z',
    });
    await events.undoCompletion(actor, {
      operationId: randomUUID(),
      eventId: legacy.id,
      completionId: idOf(completed, 'completion'),
    });
    expect(await events.get(actor, legacy.id)).toEqual(
      expect.objectContaining({ lastCompletedAt: '2026-01-01T00:00:00.000Z' }),
    );
    expect(
      await prisma.eventCompletion.count({
        where: { userId: actor.sub, eventId: legacy.id, source: 'initial' },
      }),
    ).toBe(1);
  });

  it('日历重复从普通任务启用后，未来编辑只影响本系列并可正确停止', async () => {
    // 普通任务最初没有系列身份。
    const root = await todos.create(actor, {
      operationId: randomUUID(),
      title: '后启用重复',
      scheduledDate: '2026-01-31',
    });
    await todos.update(actor, {
      operationId: randomUUID(),
      id: idOf(root),
      repeatRule: 'monthly',
    });
    await todos.ensureRepeatedInstances(actor, {
      operationId: randomUUID(),
      day: '2026-02-28',
      timeZone: 'UTC',
    });
    await todos.update(actor, {
      operationId: randomUUID(),
      id: idOf(root),
      scope: 'future',
      title: '系列新标题',
    });
    expect(
      (await prisma.todoItem.findMany({ where: { userId: actor.sub } })).every(
        (row) => row.title === '系列新标题',
      ),
    ).toBe(true);
    await todos.trash(actor, {
      operationId: randomUUID(),
      id: idOf(root),
      scope: 'future',
    });
    await todos.ensureRepeatedInstances(actor, {
      operationId: randomUUID(),
      day: '2026-03-31',
      timeZone: 'UTC',
    });
    expect(
      await prisma.todoItem.count({
        where: { userId: actor.sub, deletedAt: null },
      }),
    ).toBe(0);
  });

  it('已删标签残留不阻塞有效标签编辑，仍拒绝请求绑定失效标签', async () => {
    // 两个标签曾经有效，其中一个稍后被其他入口删除。
    const first = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'notes',
        kind: 'tag',
        name: '待删除',
        colorValue: null,
      },
    });
    // 当前仍可用的标签。
    const second = await prisma.taxonomyEntry.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        module: 'notes',
        kind: 'tag',
        name: '有效',
        colorValue: null,
      },
    });
    // 同步语义允许旧正文暂留已删标签身份。
    const created = await notes.create(actor, {
      operationId: randomUUID(),
      body: '标签清理',
      timeZone: 'UTC',
      tags: [first.id],
    });
    await prisma.taxonomyEntry.update({
      where: { id: first.id },
      data: { deletedAt: new Date() },
    });
    await notes.update(actor, {
      operationId: randomUUID(),
      id: idOf(created, 'note'),
      tags: [second.id],
      tagsBase: [],
    });
    expect(await notes.get(actor, idOf(created, 'note'))).toEqual(
      expect.objectContaining({ tags: JSON.stringify([second.id]) }),
    );
    await expect(
      notes.update(actor, {
        operationId: randomUUID(),
        id: idOf(created, 'note'),
        tags: [first.id],
        tagsBase: [],
      }),
    ).rejects.toBeInstanceOf(ConflictException);
  });
  it('进度步骤可成功条件撤销，空结构可修复且超限合并只能保持或减少', async () => {
    // 同步可能删掉最后一步，正式任务仍应可以被修复。
    const progress = await todos.create(actor, {
      operationId: randomUUID(),
      title: '合并后结构',
      taskType: 'progress',
      scheduledDate: '2026-01-01',
      steps: [{ name: '初始一步' }],
    });
    await prisma.todoProgressStep.deleteMany({
      where: { userId: actor.sub, todoId: idOf(progress) },
    });
    await todos.replaceSteps(actor, {
      operationId: randomUUID(),
      todoId: idOf(progress),
      baseline: [],
      steps: [{ name: '修复一步' }],
    });
    // 步骤撤销使用可信的原操作回执。
    const repaired = await prisma.todoProgressStep.findFirstOrThrow({
      where: { userId: actor.sub, todoId: idOf(progress), deletedAt: null },
    });
    // 同一次操作在不同撤销请求间仍能检测后续变化。
    const changeOperationId = randomUUID();
    await todos.setStepsCompleted(actor, {
      operationId: changeOperationId,
      todoId: idOf(progress),
      stepIds: [repaired.id],
      completed: true,
    });
    expect(
      await todos.undoSteps(actor, {
        operationId: randomUUID(),
        changeOperationId,
      }),
    ).toEqual({ undone: true, todoId: idOf(progress) });
    expect(
      (
        await prisma.todoProgressStep.findUniqueOrThrow({
          where: { id: repaired.id },
        })
      ).isCompleted,
    ).toBe(false);
    // 模拟多端并发新增后超过上限的合法既有结构。
    await prisma.todoProgressStep.createMany({
      data: Array.from({ length: 1000 }, (_, index) => ({
        id: randomUUID(),
        userId: actor.sub,
        todoId: idOf(progress),
        name: `合并步骤${index}`,
        sortOrder: (index + 2) * 1024,
      })),
    });
    // 结构基线与服务读取顺序一致。
    const merged = await prisma.todoProgressStep.findMany({
      where: { userId: actor.sub, todoId: idOf(progress), deletedAt: null },
      orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }, { id: 'asc' }],
    });
    // 既有超限集合允许保留，不能通过覆盖接口偷偷新增。
    const baseline = merged.map((step) => ({ id: step.id, name: step.name }));
    await todos.replaceSteps(actor, {
      operationId: randomUUID(),
      todoId: idOf(progress),
      baseline,
      steps: baseline,
    });
    await expect(
      todos.replaceSteps(actor, {
        operationId: randomUUID(),
        todoId: idOf(progress),
        baseline,
        steps: [...baseline, { name: '不能再加' }],
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    await todos.replaceSteps(actor, {
      operationId: randomUUID(),
      todoId: idOf(progress),
      baseline,
      steps: baseline.slice(0, 1000),
    });
    expect(
      await prisma.todoProgressStep.count({
        where: { userId: actor.sub, todoId: idOf(progress), deletedAt: null },
      }),
    ).toBe(1000);
  });

  it('后台真实生成路径同时保护新根与子项，旧设备模板不能覆盖新实例', async () => {
    // 旧设备曾读取的重复模板，随后服务器修改其内容。
    const source = await todos.create(actor, {
      operationId: randomUUID(),
      title: '旧模板',
      scheduledDate: '2026-10-21',
      repeatRule: 'daily',
    });
    // 子项同样随父系列生成稳定身份。
    const sourceChild = await todos.create(actor, {
      operationId: randomUUID(),
      title: '旧子模板',
      parentId: idOf(source),
      scheduledDate: '2026-10-21',
    });
    await todos.update(actor, {
      operationId: randomUUID(),
      id: idOf(source),
      title: '最新模板',
    });
    await todos.update(actor, {
      operationId: randomUUID(),
      id: idOf(sourceChild),
      title: '最新子模板',
    });
    await todos.ensureRepeatedInstances(actor, {
      operationId: randomUUID(),
      day: '2026-10-22',
      timeZone: 'UTC',
    });
    // 只检查本轮真实生成的记录，不手工调用保护助手。
    const generated = await prisma.todoItem.findMany({
      where: {
        userId: actor.sub,
        scheduledDate: new Date('2026-10-22T00:00:00Z'),
      },
    });
    expect(generated).toHaveLength(2);
    expect(
      new Set(
        (
          await prisma.todoRecurrenceProtection.findMany({
            where: { userId: actor.sub },
          })
        ).map((row) => row.todoId),
      ),
    ).toEqual(new Set(generated.map((row) => row.id)));
    for (const row of generated) {
      // 两种稳定身份都可能被旧离线设备独立生成并编辑。
      const result = await sync.applyBatch(actor.sub, {
        clientId: randomUUID(),
        transactionId: randomUUID(),
        operations: [
          {
            op: 'PATCH',
            table: 'todo_items',
            id: row.id,
            data: { title: '覆盖新版' },
            previous: { title: row.parentId ? '旧子模板' : '旧模板' },
          },
        ],
      });
      expect(result.conflict?.id).toBeDefined();
      expect(
        (await prisma.todoItem.findUniqueOrThrow({ where: { id: row.id } }))
          .title,
      ).toBe(row.parentId ? '最新子模板' : '最新模板');
    }
  });

  /// 模拟后台在同一事务建立根、子实例与保护，避免测试借用 MCP 回执。
  async function createProtectedRecurringPair(
    protectParent = true,
  ): Promise<{ parentId: string; childId: string }> {
    return prisma.$transaction(async (transaction) => {
      // 所有后台创建与同步一样持有归属锁。
      await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id=${actor.sub}::uuid FOR UPDATE`;
      // 两个真实业务身份都由服务器生成。
      const parentId = randomUUID(),
        childId = randomUUID();
      await transaction.todoItem.create({
        data: {
          id: parentId,
          userId: actor.sub,
          title: '服务器新模板',
          scheduledDate: new Date('2026-10-22T00:00:00Z'),
        },
      });
      await transaction.todoItem.create({
        data: {
          id: childId,
          userId: actor.sub,
          parentId,
          title: '服务器新子项',
          scheduledDate: new Date('2026-10-22T00:00:00Z'),
        },
      });
      await protectRecurringTodo(
        transaction,
        actor.sub,
        protectParent ? [parentId, childId] : [childId],
      );
      return { parentId, childId };
    });
  }

  it.each(['parentId', 'childId'] as const)(
    '后台实例%s的旧离线PATCH整个事务转候选且重复上传不覆盖',
    async (target) => {
      // 数据与私有保护一同提交，不需要存在任何 MCP 动作回执。
      const pair = await createProtectedRecurringPair();
      // 同一事务前置写入也必须随着冲突回滚。
      const quoteId = randomUUID();
      // 旧设备实际编辑时的模板标题不能作为当前服务器事实。
      const batch = {
        clientId: randomUUID(),
        transactionId: randomUUID(),
        operations: [
          {
            op: 'PUT' as const,
            table: 'quotes',
            id: quoteId,
            data: {
              content: '不应部分保存',
              created_at: new Date().toISOString(),
              updated_at: new Date().toISOString(),
            },
          },
          {
            op: 'PATCH' as const,
            table: 'todo_items',
            id: pair[target],
            data: { title: '旧离线编辑' },
            previous: { title: '旧模板' },
          },
        ],
      };
      // 真实同步入口保留完整冲突事务而不是静默忽略。
      const result = await sync.applyBatch(actor.sub, batch);
      expect(result.applied).toBe(0);
      expect(result.conflict?.id).toBeDefined();
      expect(
        await prisma.quote.findUnique({ where: { id: quoteId } }),
      ).toBeNull();
      expect(
        (
          await prisma.todoItem.findUniqueOrThrow({
            where: { id: pair[target] },
          })
        ).title,
      ).toBe(target === 'parentId' ? '服务器新模板' : '服务器新子项');
      expect(
        (await new SyncService(prisma).applyBatch(actor.sub, batch)).conflict
          ?.id,
      ).toBe(result.conflict?.id);
      expect(
        await prisma.mcpAction.count({ where: { userId: actor.sub } }),
      ).toBe(0);
    },
  );

  it('后台保护允许正确前值、同值重放与独立字段，仍拒绝旧DELETE', async () => {
    // 根项与子项具有独立的前值保护。
    const { childId } = await createProtectedRecurringPair();
    expect(
      await sync.applyBatch(actor.sub, {
        clientId: randomUUID(),
        transactionId: randomUUID(),
        operations: [
          {
            op: 'PATCH',
            table: 'todo_items',
            id: childId,
            data: { title: '正确基线修改' },
            previous: { title: '服务器新子项' },
          },
        ],
      }),
    ).toEqual(expect.objectContaining({ applied: 1 }));
    expect(
      await sync.applyBatch(actor.sub, {
        clientId: randomUUID(),
        transactionId: randomUUID(),
        operations: [
          {
            op: 'PATCH',
            table: 'todo_items',
            id: childId,
            data: { title: '正确基线修改', description: '独立备注' },
            previous: { title: '旧模板', description: null },
          },
        ],
      }),
    ).toEqual(expect.objectContaining({ applied: 1 }));
    // 删除需要完整当前前值，旧删除不能绕过刚刚修改的字段。
    const deletion = await sync.applyBatch(actor.sub, {
      clientId: randomUUID(),
      transactionId: randomUUID(),
      operations: [
        {
          op: 'DELETE',
          table: 'todo_items',
          id: childId,
          previous: { title: '旧模板' },
        },
      ],
    });
    expect(deletion.applied).toBe(0);
    expect(deletion.conflict?.id).toBeDefined();
    expect(
      await prisma.todoItem.findUnique({ where: { id: childId } }),
    ).not.toBeNull();
    expect(
      await prisma.syncTombstone.findUnique({
        where: {
          userId_tableName_recordId: {
            userId: actor.sub,
            tableName: 'todo_items',
            recordId: childId,
          },
        },
      }),
    ).toBeNull();
  });

  it('后台新子项使未保护父项的旧DELETE也需要核对当前关联闭包', async () => {
    // 故意只保护子项，证明不是父项自身保护偶然挡住删除。
    const { parentId, childId } = await createProtectedRecurringPair(false);
    // 原始删除没有包含后台新增孩子。
    const result = await sync.applyBatch(actor.sub, {
      clientId: randomUUID(),
      transactionId: randomUUID(),
      operations: [{ op: 'DELETE', table: 'todo_items', id: parentId }],
    });
    expect(result.conflict?.id).toBeDefined();
    // 人工处理预览展示遗漏的当前子项事实。
    const preview = await sync.getWriteConflict(actor.sub, result.conflict!.id);
    expect(JSON.stringify(preview)).toContain(childId);
    expect(
      await prisma.todoItem.count({
        where: { id: { in: [parentId, childId] } },
      }),
    ).toBe(2);
    // 固定冲突原因来自关联闭包，而非缺失父项标量前值。
    const receipt = await prisma.syncReceipt.findFirstOrThrow({
      where: { userId: actor.sub },
    });
    expect(receipt.conflict).toEqual(
      expect.objectContaining({
        reason: expect.objectContaining({ fields: ['关联记录'] }),
      }),
    );
  });

  it('后台实例创建失败同时回滚保护，重复登记幂等且不登记异主身份', async () => {
    // 事务异常不能留下业务行或对应保护身份。
    const rolledBackId = randomUUID();
    await expect(
      prisma.$transaction(async (transaction) => {
        await transaction.todoItem.create({
          data: {
            id: rolledBackId,
            userId: actor.sub,
            title: '回滚',
            scheduledDate: new Date('2026-10-22T00:00:00Z'),
          },
        });
        await protectRecurringTodo(transaction, actor.sub, [rolledBackId]);
        throw new Error('测试回滚');
      }),
    ).rejects.toThrow('测试回滚');
    expect(
      await prisma.todoItem.findUnique({ where: { id: rolledBackId } }),
    ).toBeNull();
    expect(
      await prisma.todoRecurrenceProtection.count({
        where: { userId: actor.sub },
      }),
    ).toBe(0);
    // 正常登记不得因再次扫描刷新时间或出现重复行。
    const { parentId, childId } = await createProtectedRecurringPair();
    // 另一归属的真实记录不能被错误调用登记到当前归属。
    const foreign = await todos.create(other, {
      operationId: randomUUID(),
      title: '另一归属',
      scheduledDate: '2026-10-22',
    });
    // 首次保护时间是可审计的稳定事实。
    const before = await prisma.todoRecurrenceProtection.findMany({
      where: { userId: actor.sub },
      orderBy: { todoId: 'asc' },
    });
    await prisma.$transaction(async (transaction) => {
      await protectRecurringTodo(transaction, actor.sub, [
        parentId,
        childId,
        childId,
        idOf(foreign),
        randomUUID(),
      ]);
      await protectRecurringTodo(transaction, actor.sub, []);
    });
    expect(
      await prisma.todoRecurrenceProtection.findMany({
        where: { userId: actor.sub },
        orderBy: { todoId: 'asc' },
      }),
    ).toEqual(before);
    expect(
      await prisma.todoRecurrenceProtection.count({
        where: { userId: other.sub },
      }),
    ).toBe(0);
  });

  it('后台保护在撤权和实例删除后保留，归属重建才清除且不进入同步发布', async () => {
    // 持久保护不能依赖授权仍在，也不能依赖实例行仍在。
    const { parentId, childId } = await createProtectedRecurringPair();
    // 连接只用于验证撤销不会级联删除保护。
    const connection = await prisma.mcpConnection.create({
      data: {
        id: randomUUID(),
        userId: actor.sub,
        sessionId: actor.sid,
        name: '调度授权',
        tokenHash: 'a'.repeat(64),
        readModules: ['todos'],
        writeModules: ['todos'],
        timeZone: 'UTC',
        expiresAt: null,
      },
    });
    await prisma.mcpConnection.update({
      where: { id: connection.id },
      data: { revokedAt: new Date() },
    });
    // 撤权之后迟到的离线修改仍受先前生成事实保护。
    expect(
      (
        await sync.applyBatch(actor.sub, {
          clientId: randomUUID(),
          transactionId: randomUUID(),
          operations: [
            {
              op: 'PATCH',
              table: 'todo_items',
              id: childId,
              data: { title: '迟到覆盖' },
              previous: { title: '旧模板' },
            },
          ],
        })
      ).conflict,
    ).toBeDefined();
    await prisma.todoItem.deleteMany({
      where: { id: { in: [parentId, childId] } },
    });
    expect(
      await prisma.todoRecurrenceProtection.count({
        where: { userId: actor.sub },
      }),
    ).toBe(2);
    // 该表只存在服务端，客户端版本与同步白名单不增加任何字段。
    const published = await database.query<{ tablename: string }>(
      "SELECT tablename FROM pg_publication_tables WHERE pubname='powersync'",
    );
    expect(published.rows.map((row) => row.tablename)).not.toContain(
      'todo_recurrence_protections',
    );
    await prisma.syncOwner.delete({ where: { id: actor.sub } });
    expect(
      await prisma.todoRecurrenceProtection.count({
        where: { userId: actor.sub },
      }),
    ).toBe(0);
  });

  it('首购删除不扣减期限，自动账目撤销回退期限并关闭自动续费提醒', async () => {
    // 首购与会员在同一创建动作内保存。
    const member = await memberships.create(actor, {
      operationId: randomUUID(),
      name: '首购与自动账期',
      purchaseDate: '2026-01-01',
      expirationDate: '2026-01-31',
      priceCents: 100,
      billingCycle: 'month',
      autoRenew: true,
      renewalReminderEnabled: true,
      renewalDate: '2026-01-31',
      timeZone: 'UTC',
    });
    // 最早首购包含用户原购买自然日。
    const initial = await prisma.membershipPayment.findFirstOrThrow({
      where: { userId: actor.sub, membershipId: idOf(member) },
    });
    expect(
      await memberships.deletePayment(actor, {
        operationId: randomUUID(),
        membershipId: idOf(member),
        paymentId: initial.id,
        timeZone: 'UTC',
      }),
    ).toEqual(
      expect.objectContaining({ initialPurchase: true, deductedDays: 0 }),
    );
    expect(
      (
        await prisma.membership.findUniqueOrThrow({
          where: { id: idOf(member) },
        })
      ).expirationDate?.toISOString(),
    ).toBe('2026-01-31T00:00:00.000Z');
    // 原客户端自动补账使用固定业务身份，服务端撤销必须正确识别。
    const automaticId = stableBusinessId('auto-renewal', [
      idOf(member),
      '2026-01-31',
    ]);
    await prisma.membershipPayment.create({
      data: {
        id: automaticId,
        userId: actor.sub,
        membershipId: idOf(member),
        amountCents: 100,
        paidAt: new Date('2026-01-31T00:00:00Z'),
        validFrom: new Date('2026-01-31T00:00:00Z'),
        validUntil: new Date('2026-02-28T00:00:00Z'),
      },
    });
    await prisma.membership.update({
      where: { id: idOf(member) },
      data: {
        expirationDate: new Date('2026-02-28T00:00:00Z'),
        renewalDate: new Date('2026-02-28T00:00:00Z'),
      },
    });
    expect(
      await memberships.deletePayment(actor, {
        operationId: randomUUID(),
        membershipId: idOf(member),
        paymentId: automaticId,
        timeZone: 'UTC',
      }),
    ).toEqual(
      expect.objectContaining({ autoRenewDisabled: true, deductedDays: 28 }),
    );
    expect(await memberships.get(actor, idOf(member))).toEqual(
      expect.objectContaining({
        autoRenew: false,
        renewalReminderEnabled: false,
        renewalDate: null,
        expirationDate: '2026-01-31T00:00:00.000Z',
      }),
    );
  });
});
