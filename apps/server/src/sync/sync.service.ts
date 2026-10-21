import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
  UnauthorizedException,
} from '@nestjs/common';
import { createHash } from 'node:crypto';
import { stableBusinessId } from './sync-consistency';
import { checkSyncBaseline, SyncBaselineConflict, syncCurrentRecords, syncFactsHash, type SyncWriteConflict } from './sync-write-conflicts';
import { canonicalize } from './sync-hash';
export { canonicalize } from './sync-hash';
import type { Prisma } from '../generated/prisma/client';
import type { AuthUser } from '../auth/auth.types';
import { uuidInput } from '../business/business-input';
import { PrismaService } from '../prisma/prisma.service';
import type { SyncBatchDto } from './dto/sync-batch.dto';
import type { SyncOperationDto } from './dto/sync-operation.dto';
import {
  normalizeAutomaticRenewalPatch,
  reconcileSync,
  taxonomyRecordTables,
} from './sync-consistency';
import { SyncSqlBuilder } from './sync-sql.builder';
import { normalizeNoteOperation, validateNoteTagOperation } from './note-sync';
import { isRetiredNoteCategory, retireNoteCategoryOperation } from './note-category-retirement';

/// 同步操作引用的业务父表，用于处理永久删除后的迟到写入。
const parentReferences: Readonly<Record<string, Record<string, string>>> = {
  note_versions: { note_id: 'note_entries' },
  note_audio_segments: { note_id: 'note_entries' },
  note_images: { note_id: 'note_entries' },
  todo_items: { parent_id: 'todo_items' },
  todo_progress_steps: { todo_id: 'todo_items' },
  record_taxonomy_links: { taxonomy_id: 'taxonomy_entries' },
  event_completions: { event_id: 'events' },
  inventory_items: { parent_item_id: 'inventory_items' },
  membership_payments: { membership_id: 'memberships' },
};

/// 原始客户端事务的持久化处理结果。
export interface SyncResult {
  /// 原事务已作为冲突候选保存，但客户端不得确认其队列直到用户明确处理。
  conflict?: { id: string; status: string; message: string };
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
  async applyBatch(userId: string, batch: SyncBatchDto, suppliedTransaction?: Prisma.TransactionClient, cascadeApproved = false): Promise<SyncResult> {
    // 写入之前校验全部表和列，避免忽略路径绕过白名单。
    for (const operation of batch.operations) {
      // 执行副本丢弃已退休类别，原始负载保持用于旧回执重放。
      const retired = retireNoteCategoryOperation(operation);
      if (retired !== null) this.sqlBuilder.build(validateNoteTagOperation(retired), userId);
    }
    // 操作摘要用于拒绝复用事务身份提交不同内容。
    const payloadHash = createHash('sha256')
      .update(JSON.stringify(canonicalize(batch.operations.map((operation) => {
        // 基线为新增协议元数据；原业务负载摘要保持旧格式，升级后的未知提交可重放旧回执。
        const original = { ...operation };
        delete original.previous;
        return original;
      }))))
      .digest('hex');
    // 人工冲突决策可复用同一真实事务，其他入口仍由此处建立事务。
    const execute = async (transaction: Prisma.TransactionClient): Promise<SyncResult> => {
        // 单人多设备事务按归属串行提交，保证派生数据和回执一致。
        // 加锁后再次确认归属，拒绝认证完成之后发生重建的旧请求。
        const owners = await transaction.$queryRaw<
          { id: string }[]
        >`SELECT id FROM sync_owners WHERE id = ${userId}::uuid FOR UPDATE`;
        if (owners.length === 0) {
          throw new ConflictException({
            code: 'SYNC_OWNER_CHANGED',
            message: '服务器数据归属已改变，请重新连接',
          });
        }
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
            ...(receipt.conflict && (receipt.conflict as unknown as SyncWriteConflict).status === 'pending' ? { conflict: { id: (receipt.conflict as unknown as SyncWriteConflict).id, status: 'pending', message: '离线修改与服务器记录冲突，请在设置的数据同步中处理；本机事务尚未确认' } } : {}),
          };
        }
        // 实际变化的操作交由派生状态协调器处理。
        const changedOperations: SyncOperationDto[] = [];
        // 当前事务实际写入数量。
        let applied = 0;
        // 当前事务忽略的已删除或重复创建数量。
        let ignored = 0;
        // 候选保留完整原事务；任何一步冲突都不能提交前面的部分写入。
        await transaction.$executeRawUnsafe('SAVEPOINT sync_baseline_batch');
        try {
        // 保留客户端原始事务顺序。
        for (const original of batch.operations) {
          // 旧类别操作只在当前事务的执行副本中退休。
          const operation = retireNoteCategoryOperation(original);
          if (operation === null) {
            ignored += 1;
            continue;
          }
          await checkSyncBaseline(transaction, userId, operation, cascadeApproved);
          if (isRetiredNoteCategory(original)) {
            // 身份碰撞不能让退休的旧 PUT 删除同 ID 的有效标签或其他模块类别。
            const current = await transaction.taxonomyEntry.findFirst({
              where: { userId, id: original.id },
              select: { module: true, kind: true },
            });
            if (current && (current.module !== 'notes' || current.kind !== 'category')) {
              throw new ConflictException('退休笔记类别的身份与有效分类标签冲突');
            }
          }
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
          await this.validateProgressIdentity(transaction, userId, operation);
          // 自动续费只允许推进账期，人工编辑保持原意。
          const renewed = await normalizeAutomaticRenewalPatch(
            transaction,
            userId,
            operation,
            batch.operations,
          );
          // 笔记保留所有候选，仅基线匹配的正文允许替换当前修订。
          const normalized = await normalizeNoteOperation(transaction, userId, renewed);
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
        } catch (error) {
          if (!(error instanceof SyncBaselineConflict)) throw error;
          await transaction.$executeRawUnsafe('ROLLBACK TO SAVEPOINT sync_baseline_batch');
          // 复用原事务回执持久保存候选，不把业务冲突冒充已应用或忽略。
          const conflict: SyncWriteConflict = { id: stableBusinessId('sync-write-conflict', [batch.clientId, batch.transactionId]), status: 'pending', createdAt: new Date().toISOString(), operations: batch.operations, reason: error.detail };
          await transaction.syncReceipt.create({ data: { ...identity, payloadHash, applied: 0, ignored: 0, conflict: JSON.parse(JSON.stringify(conflict)) as Prisma.InputJsonValue } });
          return { applied: 0, ignored: 0, replayed: false, conflict: { id: conflict.id, status: 'pending', message: '离线修改与服务器记录冲突，请在设置的数据同步中处理；本机事务尚未确认' } };
        }
        await transaction.syncReceipt.create({
          data: { ...identity, payloadHash, applied, ignored },
        });
        return { applied, ignored, replayed: false };
      };
    return suppliedTransaction ? execute(suppliedTransaction) : this.prisma.$transaction(execute, { maxWait: 30000, timeout: 60000 });
  }

  /// 未处理候选独立于调试日志保留，普通查询只返回摘要。
  async listWriteConflicts(userId: string): Promise<Record<string, unknown>> {
    // 数据归属来自JWT，不允许模型/客户端表单提供。
    const receipts = await this.prisma.syncReceipt.findMany({ where: { userId, conflict: { path: ['status'], equals: 'pending' } }, take: 200, orderBy: [{ clientId: 'asc' }, { transactionId: 'asc' }] });
    return { items: receipts.map((receipt) => {
      // 原负载/正文仅在用户显式打开完整预览后读取。
      const conflict = receipt.conflict as unknown as SyncWriteConflict;
      return { id: conflict.id, status: conflict.status, reason: conflict.reason, createdAt: conflict.createdAt, operationCount: conflict.operations.length };
    }), limit: 200, message: '未处理事务保留在原设备队列；选择后才允许确认该事务，其他后续事务可能也需要逐项核对' };
  }

  /// 完整原事务与当前服务器事实同时展示，基线摘要在用户阅读时固定。
  async getWriteConflict(userId: string, id: string): Promise<Record<string, unknown>> {
    // 同归属动作才可查看；ID不是授权凭据。
    const receipt = await this.prisma.syncReceipt.findFirst({ where: { userId, conflict: { path: ['id'], equals: id } } });
    if (!receipt?.conflict) throw new NotFoundException('同步冲突不存在');
    // 私有回执记录中的原事务不可由调用方替换。
    const conflict = receipt.conflict as unknown as SyncWriteConflict;
    // 当前事实读取在单一重复读快照中，不以最初冲突时旧值代替。
    const records = await this.prisma.$transaction((transaction) => syncCurrentRecords(transaction, userId, conflict.operations), { isolationLevel: 'RepeatableRead' });
    return { ...conflict, currentRecords: records, baselineHash: syncFactsHash(records), decisions: { server: '保留服务器值，原设备确认这笔队列后采用服务器下行；原候选仍留审计', local: '明确重新提交这笔完整本机事务，沿用领域规则及笔记修订/候选规则，不绕过永久墓碑或把新增变成更新' } };
  }

  /// 人工决策固定当前事实，响应丢失后以同requestId返回原处理结果。
  async resolveWriteConflict(actor: AuthUser, id: string, value: unknown): Promise<unknown> {
    // 此路径仅从已认证设备调用，不向MCP暴露自行批准工具。
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BadRequestException('需要完整冲突决策');
    // 明确白名单字段，不接受新的业务参数或任意SQL。
    const input = value as Record<string, unknown>;
    if (Object.keys(input).some((key) => !['requestId', 'decision', 'baselineHash'].includes(key)) || typeof input.requestId !== 'string' || !/^[0-9a-f-]{36}$/i.test(input.requestId) || typeof input.baselineHash !== 'string' || !/^[0-9a-f]{64}$/.test(input.baselineHash) || !['server', 'local'].includes(String(input.decision))) throw new BadRequestException('冲突决策参数不完整或非法');
    // 决策身份绑定内容，不能重放成另一项处理。
    const resolutionHash = syncFactsHash(input);
    // 严格UUID身份在异步事务闭包中保持类型及内容固定。
    const requestId = uuidInput(input.requestId, 'requestId');
    return this.prisma.$transaction(async (transaction) => {
      await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id=${actor.sub}::uuid FOR UPDATE`;
      if (!(await transaction.deviceSession.findFirst({ where: { id: actor.sid, userId: actor.sub, expiresAt: { gt: new Date() } } }))) throw new UnauthorizedException('审批设备会话已失效');
      // owner锁保证两个设备不会同时处理同一候选。
      const receipt = await transaction.syncReceipt.findFirst({ where: { userId: actor.sub, conflict: { path: ['id'], equals: id } } });
      if (!receipt?.conflict) throw new NotFoundException('同步冲突不存在');
      // 原事务和原回执身份不更改，决策执行有自己的新身份。
      const conflict = receipt.conflict as unknown as SyncWriteConflict;
      if (conflict.resolution) {
        if (conflict.resolution.hash !== resolutionHash) throw new ConflictException('该同步冲突已经处理，请查看原结果');
        return conflict.resolution.result;
      }
      // 用户打开预览后若服务器发生变化，必须重读后重新明确选择。
      const records = await syncCurrentRecords(transaction, actor.sub, conflict.operations);
      if (syncFactsHash(records) !== input.baselineHash) throw new ConflictException('服务器数据又有变化，请重新核对冲突预览');
      // 原操作完整保留，不在上传重试时偷偷重新构造基线。
      let applied: SyncResult | null = null;
      if (input.decision === 'local') {
        // 同事务内逐步推演前值，多次编辑同一记录时保留原始顺序。
        const current = new Map(records.map((row) => [`${row.table}/${row.id}`, row.data]));
        // 只有明确人工决策才用刚展示的服务器事实作为新基线。
        const operations = conflict.operations.map((operation) => {
          // 基线草稿只属于本次已批准的决策事务。
          const key = `${operation.table}/${operation.id}`, before = current.get(key) ?? null;
          // PATCH的后续步骤相对于前一步结果，不相对于服务器最初快照。
          const resolved: SyncOperationDto = { ...operation, ...(before ? { previous: { ...before } } : {}) };
          if (operation.op === 'PATCH' && before) current.set(key, { ...before, ...operation.data });
          if (operation.op === 'PUT' && !before) current.set(key, { ...operation.data });
          if (operation.op === 'DELETE') current.set(key, null);
          return resolved;
        });
        applied = await this.applyBatch(actor.sub, { clientId: receipt.clientId, transactionId: `conflict-resolution:${requestId}`, operations }, transaction, true);
        if (applied.conflict) throw new ConflictException('此事务仍有冲突，请重新核对或采用服务器结果');
      } else {
        // 重新发布当前事实，让原设备在明确确认队列后取得权威下行；不改变业务字段。
        for (const record of records) if (record.data) await transaction.$executeRawUnsafe(`UPDATE "${record.table}" SET id=id WHERE user_id=$1::uuid AND id=$2::uuid`, actor.sub, record.id);
      }
      // 原候选永久保留原意图，决策完成后上传重放才允许确认原队列。
      const result = { id, status: input.decision, resolvedAt: new Date().toISOString(), applied, message: input.decision === 'local' ? '已按明确选择重新提交；笔记正文仍遵守修订/候选规则' : '已选择服务器数据；原设备下一次重试后确认原队列并接收下行', syncStatus: '服务器已处理，原设备队列与客户端下行状态待核实' };
      conflict.status = input.decision as 'local' | 'server';
      conflict.resolution = { requestId, hash: resolutionHash, resolvedAt: result.resolvedAt, result };
      await transaction.syncReceipt.update({ where: { userId_clientId_transactionId: { userId: actor.sub, clientId: receipt.clientId, transactionId: receipt.transactionId } }, data: { conflict: JSON.parse(JSON.stringify(conflict)) as Prisma.InputJsonValue } });
      return result;
    }, { maxWait: 30000, timeout: 60000 });
  }

  /// 已保存任务不转换类型，步骤稳定身份也不能转移到另一个任务。
  private async validateProgressIdentity(
    transaction: Prisma.TransactionClient,
    userId: string,
    operation: SyncOperationDto,
  ): Promise<void> {
    if (operation.op !== 'PATCH') return;
    if (
      operation.table === 'todo_items' &&
      operation.data?.task_type !== undefined
    ) {
      // owner 锁内读取最新类型，允许完整 PATCH 重复携带原类型。
      const current = await transaction.todoItem.findFirst({
        where: { userId, id: operation.id },
        select: { taskType: true },
      });
      if (current && current.taskType !== operation.data.task_type) {
        throw new BadRequestException('已保存任务不能转换类型');
      }
    }
    if (
      operation.table === 'todo_progress_steps' &&
      operation.data?.todo_id !== undefined
    ) {
      // 步骤的归属固定，避免旧面板操作意外修改另一个任务。
      const current = await transaction.todoProgressStep.findFirst({
        where: { userId, id: operation.id },
        select: { todoId: true },
      });
      if (current && current.todoId !== operation.data.todo_id) {
        throw new BadRequestException('已保存步骤不能转移到其他任务');
      }
    }
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
    if (operation.table === 'record_taxonomy_links') {
      // PATCH 可能省略未变的模块和记录身份，必须结合当前行检查。
      const current = operation.op === 'PATCH' ? await transaction.recordTaxonomyLink.findFirst({ where: { userId, id: operation.id } }) : null;
      // 多态父关系由固定模块映射决定，不能当成任意表名。
      const module = operation.data?.module ?? current?.module;
      // 关联目标的永久墓碑优先于迟到绑定。
      const recordId = operation.data?.record_id ?? current?.recordId;
      if (typeof module === 'string' && Object.hasOwn(taxonomyRecordTables, module) && typeof recordId === 'string' && await this.wasDeleted(transaction, userId, taxonomyRecordTables[module]!, recordId)) return true;
    }
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
