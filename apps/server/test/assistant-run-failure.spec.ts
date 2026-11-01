import { ConflictException, UnauthorizedException } from '@nestjs/common';
import { AiProviderError } from '../src/ai/ai-errors';
import { AssistantRunFailure, assistantRunFailure } from '../src/assistant/assistant-run-failure';

describe('助手运行失败分类', () => {
  it.each(['ASSISTANT_TOOL_LIMIT', 'ASSISTANT_MODEL_LIMIT', 'ASSISTANT_EXECUTION_TIMEOUT'] as const)('本地%s不冒充数据发生变化', (code) => {
    // 固定运行异常不携带业务正文。
    const result = assistantRunFailure(new AssistantRunFailure(code));
    expect(result).toMatchObject({ code, unknown: false });
    expect(result.message).not.toContain('数据已发生变化');
  });

  it('只有明确的实际数据冲突使用数据变化提示', () => {
    expect(assistantRunFailure(new AssistantRunFailure('ASSISTANT_DATA_CONFLICT'))).toMatchObject({ code: 'ASSISTANT_DATA_CONFLICT', message: '数据已发生变化，请核对后重新生成方案' });
    expect(assistantRunFailure(new ConflictException('private')).code).toBe('ASSISTANT_STATE_INVALID');
    expect(assistantRunFailure(new ConflictException({ code: 'BUSINESS_OPERATION_CONFLICT', message: 'private' })).message).toContain('操作身份');
    expect(assistantRunFailure(new ConflictException({ code: 'TODO_STRUCTURE_CONFLICT', message: 'private' })).message).toBe('数据已发生变化，请核对后重新生成方案');
  });

  it('未知提交与撤权继续保留安全边界，私有异常不回显', () => {
    expect(assistantRunFailure(Object.assign(new Error('private'), { code: 'AI_SUBMISSION_UNKNOWN', uncertain: true }))).toMatchObject({ unknown: true });
    expect(assistantRunFailure(new UnauthorizedException('private')).message).toContain('授权');
    expect(JSON.stringify(assistantRunFailure(Object.assign(new Error('private'), { code: 'private-secret' })))).not.toContain('private');
  });

  it.each([
    ['AI_DNS_FAILED', 'DNS 配置'],
    ['AI_CONNECTION_FAILED', '出口网络'],
    ['AI_TLS_FAILED', 'TLS 连接失败'],
    ['AI_PRIVATE_URL', '不允许访问的网络'],
  ])('网络错误%s显示本地原因及安全诊断编号', (code, message) => {
    // Only the trusted provider class may attach a public diagnostic UUID.
    const traceId = '12345678-1234-4234-9234-123456789abc';
    // Arbitrary properties remain private even on a trusted error instance.
    const failure = Object.assign(new AiProviderError(code), { traceId, secret: 'synthetic-private-value' });
    // The client receives a bounded local message rather than the error object.
    const result = assistantRunFailure(failure);
    expect(result).toMatchObject({ code, unknown: false, message: expect.stringContaining(message) });
    expect(result.message).toContain(`诊断编号：${traceId}`);
    expect(JSON.stringify(result)).not.toContain('synthetic-private-value');
  });

  it('未知提交即使附带诊断编号也继续要求手动核实', () => {
    // Correlation does not grant permission to retry a possibly paid request.
    const failure = Object.assign(new AiProviderError('AI_SUBMISSION_UNKNOWN', true), { traceId: '12345678-1234-4234-9234-123456789abc' });
    expect(assistantRunFailure(failure)).toMatchObject({ unknown: true, message: expect.stringContaining('结果不确定，请核实后手动重试') });
  });

  it.each(['error', 'object', 'invalid-provider-id'] as const)('拒绝%s伪造或含敏感内容的诊断编号', (kind) => {
    // A valid UUID is still untrusted when it is attached to a plain Error or object.
    const traceId = '12345678-1234-4234-9234-123456789abc';
    // All source strings are synthetic and must be absent from public output.
    const failure = kind === 'error'
      ? Object.assign(new Error('synthetic-secret'), { code: 'AI_DNS_FAILED', traceId })
      : kind === 'object'
        ? { code: 'AI_DNS_FAILED', traceId, secret: 'synthetic-secret' }
        : Object.assign(new AiProviderError('AI_DNS_FAILED'), { traceId: `${traceId}\nsynthetic-secret` });
    // Formatting validation and trusted provenance are both required.
    const result = assistantRunFailure(failure);
    expect(result.message).not.toContain('诊断编号');
    expect(JSON.stringify(result)).not.toContain('synthetic-secret');
    expect(JSON.stringify(result)).not.toContain(traceId);
  });
});
