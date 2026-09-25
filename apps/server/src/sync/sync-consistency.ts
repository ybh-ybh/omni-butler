import { BadRequestException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import type { Prisma } from '../generated/prisma/client';
import type { SyncOperationDto } from './dto/sync-operation.dto';

/// 与客户端 stableBusinessId 使用相同 URL 命名空间和编码规则。
function stableBusinessId(kind: string, parts: string[]): string {
  // RFC 9562 URL 命名空间的十六进制字节。
  const namespace = Buffer.from('6ba7b8119dad11d180b400c04fd430c8', 'hex');
  // 与 Dart Uri.encodeComponent 保持一致的业务名称。
  const name = `https://omni-butler.local/${kind}/${parts.map(encodeURIComponent).join('/')}`;
  // UUIDv5 的前十六个 SHA-1 字节。
  const bytes = createHash('sha1')
    .update(namespace)
    .update(name, 'utf8')
    .digest()
    .subarray(0, 16);
  bytes[6] = (bytes.readUInt8(6) & 0x0f) | 0x50;
  bytes[8] = (bytes.readUInt8(8) & 0x3f) | 0x80;
  // 已设置版本和变体后的 UUID 十六进制文本。
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/// 提取客户端 DATE 文本的自然日，不对带时区文本做 UTC 日期换算。
function dateKey(value: unknown): string | null {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}(?:$|T| )/.test(value)) {
    return null;
  }
  // PostgreSQL DATE 实际接收的自然日。
  const day = value.slice(0, 10);
  // 避免非法日期参与自动账期身份判定。
  const parsed = new Date(`${day}T00:00:00.000Z`);
  return Number.isNaN(parsed.getTime()) ||
    parsed.toISOString().slice(0, 10) !== day
    ? null
    : day;
}

/// 对已识别自动续费事务的会员 PATCH 保留服务器较晚的到期和续费日期。
export async function normalizeAutomaticRenewalPatch(
  transaction: Prisma.TransactionClient,
  userId: string,
  operation: SyncOperationDto,
  operations: SyncOperationDto[],
): Promise<SyncOperationDto> {
  if (
    operation.table !== 'memberships' ||
    operation.op !== 'PATCH' ||
    !operation.data
  ) {
    return operation;
  }
  // 通过业务 UUID 校验自动账单，绝不依赖可编辑的备注内容。
  const automatic = operations.some((candidate) => {
    if (
      candidate.table !== 'membership_payments' ||
      candidate.op !== 'PUT' ||
      candidate.data?.membership_id !== operation.id
    ) {
      return false;
    }
    // 自动账期的稳定自然日起点。
    const start = dateKey(candidate.data.valid_from);
    return (
      start !== null &&
      candidate.id === stableBusinessId('auto-renewal', [operation.id, start])
    );
  });
  if (!automatic) {
    return operation;
  }
  // 同 owner 行锁内读取最新日期，涵盖本批中前面的续费操作。
  const membership = await transaction.membership.findFirst({
    where: { id: operation.id, userId },
    select: { expirationDate: true, renewalDate: true },
  });
  if (!membership) {
    return operation;
  }
  // 只复制需要归一化的操作，不修改幂等回执所校验的原始负载。
  const data = { ...operation.data };
  // 服务器字段与上传列名的对应关系。
  const dates = [
    ['expiration_date', membership.expirationDate],
    ['renewal_date', membership.renewalDate],
  ] as const;
  for (const [column, current] of dates) {
    if (!(column in data) || current === null) {
      continue;
    }
    // 数据库 DATE 已规范化为 UTC 零点，比较 YYYY-MM-DD 即可。
    const currentDay = current.toISOString().slice(0, 10);
    // 上传建议值；空值不能清除已存在的自动续费日期。
    const proposed = dateKey(data[column]);
    if (
      data[column] === null ||
      (proposed !== null && currentDay >= proposed)
    ) {
      data[column] = currentDay;
    }
  }
  return { ...operation, data };
}

/// 在同 owner 锁和上传事务中，根据最终数据重算跨记录业务不变量。
export async function reconcileSync(
  transaction: Prisma.TransactionClient,
  userId: string,
  operations: SyncOperationDto[],
): Promise<void> {
  if (
    operations.some(
      (operation) =>
        operation.table === 'events' || operation.table === 'event_completions',
    )
  ) {
    await reconcileEvents(transaction, userId, operations);
  }
  if (operations.some((operation) => operation.table === 'todo_items')) {
    await reconcileTodos(transaction, userId);
  }
}

/// 补齐旧本地初始时间的历史，并以有效历史最大时间作为事件汇总。
async function reconcileEvents(
  transaction: Prisma.TransactionClient,
  userId: string,
  operations: SyncOperationDto[],
): Promise<void> {
  for (const operation of operations) {
    if (
      operation.table !== 'events' ||
      operation.op !== 'PUT' ||
      operation.data?.last_completed_at == null
    ) {
      continue;
    }
    // 固定的初始历史身份可与新客户端初始记录自然合并。
    const initialId = stableBusinessId('event-initial', [operation.id]);
    await transaction.$executeRaw`
      INSERT INTO "event_completions"
        ("id", "user_id", "event_id", "completed_at", "source", "created_at")
      SELECT ${initialId}::uuid, event."user_id", event."id",
             event."last_completed_at", 'initial', event."created_at"
      FROM "events" AS event
      WHERE event."id" = ${operation.id}::uuid
        AND event."user_id" = ${userId}::uuid
        AND event."last_completed_at" IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM "event_completions" AS history
          WHERE history."user_id" = event."user_id" AND history."event_id" = event."id"
        )
      ON CONFLICT ("id") DO NOTHING
    `;
  }
  await transaction.$executeRaw`
    UPDATE "events" AS event
    SET "last_completed_at" = latest."completed_at", "updated_at" = CURRENT_TIMESTAMP
    FROM (
      SELECT parent."id", MAX(history."completed_at") AS "completed_at"
      FROM "events" AS parent
      LEFT JOIN "event_completions" AS history
        ON history."user_id" = parent."user_id" AND history."event_id" = parent."id"
        AND history."deleted_at" IS NULL AND NOT history."is_revoked"
      WHERE parent."user_id" = ${userId}::uuid
      GROUP BY parent."id"
    ) AS latest
    WHERE event."id" = latest."id" AND event."user_id" = ${userId}::uuid
      AND event."last_completed_at" IS DISTINCT FROM latest."completed_at"
  `;
}

/// 校验两层树、传播父删除，并根据最终有效孩子状态更新父任务。
async function reconcileTodos(
  transaction: Prisma.TransactionClient,
  userId: string,
): Promise<void> {
  // 任一父节点本身仍有父节点就违反两层树约束，自引用和环也会命中。
  const invalid = await transaction.$queryRaw<Array<{ id: string }>>`
    SELECT child."id"
    FROM "todo_items" AS child
    JOIN "todo_items" AS parent
      ON parent."user_id" = child."user_id" AND parent."id" = child."parent_id"
    WHERE child."user_id" = ${userId}::uuid
      AND (child."id" = child."parent_id" OR parent."parent_id" IS NOT NULL)
    LIMIT 1
  `;
  if (invalid.length > 0) {
    throw new BadRequestException(
      '待办只允许主任务和直属子任务两层，不能自引用或形成循环',
    );
  }
  await transaction.$executeRaw`
    UPDATE "todo_items" AS child
    SET "deleted_at" = parent."deleted_at", "updated_at" = CURRENT_TIMESTAMP
    FROM "todo_items" AS parent
    WHERE child."user_id" = ${userId}::uuid AND parent."user_id" = child."user_id"
      AND child."parent_id" = parent."id"
      AND child."deleted_at" IS NULL AND parent."deleted_at" IS NOT NULL
  `;
  await transaction.$executeRaw`
    UPDATE "todo_items" AS parent
    SET "is_completed" = children."all_completed",
        "completed_at" = CASE WHEN children."all_completed"
          THEN COALESCE(children."completed_at", parent."completed_at", CURRENT_TIMESTAMP)
          ELSE NULL END,
        "updated_at" = CURRENT_TIMESTAMP
    FROM (
      SELECT "parent_id", BOOL_AND("is_completed") AS "all_completed",
             MAX("completed_at") AS "completed_at"
      FROM "todo_items"
      WHERE "user_id" = ${userId}::uuid AND "parent_id" IS NOT NULL AND "deleted_at" IS NULL
      GROUP BY "parent_id"
    ) AS children
    WHERE parent."user_id" = ${userId}::uuid AND parent."id" = children."parent_id"
      AND parent."parent_id" IS NULL AND parent."deleted_at" IS NULL
      AND (parent."is_completed" IS DISTINCT FROM children."all_completed"
        OR (NOT children."all_completed" AND parent."completed_at" IS NOT NULL)
        OR (children."all_completed" AND parent."completed_at" IS DISTINCT FROM
          COALESCE(children."completed_at", parent."completed_at", CURRENT_TIMESTAMP)))
  `;
}
