import { AiProviderError } from '../src/ai/ai-provider';
import { AssistantModelFailure, assistantReportedUsage, assistantResponseMetadata, assistantTemporaryRateLimit, normalizeAssistantFailure } from '../src/ai/assistant-model-failure';
import { ASSISTANT_MAX_REQUEST_BYTES, assistantCompatibility, assistantRetryDecision, assertAssistantImageInputs, createAssistantImagePart } from '../src/ai/assistant-model-policy';

describe('助手安全重试纯策略', () => {
  /// 明确临时拒绝不会声称请求已执行，也不自行发送网络请求。
  const failure = new AssistantModelFailure('AI_RATE_LIMITED', { submission: 'rejected', retryable: true });

  it('只允许一次，抖动范围为400至600毫秒且扣除总预算', () => {
    expect(assistantRetryDecision({ failure, retriesUsed: 0, elapsedMs: 1000, random: 0 })).toEqual({ retry: true, delayMs: 400, remainingMs: 58600 });
    expect(assistantRetryDecision({ failure, retriesUsed: 0, elapsedMs: 1000, random: 1 })).toEqual({ retry: true, delayMs: 600, remainingMs: 58400 });
    expect(assistantRetryDecision({ failure, retriesUsed: 1, elapsedMs: 0 })).toEqual({ retry: false, reason: 'retryLimit' });
    expect(assistantRetryDecision({ failure, retriesUsed: 0, elapsedMs: 59500 })).toEqual({ retry: false, reason: 'deadline' });
  });

  it('Retry-After是下限，超过五秒和不足总预算都不自动延长', () => {
    // 服务商建议两秒时覆盖本地五百毫秒，而不相加重复等待。
    const delayed = new AssistantModelFailure('AI_RATE_LIMITED', { ...failure.facts, retryAfterMs: 2000 });
    expect(assistantRetryDecision({ failure: delayed, retriesUsed: 0, elapsedMs: 1000 })).toEqual({ retry: true, delayMs: 2000, remainingMs: 57000 });
    expect(assistantRetryDecision({ failure: new AssistantModelFailure('AI_RATE_LIMITED', { ...failure.facts, retryAfterMs: 5001 }), retriesUsed: 0, elapsedMs: 0 })).toEqual({ retry: false, reason: 'retryAfter' });
    expect(assistantRetryDecision({ failure: delayed, retriesUsed: 0, elapsedMs: 59000 })).toEqual({ retry: false, reason: 'deadline' });
  });

  it('未知提交、额度不足、旧错误和非模型异常均不获得重试权限', () => {
    // 即使误带 retryable，unknown 仍由策略独立阻止。
    const unknown = new AssistantModelFailure('AI_SUBMISSION_UNKNOWN', { submission: 'unknown', retryable: true });
    expect(assistantRetryDecision({ failure: unknown, retriesUsed: 0, elapsedMs: 0 })).toEqual({ retry: false, reason: 'unsafe' });
    expect(normalizeAssistantFailure(new AiProviderError('AI_RATE_LIMITED')).facts).toEqual({ submission: 'rejected', retryable: false });
    expect(normalizeAssistantFailure(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)).uncertain).toBe(true);
    expect(normalizeAssistantFailure(new Error('含敏感正文')).message).toBe('AI_SUBMISSION_UNKNOWN');
    expect(normalizeAssistantFailure(failure)).toBe(failure);
  });

  it('只有完整标准限流字段可识别，quota和未知字段不能被type掩盖', () => {
    expect(assistantTemporaryRateLimit('{"error":{"code":"rate_limit_exceeded","type":"rate_limit_error"}}')).toBe(true);
    expect(assistantTemporaryRateLimit('{"error":{"code":"insufficient_quota","type":"rate_limit_error"}}')).toBe(false);
    expect(assistantTemporaryRateLimit('{"error":{"message":"rate limit"}}')).toBe(false);
    expect(assistantTemporaryRateLimit('{"error":')).toBe(false);
  });

  it('请求ID和等待头仅输出白名单字段，用量缺失不推为零', () => {
    expect(assistantResponseMetadata({ 'x-request-id': 'req-123', 'retry-after': '0.75', authorization: 'secret' }, 0)).toEqual({ providerRequestId: 'req-123', retryAfterMs: 750 });
    expect(assistantResponseMetadata({ 'x-request-id': 'bad\nheader', 'retry-after': 'invalid' })).toEqual({});
    expect(assistantResponseMetadata({ 'retry-after': 'Thu, 01 Jan 1970 00:00:02 GMT' }, 0)).toEqual({ retryAfterMs: 2000 });
    expect(assistantReportedUsage({ input_tokens: 3, output_tokens: 2, total_tokens: 5, detail: 'secret' })).toEqual({ inputTokens: 3, outputTokens: 2, totalTokens: 5 });
    expect(assistantReportedUsage({ input_tokens: 3, output_tokens: -1, total_tokens: 2 })).toBeNull();
    expect(assistantReportedUsage(undefined)).toBeNull();
  });
});

describe('Responses能力与可信图片输入', () => {
  /// 固定合成 PNG 不含用户资料，所有测试均离线完成。
  const dataUrl = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/b6cAAAAASUVORK5CYII=';

  it('旧画像默认未知图片，预算严格限制完整请求', () => {
    expect(assistantCompatibility()).toEqual({ version: 1, imageInput: 'unknown', contextWindowTokens: 32768, maxOutputTokens: 8192, maxRequestBytes: 20 * 1024 * 1024 });
    expect(() => assistantCompatibility({ ...assistantCompatibility(), maxRequestBytes: ASSISTANT_MAX_REQUEST_BYTES + 1 })).toThrow('AI_INVALID_COMPATIBILITY');
    expect(() => assistantCompatibility({ ...assistantCompatibility(), maxOutputTokens: 32768 })).toThrow('AI_INVALID_COMPATIBILITY');
  });

  it('仅品牌对象被接受，序列化回放必须重新hydrate', () => {
    // 能力支持也不授予任意 data URL 发送权限。
    const compatibility = { ...assistantCompatibility(), imageInput: 'supported' as const };
    // 内部附件身份仅用于创建边界，不进入供应商JSON。
    const image = createAssistantImagePart('attachment-test', dataUrl);
    expect(assertAssistantImageInputs([{ role: 'user', content: [image] }], compatibility)).toBe(true);
    expect(assertAssistantImageInputs([{ role: 'user', content: '只发送文字' }], compatibility)).toBe(false);
    expect(Object.isFrozen(image)).toBe(true);
    expect(JSON.stringify(image)).not.toContain('attachment-test');
    expect(() => assertAssistantImageInputs([{ role: 'user', content: [JSON.parse(JSON.stringify(image))] }], compatibility)).toThrow('AI_INVALID_IMAGE_INPUT');
    expect(() => assertAssistantImageInputs([{ role: 'user', content: [image] }], assistantCompatibility())).toThrow('AI_IMAGE_INPUT_UNSUPPORTED');
  });

  it('单图两MiB、最多五图，重复同一品牌对象也按真实发送次数计数', () => {
    // 合成大PNG只用于预算验证，魔数后无需真实渲染。
    const bytes = Buffer.alloc(2 * 1024 * 1024 + 1);
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes);
    expect(() => createAssistantImagePart('oversized', `data:image/png;base64,${bytes.toString('base64')}`)).toThrow('AI_INVALID_IMAGE_INPUT');
    // 同一图片出现在六个位置必须视作六图，不能借WeakSet去重绕过。
    const image = createAssistantImagePart('shared-image', dataUrl);
    expect(() => assertAssistantImageInputs([{ content: [image, image, image, image, image, image] }], { ...assistantCompatibility(), imageInput: 'supported' })).toThrow('AI_INVALID_IMAGE_INPUT');
    expect(() => createAssistantImagePart('external', 'https://example.test/image.png')).toThrow('AI_INVALID_IMAGE_INPUT');
  });
});
