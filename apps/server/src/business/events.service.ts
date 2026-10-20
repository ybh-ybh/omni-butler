import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../auth/auth.types';
import type { Event, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  reconcileEventCompletions,
  stableBusinessId,
} from '../sync/sync-consistency';
import { businessRead, businessWrite, requireActive } from './business-access';
import {
  addMonths,
  booleanInput,
  enumInput,
  instantInput,
  integerInput,
  localInstant,
  localParts,
  objectInput,
  pageInput,
  pageResult,
  rangeInput,
  textInput,
  timeZoneInput,
  uuidInput,
} from './business-input';

/// 周期事件可写标量字段，最近完成时间由历史维护。
type EventFields = Pick<
  Event,
  | 'name'
  | 'category'
  | 'intervalValue'
  | 'intervalUnit'
  | 'reminderEnabled'
  | 'reminderDaysBefore'
  | 'reminderTimeMinutes'
  | 'isArchived'
  | 'notes'
>;
/// 事件信息和初始历史的明确输入。
const eventFields = [
  'name',
  'category',
  'intervalValue',
  'intervalUnit',
  'reminderEnabled',
  'reminderDaysBefore',
  'reminderTimeMinutes',
  'isArchived',
  'notes',
  'initialCompletedAt',
] as const;

/// 在明确业务时区计算周期，不采用服务器系统时区。
export function eventDueAt(event: Event, timeZone: string): Date | null {
  if (!event.lastCompletedAt) return null;
  if (event.intervalUnit === 'day' || event.intervalUnit === 'week')
    return new Date(
      event.lastCompletedAt.getTime() +
        event.intervalValue *
          (event.intervalUnit === 'week' ? 7 : 1) *
          86400000,
    );
  // 日历周期保留当地时钟与月底截断。
  const local = localParts(event.lastCompletedAt, timeZone);
  return new Date(
    localInstant(
      addMonths(
        local.day,
        event.intervalValue * (event.intervalUnit === 'year' ? 12 : 1),
      ),
      local.seconds,
      timeZone,
    ).getTime() + event.lastCompletedAt.getMilliseconds(),
  );
}

/// 状态与通知是否开启分开，复用客户端既有顺序。
export function eventStatus(
  event: Event,
  timeZone: string,
  asOf: Date,
): { dueAt: Date | null; status: string } {
  // 下次应做时间为空表示未完成过。
  const dueAt = eventDueAt(event, timeZone);
  return {
    dueAt,
    status: !dueAt
      ? 'unrecorded'
      : asOf > dueAt
        ? 'overdue'
        : asOf.getTime() >=
            dueAt.getTime() - event.reminderDaysBefore * 86400000
          ? 'upcoming'
          : 'normal',
  };
}

/// 事件基本信息与完成历史共享事务，不直接开放派生字段写入。
@Injectable()
export class EventsService {
  /// 使用当前 Prisma 服务。
  constructor(private readonly prisma: PrismaService) {}

  /// 事件列表按应做时间排序，结果只返回所选页面。
  list(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 状态需要显式业务时区。
    const input = objectInput(value, [
      'query',
      'isArchived',
      'timeZone',
      'asOf',
      'limit',
      'offset',
    ]);
    // 查询时间点在一次请求内固定。
    const asOf =
      input.asOf === undefined ? new Date() : instantInput(input.asOf, 'asOf');
    // 计算周期时不用服务器默认地区。
    const timeZone = timeZoneInput(input.timeZone);
    // 列表上限。
    const page = pageInput(input);
    // 事件名称、自由分类和备注匹配。
    const query = textInput(input.query, 'query', 200, true);
    // 默认活动事件，明确 true 才查询归档。
    const isArchived =
      input.isArchived === undefined
        ? false
        : booleanInput(input.isArchived, 'isArchived');
    return businessRead(this.prisma, actor, async (transaction) => {
      // 当前没有持久 dueAt，按实际周期计算后排序。
      const rows = await transaction.event.findMany({
        where: {
          userId: actor.sub,
          deletedAt: null,
          isArchived,
          ...(query
            ? {
                OR: [
                  { name: { contains: query, mode: 'insensitive' } },
                  { category: { contains: query, mode: 'insensitive' } },
                  { notes: { contains: query, mode: 'insensitive' } },
                ],
              }
            : {}),
        },
      });
      // 无最近完成的事件保持排后。
      const projected = rows
        .map((row) => ({ ...row, ...eventStatus(row, timeZone, asOf) }))
        .sort((left, right) =>
          isArchived
            ? right.updatedAt.getTime() - left.updatedAt.getTime() ||
              left.id.localeCompare(right.id)
            : (left.dueAt?.getTime() ?? Number.POSITIVE_INFINITY) -
                (right.dueAt?.getTime() ?? Number.POSITIVE_INFINITY) ||
              left.id.localeCompare(right.id),
        );
      return {
        ...pageResult(
          projected.slice(page.skip, page.skip + page.take + 1),
          page,
        ),
        timeZone,
        asOf,
      };
    });
  }

  /// 获取正式事件详情。
  get(actor: AuthUser, id: string): Promise<Prisma.JsonValue> {
    uuidInput(id);
    return businessRead(this.prisma, actor, async (transaction) =>
      requireActive(
        await transaction.event.findFirst({ where: { userId: actor.sub, id } }),
      ),
    );
  }

  /// 创建事件时可显式设置初始完成历史。
  create(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 表的派生字段不在白名单。
    const input = objectInput(value, ['operationId', ...eventFields]);
    if (input.name === undefined) throw new BadRequestException('需要事件名称');
    return this.save(actor, input, true);
  }

  /// 基础编辑不隐式改写完成历史。
  update(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 只有 initialCompletedAt 代表明确调整初始记录。
    const input = objectInput(value, ['operationId', 'id', ...eventFields]);
    uuidInput(input.id);
    return this.save(actor, input, false);
  }

  /// 只复用本模块创建与编辑的实际共同部分。
  private save(
    actor: AuthUser,
    input: Record<string, unknown>,
    creating: boolean,
  ): Promise<Prisma.JsonValue> {
    // 经校验的可写字段。
    const data: Partial<EventFields> = {};
    if (input.name !== undefined) data.name = textInput(input.name, 'name')!;
    if (input.category !== undefined)
      data.category = textInput(input.category, 'category', 200, true);
    if (input.notes !== undefined)
      data.notes = textInput(input.notes, 'notes', 20000, true);
    if (input.intervalValue !== undefined)
      data.intervalValue = integerInput(
        input.intervalValue,
        'intervalValue',
        1,
        120000,
      );
    if (input.intervalUnit !== undefined)
      data.intervalUnit = enumInput(input.intervalUnit, 'intervalUnit', [
        'day',
        'week',
        'month',
        'year',
      ]);
    if (input.reminderDaysBefore !== undefined)
      data.reminderDaysBefore = integerInput(
        input.reminderDaysBefore,
        'reminderDaysBefore',
      );
    if (input.reminderTimeMinutes !== undefined)
      data.reminderTimeMinutes = integerInput(
        input.reminderTimeMinutes,
        'reminderTimeMinutes',
        0,
        1439,
      );
    for (const field of ['reminderEnabled', 'isArchived'] as const)
      if (input[field] !== undefined)
        data[field] = booleanInput(input[field], field);
    // 初始完成时间显式 null 才清空，不从当前汇总反推。
    const initial =
      input.initialCompletedAt === undefined
        ? undefined
        : input.initialCompletedAt === null
          ? null
          : instantInput(input.initialCompletedAt, 'initialCompletedAt');
    return businessWrite(
      this.prisma,
      actor,
      creating ? 'events.create' : 'events.update',
      input,
      async (transaction) => {
        // 服务端分配身份，创建后由回执恢复。
        const id = creating ? randomUUID() : uuidInput(input.id);
        // 首次遇到旧的仅汇总记录时，保留原完成事实再进行编辑。
        const current = creating
          ? null
          : requireActive(
              await transaction.event.findFirst({
                where: { userId: actor.sub, id },
              }),
            );
        if (current) await this.preserveLegacyInitial(transaction, current);
        // 归档时间与状态一起更新。
        const archivedAt =
          data.isArchived === undefined
            ? {}
            : { archivedAt: data.isArchived ? new Date() : null };
        if (creating)
          await transaction.event.create({
            data: {
              ...data,
              ...archivedAt,
              id,
              userId: actor.sub,
              name: data.name!,
            },
          });
        else
          await transaction.event.update({
            where: { id },
            data: { ...data, ...archivedAt },
          });
        if (initial !== undefined) {
          // 与客户端和同步一致的稳定初始历史身份。
          const initialId = stableBusinessId('event-initial', [id]);
          if (
            initial !== null &&
            (await transaction.syncTombstone.findUnique({
              where: {
                userId_tableName_recordId: {
                  userId: actor.sub,
                  tableName: 'event_completions',
                  recordId: initialId,
                },
              },
            }))
          )
            throw new ConflictException(
              '初始记录已永久删除，请新增一次完成记录',
            );
          if (initial === null)
            await transaction.eventCompletion.updateMany({
              where: { id: initialId, userId: actor.sub, eventId: id },
              data: { deletedAt: new Date() },
            });
          else
            await transaction.eventCompletion.upsert({
              where: { id: initialId },
              create: {
                id: initialId,
                userId: actor.sub,
                eventId: id,
                completedAt: initial,
                source: 'initial',
              },
              update: {
                completedAt: initial,
                deletedAt: null,
                isRevoked: false,
              },
            });
        }
        await reconcileEventCompletions(transaction, actor.sub);
        return transaction.event.findUniqueOrThrow({ where: { id } });
      },
    );
  }

  /// 记录一次完成，网络重试不生成第二条历史。
  complete(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 未指定完成时刻时才表示“现在”。
    const input = objectInput(value, [
      'operationId',
      'eventId',
      'completedAt',
      'notes',
    ]);
    // 完成记录只能附加到当前有效事件。
    const eventId = uuidInput(input.eventId, 'eventId');
    // 参数默认值在首次执行中固定并由回执保存。
    const selected =
      input.completedAt === undefined
        ? null
        : instantInput(input.completedAt, 'completedAt');
    // 备注可留空。
    const notes = textInput(input.notes, 'notes', 20000, true);
    return businessWrite(
      this.prisma,
      actor,
      'events.complete',
      input,
      async (transaction) => {
        // 旧汇总事实不能在撤销本次新记录时丢失。
        const current = requireActive(
          await transaction.event.findFirst({
            where: { id: eventId, userId: actor.sub },
          }),
        );
        await this.preserveLegacyInitial(transaction, current);
        // 历史和派生值同事务维护。
        const completion = await transaction.eventCompletion.create({
          data: {
            id: randomUUID(),
            userId: actor.sub,
            eventId,
            completedAt: selected ?? new Date(),
            notes,
            source: selected ? 'manual' : 'recordNow',
          },
        });
        await reconcileEventCompletions(transaction, actor.sub);
        return {
          completion,
          event: await transaction.event.findUniqueOrThrow({
            where: { id: eventId },
          }),
        };
      },
    );
  }

  /// 只兼容确实没有历史的旧事件，不复活已明确删除的初始历史。
  private async preserveLegacyInitial(
    transaction: Prisma.TransactionClient,
    event: Event,
  ): Promise<void> {
    if (
      !event.lastCompletedAt ||
      (await transaction.eventCompletion.count({
        where: { userId: event.userId, eventId: event.id },
      }))
    )
      return;
    // 稳定身份与离线客户端及同步兼容逻辑一致。
    const id = stableBusinessId('event-initial', [event.id]);
    if (
      await transaction.syncTombstone.findUnique({
        where: {
          userId_tableName_recordId: {
            userId: event.userId,
            tableName: 'event_completions',
            recordId: id,
          },
        },
      })
    )
      return;
    await transaction.eventCompletion.create({
      data: {
        id,
        userId: event.userId,
        eventId: event.id,
        source: 'initial',
        completedAt: event.lastCompletedAt,
        createdAt: event.createdAt,
      },
    });
  }

  /// 历史查询包含已撤销记录，与有效完成统计区分。
  history(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 只读取一个授权事件。
    const input = objectInput(value, ['eventId', 'limit', 'offset']);
    // 事件目标。
    const eventId = uuidInput(input.eventId, 'eventId');
    // 历史也有明确上限。
    const page = pageInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      requireActive(
        await transaction.event.findFirst({
          where: { userId: actor.sub, id: eventId },
        }),
      );
      return pageResult(
        await transaction.eventCompletion.findMany({
          where: { userId: actor.sub, eventId, deletedAt: null },
          orderBy: [{ completedAt: 'desc' }, { id: 'asc' }],
          skip: page.skip,
          take: page.take + 1,
        }),
        page,
      );
    });
  }

  /// 编辑历史会恢复已撤销状态，与既有客户端保持一致。
  updateHistory(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 历史编辑不允许转移所属事件。
    const input = objectInput(value, [
      'operationId',
      'eventId',
      'completionId',
      'completedAt',
      'notes',
    ]);
    return this.changeHistory(actor, input, 'update');
  }

  /// 撤销具体一次完成，而不是猜测最后一条记录。
  undoCompletion(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 撤销身份绑定原结果。
    const input = objectInput(value, [
      'operationId',
      'eventId',
      'completionId',
    ]);
    return this.changeHistory(actor, input, 'undo');
  }

  /// 删除历史采用软删除并立即重算。
  deleteHistory(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 不能用此入口删除事件本体。
    const input = objectInput(value, [
      'operationId',
      'eventId',
      'completionId',
    ]);
    return this.changeHistory(actor, input, 'delete');
  }

  /// 三种历史动作复用归属及最终状态重算。
  private changeHistory(
    actor: AuthUser,
    input: Record<string, unknown>,
    action: 'update' | 'undo' | 'delete',
  ): Promise<Prisma.JsonValue> {
    // 父子身份都验证，拒绝跨事件操作。
    const eventId = uuidInput(input.eventId, 'eventId');
    // 历史的稳定身份。
    const id = uuidInput(input.completionId, 'completionId');
    // 更新只包含明确提交的历史字段。
    const data: Prisma.EventCompletionUpdateInput =
      action === 'undo'
        ? { isRevoked: true }
        : action === 'delete'
          ? { deletedAt: new Date() }
          : { isRevoked: false };
    if (input.completedAt !== undefined)
      data.completedAt = instantInput(input.completedAt, 'completedAt');
    if (input.notes !== undefined)
      data.notes = textInput(input.notes, 'notes', 20000, true);
    return businessWrite(
      this.prisma,
      actor,
      `events.history.${action}`,
      input,
      async (transaction) => {
        requireActive(
          await transaction.event.findFirst({
            where: { id: eventId, userId: actor.sub },
          }),
        );
        if (
          !(await transaction.eventCompletion.findFirst({
            where: { id, eventId, userId: actor.sub, deletedAt: null },
          }))
        )
          throw new NotFoundException('完成记录不存在');
        // 操作与汇总一起提交。
        const completion = await transaction.eventCompletion.update({
          where: { id },
          data,
        });
        await reconcileEventCompletions(transaction, actor.sub);
        return {
          completion,
          event: await transaction.event.findUniqueOrThrow({
            where: { id: eventId },
          }),
        };
      },
    );
  }

  /// 事件软删除保留历史，供现有回收站恢复。
  trash(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 明确软删除目标。
    const input = objectInput(value, ['operationId', 'id']);
    // 事件身份。
    const id = uuidInput(input.id);
    return businessWrite(
      this.prisma,
      actor,
      'events.trash',
      input,
      async (transaction) => {
        requireActive(
          await transaction.event.findFirst({
            where: { userId: actor.sub, id },
          }),
        );
        return transaction.event.update({
          where: { id },
          data: { deletedAt: new Date() },
        });
      },
    );
  }

  /// 周/月有效完成统计包含归档事件，排除撤销和回收站。
  statistics(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 统计输入与日期范围一致。
    const input = objectInput(value, ['from', 'to', 'timeZone', 'asOf']);
    // 服务器一次性固定范围和截止点。
    const range = rangeInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      // 历史事实不从分页结果求和。
      const rows = await transaction.eventCompletion.findMany({
        where: {
          userId: actor.sub,
          deletedAt: null,
          isRevoked: false,
          completedAt: { gte: range.from, lt: range.to, lte: range.asOf },
          event: { deletedAt: null },
        },
        select: { id: true, eventId: true, completedAt: true },
      });
      // 同事件可以在周期内完成多次。
      const counts: Record<string, number> = {};
      for (const row of rows)
        counts[row.eventId] = (counts[row.eventId] ?? 0) + 1;
      return {
        ...range,
        completionCount: rows.length,
        eventCount: Object.keys(counts).length,
        counts,
        sourceIds: rows.slice(0, 200).map((row) => row.id),
        sourcesTruncated: rows.length > 200,
        includesArchived: true,
        complete: true,
      };
    });
  }
}
