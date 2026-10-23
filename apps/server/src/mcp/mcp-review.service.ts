import {
  BadRequestException,
  ForbiddenException,
  Injectable,
} from '@nestjs/common';
import { z } from 'zod';
import type { McpConnection, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { businessRead } from '../business/business-access';
import {
  addDays,
  addMonths,
  localInstant,
  localParts,
  rangeInput,
  timeZoneInput,
} from '../business/business-input';
import { reviewSchema, type McpModule } from './mcp-catalog';
import { ActionExecutor } from './action-executor';
import type { ActionContext, ActionScope } from './action-context';
import { notePlainText } from '../business/notes-business.service';

/// 仅这些模块使用截止点计算进行中时长、支付/完成事实或状态。
const cutoffModules: readonly McpModule[] = [
  'time',
  'todos',
  'memberships',
  'events',
];
/// 可解释的主指标用于后端计算变化，金额不混合不同来源。
const metrics: Record<McpModule, string[]> = {
  quotes: ['quoteCount', 'dailyCount'],
  time: ['totalSeconds', 'count'],
  todos: ['completedCount', 'plannedCount'],
  inventory: ['purchasePriceCents', 'count'],
  memberships: ['amountCents', 'paymentCount'],
  events: ['completionCount'],
  notes: ['count', 'words'],
};

/// 统计证据包与受限辅助查询。
@Injectable()
export class McpReviewService {
  /// 复用当前连接认证及逐项业务统计。
  constructor(
    private readonly mcp: ActionExecutor,
    private readonly prisma: PrismaService,
  ) {}

  /// 助手与 MCP 使用相同统计证据规则，身份始终由共享引擎校验。
  async reviewFor(
    context: ActionContext,
    value: unknown,
  ): Promise<Record<string, unknown>> {
    return this.review(await this.mcp.scope(context), value);
  }

  /// 助手分类查询复用真实 owner 范围，不接受模型声明归属。
  async taxonomiesFor(
    context: ActionContext,
    value: unknown,
  ): Promise<Prisma.JsonValue> {
    return this.taxonomies(await this.mcp.scope(context), value);
  }

  /// 规范自然周期，并明确本期未发生部分不在默认窗口内。
  async review(
    connection: McpConnection | ActionScope,
    value: unknown,
  ): Promise<Record<string, unknown>> {
    // 模型无法增加归属、任意SQL或隐藏筛选。
    const input = reviewSchema.parse(value);
    // 未配置默认时区时必须由当前请求提供。
    const timeZone = timeZoneInput(input.timeZone ?? connection.timeZone);
    // 请求截止时刻，不能用未来时刻伪称数据已发生。
    const asOf = input.asOf ? new Date(input.asOf) : new Date();
    if (asOf.getTime() > Date.now() + 1000)
      throw new BadRequestException('数据截止时刻不能晚于当前时刻');
    // 所选范围只含当前授权模块，未授权不能默默返回空集冒充无记录。
    const modules = [
      ...new Set(input.modules ?? connection.readModules),
    ] as McpModule[];
    if (modules.some((module) => !connection.readModules.includes(module)))
      throw new ForbiddenException('未获得所选统计模块读权限');
    // 当地当前自然日。
    const local = localParts(asOf, timeZone);
    // 窗口以真实当地午夜计算，处理23/25小时日期。
    let startDay = local.day,
      endDay = addDays(local.day, 1);
    if (input.period === 'week' || input.period === 'lastWeek') {
      // 周起始日默认为周一，按显式参数转换成绝对日期。
      const weekday = new Date(`${local.day}T12:00:00Z`).getUTCDay();
      startDay = addDays(local.day, -((weekday - input.weekStartsOn + 7) % 7));
      if (input.period === 'lastWeek') startDay = addDays(startDay, -7);
      endDay = addDays(startDay, 7);
    } else if (input.period === 'month' || input.period === 'lastMonth') {
      startDay = `${local.day.slice(0, 7)}-01`;
      if (input.period === 'lastMonth') startDay = addMonths(startDay, -1);
      endDay = addMonths(startDay, 1);
    }
    if (input.period !== 'custom' && (input.from || input.to))
      throw new BadRequestException('指定起止时刻时请使用custom范围');
    if (input.period === 'custom' && (!input.from || !input.to))
      throw new BadRequestException('自定义范围必须同时提供from/to');
    // 当前自然周/月仅截至已发生部分，上一周期使用完整窗口。
    const from =
      input.from ?? localInstant(startDay, 0, timeZone).toISOString();
    // 自然周期与查询截止分别保留，方便解释部分覆盖。
    const calendarEnd =
      input.to ?? localInstant(endDay, 0, timeZone).toISOString();
    // 实际查询窗口不超过截止时刻。
    const to = new Date(
      Math.min(new Date(calendarEnd).getTime(), asOf.getTime()),
    ).toISOString();
    rangeInput({ from, to, timeZone, asOf: asOf.toISOString() });
    // 调用每个已登记统计方法，数字来自后端完整授权集合。
    const summaries: Record<string, Prisma.JsonValue> = {};
    for (const module of modules)
      summaries[module] = await this.mcp.statistics(
        'context' in connection ? connection.context : connection.id,
        {
          module,
          from,
          to,
          timeZone,
          ...(cutoffModules.includes(module)
            ? { asOf: asOf.toISOString() }
            : {}),
        },
      );
    // 比较口径单独列出，基期0不返回误导百分比。
    const comparison: Record<string, unknown> = {};
    if (input.comparePrevious) {
      // 自定义范围用前一段等长绝对区间，其余用完整前一自然周期。
      const previousFrom =
        input.period === 'custom'
          ? new Date(
              new Date(from).getTime() -
                (new Date(calendarEnd).getTime() - new Date(from).getTime()),
            ).toISOString()
          : localInstant(
              input.period === 'week' || input.period === 'lastWeek'
                ? addDays(startDay, -7)
                : addMonths(startDay, -1),
              0,
              timeZone,
            ).toISOString();
      for (const module of modules) {
        // 统计结果在当前事实基础上查询过去范围，不伪称有历史状态快照。
        const previous = (await this.mcp.statistics(
          'context' in connection ? connection.context : connection.id,
          {
            module,
            from: previousFrom,
            to: from,
            timeZone,
            ...(cutoffModules.includes(module)
              ? { asOf: asOf.toISOString() }
              : {}),
          },
        )) as Record<string, Prisma.JsonValue>;
        // 仅比较确实存在的确定性数值字段。
        const current = summaries[module] as Record<string, Prisma.JsonValue>;
        comparison[module] = {
          from: previousFrom,
          to: from,
          values: Object.fromEntries(
            metrics[module]
              .filter(
                (key) =>
                  typeof current[key] === 'number' &&
                  typeof previous[key] === 'number',
              )
              .map((key) => [
                key,
                {
                  current: current[key],
                  previous: previous[key],
                  difference: Number(current[key]) - Number(previous[key]),
                  percentChange:
                    Number(previous[key]) === 0
                      ? null
                      : Math.round(
                          ((Number(current[key]) - Number(previous[key])) /
                            Number(previous[key])) *
                            10000,
                        ) / 100,
                },
              ]),
          ),
          caution:
            '当前周期可能仅覆盖已发生部分；与完整前期比较须同时展示各自范围',
        };
      }
    }
    // 正文材料只取统计窗口中最多20篇预览，明确不能据此声称覆盖全部主题。
    const noteSources = (
      summaries.notes &&
      !Array.isArray(summaries.notes) &&
      typeof summaries.notes === 'object'
        ? (summaries.notes as Record<string, Prisma.JsonValue>).sourceIds
        : []
    ) as string[];
    // 列表预览不默认把整篇或整库正文发送给Codex。
    const noteEvidence = modules.includes('notes')
      ? await businessRead(
          this.prisma,
          { sub: connection.userId, sid: connection.sessionId, typ: 'access' },
          async (transaction) => {
            // 身份只来自已授权范围的确定性统计结果。
            const rows = await transaction.noteEntry.findMany({
              where: {
                userId: connection.userId,
                id: { in: noteSources.slice(0, 20) },
                deletedAt: null,
              },
              select: { id: true, dayKey: true, body: true },
              orderBy: [{ dayKey: 'asc' }, { id: 'asc' }],
            });
            return rows.map((row) => {
              // 使用与笔记搜索/统计相同的可见文字规则。
              const plain = notePlainText(row.body);
              return {
                id: row.id,
                dayKey: row.dayKey,
                preview: plain.slice(0, 400),
                previewTruncated: plain.length > 400,
                uri: `omni-butler://records/notes/${row.id}`,
                fetchTool: 'get_note',
              };
            });
          },
        )
      : [];
    return {
      from,
      to,
      calendarEnd,
      asOf: asOf.toISOString(),
      timeZone,
      timeZoneSource: input.timeZone ? '当前请求' : '连接设置',
      weekStartsOn: input.weekStartsOn,
      summaries,
      comparison,
      noteEvidence,
      noteEvidenceCoverage: {
        selected: Array.isArray(noteEvidence) ? noteEvidence.length : 0,
        total: summaries.notes
          ? (summaries.notes as Record<string, Prisma.JsonValue>).count
          : 0,
        maxNotes: 20,
        maxPreviewCharacters: 400,
        completeTextCoverage: false,
      },
      references: modules.map((module) => ({
        module,
        tool: 'get_statistics',
        sourceIds:
          (summaries[module] as Record<string, Prisma.JsonValue>).sourceIds ??
          [],
        truncated:
          (summaries[module] as Record<string, Prisma.JsonValue>)
            .sourcesTruncated ??
          (summaries[module] as Record<string, Prisma.JsonValue>)
            .selectionsTruncated ??
          false,
      })),
      coverage: [
        '仅覆盖服务器已接收的正式数据，不含本机草稿及未同步设备',
        '统计覆盖完整范围，来源明细最多200条；不能把截断材料视为全文覆盖',
        '没有记录不代表没有活动，推测需要明确标注',
        '生成文字默认不保存；用户另行明确要求保存单篇总结时调用create_note直接保存，多对象任务使用prepare_batch并在对话确认后commit_action',
        '不同统计请求之间可能存在并发提交；每个模块的统计在独立一致快照内完成',
      ],
    };
  }

  /// 查询规范分类身份，模块范围来自当前连接，不提供自由表查询。
  taxonomies(
    connection: McpConnection | ActionScope,
    value: unknown,
  ): Promise<Prisma.JsonValue> {
    // 多态分类目前仅四个模块存在，未开放模块不能枚举。
    const input = z
      .strictObject({
        module: z.enum(['time', 'inventory', 'memberships', 'notes']),
        limit: z.number().int().min(1).max(200).default(50),
        offset: z.number().int().min(0).max(1000000).default(0),
      })
      .parse(value);
    if (!connection.readModules.includes(input.module))
      throw new ForbiddenException('未获得该模块读权限');
    // 旧协议模块名只在固定映射内翻译。
    const names = {
      time: 'timeline',
      inventory: 'inventory',
      memberships: 'membership',
      notes: 'notes',
    };
    return businessRead(
      this.prisma,
      { sub: connection.userId, sid: connection.sessionId, typ: 'access' },
      async (transaction) => {
        // 有效规范身份可用于后续具体业务字段，禁用/删除项不建议绑定。
        const rows = await transaction.taxonomyEntry.findMany({
          where: {
            userId: connection.userId,
            module: names[input.module],
            deletedAt: null,
            isEnabled: true,
          },
          orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
          take: input.limit + 1,
          skip: input.offset,
        });
        return {
          items: rows.slice(0, input.limit),
          hasMore: rows.length > input.limit,
          nextOffset:
            rows.length > input.limit ? input.offset + input.limit : null,
        };
      },
    );
  }
}
