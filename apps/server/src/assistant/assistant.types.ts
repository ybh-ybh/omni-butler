import { z } from 'zod';
import type { Prisma } from '../generated/prisma/client';

/// 未完成任务占据会话，不能通过新的发送绕过确认。
export const assistantActive = [
  'queued',
  'running',
  'waitingConfirmation',
  'waitingInput',
  'submissionUnknown',
];
/// 所有公开写入使用严格结构，身份只来自已认证设备。
export const assistantSettingsInput = z.strictObject({
  revision: z.number().int().nonnegative(),
  enabled: z.boolean(),
  profileId: z.uuid().nullable(),
  memoryReadEnabled: z.boolean(),
  memoryWriteEnabled: z.boolean(),
  timeZone: z.string().max(128).default('Asia/Shanghai'),
});
/// 客户端身份固定重试，不由模型产生。
export const assistantMessageInput = z.strictObject({
  clientMessageId: z.uuid(),
  content: z.string().trim().max(20000),
  attachmentIds: z.array(z.uuid()).max(5).refine((ids) => new Set(ids).size === ids.length, { message: '附件不可重复' }).default([]),
  timeZone: z.string().max(128).optional(),
  reference: z
    .strictObject({
      id: z.uuid(),
      module: z.enum([
        'quotes',
        'time',
        'todos',
        'inventory',
        'memberships',
        'events',
        'notes',
      ]),
    })
    .optional(),
  selection: z
    .strictObject({
      id: z.uuid(),
      module: z.enum([
        'quotes',
        'time',
        'todos',
        'inventory',
        'memberships',
        'events',
        'notes',
      ]),
    })
    .optional(),
}).refine((input) => input.content.length > 0 || input.attachmentIds.length > 0, { message: '请输入内容或添加附件' });
/// 确认绑定不可更改的预览及计划版本。
export const assistantDecisionInput = z.strictObject({
  version: z.number().int().positive(),
  decision: z.enum(['confirm', 'cancel']),
  previewHash: z.string().length(64),
});
/// 显式记忆只保存有限文本，不接受程序或执行授权。
export const assistantMemoryInput = z.strictObject({
  content: z.string().trim().min(1).max(2000),
  category: z.string().trim().min(1).max(40).default('preference'),
  enabled: z.boolean().default(true),
  expiresAt: z.iso.datetime({ offset: true }).nullable().optional(),
  revision: z.number().int().nonnegative().optional(),
});
/// 图循环的供应商输入，不在公开事件中返回。
export interface AssistantState {
  /// 固定公开摘要，不包含模型输入、工具参数或内部推理。
  executionSteps?: AssistantExecutionStep[];
  /// 当前工作进程执行段开始时间，等待用户时清除。
  segmentStartedAt?: string;
  /// 完整且已校验的供应商消息项。
  input: Record<string, unknown>[];
  /// 本任务累计的业务写意图。
  intents: { name: string; input: Record<string, unknown> }[];
  /// 上轮响应中等待处理的调用。
  calls: { callId: string; name: string; arguments: Record<string, unknown> }[];
  /// 累计工具调用预算。
  toolCount: number;
  /// 已知只读错误仅允许一次模型修正。
  readCorrectionUsed?: boolean;
  /// 已完成只读查询的有界事实索引，供压缩和最终有限回答使用。
  readProgress?: AssistantReadProgress[];
  /// 查询预算终止后只生成最终回答，不再发起业务工具。
  answerOnly?: boolean;
  /// 查询或模型预算终止原因，不与真实业务冲突混淆。
  readLimit?: 'ASSISTANT_TOOL_LIMIT' | 'ASSISTANT_MODEL_LIMIT';
  /// 来源入口因单次或累计二十条上限被截断，不代表业务查询是否完整。
  referencesTruncated?: boolean;
  /// 有序文件身份固定到任务，不包含原文件内容。
  attachmentIds?: string[];
  /// 受控图像引用出站时临时展开，不保存base64。
  attachmentImages?: { attachmentId: string; page?: number }[];
  /// 有界重试的公开摘要。
  recovery?: { attempt: number; retryAt: string; reason: string };
  /// 单独模型调用预算，避免无工具的空循环。
  modelCount: number;
  /// 流式回答稳定消息身份。
  messageId: string;
  /// 原始用户指令，仅用于授权范围判断。
  request: string;
  /// 生成文字在实际提交后才能作为成功结果展示。
  text: string;
  /// 已提交事实只用于结果展示，不作为新的授权。
  result?: unknown;
  /// 当前上下文依赖的记忆修订。
  memoryVersion: number;
  /// 用户明确选择的真实对象，仅作为待校验业务资料。
  selection?: {
    id: string;
    module:
      | 'quotes'
      | 'time'
      | 'todos'
      | 'inventory'
      | 'memberships'
      | 'events'
      | 'notes';
  };
  /// 既有结果卡片中的明确业务引用，真实目标仍由工具读取校验。
  reference?: {
    id: string;
    module:
      | 'quotes'
      | 'time'
      | 'todos'
      | 'inventory'
      | 'memberships'
      | 'events'
      | 'notes';
  };
  /// 任务最初要求在修订时保持可追溯。
  originalRequest?: string;
  /// 当前运行唯一的真实用户消息，不能按时间猜测记忆授权来源。
  userMessageId?: string;
  /// 本次运行固定的明确时区。
  timeZone?: string;
  /// 实际执行成功的动作身份，不依赖任务后来切换的当前计划。
  actionId?: string;
  /// 单条新增补偿绑定原实际动作。
  undoOf?: string;
  /// 原运行保存已创建的补偿运行，重复点击不重复撤销。
  undoRunId?: string;
  /// 已遗忘上下文不得通过重试重新授权。
  memoryInvalidated?: boolean;
  /// 候选已保存时不能将正文冲突描述为正式采用成功。
  conflict?: boolean;
}
/// 当前任务实际交付的待办页，只记录资料，不授予后续业务写权限。
export interface AssistantReadProgress {
  /// 首版仅记录已经完成的待办列表查询。
  tool: 'list_todos';
  /// 固定顺序的筛选条件，省略条件不猜测为任何默认过滤。
  filters: {
    /// 真实标题查询词，最多二百字。
    query?: string;
    /// 查询计划日期起点，包含当天。
    fromDay?: string;
    /// 查询计划日期终点，不包含当天。
    toDay?: string;
    /// 实际完成状态过滤。
    completed?: boolean;
    /// 固定零至三的重要紧急象限。
    priorityQuadrant?: number;
  };
  /// 工具实际接受的原始分页要求。
  requested: {
    /// 请求起始偏移。
    offset: number;
    /// 请求最多条数。
    limit: number;
  };
  /// 实际交付范围采用左闭右开区间。
  delivered: {
    /// 真实交付起点。
    offset: number;
    /// 真实交付末尾后一条位置。
    endOffset: number;
  };
  /// 实际返回条数，不从压缩后显示数量推断。
  returnedCount: number;
  /// 工具确认仍有后续页，不代表此任务覆盖所有待办。
  hasMore: boolean;
  /// 服务端原始分页游标，无后续页时为空。
  nextOffset: number | null;
  /// 真实待办身份与有限摘要，不含描述、步骤正文和同步字段。
  items: {
    /// 只接受合法真实 UUID，不接受名称充当身份。
    id: string;
    /// 引用只属于待办模块。
    module: 'todos';
    /// 标题保留有限完整 Unicode 字符，省略有单独标记。
    title: string;
    /// 标题被截短或凭据类内容被移除时明确标记。
    titleOmitted?: true;
    /// 实际重要紧急象限。
    priorityQuadrant?: number;
    /// 真实计划日期。
    scheduledDate?: string;
    /// 真实完成状态。
    isCompleted?: boolean;
    /// 真实直属父待办身份。
    parentId?: string | null;
    /// 实际步骤总数，不携带步骤正文。
    progressCount?: number;
    /// 实际已完成步骤数。
    progressCompletedCount?: number;
  }[];
  /// 摘要或引用因预算省略，不能按当前数组长度误认整页结果。
  itemsOmitted?: true;
}
/// 执行摘要只能描述服务器已观察到的阶段和结果。
export interface AssistantExecutionStep {
  /// 运行身份加模型轮次或工具调用身份，供重放去重。
  id: string;
  /// 模型、工具和真实提交分开记录。
  kind: 'model' | 'tool' | 'commit';
  /// 由服务器固定词表生成，不接受模型自由文本。
  label: string;
  /// 仅真实附件名和已读取范围，不接受模型自由说明。
  detail?: string;
  /// 模型明确公开的可读思考，与工具参数和答案正文独立保存。
  reasoning?: { text: string; truncated?: boolean };
  /// 仅向所属用户展示的实际工具输入，敏感字段与超长内容由服务端裁剪。
  tool?: {
    /// 已开始执行的函数名称。
    name: string;
    /// JSON参数不包含模型推理或工具输出。
    arguments: Record<string, unknown>;
    /// 超出展示上限时明确提示存在省略。
    truncated?: boolean;
  };
  /// 登记写意图使用 planned，不能冒充实际提交成功。
  status:
    | 'running'
    | 'succeeded'
    | 'failed'
    | 'planned'
    | 'waiting'
    | 'cancelled';
  /// 首次开始的服务器时间。
  startedAt: string;
  /// 当前阶段结束时间，等待状态同样停止本阶段计时。
  finishedAt?: string;
}
/// JSON序列化保证数据库回放与首次结果形状相同。
export function assistantJson(value: unknown): Prisma.InputJsonValue {
  return JSON.parse(JSON.stringify(value)) as Prisma.InputJsonValue;
}
