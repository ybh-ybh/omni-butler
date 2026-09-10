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
const writableColumns: Readonly<Record<string, ReadonlySet<string>>> = {
  todo_items: new Set([
    'title',
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
    'notes',
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
    'is_manual',
    'created_at',
    'updated_at',
  ]),
  taxonomy_entries: new Set([
    'module',
    'kind',
    'name',
    'normalized_name',
    'color_value',
    'icon_code_point',
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
    'payment_method',
    'price_cents',
    'billing_cycle',
    'base_status',
    'purchase_date',
    'expiration_date',
    'is_permanent',
    'auto_renew',
    'renewal_date',
    'is_favorite',
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
    'billing_cycle',
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
    const allowed = writableColumns[operation.table];
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
    const data = operation.data ?? {};
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
    // 冲突更新赋值列表，永远不允许改变 user_id。
    const updates = columns
      .map((column) => `"${column}" = EXCLUDED."${column}"`)
      .join(', ');
    return {
      sql: `INSERT INTO "${operation.table}" (${insertColumns.map((column) => `"${column}"`).join(', ')}) VALUES (${placeholders}) ON CONFLICT ("id") DO UPDATE SET ${updates} WHERE "${operation.table}"."user_id" = $2::uuid`,
      values: [operation.id, userId, ...columns.map((column) => data[column])],
    };
  }
}
