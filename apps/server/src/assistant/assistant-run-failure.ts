import { ConflictException, HttpException, UnauthorizedException } from '@nestjs/common';

/// 运行器的本地限制与业务数据冲突使用互不混淆的错误身份。
export type AssistantRunFailureCode =
  | 'ASSISTANT_TOOL_LIMIT'
  | 'ASSISTANT_MODEL_LIMIT'
  | 'ASSISTANT_EXECUTION_TIMEOUT'
  | 'ASSISTANT_DATA_CONFLICT';

/// 固定文字只描述服务端事实，不回显异常正文或工具内容。
const failureMessages: Record<string, string> = {
  ASSISTANT_TOOL_LIMIT: '查询达到本轮工具调用上限，已保留读取结果，请缩小范围后继续',
  ASSISTANT_MODEL_LIMIT: '本轮模型调用次数已用尽，已保留读取结果，请手动继续',
  ASSISTANT_EXECUTION_TIMEOUT: '本轮执行时间已达上限，已保留读取结果，请缩小范围后继续',
  ASSISTANT_DATA_CONFLICT: '数据已发生变化，请核对后重新生成方案',
  ASSISTANT_STATE_INVALID: '当前任务状态或操作条件已失效，请核对后重新发起',
  BUSINESS_OPERATION_CONFLICT: '同一操作身份对应的内容不一致，请核对后重新发起',
  NOTE_BASE_MISSING: '笔记编辑基线已不存在，请重新读取后生成方案',
  TIME_INTERVAL_CONFLICT: '时间范围与已有记录冲突，请核对时间范围',
  TODO_STRUCTURE_CONFLICT: '数据已发生变化，请核对后重新生成方案',
  AI_AUTH_FAILED: '模型密钥无效或缺少权限，请检查配置',
  AI_RATE_LIMITED: '模型服务暂时限流，请稍后手动重试',
  AI_QUOTA_EXHAUSTED: '模型服务额度不足，请检查余额或配额',
  AI_CONTEXT_TOO_LARGE: '附件或对话超出模型容量，请缩小读取范围',
  AI_OUTPUT_TRUNCATED: '模型输出达到上限，已保留部分回答，请缩小任务后继续',
  AI_IMAGE_INPUT_UNSUPPORTED: '当前模型无法读取图片，请检查多模态开关和模型配置',
  AI_RETRY_BUDGET_EXHAUSTED: '本次安全恢复预算已用尽，请稍后手动继续',
};

/// 明确的本地失败不会被误解为供应商已经受理但响应未知。
export class AssistantRunFailure extends Error {
  /// 构造参数只接受固定错误码。
  constructor(readonly code: AssistantRunFailureCode) {
    super(failureMessages[code]);
  }
}

/// 提取结构化错误码；HTTP 409 本身不能证明业务数据发生变化。
export function assistantRunFailure(error: unknown): { code: string; message: string; unknown: boolean } {
  // HTTP异常通过响应对象承载业务错误码，不依赖私有message文字匹配。
  const response = error instanceof HttpException ? error.getResponse() : undefined;
  // 供应商异常和结构化业务异常共用固定命名空间。
  const candidate = error && typeof error === 'object' && 'code' in error
    ? error.code
    : response && typeof response === 'object' && 'code' in response
      ? response.code
      : undefined;
  // 不接受任意异常正文或未规范化的底层错误码进入事件。
  const code = typeof candidate === 'string' && /^(?:AI|ASSISTANT|BUSINESS|NOTE|TIME|TODO)_[A-Z0-9_]{1,64}$/.test(candidate)
    ? candidate
    : error instanceof ConflictException ? 'ASSISTANT_STATE_INVALID' : 'ASSISTANT_FAILED';
  // 未知出站继续保留显式重试边界，不能进入自动回答恢复。
  const unknown = code === 'AI_SUBMISSION_UNKNOWN' || (error instanceof Error && 'uncertain' in error && error.uncertain === true);
  return {
    code,
    unknown,
    message: unknown ? '模型请求结果不确定，请核实后手动重试'
      : error instanceof UnauthorizedException ? '设备授权或助手设置已失效'
        : failureMessages[code] ?? '助手执行未完成，可查看已保存结果后重试',
  };
}
