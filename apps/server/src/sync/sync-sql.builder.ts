import { BadRequestException } from '@nestjs/common';
import type { SyncOperationDto } from './dto/sync-operation.dto';

/// 一条参数化同步 SQL。
export interface SyncStatement {
  /// 只包含白名单标识符的 SQL 文本。
  sql: string;
  /// SQL 占位符参数。
  values: unknown[];
}

/// 各同步表允许由客户端写入的列。
export const writableColumns: Readonly<Record<string, ReadonlySet<string>>> = {
  todo_items: new Set([
    'parent_id',
    'title',
    'task_type',
    'progress_unit',
    'description',
    'scheduled_date',
    'due_at',
    'priority_quadrant',
    'is_completed',
    'completed_at',
    'reminder_at',
    'repeat_rule',
    'repeat_series_id',
    'sort_order',
    'created_at',
    'updated_at',
    'deleted_at',
  ]),
  todo_progress_steps: new Set([
    'todo_id',
    'name',
    'sort_order',
    'is_completed',
    'completed_at',
    'created_at',
    'updated_at',
    'deleted_at',
  ]),
  quotes: new Set([
    'content',
    'source',
    'is_enabled',
    'created_at',
    'updated_at',
    'deleted_at',
  ]),
  daily_quote_selections: new Set([
    'day_key',
    'quote_id',
    'created_at',
    'updated_at',
  ]),
  taxonomy_entries: new Set([
    'module',
    'kind',
    'name',
    'color_value',
    'sort_order',
    'is_enabled',
    'created_at',
    'updated_at',
    'deleted_at',
  ]),
  record_taxonomy_links: new Set([
    'module',
    'record_id',
    'taxonomy_id',
    'created_at',
    'deleted_at',
  ]),
  events: new Set([
    'name',
    'category',
    'description',
    'interval_value',
    'interval_unit',
    'last_completed_at',
    'reminder_enabled',
    'reminder_days_before',
    'reminder_time_minutes',
    'is_archived',
    'archived_at',
    'notes',
    'created_at',
    'updated_at',
    'deleted_at',
  ]),
  event_completions: new Set([
    'event_id',
    'completed_at',
    'notes',
    'source',
    'is_revoked',
    'created_at',
    'deleted_at',
  ]),
  inventory_items: new Set([
    'name',
    'category',
    'quantity',
    'purchase_price_cents',
    'purchase_date',
    'location',
    'purchase_url',
    'purchase_platform',
    'status',
    'warranty_expiration',
    'tags',
    'parent_item_id',
    'notes',
    'created_at',
    'updated_at',
    'deleted_at',
  ]),
  time_entries: new Set([
    'entry_date',
    'start_minute',
    'end_minute',
    'started_at',
    'ended_at',
    'activity',
    'category',
    'notes',
    'created_at',
    'updated_at',
    'deleted_at',
  ]),
  memberships: new Set([
    'name',
    'provider',
    'category',
    'description',
    'website_url',
    'purchase_platform',
    'price_cents',
    'billing_cycle',
    'base_status',
    'purchase_date',
    'expiration_date',
    'is_permanent',
    'auto_renew',
    'renewal_date',
    'needs_renewal',
    'expiration_reminder_enabled',
    'expiration_reminder_days',
    'renewal_reminder_enabled',
    'renewal_reminder_days',
    'reminder_time_minutes',
    'cancel_guide',
    'notes',
    'created_at',
    'updated_at',
    'deleted_at',
  ]),
  membership_payments: new Set([
    'membership_id',
    'amount_cents',
    'paid_at',
    'valid_from',
    'valid_until',
    'notes',
    'created_at',
    'deleted_at',
  ]),
};

/// 将受限 PowerSync 操作转换为参数化 PostgreSQL 语句。
export class SyncSqlBuilder {
  /// 构建一条当前用户范围内的写入语句。
  build(operation: SyncOperationDto, userId: string): SyncStatement {
    // 目标表允许写入的列。
    const allowed = Object.hasOwn(writableColumns, operation.table)
      ? writableColumns[operation.table]
      : undefined;
    if (!allowed) {
      throw new BadRequestException(`不支持同步表：${operation.table}`);
    }
    if (operation.op === 'DELETE') {
      return {
        sql: `DELETE FROM "${operation.table}" WHERE "id" = $1::uuid AND "user_id" = $2::uuid`,
        values: [operation.id, userId],
      };
    }
    // 客户端提交的数据。
    const data = { ...operation.data };
    // 对新类型字段给出明确的客户端错误，原始负载保持幂等摘要不变。
    if (operation.table === 'todo_items') {
      if (
        data.task_type !== undefined &&
        data.task_type !== 'normal' &&
        data.task_type !== 'progress'
      ) {
        throw new BadRequestException('不支持的待办任务类型');
      }
      this.normalizeOptionalText(data, 'progress_unit', 10);
    }
    if (operation.table === 'todo_progress_steps') {
      this.normalizeOptionalText(data, 'name', 200);
    }
    // 按名称排序的有效列，保证相同输入生成稳定 SQL。
    const columns = Object.keys(data).sort();
    if (columns.length === 0) {
      throw new BadRequestException(`${operation.op} 操作必须包含 data`);
    }
    for (const column of columns) {
      if (!allowed.has(column)) {
        throw new BadRequestException(
          `表 ${operation.table} 不允许写入列：${column}`,
        );
      }
    }
    if (operation.op === 'PATCH') {
      // 参数化更新赋值列表。
      const assignments = columns
        .map((column, index) => `"${column}" = $${index + 3}`)
        .join(', ');
      return {
        sql: `UPDATE "${operation.table}" SET ${assignments} WHERE "id" = $1::uuid AND "user_id" = $2::uuid`,
        values: [
          operation.id,
          userId,
          ...columns.map((column) => data[column]),
        ],
      };
    }
    // INSERT 中的全部安全标识符。
    const insertColumns = ['id', 'user_id', ...columns];
    // INSERT 的参数占位符。
    const placeholders = insertColumns
      .map((_column, index) => `$${index + 1}`)
      .join(', ');
    // PUT 只创建；另一设备生成的同一稳定实体不能覆盖既有编辑。
    return {
      sql: `INSERT INTO "${operation.table}" (${insertColumns.map((column) => `"${column}"`).join(', ')}) VALUES (${placeholders}) ON CONFLICT ("id") DO NOTHING`,
      values: [operation.id, userId, ...columns.map((column) => data[column])],
    };
  }

  /// 清理可选名称前后空白，并以 null 表示空名称。
  private normalizeOptionalText(
    data: Record<string, unknown>,
    column: string,
    maximum: number,
  ): void {
    // PATCH 不携带字段时必须保留服务端当前值。
    const value = data[column];
    if (value === undefined || value === null) return;
    if (typeof value !== 'string' || [...value.trim()].length > maximum) {
      throw new BadRequestException(
        `${column} 必须为空或不超过 ${maximum} 个字符的文字`,
      );
    }
    data[column] = value.trim() || null;
  }
}
