import {
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import type { AuthUser } from '../auth/auth.types';
import type { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { reconcileTodos } from '../sync/sync-consistency';
import { businessRead, businessWrite } from './business-access';
import {
  objectInput,
  pageInput,
  pageResult,
  uuidInput,
} from './business-input';

/// 回收站模块到固定物理表的映射，不允许输入任意表。
const recycleTables = {
  quotes: 'quotes',
  time: 'time_entries',
  todos: 'todo_items',
  inventory: 'inventory_items',
  memberships: 'memberships',
  events: 'events',
  notes: 'note_entries',
} as const;
/// 可恢复的已有业务实体。
export type RecycleModule = keyof typeof recycleTables;

/// 显式回收站查询与恢复，永久删除不开放给工具。
@Injectable()
export class BusinessRecycleService {
  /// 复用现有 Prisma 与业务回执。
  constructor(private readonly prisma: PrismaService) {}

  /// 仅返回所选模块的已删除对象摘要，不能隐式混入普通查询。
  list(
    actor: AuthUser,
    module: RecycleModule,
    value: unknown,
  ): Promise<Prisma.JsonValue> {
    // 输入分页严格限制，不开放自由SQL。
    const page = pageInput(objectInput(value, ['limit', 'offset']));
    return businessRead(this.prisma, actor, async (transaction) => {
      // 表名只来自源码枚举。
      const rows = await transaction.$queryRawUnsafe<
        Array<{ id: string; name: string; deletedAt: Date }>
      >(
        `SELECT id, COALESCE(to_jsonb(record)->>'name',to_jsonb(record)->>'title',to_jsonb(record)->>'content',LEFT(to_jsonb(record)->>'body',120),'') AS name, deleted_at AS "deletedAt" FROM "${recycleTables[module]}" AS record WHERE user_id=$1::uuid AND deleted_at IS NOT NULL ORDER BY deleted_at DESC,id LIMIT $2 OFFSET $3`,
        actor.sub,
        page.take + 1,
        page.skip,
      );
      return pageResult(rows, page);
    });
  }

  /// 恢复顶层记录及同批子项，父项已删时不单独复活孤立配件/孩子。
  restore(
    actor: AuthUser,
    module: RecycleModule,
    value: unknown,
  ): Promise<Prisma.JsonValue> {
    // 恢复必须来自当前明确选择的回收站身份。
    const input = objectInput(value, ['operationId', 'id']);
    // 仅接受已有UUID，不按名称自动选择。
    const id = uuidInput(input.id, 'id');
    return businessWrite(
      this.prisma,
      actor,
      `restore.${module}`,
      input,
      async (transaction) => {
        // 真实删除批次与父项来自数据库。
        const rows = await transaction.$queryRawUnsafe<
          Array<{ deletedAt: Date | null; parentId: string | null }>
        >(
          `SELECT deleted_at AS "deletedAt", COALESCE(to_jsonb(record)->>'parent_id',to_jsonb(record)->>'parent_item_id') AS "parentId" FROM "${recycleTables[module]}" AS record WHERE user_id=$1::uuid AND id=$2::uuid`,
          actor.sub,
          id,
        );
        // 永久删除不能被恢复操作重新创建。
        const target = rows[0];
        if (!target?.deletedAt)
          throw new NotFoundException('该回收站记录不存在或已恢复');
        if (target.parentId) {
          // 恢复孩子不能越过仍在回收站中的父项。
          const parent = await transaction.$queryRawUnsafe<
            Array<{ id: string }>
          >(
            `SELECT id FROM "${recycleTables[module]}" WHERE user_id=$1::uuid AND id=$2::uuid AND deleted_at IS NULL`,
            actor.sub,
            target.parentId,
          );
          if (!parent.length) throw new ConflictException('请先恢复父记录');
        }
        // 两层聚合只恢复相同删除时间的直属孩子，保留原来独立删除项。
        const related =
          module === 'inventory'
            ? 'parent_item_id'
            : module === 'todos'
              ? 'parent_id'
              : null;
        // 恢复影响的正式身份用于结果与预览。
        const restored = await transaction.$queryRawUnsafe<
          Array<{ id: string }>
        >(
          `UPDATE "${recycleTables[module]}" SET deleted_at=NULL,updated_at=CURRENT_TIMESTAMP WHERE user_id=$1::uuid AND deleted_at=$3 AND (id=$2::uuid ${related && !target.parentId ? `OR ${related}=$2::uuid` : ''}) RETURNING id`,
          actor.sub,
          id,
          target.deletedAt,
        );
        if (module === 'todos') {
          await transaction.todoProgressStep.updateMany({
            where: {
              userId: actor.sub,
              todoId: { in: restored.map((row) => row.id) },
              deletedAt: target.deletedAt,
            },
            data: { deletedAt: null, updatedAt: new Date() },
          });
          await reconcileTodos(transaction, actor.sub);
        }
        if (module === 'notes') {
          // 正文版本和媒体只恢复同批关联，避免复活先前独立删除内容。
          await transaction.noteVersion.updateMany({
            where: {
              userId: actor.sub,
              noteId: id,
              deletedAt: target.deletedAt,
            },
            data: { deletedAt: null },
          });
          await transaction.noteAudioSegment.updateMany({
            where: {
              userId: actor.sub,
              noteId: id,
              deletedAt: target.deletedAt,
            },
            data: { deletedAt: null, updatedAt: new Date() },
          });
          await transaction.noteImage.updateMany({
            where: {
              userId: actor.sub,
              noteId: id,
              deletedAt: target.deletedAt,
            },
            data: { deletedAt: null, updatedAt: new Date() },
          });
        }
        return { restoredIds: restored.map((row) => row.id), module };
      },
    );
  }
}
