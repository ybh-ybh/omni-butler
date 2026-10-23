import { NotFoundException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { Prisma } from '../src/generated/prisma/client';
import { AssistantPresentation } from '../src/assistant/assistant-presentation.service';
import { AssistantStore } from '../src/assistant/assistant-store.service';
import { ActionExecutor } from '../src/mcp/action-executor';
import type { ActionToolDescription, AssistantActionContext } from '../src/mcp/action-context';
import type { McpModule } from '../src/mcp/mcp-catalog';

describe('助手真实业务卡片及可读分类', () => {
  /// 独立合成 owner 和任务，不读取用户数据库或模型配置。
  const owner = randomUUID();
  /// 来源身份只由测试服务端构造。
  const context: AssistantActionContext = { source: 'assistant', taskId: randomUUID(), runId: randomUUID(), actor: { sub: owner, sid: randomUUID(), typ: 'access' }, timeZone: 'Asia/Shanghai' };
  /// 七模块采用真实工具名称及其主项字段形状。
  const modules: { module: McpModule; tool: string; table: string; name: string; fields: Record<string, unknown> }[] = [
    { module: 'quotes', tool: 'create_quote', table: 'quote', name: '合成名言', fields: { content: '合成名言' } },
    { module: 'time', tool: 'create_time_entry', table: 'timeEntry', name: '学习复盘', fields: { activity: '学习复盘' } },
    { module: 'todos', tool: 'create_todo', table: 'todoItem', name: '阅读任务', fields: { title: '阅读任务' } },
    { module: 'inventory', tool: 'create_item', table: 'inventoryItem', name: '测试物品', fields: { name: '测试物品' } },
    { module: 'memberships', tool: 'create_membership', table: 'membership', name: '测试会员', fields: { name: '测试会员' } },
    { module: 'events', tool: 'create_event', table: 'event', name: '测试事件', fields: { name: '测试事件' } },
    { module: 'notes', tool: 'create_note', table: 'noteEntry', name: '测试笔记', fields: { title: '测试笔记', tags: '[]' } },
  ];
  /// 模块与身份共同定位合成服务器记录。
  let records: Map<string, Record<string, unknown>>;
  /// 可观察的数据库读边界。
  let database: Record<string, { findFirst?: jest.Mock; findMany?: jest.Mock }>;
  /// 唯一目录替身仍限制模块与读写性质。
  let definitions: ActionToolDescription[];
  /// 正式显示服务。
  let presentation: AssistantPresentation;

  beforeEach(() => {
    records = new Map();
    database = { taxonomyEntry: { findMany: jest.fn().mockResolvedValue([]) }, recordTaxonomyLink: { findMany: jest.fn().mockResolvedValue([]) }, mcpAction: { findFirst: jest.fn().mockResolvedValue(null) } };
    definitions = modules.flatMap((item) => [{ name: item.tool, module: item.module, write: true, description: '合成业务工具', inputSchema: {} }, { name: `get_${item.module}`, module: item.module, write: false, description: '合成查询工具', inputSchema: {} }]);
    definitions.push({ name: 'trash_quote', module: 'quotes', write: true, description: '软删除名言', inputSchema: {} }, ...['get_statistics', 'get_review_context', 'list_recycle_bin'].map((name) => ({ name, write: false, description: '受控查询', inputSchema: {} })));
    for (const item of modules) {
      // 同一 UUID 不能跨模块或 owner 读取。
      database[item.table] = { findFirst: jest.fn(({ where }: { where: { id: string; userId: string } }): Promise<Record<string, unknown> | null> => Promise.resolve(where.userId === owner ? records.get(`${item.module}:${where.id}`) ?? null : null)) };
    }
    // 仅替换存储与认证边界，不重写名称、模块或关系补全实现。
    const store = { prisma: database, authorized: (_actor: unknown, action: (transaction: Prisma.TransactionClient) => Promise<unknown>): Promise<unknown> => action(database as unknown as Prisma.TransactionClient) } as unknown as AssistantStore;
    // 只向显示服务提供可发现工具，不提供任意模块字符串转换。
    const actions = { listTools: (): Promise<ActionToolDescription[]> => Promise.resolve(definitions) } as unknown as ActionExecutor;
    presentation = new AssistantPresentation(store, actions);
  });

  it.each(modules)('$module 的实际记录生成可读标题及正式引用', async (fixture) => {
    // 真实领域返回值包含主项身份及业务文字。
    const record = { id: randomUUID(), userId: owner, ...fixture.fields };
    records.set(`${fixture.module}:${record.id}`, record);
    // 不同领域使用不同包装，显示层不能只识别 note。
    const keys: Partial<Record<McpModule, string>> = { time: 'timeEntry', todos: 'todo', inventory: 'item', memberships: 'membership', events: 'event', notes: 'note' };
    // 会员与事件故意同时带有子项 ID，导航必须使用主项。
    const entry = keys[fixture.module] ? { [keys[fixture.module]!]: record, payment: { id: randomUUID() }, completion: { id: randomUUID() } } : record;
    // 执行顺序与冻结步骤对应。
    const result = await presentation.result(context, [{ name: fixture.tool, input: {} }], { values: [entry] });
    expect(result.entityRefs).toEqual([{ module: fixture.module, id: record.id, label: fixture.name, record }]);
    expect(JSON.stringify(result.entityRefs)).not.toContain('"label":"' + record.id);
  });

  it.each(['record', 'entry', 'timeEntry'])('兼容 %s 主项包装', async (key) => {
    // 时间主项不能误取同包装内的辅助身份。
    const record = { id: randomUUID(), activity: '主项活动' };
    // 兼容不同现有业务接口包装，不更改原始回执形状。
    const result = await presentation.result(context, [{ name: 'create_time_entry', input: {} }], { values: [{ [key]: record }] });
    expect(result.entityRefs).toEqual([{ module: 'time', id: record.id, label: '主项活动', record }]);
  });

  it('分类标签及位置从正式关系补显示名称，关系查询带owner和删除过滤', async () => {
    // 物品字段本身没有分类 ID，显示名称仍应从关系获取。
    const id = randomUUID();
    // 分类、标签及位置均使用合成数据。
    const taxonomies = [
      { id: randomUUID(), userId: owner, module: 'inventory', kind: 'category', name: '数码', deletedAt: null },
      { id: randomUUID(), userId: owner, module: 'inventory', kind: 'tag', name: '常用', deletedAt: null },
      { id: randomUUID(), userId: owner, module: 'inventory', kind: 'location', name: '书房', deletedAt: null },
    ];
    database.taxonomyEntry!.findMany!.mockResolvedValue(taxonomies);
    database.recordTaxonomyLink!.findMany!.mockResolvedValue(taxonomies.map((taxonomy) => ({ id: randomUUID(), recordId: id, taxonomyId: taxonomy.id, userId: owner, module: 'inventory', deletedAt: null, taxonomy })));
    // 真实分类名称不依赖旧字段中的 UUID 文本。
    const result = await presentation.result(context, [{ name: 'create_item', input: {} }], { values: [{ id, name: '电脑' }] });
    expect(result.entityRefs).toEqual([{ module: 'inventory', id, label: '电脑', record: { id, name: '电脑', categoryNames: ['数码'], tagNames: ['常用'], locationNames: ['书房'] } }]);
    expect(database.recordTaxonomyLink!.findMany).toHaveBeenCalledWith(expect.objectContaining({ where: { userId: owner, recordId: { in: [id] }, deletedAt: null, taxonomy: { deletedAt: null } } }));
  });

  it('旧categoryId/tags数组也映射名称，跨模块同UUID不能串分类', async () => {
    // 时间与物品共用合成 UUID，验证模块是关系身份的一部分。
    const id = randomUUID(), categoryId = randomUUID(), tagId = randomUUID();
    database.taxonomyEntry!.findMany!.mockResolvedValue([{ id: categoryId, userId: owner, module: 'timeline', kind: 'category', name: '学习' }, { id: tagId, userId: owner, module: 'notes', kind: 'tag', name: '面试' }]);
    database.recordTaxonomyLink!.findMany!.mockResolvedValue([{ id: randomUUID(), recordId: id, taxonomyId: categoryId, userId: owner, module: 'inventory', deletedAt: null, taxonomy: { id: categoryId, userId: owner, module: 'inventory', kind: 'category', name: '物品专用', deletedAt: null } }]);
    expect(await presentation.decorate(owner, { id, categoryId }, 'time')).toEqual({ id, categoryId, categoryNames: ['学习'] });
    expect(await presentation.decorate(owner, { id: randomUUID(), tags: JSON.stringify([tagId]) }, 'notes')).toMatchObject({ tagNames: ['面试'] });
  });

  it('generic restore_record按input.module定位，补偿空intents从真实action.steps恢复', async () => {
    // 恢复返回的正式快照可以直接定位原记录。
    const id = randomUUID();
    expect((await presentation.result(context, [{ name: 'restore_record', input: { module: 'events', id } }], { values: [{ id, name: '恢复事件' }] })).entityRefs).toEqual([{ module: 'events', id, label: '恢复事件', record: { id, name: '恢复事件' } }]);
    // 软删除补偿可能只返回 ids，必须使用真实步骤定位主项。
    const quote = { id: randomUUID(), userId: owner, content: '被补偿的名言', deletedAt: new Date().toISOString() };
    records.set(`quotes:${quote.id}`, quote);
    // 调用者无法通过空或伪造 intents 覆盖服务器步骤。
    const actionId = randomUUID();
    database.mcpAction!.findFirst!.mockResolvedValue({ status: 'succeeded', result: {}, steps: [{ name: 'trash_quote', input: { id: quote.id } }] });
    expect((await presentation.result(context, [], { values: [{ ids: [quote.id] }] }, actionId)).entityRefs).toEqual([{ module: 'quotes', id: quote.id, label: quote.content, record: quote }]);
    expect(database.mcpAction!.findFirst).toHaveBeenCalledWith({ where: { id: actionId, userId: owner, source: 'assistant', sourceId: context.taskId, connectionId: null } });
    database.mcpAction!.findFirst!.mockResolvedValue(null);
    await expect(presentation.result(context, [], { values: [] }, randomUUID())).rejects.toThrow(NotFoundException);
  });

  it('内部restore_notes已规范化而不在模型目录时仍可定位模块', async () => {
    // 动作步骤来自真实来源记录，内部名称映射不依赖模型目录泄露。
    const record = { id: randomUUID(), title: '恢复笔记' };
    database.mcpAction!.findFirst!.mockResolvedValue({ status: 'succeeded', result: {}, steps: [{ name: 'restore_notes', input: { id: record.id } }] });
    expect((await presentation.result(context, [], { values: [{ note: record }] }, randomUUID())).entityRefs).toEqual([{ module: 'notes', id: record.id, label: '恢复笔记', record }]);
  });

  it('未下行快照按固定module及owner读取，记录只有UUID时使用普通名称', async () => {
    // 名言详情也具有服务器快照入口。
    const id = randomUUID();
    records.set(`quotes:${id}`, { id, userId: owner });
    expect(await presentation.entity(context.actor, 'quotes', id)).toMatchObject({ id, module: 'quotes', label: '记录', serverSaved: true });
    expect(database.quote!.findFirst).toHaveBeenCalledWith({ where: { id, userId: owner } });
    await expect(presentation.entity({ ...context.actor, sub: randomUUID() }, 'quotes', id)).rejects.toThrow(NotFoundException);
    await expect(presentation.entity(context.actor, 'arbitrary_table', id)).rejects.toThrow();
  });

  it('统计引用最多20条真实快照，标记有限来源且不更改统计口径', async () => {
    // 合成统计源包含超过卡片上限的正式记录。
    const sourceIds = Array.from({ length: 25 }, (_value, index) => {
      // 正式资料由存储边界返回，不信任工具输出伪造的标签。
      const id = randomUUID();
      records.set(`time:${id}`, { id, activity: `活动${index}` }); return id;
    });
    // 统计值仍原封不动，由真实工具负责数值计算。
    const output = { sourceIds, count: 500, completedSeconds: 10000 };
    // 卡片仅引用当前可读取的有限对象。
    const refs = await presentation.readReferences(context, 'get_statistics', { module: 'time' }, output);
    expect(refs).toHaveLength(20);
    expect(refs.every((ref) => ref.referenceLimited === true && ref.referenceLimit === 20)).toBe(true);
    expect(refs[0]).toMatchObject({ id: sourceIds[0], module: 'time', label: '活动0' });
    expect(output.count).toBe(500); expect(output.completedSeconds).toBe(10000);
  });

  it('多模块复盘、列表及单get包装引用只读取真实owner，未知工具及写工具不能提供来源', async () => {
    // 真实记录的标题优先于输出中伪造的标题。
    const noteId = randomUUID(), eventId = randomUUID();
    records.set(`notes:${noteId}`, { id: noteId, title: '真实笔记' }); records.set(`events:${eventId}`, { id: eventId, name: '真实事件' });
    expect(await presentation.readReferences(context, 'get_review_context', {}, { references: [{ module: 'notes', sourceIds: [noteId] }, { module: 'events', sourceIds: [eventId] }, { module: 'arbitrary_table', sourceIds: [noteId] }] })).toHaveLength(2);
    expect(await presentation.readReferences(context, 'get_notes', {}, { note: { id: noteId, title: '伪造标题' } })).toEqual([expect.objectContaining({ id: noteId, label: '真实笔记', module: 'notes' })]);
    expect(await presentation.readReferences(context, 'get_notes', {}, { items: [{ id: noteId }, { id: noteId }, { id: randomUUID() }] })).toHaveLength(1);
    expect(await presentation.readReferences(context, 'unknown_tool', {}, { sourceIds: [noteId] })).toEqual([]);
    expect(await presentation.readReferences(context, 'create_note', {}, { sourceIds: [noteId] })).toEqual([]);
  });
});
