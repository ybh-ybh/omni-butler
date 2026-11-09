import { randomUUID } from 'node:crypto';
import { assistantReadProgress } from './assistant-read-progress';
import type { AssistantState } from './assistant.types';

// Resume control stays separate from the original user request and chat messages.
export const assistantContinuationInstructions =
  '用户已通过继续按钮恢复原任务。本轮没有新的用户消息，继续完成原要求，利用已有工具观察和实际执行回执，不要重复已保存的操作。已登记的意图尚未保存，不要重复登记；未完成的工具调用没有成功回执，不得假定已执行。被停止的回答可能尚未完整交付，请给出完整的最终答复。';

// Preserve observed results while closing interrupted calls before a fresh model turn.
export function assistantContinuationState(
  previous: AssistantState,
  previousRunId: string,
): AssistantState {
  // Clone JSON state so linking the old run cannot mutate the new attempt.
  const state = structuredClone(previous);
  // Only unmatched calls need a synthetic interruption result, never a success receipt.
  const pending = new Set<string>();
  for (const item of state.input) {
    if (item.type === 'function_call' && typeof item.call_id === 'string')
      pending.add(item.call_id);
    else if (
      item.type === 'function_call_output' &&
      typeof item.call_id === 'string'
    )
      pending.delete(item.call_id);
  }
  for (const callId of pending)
    state.input.push({
      type: 'function_call_output',
      call_id: callId,
      output: JSON.stringify({
        isError: true,
        code: 'ASSISTANT_INTERRUPTED',
        message:
          '上轮已停止，此调用没有已确认的完成回执；不能视为已读取、已登记或已保存。请根据原目标和已有回执决定下一步。',
      }),
    });
  state.calls = [];
  state.messageId = randomUUID();
  state.text = '';
  state.modelCount = 0;
  state.toolCount = 0;
  state.readProgress = assistantReadProgress(state);
  state.continuedFromRunId = previousRunId;
  // A fresh attempt gets its own budget, timing, and idempotent continuation link.
  if (state.readLimit) delete state.answerOnly;
  delete state.readLimit;
  delete state.readCorrectionUsed;
  delete state.recovery;
  delete state.executionSteps;
  delete state.segmentStartedAt;
  delete state.continuationRunId;
  return state;
}
