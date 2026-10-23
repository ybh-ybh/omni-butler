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
  content: z.string().trim().min(1).max(20000),
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
});
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
  /// 完整且已校验的供应商消息项。
  input: Record<string, unknown>[];
  /// 本任务累计的业务写意图。
  intents: { name: string; input: Record<string, unknown> }[];
  /// 上轮响应中等待处理的调用。
  calls: { callId: string; name: string; arguments: Record<string, unknown> }[];
  /// 累计工具调用预算。
  toolCount: number;
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
/// JSON序列化保证数据库回放与首次结果形状相同。
export function assistantJson(value: unknown): Prisma.InputJsonValue {
  return JSON.parse(JSON.stringify(value)) as Prisma.InputJsonValue;
}
