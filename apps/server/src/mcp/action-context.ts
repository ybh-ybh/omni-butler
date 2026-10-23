import type { AuthUser } from '../auth/auth.types';
import type { McpAction, Prisma } from '../generated/prisma/client';
import type { McpModule } from './mcp-catalog';

/// 仅服务端构造的助手运行身份，不从工具参数或客户端正文读取。
export interface AssistantActionContext {
  /// 来源决定动作及编辑凭据的独立作用域。
  source: 'assistant';
  /// 跨恢复稳定的用户任务身份。
  taskId: string;
  /// 当前图运行身份，实际执行资格由提交门禁复核。
  runId: string;
  /// 已认证设备身份，不创建隐藏 MCP 连接。
  actor: AuthUser;
  /// 本次任务固定的明确业务时区。
  timeZone: string;
}

/// MCP 字符串身份继续保持既有服务签名。
export type ActionContext = string | AssistantActionContext;

/// 已验证身份只用于内部执行，不返回密钥或授予客户端自行声明来源。
export interface ActionScope {
  /// 来源用于数据库和编辑凭据隔离。
  source: 'mcp' | 'assistant';
  /// MCP 使用连接身份，助手使用任务身份。
  sourceId: string;
  /// 内部上下文在每次读写时重新验证。
  context: ActionContext;
  /// 助手动作不绑定 MCP 连接。
  connectionId: string | null;
  /// 真实业务归属。
  userId: string;
  /// 当前有效设备或 MCP 内部会话。
  sessionId: string;
  /// 来源授权的读取范围。
  readModules: string[];
  /// 来源授权的写入范围。
  writeModules: string[];
  /// 日期解释使用固定时区。
  timeZone: string | null;
  /// 动作不能晚于当前身份有效期。
  expiresAt: Date | null;
}

/// 助手提交必须在共享 owner 事务内复核计划、租约与设置。
export type AssistantCommitGuard = (
  transaction: Prisma.TransactionClient,
  action: McpAction,
) => Promise<void>;

/// 共享工具描述保持业务元数据单一来源，不暴露管理与提交工具。
export interface ActionToolDescription {
  /// 稳定工具名。
  name: string;
  /// 简短业务说明。
  description: string;
  /// 与实际校验一致的 JSON Schema。
  inputSchema: Record<string, unknown>;
  /// 是否登记写入意图。
  write: boolean;
  /// 跨模块查询没有单一模块。
  module?: McpModule;
}
