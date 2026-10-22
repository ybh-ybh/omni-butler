import { BadRequestException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../src/auth/auth.types';
import {
  absoluteRangeInput,
  calendarRangeInput,
  rangeInput,
} from '../src/business/business-input';
import { InventoryService } from '../src/business/inventory.service';
import { MembershipsService } from '../src/business/memberships.service';
import { NotesBusinessService } from '../src/business/notes-business.service';
import { QuotesService } from '../src/business/quotes.service';
import { TimeEntriesService } from '../src/business/time-entries.service';
import type { Prisma } from '../src/generated/prisma/client';
import type { PrismaService } from '../src/prisma/prisma.service';

/// 只替代数据库驱动，保留真实业务校验、授权、分页和结果转换。
class QueryDatabase {
  // 测试归属与会话均使用真实格式的独立身份。
  readonly actor: AuthUser = {
    sub: randomUUID(),
    sid: randomUUID(),
    typ: 'access',
  };

  // 驱动返回值由各用例指定，不连接任何数据库或应用环境。
  readonly transaction = {
    $queryRaw: jest.fn().mockResolvedValue([{ id: this.actor.sub }]),
    deviceSession: { findFirst: jest.fn().mockResolvedValue({}) },
    timeEntry: { findMany: jest.fn().mockResolvedValue([]) },
    quote: { count: jest.fn().mockResolvedValue(0) },
    dailyQuoteSelection: { findMany: jest.fn().mockResolvedValue([]) },
    noteEntry: { findMany: jest.fn().mockResolvedValue([]) },
    inventoryItem: { findMany: jest.fn().mockResolvedValue([]) },
    membership: {
      findFirst: jest.fn(),
      update: jest.fn().mockResolvedValue({}),
      findUniqueOrThrow: jest.fn(),
    },
    membershipPayment: { create: jest.fn() },
    recordTaxonomyLink: {
      findMany: jest.fn().mockResolvedValue([]),
      updateMany: jest.fn().mockResolvedValue({ count: 0 }),
    },
    businessOperationReceipt: {
      findUnique: jest.fn().mockResolvedValue(null),
      create: jest.fn().mockResolvedValue({}),
    },
  };

  /// 在测试驱动中运行真实的只读或写入事务回调。
  $transaction<T>(
    callback: (transaction: Prisma.TransactionClient) => Promise<T>,
  ): Promise<T> {
    return callback(this.transaction as unknown as Prisma.TransactionClient);
  }

  /// 类型适配仅位于驱动边界，不替换业务服务。
  get prisma(): PrismaService {
    return this as unknown as PrismaService;
  }
}

describe('MCP v3 领域查询参数', () => {
  // 窗口包含偏移，绝对比较无需另传时区。
  const window = {
    from: '2026-10-22T00:00:00+08:00',
    to: '2026-10-23T00:00:00+08:00',
  };

  it('绝对窗口不需要时区；日历窗口不包含历史快照截止点', () => {
    expect(absoluteRangeInput(window)).toEqual({
      from: new Date('2026-10-21T16:00:00Z'),
      to: new Date('2026-10-22T16:00:00Z'),
    });
    expect(
      calendarRangeInput({ ...window, timeZone: 'Asia/Shanghai' }),
    ).not.toHaveProperty('asOf');
    expect(() => calendarRangeInput(window)).toThrow(BadRequestException);
    expect(
      rangeInput({
        ...window,
        timeZone: 'Asia/Shanghai',
        asOf: '2026-10-22T08:00:00Z',
      }).asOf,
    ).toEqual(new Date('2026-10-22T08:00:00Z'));
  });

  it.each([
    { from: window.from },
    { to: window.to },
    { from: window.to, to: window.from },
    { from: window.from, to: window.from },
    { from: '2000-01-01T00:00:00Z', to: window.to },
  ])('时间列表拒绝缺失、倒置和过长窗口 %j', (input) => {
    // 这些错误必须发生在任何数据库读取之前。
    const database = new QueryDatabase();
    expect(() =>
      new TimeEntriesService(database.prisma).list(database.actor, input),
    ).toThrow(BadRequestException);
    expect(database.transaction.timeEntry.findMany).not.toHaveBeenCalled();
  });

  it('无窗口的进行中查询覆盖早期记录，仍保留 owner 隔离和分页', async () => {
    // 模拟足以跨页的旧记录，不让默认日期范围将它们排除。
    const database = new QueryDatabase();
    database.transaction.timeEntry.findMany.mockResolvedValue([
      { id: 'old', startedAt: '2000-01-01T00:00:00Z', endedAt: null },
      { id: 'next', startedAt: '2001-01-01T00:00:00Z', endedAt: null },
    ]);
    expect(
      await new TimeEntriesService(database.prisma).list(database.actor, {
        status: 'ongoing',
        limit: 1,
        offset: 5,
      }),
    ).toEqual({
      items: [{ id: 'old', startedAt: '2000-01-01T00:00:00Z', endedAt: null }],
      hasMore: true,
      nextOffset: 6,
    });
    expect(database.transaction.timeEntry.findMany).toHaveBeenCalledWith({
      where: { userId: database.actor.sub, deletedAt: null, endedAt: null },
      orderBy: [{ startedAt: 'asc' }, { id: 'asc' }],
      skip: 5,
      take: 2,
    });
  });

  it('已结束列表将状态与相交窗口同时应用', async () => {
    // 核验查询条件同时保留状态、窗口和归属约束。
    const database = new QueryDatabase();
    await new TimeEntriesService(database.prisma).list(database.actor, {
      ...window,
      status: 'finished',
    });
    expect(database.transaction.timeEntry.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: {
          userId: database.actor.sub,
          deletedAt: null,
          endedAt: { not: null },
          startedAt: { lt: new Date(window.to) },
          OR: [{ endedAt: null }, { endedAt: { gt: new Date(window.from) } }],
        },
      }),
    );
  });

  it('缺省状态查询全部且有界；无效状态及已退役参数明确拒绝', async () => {
    // 测试默认查询与非法输入，不允许旧字段被静默忽略。
    const database = new QueryDatabase();
    // 真实时间服务使用测试驱动。
    const service = new TimeEntriesService(database.prisma);
    await service.list(database.actor, {});
    expect(database.transaction.timeEntry.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { userId: database.actor.sub, deletedAt: null },
        take: 51,
      }),
    );
    expect(() => service.list(database.actor, { status: 'invalid' })).toThrow(
      BadRequestException,
    );
    expect(() =>
      service.list(database.actor, { ...window, timeZone: 'UTC' }),
    ).toThrow(BadRequestException);
    expect(() =>
      service.list(database.actor, { ...window, asOf: window.to }),
    ).toThrow(BadRequestException);
  });

  it('笔记、日签和物品按自然日统计，结果不再虚构 asOf 快照', async () => {
    // 当地日界恰好在偏移窗口的首尾，首日包含而次日排除。
    const database = new QueryDatabase();
    database.transaction.noteEntry.findMany.mockResolvedValue([
      { id: 'today', dayKey: '2026-10-22', body: '学习' },
      { id: 'tomorrow', dayKey: '2026-10-23', body: '会议' },
    ]);
    database.transaction.dailyQuoteSelection.findMany.mockResolvedValue([
      {
        dayKey: '2026-10-22',
        quoteId: 'quote',
        quote: {
          deletedAt: null,
          isEnabled: true,
          content: '今天',
          source: null,
        },
      },
      {
        dayKey: '2026-10-23',
        quoteId: 'quote',
        quote: {
          deletedAt: null,
          isEnabled: true,
          content: '明天',
          source: null,
        },
      },
    ]);
    database.transaction.inventoryItem.findMany.mockResolvedValue([
      {
        id: 'today',
        quantity: 2,
        purchasePriceCents: 1500,
        purchaseDate: new Date('2026-10-22T00:00:00Z'),
        status: 'active',
        category: '学习',
        location: null,
      },
      {
        id: 'tomorrow',
        quantity: 3,
        purchasePriceCents: 2500,
        purchaseDate: new Date('2026-10-23T00:00:00Z'),
        status: 'active',
        category: null,
        location: null,
      },
    ]);
    // 三个统计均只需要真实参与计算的自然日窗口。
    const input = { ...window, timeZone: 'Asia/Shanghai' };
    // 三个领域结果分别核验，避免只检查共有外形。
    const note = await new NotesBusinessService(database.prisma).statistics(
      database.actor,
      input,
    );
    // 日签库总数仍为当前库事实，窗口只用于选择日签。
    const quote = await new QuotesService(database.prisma).statistics(
      database.actor,
      input,
    );
    // 购买时间窗口不等同于历史库存快照。
    const inventory = await new InventoryService(database.prisma).statistics(
      database.actor,
      { ...input, includeAccessories: true },
    );
    expect(note).toEqual(
      expect.objectContaining({ count: 1, days: 1, words: 2 }),
    );
    expect(quote).toEqual(expect.objectContaining({ dailyCount: 1 }));
    expect(inventory).toEqual(
      expect.objectContaining({
        count: 1,
        quantity: 2,
        purchasePriceCents: 1500,
        basis: 'purchaseDate',
        includeAccessories: true,
      }),
    );
    expect(note).not.toHaveProperty('asOf');
    expect(quote).not.toHaveProperty('asOf');
    expect(inventory).not.toHaveProperty('asOf');
  });

  it('全量库存不要求地区和窗口；三个统计拒绝已退役的 asOf', async () => {
    // 全量库存保持可查询，避免合并统计工具后损失原有能力。
    const database = new QueryDatabase();
    expect(
      await new InventoryService(database.prisma).statistics(database.actor),
    ).toEqual(expect.objectContaining({ basis: 'currentRecords', count: 0 }));
    // 历史截止点不能因无效回显而造成能力误解。
    const input = { ...window, timeZone: 'UTC', asOf: window.to };
    expect(() =>
      new QuotesService(database.prisma).statistics(database.actor, input),
    ).toThrow(BadRequestException);
    expect(() =>
      new NotesBusinessService(database.prisma).statistics(
        database.actor,
        input,
      ),
    ).toThrow(BadRequestException);
    expect(() =>
      new InventoryService(database.prisma).statistics(database.actor, input),
    ).toThrow(BadRequestException);
  });

  it('会员基础修改不需要时区，也不额外产生首购账目', async () => {
    // 有效周期会员只修改名称，保持原到期日和续费属性。
    const database = new QueryDatabase();
    // 当前会员在真实业务锁内从驱动读取。
    const member = {
      id: randomUUID(),
      deletedAt: null,
      isPermanent: false,
      expirationDate: new Date('2027-01-01T00:00:00Z'),
      billingCycle: 'month',
      autoRenew: true,
    };
    database.transaction.membership.findFirst.mockResolvedValue(member);
    database.transaction.membership.findUniqueOrThrow.mockResolvedValue({
      ...member,
      name: '修改后的会员',
    });
    expect(
      await new MembershipsService(database.prisma).update(database.actor, {
        id: member.id,
        operationId: randomUUID(),
        name: '修改后的会员',
      }),
    ).toEqual(expect.objectContaining({ name: '修改后的会员' }));
    expect(database.transaction.membership.update).toHaveBeenCalledWith({
      where: { id: member.id },
      data: { name: '修改后的会员' },
    });
    expect(
      database.transaction.membershipPayment.create,
    ).not.toHaveBeenCalled();
    expect(
      database.transaction.businessOperationReceipt.create,
    ).toHaveBeenCalledTimes(1);
    expect(() =>
      new MembershipsService(database.prisma).create(database.actor, {
        operationId: randomUUID(),
        name: '首购',
        purchaseDate: '2026-10-22',
      }),
    ).toThrow(BadRequestException);
    expect(() =>
      new MembershipsService(database.prisma).update(database.actor, {
        id: member.id,
        operationId: randomUUID(),
        timeZone: 'UTC',
        name: '旧参数',
      }),
    ).toThrow(BadRequestException);
  });
});
