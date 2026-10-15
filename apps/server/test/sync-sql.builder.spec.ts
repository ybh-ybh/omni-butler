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

  it('标签置顶支持创建和独立差量，旧编辑不会隐式写入取消置顶', () => {
    // 新版创建明确携带置顶值。
    const creation = builder.build({ op: 'PUT', table: 'taxonomy_entries', id: recordId, data: { module: 'notes', kind: 'tag', name: '工作', is_pinned: true } }, userId);
    expect(creation.sql).toContain('"is_pinned"');
    expect(creation.sql).toContain('ON CONFLICT ("id") DO NOTHING');
    // 独立置顶不得把客户端缓存中的名称和排序带入更新。
    const pinned = builder.build({ op: 'PATCH', table: 'taxonomy_entries', id: recordId, data: { is_pinned: true } }, userId);
    expect(pinned.sql).toBe('UPDATE "taxonomy_entries" SET "is_pinned" = $3 WHERE "id" = $1::uuid AND "user_id" = $2::uuid');
    expect(pinned.values).toEqual([recordId, userId, true]);
    // 旧离线编辑缺失置顶字段时仍只改变名称。
    const legacy = builder.build({ op: 'PATCH', table: 'taxonomy_entries', id: recordId, data: { name: '改名' } }, userId);
    expect(legacy.sql).not.toContain('is_pinned');
  });

  it('笔记图片只开放关联和排序字段，拒绝路径及非整数顺序', () => {
    // 合法子记录按图片身份创建，而非覆盖整篇图片数组。
    const operation: SyncOperationDto = { op: 'PUT', table: 'note_images', id: recordId, data: { note_id: userId, sort_order: 0 } };
    expect(builder.build(operation, userId).sql).toContain('INSERT INTO "note_images"');
    for (const order of [-1, 0.5, '0', null]) {
      expect(() => builder.build({ ...operation, data: { ...operation.data, sort_order: order } }, userId)).toThrow(BadRequestException);
    }
    expect(() => builder.build({ ...operation, data: { local_path: 'private/file.png' } }, userId)).toThrow(BadRequestException);
  });

  it('PUT 强制使用当前用户且重复创建不覆盖既有记录', () => {
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
    expect(statement.sql).toContain('("id", "user_id",');
    expect(statement.sql).toContain('ON CONFLICT ("id") DO NOTHING');
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

  it('进度可选名称规范为空且不改变客户端原始幂等负载', () => {
    // 仅空格的可选名称不成为实际名称。
    const operation: SyncOperationDto = {
      op: 'PATCH',
      table: 'todo_progress_steps',
      id: recordId,
      data: { name: '   ' },
    };
    expect(builder.build(operation, userId).values).toEqual([
      recordId,
      userId,
      null,
    ]);
    expect(operation.data).toEqual({ name: '   ' });
  });

  it('事件只允许写入备注，拒绝已删除的事件说明', () => {
    // 备注继续使用参数化更新。
    const statement = builder.build(
      {
        op: 'PATCH',
        table: 'events',
        id: recordId,
        data: { notes: '保留备注' },
      },
      userId,
    );
    expect(statement.sql).toContain('SET "notes" = $3');
    expect(statement.values).toEqual([recordId, userId, '保留备注']);
    expect(() =>
      builder.build(
        {
          op: 'PUT',
          table: 'events',
          id: recordId,
          data: { name: '事件', description: '旧说明' },
        },
        userId,
      ),
    ).toThrow(BadRequestException);
  });

  it.each([
    ['todo_items', { task_type: 'unknown' }],
    ['todo_items', { progress_unit: '章'.repeat(11) }],
    ['todo_progress_steps', { name: '章'.repeat(201) }],
    ['todo_progress_steps', { name: 123 }],
    ['todo_progress_steps', { user_id: userId }],
  ])('拒绝进度任务的非法类型、超长字段或归属覆盖：%s %j', (table, data) => {
    expect(() =>
      builder.build({ op: 'PATCH', table, id: recordId, data }, userId),
    ).toThrow(BadRequestException);
  });
});
