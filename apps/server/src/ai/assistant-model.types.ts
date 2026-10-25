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
  /// 本任务固定的思考模式，旧快照缺失时保持关闭。
  thinkingEnabled?: boolean;
  /// 独立持久密钥加密后的凭据。
  encryptedApiKey: string;
  /// 运行开始时固定的 Responses 能力及预算，旧快照采用保守默认值。
  compatibility?: AssistantModelCompatibility;
}

/// 能力画像只描述 Responses，不允许切换协议或供应商。
export interface AssistantModelCompatibility {
  /// 画像结构版本，未知版本必须拒绝。
  version: 1;
  /// 新快照由配置多模态开关决定，旧快照缺少声明时仍不推断支持。
  imageInput: 'unknown' | 'supported' | 'unsupported';
  /// 上下文预算由运行器在组装历史时使用。
  contextWindowTokens: number;
  /// 单次输出上限包含推理和工具参数。
  maxOutputTokens: number;
  /// 完整 JSON 请求字节预算包含图片 base64 开销。
  maxRequestBytes: number;
}

/// 固定连接测试得到的能力事实，不表示真实业务效果已验。
export interface AssistantModelCapabilities {
  /// 能力格式独立版本，方便旧配置保守恢复。
  version: 1;
  /// 普通文本流已由实际增量验证。
  streaming: true;
  /// 无副作用函数两轮续接已验证。
  functionCalling: true;
  /// 只回传配置的多模态声明，连接测试不授予图像能力。
  imageInput: 'unknown' | 'supported' | 'unsupported';
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
  /// 模型明确公开的思考或摘要累计快照，与回答正文和工具参数分开交付。
  onReasoning?: (reasoning: AssistantVisibleReasoning) => void | Promise<void>;
  /// 调度器传入本次允许的剩余时间，不能超过单次总预算。
  timeoutMs?: number;
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
  /// 仅可读思考的有界展示副本，完整协议output仍保持原样。
  reasoning?: AssistantVisibleReasoning;
  /// 未完成流不会返回部分函数调用。
  functionCalls: AssistantFunctionCall[];
  /// 包含不透明推理项，仅供下一轮模型协议续接。
  output: Record<string, unknown>[];
  /// 供应商实际报告的用量，缺失时明确为 null。
  usage: { inputTokens: number; outputTokens: number; totalTokens: number } | null;
}

/// 供应商明确公开的可读思考，不包含加密推理或内部协议数据。
export interface AssistantVisibleReasoning {
  /// 原返回文字，前端不将它混入正式回答。
  text: string;
  /// 达到展示上限时明确标记省略。
  truncated?: boolean;
}
