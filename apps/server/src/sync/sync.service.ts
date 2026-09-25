import {
  BadRequestException,
  ConflictException,
  Injectable,
} from '@nestjs/common';
import { createHash } from 'node:crypto';
import type { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import type { SyncBatchDto } from './dto/sync-batch.dto';
import type { SyncOperationDto } from './dto/sync-operation.dto';
import {
  normalizeAutomaticRenewalPatch,
  reconcileSync,
} from './sync-consistency';
import { SyncSqlBuilder } from './sync-sql.builder';

/// 同步操作引用的业务父表，用于处理永久删除后的迟到写入。
const parentReferences: Readonly<Record<string, Record<string, string>>> = {
  todo_items: { parent_id: 'todo_items' },
  record_taxonomy_links: { taxonomy_id: 'taxonomy_entries' },
  event_completions: { event_id: 'events' },
  inventory_items: { parent_item_id: 'inventory_items' },
  membership_payments: { membership_id: 'memberships' },
};

/// 对对象键排序，保证不同 JSON 属性顺序不会影响幂等内容校验。
function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, canonicalize(item)]),
    );
  }
  return value;
}

/// 原始客户端事务的持久化处理结果。
export interface SyncResult {
  /// 实际改变数据库的操作数量。
  applied: number;
  /// 已存在或被永久删除的操作数量。
  ignored: number;
  /// 是否直接返回已提交的幂等回执。
  replayed: boolean;
}

/// PowerSync 离线写入落库服务。
@Injectable()
export class SyncService {
  /// SQL 白名单构建器。
  private readonly sqlBuilder = new SyncSqlBuilder();

  /// 注入 Prisma 数据访问服务。
  constructor(private readonly prisma: PrismaService) {}

  /// 原子应用完整本地事务，重放返回旧结果而不重新写入。
  async applyBatch(userId: string, batch: SyncBatchDto): Promise<SyncResult> {
    // 写入之前校验全部表和列，避免忽略路径绕过白名单。
    for (const operation of batch.operations) {
      this.sqlBuilder.build(operation, userId);
    }
    // 操作摘要用于拒绝复用事务身份提交不同内容。
    const payloadHash = createHash('sha256')
      .update(JSON.stringify(canonicalize(batch.operations)))
      .digest('hex');
    return this.prisma.$transaction(
      async (transaction) => {
        // 单人多设备事务按归属串行提交，保证派生数据和回执一致。
        await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id = ${userId}::uuid FOR UPDATE`;
        // 同一数据库安装身份与事务编号构成唯一回执。
        const identity = {
          userId,
          clientId: batch.clientId,
          transactionId: batch.transactionId,
        };
        // 已提交事务的回执。
        const receipt = await transaction.syncReceipt.findUnique({
          where: { userId_clientId_transactionId: identity },
        });
        if (receipt) {
          if (receipt.payloadHash !== payloadHash) {
            throw new ConflictException('同一同步事务标识不能用于不同内容');
          }
          return {
            applied: receipt.applied,
            ignored: receipt.ignored,
            replayed: true,
          };
        }
        // 实际变化的操作交由派生状态协调器处理。
        const changedOperations: SyncOperationDto[] = [];
        // 当前事务实际写入数量。
        let applied = 0;
        // 当前事务忽略的已删除或重复创建数量。
        let ignored = 0;
        // 保留客户端原始事务顺序。
        for (const operation of batch.operations) {
          if (operation.table === 'daily_quote_selections') {
            // 日签需持久合并旧身份，并将删除解释为取消当日选择。
            const affected = await this.applyDailyQuoteOperation(
              transaction,
              userId,
              operation,
            );
            if (affected > 0) applied += 1;
            else ignored += 1;
            continue;
          }
          if (operation.op === 'DELETE') {
            await this.rememberDeletion(
              transaction,
              userId,
              operation.table,
              operation.id,
            );
          } else {
            // 本行自身的永久删除优先于所有后续写入。
            const deletedRecord = await this.wasDeleted(
              transaction,
              userId,
              operation.table,
              operation.id,
            );
            // 显式改绑到已删除父行也必须处理当前仍存在的子行。
            const deletedParent = await this.hasDeletedParent(
              transaction,
              userId,
              operation,
            );
            if (deletedRecord || deletedParent) {
              // 删除优先，同时移除现有行，避免墓碑与可见记录并存。
              const deletion: SyncOperationDto = {
                op: 'DELETE',
                table: operation.table,
                id: operation.id,
              };
              // 复用带所有者条件的删除语句，并让数据库级联记录墓碑。
              const deletionStatement = this.sqlBuilder.build(deletion, userId);
              await this.rememberDeletion(
                transaction,
                userId,
                operation.table,
                operation.id,
              );
              // 实际删除需要参与父任务和事件汇总的重新计算。
              const deleted = await transaction.$executeRawUnsafe(
                deletionStatement.sql,
                ...deletionStatement.values,
              );
              if (deleted > 0) changedOperations.push(deletion);
              ignored += 1;
              continue;
            }
          }
          // 自动续费只允许推进账期，人工编辑保持原意。
          const normalized = await normalizeAutomaticRenewalPatch(
            transaction,
            userId,
            operation,
            batch.operations,
          );
          // 当前操作的参数化 SQL。
          const statement = this.sqlBuilder.build(normalized, userId);
          // 真实受影响行数，缺失行 PATCH 不能伪装成同步成功。
          const affected = await transaction.$executeRawUnsafe(
            statement.sql,
            ...statement.values,
          );
          if (affected === 0 && operation.op === 'PATCH') {
            throw new ConflictException({
              message: '更新目标不存在，需要先上传完整记录',
              code: 'SYNC_RECORD_MISSING',
              table: operation.table,
              id: operation.id,
            });
          }
          if (affected > 0) {
            applied += 1;
            changedOperations.push(normalized);
          } else {
            ignored += 1;
          }
        }
        await reconcileSync(transaction, userId, changedOperations);
        await transaction.syncReceipt.create({
          data: { ...identity, payloadHash, applied, ignored },
        });
        return { applied, ignored, replayed: false };
      },
      { maxWait: 30000, timeout: 60000 },
    );
  }

  /// 合并同一天的旧随机身份，让后续增量操作持续命中同一日历槽位。
  private async applyDailyQuoteOperation(
    transaction: Prisma.TransactionClient,
    userId: string,
    operation: SyncOperationDto,
  ): Promise<number> {
    // 同一旧身份的映射在事务与服务重启后均保持有效。
    const alias = await transaction.dailyQuoteSelectionAlias.findUnique({
      where: { userId_recordId: { userId, recordId: operation.id } },
      include: { selection: true },
    });
    // 先按已知身份解析，避免相同身份被后续请求挪到另一天。
    let selection =
      alias?.selection ??
      (await transaction.dailyQuoteSelection.findFirst({
        where: { userId, id: operation.id },
      }));
    // 日历日期是槽位的业务身份，不接受增量修改。
    const dayKey = operation.data?.day_key;
    if (selection && dayKey !== undefined && dayKey !== selection.dayKey) {
      throw new ConflictException('日签身份不能改为其他日期');
    }
    if (operation.op === 'PUT' && !selection) {
      if (typeof dayKey !== 'string') {
        throw new BadRequestException('日签 PUT 必须包含 day_key');
      }
      selection = await transaction.dailyQuoteSelection.findUnique({
        where: { userId_dayKey: { userId, dayKey } },
      });
      if (selection) {
        await transaction.dailyQuoteSelectionAlias.create({
          data: { userId, recordId: operation.id, selectionId: selection.id },
        });
      }
    }
    if (operation.op === 'PUT' && selection) return 0;
    if (operation.op === 'DELETE' && !selection) return 0;
    if (operation.op === 'PATCH' && !selection) {
      throw new ConflictException({
        message: '更新目标不存在，需要先上传完整记录',
        code: 'SYNC_RECORD_MISSING',
        table: operation.table,
        id: operation.id,
      });
    }
    // 独立复制数据，保持回执对原始请求的摘要稳定。
    const data: Record<string, unknown> =
      operation.op === 'DELETE'
        ? { quote_id: null, updated_at: new Date().toISOString() }
        : { ...operation.data };
    if (
      typeof data.quote_id === 'string' &&
      (await this.wasDeleted(transaction, userId, 'quotes', data.quote_id))
    )
      data.quote_id = null;
    // DELETE 保留槽位和映射，旧客户端之后仍可通过原身份重新选择。
    const normalized: SyncOperationDto = {
      ...operation,
      id: selection?.id ?? operation.id,
      op: operation.op === 'DELETE' ? 'PATCH' : operation.op,
      data,
    };
    // 继续使用统一白名单和所有者过滤，不能写入其他所有者的槽位。
    const statement = this.sqlBuilder.build(normalized, userId);
    // 全局 UUID 碰撞不可当作日签合并成功，以免后续 PATCH 找不到目标。
    const affected = await transaction.$executeRawUnsafe(
      statement.sql,
      ...statement.values,
    );
    if (affected === 0)
      throw new ConflictException('日签身份冲突，请使用新的记录身份');
    return affected;
  }

  /// 查询记录是否已有永久删除墓碑。
  private async wasDeleted(
    transaction: Prisma.TransactionClient,
    userId: string,
    tableName: string,
    recordId: string,
  ): Promise<boolean> {
    return (
      (await transaction.syncTombstone.findUnique({
        where: { userId_tableName_recordId: { userId, tableName, recordId } },
      })) !== null
    );
  }

  /// 永久删除即使目标尚未上传，也必须记住其身份。
  private async rememberDeletion(
    transaction: Prisma.TransactionClient,
    userId: string,
    tableName: string,
    recordId: string,
  ): Promise<void> {
    await transaction.syncTombstone.upsert({
      where: { userId_tableName_recordId: { userId, tableName, recordId } },
      create: { userId, tableName, recordId },
      update: {},
    });
  }

  /// 检查显式关联是否指向已永久删除的父实体。
  private async hasDeletedParent(
    transaction: Prisma.TransactionClient,
    userId: string,
    operation: SyncOperationDto,
  ): Promise<boolean> {
    // 当前表受保护的关联列。
    const references = parentReferences[operation.table] ?? {};
    // 当前操作显式携带的引用。
    for (const [column, table] of Object.entries(references)) {
      // 可空关联值。
      const id = operation.data?.[column];
      if (
        typeof id === 'string' &&
        (await this.wasDeleted(transaction, userId, table, id))
      )
        return true;
    }
    return false;
  }
}
