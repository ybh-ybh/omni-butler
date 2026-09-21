import { BadRequestException } from '@nestjs/common';
import type { SyncOperationDto } from '../src/sync/dto/sync-operation.dto';
import { SyncSqlBuilder } from '../src/sync/sync-sql.builder';

/// PowerSync SQL 白名单构建器测试。
describe('SyncSqlBuilder', () => {
  /// 被测 SQL 构建器。
  const builder = new SyncSqlBuilder();
  /// 固定用户标识。
  const userId = '9b1c7a3e-3fcf-4e06-8d29-4f9ca1d1fc74';
  /// 固定记录标识。
  const recordId = 'ea78cdfc-4368-45e9-b541-2adb46a0c136';

  it('PUT 强制使用当前用户且只更新白名单列', () => {
    // 测试同步操作。
    const operation: SyncOperationDto = {
      op: 'PUT',
      table: 'todo_items',
      id: recordId,
      data: { title: '喝水', priority_quadrant: 2 },
    };
    // 生成的参数化语句。
    const statement = builder.build(operation, userId);

    expect(statement.sql).toContain('INSERT INTO "todo_items"');
    expect(statement.sql).toContain('"user_id" = $2::uuid');
    expect(statement.values).toEqual([recordId, userId, 2, '喝水']);
  });

  it('允许同步待办父任务标识且保留当前用户过滤条件', () => {
    // 固定父任务标识。
    const parentId = '22f61737-ef1d-4b23-8f89-1ae14d1ae43b';
    // 包含可空父任务标识的同步操作。
    const operation: SyncOperationDto = {
      op: 'PATCH',
      table: 'todo_items',
      id: recordId,
      data: { parent_id: parentId },
    };
    // 生成的参数化语句。
    const statement = builder.build(operation, userId);

    expect(statement.sql).toBe(
      'UPDATE "todo_items" SET "parent_id" = $3 WHERE "id" = $1::uuid AND "user_id" = $2::uuid',
    );
    expect(statement.values).toEqual([recordId, userId, parentId]);
  });

  it('拒绝写入已下线的待办备注字段', () => {
    // 包含已下线备注字段的待办同步操作。
    const operation: SyncOperationDto = {
      op: 'PATCH',
      table: 'todo_items',
      id: recordId,
      data: { notes: '不再接受' },
    };

    expect(() => builder.build(operation, userId)).toThrow(BadRequestException);
  });

  it('拒绝客户端覆盖 user_id', () => {
    // 包含越权字段的同步操作。
    const operation: SyncOperationDto = {
      op: 'PATCH',
      table: 'events',
      id: recordId,
      data: { user_id: 'another-user' },
    };

    expect(() => builder.build(operation, userId)).toThrow(BadRequestException);
  });

  it('拒绝写入已下线的物品品牌和型号字段', () => {
    for (const column of ['brand', 'model']) {
      // 包含已下线字段的物品同步操作。
      const operation: SyncOperationDto = {
        op: 'PATCH',
        table: 'inventory_items',
        id: recordId,
        data: { [column]: '旧值' },
      };

      expect(() => builder.build(operation, userId)).toThrow(
        BadRequestException,
      );
    }
  });

  it('允许同步跨天与进行中时间字段', () => {
    // 包含绝对开始时间和可空结束时间的同步操作。
    const operation: SyncOperationDto = {
      op: 'PATCH',
      table: 'time_entries',
      id: recordId,
      data: {
        started_at: '2026-09-09T23:00:00.000Z',
        ended_at: null,
        activity: null,
      },
    };
    // 生成的参数化语句。
    const statement = builder.build(operation, userId);

    expect(statement.sql).toContain('"started_at"');
    expect(statement.sql).toContain('"ended_at"');
    expect(statement.values).toEqual([
      recordId,
      userId,
      null,
      null,
      '2026-09-09T23:00:00.000Z',
    ]);
  });

  it('DELETE 始终带当前用户过滤条件', () => {
    // 删除同步操作。
    const operation: SyncOperationDto = {
      op: 'DELETE',
      table: 'memberships',
      id: recordId,
    };
    // 生成的参数化语句。
    const statement = builder.build(operation, userId);

    expect(statement.sql).toBe(
      'DELETE FROM "memberships" WHERE "id" = $1::uuid AND "user_id" = $2::uuid',
    );
    expect(statement.values).toEqual([recordId, userId]);
  });
});
