import type { AssistantRun } from '../generated/prisma/client';
import type { AssistantExecutionStep, AssistantState } from './assistant.types';
import { assistantVisibleReasoning } from '../ai/assistant-reasoning';

/// 模块仅映射固定公开名称，不允许自由文本拼入摘要。
const executionModules: Record<string, string> = {
  quotes: '语录',
  time: '时间记录',
  todos: '待办',
  inventory: '物品',
  memberships: '会员',
  events: '事件',
  notes: '笔记',
};
/// 专用只读工具使用固定可读名称。
const executionToolLabels: Record<string, string> = {
  read_attachment: '读取文件',
  search_attachment: '搜索文件',
  get_capabilities: '查询助手能力',
  get_action_status: '查询操作状态',
  list_recycle_bin: '查询回收站',
  get_statistics: '查询统计',
  get_review_context: '查询复盘资料',
  list_taxonomies: '查询分类和标签',
};
/// 固定词表避免模型或工具输出进入执行摘要。
const executionLabels = new Set([
  '分析任务',
  '生成回答',
  '查询资料',
  '登记修改计划',
  '保存记忆',
  '等待补充信息',
  '保存修改',
  ...Object.values(executionToolLabels),
  ...Object.values(executionModules).flatMap((module) => [
    `查询${module}`,
    `登记${module}修改计划`,
  ]),
]);
/// 摘要校验只依赖安全状态列，不接触模型快照。
type ExecutionRun = Pick<AssistantRun, 'id' | 'status' | 'updatedAt'> & {
  /// 状态从数据库或当前节点传入，公开前统一重新校验。
  state: unknown;
};

/// 私有调用详情只接受JSON参数，凭据字段脱敏并限制展示体积。
export function assistantToolDetails(value: unknown): AssistantExecutionStep['tool'] {
  if (!value || typeof value !== 'object') return undefined;
  // 历史状态也重新校验，不能直接向客户端透传任意字段。
  const tool = value as { name?: unknown; arguments?: unknown; truncated?: unknown };
  if (typeof tool.name !== 'string' || !/^[a-zA-Z][a-zA-Z0-9_]{0,79}$/.test(tool.name) || !tool.arguments || typeof tool.arguments !== 'object' || Array.isArray(tool.arguments)) return undefined;
  // 脱敏与省略分别保留明确的可读标记。
  let truncated = tool.truncated === true;
  /// 递归重建普通JSON，拒绝原型字段并限制嵌套和集合数量。
  const clean = (input: unknown, depth: number): unknown => {
    if (depth > 8) { truncated = true; return '[层级过深，已省略]'; }
    if (typeof input === 'string') {
      if (input.length <= 4000) return input;
      truncated = true;
      return `${input.slice(0, 4000)}[内容过长，已省略]`;
    }
    if (input === null || typeof input === 'boolean' || typeof input === 'number') return input;
    if (Array.isArray(input)) {
      if (input.length > 100) truncated = true;
      return input.slice(0, 100).map((entry) => clean(entry, depth + 1));
    }
    if (!input || typeof input !== 'object') return null;
    // 每个对象也有上限，展示不是额外的无限资料出口。
    const entries = Object.entries(input);
    if (entries.length > 100) truncated = true;
    return Object.fromEntries(entries.slice(0, 100).filter(([key]) => !['__proto__', 'constructor', 'prototype'].includes(key)).map(([key, entry]) => [key.slice(0, 200), /^(authorization|cookie|.*token|password|.*secret.*|api[_-]?key|base64|data[_-]?url)$/i.test(key) ? '[已隐藏]' : clean(entry, depth + 1)]));
  };
  // 最终UTF8预算包含JSON结构，不能仅限制字符数。
  const args = clean(tool.arguments, 0) as Record<string, unknown>;
  if (Buffer.byteLength(JSON.stringify(args)) > 16 * 1024) return { name: tool.name, arguments: { _omitted: '参数超过展示上限，已省略' }, truncated: true };
  return { name: tool.name, arguments: args, ...(truncated ? { truncated: true } : {}) };
}

/// 工具名必须已由目录校验；模块仍只允许服务器固定词表。
export function assistantToolLabel(
  name: string,
  planned: boolean,
  module?: string,
): string {
  if (name === 'ask_user') return '等待补充信息';
  if (name === 'save_memory') return '保存记忆';
  // 只采用已知模块，参数中的任意字符串不能变成摘要。
  const noun =
    module && Object.hasOwn(executionModules, module)
      ? executionModules[module]
      : undefined;
  if (planned) return noun ? `登记${noun}修改计划` : '登记修改计划';
  return Object.hasOwn(executionToolLabels, name)
    ? executionToolLabels[name]!
    : noun
      ? `查询${noun}`
      : '查询资料';
}

/// 在同一状态对象上更新步骤，防止后续业务状态保存覆盖摘要。
export function assistantRecordExecution(
  state: AssistantState,
  step: Omit<AssistantExecutionStep, 'startedAt' | 'finishedAt'>,
  now = new Date().toISOString(),
): void {
  // 稳定身份恢复时保留首次开始时间，不新增重复行。
  const previous = state.executionSteps?.find((entry) => entry.id === step.id);
  // 终态在同一次业务观察持久化时记录完成时间。
  const next: AssistantExecutionStep = {
    ...step,
    ...(!step.tool && previous?.tool ? { tool: previous.tool } : {}),
    ...(!step.reasoning && previous?.reasoning ? { reasoning: previous.reasoning } : {}),
    startedAt: previous?.startedAt ?? now,
    ...(step.status === 'running' ? {} : { finishedAt: now }),
  };
  state.executionSteps = previous
    ? state.executionSteps!.map((entry) =>
        entry.id === step.id ? next : entry,
      )
    : [...(state.executionSteps ?? []), next];
}

/// 通用查询详情只接受服务端固定计数句式，禁止自由工具正文进入公开事件。
function executionDetail(entry: AssistantExecutionStep): string | undefined {
  if (typeof entry.detail !== 'string') return undefined;
  if (['读取文件', '搜索文件'].includes(entry.label))
    return Array.from(entry.detail).filter((character) => character.charCodeAt(0) >= 32 && character.charCodeAt(0) !== 127).join('').slice(0, 200);
  if (entry.kind === 'tool' && (entry.detail === '工具结果超出交付上限，请缩小查询范围'
    || entry.label === '查询待办' && /^已读取(?:0|[1-9]\d{0,2})条，进度步骤已摘要(?:，仍有后续记录)?$/.test(entry.detail))) return entry.detail;
  if (entry.kind === 'model' && entry.detail === '已预留最终回答预算，停止继续查询') return entry.detail;
  return undefined;
}

/// 公开投影重建白名单字段，并将停止后的未结束步骤标为真实终态。
export function assistantExecutionSteps(
  run: ExecutionRun,
): AssistantExecutionStep[] {
  // 遗忘清理后的状态不能恢复旧执行摘要。
  const state =
    run.state && typeof run.state === 'object'
      ? (run.state as Partial<AssistantState>)
      : {};
  if (state.memoryInvalidated || !Array.isArray(state.executionSteps))
    return [];
  // 同一次运行中的重复身份只保留最后一次持久观察。
  const steps = new Map<string, AssistantExecutionStep>();
  // 整个执行链的思考展示同样有界，防止历史状态拼成超大SSE帧。
  let reasoningBudget = 64000;
  for (const entry of state.executionSteps.slice(0, 128)) {
    if (
      !entry ||
      typeof entry.id !== 'string' ||
      !entry.id.startsWith(`${run.id}:`) ||
      entry.id.length > 256 ||
      !['model', 'tool', 'commit'].includes(entry.kind) ||
      !executionLabels.has(entry.label) ||
      ![
        'running',
        'succeeded',
        'failed',
        'planned',
        'waiting',
        'cancelled',
      ].includes(entry.status) ||
      !Number.isFinite(Date.parse(entry.startedAt))
    )
      continue;
    // 取消覆盖未提交计划；失败只终结正在执行的步骤，既有成功保持事实。
    const stopped =
      ['running', 'waiting', 'planned'].includes(entry.status) &&
      run.status === 'cancelled'
        ? 'cancelled'
        : entry.status === 'running' && run.status === 'failed'
          ? 'failed'
          : entry.status === 'running' &&
              !['running', 'queued'].includes(run.status)
            ? 'waiting'
            : entry.status;
    // 仅模型步骤可拥有可读思考，不透传历史对象中的其他字段。
    const reasoning = entry.kind === 'model' ? assistantVisibleReasoning(entry.reasoning, Math.max(0, Math.min(16000, reasoningBudget))) : undefined;
    reasoningBudget -= Array.from(reasoning?.text ?? '').length;
    steps.set(entry.id, {
      id: entry.id,
      kind: entry.kind,
      label: entry.label,
      ...(entry.kind === 'tool' && assistantToolDetails(entry.tool) ? { tool: assistantToolDetails(entry.tool) } : {}),
      ...(reasoning ? { reasoning } : {}),
      ...(executionDetail(entry) ? { detail: executionDetail(entry) } : {}),
      status: stopped,
      startedAt: new Date(entry.startedAt).toISOString(),
      ...(stopped !== entry.status
        ? { finishedAt: run.updatedAt.toISOString() }
        : entry.finishedAt && Number.isFinite(Date.parse(entry.finishedAt))
          ? { finishedAt: new Date(entry.finishedAt).toISOString() }
          : {}),
    });
  }
  return [...steps.values()];
}

/// 已结算时间加当前执行段；暂停快照冻结在状态过渡时刻。
export function assistantLiveElapsedMs(
  run: ExecutionRun &
    Pick<AssistantRun, 'elapsedMs' | 'leaseOwner' | 'leaseUntil'>,
  now = Date.now(),
): number {
  // 无当前租约的历史状态只采用已结算用时。
  const state =
    run.state && typeof run.state === 'object'
      ? (run.state as Partial<AssistantState>)
      : {};
  // 无可靠开始时间的旧运行不猜测执行耗时。
  const started = Date.parse(state.segmentStartedAt ?? '');
  if (!run.leaseOwner || !run.leaseUntil || !Number.isFinite(started))
    return run.elapsedMs;
  // 过期租约和等待状态都不能随着读取继续增加。
  const end = Math.min(
    now,
    run.leaseUntil.getTime(),
    run.status === 'running' ? now : run.updatedAt.getTime(),
  );
  return run.elapsedMs + Math.max(0, end - started);
}
