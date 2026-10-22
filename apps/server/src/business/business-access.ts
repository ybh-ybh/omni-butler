import {
  ConflictException,
  BadRequestException,
  NotFoundException,
  UnauthorizedException,
} from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import { AsyncLocalStorage } from 'node:async_hooks';
import type { AuthUser } from '../auth/auth.types';
import type { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { canonicalize } from '../sync/sync.service';
import { idsInput, taxonomyTextInput, uuidInput } from './business-input';

/// 已锁定的业务事务只在当前异步调用链内复用，避免审批与副作用分开提交。
const businessContext = new AsyncLocalStorage<{
  prisma: PrismaService;
  owner: string;
  transaction: Prisma.TransactionClient;
}>();

/// 审批提交及预览回滚复用业务方法，身份和 owner 锁仍由既有规则校验。
export async function withinBusinessTransaction<T>(
  prisma: PrismaService,
  actor: AuthUser,
  action: (transaction: Prisma.TransactionClient) => Promise<T>,
): Promise<T> {
  if (!actor || actor.typ !== 'access')
    throw new UnauthorizedException('需要有效设备身份');
  uuidInput(actor.sub, 'owner');
  return prisma.$transaction(
    async (transaction) => {
      await transaction.$queryRaw`SELECT id FROM sync_owners WHERE id=${actor.sub}::uuid FOR UPDATE`;
      await authorize(transaction, actor);
      return businessContext.run(
        { prisma, owner: actor.sub, transaction },
        () => action(transaction),
      );
    },
    { maxWait: 30000, timeout: 60000 },
  );
}

/// 在 JSON 结果中统一日期及大整数，重放与首次响应形状一致。
function jsonResult(value: unknown): Prisma.JsonValue {
  return JSON.parse(
    JSON.stringify(value, (_key: string, item: unknown) =>
      typeof item === 'bigint' ? item.toString() : item,
    ),
  ) as Prisma.JsonValue;
}

/// 每次服务内调用都校验当前设备会话，不能仅相信对象形状。
async function authorize(
  transaction: Prisma.TransactionClient,
  actor: AuthUser,
): Promise<void> {
  if (!actor || actor.typ !== 'access')
    throw new UnauthorizedException('需要有效设备身份');
  uuidInput(actor.sub, 'owner');
  uuidInput(actor.sid, 'session');
  // 会话事实在执行事务中重新读取，撤权和换服后旧调用失效。
  const session = await transaction.deviceSession.findFirst({
    where: { id: actor.sid, userId: actor.sub, expiresAt: { gt: new Date() } },
  });
  if (!session) throw new UnauthorizedException('设备会话已失效');
}

/// 两个以上调用方共用的只读事务；重复读取看到同一快照。
export async function businessRead(
  prisma: PrismaService,
  actor: AuthUser,
  read: (transaction: Prisma.TransactionClient) => Promise<unknown>,
): Promise<Prisma.JsonValue> {
  // 同一审批事务内的领域查询看到尚未提交的同批结果。
  const context = businessContext.getStore();
  if (context?.prisma === prisma && context.owner === actor.sub) {
    await authorize(context.transaction, actor);
    return jsonResult(await read(context.transaction));
  }
  return prisma.$transaction(
    async (transaction) => {
      await authorize(transaction, actor);
      return jsonResult(await read(transaction));
    },
    { isolationLevel: 'RepeatableRead' },
  );
}

/// 业务写入共用现有 owner 锁；回执与副作用同事务，不冒用同步身份。
export async function businessWrite(
  prisma: PrismaService,
  actor: AuthUser,
  action: string,
  input: Record<string, unknown>,
  write: (transaction: Prisma.TransactionClient) => Promise<unknown>,
): Promise<Prisma.JsonValue> {
  // 操作身份在调用前生成，并在网络重试中保持不变。
  const operationId = uuidInput(input.operationId, 'operationId');
  if (!actor) throw new UnauthorizedException('需要有效设备身份');
  uuidInput(actor.sub, 'owner');
  // 摘要只覆盖真实业务参数；不修改请求来适配旧协议。
  const payloadHash = createHash('sha256')
    .update(JSON.stringify(canonicalize({ action, input })))
    .digest('hex');
  // 独立调用和审批事务内调用走相同的授权及回执代码。
  const execute = async (
    transaction: Prisma.TransactionClient,
  ): Promise<Prisma.JsonValue> => {
    // 与离线写入采用相同 owner 锁，聚合操作不会互相交叉执行。
    const owners = await transaction.$queryRaw<
      Array<{ id: string }>
    >`SELECT id FROM sync_owners WHERE id=${actor.sub}::uuid FOR UPDATE`;
    if (!owners.length) throw new UnauthorizedException('数据归属已失效');
    await authorize(transaction, actor);
    // 全 owner 共用操作身份，不允许跨业务挪用同一个身份。
    const identity = { userId: actor.sub, operationId };
    // 已提交的原结果可在记录后来编辑或删除后安全重放。
    const receipt = await transaction.businessOperationReceipt.findUnique({
      where: { userId_operationId: identity },
    });
    if (receipt) {
      if (receipt.action !== action || receipt.payloadHash !== payloadHash)
        throw new ConflictException({
          code: 'BUSINESS_OPERATION_CONFLICT',
          message: '同一操作身份不能提交不同业务内容',
        });
      return receipt.result;
    }
    // 首次结果也先转换为 JSON，避免重放日期类型不同。
    const result = jsonResult(await write(transaction));
    await transaction.businessOperationReceipt.create({
      data: {
        ...identity,
        action,
        payloadHash,
        result: result as Prisma.InputJsonValue,
      },
    });
    return result;
  };
  // 审批、领域副作用和业务回执必须共用一个真实数据库事务。
  const context = businessContext.getStore();
  if (context?.prisma === prisma && context.owner === actor.sub)
    return execute(context.transaction);
  return prisma.$transaction(execute, { maxWait: 30000, timeout: 60000 });
}

/// 找不到或属于其他归属时返回相同错误，不泄露记录存在性。
export function requireActive<T extends { deletedAt: Date | null }>(
  record: T | null,
): T {
  if (!record || record.deletedAt !== null)
    throw new NotFoundException('记录不存在或已删除');
  return record;
}

/// 兼容名称与规范ID采用单一选择，缺省保留；名称清空或无匹配时解除旧关系。
export async function resolveNamedTaxonomy(
  transaction: Prisma.TransactionClient,
  userId: string,
  module: string,
  kind: 'category' | 'location',
  input: Record<string, unknown>,
): Promise<{ ids: string[]; name: string | null } | null> {
  // 现有业务使用复数ID字段支持多选，兼容文字字段只表达一个旧名称。
  const idField = `${kind}Ids`;
  if (input[idField] !== undefined && input[kind] !== undefined)
    throw new BadRequestException(`${idField} 与 ${kind} 不能同时提供`);
  if (input[idField] === undefined && input[kind] === undefined) return null;
  if (input[idField] !== undefined) {
    // 身份归属、模块、类型与有效状态均在当前写事务内核验。
    const ids = idsInput(input[idField], idField);
    // 使用稳定顺序维护兼容展示名称，不能采用模型额外提交的名字。
    const entries = await transaction.taxonomyEntry.findMany({
      where: {
        userId,
        module,
        kind,
        id: { in: ids },
        deletedAt: null,
        isEnabled: true,
      },
      orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
    });
    if (entries.length !== ids.length)
      throw new ConflictException('分类或位置不存在、已失效或类型不匹配');
    return { ids, name: entries.map((entry) => entry.name).join(',') || null };
  }
  // 原有自由名称兼容保留，但不能遗留指向其他分类的旧关联。
  const name = taxonomyTextInput(input[kind], kind);
  if (name === null) return { ids: [], name: null };
  // 最多读取两个匹配项即可判定歧义，不能静默选择同名记录。
  const matches = await transaction.taxonomyEntry.findMany({
    where: {
      userId,
      module,
      kind,
      name: { equals: name, mode: 'insensitive' },
      deletedAt: null,
      isEnabled: true,
    },
    take: 2,
  });
  if (matches.length > 1)
    throw new ConflictException('分类或位置名称重名，请查询并使用明确ID');
  return {
    ids: matches.map((entry) => entry.id),
    name: matches[0]?.name ?? name,
  };
}

/// 关系替换与业务保存处于同一事务，关联必须有效且属于相同模块/类型。
export async function replaceTaxonomies(
  transaction: Prisma.TransactionClient,
  userId: string,
  module: string,
  recordId: string,
  selected: Record<string, string[]>,
): Promise<void> {
  // 每类引用分别校验，不能用位置 ID 冒充分类。
  for (const [kind, ids] of Object.entries(selected)) {
    if (
      ids.length !==
      (await transaction.taxonomyEntry.count({
        where: {
          userId,
          id: { in: ids },
          module,
          kind,
          deletedAt: null,
          isEnabled: true,
        },
      }))
    )
      throw new ConflictException('分类或位置不存在、已失效或类型不匹配');
  }
  // 只替换本次明确选择的关系种类，其他关系保持。
  const prior = await transaction.recordTaxonomyLink.findMany({
    where: { userId, module, recordId, deletedAt: null },
    include: { taxonomy: true },
  });
  // 同时软删除历史关系，保留离线恢复所需事实。
  const now = new Date();
  await transaction.recordTaxonomyLink.updateMany({
    where: {
      userId,
      id: {
        in: prior
          .filter((link) => Object.hasOwn(selected, link.taxonomy.kind))
          .map((link) => link.id),
      },
    },
    data: { deletedAt: now },
  });
  for (const ids of Object.values(selected))
    for (const taxonomyId of ids)
      await transaction.recordTaxonomyLink.create({
        data: {
          id: randomUUID(),
          userId,
          module,
          recordId,
          taxonomyId,
          createdAt: now,
        },
      });
}
