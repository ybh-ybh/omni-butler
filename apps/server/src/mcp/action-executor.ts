import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
  UnauthorizedException,
} from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { AuthUser } from '../auth/auth.types';
import { withinBusinessTransaction } from '../business/business-access';
import { localParts, timeZoneInput } from '../business/business-input';
import type { McpAction, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { canonicalize } from '../sync/sync.service';
import { stableBusinessId } from '../sync/sync-consistency';
import {
  McpCatalog,
  mcpId,
  mcpModules,
  type McpModule,
  type McpToolDefinition,
} from './mcp-catalog';
import {
  McpEditTokenService,
  type EditTokenIdentity,
} from './mcp-edit-token.service';
import type {
  ActionContext,
  ActionScope,
  ActionToolDescription,
  AssistantCommitGuard,
} from './action-context';

/// MCP 业务步骤只能引用已登记的具体工具。
export interface McpStep {
  /// 固定工具目录身份。
  name: string;
  /// 经过严格Schema校验的业务参数。
  input: Record<string, unknown>;
}
/// 用于基线和影响比较的数据库事实，不包含密钥表。
type Snapshot = Record<string, Array<Record<string, Prisma.JsonValue>>>;
/// 固定表映射只用于服务端快照，不接受模型选择表。
const moduleTables: Record<McpModule, string[]> = {
  quotes: ['quotes', 'daily_quote_selections'],
  time: ['time_entries'],
  todos: ['todo_items', 'todo_progress_steps'],
  inventory: ['inventory_items'],
  memberships: ['memberships', 'membership_payments'],
  events: ['events', 'event_completions'],
  notes: [
    'note_entries',
    'note_versions',
    'note_audio_segments',
    'note_images',
  ],
};
/// 共用分类模块的旧协议名称。
const taxonomyModules: Partial<Record<McpModule, string>> = {
  time: 'timeline',
  inventory: 'inventory',
  memberships: 'membership',
  notes: 'notes',
};

/// 将日期与其他 JSON 值固定为可持久回放的形状。
export function mcpJson(value: unknown): Prisma.InputJsonValue {
  return JSON.parse(
    JSON.stringify(value, (_key: string, item: unknown) =>
      typeof item === 'bigint' ? item.toString() : item,
    ),
  ) as Prisma.InputJsonValue;
}
/// 摘要绑定规范内容，不能由调用方修改预览后继续使用旧基线。
export function mcpHash(value: unknown): string {
  return createHash('sha256')
    .update(JSON.stringify(canonicalize(mcpJson(value))))
    .digest('hex');
}
/// 专用授权映射为独立内部身份，绝不复制某个设备的长期凭据。
function connectionActor(connection: ActionScope): AuthUser {
  return { sub: connection.userId, sid: connection.sessionId, typ: 'access' };
}
/// 内外入口共享同一执行链；助手不创建隐藏 MCP 连接。
@Injectable()
export class ActionExecutor {
  /// 注入唯一业务目录及持久签名服务。
  constructor(
    private readonly prisma: PrismaService,
    readonly catalog: McpCatalog,
    private readonly editTokens: McpEditTokenService,
  ) {}

  /// 来源身份仅由服务端构造，每次操作仍验证真实会话。
  async scope(
    context: ActionContext,
    transaction: Prisma.TransactionClient = this.prisma,
  ): Promise<ActionScope> {
    if (typeof context === 'string') {
      // 外部连接拥有独立令牌及内部业务身份。
      const connection = await transaction.mcpConnection.findUnique({
        where: { id: context },
      });
      if (
        !connection ||
        connection.revokedAt ||
        (connection.expiresAt !== null && connection.expiresAt <= new Date()) ||
        !(await transaction.deviceSession.findFirst({
          where: {
            id: connection.sessionId,
            userId: connection.userId,
            expiresAt: { gt: new Date() },
          },
        }))
      )
        throw new UnauthorizedException('MCP 连接已撤销、到期或归属失效');
      return {
        ...connection,
        connectionId: connection.id,
        source: 'mcp',
        sourceId: connection.id,
        context,
      };
    }
    mcpId.parse(context.taskId);
    mcpId.parse(context.runId);
    mcpId.parse(context.actor.sub);
    mcpId.parse(context.actor.sid);
    if (context.source !== 'assistant' || context.actor.typ !== 'access')
      throw new UnauthorizedException('助手需要有效设备身份');
    // 真实设备会话仍由业务授权规则逐项复核，不能以任务身份替代。
    const session = await transaction.deviceSession.findFirst({
      where: {
        id: context.actor.sid,
        userId: context.actor.sub,
        expiresAt: { gt: new Date() },
      },
    });
    if (!session) throw new UnauthorizedException('设备会话已失效');
    return {
      source: 'assistant',
      sourceId: context.taskId,
      context,
      connectionId: null,
      userId: context.actor.sub,
      sessionId: context.actor.sid,
      readModules: [...mcpModules],
      writeModules: [...mcpModules],
      timeZone: timeZoneInput(context.timeZone),
      expiresAt: session.expiresAt,
    };
  }

  /// 每次动作读取都同时限定归属、来源及来源身份。
  private actionIdentity(scope: ActionScope): {
    userId: string;
    source: string;
    sourceId: string;
    connectionId: string | null;
  } {
    return {
      userId: scope.userId,
      source: scope.source,
      sourceId: scope.sourceId,
      connectionId: scope.connectionId,
    };
  }

  /// 编辑凭据的助手作用域与 MCP 签名域严格隔离。
  private editIdentity(scope: ActionScope): EditTokenIdentity {
    return scope.source === 'mcp'
      ? { id: scope.sourceId, userId: scope.userId }
      : { source: 'assistant', taskId: scope.sourceId, userId: scope.userId };
  }

  /// 预演也必须与停止和接管竞争同一 owner 锁，不能创建孤立待执行动作。
  private async requireAssistantPreparation(
    transaction: Prisma.TransactionClient,
    scope: ActionScope,
  ): Promise<void> {
    if (typeof scope.context === 'string') return;
    // 模型参数不能声明任务、运行或设备身份。
    const context = scope.context;
    // 所有事实在取得 owner 锁之后读取，不相信此前的 current 检查。
    const task = await transaction.assistantTask.findFirst({
      where: {
        id: context.taskId,
        userId: scope.userId,
        runId: context.runId,
        sessionId: scope.sessionId,
        status: 'running',
      },
    });
    // 当前运行仍在执行才允许固定新的业务动作。
    const run = await transaction.assistantRun.findFirst({
      where: {
        id: context.runId,
        userId: scope.userId,
        taskId: context.taskId,
        sessionId: scope.sessionId,
        status: 'running',
      },
    });
    // 关闭助手会在同一 owner 锁下取消任务。
    const settings = await transaction.assistantSettings.findUnique({
      where: { userId: scope.userId },
    });
    if (!task || !run || !settings?.enabled)
      throw new UnauthorizedException('助手准备授权已失效');
  }

  /// 只暴露来源允许的固定业务工具，不提供模型直接提交管理入口。
  async listTools(context: ActionContext): Promise<ActionToolDescription[]> {
    // 使用实际公开工具目录，管理类工具由运行器控制。
    const scope = await this.scope(context);
    return [
      ...this.catalog.visible(scope.readModules, scope.writeModules),
      ...this.catalog.controls(scope.readModules, scope.writeModules),
    ]
      .filter(
        (tool) =>
          ![
            'get_capabilities',
            'get_action_status',
            'prepare_batch',
            'commit_action',
            'cancel_action',
            'undo_action',
          ].includes(tool.name),
      )
      .map((tool) => {
        // 请求幂等身份由运行器注入，工具模型只填写业务参数。
        const schema =
          tool.write && Object.hasOwn(tool.schema.shape, 'requestId')
            ? tool.schema.omit({ requestId: true })
            : tool.schema;
        // 对应模块身份只来自目录，不从模型文字推断。
        const definition = this.catalog
          .authorized(scope.readModules, scope.writeModules)
          .find((entry) => entry.name === tool.name);
        return {
          name: tool.name,
          description: tool.description,
          inputSchema: z.toJSONSchema(schema) as Record<string, unknown>,
          write: tool.write,
          ...(definition ? { module: definition.module } : {}),
        };
      });
  }

  /// 整批前后基线覆盖七模块及关系，调用方不能指定任意表。
  async snapshotBaseline(context: ActionContext): Promise<string> {
    // 初次身份读取后，在 owner 事务内复验授权及完整快照。
    const initial = await this.scope(context);
    return withinBusinessTransaction(
      this.prisma,
      connectionActor(initial),
      async (transaction) => {
        // 同归属外层事务自动复用，批量预演不会再开一把 owner 锁。
        const scope = await this.scope(context, transaction);
        return mcpHash(
          await this.snapshot(transaction, scope.userId, [...mcpModules]),
        );
      },
    );
  }

  /// 完整批次按独立对象去重，不累加分批中重复出现的同一目标。
  async countPlanTargets(
    context: ActionContext,
    steps: McpStep[],
    changes: Array<Record<string, unknown>> = [],
  ): Promise<number> {
    // 计数不是执行授权，也不能接受自由表查询。
    const initial = await this.scope(context);
    return withinBusinessTransaction(
      this.prisma,
      connectionActor(initial),
      async (transaction) => {
        // 读取完整事实使 future 范围的系列归属不可由模型伪造。
        const scope = await this.scope(context, transaction);
        // 预览最终回滚后，变化清单只覆盖实际展示的字段。
        const before = await this.snapshot(transaction, scope.userId, [
          ...mcpModules,
        ]);
        // 每表复制不修改原始基线，固定白名单之外的变化不参与计数。
        const after: Snapshot = Object.fromEntries(
          Object.entries(before).map(([table, rows]) => [
            table,
            rows.map((row) => ({ ...row })),
          ]),
        );
        for (const change of changes) {
          if (
            change.table !== 'todo_items' ||
            typeof change.id !== 'string' ||
            !change.after ||
            typeof change.after !== 'object' ||
            Array.isArray(change.after)
          )
            continue;
          // 已保存实例使用真实 ID 关联，临时新增 ID 不作为正式目标。
          const row = after.todo_items?.find((entry) => entry.id === change.id);
          if (row) Object.assign(row, change.after);
        }
        // 恢复工具只展开固定模块名，不允许字符串构造其他写入口。
        const mapped = steps.map((step) =>
          step.name === 'restore_record'
            ? {
                name: `restore_${z.enum(mcpModules).parse(step.input.module)}`,
                input: { id: mcpId.parse(step.input.id) },
              }
            : step,
        );
        return this.targetCount(scope, mapped, before, after);
      },
    );
  }

  /// 权限仍由实际目录决定，不允许猜测隐藏写工具。
  private tool(
    scope: ActionScope,
    name: string,
    write: boolean,
  ): McpToolDefinition {
    // 唯一目录同时承担函数参数和领域执行。
    const tool = this.catalog
      .authorized(scope.readModules, scope.writeModules)
      .find((entry) => entry.name === name && entry.write === write);
    if (!tool) throw new ForbiddenException('当前来源未获该工具权限');
    return tool;
  }

  /// 同一对象的正文、账单和步骤操作合并计数，新建每次代表一个目标。
  private targetCount(
    scope: ActionScope,
    steps: McpStep[],
    before: Snapshot,
    after: Snapshot,
  ): number {
    // 主对象字段映射来自固定工具契约，不接受模型报告数量。
    const targets = new Set<string>();
    for (const [index, step] of steps.entries()) {
      // 会员支付、事件完成、待办步骤均归于其主对象。
      const definition = this.tool(scope, step.name, true);
      // 主对象字段与实际参数 schema 一同登记，不信任模型传入的数量。
      const id = definition.targetField
        ? step.input[definition.targetField]
        : undefined;
      targets.add(
        `${definition.module}:${typeof id === 'string' ? id : `new:${index}`}`,
      );
      if (
        typeof id === 'string' &&
        definition.targetScopeField &&
        step.input[definition.targetScopeField] === 'future'
      ) {
        // 同系列未来实例是独立目标，父项正常级联孩子不属于这个系列。
        const original = before.todo_items?.find((row) => row.id === id);
        // 非重复任务的 future 与 single 相同，不凭字段存在推断批量。
        if (!original || (!original.repeat_series_id && !original.repeat_rule))
          continue;
        // 使用数据库预演中真实变化，不相信模型声称的未来数量。
        const seriesId = original.repeat_series_id ?? id;
        for (const row of after.todo_items ?? []) {
          // 子系列有自己的身份，不能把父对象的普通孩子误计为多个目标。
          const prior = before.todo_items?.find((value) => value.id === row.id);
          if (
            typeof row.id === 'string' &&
            (row.id === id || row.repeat_series_id === seriesId) &&
            mcpHash(row) !== mcpHash(prior ?? null)
          )
            targets.add(`todos:${row.id}`);
        }
      }
    }
    return targets.size;
  }

  /// 普通查询逐项校验，不接收自由表名或任意列操作。
  async read(
    context: ActionContext,
    name: string,
    value: unknown,
  ): Promise<Prisma.JsonValue> {
    // 已认证连接决定唯一 actor，不允许参数覆盖。
    const connection = await this.scope(context);
    // 运行时严格 Schema 再校验一次，不能只依靠模型遵守 Schema。
    const tool = this.tool(connection, name, false);
    // 编辑凭据必须来自同一次详情查询，不在生成凭据时再读最新事实。
    const result = await tool.run(
      connectionActor(connection),
      tool.schema.parse(this.defaultZone(connection, tool, value)),
    );
    if (
      (name === 'get_note' || name === 'get_todo') &&
      result &&
      typeof result === 'object' &&
      !Array.isArray(result)
    ) {
      return {
        ...result,
        editToken: this.editTokens.issue(
          this.editIdentity(connection),
          mcpId.parse(result.id),
          name === 'get_note'
            ? {
                kind: 'note',
                revision: mcpId.parse(result.revision),
                tags: JSON.parse(z.string().parse(result.tags)) as string[],
              }
            : {
                kind: 'todoSteps',
                structureHash: mcpHash(
                  (
                    result.progressSteps as Array<{
                      id: string;
                      name: string | null;
                    }>
                  ).map((step) => ({ id: step.id, name: step.name })),
                ),
              },
        ),
      };
    }
    return result;
  }

  /// 统一统计入口仍使用各模块严格契约，拒绝不适用的参数。
  async statistics(
    context: ActionContext,
    value: unknown,
  ): Promise<Prisma.JsonValue> {
    // 模块枚举限制公开参数，权限在底层读取时再次核对。
    const { module, ...input } = z
      .strictObject({
        module: z.enum(mcpModules),
        from: z.string().optional(),
        to: z.string().optional(),
        timeZone: z.string().optional(),
        asOf: z.string().optional(),
        includeAccessories: z.boolean().optional(),
      })
      .parse(value);
    // 内部目录名固定，不能借模块参数访问任意工具。
    const summaries: Record<McpModule, string> = {
      quotes: 'get_quote_summary',
      time: 'get_time_summary',
      todos: 'get_todo_summary',
      inventory: 'get_inventory_summary',
      memberships: 'get_membership_spending',
      events: 'get_event_summary',
      notes: 'get_note_summary',
    };
    return this.read(context, summaries[module], input);
  }

  /// 七模块回收站共享分页入口，内部仍按模块验证owner与只读权限。
  async recycle(
    context: ActionContext,
    value: unknown,
  ): Promise<Prisma.JsonValue> {
    // 不接受自由表名、任意筛选或写入字段。
    const { module, ...input } = z
      .strictObject({
        module: z.enum(mcpModules),
        limit: z.number().optional(),
        offset: z.number().optional(),
      })
      .parse(value);
    return this.read(context, `list_${module}_recycle_bin`, input);
  }

  /// 只给工具已声明的时区字段应用显式连接默认值，不向其他工具注入额外字段。
  private defaultZone(
    connection: ActionScope,
    tool: McpToolDefinition,
    value: unknown,
  ): unknown {
    if (
      connection.timeZone &&
      Object.hasOwn(tool.schema.shape, 'timeZone') &&
      value &&
      typeof value === 'object' &&
      !Array.isArray(value) &&
      !Object.hasOwn(value, 'timeZone')
    )
      return { ...value, timeZone: connection.timeZone };
    return value;
  }

  /// 固定映射中的完整授权模块快照，宁可让无关同模块编辑要求重新预览。
  private async snapshot(
    transaction: Prisma.TransactionClient,
    userId: string,
    modules: McpModule[],
  ): Promise<Snapshot> {
    // 所有 SQL 标识来自源码固定清单，值全部参数化。
    const result: Snapshot = {};
    for (const table of [
      ...new Set(modules.flatMap((module) => moduleTables[module])),
    ]) {
      // PostgreSQL JSON 固定数据库时间表示，不混入 Prisma 对象转换。
      const rows = await transaction.$queryRawUnsafe<
        Array<{ data: Record<string, Prisma.JsonValue> }>
      >(
        `SELECT row_to_json(record) AS data FROM "${table}" AS record WHERE user_id=$1::uuid ORDER BY id`,
        userId,
      );
      result[table] = rows.map((row) => row.data);
    }
    // 分类和永久墓碑同样属于写入前提，不能只比较主记录。
    result.taxonomy_entries = (
      await transaction.taxonomyEntry.findMany({
        where: {
          userId,
          module: {
            in: modules
              .map((module) => taxonomyModules[module])
              .filter((module): module is string => !!module),
          },
        },
        orderBy: { id: 'asc' },
      })
    ).map((row) => mcpJson(row) as Record<string, Prisma.JsonValue>);
    result.record_taxonomy_links = (
      await transaction.recordTaxonomyLink.findMany({
        where: {
          userId,
          module: {
            in: modules
              .map((module) => taxonomyModules[module])
              .filter((module): module is string => !!module),
          },
        },
        orderBy: { id: 'asc' },
      })
    ).map((row) => mcpJson(row) as Record<string, Prisma.JsonValue>);
    result.tombstones = (
      await transaction.syncTombstone.findMany({
        where: {
          userId,
          tableName: { in: modules.flatMap((module) => moduleTables[module]) },
        },
        orderBy: [{ tableName: 'asc' }, { recordId: 'asc' }],
      })
    ).map((row) => mcpJson(row) as Record<string, Prisma.JsonValue>);
    return result;
  }

  /// 预览只展示实际变化的字段与关联数量，不把整个库复制到操作预览。
  private changes(
    before: Snapshot,
    after: Snapshot,
  ): Array<Record<string, unknown>> {
    // 大范围动作必须拆分，不能截断后提交未展示影响。
    const result: Array<Record<string, unknown>> = [];
    for (const [table, rows] of Object.entries(after))
      for (const row of rows) {
        // 预览中新建身份与正式提交的随机身份不同，不把临时身份当正式引用。
        const prior = before[table]?.find((item) => item.id === row.id);
        // 时间戳及归属不是用户变更字段，但仍进入基线摘要。
        const fields = Object.keys(row).filter(
          (key) =>
            ![
              'id',
              'user_id',
              'created_at',
              'updated_at',
              'userId',
              'createdAt',
              'updatedAt',
            ].includes(key) &&
            JSON.stringify(prior?.[key]) !== JSON.stringify(row[key]),
        );
        if (fields.length)
          result.push({
            table,
            id: prior ? row.id : null,
            newRecord: !prior,
            label:
              [row.name, row.title, row.content, row.body]
                .find((value): value is string => typeof value === 'string')
                ?.slice(0, 120) ?? table,
            before: prior
              ? Object.fromEntries(
                  fields.map((key) => [key, prior[key] ?? null]),
                )
              : null,
            after: Object.fromEntries(fields.map((key) => [key, row[key]])),
          });
      }
    if (result.length > 200)
      throw new BadRequestException(
        '本次影响超过200条记录，请拆分为更小操作后重新预览',
      );
    return result;
  }

  /// 从原始步骤生成固定的绝对事实；提交跨午夜不会重新解释“现在”。
  private async fixedSteps(
    transaction: Prisma.TransactionClient,
    connection: ActionScope,
    steps: McpStep[],
    now: Date,
  ): Promise<McpStep[]> {
    // 顺序解析在同一owner锁内完成，不并行访问事务连接。
    const fixed: McpStep[] = [];
    for (const step of steps) {
      // 严格输入不接受 operationId、confirmed、owner 等非业务参数。
      const mapped =
        step.name === 'restore_record'
          ? z
              .strictObject({ module: z.enum(mcpModules), id: mcpId })
              .parse(step.input)
          : null;
      // 统一恢复工具只展开到固定目录，不能构造隐藏业务工具名。
      const name = mapped ? `restore_${mapped.module}` : step.name;
      // 批量只接受公开业务动作；历史隐藏入口不能通过字符串绕过目录。
      if (
        !mapped &&
        !this.catalog
          .visible(connection.readModules, connection.writeModules)
          .some((item) => item.name === name && item.write)
      )
        throw new ForbiddenException('当前连接未开放该写工具');
      // 内部目录保留恢复映射的领域实现。
      const tool = this.tool(connection, name, true);
      // 初次校验之后才补服务端默认值，不能为模型保留任意字段。
      const input = tool.schema.parse(
        this.defaultZone(
          connection,
          tool,
          mapped ? { id: mapped.id } : step.input,
        ),
      );
      if (input.editToken !== undefined) {
        // 解包读取时签名的事实，不从当前数据库补造过期基线。
        const baseline = this.editTokens.read(
          this.editIdentity(connection),
          String(name === 'replace_todo_steps' ? input.todoId : input.id),
          z.string().parse(input.editToken),
          name === 'replace_todo_steps' ? 'todoSteps' : 'note',
        );
        if (baseline.kind === 'note') {
          if (name === 'append_note' || input.body !== undefined)
            input.expectedRevision = baseline.revision;
          if (input.tags !== undefined) input.tagsBase = baseline.tags;
        } else {
          // 大型历史结构只签摘要；当前结构必须与已读取的签名事实完全相同。
          const current = await transaction.todoProgressStep.findMany({
            where: {
              userId: connection.userId,
              todoId: String(input.todoId),
              deletedAt: null,
            },
            orderBy: [
              { sortOrder: 'asc' },
              { createdAt: 'asc' },
              { id: 'asc' },
            ],
            select: { id: true, name: true },
          });
          if (mcpHash(current) !== baseline.structureHash)
            throw new ConflictException('进度结构已变化，请停止并核对变更');
          input.baseline = current;
        }
        delete input.editToken;
      }
      if (
        (name === 'create_membership' || name === 'update_membership') &&
        input.billingCycle !== undefined
      ) {
        // 单一周期字段映射到旧存储，转换永久时清除不适用的到期日。
        input.isPermanent = input.billingCycle === 'permanent';
        if (input.isPermanent) {
          if (
            input.expirationDate !== undefined &&
            input.expirationDate !== null
          )
            throw new BadRequestException('永久会员不能设置到期日');
          input.expirationDate = null;
        }
      }
      if (input.recordedAt !== undefined) {
        // 保留输入偏移与墙钟时间，不能转成UTC后丢失原记录日期。
        const recorded = z.string().parse(input.recordedAt);
        // ISO Schema已验证格式，偏移另外限制在现有笔记存储范围。
        const offset = /([+-])(\d{2}):(\d{2})$/.exec(recorded);
        input.dayKey = recorded.slice(0, 10);
        input.recordTimeSeconds =
          Number(recorded.slice(11, 13)) * 3600 +
          Number(recorded.slice(14, 16)) * 60 +
          Number(recorded.slice(17, 19) || 0);
        input.recordUtcOffsetMinutes = offset
          ? (offset[1] === '-' ? -1 : 1) *
            (Number(offset[2]) * 60 + Number(offset[3]))
          : 0;
        delete input.recordedAt;
      }
      if (step.name === 'start_time_entry' && input.startedAt === undefined)
        input.startedAt = now.toISOString();
      if (step.name === 'finish_time_entry' && input.endedAt === undefined)
        input.endedAt = now.toISOString();
      if (step.name === 'complete_event' && input.completedAt === undefined)
        input.completedAt = now.toISOString();
      if (
        step.name === 'record_membership_payment' &&
        input.paidAt === undefined
      )
        input.paidAt = now.toISOString();
      if (
        step.name === 'create_note' &&
        input.dayKey === undefined &&
        input.recordTimeSeconds === undefined &&
        input.recordUtcOffsetMinutes === undefined
      ) {
        // 笔记自然日与钟点固定为准备时的明确业务时区。
        const local = localParts(now, timeZoneInput(input.timeZone));
        input.dayKey = local.day;
        input.recordTimeSeconds = local.seconds;
        input.recordUtcOffsetMinutes = local.offsetMinutes;
      }
      fixed.push({ name, input });
    }
    return fixed;
  }

  /// 一次可见清单在一个事务内模拟或提交，最多8个明确动作。
  private async runSteps(
    connection: ActionScope,
    actionId: string,
    steps: McpStep[],
  ): Promise<Prisma.JsonValue[]> {
    // 同批业务回执使用稳定派生身份，提交重放不生成新副作用。
    const results: Prisma.JsonValue[] = [];
    for (const [index, step] of steps.entries())
      results.push(
        await this.tool(connection, step.name, true).run(
          connectionActor(connection),
          {
            ...step.input,
            operationId: stableBusinessId('mcp-operation', [
              actionId,
              String(index),
            ]),
          },
        ),
      );
    return results;
  }

  /// 预览运行真实业务规则后回滚到保存点，业务表和业务回执均不改变。
  async prepare(
    context: ActionContext,
    requestId: string,
    steps: McpStep[],
    undoOf?: string,
  ): Promise<Record<string, unknown>> {
    mcpId.parse(requestId);
    if (!steps.length || steps.length > 8)
      throw new BadRequestException('一次准备1至8个明确操作');
    // 外层校验后由事务重新复验，避免撤销时仍创建待执行动作。
    const initial = await this.scope(context);
    return withinBusinessTransaction(
      this.prisma,
      connectionActor(initial),
      async (transaction) => {
        // 当前连接权限是本次操作的唯一授权来源。
        const connection = await this.scope(context, transaction);
        // 即使已有同请求预览，停止后也不能重新取得 pending 准备资格。
        await this.requireAssistantPreparation(transaction, connection);
        // 原请求身份与原参数摘要绑定，重放不重新解释默认时刻。
        const inputHash = mcpHash({ steps, undoOf: undoOf ?? null });
        // 重复准备返回旧操作，不生成第二份预览。
        const prior = await transaction.mcpAction.findFirst({
          where: { ...this.actionIdentity(connection), requestId },
        });
        if (prior) {
          if (prior.inputHash !== inputHash)
            throw new ConflictException('同一请求身份不能准备不同内容');
          return this.actionView(prior, true);
        }
        // 执行前固定动作、时间和授权。
        const fixed = await this.fixedSteps(
          transaction,
          connection,
          steps,
          new Date(),
        );
        // 基线包含本次所有模块及其关系，数据变化后不能沿用旧预览。
        const modules = [
          ...new Set(
            fixed.map((step) => this.tool(connection, step.name, true).module),
          ),
        ];
        // 准备时的数据库事实。
        const before = await this.snapshot(
          transaction,
          connection.userId,
          modules,
        );
        // 补偿不能因为晚准备而延长原操作的10分钟窗口。
        let undoExpiresAt = Infinity;
        if (undoOf) {
          // 补偿只能针对仍满足原后置状态且在窗口内的原动作。
          const original = await transaction.mcpAction.findFirst({
            where: {
              id: undoOf,
              ...this.actionIdentity(connection),
              status: 'succeeded',
            },
          });
          if (
            !original ||
            Date.now() - original.updatedAt.getTime() > 600000 ||
            (original.result as Record<string, Prisma.JsonValue> | null)
              ?.afterBaseline !== mcpHash(before)
          )
            throw new ConflictException('原操作已过撤销窗口或数据已有后续变化');
          undoExpiresAt = original.updatedAt.getTime() + 600000;
        }
        // 固定动作身份不由模型指定数据库记录ID。
        const id = randomUUID();
        await transaction.$executeRawUnsafe('SAVEPOINT mcp_preview');
        // 冲突候选属于保存候选而非采用正文，必须在提交前说明。
        const simulated = await this.runSteps(connection, id, fixed);
        // 只记录真实变化，不把预览生成的业务回执提交。
        const after = await this.snapshot(
          transaction,
          connection.userId,
          modules,
        );
        // 预览必须完整，过大的级联不允许被静默截断。
        const changes = this.changes(before, after);
        await transaction.$executeRawUnsafe(
          'ROLLBACK TO SAVEPOINT mcp_preview',
        );
        // 操作固定内容、前置事实、完整影响及截止时刻。
        const expiresAt = new Date(
          Math.min(
            Date.now() + 600000,
            connection.expiresAt?.getTime() ?? Infinity,
            undoExpiresAt,
          ),
        );
        // 新建记录ID在执行时分配，预览不将临时身份当作正式数据。
        const preview = {
          expectedOutcomes: simulated.map((value) =>
            value &&
            typeof value === 'object' &&
            !Array.isArray(value) &&
            value.status === 'conflict'
              ? '仅保存冲突候选，正式正文不采用'
              : '按清单变更',
          ),
          steps: fixed.map((step) => ({
            tool: step.name,
            description: this.tool(connection, step.name, true).description,
            input: step.input,
          })),
          changes,
          affectedRecords: changes.length,
          targetCount: this.targetCount(connection, fixed, before, after),
          atomic: true,
          undoOf: undoOf ?? null,
          newRecordIds: '执行时分配，预览中的关联身份仅用于表示关联关系',
          systemGeneratedValues:
            '状态完成/回收站等系统生成的时刻在正式执行时确定，预览时刻用于说明变更方向；明确指定的业务时间保持固定。',
        };
        // 沿用历史必填摘要列，摘要不再代表设备审批凭据。
        const approvalHash = mcpHash({ id, fixed, before, preview, expiresAt });
        // 私有动作表不触发客户端业务创建。
        const action = await transaction.mcpAction.create({
          data: {
            id,
            ...this.actionIdentity(connection),
            requestId,
            inputHash,
            steps: mcpJson(fixed),
            baseline: mcpHash(before),
            preview: mcpJson(preview),
            approvalHash,
            expiresAt,
          },
        });
        return this.actionView(action, true);
      },
    );
  }

  /// 取消与提交共用owner锁，终态仅返回回执，取消不是补偿撤销。
  async cancel(
    context: ActionContext,
    actionId: string,
  ): Promise<Record<string, unknown>> {
    mcpId.parse(actionId);
    // 外部鉴权后在事务内重新检查，不能使用已撤销的旧连接对象。
    const initial = await this.scope(context);
    return withinBusinessTransaction(
      this.prisma,
      connectionActor(initial),
      async (transaction) => {
        // 只有当前有效连接能够操作自己的待执行动作。
        const connection = await this.scope(context, transaction);
        // 所有模块范围仍以当前权限为准，不能猜测其他连接动作身份。
        const action = await transaction.mcpAction.findFirst({
          where: { id: actionId, ...this.actionIdentity(connection) },
        });
        if (!action) throw new NotFoundException('操作不存在');
        if (action.result || action.status !== 'pending')
          return this.actionView(action, true);
        for (const step of action.steps as unknown as McpStep[])
          this.tool(connection, step.name, true);
        return this.actionView(
          await transaction.mcpAction.update({
            where: { id: actionId },
            data: {
              status: action.expiresAt <= new Date() ? 'expired' : 'cancelled',
            },
          }),
          true,
        );
      },
    );
  }

  /// 按连接写权限原子提交固定动作，响应丢失后按原ID重放回执。
  async commit(
    context: ActionContext,
    actionId: string,
    guard?: AssistantCommitGuard,
  ): Promise<Record<string, unknown>> {
    mcpId.parse(actionId);
    if (typeof context !== 'string' && !guard)
      throw new ForbiddenException('助手提交缺少服务端执行门禁');
    // 事务内再次检查撤销/到期和每个工具权限。
    const initial = await this.scope(context);
    return withinBusinessTransaction(
      this.prisma,
      connectionActor(initial),
      async (transaction) => {
        // 未过期授权在 owner 锁内重新确认。
        const connection = await this.scope(context, transaction);
        // 不跨连接提交或查询他人操作。
        const action = await transaction.mcpAction.findFirst({
          where: { id: actionId, ...this.actionIdentity(connection) },
        });
        if (!action) throw new NotFoundException('操作不存在');
        if (action.result) return this.actionView(action, true);
        // 终态只读返回，旧approved动作也不能被新流程自动放行。
        if (action.status !== 'pending') return this.actionView(action, true);
        if (action.expiresAt <= new Date())
          return this.actionView(
            await transaction.mcpAction.update({
              where: { id: actionId },
              data: { status: 'expired' },
            }),
            true,
          );
        // 私有步骤由服务端准备，提交不接收模型修改参数。
        const steps = action.steps as unknown as McpStep[];
        // 前置摘要包含主项、子项、关系、历史和永久墓碑。
        const modules = [
          ...new Set(
            steps.map((step) => this.tool(connection, step.name, true).module),
          ),
        ];
        // 同一份真实前置快照还用于记录实际提交的受保护身份。
        const beforeSnapshot = await this.snapshot(
          transaction,
          connection.userId,
          modules,
        );
        // 补偿在真正提交时再次验证原动作和窗口，不依赖准备时校验。
        const undoOf = (action.preview as Record<string, Prisma.JsonValue>)
          .undoOf;
        if (typeof undoOf === 'string') {
          // 原结果只能来自当前连接，后置基线仍必须与当前完整事实相同。
          const original = await transaction.mcpAction.findFirst({
            where: {
              id: undoOf,
              ...this.actionIdentity(connection),
              status: 'succeeded',
            },
          });
          if (
            !original ||
            Date.now() >= original.updatedAt.getTime() + 600000 ||
            (original.result as Record<string, Prisma.JsonValue> | null)
              ?.afterBaseline !== mcpHash(beforeSnapshot)
          )
            return this.actionView(
              await transaction.mcpAction.update({
                where: { id: actionId },
                data: { status: 'conflict' },
              }),
              true,
            );
        }
        if (mcpHash(beforeSnapshot) !== action.baseline)
          return this.actionView(
            await transaction.mcpAction.update({
              where: { id: actionId },
              data: { status: 'conflict' },
            }),
            true,
          );
        // 仅在基线与有效期均可执行时放行，失败状态不能被标为已提交。
        if (connection.source === 'assistant')
          await guard!(transaction, action);
        // 所有步骤及领域回执和最终操作状态共用一个事务。
        const values = await this.runSteps(connection, actionId, steps);
        // 候选提交成功仍属于正文冲突，不能把它伪装成正式正文已经采用。
        const hasConflict = values.some(
          (value) =>
            value &&
            typeof value === 'object' &&
            !Array.isArray(value) &&
            value.status === 'conflict',
        );
        // 补偿基线只能由服务器保存，不能由模型伪造。
        const afterSnapshot = await this.snapshot(
          transaction,
          connection.userId,
          modules,
        );
        // 后置摘要只用于条件补偿；实际身份用于阻止迟到离线字段覆盖。
        const afterBaseline = mcpHash(afterSnapshot);
        // 动作回执持久保留这些身份，不随令牌撤销或日志轮换丢弃保护。
        const protectedRecords = Object.entries(afterSnapshot).flatMap(
          ([table, rows]) =>
            rows
              .filter(
                (row) =>
                  typeof row.id === 'string' &&
                  mcpHash(row) !==
                    mcpHash(
                      beforeSnapshot[table]?.find(
                        (prior) => prior.id === row.id,
                      ) ?? null,
                    ),
              )
              .map((row) => ({ table, id: row.id })),
        );
        return this.actionView(
          await transaction.mcpAction.update({
            where: { id: actionId },
            data: {
              status: hasConflict ? 'conflict' : 'succeeded',
              result: mcpJson({
                values,
                afterBaseline,
                protectedRecords,
                serverSavedAt: new Date().toISOString(),
                syncStatus: hasConflict
                  ? '冲突候选已保存，正式正文未采用；客户端下行状态未知'
                  : '服务器已保存，客户端下行状态未知',
              }),
            },
          }),
          true,
        );
      },
    );
  }

  /// 持久回执可重启恢复，查询不会修改状态或再次执行业务。
  async status(
    context: ActionContext,
    actionId: string,
  ): Promise<Record<string, unknown>> {
    mcpId.parse(actionId);
    // 不缓存旧的能力和操作授权。
    const connection = await this.scope(context);
    // 限定当前连接，避免另一只读连接探查写入结果。
    const action = await this.prisma.mcpAction.findFirst({
      where: { id: actionId, ...this.actionIdentity(connection) },
    });
    if (!action) throw new NotFoundException('操作不存在');
    return this.actionView(action, true);
  }

  /// 新增操作的条件补偿先准备固定预览，再由提交工具执行软删除。
  async undo(
    context: ActionContext,
    actionId: string,
    requestId: string,
  ): Promise<Record<string, unknown>> {
    mcpId.parse(actionId);
    // 状态结果包含真实正式记录身份，不能使用预览中的临时身份。
    const original = await this.status(context, actionId);
    // 私有步骤不从MCP响应反向接受。
    // 当前来源在读取私有参数前必须重新验证。
    const connection = await this.scope(context);
    const action = await this.prisma.mcpAction.findFirstOrThrow({
      where: { id: actionId, ...this.actionIdentity(connection) },
    });
    // 只给可靠单条新增显示补偿，批量及其他变更需明确业务动作。
    const steps = action.steps as unknown as McpStep[];
    // 当前目录必须仍将此动作标为可补偿。
    if (
      original.status !== 'succeeded' ||
      steps.length !== 1 ||
      !this.tool(connection, steps[0]!.name, true).undoCreate
    )
      throw new BadRequestException('此操作不支持通用撤销，请使用明确业务操作');
    // 真实创建结果的正式身份，笔记结果包装在note字段。
    const value = (
      (action.result as Record<string, Prisma.JsonValue>)
        .values as Prisma.JsonValue[]
    )[0] as Record<string, Prisma.JsonValue>;
    // 笔记正文保存返回带状态的对象。
    const record = (value.note ?? value) as Record<string, Prisma.JsonValue>;
    // 模块固定删除入口，不使用任意记录执行器。
    const deletes: Record<McpModule, string> = {
      quotes: 'delete_quote',
      time: 'delete_time_entry',
      todos: 'delete_todo',
      inventory: 'delete_item',
      memberships: 'delete_membership',
      events: 'delete_event',
      notes: 'delete_note',
    };
    return this.prepare(
      context,
      requestId,
      [
        {
          name: deletes[this.tool(connection, steps[0]!.name, true).module],
          input: { id: record.id },
        },
      ],
      actionId,
    );
  }

  /// 同一状态视图用于协议和设置页，敏感内部基线不返回。
  private actionView(
    action: McpAction,
    detail: boolean,
  ): Record<string, unknown> {
    // 到期状态可只读推导，不让查询工具隐式写入。
    const status =
      ['pending', 'approved'].includes(action.status) &&
      action.expiresAt <= new Date()
        ? 'expired'
        : action.status;
    return {
      id: action.id,
      connectionId: action.connectionId,
      source: action.source,
      status,
      createdAt: action.createdAt.toISOString(),
      updatedAt: action.updatedAt.toISOString(),
      expiresAt: action.expiresAt.toISOString(),
      ...(detail
        ? {
            preview: {
              ...(action.preview as Record<string, Prisma.JsonValue>),
              approvalLocation: undefined,
            },
            result: action.result
              ? {
                  ...(action.result as Record<string, Prisma.JsonValue>),
                  afterBaseline: undefined,
                }
              : null,
          }
        : {
            preview: {
              steps: (
                (action.preview as Record<string, Prisma.JsonValue>)
                  .steps as Array<Record<string, Prisma.JsonValue>>
              ).map((step) => ({
                tool: step.tool,
                description: step.description,
              })),
              affectedRecords: (
                action.preview as Record<string, Prisma.JsonValue>
              ).affectedRecords,
            },
          }),
    };
  }
}
