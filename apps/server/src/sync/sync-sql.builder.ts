import { BadRequestException } from '@nestjs/common';
import type { SyncOperationDto } from './dto/sync-operation.dto';
import { validateNoteRecordTime } from './note-record-time';

/// 一条参数化同步 SQL。
export interface SyncStatement {
  /// 只包含白名单标识符的 SQL 文本。
  sql: string;
  /// SQL 占位符参数。
  values: unknown[];
}

/// 各同步表允许由客户端写入的列。
export const writableColumns: Readonly<Record<string, ReadonlySet<string>>> = {
  note_entries: new Set(['body', 'day_key', 'record_time_seconds', 'record_utc_offset_minutes', 'is_pinned', 'creation_timezone', 'tags', 'revision', 'created_at', 'updated_at', 'deleted_at']),
  note_versions: new Set(['note_id', 'body', 'base_revision', 'revision', 'created_at', 'deleted_at']),
  note_audio_segments: new Set(['note_id', 'sort_order', 'duration_ms', 'mime', 'sha256', 'byte_size', 'transcript', 'created_at', 'updated_at', 'deleted_at']),
  note_images: new Set(['note_id', 'sort_order', 'created_at', 'updated_at', 'deleted_at']),
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
    'icon_emoji',
    'sort_order',
    'is_pinned',
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
    if (operation.table === 'taxonomy_entries' && data.module === 'notes' && data.kind === 'tag') {
      // 兼容升级前完整上传和换服快照，仅清除笔记标签的退休颜色。
      data.color_value = null;
    }
    if (operation.table === 'taxonomy_entries' && Object.hasOwn(data, 'icon_emoji') && data.icon_emoji !== null && typeof data.icon_emoji !== 'string') {
      throw new BadRequestException('标签图标必须为空或完整的表情文字');
    }
    if (operation.table === 'note_images' && data.sort_order !== undefined && (!Number.isSafeInteger(data.sort_order) || (data.sort_order as number) < 0)) {
      throw new BadRequestException('笔记图片顺序必须为非负整数');
    }
    if (operation.table === 'taxonomy_entries' && data.module === 'notes' && data.kind === 'category') {
      throw new BadRequestException('笔记类别已下线，请使用笔记标签');
    }
    if (operation.table === 'note_entries' && data.creation_timezone !== undefined) {
      // 保留客户端创建时的精确字符串，不能从服务器当前时区重新推导。
      const timezone = data.creation_timezone;
      if (typeof timezone !== 'string' || timezone.trim().length === 0 || [...timezone].length > 128) throw new BadRequestException('笔记创建时区必须为一至一百二十八字的非空文字');
    }
    if (operation.table === 'note_entries' && data.tags !== undefined) {
      // 标签必须是最多二十个 UUID 的 JSON 文本，防止歧义同步。
      let tags: unknown;
      try { if (typeof data.tags !== 'string') throw new Error('invalid'); tags = JSON.parse(data.tags); } catch { throw new BadRequestException('笔记标签必须为 JSON 数组'); }
      if (!Array.isArray(tags) || tags.length > 20 || tags.some((tag: unknown) => typeof tag !== 'string' || !/^[a-f0-9-]{36}$/i.test(tag))) throw new BadRequestException('笔记最多支持二十个有效标签');
    }
    if (operation.table === 'note_entries' && data.day_key !== undefined) {
      // 真实自然日校验，不能接受 2 月 30 日之类无效值。
      const day = typeof data.day_key === 'string' ? data.day_key : '';
      // 对应 UTC 自然日的解析值。
      const parsed = new Date(`${day}T00:00:00Z`);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== day) throw new BadRequestException('笔记日期无效');
    }
    if (operation.table === 'note_entries') {
      if (Object.hasOwn(data, 'is_pinned') && typeof data.is_pinned !== 'boolean') {
        throw new BadRequestException('笔记置顶状态必须为布尔值');
      }
      validateNoteRecordTime(data, operation.op === 'PATCH');
    }
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
