import { BadRequestException } from '@nestjs/common';
import type { Prisma } from '../src/generated/prisma/client';
import type { SyncOperationDto } from '../src/sync/dto/sync-operation.dto';
import {
  normalizeAutomaticRenewalPatch,
  reconcileSync,
} from '../src/sync/sync-consistency';

/// 验证自动账期身份识别和派生一致性协调入口。
describe('sync consistency', () => {
  // 固定所有者与会员/事件身份。
  const userId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const recordId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  // 由 Python uuid.uuid5 独立计算的跨语言账期标识。
  const automaticId = '617b4652-4d78-5490-8f48-16489204104b';
  // 最小 Prisma 事务替身。
  const query = jest.fn();
  const execute = jest.fn();
  const findMembership = jest.fn();
  const transaction = {
    $queryRaw: query,
    $executeRaw: execute,
    membership: { findFirst: findMembership },
  } as unknown as Prisma.TransactionClient;

  beforeEach(() => {
    jest.clearAllMocks();
    query.mockResolvedValue([]);
    execute.mockResolvedValue(0);
    findMembership.mockResolvedValue({
      expirationDate: new Date('2026-05-01T00:00:00Z'),
      renewalDate: new Date('2026-05-01T00:00:00Z'),
    });
  });

  // 构造自动续费付款，特意使用带时区的本地午夜验证日期身份。
  const payment: SyncOperationDto = {
    op: 'PUT',
    table: 'membership_payments',
    id: automaticId,
    data: {
      membership_id: recordId,
      valid_from: '2026-02-01T00:00:00.000+08:00',
    },
  };

  it('跨端自动续费较旧日期不能回退服务器且原始幂等负载不变', async () => {
    // 设备仍基于二月份快照推进一次的建议值。
    const operation: SyncOperationDto = {
      op: 'PATCH',
      table: 'memberships',
      id: recordId,
      data: { expiration_date: '2026-03-01', renewal_date: null, name: '会员' },
    };
    // 归一化后的独立操作。
    const normalized = await normalizeAutomaticRenewalPatch(
      transaction,
      userId,
      operation,
      [payment, operation],
    );
    expect(normalized.data).toEqual({
      expiration_date: '2026-05-01',
      renewal_date: '2026-05-01',
      name: '会员',
    });
    expect(operation.data?.expiration_date).toBe('2026-03-01');
    expect(operation.data?.renewal_date).toBeNull();
  });

  it('自动续费允许继续推进到更晚日期', async () => {
    // 新账期建议值大于服务器当前日期。
    const operation: SyncOperationDto = {
      op: 'PATCH',
      table: 'memberships',
      id: recordId,
      data: { expiration_date: '2026-06-01', renewal_date: '2026-06-01' },
    };
    expect(
      (
        await normalizeAutomaticRenewalPatch(transaction, userId, operation, [
          payment,
          operation,
        ])
      ).data,
    ).toEqual(operation.data);
  });

  it('备注伪装成自动续费的普通支付不会改变人工日期编辑语义', async () => {
    // 普通随机身份即使备注包含自动续费也不能被识别为自动账单。
    const manual: SyncOperationDto = {
      ...payment,
      id: recordId,
      data: { ...payment.data, notes: '自动续费' },
    };
    // 人工将到期日提前属于明确编辑意图。
    const operation: SyncOperationDto = {
      op: 'PATCH',
      table: 'memberships',
      id: recordId,
      data: { expiration_date: '2026-03-01' },
    };
    expect(
      await normalizeAutomaticRenewalPatch(transaction, userId, operation, [
        manual,
        operation,
      ]),
    ).toBe(operation);
    expect(findMembership).not.toHaveBeenCalled();
  });

  it('只修改其他模块时不扫描事件和待办表', async () => {
    await reconcileSync(transaction, userId, [
      {
        op: 'PATCH',
        table: 'quotes',
        id: recordId,
        data: { content: '更新' },
      },
    ]);
    expect(query).not.toHaveBeenCalled();
    expect(execute).not.toHaveBeenCalled();
  });

  it('无效待办层级在删除传播和完成状态修改前以400拒绝', async () => {
    query.mockResolvedValue([{ id: recordId }]);
    await expect(
      reconcileSync(transaction, userId, [
        {
          op: 'PATCH',
          table: 'todo_items',
          id: recordId,
          data: { parent_id: recordId },
        },
      ]),
    ).rejects.toThrow(BadRequestException);
    expect(execute).not.toHaveBeenCalled();
  });

  it('旧事件初始化补历史使用与客户端一致的UUIDv5', async () => {
    await reconcileSync(transaction, userId, [
      {
        op: 'PUT',
        table: 'events',
        id: recordId,
        data: { last_completed_at: '2026-02-01T00:00:00Z' },
      },
    ]);
    expect(execute.mock.calls[0]).toContain(
      'fc443801-06ae-5e50-b799-f86e0bfd841d',
    );
    // 插入初始历史后还必须重算汇总。
    expect(execute).toHaveBeenCalledTimes(2);
  });
});
