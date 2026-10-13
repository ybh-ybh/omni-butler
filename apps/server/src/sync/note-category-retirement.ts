import { BadRequestException } from '@nestjs/common';
import type { SyncOperationDto } from './dto/sync-operation.dto';
import { writableColumns } from './sync-sql.builder';

/// 仅识别旧客户端创建的笔记类别，不把标签或其他模块类别视为退休数据。
export function isRetiredNoteCategory(operation: SyncOperationDto): boolean {
  return operation.op === 'PUT' &&
    operation.table === 'taxonomy_entries' &&
    operation.data?.module === 'notes' && operation.data.kind === 'category';
}

/// 旧队列仅在执行副本中退休类别，原始请求仍用于跨版本幂等摘要。
export function retireNoteCategoryOperation(operation: SyncOperationDto): SyncOperationDto | null {
  if (isRetiredNoteCategory(operation)) {
    // 退休行同样检查全部列，避免把未知字段隐藏在忽略路径中。
    for (const column of Object.keys(operation.data ?? {})) {
      if (!writableColumns.taxonomy_entries!.has(column)) {
        throw new BadRequestException(`表 taxonomy_entries 不允许写入列：${column}`);
      }
    }
    return { op: 'DELETE', table: operation.table, id: operation.id };
  }
  if (operation.table !== 'note_entries' || operation.op === 'DELETE') return operation;
  // 独立复制已知旧字段，禁止改变客户端队列原件及其回执身份。
  const data = { ...operation.data };
  // 只有明确存在退休字段的空 PATCH 才能忽略，原本无效的空操作仍需拒绝。
  const retired = Object.hasOwn(data, 'category_id') || Object.hasOwn(data, 'category_name');
  delete data.category_id;
  delete data.category_name;
  if (operation.op === 'PATCH' && retired && Object.keys(data).length === 0) return null;
  return { ...operation, data };
}
