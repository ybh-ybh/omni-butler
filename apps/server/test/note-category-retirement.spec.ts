import { BadRequestException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import type { PrismaService } from '../src/prisma/prisma.service';
import type { SyncOperationDto } from '../src/sync/dto/sync-operation.dto';
import { retireNoteCategoryOperation } from '../src/sync/note-category-retirement';
import { canonicalize, SyncService } from '../src/sync/sync.service';
import { SyncSqlBuilder } from '../src/sync/sync-sql.builder';

/// 退休兼容只处理旧队列，当前结构与原始幂等负载必须保持明确边界。
describe('笔记类别退休兼容', () => {
  it('仅剔除执行副本中的旧类别字段并保留正文、标签基线和原始请求', () => {
    // 冻结真实旧操作，任何原地改动都会让测试失败。
    const operation: SyncOperationDto = Object.freeze({ op: 'PATCH', table: 'note_entries', id: 'note', data: Object.freeze({ category_id: 'category', category_name: '日报', body: '保留正文', tags: '[]', tags_base: '[]' }) });
    expect(retireNoteCategoryOperation(operation)).toEqual({ ...operation, data: { body: '保留正文', tags: '[]', tags_base: '[]' } });
    expect(operation.data).toHaveProperty('category_name', '日报');
    expect(retireNoteCategoryOperation({ ...operation, data: { category_id: null } })).toBeNull();
    expect(retireNoteCategoryOperation({ ...operation, data: {} })).not.toBeNull();
  });

  it('旧笔记类别创建改为删除，标签及其他模块类别不改写且未知列仍拒绝', () => {
    // 同一输入骨架只变更业务模块和种类。
    const operation: SyncOperationDto = { op: 'PUT', table: 'taxonomy_entries', id: 'category', data: { module: 'notes', kind: 'category', name: '日报' } };
    expect(retireNoteCategoryOperation(operation)).toEqual({ op: 'DELETE', table: 'taxonomy_entries', id: 'category' });
    expect(operation.data).toHaveProperty('name', '日报');
    // 每个仍有效的分类标签组合必须完整保留。
    for (const [module, kind] of [['notes', 'tag'], ['inventory', 'category'], ['membership', 'category'], ['timeline', 'category']]) {
      // 独立构造一条仍有效的分类标签写入。
      const active: SyncOperationDto = { ...operation, data: { ...operation.data, module, kind } };
      expect(retireNoteCategoryOperation(active)).toBe(active);
    }
    expect(() => retireNoteCategoryOperation({ ...operation, data: { ...operation.data, unknown_column: '不能隐藏' } })).toThrow(BadRequestException);
  });

  it('当前SQL和完整快照拒绝笔记类别及类别列', () => {
    // 当前结构没有旧类别的可写入口。
    const builder = new SyncSqlBuilder();
    expect(() => builder.build({ op: 'PATCH', table: 'note_entries', id: 'note', data: { category_name: '旧类别' } }, 'owner')).toThrow(BadRequestException);
    expect(() => builder.build({ op: 'PUT', table: 'taxonomy_entries', id: 'category', data: { module: 'notes', kind: 'category' } }, 'owner')).toThrow(BadRequestException);
  });

  it('旧服务器已提交但未确认的事务按原始摘要重放，不执行退休后的新负载', async () => {
    // 升级前已经提交的混合事务，不能先剥列再求摘要。
    const operations: SyncOperationDto[] = [
      { op: 'PUT', table: 'taxonomy_entries', id: 'category', data: { module: 'notes', kind: 'category', name: '日报' } },
      { op: 'PATCH', table: 'note_entries', id: 'note', data: { category_id: 'category', category_name: '日报' } },
    ];
    // 旧服务端回执按原始操作保存的真实摘要算法。
    const payloadHash = createHash('sha256').update(JSON.stringify(canonicalize(operations))).digest('hex');
    // 已有回执的路径不应继续执行任何业务SQL。
    const transaction = { $queryRaw: jest.fn().mockResolvedValue([{ id: 'owner' }]), syncReceipt: { findUnique: jest.fn().mockResolvedValue({ payloadHash, applied: 2, ignored: 0 }) }, $executeRawUnsafe: jest.fn() };
    // 仅替换数据库事务宿主，保留完整生产预检和摘要计算。
    const prisma = { $transaction: jest.fn(async (run: (value: typeof transaction) => Promise<unknown>) => run(transaction)) } as unknown as PrismaService;
    expect(await new SyncService(prisma).applyBatch('owner', { clientId: 'client', transactionId: 'before-upgrade', operations })).toEqual({ applied: 2, ignored: 0, replayed: true });
    expect(transaction.$executeRawUnsafe).not.toHaveBeenCalled();
    expect(operations[1]!.data).toHaveProperty('category_name', '日报');
  });
});
