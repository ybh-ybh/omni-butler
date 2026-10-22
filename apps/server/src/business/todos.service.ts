import {
  BadRequestException,
  ConflictException,
  Injectable,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../auth/auth.types';
import type { Prisma, TodoItem } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { reconcileTodos, stableBusinessId } from '../sync/sync-consistency';
import { businessRead, businessWrite, requireActive } from './business-access';
import {
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
  timeZoneInput,
  uuidInput,
} from './business-input';

/// 待办基本字段与聚合动作分开，不允许随意写完成状态。
const todoFields = [
  'title',
  'taskType',
  'description',
  'scheduledDate',
  'dueAt',
  'reminderAt',
  'priorityQuadrant',
  'parentId',
  'progressUnit',
  'repeatRule',
] as const;
/// 同步协议中的最大新增进度结构保持不变。
const maxProgressSteps = 1000;
/// 步骤名称和顺序基线不混入步骤状态。
interface StepDraft {
  /// 缺少身份表示本次明确新增。
  id: string | null;
  /// 无名步骤用 null，不保存展示序号。
  name: string | null;
}

/// 校验步骤草稿，允许既有超限结构减少或保持。
function stepDrafts(value: unknown, allowEmpty = false): StepDraft[] {
  if (
    !Array.isArray(value) ||
    (!allowEmpty && !value.length) ||
    value.length > 100000
  )
    throw new BadRequestException('需要非空进度步骤数组');
  return value.map((item: unknown) => {
    // 步骤输入不可设置任意状态或归属。
    const input = objectInput(item, ['id', 'name']);
    return {
      id: input.id === undefined ? null : uuidInput(input.id, 'step.id'),
      name: textInput(input.name, 'step.name', 200, true),
    };
  });
}

/// 重复日历只基于自然日，月末截断与客户端一致。
export function todoOccursOn(
  seed: Pick<TodoItem, 'scheduledDate' | 'repeatRule'>,
  day: string,
): boolean {
  // 初始日为重复周期的固定锚点。
  const first = seed.scheduledDate.toISOString().slice(0, 10);
  if (day < first) return false;
  // 自然日差不使用部署地区的 DST 时长。
  const days = Math.round(
    (Date.parse(`${day}T00:00:00Z`) - seed.scheduledDate.getTime()) / 86400000,
  );
  if (seed.repeatRule === 'daily') return true;
  if (seed.repeatRule === 'weekly') return days % 7 === 0;
  if (seed.repeatRule !== 'monthly') return false;
  // 月差由目标年月与种子年月计算。
  const months =
    (Number(day.slice(0, 4)) - Number(first.slice(0, 4))) * 12 +
    Number(day.slice(5, 7)) -
    Number(first.slice(5, 7));
  return addMonths(first, months) === day;
}

/// 普通父子、进度步骤和重复系列的真实业务入口。
@Injectable()
export class TodosService {
  /// 复用现有数据库。
  constructor(private readonly prisma: PrismaService) {}

  /// 纯列表不物化重复实例，明确返回当前已保存的记录。
  list(actor: AuthUser, value: unknown = {}): Promise<Prisma.JsonValue> {
    // 查询作用范围由业务字段限定。
    const input = objectInput(value, [
      'query',
      'fromDay',
      'toDay',
      'completed',
      'limit',
      'offset',
    ]);
    // 受控分页。
    const page = pageInput(input);
    // 可选标题搜索。
    const query = textInput(input.query, 'query', 200, true);
    // 计划自然日范围左闭右开。
    const from =
      input.fromDay === undefined
        ? undefined
        : new Date(`${dayInput(input.fromDay, 'fromDay')}T00:00:00Z`);
    // 缺省表示不按计划日期截断。
    const to =
      input.toDay === undefined
        ? undefined
        : new Date(`${dayInput(input.toDay, 'toDay')}T00:00:00Z`);
    if (from && to && to <= from)
      throw new BadRequestException('计划日期范围必须为正');
    // 未指定完成状态时允许查询全部正式任务。
    const completed =
      input.completed === undefined
        ? undefined
        : booleanInput(input.completed, 'completed');
    return businessRead(this.prisma, actor, async (transaction) => ({
      ...pageResult(
        await transaction.todoItem.findMany({
          where: {
            userId: actor.sub,
            deletedAt: null,
            isCompleted: completed,
            scheduledDate: { gte: from, lt: to },
            ...(query
              ? { title: { contains: query, mode: 'insensitive' } }
              : {}),
          },
          include: {
            progressSteps: {
              where: { deletedAt: null },
              orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
            },
          },
          orderBy: [
            { scheduledDate: 'asc' },
            { priorityQuadrant: 'asc' },
            { sortOrder: 'asc' },
            { id: 'asc' },
          ],
          skip: page.skip,
          take: page.take + 1,
        }),
        page,
      ),
      includesUnmaterializedRecurring: false,
    }));
  }

  /// 详情包含有效直属孩子和进度步骤。
  get(actor: AuthUser, id: string): Promise<Prisma.JsonValue> {
    uuidInput(id);
    return businessRead(this.prisma, actor, async (transaction) =>
      requireActive(
        await transaction.todoItem.findFirst({
          where: { userId: actor.sub, id },
          include: {
            subtasks: {
              where: { deletedAt: null },
              orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
            },
            progressSteps: {
              where: { deletedAt: null },
              orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
            },
          },
        }),
      ),
    );
  }

  /// 创建任务与初始进度结构在同一事务完成。
  create(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 新步骤不接受人为预置完成状态。
    const input = objectInput(value, ['operationId', 'steps', ...todoFields]);
    if (input.title === undefined || input.scheduledDate === undefined)
      throw new BadRequestException('需要待办标题和计划日期');
    return this.save(actor, input, true);
  }

  /// 单条或未来系列编辑，不更改任务类型或完成事实。
  update(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 进度结构通过独立基线接口修改。
    const input = objectInput(value, [
      'operationId',
      'id',
      'scope',
      'timeZone',
      ...todoFields,
    ]);
    uuidInput(input.id);
    return this.save(actor, input, false);
  }

  /// 只共享创建/编辑的当前业务校验，不生成通用 CRUD 层。
  private save(
    actor: AuthUser,
    input: Record<string, unknown>,
    creating: boolean,
  ): Promise<Prisma.JsonValue> {
    // 基本可写字段均为标量。
    const data: Partial<
      Pick<
        TodoItem,
        | 'title'
        | 'taskType'
        | 'description'
        | 'scheduledDate'
        | 'dueAt'
        | 'reminderAt'
        | 'priorityQuadrant'
        | 'parentId'
        | 'progressUnit'
        | 'repeatRule'
      >
    > = {};
    if (input.title !== undefined)
      data.title = textInput(input.title, 'title')!;
    if (input.description !== undefined)
      data.description = textInput(
        input.description,
        'description',
        20000,
        true,
      );
    if (input.scheduledDate !== undefined)
      data.scheduledDate = new Date(
        `${dayInput(input.scheduledDate, 'scheduledDate')}T00:00:00Z`,
      );
    if (input.taskType !== undefined)
      data.taskType = enumInput(input.taskType, 'taskType', [
        'normal',
        'progress',
      ]);
    for (const field of ['dueAt', 'reminderAt'] as const)
      if (input[field] !== undefined)
        data[field] =
          input[field] === null ? null : instantInput(input[field], field);
    if (data.reminderAt && data.reminderAt < new Date())
      throw new BadRequestException('提醒时间不能早于当前时间');
    if (input.priorityQuadrant !== undefined)
      data.priorityQuadrant = integerInput(
        input.priorityQuadrant,
        'priorityQuadrant',
        0,
        3,
      );
    if (input.parentId !== undefined)
      data.parentId =
        input.parentId === null ? null : uuidInput(input.parentId, 'parentId');
    if (input.progressUnit !== undefined)
      data.progressUnit = textInput(
        input.progressUnit,
        'progressUnit',
        10,
        true,
      );
    if (input.repeatRule !== undefined)
      data.repeatRule =
        input.repeatRule === null || input.repeatRule === 'none'
          ? null
          : enumInput(input.repeatRule, 'repeatRule', [
              'daily',
              'weekly',
              'monthly',
            ]);
    // 未来范围与单条修改明确区分。
    const scope =
      creating || input.scope === undefined
        ? 'single'
        : enumInput(input.scope, 'scope', ['single', 'future']);
    // 初始步骤只用于创建进度任务。
    const initialSteps =
      input.steps === undefined ? null : stepDrafts(input.steps);
    if (
      initialSteps &&
      (initialSteps.length > maxProgressSteps ||
        initialSteps.some((step) => step.id))
    )
      throw new BadRequestException('新增最多 1000 步且不能预设步骤身份');
    return businessWrite(
      this.prisma,
      actor,
      creating ? 'todos.create' : 'todos.update',
      input,
      async (transaction) => {
        // 当前目标由服务器分配或事务内读取。
        const id = creating ? randomUUID() : uuidInput(input.id);
        // 任务类型一经保存不可转换。
        const current = creating
          ? null
          : requireActive(
              await transaction.todoItem.findFirst({
                where: { userId: actor.sub, id },
              }),
            );
        if (
          current &&
          data.taskType !== undefined &&
          current.taskType !== data.taskType
        )
          throw new ConflictException('创建后不能转换待办类型');
        // 进度任务独立于普通父子和重复系列。
        const taskType = data.taskType ?? current?.taskType ?? 'normal';
        // null 才表示明确解除父关系。
        const parentId =
          data.parentId === undefined
            ? (current?.parentId ?? null)
            : data.parentId;
        // 父任务仍需是有效普通主任务。
        const parent = parentId
          ? requireActive(
              await transaction.todoItem.findFirst({
                where: { id: parentId, userId: actor.sub },
              }),
            )
          : null;
        if (
          parent &&
          (parent.id === id ||
            parent.parentId !== null ||
            parent.taskType !== 'normal' ||
            taskType === 'progress' ||
            (await transaction.todoItem.count({
              where: { userId: actor.sub, parentId: id },
            })))
        )
          throw new ConflictException('普通待办只允许两层且不能形成循环');
        // 子任务继承主任务的业务日期及象限。
        const scheduledDate =
          parent?.scheduledDate ?? data.scheduledDate ?? current?.scheduledDate;
        // 所属象限由父项统一决定。
        const priorityQuadrant =
          parent?.priorityQuadrant ??
          data.priorityQuadrant ??
          current?.priorityQuadrant ??
          2;
        // 旧非法编号保留待核对，但不能经继承或未来编辑传播到其他记录。
        if (creating || input.parentId !== undefined || scope === 'future')
          integerInput(priorityQuadrant, 'priorityQuadrant', 0, 3);
        // 进度规则同客户端，不能混用步骤和普通任务。
        const repeatRule = parent
          ? null
          : data.repeatRule === undefined
            ? (current?.repeatRule ?? null)
            : data.repeatRule;
        if (
          taskType === 'progress' &&
          (parent || repeatRule || (creating && !initialSteps))
        )
          throw new BadRequestException(
            '进度任务必须独立、不重复且至少包含一步',
          );
        if (taskType === 'normal' && (initialSteps || data.progressUnit))
          throw new BadRequestException('普通待办不能包含进度项或进度单位');
        if (creating) {
          // 重复父项和孩子各自持有稳定系列身份。
          const repeatSeriesId =
            repeatRule || parent?.repeatSeriesId ? randomUUID() : null;
          // 同层末尾顺序避免新建跳到已有项中间。
          const latest = await transaction.todoItem.aggregate({
            where: {
              userId: actor.sub,
              parentId,
              priorityQuadrant,
              deletedAt: null,
            },
            _max: { sortOrder: true },
          });
          await transaction.todoItem.create({
            data: {
              ...data,
              id,
              userId: actor.sub,
              title: data.title!,
              taskType,
              parentId,
              scheduledDate: scheduledDate!,
              priorityQuadrant,
              repeatRule,
              repeatSeriesId,
              sortOrder: (latest._max.sortOrder ?? 0) + 1024,
            },
          });
          if (initialSteps)
            for (const [index, step] of initialSteps.entries())
              await transaction.todoProgressStep.create({
                data: {
                  id: randomUUID(),
                  userId: actor.sub,
                  todoId: id,
                  name: step.name,
                  sortOrder: (index + 1) * 1024,
                },
              });
        } else if (
          scope === 'future' &&
          current &&
          (current.repeatSeriesId || current.repeatRule)
        ) {
          if (
            (data.parentId !== undefined &&
              data.parentId !== current.parentId) ||
            data.taskType === 'progress'
          )
            throw new BadRequestException('未来范围不能变更父关系或任务类型');
          if (
            data.scheduledDate &&
            data.scheduledDate.getTime() !== current.scheduledDate.getTime()
          )
            throw new BadRequestException(
              '未来范围编辑不平移计划日期，请按实例修改日期',
            );
          // 同系列已保存实例都按相同内容更新，历史完成状态保持。
          const future = await transaction.todoItem.findMany({
            where: {
              userId: actor.sub,
              OR: [
                { repeatSeriesId: current.repeatSeriesId ?? current.id },
                { id: current.id },
              ],
              scheduledDate: { gte: current.scheduledDate },
              deletedAt: null,
            },
          });
          // 修改时钟到每个业务自然日需要明确地区。
          const timeZone =
            data.dueAt || data.reminderAt
              ? timeZoneInput(input.timeZone)
              : null;
          for (const row of future) {
            // 子系列实例继承各自当前主任务的上下文，不套用首条实例的父状态。
            const rowParent = row.parentId
              ? requireActive(
                  await transaction.todoItem.findFirst({
                    where: { userId: actor.sub, id: row.parentId },
                  }),
                )
              : null;
            // 每条实例保留自己的计划日，时钟才按指定地区迁移。
            const next = {
              ...data,
              scheduledDate: rowParent?.scheduledDate ?? row.scheduledDate,
              parentId: row.parentId,
              priorityQuadrant: rowParent?.priorityQuadrant ?? priorityQuadrant,
              repeatRule:
                input.repeatRule !== undefined &&
                data.repeatRule === null &&
                row.parentId === null
                  ? 'stopped'
                  : repeatRule,
            };
            for (const field of ['dueAt', 'reminderAt'] as const)
              if (next[field] && timeZone)
                next[field] = localInstant(
                  row.scheduledDate.toISOString().slice(0, 10),
                  localParts(next[field], timeZone).seconds,
                  timeZone,
                );
            await transaction.todoItem.update({
              where: { id: row.id },
              data: next,
            });
            if (!row.parentId)
              await transaction.todoItem.updateMany({
                where: { userId: actor.sub, parentId: row.id, deletedAt: null },
                data: { priorityQuadrant, scheduledDate: row.scheduledDate },
              });
          }
        } else {
          await transaction.todoItem.update({
            where: { id },
            data: {
              ...data,
              scheduledDate,
              priorityQuadrant,
              repeatRule,
              parentId,
              ...(repeatRule && !parentId && !current?.repeatSeriesId
                ? { repeatSeriesId: id }
                : {}),
            },
          });
          if (!parentId)
            await transaction.todoItem.updateMany({
              where: { userId: actor.sub, parentId: id, deletedAt: null },
              data: { scheduledDate, priorityQuadrant },
            });
        }
        await reconcileTodos(transaction, actor.sub);
        return transaction.todoItem.findUniqueOrThrow({
          where: { id },
          include: {
            progressSteps: {
              where: { deletedAt: null },
              orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
            },
          },
        });
      },
    );
  }

  /// 完成/重开普通父项对孩子对称级联；进度任务必须先全满。
  setCompleted(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 不接受任意 completedAt，由业务命令设置。
    const input = objectInput(value, ['operationId', 'id', 'completed']);
    // 当前任务身份。
    const id = uuidInput(input.id);
    // 明确完成或重开。
    const completed = booleanInput(input.completed, 'completed');
    return businessWrite(
      this.prisma,
      actor,
      'todos.setCompleted',
      input,
      async (transaction) => {
        // 对话旧快照不参与最终可完成性判断。
        const current = requireActive(
          await transaction.todoItem.findFirst({
            where: { userId: actor.sub, id },
          }),
        );
        if (current.taskType === 'progress' && completed) {
          // 满进度仍需本命令显式确认。
          const steps = await transaction.todoProgressStep.findMany({
            where: { userId: actor.sub, todoId: id, deletedAt: null },
          });
          if (!steps.length || steps.some((step) => !step.isCompleted))
            throw new ConflictException('请先完成全部进度项，再确认任务完成');
        }
        // 已完成孩子保持自己的历史完成时间。
        const now = new Date();
        await transaction.todoItem.updateMany({
          where: {
            userId: actor.sub,
            deletedAt: null,
            isCompleted: !completed,
            OR:
              current.parentId || current.taskType === 'progress'
                ? [{ id }]
                : [{ id }, { parentId: id }],
          },
          data: { isCompleted: completed, completedAt: completed ? now : null },
        });
        if (!completed && current.parentId)
          await transaction.todoItem.updateMany({
            where: { userId: actor.sub, id: current.parentId, deletedAt: null },
            data: { isCompleted: false, completedAt: null },
          });
        await reconcileTodos(transaction, actor.sub);
        return transaction.todoItem.findUniqueOrThrow({ where: { id } });
      },
    );
  }

  /// 选中子任务调整象限时，整个树一起移动。
  setQuadrant(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 树移动是独立业务动作。
    const input = objectInput(value, ['operationId', 'id', 'priorityQuadrant']);
    // 输入可以是根或孩子。
    const id = uuidInput(input.id);
    // 保持现有四象限编号。
    const priorityQuadrant = integerInput(
      input.priorityQuadrant,
      'priorityQuadrant',
      0,
      3,
    );
    return businessWrite(
      this.prisma,
      actor,
      'todos.setQuadrant',
      input,
      async (transaction) => {
        // 根身份由实际当前关系决定。
        const target = requireActive(
          await transaction.todoItem.findFirst({
            where: { userId: actor.sub, id },
          }),
        );
        // 同一树不可分散到不同象限。
        const rootId = target.parentId ?? target.id;
        requireActive(
          await transaction.todoItem.findFirst({
            where: { userId: actor.sub, id: rootId },
          }),
        );
        await transaction.todoItem.updateMany({
          where: {
            userId: actor.sub,
            deletedAt: null,
            OR: [{ id: rootId }, { parentId: rootId }],
          },
          data: { priorityQuadrant },
        });
        return { rootId, priorityQuadrant };
      },
    );
  }

  /// 修改稳定步骤集合，满进度也不会自动确认任务。
  setStepsCompleted(
    actor: AuthUser,
    value: unknown,
  ): Promise<Prisma.JsonValue> {
    // 只允许明确选择步骤，不允许模型改写整张表。
    const input = objectInput(value, [
      'operationId',
      'todoId',
      'stepIds',
      'completed',
    ]);
    // 任务身份。
    const todoId = uuidInput(input.todoId, 'todoId');
    // 已有超限结构仍可操作其步骤。
    const stepIds = idsInput(input.stepIds, 'stepIds', 100000);
    if (!stepIds.length) throw new BadRequestException('请至少选择一个步骤');
    // 明确步骤动作。
    const completed = booleanInput(input.completed, 'completed');
    return businessWrite(
      this.prisma,
      actor,
      'todos.setStepsCompleted',
      input,
      async (transaction) => {
        // 确认之后须先重新打开再改步骤。
        const todo = requireActive(
          await transaction.todoItem.findFirst({
            where: { userId: actor.sub, id: todoId },
          }),
        );
        if (todo.taskType !== 'progress' || todo.isCompleted)
          throw new ConflictException('仅未确认的进度任务可修改步骤');
        // 同时检查所有步骤归属和有效状态。
        const steps = await transaction.todoProgressStep.findMany({
          where: {
            userId: actor.sub,
            todoId,
            id: { in: stepIds },
            deletedAt: null,
          },
        });
        if (steps.length !== stepIds.length)
          throw new ConflictException('所选步骤已变化或不属于该任务');
        // 不记录未发生变化的项目，撤销不影响后续新增步骤。
        const changed = steps.filter((step) => step.isCompleted !== completed);
        // 大于旧时戳保证同毫秒动作也能使用条件撤销。
        const changedAt = new Date(
          Math.max(
            Date.now(),
            ...changed.map((step) => step.updatedAt.getTime() + 1),
          ),
        );
        await transaction.todoProgressStep.updateMany({
          where: {
            userId: actor.sub,
            todoId,
            id: { in: changed.map((step) => step.id) },
            deletedAt: null,
          },
          data: {
            isCompleted: completed,
            completedAt: completed ? changedAt : null,
            updatedAt: changedAt,
          },
        });
        await reconcileTodos(transaction, actor.sub);
        return {
          todoId,
          completed,
          changedAt,
          steps: changed.map((step) => ({
            id: step.id,
            isCompleted: step.isCompleted,
            completedAt: step.completedAt,
          })),
        };
      },
    );
  }

  /// 撤销只读取受信任的原操作回执，不接受模型伪造的旧状态。
  undoSteps(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 新操作身份与被撤销操作身份分开。
    const input = objectInput(value, ['operationId', 'changeOperationId']);
    // 原动作的持久身份。
    const changeOperationId = uuidInput(
      input.changeOperationId,
      'changeOperationId',
    );
    return businessWrite(
      this.prisma,
      actor,
      'todos.undoSteps',
      input,
      async (transaction) => {
        // 原回执来自本归属的真实执行结果。
        const receipt = await transaction.businessOperationReceipt.findUnique({
          where: {
            userId_operationId: {
              userId: actor.sub,
              operationId: changeOperationId,
            },
          },
        });
        if (!receipt || receipt.action !== 'todos.setStepsCompleted')
          throw new ConflictException('未找到可撤销的步骤操作');
        // 该形状只由本服务写入，不能由工具参数传入。
        const change = receipt.result as unknown as {
          todoId: string;
          changedAt: string;
          completed: boolean;
          steps: Array<{
            id: string;
            isCompleted: boolean;
            completedAt: string | null;
          }>;
        };
        // 已删或已确认任务不可被撤销动作复活。
        const todo = await transaction.todoItem.findFirst({
          where: {
            userId: actor.sub,
            id: change.todoId,
            deletedAt: null,
            isCompleted: false,
            taskType: 'progress',
          },
        });
        if (!todo)
          return { undone: false, reason: '任务已删除、确认或类型变化' };
        // 原步骤必须仍处在操作之后的精确状态。
        const current = await transaction.todoProgressStep.findMany({
          where: {
            userId: actor.sub,
            todoId: todo.id,
            id: { in: change.steps.map((step) => step.id) },
            deletedAt: null,
          },
        });
        if (
          current.length !== change.steps.length ||
          current.some(
            (step) =>
              step.updatedAt.toISOString() !== change.changedAt ||
              step.isCompleted !== change.completed ||
              (step.completedAt?.toISOString() ?? null) !==
                (change.completed ? change.changedAt : null),
          )
        )
          return { undone: false, reason: '步骤已发生后续变化' };
        for (const step of change.steps)
          await transaction.todoProgressStep.update({
            where: { id: step.id },
            data: {
              isCompleted: step.isCompleted,
              completedAt: step.completedAt ? new Date(step.completedAt) : null,
              updatedAt: new Date(
                Math.max(Date.now(), Date.parse(change.changedAt) + 1),
              ),
            },
          });
        await reconcileTodos(transaction, actor.sub);
        return { undone: true, todoId: todo.id };
      },
    );
  }

  /// 替换结构先比对 ID/名称/顺序基线，步骤完成事实按身份保留。
  replaceSteps(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // baseline 是实际编辑前结构，不从最新行补造。
    const input = objectInput(value, [
      'operationId',
      'todoId',
      'steps',
      'baseline',
    ]);
    // 正式进度任务目标。
    const todoId = uuidInput(input.todoId, 'todoId');
    // 当前想保留/新增的结构。
    const drafts = stepDrafts(input.steps);
    // 原结构允许来自已同步合并的超限集合。
    const baseline = stepDrafts(input.baseline, true);
    return businessWrite(
      this.prisma,
      actor,
      'todos.replaceSteps',
      input,
      async (transaction) => {
        // 已确认任务不能直接管理结构。
        const todo = requireActive(
          await transaction.todoItem.findFirst({
            where: { userId: actor.sub, id: todoId },
          }),
        );
        if (todo.taskType !== 'progress' || todo.isCompleted)
          throw new ConflictException('请先重新打开进度任务');
        // 查询顺序是结构基线的一部分。
        const current = await transaction.todoProgressStep.findMany({
          where: { userId: actor.sub, todoId, deletedAt: null },
          orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }, { id: 'asc' }],
        });
        if (
          baseline.length !== current.length ||
          current.some(
            (step, index) =>
              baseline[index]?.id !== step.id ||
              baseline[index]?.name !== step.name,
          )
        )
          throw new ConflictException('进度结构已变化，请重新读取');
        if (
          drafts.length > maxProgressSteps &&
          (drafts.length > current.length || drafts.some((step) => !step.id))
        )
          throw new BadRequestException('超限结构只能保留或减少，不能继续新增');
        // 只能保留当前有效身份；新身份必须由服务端分配。
        const byId = new Map(current.map((step) => [step.id, step]));
        // 防止同一步骤重复出现在结构中。
        const retained = new Set<string>();
        for (const [index, draft] of drafts.entries()) {
          if (draft.id) {
            if (!byId.has(draft.id) || retained.has(draft.id))
              throw new ConflictException('步骤身份失效或重复');
            retained.add(draft.id);
            await transaction.todoProgressStep.update({
              where: { id: draft.id },
              data: { name: draft.name, sortOrder: (index + 1) * 1024 },
            });
          } else
            await transaction.todoProgressStep.create({
              data: {
                id: randomUUID(),
                userId: actor.sub,
                todoId,
                name: draft.name,
                sortOrder: (index + 1) * 1024,
              },
            });
        }
        await transaction.todoProgressStep.updateMany({
          where: {
            userId: actor.sub,
            todoId,
            id: {
              in: current
                .filter((step) => !retained.has(step.id))
                .map((step) => step.id),
            },
            deletedAt: null,
          },
          data: { deletedAt: new Date() },
        });
        await reconcileTodos(transaction, actor.sub);
        return transaction.todoProgressStep.findMany({
          where: { userId: actor.sub, todoId, deletedAt: null },
          orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
        });
      },
    );
  }

  /// 明确物化某个自然日的重复实例，普通查询不隐式写入。
  ensureRepeatedInstances(
    actor: AuthUser,
    value: unknown,
  ): Promise<Prisma.JsonValue> {
    // 生成范围单独明确，不扫描所有历史日期。
    const input = objectInput(value, ['operationId', 'day', 'timeZone']);
    // 目标自然日。
    const day = dayInput(input.day);
    // 提醒/截止时钟需要继承原地区语义。
    const timeZone = timeZoneInput(input.timeZone);
    return businessWrite(
      this.prisma,
      actor,
      'todos.ensureRepeatedInstances',
      input,
      async (transaction) => {
        // 包括软删除例外与停止标记，防止自动复活。
        const repeating = await transaction.todoItem.findMany({
          where: {
            userId: actor.sub,
            parentId: null,
            repeatRule: { not: null },
          },
          orderBy: [{ scheduledDate: 'asc' }, { id: 'asc' }],
        });
        // 系列身份与旧无 series 数据兼容。
        const series = new Map<string, TodoItem[]>();
        for (const row of repeating) {
          // 兼容旧记录尚未保存独立系列身份的情况。
          const key = row.repeatSeriesId ?? row.id;
          series.set(key, [...(series.get(key) ?? []), row]);
        }
        // 本次真正创建的实例身份。
        const created: string[] = [];
        for (const [seriesId, rows] of series) {
          // 最早实例决定重复日历锚点。
          const seed = rows[0]!;
          if (
            !todoOccursOn(seed, day) ||
            rows.some(
              (row) => row.scheduledDate.toISOString().slice(0, 10) === day,
            )
          )
            continue;
          // 目标日前最近状态决定系列是否停止。
          const previous = rows.filter(
            (row) => row.scheduledDate.toISOString().slice(0, 10) <= day,
          );
          if (previous.at(-1)?.repeatRule === 'stopped') continue;
          // 最近未删模板提供内容和孩子，不使用未来实例反向生成。
          const template = previous
            .filter(
              (row) =>
                row.deletedAt === null &&
                row.scheduledDate.toISOString().slice(0, 10) < day,
            )
            .at(-1);
          if (!template) continue;
          // 与客户端 UUIDv5 完全一致，重启和双端生成自然合并。
          const rootId = stableBusinessId('repeat-todo', [seriesId, day]);
          if (await transaction.todoItem.findUnique({ where: { id: rootId } }))
            continue;
          // 永久墓碑是明确删除，不能因重新生成请求而复活。
          if (
            await transaction.syncTombstone.findUnique({
              where: {
                userId_tableName_recordId: {
                  userId: actor.sub,
                  tableName: 'todo_items',
                  recordId: rootId,
                },
              },
            })
          )
            continue;
          // 不能从旧非法象限模板继续物化错误实例。
          integerInput(template.priorityQuadrant, 'priorityQuadrant', 0, 3);
          // 提醒与截止按目标日保留当地钟点。
          const move = (at: Date | null): Date | null =>
            at
              ? localInstant(day, localParts(at, timeZone).seconds, timeZone)
              : null;
          await transaction.todoItem.create({
            data: {
              id: rootId,
              userId: actor.sub,
              title: template.title,
              description: template.description,
              scheduledDate: new Date(`${day}T00:00:00Z`),
              dueAt: move(template.dueAt),
              reminderAt: move(template.reminderAt),
              priorityQuadrant: template.priorityQuadrant,
              sortOrder: template.sortOrder,
              repeatRule: seed.repeatRule,
              repeatSeriesId: seriesId,
            },
          });
          // 不包含软删除孩子，独立子系列身份保持。
          const children = await transaction.todoItem.findMany({
            where: {
              userId: actor.sub,
              parentId: template.id,
              deletedAt: null,
            },
            orderBy: [
              { sortOrder: 'asc' },
              { createdAt: 'asc' },
              { id: 'asc' },
            ],
          });
          for (const child of children) {
            // 双端会生成相同子项身份。
            const childId = stableBusinessId('repeat-subtask', [
              seriesId,
              child.repeatSeriesId ?? child.id,
              day,
            ]);
            if (
              await transaction.syncTombstone.findUnique({
                where: {
                  userId_tableName_recordId: {
                    userId: actor.sub,
                    tableName: 'todo_items',
                    recordId: childId,
                  },
                },
              })
            )
              continue;
            await transaction.todoItem.create({
              data: {
                id: childId,
                userId: actor.sub,
                parentId: rootId,
                title: child.title,
                description: child.description,
                scheduledDate: new Date(`${day}T00:00:00Z`),
                dueAt: move(child.dueAt),
                reminderAt: move(child.reminderAt),
                priorityQuadrant: template.priorityQuadrant,
                sortOrder: child.sortOrder,
                repeatSeriesId: child.repeatSeriesId ?? child.id,
              },
            });
          }
          created.push(rootId);
        }
        await reconcileTodos(transaction, actor.sub);
        return { day, timeZone, created };
      },
    );
  }

  /// 单条与未来范围软删除，主任务停止系列，子任务不停止父系列。
  trash(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 作用范围是业务语义，不能由通用表 PATCH 猜测。
    const input = objectInput(value, ['operationId', 'id', 'scope']);
    // 当前实例身份。
    const id = uuidInput(input.id);
    // 缺省仅删除这一次。
    const scope =
      input.scope === undefined
        ? 'single'
        : enumInput(input.scope, 'scope', ['single', 'future']);
    return businessWrite(
      this.prisma,
      actor,
      'todos.trash',
      input,
      async (transaction) => {
        // 已删实例不能被新删除动作默默当成活动实例。
        const current = requireActive(
          await transaction.todoItem.findFirst({
            where: { userId: actor.sub, id },
          }),
        );
        // 未来范围仅选未完成的当前及以后实例。
        const targets =
          scope === 'future' && (current.repeatSeriesId || current.repeatRule)
            ? await transaction.todoItem.findMany({
                where: {
                  userId: actor.sub,
                  OR: [
                    { repeatSeriesId: current.repeatSeriesId ?? current.id },
                    { id: current.id },
                  ],
                  scheduledDate: { gte: current.scheduledDate },
                  isCompleted: false,
                  deletedAt: null,
                },
                select: { id: true },
              })
            : [{ id }];
        // 所有实际删除使用一个时间，保留原恢复边界。
        const deletedAt = new Date();
        await transaction.todoItem.updateMany({
          where: {
            userId: actor.sub,
            deletedAt: null,
            OR: [
              { id: { in: targets.map((row) => row.id) } },
              { parentId: { in: targets.map((row) => row.id) } },
            ],
          },
          data: { deletedAt },
        });
        if (
          scope === 'future' &&
          (current.repeatSeriesId || current.repeatRule) &&
          !current.parentId
        )
          await transaction.todoItem.update({
            where: { id },
            data: { repeatRule: 'stopped' },
          });
        return { ids: targets.map((row) => row.id), scope, deletedAt };
      },
    );
  }

  /// 统计已保存任务，分别声明计划日及真实完成日口径。
  statistics(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 业务时区用于完成时间和计划日窗口。
    const input = objectInput(value, ['from', 'to', 'timeZone', 'asOf']);
    // 统计只读，不自动创建未来任务。
    const range = rangeInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      // 根与孩子分别计数，不能把进度步骤算成普通任务。
      const rows = await transaction.todoItem.findMany({
        where: { userId: actor.sub, deletedAt: null },
        include: {
          progressSteps: {
            where: { deletedAt: null },
            select: { isCompleted: true },
          },
        },
      });
      // 计划日按当地日历起点归入窗口。
      const planned = rows.filter((row) => {
        // 计划日归属和完成时间归属不能混为一谈。
        const at = localInstant(
          row.scheduledDate.toISOString().slice(0, 10),
          0,
          range.timeZone,
        );
        return at >= range.from && at < range.to;
      });
      // 完成日期不要求计划日在本窗口中。
      const completed = rows.filter(
        (row) =>
          row.isCompleted &&
          row.completedAt &&
          row.completedAt >= range.from &&
          row.completedAt < range.to &&
          row.completedAt <= range.asOf,
      );
      return {
        ...range,
        plannedCount: planned.length,
        plannedRoots: planned.filter((row) => !row.parentId).length,
        completedCount: completed.length,
        completedRoots: completed.filter((row) => !row.parentId).length,
        unfinishedCount: planned.filter((row) => !row.isCompleted).length,
        progressSteps: planned.reduce(
          (sum, row) => sum + row.progressSteps.length,
          0,
        ),
        completedSteps: planned.reduce(
          (sum, row) =>
            sum + row.progressSteps.filter((step) => step.isCompleted).length,
          0,
        ),
        sourceIds: [
          ...new Set([...planned, ...completed].map((row) => row.id)),
        ].slice(0, 200),
        sourcesTruncated:
          new Set([...planned, ...completed].map((row) => row.id)).size > 200,
        complete: true,
        includesUnmaterializedRecurring: false,
      };
    });
  }
}
