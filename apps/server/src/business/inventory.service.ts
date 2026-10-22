import {
  BadRequestException,
  ConflictException,
  Injectable,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../auth/auth.types';
import type { InventoryItem, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  businessRead,
  businessWrite,
  replaceTaxonomies,
  resolveNamedTaxonomy,
  requireActive,
} from './business-access';
import {
  booleanInput,
  dayInput,
  enumInput,
  idsInput,
  integerInput,
  localInstant,
  objectInput,
  pageInput,
  pageResult,
  calendarRangeInput,
  textInput,
  taxonomyTextInput,
  urlInput,
  uuidInput,
} from './business-input';

/// 仅包含当前物品真正可编辑的标量字段。
type InventoryFields = Pick<
  InventoryItem,
  | 'name'
  | 'category'
  | 'quantity'
  | 'purchasePriceCents'
  | 'purchaseDate'
  | 'location'
  | 'purchaseUrl'
  | 'purchasePlatform'
  | 'status'
  | 'warrantyExpiration'
  | 'tags'
  | 'parentItemId'
  | 'notes'
>;
/// 物品写入白名单，不含归属、创建时间和回收站列。
const inventoryFields = [
  'name',
  'category',
  'quantity',
  'purchasePriceCents',
  'purchaseDate',
  'location',
  'purchaseUrl',
  'purchasePlatform',
  'status',
  'warrantyExpiration',
  'tags',
  'parentItemId',
  'notes',
  'categoryIds',
  'locationIds',
] as const;

/// 将已选择字段转换为受限数据库更新，不清空缺省字段。
function inventoryData(
  input: Record<string, unknown>,
): Partial<InventoryFields> {
  // 全部值经各自规则校验后才进入持久化。
  const data: Partial<InventoryFields> = {};
  if (input.name !== undefined) data.name = textInput(input.name, 'name')!;
  for (const field of ['category', 'location'] as const)
    if (input[field] !== undefined)
      data[field] = taxonomyTextInput(input[field], field);
  if (input.purchasePlatform !== undefined)
    data.purchasePlatform = textInput(
      input.purchasePlatform,
      'purchasePlatform',
      200,
      true,
    );
  if (input.notes !== undefined)
    data.notes = textInput(input.notes, 'notes', 20000, true);
  if (input.quantity !== undefined)
    data.quantity = integerInput(input.quantity, 'quantity', 1);
  if (input.purchasePriceCents !== undefined)
    data.purchasePriceCents =
      input.purchasePriceCents === null
        ? null
        : integerInput(input.purchasePriceCents, 'purchasePriceCents');
  if (input.purchaseUrl !== undefined)
    data.purchaseUrl = urlInput(input.purchaseUrl, 'purchaseUrl');
  if (input.status !== undefined)
    data.status = enumInput(input.status, 'status', [
      'inUse',
      'idle',
      'lent',
      'sold',
      'discarded',
    ]);
  for (const field of ['purchaseDate', 'warrantyExpiration'] as const)
    if (input[field] !== undefined)
      data[field] =
        input[field] === null
          ? null
          : new Date(`${dayInput(input[field], field)}T00:00:00Z`);
  if (input.parentItemId !== undefined)
    data.parentItemId =
      input.parentItemId === null
        ? null
        : uuidInput(input.parentItemId, 'parentItemId');
  if (input.tags !== undefined) {
    if (!Array.isArray(input.tags) || input.tags.length > 200)
      throw new BadRequestException('tags 必须为文字数组');
    // 与客户端相同，以逗号保存去重后的标签文字。
    const tags = [
      ...new Set(
        input.tags.map(
          (tag: unknown) => taxonomyTextInput(tag, 'tags', false)!,
        ),
      ),
    ];
    data.tags = tags.length ? tags.join(',') : null;
  }
  return data;
}

/// 物品与配件业务，包括原子关系保存和搬家。
@Injectable()
export class InventoryService {
  /// 注入现有数据库服务。
  constructor(private readonly prisma: PrismaService) {}

  /// 搜索主物品时保留“配件命中返回父物品”的现有语义。
  list(actor: AuthUser, value: unknown = {}): Promise<Prisma.JsonValue> {
    // 查询不会执行位置初始化或迁移。
    const input = objectInput(value, [
      'query',
      'status',
      'includeAccessories',
      'parentItemId',
      'limit',
      'offset',
    ]);
    // 可读页大小。
    const page = pageInput(input);
    // 可选全文筛选。
    const query = textInput(input.query, 'query', 200, true);
    // 配件默认由父物品详情呈现。
    const includeAccessories =
      input.includeAccessories === undefined
        ? false
        : booleanInput(input.includeAccessories, 'includeAccessories');
    // 明确指定父项时查询其配件。
    const parentItemId =
      input.parentItemId === undefined
        ? undefined
        : uuidInput(input.parentItemId, 'parentItemId');
    // 状态仅接受现有五种。
    const status =
      input.status === undefined
        ? undefined
        : enumInput(input.status, 'status', [
            'inUse',
            'idle',
            'lent',
            'sold',
            'discarded',
          ]);
    // 相同字段匹配复用于父项与配件。
    const search: Prisma.InventoryItemWhereInput = query
      ? {
          OR: [
            'name',
            'category',
            'location',
            'tags',
            'status',
            'purchasePlatform',
            'notes',
          ].map((field) => ({
            [field]: { contains: query, mode: 'insensitive' },
          })),
        }
      : {};
    return businessRead(this.prisma, actor, async (transaction) => {
      if (parentItemId)
        requireActive(
          await transaction.inventoryItem.findFirst({
            where: { id: parentItemId, userId: actor.sub },
          }),
        );
      return pageResult(
        await transaction.inventoryItem.findMany({
          where: {
            userId: actor.sub,
            deletedAt: null,
            status,
            ...(parentItemId
              ? { parentItemId }
              : includeAccessories
                ? {}
                : { parentItemId: null }),
            ...(query
              ? {
                  OR: [
                    search,
                    {
                      accessories: {
                        some: { userId: actor.sub, deletedAt: null, ...search },
                      },
                    },
                  ],
                }
              : {}),
          },
          orderBy: [
            { purchaseDate: { sort: 'desc', nulls: 'last' } },
            { name: 'asc' },
            { id: 'asc' },
          ],
          skip: page.skip,
          take: page.take + 1,
        }),
        page,
      );
    });
  }

  /// 详情附有效直属配件和规范引用身份。
  get(actor: AuthUser, id: string): Promise<Prisma.JsonValue> {
    uuidInput(id);
    return businessRead(this.prisma, actor, async (transaction) => ({
      ...requireActive(
        await transaction.inventoryItem.findFirst({
          where: { id, userId: actor.sub },
          include: {
            accessories: {
              where: { deletedAt: null },
              orderBy: [{ name: 'asc' }, { id: 'asc' }],
            },
          },
        }),
      ),
      links: await transaction.recordTaxonomyLink.findMany({
        where: {
          userId: actor.sub,
          module: 'inventory',
          recordId: id,
          deletedAt: null,
          taxonomy: { deletedAt: null },
        },
        select: {
          taxonomyId: true,
          taxonomy: { select: { name: true, kind: true } },
        },
      }),
    }));
  }

  /// 新增本体及规范分类位置在同一事务保存。
  create(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 模型只提供业务字段。
    const input = objectInput(value, ['operationId', ...inventoryFields]);
    if (input.name === undefined) throw new BadRequestException('需要物品名称');
    return this.save(actor, input, true);
  }

  /// 编辑支持明确状态更新与配件绑定/解绑。
  update(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 不允许修改服务器维护列。
    const input = objectInput(value, ['operationId', 'id', ...inventoryFields]);
    uuidInput(input.id);
    return this.save(actor, input, false);
  }

  /// 共用写入规则仅覆盖本业务的实际新增与修改入口。
  private save(
    actor: AuthUser,
    input: Record<string, unknown>,
    creating: boolean,
  ): Promise<Prisma.JsonValue> {
    // 请求中的业务值先独立校验。
    const data = inventoryData(input);
    return businessWrite(
      this.prisma,
      actor,
      creating ? 'inventory.create' : 'inventory.update',
      input,
      async (transaction) => {
        // 只处理明确选择的分类种类，名称更新与ID关系始终在同一事务保存。
        const selected: Record<string, string[]> = {};
        for (const kind of ['category', 'location'] as const) {
          // 规范身份推导名称，兼容名称推导唯一身份或解除旧关系。
          const selection = await resolveNamedTaxonomy(
            transaction,
            actor.sub,
            'inventory',
            kind,
            input,
          );
          if (selection) {
            selected[kind] = selection.ids;
            data[kind] = selection.name;
          }
        }
        // 目标身份由服务端创建，编辑则必须存在。
        const id = creating ? randomUUID() : uuidInput(input.id);
        // 当前数据在事务内核验。
        const current = creating
          ? null
          : requireActive(
              await transaction.inventoryItem.findFirst({
                where: { userId: actor.sub, id },
              }),
            );
        // 缺省父关系保持，null 表示明确解除。
        const parentId =
          data.parentItemId === undefined
            ? current?.parentItemId
            : data.parentItemId;
        if (parentId) {
          // 配件只能属于有效主物品，禁止自引用、多层及循环。
          const parent = requireActive(
            await transaction.inventoryItem.findFirst({
              where: { userId: actor.sub, id: parentId },
            }),
          );
          if (
            parent.id === id ||
            parent.parentItemId !== null ||
            (await transaction.inventoryItem.count({
              where: { userId: actor.sub, parentItemId: id },
            }))
          )
            throw new ConflictException(
              '配件只允许两层，不能形成循环或移动带配件的主物品',
            );
        }
        if (creating)
          await transaction.inventoryItem.create({
            data: { ...data, id, userId: actor.sub, name: data.name! },
          });
        else await transaction.inventoryItem.update({ where: { id }, data });
        await replaceTaxonomies(
          transaction,
          actor.sub,
          'inventory',
          id,
          selected,
        );
        return transaction.inventoryItem.findUniqueOrThrow({ where: { id } });
      },
    );
  }

  /// 搬家保留独立位置配件和未选择配件的边界。
  move(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 批量作用范围显式列出，不允许工具选择任意 where。
    const input = objectInput(value, [
      'operationId',
      'ids',
      'destinationLocationId',
    ]);
    // 受控目标集合。
    const ids = idsInput(input.ids, 'ids');
    if (!ids.length) throw new BadRequestException('请选择需要搬家的物品');
    // 已有规范位置身份。
    const destinationId = uuidInput(
      input.destinationLocationId,
      'destinationLocationId',
    );
    return businessWrite(
      this.prisma,
      actor,
      'inventory.move',
      input,
      async (transaction) => {
        // 位置归属、模块、类型与开关均检查。
        const destination = await transaction.taxonomyEntry.findFirst({
          where: {
            id: destinationId,
            userId: actor.sub,
            module: 'inventory',
            kind: 'location',
            deletedAt: null,
            isEnabled: true,
          },
        });
        if (!destination) throw new ConflictException('目标位置不可用');
        // 缺失记录单独报告，不扩大作用集合。
        const rows = await transaction.inventoryItem.findMany({
          where: { userId: actor.sub, id: { in: ids }, deletedAt: null },
        });
        // 当前有效位置关系。
        const links = await transaction.recordTaxonomyLink.findMany({
          where: {
            userId: actor.sub,
            recordId: { in: ids },
            module: 'inventory',
            deletedAt: null,
            taxonomy: { kind: 'location' },
          },
        });
        // 用于判断主项是否会实际迁移。
        const byId = new Map(rows.map((row) => [row.id, row]));
        // 结果分别列出，便于显示真实影响。
        const moved: string[] = [],
          followed: string[] = [],
          unchanged: string[] = [];
        // 位置是否已经规范为目标。
        const alreadyThere = (row: InventoryItem): boolean =>
          row.location?.trim() === destination.name &&
          links.filter((link) => link.recordId === row.id).length === 1 &&
          links.some(
            (link) =>
              link.recordId === row.id && link.taxonomyId === destinationId,
          );
        for (const row of rows) {
          // 无独立位置的已选配件跟随已选主项，不新增位置覆盖。
          const parent = row.parentItemId
            ? byId.get(row.parentItemId)
            : undefined;
          if (
            parent &&
            !row.location?.trim() &&
            !links.some((link) => link.recordId === row.id)
          ) {
            (alreadyThere(parent) ? unchanged : followed).push(row.id);
            continue;
          }
          if (alreadyThere(row)) {
            unchanged.push(row.id);
            continue;
          }
          await replaceTaxonomies(transaction, actor.sub, 'inventory', row.id, {
            location: [destinationId],
          });
          await transaction.inventoryItem.update({
            where: { id: row.id },
            data: { location: destination.name },
          });
          moved.push(row.id);
        }
        return {
          destinationName: destination.name,
          moved,
          followed,
          unchanged,
          missing: ids.filter((id) => !byId.has(id)),
        };
      },
    );
  }

  /// 父项及直属配件同批软删，保留恢复关系。
  trash(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 删除仅选择具体身份。
    const input = objectInput(value, ['operationId', 'id']);
    // 所有影响在同一 owner 下。
    const id = uuidInput(input.id);
    return businessWrite(
      this.prisma,
      actor,
      'inventory.trash',
      input,
      async (transaction) => {
        requireActive(
          await transaction.inventoryItem.findFirst({
            where: { id, userId: actor.sub },
          }),
        );
        // 同一个删除时间便于原有客户端恢复同批父子。
        const deletedAt = new Date();
        return transaction.inventoryItem.updateMany({
          where: {
            userId: actor.sub,
            OR: [{ id }, { parentItemId: id }],
            deletedAt: null,
          },
          data: { deletedAt },
        });
      },
    );
  }

  /// 完整有效集合统计；购买金额已是每条记录总额，不再乘数量。
  statistics(actor: AuthUser, value: unknown = {}): Promise<Prisma.JsonValue> {
    // 显式说明是否包含配件，避免重复计价。
    const input = objectInput(value, [
      'includeAccessories',
      'from',
      'to',
      'timeZone',
    ]);
    // 默认只统计主物品。
    const includeAccessories =
      input.includeAccessories === undefined
        ? false
        : booleanInput(input.includeAccessories, 'includeAccessories');
    // 有日期窗口时统计购买事实，不宣称重建过去时点的物品状态。
    const range =
      input.from !== undefined || input.to !== undefined
        ? calendarRangeInput(input)
        : null;
    return businessRead(this.prisma, actor, async (transaction) => {
      // 全量统计不使用分页列表。
      const available = await transaction.inventoryItem.findMany({
        where: {
          userId: actor.sub,
          deletedAt: null,
          ...(includeAccessories ? {} : { parentItemId: null }),
        },
        select: {
          id: true,
          quantity: true,
          purchasePriceCents: true,
          purchaseDate: true,
          status: true,
          category: true,
          location: true,
        },
      });
      // 缺少购买日期的记录不混入窗口统计。
      const rows = range
        ? available.filter((row) => {
            if (!row.purchaseDate) return false;
            // 购买日期按所选地区的自然日起点归属统计窗口。
            const at = localInstant(
              row.purchaseDate.toISOString().slice(0, 10),
              0,
              range.timeZone,
            );
            return at >= range.from && at < range.to;
          })
        : available;
      // 状态数量采用记录数口径。
      const statuses: Record<string, number> = Object.create(null) as Record<
        string,
        number
      >;
      // 自定义分类/位置名称不能作为普通对象原型属性使用。
      const categories = new Map<
          string,
          { count: number; amountCents: number }
        >(),
        locations = new Map<string, number>();
      for (const row of rows)
        statuses[row.status] = (statuses[row.status] ?? 0) + 1;
      for (const row of rows) {
        // 缺少分类使用明确展示桶，不丢弃该记录。
        const key = row.category ?? '未分类';
        // 已累计金额是每条记录总额。
        const prior = categories.get(key) ?? { count: 0, amountCents: 0 };
        categories.set(key, {
          count: prior.count + 1,
          amountCents: prior.amountCents + (row.purchasePriceCents ?? 0),
        });
        locations.set(
          row.location ?? '未指定',
          (locations.get(row.location ?? '未指定') ?? 0) + 1,
        );
      }
      return {
        ...(range ?? {}),
        basis: range ? 'purchaseDate' : 'currentRecords',
        count: rows.length,
        quantity: rows.reduce((sum, row) => sum + row.quantity, 0),
        purchasePriceCents: rows.reduce(
          (sum, row) => sum + (row.purchasePriceCents ?? 0),
          0,
        ),
        statuses,
        categories: Object.fromEntries(categories),
        locations: Object.fromEntries(locations),
        includeAccessories,
        complete: true,
        unit: 'cents',
        sourceIds: rows.slice(0, 200).map((row) => row.id),
        sourcesTruncated: rows.length > 200,
      };
    });
  }
}
