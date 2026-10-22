import type { Prisma } from '../generated/prisma/client';

/// 在创建实例的同一 owner 锁事务内登记真实身份，供后续离线更新检查前值。
export async function protectRecurringTodo(
  transaction: Prisma.TransactionClient,
  userId: string,
  ids: readonly string[],
): Promise<void> {
  if (!ids.length) return;
  // 只选择当前归属真实存在的根/子任务，重复调用不刷新首次保护时间。
  await transaction.$executeRaw`
    INSERT INTO todo_recurrence_protections (user_id, todo_id)
    SELECT user_id, id FROM todo_items
    WHERE user_id=${userId}::uuid
      AND id IN (SELECT value::uuid FROM jsonb_array_elements_text(${JSON.stringify(ids)}::jsonb))
    ON CONFLICT (user_id, todo_id) DO NOTHING`;
}
