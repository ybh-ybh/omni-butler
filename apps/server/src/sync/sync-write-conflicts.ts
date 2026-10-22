import { createHash } from 'node:crypto';
import type { Prisma } from '../generated/prisma/client';
import type { SyncOperationDto } from './dto/sync-operation.dto';
import { canonicalize } from './sync-hash';
import { writableColumns } from './sync-sql.builder';

/// 冲突保留原事务及服务器事实；不会因为日志过期删除未处理意图。
export interface SyncWriteConflict {
  /// 跨重试稳定的候选身份。
  id: string;
  /// pending/local/server三种决策状态。
  status: 'pending' | 'local' | 'server';
  /// 第一次冲突时刻。
  createdAt: string;
  /// 完整原事务，不能以部分成功丢掉后续步骤。
  operations: SyncOperationDto[];
  /// 最初发现冲突的字段说明。
  reason: {
    table: string;
    id: string;
    fields: string[];
    missingBaseline: boolean;
  };
  /// 显式决策的固定身份与摘要。
  resolution?: {
    requestId: string;
    hash: string;
    resolvedAt: string;
    result: unknown;
  };
}
/// 保存点内抛出，外层回滚全部业务后才保存候选回执。
export class SyncBaselineConflict extends Error {
  /// 冻结最先冲突字段，不携带原始正文到日志。
  constructor(readonly detail: SyncWriteConflict['reason']) {
    super('SYNC_WRITE_CONFLICT');
  }
}
/// 稳定事实摘要不依赖客户端时钟。
export function syncFactsHash(value: unknown): string {
  return createHash('sha256')
    .update(JSON.stringify(canonicalize(value)))
    .digest('hex');
}

/// 删除聚合时固定检查关联事实；只接受同步白名单里的固定关系。
async function syncDeletionDependents(
  transaction: Prisma.TransactionClient,
  userId: string,
  operation: SyncOperationDto,
): Promise<
  Array<{ table: string; id: string; data: Record<string, unknown> }>
> {
  if (
    operation.op !== 'DELETE' &&
    !(operation.op === 'PATCH' && operation.data?.deleted_at != null)
  )
    return [];
  // SQL标识全部来自固定关系，不接受客户端选择联表或条件。
  const relations: Array<{ table: string; predicate: string }> = [];
  // 两层主从记录共用同一删除闭包。
  const inventoryIds =
    'SELECT id FROM inventory_items WHERE user_id=$1::uuid AND (id=$2::uuid OR parent_item_id=$2::uuid)';
  // 进度步骤也可能属于本次被删除的子任务。
  const todoIds =
    'SELECT id FROM todo_items WHERE user_id=$1::uuid AND (id=$2::uuid OR parent_id=$2::uuid)';
  if (operation.table === 'inventory_items')
    relations.push(
      { table: 'inventory_items', predicate: 'parent_item_id=$2::uuid' },
      {
        table: 'record_taxonomy_links',
        predicate: `module='inventory' AND record_id IN (${inventoryIds})`,
      },
    );
  if (operation.table === 'todo_items')
    relations.push(
      { table: 'todo_items', predicate: 'parent_id=$2::uuid' },
      { table: 'todo_progress_steps', predicate: `todo_id IN (${todoIds})` },
    );
  if (operation.table === 'quotes')
    relations.push({
      table: 'daily_quote_selections',
      predicate: 'quote_id=$2::uuid',
    });
  if (operation.table === 'time_entries')
    relations.push({
      table: 'record_taxonomy_links',
      predicate: "module='timeline' AND record_id=$2::uuid",
    });
  if (operation.table === 'memberships')
    relations.push(
      { table: 'membership_payments', predicate: 'membership_id=$2::uuid' },
      {
        table: 'record_taxonomy_links',
        predicate: "module='membership' AND record_id=$2::uuid",
      },
    );
  if (operation.table === 'events')
    relations.push({
      table: 'event_completions',
      predicate: 'event_id=$2::uuid',
    });
  if (operation.table === 'note_entries')
    relations.push(
      { table: 'note_versions', predicate: 'note_id=$2::uuid' },
      { table: 'note_audio_segments', predicate: 'note_id=$2::uuid' },
      { table: 'note_images', predicate: 'note_id=$2::uuid' },
      {
        table: 'record_taxonomy_links',
        predicate: "module='notes' AND record_id=$2::uuid",
      },
    );
  if (operation.table === 'taxonomy_entries')
    relations.push({
      table: 'record_taxonomy_links',
      predicate: 'taxonomy_id=$2::uuid',
    });
  // 完整关联事实进入人工预览和摘要；不能只检查原队列当时已知的孩子。
  const result: Array<{
    table: string;
    id: string;
    data: Record<string, unknown>;
  }> = [];
  for (const relation of relations) {
    // 排序固定事实摘要，查询不读取任何私有服务表。
    const rows = await transaction.$queryRawUnsafe<
      Array<{ data: Record<string, unknown> }>
    >(
      `SELECT to_jsonb(record) AS data FROM "${relation.table}" AS record WHERE user_id=$1::uuid AND (${relation.predicate}) ORDER BY id`,
      userId,
      operation.id,
    );
    for (const row of rows)
      result.push({
        table: relation.table,
        id: String(row.data.id),
        data: Object.fromEntries(
          Object.entries(row.data).filter(([column]) =>
            writableColumns[relation.table]!.has(column),
          ),
        ),
      });
  }
  return result;
}

/// 只读取固定同步表的本归属事实，敏感服务表从不进入候选。
export async function syncCurrentRecords(
  transaction: Prisma.TransactionClient,
  userId: string,
  operations: SyncOperationDto[],
): Promise<
  Array<{ table: string; id: string; data: Record<string, unknown> | null }>
> {
  // 同一记录多次编辑只显示一份服务器当前事实。
  const result: Array<{
    table: string;
    id: string;
    data: Record<string, unknown> | null;
  }> = [];
  for (const operation of operations) {
    if (
      result.some(
        (row) => row.table === operation.table && row.id === operation.id,
      )
    )
      continue;
    // 表名必须在既有上传白名单中，值参数化。
    if (!Object.hasOwn(writableColumns, operation.table)) continue;
    // PostgreSQL JSON用于规范日期/布尔/整数的表示。
    const rows = await transaction.$queryRawUnsafe<
      Array<{ data: Record<string, unknown> }>
    >(
      `SELECT to_jsonb(record) AS data FROM "${operation.table}" AS record WHERE user_id=$1::uuid AND id=$2::uuid`,
      userId,
      operation.id,
    );
    // 只展示原同步业务字段，不附带服务端授权或资产密钥。
    const current = rows[0]?.data;
    result.push({
      table: operation.table,
      id: operation.id,
      data: current
        ? Object.fromEntries(
            Object.entries(current).filter(([column]) =>
              writableColumns[operation.table]!.has(column),
            ),
          )
        : null,
    });
  }
  // 原事务未列出的后来关联记录也必须展示，否则父项删除可能绕过子项保护。
  for (const operation of operations)
    for (const dependent of await syncDeletionDependents(
      transaction,
      userId,
      operation,
    )) {
      if (
        !result.some(
          (row) => row.table === dependent.table && row.id === dependent.id,
        )
      )
        result.push(dependent);
    }
  return result;
}

/// MCP 回执与后台实例登记共同形成持续保护，撤销连接不撤销既有事实。
async function hasProtectedRecords(
  transaction: Prisma.TransactionClient,
  userId: string,
  records: Array<{ table: string; id: string }>,
): Promise<boolean> {
  // 关联身份来自固定业务查询，JSON 参数不会成为自由 SQL 标识。
  const refs = JSON.stringify(records);
  // 后台登记只覆盖待办；其他模块继续沿用实际 MCP 回执。
  const result = await transaction.$queryRaw<Array<{ protected: boolean }>>`
    SELECT EXISTS(
      SELECT 1 FROM mcp_actions
      WHERE user_id=${userId}::uuid
        AND result->'protectedRecords' @> ANY(
          ARRAY(SELECT jsonb_build_array(ref) FROM jsonb_array_elements(${refs}::jsonb) AS ref)
        )
    ) OR EXISTS(
      SELECT 1 FROM todo_recurrence_protections protection
      JOIN jsonb_to_recordset(${refs}::jsonb) AS ref("table" text, id uuid)
        ON ref."table"='todo_items' AND ref.id=protection.todo_id
      WHERE protection.user_id=${userId}::uuid
    ) AS protected`;
  return result[0]?.protected ?? false;
}

/// 对 MCP 写入及后台生成记录永久启用前值检查；其他旧业务维持原同步语义。
export async function checkSyncBaseline(
  transaction: Prisma.TransactionClient,
  userId: string,
  operation: SyncOperationDto,
  cascadeApproved = false,
): Promise<void> {
  if (operation.op === 'PUT') return;
  if (!cascadeApproved) {
    // 旧协议队列没有关联集合基线，即使父项字段相同也不能证明已知MCP新增的孩子。
    const dependents = await syncDeletionDependents(
      transaction,
      userId,
      operation,
    );
    if (dependents.length) {
      // 关联身份来自固定关系查询，不由客户端声明。
      const refs = dependents.map(({ table, id }) => ({ table, id }));
      // 任一受保护的关联记录都要求明确核对整个当前删除闭包。
      const protectedDependents = await hasProtectedRecords(
        transaction,
        userId,
        refs,
      );
      if (protectedDependents)
        throw new SyncBaselineConflict({
          table: operation.table,
          id: operation.id,
          fields: ['关联记录'],
          missingBaseline: true,
        });
    }
  }
  // 本体和级联删除使用同一保护集合，调度新子任务不能绕过父项删除检查。
  const protectedRecord = await hasProtectedRecords(transaction, userId, [
    { table: operation.table, id: operation.id },
  ]);
  if (!protectedRecord) return;
  // 只有真实目标存在时才比较，原有墓碑和缺失目标逻辑继续处理其他情况。
  const rows = await transaction.$queryRawUnsafe<
    Array<{
      current: Record<string, unknown>;
      previous: Record<string, unknown>;
      proposed: Record<string, unknown>;
    }>
  >(
    `SELECT to_jsonb(record) AS current, to_jsonb(jsonb_populate_record(NULL::"${operation.table}",$3::jsonb)) AS previous, to_jsonb(jsonb_populate_record(NULL::"${operation.table}",$4::jsonb)) AS proposed FROM "${operation.table}" AS record WHERE user_id=$1::uuid AND id=$2::uuid`,
    userId,
    operation.id,
    JSON.stringify(operation.previous ?? {}),
    JSON.stringify(operation.data ?? {}),
  );
  // 真正删除后的迟到操作按墓碑忽略，不制造无法恢复的假冲突。
  const row = rows[0];
  if (!row) return;
  // 正文/标签已有版本候选和差量合并；事件汇总来自有效历史，不用标量覆盖。
  const independentlyProtected =
    operation.table === 'note_entries'
      ? ['body', 'revision', 'tags', 'tags_base']
      : operation.table === 'events'
        ? ['last_completed_at']
        : [];
  // 仅校验本次真正改变的字段，独立字段允许并发合并；删除则要求完整前值。
  const columns = (
    operation.op === 'DELETE'
      ? [...writableColumns[operation.table]!]
      : Object.keys(operation.data ?? {})
  ).filter(
    (column) =>
      !['created_at', 'updated_at'].includes(column) &&
      writableColumns[operation.table]!.has(column) &&
      (operation.op === 'DELETE' || !independentlyProtected.includes(column)),
  );
  // 同值重放不覆盖任何事实；缺前值的老队列保留为待决候选，绝不猜当前基线。
  const conflicts = columns.filter(
    (column) =>
      !(
        operation.previous &&
        Object.hasOwn(operation.previous, column) &&
        JSON.stringify(row.current[column]) ===
          JSON.stringify(row.previous[column])
      ) &&
      !(
        operation.op === 'PATCH' &&
        JSON.stringify(row.current[column]) ===
          JSON.stringify(row.proposed[column])
      ),
  );
  if (conflicts.length)
    throw new SyncBaselineConflict({
      table: operation.table,
      id: operation.id,
      fields: conflicts,
      missingBaseline: conflicts.some(
        (column) =>
          !operation.previous || !Object.hasOwn(operation.previous, column),
      ),
    });
}
