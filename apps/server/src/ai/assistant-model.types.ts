/// 助手任务只持久保存密文及固定版本，不向客户端返回此类型。
export interface AssistantProfileSnapshot {
  /// 原配置身份仍用于每次出站前确认归属及撤回。
  profileId: string;
  /// 开始任务时固定的配置修订。
  profileRevision: number;
  /// 供应商类型只影响协议兼容处理。
  provider: string;
  /// 固定后的公网服务基址。
  baseUrl: string;
  /// 本轮使用的模型名称。
  model: string;
  /// 独立持久密钥加密后的凭据。
  encryptedApiKey: string;
}

/// 只接受普通 Function Calling，不开放远程工具、代码或供应商内建工具。
export interface AssistantFunctionTool {
  /// Responses 使用扁平函数工具定义。
  type: 'function';
  /// 名称须与后端工具目录一致。
  name: string;
  /// 必要而简短的业务说明。
  description: string;
  /// 现有工具目录生成的参数 JSON Schema。
  parameters: Record<string, unknown>;
  /// 关闭默认严格模式，保留省略字段的业务语义。
  strict?: false;
}

/// 单次 Responses 请求，后端图负责循环、持久化及业务授权。
export interface AssistantModelRequest {
  /// 服务端指令与资料分开传入。
  instructions: string;
  /// 历史消息、供应商输出项与函数结果组成的显式上下文。
  input: Record<string, unknown>[];
  /// 本轮允许模型提出的函数调用。
  tools: AssistantFunctionTool[];
  /// 固定测试可强制调用无业务副作用函数。
  toolChoice?: 'auto' | 'none' | { type: 'function'; name: string };
  /// 输出预算包含供应商内部思考和工具参数。
  maxOutputTokens?: number;
  /// 停止及服务端执行时限共用取消信号。
  signal?: AbortSignal;
  /// 仅展示可见助手正文，绝不传递 reasoning 或工具参数。
  onDelta?: (text: string) => void | Promise<void>;
}

/// 仅在完整成功终态后返回可提交给业务校验的调用。
export interface AssistantFunctionCall {
  /// 供应商输出项身份，用于完整回传上下文。
  id: string;
  /// 关联函数结果的协议身份。
  callId: string;
  /// 已确认位于本轮允许目录中的工具名称。
  name: string;
  /// 完整 JSON 对象，仍须经过真实业务工具 schema 校验。
  arguments: Record<string, unknown>;
}

/// 可持久保存的终态结果，output 仅作为模型后续上下文。
export interface AssistantModelResult {
  /// 服务商响应身份，不能当成业务幂等身份。
  responseId: string;
  /// 已验证完整的助手可见文本。
  text: string;
  /// 未完成流不会返回部分函数调用。
  functionCalls: AssistantFunctionCall[];
  /// 包含不透明推理项，仅供下一轮模型协议续接。
  output: Record<string, unknown>[];
  /// 供应商实际报告的用量，缺失时明确为 null。
  usage: { inputTokens: number; outputTokens: number; totalTokens: number } | null;
}
