import { BadRequestException } from '@nestjs/common';
import type { AuthService } from '../src/auth/auth.service';
import type { Prisma } from '../src/generated/prisma/client';
import type { PrismaService } from '../src/prisma/prisma.service';
import type { SyncMigrationDto } from '../src/sync/dto/sync-migration.dto';
import type { SyncOperationDto } from '../src/sync/dto/sync-operation.dto';
import { normalizeNoteOperation } from '../src/sync/note-sync';
import { SyncMigrationService } from '../src/sync/sync-migration.service';
import { SyncSqlBuilder } from '../src/sync/sync-sql.builder';

/// 置顶协议独立于正文版本，兼容旧队列和换服快照。
describe('笔记置顶', () => {
  // 增量上传与快照共用的字段边界。
  const builder = new SyncSqlBuilder();

  it.each([true, false])('独立置顶差量仅提交布尔状态与更新时间：%s', async (isPinned) => {
    // 缺少版本查询能力，确保置顶不依赖正文候选。
    const transaction = { noteEntry: { findFirst: jest.fn().mockResolvedValue({ id: 'note', isPinned: !isPinned, deletedAt: null }) } } as unknown as Prisma.TransactionClient;
    // 冻结请求，避免服务端归一化改变原始幂等摘要。
    const operation: SyncOperationDto = Object.freeze({ op: 'PATCH', table: 'note_entries', id: 'note', data: Object.freeze({ is_pinned: isPinned, updated_at: '2026-10-19T10:00:00Z' }) });
    expect(await normalizeNoteOperation(transaction, 'owner', operation)).toEqual(operation);
    // SQL 不包含正文、时间或修订事实。
    const statement = builder.build(operation, 'owner');
    expect(statement.sql).toBe('UPDATE "note_entries" SET "is_pinned" = $3, "updated_at" = $4 WHERE "id" = $1::uuid AND "user_id" = $2::uuid');
    expect(statement.values).toEqual(['note', 'owner', isPinned, '2026-10-19T10:00:00Z']);
  });

  it.each(['PUT', 'PATCH'] as const)('%s 拒绝所有非布尔置顶状态', (op) => {
    for (const isPinned of [0, 1, 'true', 'false', null, undefined, {}, []]) {
      expect(() => builder.build({ op, table: 'note_entries', id: 'note', data: { is_pinned: isPinned } }, 'owner')).toThrow(BadRequestException);
    }
  });

  it('旧 PUT 不补写置顶，旧正文 PATCH 不覆盖另一设备置顶', async () => {
    expect(builder.build({ op: 'PUT', table: 'note_entries', id: 'note', data: { body: '旧笔记' } }, 'owner').sql).not.toContain('is_pinned');
    // 正文与修订完全相同，模拟旧队列的幂等正文更新。
    const transaction = { noteEntry: { findFirst: jest.fn().mockResolvedValue({ id: 'note', body: '旧正文', revision: 'revision', isPinned: true, deletedAt: null }) } } as unknown as Prisma.TransactionClient;
    // 旧正文负载没有置顶字段，任何归一化都不能推入 false。
    const normalized = await normalizeNoteOperation(transaction, 'owner', { op: 'PATCH', table: 'note_entries', id: 'note', data: { body: '旧正文', revision: 'revision' } });
    expect(normalized.data).toEqual({ body: '旧正文', revision: 'revision' });
    expect(builder.build(normalized, 'owner').sql).not.toContain('is_pinned');
  });

  it('删除后的笔记拒绝普通置顶差量覆盖回收站状态', async () => {
    // 已删除行的更新时间必须保留，不恢复也不置顶。
    const updatedAt = new Date('2026-10-19T00:00:00Z');
    // 回收站保护沿用其他元数据 PATCH 的统一规则。
    const transaction = { noteEntry: { findFirst: jest.fn().mockResolvedValue({ deletedAt: updatedAt, updatedAt }) } } as unknown as Prisma.TransactionClient;
    expect((await normalizeNoteOperation(transaction, 'owner', { op: 'PATCH', table: 'note_entries', id: 'note', data: { is_pinned: true } })).data).toEqual({ updated_at: updatedAt.toISOString() });
  });

  it.each([undefined, true, false])('wire v3 兼容新旧完整笔记快照：%s', async (isPinned) => {
    // 完整旧笔记明确缺少新版时间组与置顶字段。
    const data: Record<string, unknown> = { body: '备份正文', day_key: '2026-10-19', creation_timezone: 'legacy:unknown', tags: '[]', revision: 'revision', created_at: '2026-10-19T00:00:00Z', updated_at: '2026-10-19T00:00:00Z', deleted_at: null };
    if (isPinned !== undefined) data.is_pinned = isPinned;
    // 只验证公共 replace 的预检阶段；绝不触碰实际数据库。
    const reachedTransaction = new Error('snapshot validation accepted');
    // 验证预检通过后才进入事务，且不改变原始快照摘要。
    const executeTransaction = jest.fn().mockRejectedValue(reachedTransaction);
    // 使用受控依赖，不连接任何外部服务。
    const service = new SyncMigrationService({ $transaction: executeTransaction } as unknown as PrismaService, { verifySyncKey: jest.fn() } as unknown as AuthService);
    // 本机快照版本与换服协议独立；服务端依然接受 v3。
    const input: SyncMigrationDto = { syncKey: 'test-key', migrationId: 'migration', expectedOwnerId: 'owner', snapshotVersion: 3, operations: [{ op: 'PUT', table: 'note_entries', id: 'note', data }] };
    await expect(service.replace(input)).rejects.toBe(reachedTransaction);
    expect(executeTransaction).toHaveBeenCalledTimes(1);
    expect(Object.hasOwn(data, 'is_pinned')).toBe(isPinned !== undefined);
  });
});
