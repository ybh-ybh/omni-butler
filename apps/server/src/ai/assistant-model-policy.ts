import { AssistantModelFailure } from './assistant-model-failure';
import type { AssistantModelCompatibility } from './assistant-model.types';

export { AssistantModelFailure, normalizeAssistantFailure } from './assistant-model-failure';

/// 预算覆盖完整 JSON，而非仅图片原始大小。
export const ASSISTANT_MAX_REQUEST_BYTES = 20 * 1024 * 1024;
/// 单个持久化请求的所有安全重试共用一分钟。
export const ASSISTANT_REQUEST_BUDGET_MS = 60000;
/// 解码后的单图上限与附件服务共同防止图片放大请求。
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
/// 仅附件服务刚完成 hydrate 的对象可穿过图片输入边界。
const hydratedImages = new WeakSet<object>();

/// 旧配置不猜测图像能力，预算采用固定的保守值。
export function assistantCompatibility(value?: AssistantModelCompatibility): AssistantModelCompatibility {
  if (value === undefined) return { version: 1, imageInput: 'unknown', contextWindowTokens: 32768, maxOutputTokens: 8192, maxRequestBytes: ASSISTANT_MAX_REQUEST_BYTES };
  if (value === null || value.version !== 1 || !['unknown', 'supported', 'unsupported'].includes(value.imageInput) || !Number.isSafeInteger(value.contextWindowTokens) || value.contextWindowTokens < 1024 || value.contextWindowTokens > 2000000 || !Number.isSafeInteger(value.maxOutputTokens) || value.maxOutputTokens < 1 || value.maxOutputTokens > 32768 || value.maxOutputTokens >= value.contextWindowTokens || !Number.isSafeInteger(value.maxRequestBytes) || value.maxRequestBytes < 1024 || value.maxRequestBytes > ASSISTANT_MAX_REQUEST_BYTES) throw new AssistantModelFailure('AI_INVALID_COMPATIBILITY', { submission: 'notSubmitted', retryable: false });
  return { version: 1, imageInput: value.imageInput, contextWindowTokens: value.contextWindowTokens, maxOutputTokens: value.maxOutputTokens, maxRequestBytes: value.maxRequestBytes };
}

/// 附件服务验证归属并读取私有对象后，在内存创建唯一可信图片部分。
export function createAssistantImagePart(attachmentId: string, dataUrl: string): Record<string, unknown> {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(attachmentId) || typeof dataUrl !== 'string' || dataUrl.length > ASSISTANT_MAX_REQUEST_BYTES) throw new AssistantModelFailure('AI_INVALID_IMAGE_INPUT', { submission: 'notSubmitted', retryable: false });
  // 仅允许内联标准图片，禁止远程 URL、本地路径和供应商 file_id。
  const match = /^data:image\/(png|jpeg|webp|gif);base64,([A-Za-z0-9+/]+={0,2})$/.exec(dataUrl);
  if (!match) throw new AssistantModelFailure('AI_INVALID_IMAGE_INPUT', { submission: 'notSubmitted', retryable: false });
  // 校验规范 base64，避免不同解码器接受损坏输入。
  const bytes = Buffer.from(match[2]!, 'base64');
  // 图片已由附件服务完整验证，此处再检查容器魔数与声明一致。
  const validMagic = match[1] === 'png' ? bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) : match[1] === 'jpeg' ? bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255 : match[1] === 'gif' ? /^GIF8[79]a$/.test(bytes.subarray(0, 6).toString('ascii')) : bytes.subarray(0, 4).toString('ascii') === 'RIFF' && bytes.subarray(8, 12).toString('ascii') === 'WEBP';
  if (!validMagic || bytes.length > MAX_IMAGE_BYTES || bytes.toString('base64') !== match[2]) throw new AssistantModelFailure('AI_INVALID_IMAGE_INPUT', { submission: 'notSubmitted', retryable: false });
  // 冻结对象防止验证后被调用方替换为任意远程地址。
  const part = Object.freeze({ type: 'input_image', image_url: dataUrl, detail: 'auto' });
  hydratedImages.add(part);
  return part;
}

/// 输入图片只接受本进程 hydrate 品牌，序列化后必须重新核验归属并 hydrate。
export function assertAssistantImageInputs(input: Record<string, unknown>[], compatibility: AssistantModelCompatibility): boolean {
  // 当前路径检测循环，共享对象在不同位置仍按实际发送次数计数。
  const ancestors = new WeakSet<object>();
  // 每次模型调用最多五图，包括历史和本次附件。
  let images = 0;
  // 限制输入节点及嵌套深度，不接受异常巨大对象图。
  let nodes = 0;
  // 深度和节点数均受限后递归，避免展开大数组产生参数栈溢出。
  const visit = (value: unknown, depth: number): void => {
    if (typeof value !== 'object' || value === null) return;
    if (++nodes > 100000 || depth > 64 || ancestors.has(value)) throw new AssistantModelFailure('AI_INVALID_REQUEST', { submission: 'notSubmitted', retryable: false });
    ancestors.add(value);
    // 来源形状仍为未知对象，不因 TypeScript 类型而信任。
    const object = value as Record<string, unknown>;
    if (object.type === 'input_image') {
      if (++images > 5 || !hydratedImages.has(object)) throw new AssistantModelFailure('AI_INVALID_IMAGE_INPUT', { submission: 'notSubmitted', retryable: false });
      if (compatibility.imageInput !== 'supported') throw new AssistantModelFailure('AI_IMAGE_INPUT_UNSUPPORTED', { submission: 'notSubmitted', retryable: false });
    }
    // 数组与对象仅遍历其已有字段，不展开文本和 base64。
    for (const child of Object.values(value)) visit(child, depth + 1);
    ancestors.delete(value);
  };
  visit(input, 0);
  return images > 0;
}

/// 调度器得到决定后才负责持久化与等待，策略本身没有计时或网络副作用。
export function assistantRetryDecision(input: { failure: AssistantModelFailure; retriesUsed: number; elapsedMs: number; random?: number }): { retry: true; delayMs: number; remainingMs: number } | { retry: false; reason: string } {
  if (!Number.isSafeInteger(input.retriesUsed) || input.retriesUsed !== 0) return { retry: false, reason: 'retryLimit' };
  if (!Number.isFinite(input.elapsedMs) || input.elapsedMs < 0 || input.elapsedMs >= ASSISTANT_REQUEST_BUDGET_MS) return { retry: false, reason: 'deadline' };
  if (!input.failure.facts.retryable || input.failure.facts.submission === 'unknown') return { retry: false, reason: 'unsafe' };
  // 超过五秒的供应商等待不自动延长用户操作。
  const retryAfterMs = input.failure.facts.retryAfterMs ?? 0;
  if (!Number.isFinite(retryAfterMs) || retryAfterMs < 0 || retryAfterMs > 5000) return { retry: false, reason: 'retryAfter' };
  // 随机值由调用方提供以便审计及确定性测试，默认取中心值。
  const random = input.random ?? 0.5;
  if (!Number.isFinite(random) || random < 0 || random > 1) return { retry: false, reason: 'invalidRandom' };
  // Retry-After 是下限，抖动只作用于本地五百毫秒退避。
  const delayMs = Math.max(Math.round(400 + random * 200), retryAfterMs);
  // 剩余预算供下一次模型调用 timeoutMs 使用。
  const remainingMs = Math.floor(ASSISTANT_REQUEST_BUDGET_MS - input.elapsedMs - delayMs);
  return remainingMs > 0 ? { retry: true, delayMs, remainingMs } : { retry: false, reason: 'deadline' };
}
