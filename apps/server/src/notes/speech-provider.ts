/// 与笔记存储、任务生命周期解耦的文件识别边界。
export abstract class SpeechRecognitionProvider {
  /// 服务商标识，与任务一起持久保存。
  abstract readonly name: string;
  /// 是否配置了可用凭证。
  abstract configured(): boolean;
  /// 创建远端任务；本方法绝不自动重试有计费副作用的请求。
  abstract submit(input: { model: string; audioUrl?: string; bytes?: Buffer }): Promise<string>;
  /// 查询已存在任务，幂等且不会重复提交音频。
  abstract poll(taskId: string): Promise<SpeechPollResult>;
}

/// 统一后的服务商状态。
export interface SpeechPollResult {
  /// 等待中、成功或失败。
  status: 'processing' | 'succeeded' | 'failed';
  /// 保留原转写结果，正文是否采用由客户端决定。
  transcript?: string;
  /// 去除敏感正文后的错误编码。
  errorCode?: string;
}

/// 明确拒绝与响应丢失必须分开，后者不能自动再收费。
export class SpeechProviderError extends Error {
  /// 只保存服务商错误码，不保存含凭证或音频的请求。
  constructor(public readonly code: string, public readonly submissionUncertain = false) { super(code); }
}
