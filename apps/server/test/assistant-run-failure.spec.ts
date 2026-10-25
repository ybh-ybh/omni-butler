import { ConflictException, UnauthorizedException } from '@nestjs/common';
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
});
