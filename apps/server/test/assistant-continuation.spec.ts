import { assistantContinuationState } from '../src/assistant/assistant-continuation';
import { AssistantContextService } from '../src/assistant/assistant-context.service';
import type { AssistantState } from '../src/assistant/assistant.types';
import type { PrismaService } from '../src/prisma/prisma.service';

describe('助手继续执行的上下文', () => {
  it('保留已读结果，关闭未完成调用且不覆盖或重复已有工具回执', () => {
    // The old turn contains both an observed result and an interrupted parallel call.
    const previous: AssistantState = {
      request: '查询资料',
      originalRequest: '查询资料',
      userMessageId: 'original-user',
      input: [
        { role: 'user', content: '查询资料' },
        {
          type: 'function_call',
          call_id: 'read',
          name: 'list_quotes',
          arguments: '{}',
        },
        {
          type: 'function_call',
          call_id: 'pending',
          name: 'list_todos',
          arguments: '{}',
        },
        {
          type: 'function_call_output',
          call_id: 'read',
          output: '{"items":[{"content":"已有资料"}]}',
        },
      ],
      calls: [{ callId: 'pending', name: 'list_todos', arguments: {} }],
      intents: [],
      text: '未完成回答',
      messageId: 'old-answer',
      modelCount: 3,
      toolCount: 8,
      memoryVersion: 0,
      readLimit: 'ASSISTANT_TOOL_LIMIT',
      answerOnly: true,
      continuationRunId: 'old-link',
      segmentStartedAt: new Date().toISOString(),
      executionSteps: [],
    };
    // Keep a separate baseline to verify the cancelled run remains untouched.
    const snapshot = structuredClone(previous);
    // Build the new attempt without a visible user-message insertion.
    const continued = assistantContinuationState(previous, 'interrupted-run');
    expect(previous).toEqual(snapshot);
    expect(continued.input.slice(0, 4)).toEqual(snapshot.input);
    expect(continued.input.at(-1)).toMatchObject({
      type: 'function_call_output',
      call_id: 'pending',
    });
    expect(JSON.parse(continued.input.at(-1)!.output as string)).toMatchObject({
      isError: true,
      code: 'ASSISTANT_INTERRUPTED',
    });
    expect(continued).toMatchObject({
      request: previous.request,
      originalRequest: previous.request,
      userMessageId: 'original-user',
      continuedFromRunId: 'interrupted-run',
      calls: [],
      toolCount: 0,
      modelCount: 0,
      text: '',
    });
    expect(continued.continuationRunId).toBeUndefined();
    expect(continued.readLimit).toBeUndefined();
    expect(continued.answerOnly).toBeUndefined();
    expect(continued.executionSteps).toBeUndefined();
    // The real context validator must accept the repaired call/output pairing.
    const contexts = new AssistantContextService({} as PrismaService);
    expect(contexts.compact(continued.input, 16000, continued.request)).toEqual(
      continued.input,
    );
    // Repeated continuation must not add another output for the same completed call.
    expect(assistantContinuationState(continued, 'another-run').input).toEqual(
      continued.input,
    );
  });
});
