import { BadRequestException } from '@nestjs/common';
import type { Prisma } from '../generated/prisma/client';

/// 预算覆盖整个工具 JSON，中文按实际 UTF-8 字节计算。
export const assistantTodoOutputBytes = 16 * 1024;

/// 只读取普通对象，不让历史或测试结果的额外字段进入模型资料。
function object(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/// 日期由业务读事务转为 ISO，纯投影也兼容尚未序列化的日期。
function date(value: unknown): string | null {
  return value instanceof Date
    ? value.toISOString()
    : typeof value === 'string'
      ? value
      : null;
}

/// 将真实列表固定为助手摘要；分页位置永远只越过实际交付的完整项。
export function assistantTodoOutput(
  value: unknown,
  args: Record<string, unknown> = {},
): Prisma.JsonValue {
  // 只认可领域列表的 items，不把错误对象伪装成空列表成功。
  const source = object(value);
  if (!Array.isArray(source.items))
    throw new BadRequestException({
      code: 'ASSISTANT_TODO_RESULT_INVALID',
      message: '待办列表结果无效，请重新查询',
    });
  // 历史完整步骤仅用于计数，不保留正文与同步字段。
  const items = source.items.map((value: unknown) => {
    // 已投影记录和旧完整记录使用同一允许字段集。
    const row = object(value);
    // 软删步骤不应被统计为有效进度。
    const steps = Array.isArray(row.progressSteps)
      ? row.progressSteps.map(object).filter((step) => !step.deletedAt)
      : [];
    // 新查询由数据库直接提供计数，不加载步骤。
    const progress = object(row.progress);
    return {
      id: row.id,
      title: row.title,
      taskType: row.taskType,
      priorityQuadrant: row.priorityQuadrant,
      scheduledDate: date(row.scheduledDate),
      dueAt: date(row.dueAt),
      isCompleted: row.isCompleted,
      parentId: row.parentId ?? null,
      progress: {
        total:
          typeof progress.total === 'number' ? progress.total : steps.length,
        completed:
          typeof progress.completed === 'number'
            ? progress.completed
            : steps.filter((step) => step.isCompleted === true).length,
      },
    };
  });
  // 参数已由共享目录校验；纯投影缺省从第一页开始。
  const offset =
    typeof args.offset === 'number' && Number.isSafeInteger(args.offset)
      ? args.offset
      : 0;
  // 截断只指本页条数减少，步骤摘要有独立标识。
  let truncated = source.truncated === true;
  // 每次重建元数据，使末尾项移除后游标与事实一致。
  const result = (): Record<string, unknown> => {
    // 查询仍有未交付项时必须保留继续分页能力。
    const hasMore = source.hasMore === true || truncated;
    return {
      items,
      hasMore,
      nextOffset: hasMore ? offset + items.length : null,
      includesUnmaterializedRecurring: false,
      stepsSummarized: true,
      truncated,
      returnedCount: items.length,
    };
  };
  while (
    Buffer.byteLength(JSON.stringify(result()), 'utf8') >
    assistantTodoOutputBytes
  ) {
    if (items.length <= 1)
      throw new BadRequestException({
        code: 'ASSISTANT_TOOL_RESULT_TOO_LARGE',
        message: '单条待办摘要超过读取预算，请按标题缩小查询范围',
      });
    items.pop();
    truncated = true;
  }
  return JSON.parse(JSON.stringify(result())) as Prisma.JsonValue;
}
