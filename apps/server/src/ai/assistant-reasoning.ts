import type { AssistantVisibleReasoning } from './assistant-model.types';

/// 单轮可读思考的展示上限，不改变供应商原始协议回执。
export const ASSISTANT_REASONING_LIMIT = 16000;

/// 只重建可读文本，永不透传加密续接项、供应商原始对象或工具参数。
export function assistantVisibleReasoning(value: unknown, limit = ASSISTANT_REASONING_LIMIT): AssistantVisibleReasoning | undefined {
  if (!value || typeof value !== 'object') return undefined;
  // 调用方和旧缓存都要经过相同的白名单校验。
  const source = value as { text?: unknown; truncated?: unknown };
  if (typeof source.text !== 'string') return undefined;
  // 保留正常换行和制表，清除不可打印控制字符及孤立代理字符。
  const text = Array.from(source.text).filter((character) => character === '\n' || character === '\t' || character.charCodeAt(0) >= 32 && character.charCodeAt(0) !== 127).join('').replace(/[\ud800-\udfff]/gu, '\ufffd');
  // 按Unicode码点截断，避免截断中文扩展字符或emoji。
  const characters = Array.from(text);
  // 展示省略是事实字段，不能把部分内容伪装成完整思考。
  const truncated = source.truncated === true || characters.length > limit;
  if (!text && !truncated) return undefined;
  return { text: characters.slice(0, Math.max(0, limit)).join(''), ...(truncated ? { truncated: true } : {}) };
}

/// 成功回执及旧成功响应恢复共用提取规则，只接受Responses可读思考字段。
export function assistantResponseReasoning(output: unknown): AssistantVisibleReasoning | undefined {
  if (!Array.isArray(output)) return undefined;
  // 同一项优先使用公开摘要，避免同时显示摘要和正文产生重复。
  const texts: string[] = [];
  for (const item of output as Array<Record<string, unknown>>) {
    if (!item || item.type !== 'reasoning') continue;
    // 供应商明确公开的摘要列表。
    const summary = Array.isArray(item.summary) ? item.summary.filter((part: unknown) => part && typeof part === 'object' && (part as Record<string, unknown>).type === 'summary_text' && typeof (part as Record<string, unknown>).text === 'string').map((part: { text: string }) => part.text) : [];
    // DeepSeek等Responses服务明确返回的可读思考内容。
    const content = Array.isArray(item.content) ? item.content.filter((part: unknown) => part && typeof part === 'object' && (part as Record<string, unknown>).type === 'reasoning_text' && typeof (part as Record<string, unknown>).text === 'string').map((part: { text: string }) => part.text) : [];
    texts.push(...(summary.some((text) => text.length > 0) ? summary : content));
  }
  return assistantVisibleReasoning({ text: texts.join('\n\n') });
}

/// 按供应商输出项合并流式思考；摘要和全文双通道不能重复拼接。
export class AssistantReasoningBuffer {
  /// 输出项仅保存两个有界可读通道，不保存协议中的其他字段。
  private readonly items = new Map<string, { summary: string; content: string }>();
  /// 超出展示预算后保持明确的省略标记。
  private truncated = false;

  /// 输入必须已经过事件类型和delta字符串检查。
  append(event: Record<string, unknown>): AssistantVisibleReasoning | undefined {
    // 序号仅接受有效非负整数，不能把任意供应商对象隐式转为身份。
    const index = typeof event.output_index === 'number' && Number.isSafeInteger(event.output_index) && event.output_index >= 0 ? String(event.output_index) : 'default';
    // 缺少供应商身份的兼容事件仍属于同一个默认输出项。
    const id = typeof event.item_id === 'string' ? event.item_id.slice(0, 256) : index;
    if (!this.items.has(id) && this.items.size >= 128) { this.truncated = true; return this.snapshot(); }
    // 每项摘要与全文分别有界，最终展示优先摘要。
    const item = this.items.get(id) ?? { summary: '', content: '' };
    // 明确事件通道，其他字段不能当作可读思考。
    const key = event.type === 'response.reasoning_summary_text.delta' ? 'summary' : 'content';
    item[key] += event.delta as string;
    if (item[key].length > ASSISTANT_REASONING_LIMIT * 2) { item[key] = item[key].slice(0, ASSISTANT_REASONING_LIMIT * 2); this.truncated = true; }
    this.items.set(id, item);
    return this.snapshot();
  }

  /// 交付累计快照而非裸增量，落库、SSE重放及终态回补不会重复正文。
  snapshot(): AssistantVisibleReasoning | undefined {
    return assistantVisibleReasoning({ text: [...this.items.values()].map((item) => item.summary || item.content).join('\n\n'), truncated: this.truncated });
  }
}
