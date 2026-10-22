import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../auth/auth.types';
import type { Membership, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { stableBusinessId } from '../sync/sync-consistency';
import {
  businessRead,
  businessWrite,
  replaceTaxonomies,
  resolveNamedTaxonomy,
  requireActive,
} from './business-access';
import {
  addDays,
  addMonths,
  booleanInput,
  dayInput,
  enumInput,
  idsInput,
  instantInput,
  integerInput,
  localInstant,
  localParts,
  objectInput,
  pageInput,
  pageResult,
  rangeInput,
  textInput,
  taxonomyTextInput,
  timeZoneInput,
  urlInput,
  uuidInput,
} from './business-input';

/// 本业务可编辑字段不包含服务端身份与生命周期事实。
type MemberFields = Omit<
  Membership,
  'id' | 'userId' | 'createdAt' | 'updatedAt' | 'deletedAt'
>;
/// 当前客户端支持的计费周期，不增加真实支付能力。
const billingCycles = [
  'week',
  'month',
  'quarter',
  'halfYear',
  'year',
  'twoYears',
  'threeYears',
  'permanent',
  'custom',
] as const;
/// 会员窄输入字段白名单。
const memberFields = [
  'name',
  'provider',
  'category',
  'description',
  'websiteUrl',
  'purchasePlatform',
  'priceCents',
  'billingCycle',
  'baseStatus',
  'purchaseDate',
  'expirationDate',
  'isPermanent',
  'autoRenew',
  'renewalDate',
  'needsRenewal',
  'expirationReminderEnabled',
  'expirationReminderDays',
  'renewalReminderEnabled',
  'renewalReminderDays',
  'reminderTimeMinutes',
  'cancelGuide',
  'notes',
  'categoryIds',
  'tagIds',
] as const;

/// 标准周期从给定业务自然日推进，月底不进位。
export function membershipPeriodEnd(day: string, cycle: string): string {
  if (cycle === 'week') return addDays(day, 7);
  // 月周期映射与客户端保持一致。
  const months: Record<string, number> = {
    month: 1,
    quarter: 3,
    halfYear: 6,
    year: 12,
    twoYears: 24,
    threeYears: 36,
  };
  if (!months[cycle])
    throw new BadRequestException('自定义周期必须明确结束日期');
  return addMonths(day, months[cycle]);
}

/// 状态使用明确业务日及截止点，不依赖宿主系统时区。
export function membershipStatus(
  member: Membership,
  timeZone: string,
  asOf: Date,
): string {
  if (member.isPermanent) return 'permanent';
  if (!member.expirationDate) return 'active';
  // 日期列对应用户地区该自然日的开始，与现有客户端 Date 比较一致。
  const expiration = localInstant(
    member.expirationDate.toISOString().slice(0, 10),
    0,
    timeZone,
  );
  if (asOf > expiration) return 'expired';
  if (
    asOf.getTime() >=
    expiration.getTime() - member.expirationReminderDays * 86400000
  )
    return 'upcoming';
  if (member.needsRenewal) return 'renewalDue';
  return member.baseStatus === 'trial' || member.baseStatus === 'cancelled'
    ? member.baseStatus
    : 'active';
}

/// 会员保存、账目与到期信息共用原子业务入口。
@Injectable()
export class MembershipsService {
  /// 注入现有数据库客户端。
  constructor(private readonly prisma: PrismaService) {}

  /// 有界会员列表，明确地区与状态计算时点。
  list(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 搜索只接受业务过滤条件。
    const input = objectInput(value, [
      'query',
      'timeZone',
      'asOf',
      'limit',
      'offset',
    ]);
    // 状态时区来自调用上下文。
    const timeZone = timeZoneInput(input.timeZone);
    // 单次调用固定当前时间。
    const asOf =
      input.asOf === undefined ? new Date() : instantInput(input.asOf, 'asOf');
    // 受控分页。
    const page = pageInput(input);
    // 名称及供应商搜索。
    const query = textInput(input.query, 'query', 200, true);
    return businessRead(this.prisma, actor, async (transaction) =>
      pageResult(
        (
          await transaction.membership.findMany({
            where: {
              userId: actor.sub,
              deletedAt: null,
              ...(query
                ? {
                    OR: [
                      { name: { contains: query, mode: 'insensitive' } },
                      { provider: { contains: query, mode: 'insensitive' } },
                      { category: { contains: query, mode: 'insensitive' } },
                    ],
                  }
                : {}),
            },
            orderBy: [
              { isPermanent: 'asc' },
              { expirationDate: { sort: 'asc', nulls: 'last' } },
              { id: 'asc' },
            ],
            skip: page.skip,
            take: page.take + 1,
          })
        ).map((row) => ({
          ...row,
          status: membershipStatus(row, timeZone, asOf),
        })),
        page,
      ),
    );
  }

  /// 详情返回规范分类身份，但不读任何供应商密钥。
  get(actor: AuthUser, id: string): Promise<Prisma.JsonValue> {
    uuidInput(id);
    return businessRead(this.prisma, actor, async (transaction) => ({
      ...requireActive(
        await transaction.membership.findFirst({
          where: { id, userId: actor.sub },
        }),
      ),
      links: await transaction.recordTaxonomyLink.findMany({
        where: {
          userId: actor.sub,
          module: 'membership',
          recordId: id,
          deletedAt: null,
          taxonomy: { deletedAt: null },
        },
        select: { taxonomyId: true },
      }),
    }));
  }

  /// 新增会员、本次首购和分类标签一起提交。
  create(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 业务时区用于首购账目的真实时间。
    const input = objectInput(value, [
      'operationId',
      'timeZone',
      ...memberFields,
    ]);
    if (input.name === undefined || input.purchaseDate === undefined)
      throw new BadRequestException('需要名称及购买日期');
    return this.save(actor, input, true);
  }

  /// 基础编辑不会自动生成第二次首购账目。
  update(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 不接受直接插入支付记录的参数。
    const input = objectInput(value, [
      'operationId',
      'id',
      'timeZone',
      ...memberFields,
    ]);
    uuidInput(input.id);
    return this.save(actor, input, false);
  }

  /// 保存时只复用已选字段的校验及事务。
  private save(
    actor: AuthUser,
    input: Record<string, unknown>,
    creating: boolean,
  ): Promise<Prisma.JsonValue> {
    // 首购时区不从服务器默认值推断。
    const timeZone = timeZoneInput(input.timeZone);
    // 独立构造受限标量数据。
    const data: Partial<MemberFields> = {};
    if (input.name !== undefined) data.name = textInput(input.name, 'name')!;
    for (const field of [
      'provider',
      'purchasePlatform',
      'description',
      'cancelGuide',
      'notes',
    ] as const)
      if (input[field] !== undefined)
        data[field] = textInput(
          input[field],
          field,
          field === 'notes' ||
            field === 'description' ||
            field === 'cancelGuide'
            ? 20000
            : 200,
          true,
        );
    if (input.category !== undefined)
      data.category = taxonomyTextInput(input.category, 'category');
    if (input.websiteUrl !== undefined)
      data.websiteUrl = urlInput(input.websiteUrl, 'websiteUrl');
    if (input.priceCents !== undefined)
      data.priceCents = integerInput(input.priceCents, 'priceCents');
    if (input.billingCycle !== undefined)
      data.billingCycle = enumInput(
        input.billingCycle,
        'billingCycle',
        billingCycles,
      );
    if (input.baseStatus !== undefined)
      data.baseStatus = enumInput(input.baseStatus, 'baseStatus', [
        'active',
        'trial',
        'cancelled',
      ]);
    for (const field of [
      'isPermanent',
      'autoRenew',
      'needsRenewal',
      'expirationReminderEnabled',
      'renewalReminderEnabled',
    ] as const)
      if (input[field] !== undefined)
        data[field] = booleanInput(input[field], field);
    if (input.purchaseDate !== undefined)
      data.purchaseDate = new Date(
        `${dayInput(input.purchaseDate, 'purchaseDate')}T00:00:00Z`,
      );
    for (const field of ['expirationDate', 'renewalDate'] as const)
      if (input[field] !== undefined)
        data[field] =
          input[field] === null
            ? null
            : new Date(`${dayInput(input[field], field)}T00:00:00Z`);
    for (const field of [
      'expirationReminderDays',
      'renewalReminderDays',
    ] as const)
      if (input[field] !== undefined)
        data[field] = integerInput(input[field], field, 1);
    if (input.reminderTimeMinutes !== undefined)
      data.reminderTimeMinutes = integerInput(
        input.reminderTimeMinutes,
        'reminderTimeMinutes',
        0,
        1439,
      );
    return businessWrite(
      this.prisma,
      actor,
      creating ? 'memberships.create' : 'memberships.update',
      input,
      async (transaction) => {
        // 分类兼容名称与规范关系统一解释，标签ID仍保持原有独立语义。
        const selected: Record<string, string[]> = {};
        // 此处不能使用提交前的模型名称替代规范分类名称。
        const category = await resolveNamedTaxonomy(
          transaction,
          actor.sub,
          'membership',
          'category',
          input,
        );
        if (category) {
          selected.category = category.ids;
          data.category = category.name;
        }
        if (input.tagIds !== undefined)
          selected.tag = idsInput(input.tagIds, 'tagIds');
        // 当前状态在 owner 锁内读取。
        const id = creating ? randomUUID() : uuidInput(input.id);
        // 创建与修改都使用同一个有效期规则。
        const current = creating
          ? null
          : requireActive(
              await transaction.membership.findFirst({
                where: { id, userId: actor.sub },
              }),
            );
        // 永久标记与到期日期不能相互矛盾。
        const permanent = data.isPermanent ?? current?.isPermanent ?? false;
        // null 是明确清空，缺省才继承。
        const expiration =
          data.expirationDate === undefined
            ? (current?.expirationDate ?? null)
            : data.expirationDate;
        if ((permanent && expiration) || (!permanent && !expiration))
          throw new BadRequestException(
            '永久会员不能设置到期日，周期会员必须设置到期日',
          );
        if (permanent) {
          data.billingCycle = 'permanent';
          data.expirationReminderEnabled = false;
          data.renewalReminderEnabled = false;
        } else if ((data.billingCycle ?? current?.billingCycle) === 'permanent')
          throw new BadRequestException('周期会员需要有效计费周期');
        if ((data.autoRenew ?? current?.autoRenew ?? false) === false)
          data.renewalReminderEnabled = false;
        if (creating) {
          // 主记录先建立，关联与账目仍在同一事务。
          const member = await transaction.membership.create({
            data: {
              ...data,
              id,
              userId: actor.sub,
              name: data.name!,
              purchaseDate: data.purchaseDate!,
            },
          });
          if (member.priceCents > 0)
            await transaction.membershipPayment.create({
              data: {
                id: randomUUID(),
                userId: actor.sub,
                membershipId: id,
                amountCents: member.priceCents,
                paidAt: localInstant(
                  member.purchaseDate.toISOString().slice(0, 10),
                  0,
                  timeZone,
                ),
                validFrom: member.purchaseDate,
                validUntil: member.expirationDate,
              },
            });
        } else await transaction.membership.update({ where: { id }, data });
        await replaceTaxonomies(
          transaction,
          actor.sub,
          'membership',
          id,
          selected,
        );
        return transaction.membership.findUniqueOrThrow({ where: { id } });
      },
    );
  }

  /// 记录账目并推进到期时间；不调用真实支付渠道。
  recordPayment(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 自动补账仍留在现有调度，不接受模型假冒自动标记。
    const input = objectInput(value, [
      'operationId',
      'membershipId',
      'amountCents',
      'paidAt',
      'timeZone',
      'billingCycle',
      'validUntil',
      'notes',
    ]);
    // 目标会员必须有效。
    const membershipId = uuidInput(input.membershipId, 'membershipId');
    // 金额使用整数分值。
    const amountCents = integerInput(input.amountCents, 'amountCents');
    // 账期自然日由指定地区提取。
    const timeZone = timeZoneInput(input.timeZone);
    // 省略时间表示现在，在首次执行后由回执固定。
    const paid =
      input.paidAt === undefined ? null : instantInput(input.paidAt, 'paidAt');
    // 可选备注。
    const notes = textInput(input.notes, 'notes', 20000, true);
    // 自定义结束日不是服务器时间点。
    const until =
      input.validUntil === undefined || input.validUntil === null
        ? null
        : dayInput(input.validUntil, 'validUntil');
    // 传入周期覆盖本笔，不擅自改会员长期策略。
    const selectedCycle =
      input.billingCycle === undefined
        ? null
        : enumInput(input.billingCycle, 'billingCycle', billingCycles);
    return businessWrite(
      this.prisma,
      actor,
      'memberships.recordPayment',
      input,
      async (transaction) => {
        // 全部账期变更基于最新已提交值计算。
        const member = requireActive(
          await transaction.membership.findFirst({
            where: { id: membershipId, userId: actor.sub },
          }),
        );
        // 本笔支付的真实时间。
        const paidAt = paid ?? new Date();
        // 本笔账目用自己的支付日作为有效期起点。
        const day = localParts(paidAt, timeZone).day;
        // 标准续费从当前到期日叠加，而非 max(now, expiration)。
        const cycle = selectedCycle ?? member.billingCycle;
        if (!member.isPermanent && cycle === 'permanent')
          throw new BadRequestException('周期会员不能按永久周期记账');
        if (
          !member.isPermanent &&
          cycle === 'custom' &&
          (!until || until <= day)
        )
          throw new BadRequestException('自定义周期的结束日必须晚于支付日');
        // 本笔有效期与会员总到期日分别计算。
        const paymentEnd = member.isPermanent
          ? null
          : cycle === 'custom'
            ? until
            : membershipPeriodEnd(day, cycle);
        // 到期日列只按自然日做日历运算。
        const expiration = member.isPermanent
          ? null
          : cycle === 'custom'
            ? until
            : membershipPeriodEnd(
                member.expirationDate?.toISOString().slice(0, 10) ?? day,
                cycle,
              );
        // 与会员到期信息同事务的账目。
        const payment = await transaction.membershipPayment.create({
          data: {
            id: randomUUID(),
            userId: actor.sub,
            membershipId,
            amountCents,
            paidAt,
            validFrom: new Date(`${day}T00:00:00Z`),
            validUntil: paymentEnd ? new Date(`${paymentEnd}T00:00:00Z`) : null,
            notes,
          },
        });
        if (expiration)
          await transaction.membership.update({
            where: { id: membershipId },
            data: {
              expirationDate: new Date(`${expiration}T00:00:00Z`),
              ...(member.autoRenew
                ? { renewalDate: new Date(`${expiration}T00:00:00Z`) }
                : {}),
            },
          });
        return {
          payment,
          membership: await transaction.membership.findUniqueOrThrow({
            where: { id: membershipId },
          }),
        };
      },
    );
  }

  /// 删除账目准确回退账期，首购与自动续费按既有语义区分。
  deletePayment(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 作用范围只包含具体会员与账目。
    const input = objectInput(value, [
      'operationId',
      'membershipId',
      'paymentId',
      'timeZone',
    ]);
    // 父记录身份。
    const membershipId = uuidInput(input.membershipId, 'membershipId');
    // 要撤销的账目身份。
    const paymentId = uuidInput(input.paymentId, 'paymentId');
    // 旧账目缺 validFrom 时使用明确时区兜底。
    const timeZone = timeZoneInput(input.timeZone);
    return businessWrite(
      this.prisma,
      actor,
      'memberships.deletePayment',
      input,
      async (transaction) => {
        // 会员必须仍在正式列表中。
        const member = requireActive(
          await transaction.membership.findFirst({
            where: { id: membershipId, userId: actor.sub },
          }),
        );
        // 父子归属都要匹配。
        const payment = await transaction.membershipPayment.findFirst({
          where: {
            id: paymentId,
            userId: actor.sub,
            membershipId,
            deletedAt: null,
          },
        });
        if (!payment) throw new NotFoundException('支付记录不存在或已删除');
        // 包括已删除历史，不能删除一次后重判首购。
        const earliest = await transaction.membershipPayment.findFirstOrThrow({
          where: { userId: actor.sub, membershipId },
          orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
        });
        // 统计业务日不受服务器地区影响。
        const day =
          payment.validFrom?.toISOString().slice(0, 10) ??
          localParts(payment.paidAt, timeZone).day;
        // 首购识别与客户端相同。
        const initialPurchase =
          earliest.id === payment.id &&
          day === member.purchaseDate.toISOString().slice(0, 10);
        // 自动账期必须验证稳定身份，不能依据备注猜测。
        const automatic =
          payment.id === stableBusinessId('auto-renewal', [membershipId, day]);
        // 实际回退天数，永久或首购为零。
        let deductedDays = 0;
        // 到期日缺省保持，仅续费撤销计算回退。
        let expiration = member.expirationDate;
        if (!initialPurchase && !member.isPermanent) {
          if (!payment.validFrom || !payment.validUntil || !expiration)
            throw new ConflictException('缺少完整账期，无法安全撤销');
          deductedDays = Math.round(
            (payment.validUntil.getTime() - payment.validFrom.getTime()) /
              86400000,
          );
          if (deductedDays <= 0)
            throw new ConflictException('支付有效期必须为正');
          expiration = new Date(
            `${addDays(expiration.toISOString().slice(0, 10), -deductedDays)}T00:00:00Z`,
          );
          if (expiration < member.purchaseDate)
            throw new ConflictException('撤销后到期日将早于购买日');
        }
        await transaction.membershipPayment.update({
          where: { id: paymentId },
          data: { deletedAt: new Date() },
        });
        if (deductedDays || automatic)
          await transaction.membership.update({
            where: { id: membershipId },
            data: {
              expirationDate: expiration,
              ...(automatic
                ? {
                    autoRenew: false,
                    renewalDate: null,
                    renewalReminderEnabled: false,
                  }
                : member.autoRenew
                  ? { renewalDate: expiration }
                  : {}),
            },
          });
        return {
          deductedDays,
          initialPurchase,
          autoRenewDisabled: automatic,
          membership: await transaction.membership.findUniqueOrThrow({
            where: { id: membershipId },
          }),
        };
      },
    );
  }

  /// 有界读取一份有效会员的账目。
  payments(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 不接受任意支付表查询条件。
    const input = objectInput(value, ['membershipId', 'limit', 'offset']);
    // 具体会员。
    const membershipId = uuidInput(input.membershipId, 'membershipId');
    // 明确分页状态。
    const page = pageInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      requireActive(
        await transaction.membership.findFirst({
          where: { userId: actor.sub, id: membershipId },
        }),
      );
      return pageResult(
        await transaction.membershipPayment.findMany({
          where: { userId: actor.sub, membershipId, deletedAt: null },
          orderBy: [{ paidAt: 'desc' }, { id: 'asc' }],
          skip: page.skip,
          take: page.take + 1,
        }),
        page,
      );
    });
  }

  /// 会员软删除保留支付历史，回收站统计排除父会员。
  trash(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 删除不等于真实退订。
    const input = objectInput(value, ['operationId', 'id']);
    // 正式记录身份。
    const id = uuidInput(input.id);
    return businessWrite(
      this.prisma,
      actor,
      'memberships.trash',
      input,
      async (transaction) => {
        requireActive(
          await transaction.membership.findFirst({
            where: { userId: actor.sub, id },
          }),
        );
        return transaction.membership.update({
          where: { id },
          data: { deletedAt: new Date() },
        });
      },
    );
  }

  /// 周/月支出按账目自然日统计，不从分页或到期日期推算费用。
  statistics(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 范围与业务时区是统计事实。
    const input = objectInput(value, ['from', 'to', 'timeZone', 'asOf']);
    // 所有读取使用同一快照及截止点。
    const range = rangeInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      // 旧数据需要按时区兜底，完整读取有效会员账目再筛业务日。
      const payments = await transaction.membershipPayment.findMany({
        where: {
          userId: actor.sub,
          deletedAt: null,
          membership: { deletedAt: null },
        },
        select: {
          id: true,
          membershipId: true,
          amountCents: true,
          paidAt: true,
          validFrom: true,
        },
      });
      // 起止点都以自然日表达，与客户端按年/月统计一致。
      const fromDay = localParts(range.from, range.timeZone).day;
      // 右边界自然日不计入当前周期。
      const toDay = localParts(range.to, range.timeZone).day;
      // DATE 优先，旧账目仅在缺失时使用 paidAt 的当地日期。
      const selected = payments.filter((payment) => {
        // 原自然日优先，旧数据才从支付时间点推导。
        const day =
          payment.validFrom?.toISOString().slice(0, 10) ??
          localParts(payment.paidAt, range.timeZone).day;
        // 日期列按地区自然日起点进入窗口。
        const at = localInstant(day, 0, range.timeZone);
        return (
          at >= range.from && at < range.to && payment.paidAt <= range.asOf
        );
      });
      // 全部会员当前状态不依赖分页。
      const members = await transaction.membership.findMany({
        where: { userId: actor.sub, deletedAt: null },
      });
      // 状态计数可用于到期分析。
      const statuses: Record<string, number> = {};
      for (const member of members) {
        // 统计状态与列表使用同一纯计算函数。
        const status = membershipStatus(member, range.timeZone, range.asOf);
        statuses[status] = (statuses[status] ?? 0) + 1;
      }
      return {
        ...range,
        fromDay,
        toDay,
        paymentCount: selected.length,
        amountCents: selected.reduce(
          (sum, payment) => sum + payment.amountCents,
          0,
        ),
        membershipCount: members.length,
        statuses,
        complete: true,
        unit: 'cents',
        sourceIds: selected.slice(0, 200).map((payment) => payment.id),
        sourcesTruncated: selected.length > 200,
      };
    });
  }
}
