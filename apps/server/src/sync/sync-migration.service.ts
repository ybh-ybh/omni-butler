import {
  BadRequestException,
  ConflictException,
  Injectable,
  Optional,
  ServiceUnavailableException,
} from '@nestjs/common';
import { createHash } from 'node:crypto';
import { AuthService } from '../auth/auth.service';
import type { Prisma, SyncMigrationReceipt } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import type {
  MigrationStatusDto,
  SyncMigrationDto,
} from './dto/sync-migration.dto';
import { reconcileSync, taxonomyRecordTables } from './sync-consistency';
import { SyncSqlBuilder, writableColumns } from './sync-sql.builder';
import { canonicalize } from './sync.service';
import { syncSchemaVersion } from './sync-schema';
import { NoteAudioStore } from '../notes/note-audio-store';

/// 客户端预检与服务端统一使用的快照上限。
const limits = { maxOperations: 100000, maxBytes: 33554432 } as const;
/// 必须包含在同一快照内的业务引用。
const references: Record<string, Record<string, string>> = {
  note_versions: { note_id: 'note_entries' },
  note_audio_segments: { note_id: 'note_entries' },
  note_images: { note_id: 'note_entries' },
  todo_items: { parent_id: 'todo_items' },
  todo_progress_steps: { todo_id: 'todo_items' },
  daily_quote_selections: { quote_id: 'quotes' },
  record_taxonomy_links: { taxonomy_id: 'taxonomy_entries' },
  event_completions: { event_id: 'events' },
  inventory_items: { parent_item_id: 'inventory_items' },
  membership_payments: { membership_id: 'memberships' },
};

/// 跨重建保留的迁移结果；superseded 不允许本地激活。
export interface MigrationResult {
  /// 当前回执是否仍属于目标最新数据集。
  status: 'committed' | 'superseded';
  /// 客户端迁移身份。
  migrationId: string;
  /// 此次提交生成的归属。
  ownerId: string;
  /// 规范化原始快照的摘要。
  payloadHash: string;
}

/// 隔离普通增量上传与显式全量覆盖语义。
@Injectable()
export class SyncMigrationService {
  /// 复用业务表列白名单，绝不允许客户端导入归属和凭证表。
  private readonly builder = new SyncSqlBuilder();

  /// 注入数据库与部署密钥验证服务。
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
    @Optional() private readonly audioStore?: NoteAudioStore,
  ) {}

  /// 在同一个一致视图中返回目标身份与各表数量。
  async preview(syncKey: string): Promise<{
    protocolVersion: number;
    snapshotVersion: number;
    syncSchemaVersion: number;
    ownerId: string;
    counts: Record<string, number>;
    deletedCount: number;
    limits: typeof limits;
  }> {
    this.auth.verifySyncKey(syncKey);
    return this.prisma.$transaction(
      async (transaction) => {
        // 与初始化和替换共享锁，避免预检看到重建前后混合身份。
        await transaction.$executeRaw`SELECT pg_advisory_xact_lock(1573090401)`;
        // 当前单人部署所有者。
        const owner = await transaction.syncOwner.findFirst();
        if (!owner)
          throw new ServiceUnavailableException('同步服务尚未完成初始化');
        await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id = ${owner.id}::uuid FOR UPDATE`;
        // 固定白名单业务表的数量。
        const counts: Record<string, number> = {};
        // 快照范围内处于回收站的行数。
        let deletedCount = 0;
        for (const [table, columns] of Object.entries(writableColumns)) {
          // 所有动态标识符均来自静态代码白名单。
          const rows = await transaction.$queryRawUnsafe<
            { count: bigint; deleted: bigint }[]
          >(
            `SELECT count(*) AS count, ${columns.has('deleted_at') ? 'count(*) FILTER (WHERE deleted_at IS NOT NULL)' : '0::bigint'} AS deleted FROM "${table}" WHERE user_id = $1::uuid`,
            owner.id,
          );
          counts[table] = Number(rows[0]!.count);
          // 步骤只随任务展示，不能作为独立回收站记录计数。
          if (table !== 'todo_progress_steps' && table !== 'note_images') {
            deletedCount += Number(rows[0]!.deleted);
          }
        }
        return {
          protocolVersion: 1,
          snapshotVersion: 3,
          syncSchemaVersion,
          ownerId: owner.id,
          counts,
          deletedCount,
          limits,
        };
      },
      { maxWait: 30000, timeout: 60000 },
    );
  }

  /// 查询结果也使用同一事务锁，提交中的请求完成后才返回确定视图。
  async status(
    input: MigrationStatusDto,
  ): Promise<MigrationResult | { status: 'notFound'; migrationId: string }> {
    this.auth.verifySyncKey(input.syncKey);
    return this.prisma.$transaction(
      async (transaction) => {
        await transaction.$executeRaw`SELECT pg_advisory_xact_lock(1573090401)`;
        // 不依赖已撤销会话或已删除 owner 的持久回执。
        const receipt = await transaction.syncMigrationReceipt.findUnique({
          where: { migrationId: input.migrationId },
        });
        return receipt
          ? this.result(transaction, receipt)
          : { status: 'notFound' as const, migrationId: input.migrationId };
      },
      { maxWait: 30000, timeout: 60000 },
    );
  }

  /// 原子替换 owner 和全部业务数据，任何错误均保留原服务端快照。
  async replace(input: SyncMigrationDto): Promise<MigrationResult> {
    this.auth.verifySyncKey(input.syncKey);
    this.validateSnapshot(input);
    // 摘要包含目标身份与版本，拒绝同迁移身份改变请求意图。
    const payloadHash = createHash('sha256')
      .update(
        JSON.stringify(
          canonicalize({
            expectedOwnerId: input.expectedOwnerId,
            snapshotVersion: input.snapshotVersion,
            operations: input.operations,
            ...(input.snapshotVersion === 3 ? { omittedAudioIds: input.omittedAudioIds ?? [] } : {}),
          }),
        ),
      )
      .digest('hex');
    return this.prisma.$transaction(
      async (transaction) => {
        await transaction.$executeRaw`SELECT pg_advisory_xact_lock(1573090401)`;
        // 必须在锁内查回执，涵盖并发同身份请求及提交成功后响应丢失。
        const receipt = await transaction.syncMigrationReceipt.findUnique({
          where: { migrationId: input.migrationId },
        });
        if (receipt) {
          if (receipt.payloadHash !== payloadHash)
            throw new ConflictException({
              code: 'MIGRATION_CONTENT_CHANGED',
              message: '同一迁移身份不能用于不同快照',
            });
          return this.result(transaction, receipt);
        }
        // 与普通增量事务使用相同行锁，等待已开始的写入完成。
        const owners = await transaction.$queryRaw<
          { id: string }[]
        >`SELECT id FROM sync_owners WHERE id = ${input.expectedOwnerId}::uuid FOR UPDATE`;
        if (owners.length !== 1)
          throw new ConflictException({
            code: 'SYNC_OWNER_CHANGED',
            message: '目标服务器数据归属已改变，请重新预检',
          });
        // 覆盖前验证全部非省略原音，缺失文件不得删除当前快照。
        const audioOperations = input.operations.filter((operation) => operation.table === 'note_audio_segments');
        // 用户已明确接受不完整迁移的原音身份。
        const omitted = new Set((input.omittedAudioIds ?? []).map((id) => id.toLowerCase()));
        // 完整暂存文件仅在此原子事务内被新归属接管。
        const staged = await transaction.noteAudioStaging.findMany({ where: { migrationId: input.migrationId } });
        for (const operation of audioOperations) {
          if (omitted.has(operation.id.toLowerCase())) continue;
          // 一段音频必须有同身份、摘要、大小和 MIME 的真实文件。
          const asset = staged.find((candidate) => candidate.segmentId.toLowerCase() === operation.id.toLowerCase());
          if (!asset || asset.sha256 !== operation.data!.sha256 || asset.byteSize !== operation.data!.byte_size || asset.mime !== operation.data!.mime) throw new BadRequestException({ code: 'NOTE_AUDIO_STAGE_MISSING', message: '迁移原音未暂存或文件校验不匹配', segmentId: operation.id });
          // 覆盖前再次读取真实文件，暂存回执不能替代文件存在和完整性证据。
          const bytes = await this.audioStore?.get(asset.objectKey).catch(() => undefined);
          if (!bytes || bytes.length !== asset.byteSize || createHash('sha256').update(bytes).digest('hex') !== asset.sha256) throw new BadRequestException({ code: 'NOTE_AUDIO_STAGE_CORRUPTED', message: '迁移原音文件丢失或校验失败', segmentId: operation.id });
        }
        await transaction.syncOwner.delete({
          where: { id: input.expectedOwnerId },
        });
        // 新 owner 同时隔离旧设备、墓碑、回执和 PowerSync 下行流。
        const owner = await transaction.syncOwner.create({ data: {} });
        for (const operation of input.operations) {
          // 全量快照已验证同表身份不重复，任何插入忽略均为异常。
          const statement = this.builder.build(operation, owner.id);
          // 导入保留原业务身份和事实字段，不使用日签旧身份合并规则。
          const affected = await transaction.$executeRawUnsafe(
            statement.sql,
            ...statement.values,
          );
          if (affected !== 1) throw new ConflictException('快照记录身份冲突');
        }
        for (const operation of audioOperations) {
          if (omitted.has(operation.id.toLowerCase())) continue;
          // 元数据插入完成后关联不可变真实文件。
          const asset = staged.find((candidate) => candidate.segmentId.toLowerCase() === operation.id.toLowerCase())!;
          await transaction.noteAudioAsset.create({ data: { userId: owner.id, segmentId: operation.id, objectKey: asset.objectKey } });
        }
        // 删除暂存回执不删除已被新资产引用的文件。
        await transaction.noteAudioStaging.deleteMany({ where: { migrationId: input.migrationId } });
        await reconcileSync(transaction, owner.id, input.operations);
        // 在保存回执前主动检查全部延迟外键。
        await transaction.$executeRawUnsafe('SET CONSTRAINTS ALL IMMEDIATE');
        // 回执与业务写入原子提交；不保存任何明文设备凭证。
        const committed = await transaction.syncMigrationReceipt.create({
          data: {
            migrationId: input.migrationId,
            expectedOwnerId: input.expectedOwnerId,
            ownerId: owner.id,
            payloadHash,
          },
        });
        return this.result(transaction, committed);
      },
      { maxWait: 30000, timeout: 60000 },
    );
  }

  /// 验证完整列、重复身份、引用闭包与请求大小，空快照合法。
  private validateSnapshot(input: SyncMigrationDto): void {
    if (
      ![2, 3].includes(input.snapshotVersion) ||
      input.operations.length > limits.maxOperations ||
      Buffer.byteLength(JSON.stringify(input), 'utf8') > limits.maxBytes
    )
      throw new BadRequestException({
        code: 'SNAPSHOT_LIMIT_EXCEEDED',
        message: '快照版本或大小不受支持',
      });
    if (input.snapshotVersion === 2 && (input.operations.some((operation) => operation.table.startsWith('note_')) || (input.omittedAudioIds?.length ?? 0) > 0)) throw new BadRequestException('笔记原音迁移需要快照协议 v3');
    // 省略原音必须明确指向本次快照中的段，不能误拼导致静默丢附件。
    const audioIdentities = new Set(input.operations.filter((operation) => operation.table === 'note_audio_segments').map((operation) => operation.id.toLowerCase()));
    // 相同 UUID 大小写也视作重复省略。
    const omitted = (input.omittedAudioIds ?? []).map((id) => id.toLowerCase());
    if (new Set(omitted).size !== omitted.length || omitted.some((id) => !audioIdentities.has(id))) throw new BadRequestException('省略原音清单不是本次快照的有效段子集');
    // 已声明的同表业务身份。
    const identities = new Map<string, Record<string, unknown>>();
    for (const operation of input.operations) {
      this.builder.build(operation, input.expectedOwnerId);
      if (operation.op !== 'PUT')
        throw new BadRequestException('快照只允许完整 PUT');
      // 静态字段白名单同时定义快照完整行协议。
      const columns = writableColumns[operation.table]!;
      // v3 历史笔记允许缺失新增元数据，数据库默认保留未知时间与未置顶。
      const requiredColumns = [...columns].filter((column) => {
        if (operation.table !== 'note_entries') return true;
        if (column === 'is_pinned') return Object.hasOwn(operation.data ?? {}, column);
        if (column === 'record_time_seconds' || column === 'record_utc_offset_minutes') {
          return Object.hasOwn(operation.data ?? {}, 'record_time_seconds') ||
            Object.hasOwn(operation.data ?? {}, 'record_utc_offset_minutes');
        }
        return true;
      });
      if (
        !operation.data ||
        requiredColumns.length !== Object.keys(operation.data).length ||
        requiredColumns.some(
          (column) =>
            !Object.hasOwn(operation.data!, column) ||
            operation.data![column] === undefined,
        )
      )
        throw new BadRequestException(
          `快照记录必须包含 ${operation.table} 的全部同步字段`,
        );
      // UUID 不区分大小写，与数据库身份判定保持一致。
      const identity = `${operation.table}:${operation.id.toLowerCase()}`;
      if (identities.has(identity))
        throw new BadRequestException('快照包含重复记录身份');
      identities.set(identity, operation.data);
    }
    for (const operation of input.operations) {
      if (operation.table === 'record_taxonomy_links') {
        // 多态业务引用没有数据库外键，必须显式检查模块与业务记录闭包。
        const module = operation.data!.module;
        // 仅接受客户端已定义的模块名称。
        const table =
          typeof module === 'string' &&
          Object.hasOwn(taxonomyRecordTables, module)
            ? taxonomyRecordTables[module]
            : undefined;
        // 该标签关系指向的业务记录身份。
        const recordId = operation.data!.record_id;
        // 标签本身也必须属于同一业务模块。
        const taxonomyId = operation.data!.taxonomy_id;
        if (
          !table ||
          typeof recordId !== 'string' ||
          !identities.has(`${table}:${recordId.toLowerCase()}`) ||
          typeof taxonomyId !== 'string' ||
          identities.get(`taxonomy_entries:${taxonomyId.toLowerCase()}`)
            ?.module !== module
        ) {
          throw new BadRequestException(
            '快照标签关联缺少同模块的业务记录或标签',
          );
        }
      }
      for (const [column, table] of Object.entries(
        references[operation.table] ?? {},
      )) {
        // 可空关联为空时无需父记录，其余关联必须在本次快照内。
        const id = operation.data![column];
        if (
          id !== null &&
          (typeof id !== 'string' ||
            !identities.has(`${table}:${id.toLowerCase()}`))
        )
          throw new BadRequestException(
            `快照引用缺失：${operation.table}.${column}`,
          );
      }
    }
  }

  /// 旧回执保留原结果身份，但标明已经被后续覆盖替代。
  private async result(
    transaction: Prisma.TransactionClient,
    receipt: SyncMigrationReceipt,
  ): Promise<MigrationResult> {
    // 当前归属是否仍为该次迁移生成的归属。
    const owner = await transaction.syncOwner.findUnique({
      where: { id: receipt.ownerId },
    });
    return {
      status: owner ? 'committed' : 'superseded',
      migrationId: receipt.migrationId,
      ownerId: receipt.ownerId,
      payloadHash: receipt.payloadHash,
    };
  }
}
