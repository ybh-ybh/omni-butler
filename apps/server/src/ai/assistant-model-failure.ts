import { AiProviderError } from './ai-provider';
import type { AssistantModelResult } from './assistant-model.types';

/// 只保存安全事实，禁止携带原始供应商正文、请求和凭据。
export interface AssistantModelFailureFacts {
  /// 未提交、明确拒绝和未知计费是不同恢复边界。
  submission: 'notSubmitted' | 'rejected' | 'unknown';
  /// 只有供应商或传输层给出确定证据才允许重试。
  retryable: boolean;
  /// 实际 HTTP 状态供本地分类，不推断计费状态。
  httpStatus?: number;
  /// 白名单头中的受限请求身份用于服务商排查。
  providerRequestId?: string;
  /// 合法 Retry-After 换算后的等待时间。
  retryAfterMs?: number;
  /// 终态明确报告的用量，缺失不推算为零。
  usage?: NonNullable<AssistantModelResult['usage']>;
}

/// 与原 AiProviderError 兼容，同时向运行器提供可持久化事实。
export class AssistantModelFailure extends AiProviderError {
  /// unknown 保持既有 uncertain 语义，不携带底层异常 cause。
  constructor(code: string, readonly facts: AssistantModelFailureFacts) {
    super(code, facts.submission === 'unknown');
  }
}

/// 旧错误保留错误码和 uncertain，但从不凭旧布尔值授予自动重试。
export function normalizeAssistantFailure(error: unknown): AssistantModelFailure {
  if (error instanceof AssistantModelFailure) return error;
  if (error instanceof AiProviderError) return new AssistantModelFailure(error.code, { submission: error.uncertain ? 'unknown' : 'rejected', retryable: false });
  return new AssistantModelFailure('AI_SUBMISSION_UNKNOWN', { submission: 'unknown', retryable: false });
}

/// 仅接受完整、有限且非负的供应商用量对象。
export function assistantReportedUsage(value: unknown): AssistantModelResult['usage'] {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  // 未知 JSON 字段先验证再投影，不回传供应商附加字段。
  const usage = value as Record<string, unknown>;
  if (![usage.input_tokens, usage.output_tokens, usage.total_tokens].every((token) => Number.isSafeInteger(token) && (token as number) >= 0)) return null;
  return { inputTokens: usage.input_tokens as number, outputTokens: usage.output_tokens as number, totalTokens: usage.total_tokens as number };
}

/// 只读取安全格式请求身份和等待头，拒绝数组、控制字符和超长文本。
export function assistantResponseMetadata(headers: Record<string, string | string[] | undefined>, now = Date.now()): Pick<AssistantModelFailureFacts, 'providerRequestId' | 'retryAfterMs'> {
  // 供应商头名集合固定，不能把认证或任意头误当诊断资料。
  const rawId = headers['x-request-id'] ?? headers['request-id'] ?? headers['x-deepseek-request-id'];
  // 格式限制避免把任意错误文本带入持久化和日志。
  const providerRequestId = typeof rawId === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/.test(rawId) ? rawId : undefined;
  // Retry-After 支持秒数或 HTTP 日期，超长输入直接忽略。
  const rawRetry = headers['retry-after'];
  // 无效值保持缺失，不能误作立即重试。
  const parsed = typeof rawRetry === 'string' && rawRetry.length <= 64 ? (/^\d+(?:\.\d+)?$/.test(rawRetry) ? Number(rawRetry) * 1000 : Date.parse(rawRetry) - now) : NaN;
  // 保留零等待语义，负数 HTTP 日期按零处理。
  const retryAfterMs = Number.isFinite(parsed) && parsed <= Number.MAX_SAFE_INTEGER ? Math.max(0, Math.ceil(parsed)) : undefined;
  return { ...(providerRequestId === undefined ? {} : { providerRequestId }), ...(retryAfterMs === undefined ? {} : { retryAfterMs }) };
}

/// HTTP 429 只有明确临时限流字段才可安全进入一次重试策略。
export function assistantTemporaryRateLimit(body: string): boolean {
  try {
    // 错误正文只在内存检查固定 code/type，绝不返回或记录原文。
    const envelope: unknown = JSON.parse(body);
    if (typeof envelope !== 'object' || envelope === null || Array.isArray(envelope)) return false;
    if ('usage' in envelope || 'output' in envelope || 'response' in envelope) return false;
    // 拒绝所有非标准错误结构，包括只给自然语言说明的供应商。
    const error: unknown = (envelope as Record<string, unknown>).error;
    if (typeof error !== 'object' || error === null || Array.isArray(error)) return false;
    // 未知字段值不能被另一个看似限流的字段掩盖。
    const fields = [(error as Record<string, unknown>).code, (error as Record<string, unknown>).type].filter((field) => field !== undefined && field !== null);
    return fields.length > 0 && fields.every((field) => field === 'rate_limit_exceeded' || field === 'rate_limit_error');
  } catch { return false; }
}

/// 只从标准错误code/type分类，不检查或保存供应商自然语言message。
export function assistantRejectionCode(value: unknown): string {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return 'AI_PROVIDER_REJECTED';
  // 同时支持HTTP错误信封与Responses失败对象的error字段。
  const nested: unknown = (value as Record<string, unknown>).error;
  // SSE error事件可直接携带code，仍只读取固定两个字段。
  const error = typeof nested === 'object' && nested !== null && !Array.isArray(nested) ? nested as Record<string, unknown> : value as Record<string, unknown>;
  // 限制字段长度，不把异常长字符串当作稳定错误身份。
  const fields = [error.code, error.type].filter((field): field is string => typeof field === 'string' && field.length <= 128);
  if (fields.some((field) => ['insufficient_quota', 'quota_exceeded', 'insufficient_balance', 'credit_balance_too_low'].includes(field))) return 'AI_QUOTA_EXHAUSTED';
  if (fields.some((field) => ['context_length_exceeded', 'context_window_exceeded', 'model_context_window_exceeded'].includes(field))) return 'AI_CONTEXT_TOO_LARGE';
  if (fields.some((field) => ['rate_limit_exceeded', 'rate_limit_error'].includes(field))) return 'AI_RATE_LIMITED';
  if (fields.some((field) => ['invalid_request_error', 'invalid_parameter', 'invalid_argument', 'unsupported_parameter', 'unsupported_value'].includes(field))) return 'AI_INVALID_REQUEST';
  return 'AI_PROVIDER_REJECTED';
}
