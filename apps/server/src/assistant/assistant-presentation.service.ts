import { Injectable, NotFoundException } from '@nestjs/common';
import { z } from 'zod';
import type { AuthUser } from '../auth/auth.types';
import type { Prisma } from '../generated/prisma/client';
import type { McpStep } from '../mcp/action-executor';
import type { AssistantActionContext, ActionToolDescription } from '../mcp/action-context';
import { ActionExecutor } from '../mcp/action-executor';
import { mcpModules, type McpModule } from '../mcp/mcp-catalog';
import { AssistantStore } from './assistant-store.service';
import { assistantEntityVersion } from './assistant-entity-editor.service';

/// 分类关系沿用已有模块名称，不与公开业务模块名称混淆。
const taxonomyModules: Partial<Record<McpModule, string>> = { time: 'timeline', inventory: 'inventory', memberships: 'membership', notes: 'notes' };
/// 预览表名只通过固定映射提供显示上下文，不能动态查询任意表。
const tableModules: Record<string, McpModule> = { quotes: 'quotes', time_entries: 'time', todo_items: 'todos', inventory_items: 'inventory', memberships: 'memberships', events: 'events', note_entries: 'notes' };
/// 主项包装优先于账单、步骤及完成历史的子项身份。
const recordFields = ['record', 'note', 'event', 'membership', 'todo', 'item', 'timeEntry', 'entry', 'quote'] as const;
/// 递归装饰只接受已登记的包装字段。
const wrapperModules: Record<string, McpModule> = { note: 'notes', event: 'events', membership: 'memberships', todo: 'todos', item: 'inventory', timeEntry: 'time', entry: 'time', quote: 'quotes' };

/// 卡片仅增加真实名称及引用，不修改任何业务数据或执行基线。
@Injectable()
export class AssistantPresentation {
  /// 复用当前认证归属和唯一工具目录。
  constructor(private readonly store: AssistantStore, private readonly actions: ActionExecutor) {}

  /// 未下行到本机的记录也可按明确模块读取同归属服务器快照。
  async entity(actor: AuthUser, module: string, id: string): Promise<unknown> {
    // 模块及身份不能解释成任意路由、表名或 URL。
    const target = z.enum(mcpModules).parse(module);
    z.uuid().parse(id);
    // 认证事务先完成主项读取，不在持有 owner 锁时占用第二条池连接装饰名称。
    const record = await this.store.authorized(actor, (transaction) => this.readRecord(transaction, actor.sub, target, id));
    if (!record) throw new NotFoundException('该业务记录尚不可用或已永久删除');
    return { module: target, id, label: this.label(record), record: await this.decorate(actor.sub, record, target), editVersion: assistantEntityVersion(record), serverSaved: true };
  }

  /// 正文中的分类 ID 与真实关系同时补显示名称，绝不把 UUID 当名称。
  async decorate(userId: string, value: unknown, module?: McpModule): Promise<unknown> {
    // 仅收集对象身份，正文文本不能变成关系查询参数。
    const ids = new Set<string>();
    // 结果结构只作为 JSON 资料遍历。
    const collect = (item: unknown): void => {
      if (Array.isArray(item)) { for (const child of item) collect(child); return; }
      if (!isRecord(item) || item instanceof Date) return;
      if (typeof item.id === 'string' && z.uuid().safeParse(item.id).success) ids.add(item.id);
      for (const child of Object.values(item)) collect(child);
    };
    collect(value);
    // 元数据和关系都限定 owner，历史删除关系不会冒充当前分类。
    const [entries, links] = await Promise.all([
      this.store.prisma.taxonomyEntry.findMany({ where: { userId, deletedAt: null }, orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }] }),
      ids.size ? this.store.prisma.recordTaxonomyLink.findMany({ where: { userId, recordId: { in: [...ids] }, deletedAt: null, taxonomy: { deletedAt: null } }, include: { taxonomy: true }, orderBy: [{ createdAt: 'asc' }, { id: 'asc' }] }) : Promise.resolve([]),
    ]);
    // 名称只从当前归属的真实分类读取。
    const names = new Map(entries.map((entry) => [entry.id, entry]));
    // 同一 UUID 在不同模块不能串用分类关系。
    const relationNames = new Map<string, { category: string[]; tag: string[]; location: string[] }>();
    for (const link of links) {
      if (link.userId !== userId || link.deletedAt || link.taxonomy.userId !== userId || link.taxonomy.deletedAt || link.taxonomy.module !== link.module) continue;
      // 只显示现有三种业务分类关系。
      const kind = link.taxonomy.kind;
      if (kind !== 'category' && kind !== 'tag' && kind !== 'location') continue;
      // 分类模块与对象身份共同构成显示缓存身份。
      const key = `${link.module}:${link.recordId}`;
      // 重复关系不重复显示名称。
      const selected = relationNames.get(key) ?? { category: [], tag: [], location: [] };
      if (!selected[kind].includes(link.taxonomy.name)) selected[kind].push(link.taxonomy.name);
      relationNames.set(key, selected);
    }
    // 预览 before/after 只装饰明确字段，不用当前关系伪造计划后的分类。
    const visit = (item: unknown, inherited?: McpModule): unknown => {
      if (Array.isArray(item)) return item.map((child) => visit(child, inherited));
      if (!isRecord(item) || item instanceof Date) return item;
      // 模块仅来自固定表映射或已验证业务模块。
      const current = typeof item.table === 'string' ? tableModules[item.table] ?? inherited : moduleValue(item.module) ?? inherited;
      // 包装字段传递主项上下文，普通字符串仍保持原样。
      const object = Object.fromEntries(Object.entries(item).map(([key, child]) => [key, visit(child, wrapperModules[key] ?? current)]));
      for (const [key, target] of [['categoryId', 'categoryNames'], ['categoryIds', 'categoryNames'], ['category_id', 'categoryNames'], ['category_ids', 'categoryNames'], ['category', 'categoryNames'], ['tagIds', 'tagNames'], ['tag_ids', 'tagNames'], ['tags', 'tagNames'], ['locationIds', 'locationNames'], ['location_ids', 'locationNames'], ['taxonomyId', 'taxonomyNames'], ['taxonomy_id', 'taxonomyNames']] as const) {
        // 只解析合法 UUID 或 UUID 数组，不将普通分类名称解释为身份。
        const labels = taxonomyIds(object[key]).map((id) => names.get(id)).filter((entry) => !!entry && (!current || entry.module === taxonomyModules[current])).map((entry) => entry!.name);
        if (labels.length) object[target] = [...new Set(labels)];
      }
      // 缺少裸分类字段时，正式关系仍可提供当前分类、标签及位置。
      const selected = current && typeof item.id === 'string' ? relationNames.get(`${taxonomyModules[current] ?? current}:${item.id}`) : undefined;
      if (selected) for (const [kind, target] of [['category', 'categoryNames'], ['tag', 'tagNames'], ['location', 'locationNames']] as const) if (selected[kind].length) object[target] = selected[kind];
      if (isRecord(object.after)) object.label = this.label(object.after);
      return object;
    };
    return visit(value, module);
  }

  /// 结果引用正式业务主项，补偿使用服务器实际步骤恢复模块和目标。
  async result(context: AssistantActionContext, steps: McpStep[], value: unknown, actionId?: string): Promise<Record<string, unknown>> {
    // 动作身份存在时，以真实动作步骤为准，不能信任空 intents 或客户端参数。
    const actualSteps = actionId ? await this.actualSteps(context, actionId) : steps;
    // 模块来自唯一工具目录及固定恢复映射。
    const definitions = await this.actions.listTools(context);
    // 完整业务回执只增加展示字段，不修改实际执行结果。
    const original = isRecord(value) ? value : {};
    // 结果顺序与冻结的实际步骤保持对应。
    const values = Array.isArray(original.values) ? original.values as unknown[] : [];
    // 多次编辑同一对象时，卡片引用保留最后一步真实快照。
    const references = new Map<string, Record<string, unknown>>();
    // 每一步原始回执也补齐可读分类名称。
    const decoratedValues: unknown[] = [];
    for (const [index, entry] of values.entries()) {
      // 没有实际步骤则不猜测业务模块。
      const step = actualSteps[index];
      // 通用恢复通过明确的 input.module 定位，内部恢复通过固定名称定位。
      const module = step ? this.stepModule(step, definitions) : undefined;
      // 包装中的主项优先，不能误将账单和完成历史作为主项。
      let record = recordValue(entry);
      if (module && (!record || typeof record.id !== 'string')) {
        // 只返回 ids 的状态/软删除工具，从真实主项参数取当前快照。
        const id = step ? primaryId(module, step.input) : undefined;
        if (id) record = await this.store.authorized(context.actor, (transaction) => this.readRecord(transaction, context.actor.sub, module, id));
      }
      decoratedValues.push(await this.decorate(context.actor.sub, entry, module));
      if (!module || !record || typeof record.id !== 'string' || !z.uuid().safeParse(record.id).success) continue;
      // 正式主项的分类由真实关系补充，名称绝不回退到 UUID。
      const decorated = await this.decorate(context.actor.sub, record, module);
      references.set(`${module}:${record.id}`, { module, id: record.id, label: this.label(record), record: decorated, operation: resultOperation(step) });
    }
    return { ...original, values: decoratedValues, entityRefs: [...references.values()] };
  }

  /// 只读工具的来源引用最多展示20条，所有标题与快照都重新按 owner 查询。
  async readReferences(context: AssistantActionContext, toolName: string, args: Record<string, unknown>, output: unknown): Promise<Record<string, unknown>[]> {
    // 引用收集只允许当前目录中的已注册只读工具。
    const definitions = await this.actions.listTools(context);
    // 非工具或写工具的任意输出不能伪装成查询来源。
    const definition = definitions.find((tool) => tool.name === toolName && !tool.write);
    if (!definition || !isRecord(output)) return [];
    // 多模块复盘仅接受受控工具自身返回的 references。
    const selectedModule = definition.module ?? (toolName === 'get_statistics' || toolName === 'list_recycle_bin' ? moduleValue(args.module) : undefined);
    // 模块加真实身份去重，引用上限不会改变原统计口径。
    const candidates = new Map<string, { module: McpModule; id: string }>();
    // 来源身份须为 UUID，不能接受任意 URL 或自由模块。
    const add = (module: McpModule | undefined, id: unknown): void => { if (module && typeof id === 'string' && z.uuid().safeParse(id).success) candidates.set(`${module}:${id}`, { module, id }); };
    if (Array.isArray(output.references)) for (const reference of output.references) {
      if (!isRecord(reference)) continue;
      // 模块必须在固定七模块中，不能解释成任意资源。
      const module = moduleValue(reference.module);
      if (module !== selectedModule && toolName !== 'get_review_context') continue;
      if (Array.isArray(reference.sourceIds)) for (const id of reference.sourceIds) add(module, id);
    }
    if (selectedModule) {
      if (Array.isArray(output.sourceIds)) for (const id of output.sourceIds) add(selectedModule, id);
      if (Array.isArray(output.items)) for (const item of output.items) add(selectedModule, recordValue(item)?.id);
      add(selectedModule, recordValue(output)?.id);
    }
    // 限量只约束引用卡片，不能把20条引用说成覆盖全部统计来源。
    const limited = candidates.size > 20;
    // 已删除或不存在的源记录不伪造为可点击对象。
    const references: Record<string, unknown>[] = [];
    for (const candidate of [...candidates.values()].slice(0, 20)) {
      try {
        // 返回标签由服务器当前记录生成，不信任工具文本中的标题。
        const entity = await this.entity(context.actor, candidate.module, candidate.id) as Record<string, unknown>;
        references.push({ ...entity, referenceLimited: limited, referenceLimit: 20 });
      } catch (error: unknown) { if (!(error instanceof NotFoundException)) throw error; }
    }
    return references;
  }

  /// 真实动作必须属于当前 owner 与助手任务，且已经保存实际结果。
  private async actualSteps(context: AssistantActionContext, id: string): Promise<McpStep[]> {
    z.uuid().parse(id);
    return this.store.authorized(context.actor, async (transaction) => {
      // 来源隔离防止借外部 MCP 或其他任务生成伪造结果卡片。
      const action = await transaction.mcpAction.findFirst({ where: { id, userId: context.actor.sub, source: 'assistant', sourceId: context.taskId, connectionId: null } });
      if (!action?.result || !['succeeded', 'conflict'].includes(action.status)) throw new NotFoundException('实际助手操作结果不存在');
      return action.steps as unknown as McpStep[];
    });
  }

  /// 内部恢复工具不在模型目录，仍只允许固定模块名称。
  private stepModule(step: McpStep, definitions: ActionToolDescription[]): McpModule | undefined {
    if (step.name === 'restore_record') return moduleValue(step.input.module);
    // canonical恢复工具由服务端固定，不进行任意字符串到数据库映射。
    const restore = step.name.startsWith('restore_') ? moduleValue(step.name.slice(8)) : undefined;
    return definitions.find((definition) => definition.name === step.name)?.module ?? restore;
  }

  /// 读取只使用固定表分支，每个主键查询同时带 owner。
  private async readRecord(transaction: Prisma.TransactionClient, userId: string, module: McpModule, id: string): Promise<Record<string, unknown> | null> {
    // 软删除快照用于明确实际执行结果，不意味着自动恢复。
    const where = { id, userId };
    return module === 'quotes' ? transaction.quote.findFirst({ where }) : module === 'time' ? transaction.timeEntry.findFirst({ where }) : module === 'todos' ? transaction.todoItem.findFirst({ where }) : module === 'inventory' ? transaction.inventoryItem.findFirst({ where }) : module === 'memberships' ? transaction.membership.findFirst({ where }) : module === 'events' ? transaction.event.findFirst({ where }) : transaction.noteEntry.findFirst({ where });
  }

  /// 卡片名称只取真实业务字段，空值和裸 UUID 均使用普通名称。
  private label(record: Record<string, unknown>): string {
    // 优先主项名称，不用身份字段作为标题。
    const value = [record.name, record.title, record.activity, record.content, record.body].find((item): item is string => typeof item === 'string' && !!item.trim() && !z.uuid().safeParse(item.trim()).success);
    return value?.trim().slice(0, 80) ?? '记录';
  }
}

/// 操作摘要只从真实冻结工具步骤推导，旧卡片不据此猜测动作。
function resultOperation(step: McpStep | undefined): string | undefined {
  if (!step) return undefined;
  if (step.name.startsWith('create_') || step.name === 'start_time_entry') return 'create';
  if (step.name.startsWith('trash_') || ['delete_quote', 'delete_time_entry', 'delete_todo', 'delete_item', 'delete_membership', 'delete_event', 'delete_note'].includes(step.name)) return 'delete';
  if (step.name.startsWith('restore_')) return 'restore';
  if (step.name === 'set_todo_completed') return step.input.completed === true ? 'complete' : 'revoke';
  if (step.name === 'complete_event' || step.name === 'finish_time_entry') return 'complete';
  if (step.name === 'undo_event_completion') return 'revoke';
  return 'update';
}

/// 未知返回值只作为普通对象读取。
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === 'object' && value !== null && !Array.isArray(value); }

/// 主项包装必须有正式身份，普通 notes 文本不能变成导航对象。
function recordValue(value: unknown): Record<string, unknown> | null {
  if (!isRecord(value)) return null;
  for (const key of recordFields) if (isRecord(value[key]) && typeof value[key].id === 'string') return value[key];
  return value;
}

/// 模块使用唯一固定七模块枚举。
function moduleValue(value: unknown): McpModule | undefined { return typeof value === 'string' && (mcpModules as readonly string[]).includes(value) ? value as McpModule : undefined; }

/// 旧存储数组允许 JSON 字符串，解析失败时不把原文显示成分类身份。
function taxonomyIds(value: unknown): string[] {
  // 只解析数组字符串，不修改普通分类名称。
  let parsed = value;
  if (typeof parsed === 'string' && parsed.startsWith('[')) { try { parsed = JSON.parse(parsed); } catch { return []; } }
  return (Array.isArray(parsed) ? parsed : [parsed]).filter((id): id is string => typeof id === 'string' && z.uuid().safeParse(id).success);
}

/// 子项工具优先引用主项字段，避免导航到账单或步骤的 ID。
function primaryId(module: McpModule, input: Record<string, unknown>): string | undefined {
  // 字段来自既有领域工具契约，不接受客户端自由列名。
  const fields: Record<McpModule, string[]> = { quotes: ['quoteId', 'id'], time: ['timeEntryId', 'entryId', 'id'], todos: ['todoId', 'rootId', 'id'], inventory: ['itemId', 'id'], memberships: ['membershipId', 'id'], events: ['eventId', 'id'], notes: ['noteId', 'id'] };
  for (const field of fields[module]) if (typeof input[field] === 'string' && z.uuid().safeParse(input[field]).success) return input[field];
  return undefined;
}
