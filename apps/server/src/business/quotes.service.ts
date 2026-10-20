import { Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../auth/auth.types';
import type { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { businessRead, businessWrite, requireActive } from './business-access';
import {
  booleanInput,
  dayInput,
  localInstant,
  localParts,
  objectInput,
  pageInput,
  pageResult,
  rangeInput,
  textInput,
  uuidInput,
} from './business-input';

/// 名言库业务方法供不同工具入口复用，不处理 HTTP 或模型协议。
@Injectable()
export class QuotesService {
  /// 注入现有数据库客户端。
  constructor(private readonly prisma: PrismaService) {}

  /// 有界读取有效名言，不初始化默认内容或日签。
  list(actor: AuthUser, value: unknown = {}): Promise<Prisma.JsonValue> {
    // 列表只接受显式筛选字段。
    const input = objectInput(value, ['query', 'isEnabled', 'limit', 'offset']);
    // 单页边界不能被模型扩大。
    const page = pageInput(input);
    // 搜索词可为空。
    const query = textInput(input.query, 'query', 200, true);
    // 未指定启停时返回全部有效项。
    const isEnabled =
      input.isEnabled === undefined
        ? undefined
        : booleanInput(input.isEnabled, 'isEnabled');
    return businessRead(this.prisma, actor, async (transaction) =>
      pageResult(
        await transaction.quote.findMany({
          where: {
            userId: actor.sub,
            deletedAt: null,
            isEnabled,
            ...(query
              ? {
                  OR: [
                    { content: { contains: query, mode: 'insensitive' } },
                    { source: { contains: query, mode: 'insensitive' } },
                  ],
                }
              : {}),
          },
          orderBy: [{ isEnabled: 'desc' }, { createdAt: 'asc' }, { id: 'asc' }],
          skip: page.skip,
          take: page.take + 1,
        }),
        page,
      ),
    );
  }

  /// 详情不泄露其他归属的记录。
  get(actor: AuthUser, id: string): Promise<Prisma.JsonValue> {
    uuidInput(id);
    return businessRead(this.prisma, actor, async (transaction) =>
      requireActive(
        await transaction.quote.findFirst({ where: { id, userId: actor.sub } }),
      ),
    );
  }

  /// 新增内容不复用 JSON 导入的额外字数限制。
  create(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 最多受当前请求边界约束，保留库编辑原有口径。
    const input = objectInput(value, [
      'operationId',
      'content',
      'source',
      'isEnabled',
    ]);
    // 名言正文不能为空。
    const content = textInput(input.content, 'content', 1000000)!;
    // 来源允许留空。
    const source = textInput(input.source, 'source', 1000000, true);
    // 默认启用与原客户端一致。
    const isEnabled =
      input.isEnabled === undefined
        ? true
        : booleanInput(input.isEnabled, 'isEnabled');
    return businessWrite(
      this.prisma,
      actor,
      'quotes.create',
      input,
      (transaction) =>
        transaction.quote.create({
          data: {
            id: randomUUID(),
            userId: actor.sub,
            content,
            source,
            isEnabled,
          },
        }),
    );
  }

  /// 只编辑允许的库字段，缺省字段不会被清空。
  update(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 请求身份与目标 ID 均需明确。
    const input = objectInput(value, [
      'operationId',
      'id',
      'content',
      'source',
      'isEnabled',
    ]);
    // 修改字段不包含任何归属或创建事实。
    const data: Prisma.QuoteUpdateInput = {};
    // 稳定目标身份。
    const id = uuidInput(input.id);
    if (input.content !== undefined)
      data.content = textInput(input.content, 'content', 1000000)!;
    if (input.source !== undefined)
      data.source = textInput(input.source, 'source', 1000000, true);
    if (input.isEnabled !== undefined)
      data.isEnabled = booleanInput(input.isEnabled, 'isEnabled');
    return businessWrite(
      this.prisma,
      actor,
      'quotes.update',
      input,
      async (transaction) => {
        requireActive(
          await transaction.quote.findFirst({
            where: { id, userId: actor.sub },
          }),
        );
        return transaction.quote.update({ where: { id }, data });
      },
    );
  }

  /// 普通删除进入回收站，不删除日期槽位。
  trash(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 软删除仅接受目标与操作身份。
    const input = objectInput(value, ['operationId', 'id']);
    // 当前库记录。
    const id = uuidInput(input.id);
    return businessWrite(
      this.prisma,
      actor,
      'quotes.trash',
      input,
      async (transaction) => {
        requireActive(
          await transaction.quote.findFirst({
            where: { id, userId: actor.sub },
          }),
        );
        return transaction.quote.update({
          where: { id },
          data: { deletedAt: new Date() },
        });
      },
    );
  }

  /// 日签查询只读取既有槽位；缺少时明确返回 null。
  daily(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 日期查询不产生默认记录。
    const input = objectInput(value, ['day']);
    // 自然日不转换为服务器本地日期。
    const day = dayInput(input.day);
    return businessRead(this.prisma, actor, async (transaction) => {
      // 已有槽位可能保留空引用或失效名言。
      const selection = await transaction.dailyQuoteSelection.findUnique({
        where: { userId_dayKey: { userId: actor.sub, dayKey: day } },
        include: { quote: true },
      });
      return {
        day,
        selectionId: selection?.id ?? null,
        quote:
          selection?.quote &&
          selection.quote.deletedAt === null &&
          selection.quote.isEnabled
            ? selection.quote
            : null,
      };
    });
  }

  /// 查询范围内已有日签及库计数，不为总结生成额外业务实体。
  statistics(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 周/月仅体现为日期窗口。
    const input = objectInput(value, ['from', 'to', 'timeZone', 'asOf']);
    // 固定调用方指定的地区与范围。
    const range = rangeInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      // 日期槽位不扫描或补写历史默认数据。
      const rows = await transaction.dailyQuoteSelection.findMany({
        where: {
          userId: actor.sub,
          dayKey: {
            gte: localParts(range.from, range.timeZone).day,
            lte: localParts(range.to, range.timeZone).day,
          },
        },
        include: { quote: true },
        orderBy: [{ dayKey: 'asc' }, { id: 'asc' }],
      });
      // 无效或空引用保留槽位事实，但不作为有效日签计数。
      const selected = rows.filter((row) => {
        // 日期槽位按地区日界筛选，不隐式生成缺失日签。
        const at = localInstant(row.dayKey, 0, range.timeZone);
        return (
          at >= range.from &&
          at < range.to &&
          row.quote?.deletedAt === null &&
          row.quote.isEnabled
        );
      });
      return {
        ...range,
        quoteCount: await transaction.quote.count({
          where: { userId: actor.sub, deletedAt: null },
        }),
        enabledQuoteCount: await transaction.quote.count({
          where: { userId: actor.sub, deletedAt: null, isEnabled: true },
        }),
        dailyCount: selected.length,
        selections: selected.slice(0, 200).map((row) => ({
          day: row.dayKey,
          quoteId: row.quoteId,
          content: row.quote!.content,
          source: row.quote!.source,
        })),
        selectionsTruncated: selected.length > 200,
        complete: true,
        missingDaysGenerated: false,
      };
    });
  }
}
