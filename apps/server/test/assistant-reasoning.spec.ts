import { assistantResponseReasoning, assistantVisibleReasoning, AssistantReasoningBuffer } from '../src/ai/assistant-reasoning';
import { assistantExecutionSteps, assistantRecordExecution } from '../src/assistant/assistant-execution';
import type { AssistantState } from '../src/assistant/assistant.types';

/// 协议公开思考的提取与展示边界，不调用任何真实供应商。
describe('公开思考与答案、工具和不透明协议分离', () => {
  it('只读取公开摘要或reasoning_text，密文及任意伪装字段不展示', () => {
    expect(assistantResponseReasoning([
      { type: 'reasoning', encrypted_content: 'private-cipher', content: [{ type: 'reasoning_text', text: '未选中的全文' }], summary: [{ type: 'summary_text', text: '公开摘要' }] },
      { type: 'reasoning', content: [{ type: 'reasoning_text', text: '可读思考' }] },
      { type: 'message', content: [{ type: 'reasoning_text', text: '非思考项' }] },
      { type: 'reasoning', encrypted_content: 'private-cipher', text: '非协议字段', summary: [{ type: 'unknown', text: '非公开类型' }] },
    ])).toEqual({ text: '公开摘要\n\n可读思考' });
    expect(assistantResponseReasoning([{ type: 'reasoning', encrypted_content: 'private-cipher' }])).toBeUndefined();
  });

  it('按输出项合并增量，摘要替代同项全文而不是重复拼接', () => {
    // 状态仅保存可读通道，不持有供应商对象。
    const buffer = new AssistantReasoningBuffer();
    buffer.append({ type: 'response.reasoning_text.delta', item_id: 'r1', delta: '全文' });
    buffer.append({ type: 'response.reasoning_summary_text.delta', item_id: 'r1', delta: '摘要' });
    buffer.append({ type: 'response.reasoning_summary_text.delta', item_id: 'r1', delta: '完成' });
    buffer.append({ type: 'response.reasoning_text.delta', item_id: 'r2', delta: '另一段' });
    expect(buffer.snapshot()).toEqual({ text: '摘要完成\n\n另一段' });
  });

  it('截断保持Unicode码点完整，并明确标记展示省略', () => {
    expect(assistantVisibleReasoning({ text: '😀\u0000中文😀', encrypted_content: 'private' }, 3)).toEqual({ text: '😀中文', truncated: true });
    expect(assistantVisibleReasoning({ text: '\ud800' })).toEqual({ text: '\ufffd' });
    expect(assistantVisibleReasoning({ text: '', truncated: true }, 0)).toEqual({ text: '', truncated: true });
  });

  it('执行步骤完成时保留已交付思考，公开投影只含文字且遗忘状态不恢复', () => {
    // 仅设置本用例要验证的状态字段。
    const state = { executionSteps: [] } as unknown as AssistantState;
    assistantRecordExecution(state, { id: 'run:model:1', kind: 'model', label: '分析任务', status: 'running', reasoning: { text: '公开的思考' } }, '2026-10-24T00:00:00Z');
    assistantRecordExecution(state, { id: 'run:model:1', kind: 'model', label: '分析任务', status: 'succeeded' }, '2026-10-24T00:00:01Z');
    // 原始状态可能携带额外协议字段，但公开响应必须重建白名单。
    Object.assign(state.executionSteps![0]!.reasoning!, { encrypted_content: 'private-cipher' });
    expect(assistantExecutionSteps({ id: 'run', status: 'succeeded', state, updatedAt: new Date('2026-10-24T00:00:01Z') })[0]?.reasoning).toEqual({ text: '公开的思考' });
    state.memoryInvalidated = true;
    expect(assistantExecutionSteps({ id: 'run', status: 'succeeded', state, updatedAt: new Date() })).toEqual([]);
  });

  it('整条执行链以Unicode码点共享预算，超过上限的轮次保留省略标记', () => {
    // 五轮实际思考超过整链预算，不能因emoji占两个UTF16单元而提前省略。
    const state = { executionSteps: [] } as unknown as AssistantState;
    for (const round of [1, 2, 3, 4, 5]) {
      assistantRecordExecution(state, { id: `run:model:${round}`, kind: 'model', label: '分析任务', status: 'succeeded', reasoning: { text: '😀'.repeat(16000) } }, '2026-10-24T00:00:00Z');
    }
    // 整链预算只裁展示副本，最后一轮仍可识别为存在思考且已省略。
    const steps = assistantExecutionSteps({ id: 'run', status: 'succeeded', state, updatedAt: new Date() });
    expect(steps.slice(0, 4).map((step) => Array.from(step.reasoning!.text).length)).toEqual([16000, 16000, 16000, 16000]);
    expect(steps[4]?.reasoning).toEqual({ text: '', truncated: true });
  });
});
