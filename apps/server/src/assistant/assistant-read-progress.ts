import { z } from 'zod';
import type { AssistantReadProgress, AssistantState } from './assistant.types';

/// 任务工具预算为八次，查询事实不能无限累积。
const MAX_READS = 8;
/// 索引包含完整 JSON 开销，中文不能按单字节估算。
const MAX_PROGRESS_BYTES = 16 * 1024;
/// 每页摘要先保留有限身份，再按整体预算确定性减少旧页明细。
const MAX_ITEMS = 40;
/// 日期资料仅接受业务日期或实际 ISO 时间，不允许夹带任意文本。
const DAY = /^\d{4}-\d{2}-\d{2}$/u;
/// 凭据不能借标题或查询词滚入长期压缩资料。
const SENSITIVE = /(?:-----BEGIN\s+(?:[A-Z ]+\s+)?PRIVATE KEY-----)|\bBearer\s+[A-Za-z0-9._~+/=-]{8,}|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|\bsk-[A-Za-z0-9_-]{12,}|(?:api[ _-]?key|access[ _-]?token|refresh[ _-]?token|token|secret|密钥|密码|口令)\s*(?:[:=：]|是|为)\s*\S+|https?:\/\/[^\s/:]+:[^\s/@]+@/iu;

/// 仅把已成功交付的只读列表事实加入当前任务，不读取模型说明或历史会话。
export function assistantRecordReadProgress(state: AssistantState, toolName: string, args: Record<string, unknown>, output: unknown): void {
  if (state.memoryInvalidated || state.undoOf) { delete state.readProgress; return; }
  if (toolName !== 'list_todos') return;
  // 请求参数与实际交付值同时校验，失败、截断占位符和未知响应不能伪造覆盖记录。
  const parameters = readParameters(args);
  // 工具正常返回的投影为对象，任意错误返回均不进入索引。
  const value = object(output);
  if (!parameters || !value || value.isError || !Array.isArray(value.items) || typeof value.hasMore !== 'boolean' || value.items.length > parameters.requested.limit) return;
  // 返回数量必须与实际条目一致，不能使用模型自报的总量。
  const returnedCount = value.items.length;
  if (value.returnedCount !== undefined && value.returnedCount !== returnedCount) return;
  // 页游标只接受已经交付条目之后的位置，避免再次从丢弃内容后跳页。
  const nextOffset = value.hasMore ? parameters.requested.offset + returnedCount : null;
  if ((value.hasMore && !returnedCount) || value.nextOffset !== nextOffset) return;
  // 只投影真实对象摘要，不复制描述、步骤或额外私有字段。
  const items = value.items.slice(0, MAX_ITEMS).map(readToolItem).filter((item): item is AssistantReadProgress['items'][number] => !!item);
  // 保留原始交付数量，非法身份或预算省略只能减少展示索引，不能变造事实。
  const observation: AssistantReadProgress = { tool: 'list_todos', ...parameters, delivered: { offset: parameters.requested.offset, endOffset: parameters.requested.offset + returnedCount }, returnedCount, hasMore: value.hasMore, nextOffset, items, ...(items.length !== returnedCount ? { itemsOmitted: true } : {}) };
  // 最近同一规范化查询取真实新结果，避免重复页无意义扩大状态。
  const previous = assistantReadProgress(state).filter((entry) => queryKey(entry) !== queryKey(observation));
  state.readProgress = bounded([...previous, observation]);
}

/// 数据库和检查点均按未知输入校验，返回隔离投影而不接受旧资料中的权限字段。
export function assistantReadProgress(state: Pick<AssistantState, 'readProgress' | 'memoryInvalidated' | 'undoOf'>): AssistantReadProgress[] {
  if (state.memoryInvalidated || state.undoOf || !Array.isArray(state.readProgress)) return [];
  // 只检查最后有限项，恶意或损坏的状态不会引发无界遍历。
  const observations: AssistantReadProgress[] = [];
  for (const candidate of state.readProgress.slice(-MAX_READS)) {
    // 持久项重新构造分页、过滤和真实对象字段，不把原对象直接交给供应商。
    const item = readObservation(candidate);
    if (!item) continue;
    // 确定性去重保持最后一次真实观察顺序。
    const previous = observations.findIndex((entry) => queryKey(entry) === queryKey(item));
    if (previous >= 0) observations.splice(previous, 1);
    observations.push(item);
  }
  return bounded(observations);
}

/// 未知值仅在普通对象形状时可投影，不消费数组中的自定义键。
function object(value: unknown): Record<string, unknown> | null { return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null; }

/// 安全整数范围和业务分页上限与实际只读工具一致。
function integer(value: unknown, min: number, max = Number.MAX_SAFE_INTEGER): value is number { return typeof value === 'number' && Number.isSafeInteger(value) && value >= min && value <= max; }

/// 日期只确认原值有效，不引入当前日期或默认时区。
function day(value: unknown): value is string { return typeof value === 'string' && DAY.test(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value; }

/// 统一参数顺序和缺省分页，过滤条件不会被压缩摘要改写。
function readParameters(value: Record<string, unknown>): Pick<AssistantReadProgress, 'filters' | 'requested'> | null {
  // 实际业务请求有确定默认分页，只有缺省字段允许补入该默认值。
  const offset = value.offset === undefined ? 0 : value.offset;
  // 页大小默认五十，与共享工具契约一致。
  const limit = value.limit === undefined ? 50 : value.limit;
  if (!integer(offset, 0, 1000000) || !integer(limit, 1, 200)) return null;
  if (value.query !== undefined && (typeof value.query !== 'string' || [...value.query].length > 200 || SENSITIVE.test(value.query))) return null;
  if ((value.fromDay !== undefined && !day(value.fromDay)) || (value.toDay !== undefined && !day(value.toDay)) || (typeof value.fromDay === 'string' && typeof value.toDay === 'string' && value.toDay <= value.fromDay)) return null;
  if ((value.completed !== undefined && typeof value.completed !== 'boolean') || (value.priorityQuadrant !== undefined && !integer(value.priorityQuadrant, 0, 3))) return null;
  return { filters: { ...(typeof value.query === 'string' && value.query.trim() ? { query: value.query.trim() } : {}), ...(typeof value.fromDay === 'string' ? { fromDay: value.fromDay } : {}), ...(typeof value.toDay === 'string' ? { toDay: value.toDay } : {}), ...(typeof value.completed === 'boolean' ? { completed: value.completed } : {}), ...(typeof value.priorityQuadrant === 'number' ? { priorityQuadrant: value.priorityQuadrant } : {}) }, requested: { offset, limit } };
}

/// 业务返回只投影白名单字段，不依赖已经可能被压缩过的标题推断身份。
function readToolItem(value: unknown): AssistantReadProgress['items'][number] | null {
  // 原始业务条目与持久索引使用同一身份校验。
  const row = object(value);
  if (!row || !z.uuid().safeParse(row.id).success || typeof row.title !== 'string') return null;
  // 标题资料始终保留为普通文本；凭据类文字不能被上下文重复携带。
  const title = SENSITIVE.test(row.title) ? '[已省略凭据类标题]' : [...row.title].slice(0, 80).join('');
  // 计数只读真实汇总，不重新遍历或复制完整步骤内容。
  const progress = object(row.progress);
  return { id: String(row.id).toLowerCase(), module: 'todos', title, ...(title !== row.title || row.titleOmitted === true ? { titleOmitted: true } : {}), ...(integer(row.priorityQuadrant, 0, 3) ? { priorityQuadrant: row.priorityQuadrant } : {}), ...(day(row.scheduledDate) ? { scheduledDate: row.scheduledDate } : {}), ...(typeof row.scheduledDate === 'string' && /^\d{4}-\d{2}-\d{2}T/u.test(row.scheduledDate) && Number.isFinite(Date.parse(row.scheduledDate)) ? { scheduledDate: new Date(row.scheduledDate).toISOString() } : {}), ...(typeof row.isCompleted === 'boolean' ? { isCompleted: row.isCompleted } : {}), ...(row.parentId === null || z.uuid().safeParse(row.parentId).success ? { parentId: row.parentId as string | null } : {}), ...(progress && integer(progress.total, 0) && integer(progress.completed, 0, progress.total) ? { progressCount: progress.total, progressCompletedCount: progress.completed } : {}) };
}

/// 索引恢复时仍验证交付范围，坏检查点不能伪称已完整读取。
function readObservation(value: unknown): AssistantReadProgress | null {
  // 顶层参数只使用白名单，不接受任何权限或运行状态字段。
  const row = object(value);
  if (!row || row.tool !== 'list_todos' || typeof row.hasMore !== 'boolean' || !Array.isArray(row.items) || !integer(row.returnedCount, 0, 200)) return null;
  // 规范过滤和分页不能从缺失的对象猜测还原。
  const filters = object(row.filters);
  // 请求和交付必须同时存在。
  const requested = object(row.requested);
  // 实际区间保留原始页面覆盖，不按剩余摘要条数回写。
  const delivered = object(row.delivered);
  if (!filters || !requested || !delivered) return null;
  // 持久字段必须具有真实分页值，不按缺省值修复损坏检查点。
  const parameters = readParameters({ ...filters, offset: requested.offset, limit: requested.limit });
  if (requested.offset === undefined || requested.limit === undefined || !parameters || row.returnedCount > parameters.requested.limit || delivered.offset !== parameters.requested.offset || delivered.endOffset !== parameters.requested.offset + row.returnedCount || row.items.length > row.returnedCount) return null;
  if (row.hasMore ? !row.returnedCount || row.nextOffset !== delivered.endOffset : row.nextOffset !== null) return null;
  // 索引中的汇总计数映射回同一安全投影，再立即丢弃其余未知字段。
  const items = row.items.slice(0, MAX_ITEMS).map((entry) => {
    // 每条持久引用只恢复白名单事实，不接受模块伪装。
    const item = object(entry);
    if (!item || item.module !== 'todos') return null;
    return readToolItem({ ...item, progress: { total: item.progressCount, completed: item.progressCompletedCount } });
  }).filter((item): item is AssistantReadProgress['items'][number] => !!item);
  // 合法但重复的身份只保留一个，原始交付数仍不变。
  const unique = [...new Map(items.map((item) => [item.id, item])).values()];
  return { tool: 'list_todos', ...parameters, delivered: { offset: parameters.requested.offset, endOffset: delivered.endOffset }, returnedCount: row.returnedCount, hasMore: row.hasMore, nextOffset: row.nextOffset as number | null, items: unique, ...(row.itemsOmitted === true || unique.length !== row.returnedCount ? { itemsOmitted: true } : {}) };
}

/// 完整参数键固定，等价字段顺序不会重复占用预算。
function queryKey(value: AssistantReadProgress): string { return JSON.stringify({ filters: value.filters, requested: value.requested }); }

/// 优先保留所有查询过滤与游标，逐条省略最早页明细并明确标记。
function bounded(values: AssistantReadProgress[]): AssistantReadProgress[] {
  // 新数组避免调用方持有的旧状态被投影读取修改。
  const result = values.slice(-MAX_READS);
  while (Buffer.byteLength(JSON.stringify(result)) > MAX_PROGRESS_BYTES) {
    // 每轮只移除一个旧明细，页面实际计数和游标完全保留。
    const candidate = result.find((entry) => entry.items.length > 0);
    if (!candidate) break;
    candidate.items.pop(); candidate.itemsOmitted = true;
  }
  return result;
}
