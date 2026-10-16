import type { Prisma } from '../src/generated/prisma/client';
import type { SyncOperationDto } from '../src/sync/dto/sync-operation.dto';
import { normalizeNoteOperation } from '../src/sync/note-sync';
import { SyncSqlBuilder } from '../src/sync/sync-sql.builder';

/// 旧持久队列与换服快照不能重新带回笔记颜色，其他模块颜色必须保留。
describe('笔记标签颜色退休', () => {
  it('完整 PUT 只清除笔记颜色且不修改原负载', () => {
    // SQL 构建器的输入仍用于幂等摘要，禁止原地归一化。
    const builder = new SyncSqlBuilder();
    for (const module of ['notes', 'inventory', 'timeline', 'membership']) {
      // 旧客户端的完整标签记录。
      const operation: SyncOperationDto = {
        op: 'PUT', table: 'taxonomy_entries', id: 'tag',
        data: { module, kind: 'tag', name: '原名称', color_value: 4294967295, icon_emoji: '👩🏽‍💻' },
      };
      // 规范化后的参数仍完整保留名称和 Unicode。
      const statement = builder.build(operation, 'owner');
      expect(statement.values).toContain(module === 'notes' ? null : 4294967295);
      expect(statement.values).toContain('👩🏽‍💻');
      expect(operation.data?.color_value).toBe(4294967295);
    }
  });

  it('仅颜色 PATCH 按数据库中的归属处理，重试不改原始请求', async () => {
    for (const module of ['notes', 'inventory', 'timeline', 'membership']) {
      // 不信任缺少模块字段的旧 PATCH，通过真实身份所在行辨别范围。
      const transaction = {
        taxonomyEntry: { findFirst: jest.fn().mockResolvedValue({ module, kind: 'tag' }) },
      } as unknown as Prisma.TransactionClient;
      // 仅旧颜色的请求仍须完成，避免永久堵塞后续同步事务。
      const operation: SyncOperationDto = {
        op: 'PATCH', table: 'taxonomy_entries', id: 'tag', data: { color_value: 42 },
      };
      // 兼容处理的副本不会影响重放幂等性。
      const normalized = await normalizeNoteOperation(transaction, 'owner', operation);
      expect(normalized.data?.color_value).toBe(module === 'notes' ? null : 42);
      expect(operation.data?.color_value).toBe(42);
    }
  });

  it('笔记改名不附加颜色，转入笔记标签则清除已有颜色', async () => {
    // 同一身份的持久模块参与 PATCH 的最终状态计算。
    const transaction = {
      taxonomyEntry: { findFirst: jest.fn().mockResolvedValue({ module: 'notes', kind: 'tag' }) },
    } as unknown as Prisma.TransactionClient;
    // 无关字段编辑必须保持差量。
    const rename: SyncOperationDto = {
      op: 'PATCH', table: 'taxonomy_entries', id: 'tag', data: { name: '新名称' },
    };
    expect(await normalizeNoteOperation(transaction, 'owner', rename)).toEqual(rename);
    expect((await normalizeNoteOperation(transaction, 'owner', {
      ...rename, data: { module: 'notes', kind: 'tag', color_value: 42 },
    })).data).toEqual({ module: 'notes', kind: 'tag', color_value: null });
  });
});
