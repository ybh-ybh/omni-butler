import {
  BadRequestException,
  ConflictException,
  Injectable,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../auth/auth.types';
import type { Prisma, TimeEntry } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { businessRead, businessWrite, requireActive } from './business-access';
import {
  addDays,
  instantInput,
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

/// 绝对时间记录的查询、开始/结束和区间统计。
@Injectable()
export class TimeEntriesService {
  /// 注入共享持久化连接。
  constructor(private readonly prisma: PrismaService) {}

  /// 查询与窗口相交的记录，采用左闭右开范围。
  list(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 范围语义由服务校验，工具不能直接拼数据库条件。
    const input = objectInput(value, [
      'from',
      'to',
      'timeZone',
      'asOf',
      'limit',
      'offset',
    ]);
    // 已解析的时间范围。
    const range = rangeInput(input);
    // 返回显式截断状态。
    const page = pageInput(input);
    return businessRead(this.prisma, actor, async (transaction) =>
      pageResult(
        await transaction.timeEntry.findMany({
          where: {
            userId: actor.sub,
            deletedAt: null,
            startedAt: { lt: range.to },
            OR: [{ endedAt: null }, { endedAt: { gt: range.from } }],
          },
          orderBy: [{ startedAt: 'asc' }, { id: 'asc' }],
          skip: page.skip,
          take: page.take + 1,
        }),
        page,
      ),
    );
  }

  /// 详情沿用同归属和回收站保护。
  get(actor: AuthUser, id: string): Promise<Prisma.JsonValue> {
    uuidInput(id);
    return businessRead(this.prisma, actor, async (transaction) =>
      requireActive(
        await transaction.timeEntry.findFirst({
          where: { id, userId: actor.sub },
        }),
      ),
    );
  }

  /// 进行中查询返回全部可见项而非掩盖多设备冲突。
  ongoing(actor: AuthUser, value: unknown = {}): Promise<Prisma.JsonValue> {
    // 进行中列表同样有界。
    const input = objectInput(value, ['limit', 'offset']);
    // 分页不会改变记录状态。
    const page = pageInput(input);
    return businessRead(this.prisma, actor, async (transaction) =>
      pageResult(
        await transaction.timeEntry.findMany({
          where: { userId: actor.sub, deletedAt: null, endedAt: null },
          orderBy: [{ startedAt: 'asc' }, { id: 'asc' }],
          skip: page.skip,
          take: page.take + 1,
        }),
        page,
      ),
    );
  }

  /// 开始新记录，默认使用真实服务器当前时间。
  start(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 开始命令不接受任意结束时间。
    const input = objectInput(value, [
      'operationId',
      'startedAt',
      'timeZone',
      'activity',
      'category',
      'notes',
    ]);
    return this.save(actor, input, 'time.start', null);
  }

  /// 补记一条完整区间。
  create(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 完整记录必须明确首尾时间。
    const input = objectInput(value, [
      'operationId',
      'startedAt',
      'endedAt',
      'timeZone',
      'activity',
      'category',
      'notes',
    ]);
    if (
      input.startedAt === undefined ||
      input.endedAt === undefined ||
      input.endedAt === null
    )
      throw new BadRequestException('补记必须包含开始和结束时间');
    return this.save(actor, input, 'time.create');
  }

  /// 结束原进行中记录时允许收尾既有同步冲突。
  finish(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 开始时间不能由结束动作改写。
    const input = objectInput(value, [
      'operationId',
      'id',
      'endedAt',
      'timeZone',
      'activity',
      'category',
      'notes',
    ]);
    if (input.endedAt === null)
      throw new BadRequestException('结束时间不能为空');
    return this.save(actor, input, 'time.finish');
  }

  /// 编辑使用窄字段集合，保留未选择字段。
  update(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 编辑不会默默创建缺失目标。
    const input = objectInput(value, [
      'operationId',
      'id',
      'startedAt',
      'endedAt',
      'timeZone',
      'activity',
      'category',
      'notes',
    ]);
    return this.save(actor, input, 'time.update');
  }

  /// 共享区间写入仅服务真实的四个业务动作。
  private save(
    actor: AuthUser,
    input: Record<string, unknown>,
    action: string,
    forcedEnd?: null,
  ): Promise<Prisma.JsonValue> {
    // 兼容投影所用业务时区必须由调用方指定。
    const timeZone = timeZoneInput(input.timeZone);
    // 有目标时只允许修改有效记录。
    const id = input.id === undefined ? null : uuidInput(input.id);
    if ((action === 'time.update' || action === 'time.finish') && !id)
      throw new BadRequestException('必须指定记录身份');
    return businessWrite(
      this.prisma,
      actor,
      action,
      input,
      async (transaction) => {
        // 当前行在 owner 锁内读取，避免基于对话旧快照判断。
        const current = id
          ? requireActive(
              await transaction.timeEntry.findFirst({
                where: { id, userId: actor.sub },
              }),
            )
          : null;
        if (action === 'time.finish' && current?.endedAt !== null)
          throw new ConflictException('记录已经结束');
        // 开始默认当前时间，仅开始命令允许省略。
        const startedAt =
          input.startedAt === undefined
            ? (current?.startedAt ?? new Date())
            : instantInput(input.startedAt, 'startedAt');
        // 结束默认当前时间，编辑缺省保留原值。
        const endedAt =
          forcedEnd === null
            ? null
            : input.endedAt === null
              ? null
              : input.endedAt === undefined
                ? action === 'time.finish'
                  ? new Date()
                  : (current?.endedAt ?? null)
                : instantInput(input.endedAt, 'endedAt');
        // 活动文字使用原字段上限。
        const activity =
          input.activity === undefined && current
            ? current.activity
            : textInput(input.activity, 'activity', 200, true);
        if (endedAt && (!activity || endedAt <= startedAt))
          throw new BadRequestException(
            '结束记录需要活动内容，且结束必须晚于开始',
          );
        // 结束既有记录不被历史冲突锁死；其他写入检查当前完整区间。
        const finishing = current?.endedAt === null && endedAt !== null;
        if (!finishing) {
          // 时间冲突检查在 owner 锁中，与并发开始串行。
          const conflict = await transaction.timeEntry.findFirst({
            where: {
              userId: actor.sub,
              deletedAt: null,
              ...(id ? { id: { not: id } } : {}),
              ...(endedAt ? { startedAt: { lt: endedAt } } : {}),
              OR: [{ endedAt: null }, { endedAt: { gt: startedAt } }],
            },
          });
          if (conflict)
            throw new ConflictException({
              code: 'TIME_INTERVAL_CONFLICT',
              message: '时间区间与现有记录冲突',
              conflictingId: conflict.id,
            });
        }
        // 为旧客户端保持自然日与分钟投影。
        const local = localParts(startedAt, timeZone);
        // 起始日午夜的绝对边界由真实开始点及日内时钟计算。
        const midnight = localInstant(local.day, 0, timeZone).getTime();
        // 可写数据完全由业务输入生成。
        const data = {
          startedAt,
          endedAt,
          activity,
          entryDate: new Date(`${local.day}T00:00:00Z`),
          startMinute: Math.floor((startedAt.getTime() - midnight) / 60000),
          endMinute: endedAt
            ? Math.floor((endedAt.getTime() - midnight) / 60000)
            : Math.floor((startedAt.getTime() - midnight) / 60000),
          category:
            input.category === undefined && current
              ? current.category
              : textInput(input.category, 'category', 200, true),
          notes:
            input.notes === undefined && current
              ? current.notes
              : textInput(input.notes, 'notes', 20000, true),
        };
        return id
          ? transaction.timeEntry.update({ where: { id }, data })
          : transaction.timeEntry.create({
              data: { ...data, id: randomUUID(), userId: actor.sub },
            });
      },
    );
  }

  /// 将记录移入回收站，不触发额外计时。
  trash(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 删除不接受任意列更新。
    const input = objectInput(value, ['operationId', 'id']);
    // 当前目标。
    const id = uuidInput(input.id);
    return businessWrite(
      this.prisma,
      actor,
      'time.trash',
      input,
      async (transaction) => {
        requireActive(
          await transaction.timeEntry.findFirst({
            where: { id, userId: actor.sub },
          }),
        );
        return transaction.timeEntry.update({
          where: { id },
          data: { deletedAt: new Date() },
        });
      },
    );
  }

  /// 对完整相交集合裁剪后求和，绝不从一页列表统计。
  statistics(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 时间统计必须声明窗口、时区和可选截止点。
    const input = objectInput(value, ['from', 'to', 'timeZone', 'asOf']);
    // 固定进行中记录的统计截止点。
    const range = rangeInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      // 数据范围不受模型列表上限截断。
      const rows: TimeEntry[] = await transaction.timeEntry.findMany({
        where: {
          userId: actor.sub,
          deletedAt: null,
          startedAt: { lt: range.to },
          OR: [{ endedAt: null }, { endedAt: { gt: range.from } }],
        },
        orderBy: [{ startedAt: 'asc' }, { id: 'asc' }],
      });
      // 分类合计以毫秒累加，最后转换秒避免逐段截断误差。
      const categories: Record<string, number> = Object.create(null) as Record<
        string,
        number
      >;
      // 自然日汇总按真实日界拆分，DST 日可为 23 或 25 小时。
      const days: Record<string, number> = {};
      // 参与统计的有效来源身份。
      const sourceIds: string[] = [];
      // 已结束事实与进行中暂估分别列出，模型不能把暂估冒充完整记录。
      let completedMilliseconds = 0,
        ongoingMilliseconds = 0;
      for (const row of rows) {
        // 每条区间裁剪到查询窗口和进行中截止点。
        const duration = Math.max(
          0,
          Math.min(
            (row.endedAt ?? range.asOf).getTime(),
            range.to.getTime(),
            range.asOf.getTime(),
          ) - Math.max(row.startedAt.getTime(), range.from.getTime()),
        );
        if (!duration) continue;
        if (row.endedAt === null || row.endedAt > range.asOf)
          ongoingMilliseconds += duration;
        else completedMilliseconds += duration;
        categories[row.category ?? '未分类'] =
          (categories[row.category ?? '未分类'] ?? 0) + duration;
        sourceIds.push(row.id);
        // 将该记录按业务地区的日界逐段累计。
        let cursor = Math.max(row.startedAt.getTime(), range.from.getTime());
        // 进行中只累计至固定截止点。
        const end = Math.min(
          (row.endedAt ?? range.asOf).getTime(),
          range.to.getTime(),
        );
        while (cursor < end) {
          // 当前片段的自然日。
          const day = localParts(new Date(cursor), range.timeZone).day;
          // 日历下一天不能用固定 24 小时替代。
          const next = Math.min(
            end,
            localInstant(addDays(day, 1), 0, range.timeZone).getTime(),
          );
          if (next <= cursor)
            throw new BadRequestException('无法划分业务自然日');
          days[day] = (days[day] ?? 0) + next - cursor;
          cursor = next;
        }
      }
      return {
        ...range,
        count: sourceIds.length,
        completedSeconds: completedMilliseconds / 1000,
        ongoingEstimatedSeconds: ongoingMilliseconds / 1000,
        categoryPercentages: Object.fromEntries(
          Object.entries(categories).map(([category, duration]) => [
            category,
            completedMilliseconds + ongoingMilliseconds === 0
              ? null
              : Math.round(
                  (duration / (completedMilliseconds + ongoingMilliseconds)) *
                    10000,
                ) / 100,
          ]),
        ),
        totalSeconds:
          Object.values(categories).reduce(
            (sum, duration) => sum + duration,
            0,
          ) / 1000,
        categories: Object.fromEntries(
          Object.entries(categories).map(([category, duration]) => [
            category,
            duration / 1000,
          ]),
        ),
        days: Object.fromEntries(
          Object.entries(days).map(([day, duration]) => [day, duration / 1000]),
        ),
        sourceIds: sourceIds.slice(0, 200),
        sourcesTruncated: sourceIds.length > 200,
        complete: true,
        unit: 'seconds',
        interval: '[from,to)',
      };
    });
  }
}
