import { Injectable } from '@nestjs/common';
import { request } from 'node:https';
import { StringDecoder } from 'node:string_decoder';
import { AiKeyStore } from './ai-key-store';
import { AiProviderError, resolveAiEndpoint } from './ai-provider';
import { AiService } from './ai.service';
import type { AssistantFunctionCall, AssistantFunctionTool, AssistantModelRequest, AssistantModelResult, AssistantProfileSnapshot } from './assistant-model.types';

/// SSE 流、完整结果及工具参数共享有限字节上限，防止无界供应商输出。
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
/// 单个事件足以容纳完整终态，但不能无限堆积未换行数据。
const MAX_EVENT_CHARACTERS = 2 * 1024 * 1024;
/// 文本按字符限制，避免只限制 SSE 字节却让终态无限增长。
const MAX_TEXT_CHARACTERS = 80000;

/// 助手只使用 Responses 流式函数调用，业务图自行负责工具执行与授权。
@Injectable()
export class AssistantModelProvider {
  /// 密钥仅在安全出站前解密，配置归属由现有 AI 服务校验。
  constructor(private readonly profiles: AiService, private readonly keys: AiKeyStore) {}

  /// 完整终态前只发送可见正文增量，不向上层提供部分工具参数。
  async complete(userId: string, snapshot: AssistantProfileSnapshot, input: AssistantModelRequest): Promise<AssistantModelResult> {
    await this.profiles.assertAssistantProfileAvailable(userId, snapshot);
    if (input.signal?.aborted) throw new AiProviderError('AI_CANCELLED');
    // 允许目录在本次请求前固定，供应商返回的陌生函数不可执行。
    const names = validateTools(input.tools);
    // 只接受受控预算，不透传供应商的任意选项。
    const maxOutputTokens = input.maxOutputTokens ?? 8192;
    if (!Number.isSafeInteger(maxOutputTokens) || maxOutputTokens < 1 || maxOutputTokens > 32768) throw new AiProviderError('AI_INVALID_REQUEST');
    if (!Array.isArray(input.input) || !input.input.length || input.input.some((item) => !isObject(item))) throw new AiProviderError('AI_INVALID_REQUEST');
    if (typeof input.toolChoice === 'object' && (!input.toolChoice || input.toolChoice.type !== 'function' || !names.has(input.toolChoice.name))) throw new AiProviderError('AI_INVALID_REQUEST');
    // 固定快照中的地址仍须经过与笔记相同的公网解析及 TLS 边界。
    const { url, address } = await resolveAiEndpoint(snapshot.baseUrl, input.signal);
    await this.profiles.assertAssistantProfileAvailable(userId, snapshot);
    if (input.signal?.aborted) throw new AiProviderError('AI_CANCELLED');
    // 解密结果只用于当前 HTTP 认证头，永不进入返回值或日志。
    const apiKey = this.keys.decrypt(snapshot.encryptedApiKey);
    if (!apiKey || /[\r\n\0]/.test(apiKey)) throw new AiProviderError('AI_KEY_INVALID');
    // 不继承笔记整理的 reasoning.effort=none，让助手采用供应商默认设置。
    const payload = JSON.stringify({ model: snapshot.model.trim(), instructions: input.instructions, input: input.input, tools: input.tools.map((tool) => ({ ...tool, strict: false })), tool_choice: input.toolChoice ?? 'auto', max_output_tokens: maxOutputTokens, stream: true, store: false });
    if (Buffer.byteLength(payload) > 2 * 1024 * 1024) throw new AiProviderError('AI_INPUT_TOO_LARGE');
    // 网络提交后发生取消、断流、超时均不能推断为没有计费。
    const completed = await new Promise<unknown>((resolve, reject) => {
      // 记录成功终态，仍需等 HTTP 完整结束后再释放函数调用。
      let terminal: unknown;
      // 传输字节、可见字符及事件缓冲各自都有独立上限。
      let receivedBytes = 0;
      // 只累计正文增量用于流量保护，不存储或展示 reasoning 增量。
      let visibleCharacters = 0;
      // 异步事件落库顺序与供应商增量顺序一致，结束前等待全部交付。
      let delivery = Promise.resolve();
      // 数据库回调失败时停止后续交付，不能产生未处理的 Promise 拒绝。
      let deliveryFailure: AiProviderError | undefined;
      // 流解析器支持 UTF-8 和 CRLF 在任意网络包边界拆开。
      const stream = new AssistantSseReader((event) => {
        if (!isObject(event) || typeof event.type !== 'string') throw new AiProviderError('AI_INVALID_RESPONSE');
        if (terminal !== undefined) throw new AiProviderError('AI_INVALID_RESPONSE');
        if (event.type === 'error' || event.type === 'response.failed') throw new AiProviderError('AI_PROVIDER_REJECTED');
        if (event.type === 'response.incomplete') throw new AiProviderError(isObject(event.response) && isObject(event.response.incomplete_details) && event.response.incomplete_details.reason === 'max_output_tokens' ? 'AI_OUTPUT_TRUNCATED' : 'AI_PROVIDER_REJECTED');
        if (event.type === 'response.completed') { terminal = event.response; return; }
        if (event.type !== 'response.output_text.delta') return;
        if (typeof event.delta !== 'string') throw new AiProviderError('AI_INVALID_RESPONSE');
        visibleCharacters += event.delta.length;
        if (visibleCharacters > MAX_TEXT_CHARACTERS) throw new AiProviderError('AI_OUTPUT_TOO_LONG');
        // 异步闭包固定当前增量，不能在后续事件中复用可变字段。
        const delta = event.delta;
        delivery = delivery.then(async () => {
          if (deliveryFailure) return;
          try { await input.onDelta?.(delta); } catch { deliveryFailure = new AiProviderError('AI_SUBMISSION_UNKNOWN', true); outgoing.destroy(deliveryFailure); }
        });
      });
      // lookup 固定已验证 IP，保留原域名的 SNI 与证书检查，禁止重定向。
      const outgoing = request(url, { method: 'POST', agent: false, headers: { 'content-type': 'application/json', accept: 'text/event-stream', 'content-length': Buffer.byteLength(payload), authorization: `Bearer ${apiKey}` }, family: address.family, lookup: (_name, options, callback) => options.all ? callback(null, [address]) : callback(null, address.address, address.family), timeout: 60000, signal: input.signal }, (response) => {
        // 状态码仅分类为本地稳定错误，不包含供应商敏感正文。
        const status = response.statusCode ?? 0;
        response.on('data', (chunk: Buffer) => {
          try {
            receivedBytes += chunk.length;
            if (receivedBytes > MAX_RESPONSE_BYTES) throw new AiProviderError('AI_RESPONSE_TOO_LARGE', true);
            if (status < 200 || status >= 300) return;
            stream.push(chunk);
          } catch (error: unknown) { outgoing.destroy(providerError(error)); }
        });
        response.on('aborted', () => reject(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)));
        response.on('error', () => reject(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)));
        response.on('end', () => {
          try {
            if (status < 200 || status >= 300) throw httpFailure(status);
            stream.finish();
            if (terminal === undefined) throw new AiProviderError('AI_SUBMISSION_UNKNOWN', true);
            // 完整结果在正文事件全部持久保存之后才交给图运行器。
            void delivery.then(() => { if (deliveryFailure) reject(deliveryFailure); else resolve(terminal); });
          } catch (error: unknown) { reject(providerError(error)); }
        });
      });
      // 独立总时限同时限制不断滴流的供应商，不依赖 socket 空闲超时。
      const deadline = setTimeout(() => outgoing.destroy(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)), 60000);
      outgoing.on('close', () => clearTimeout(deadline));
      outgoing.on('timeout', () => outgoing.destroy(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)));
      outgoing.on('error', (error: Error) => reject(providerError(error)));
      outgoing.end(payload);
    });
    // 后台配置删除或换 Key 后，迟到结果也不可用于新工具计划。
    await this.profiles.assertAssistantProfileAvailable(userId, snapshot);
    return readCompleted(completed, snapshot.provider, names);
  }

  /// 固定无业务副作用的两轮测试，验证函数参数、结果回传和真实正文流。
  async testCapability(userId: string, snapshot: AssistantProfileSnapshot): Promise<{ ok: true; message: string }> {
    // 固定测试工具不会接触业务资料，实际执行只是返回固定字符串。
    const tool: AssistantFunctionTool = { type: 'function', name: 'assistant_capability_echo', description: '连接测试：原样返回固定测试文本。', parameters: { type: 'object', properties: { text: { type: 'string', enum: ['连接测试'] } }, required: ['text'], additionalProperties: false } };
    // 测试上下文不使用任何用户笔记或聊天消息。
    const messages: Record<string, unknown>[] = [{ role: 'user', content: '调用 assistant_capability_echo，text 必须为连接测试。' }];
    // 第一轮强制函数调用，不能将普通文本回复误判为支持工具。
    const first = await this.complete(userId, snapshot, { instructions: '这是固定连接测试。只调用提供的测试函数，不需要解释。', input: messages, tools: [tool], toolChoice: { type: 'function', name: tool.name }, maxOutputTokens: 2048 });
    // 只有精确匹配的无副作用测试调用才允许进入下一轮。
    const call = first.functionCalls[0];
    if (first.functionCalls.length !== 1 || !call || call.name !== tool.name || call.arguments.text !== '连接测试' || Object.keys(call.arguments).length !== 1) throw new AiProviderError('AI_FUNCTION_CALL_UNSUPPORTED');
    // 检测实际 output_text.delta，终态正文不能冒充流式能力。
    let streamed = false;
    // 回传完整输出项，保留供应商要求的 reasoning 续接项。
    const second = await this.complete(userId, snapshot, { instructions: '测试函数已经返回。只回复“连接成功”。', input: [...messages, ...first.output, { type: 'function_call_output', call_id: call.callId, output: JSON.stringify({ text: '连接测试' }) }], tools: [], toolChoice: 'none', maxOutputTokens: 2048, onDelta: (text) => { if (text) streamed = true; } });
    if (!streamed || !second.text.trim() || second.functionCalls.length) throw new AiProviderError('AI_STREAMING_UNSUPPORTED');
    return { ok: true, message: '助手流式回答与工具调用测试成功' };
  }
}

/// 按 SSE 空行划分事件，支持注释、多行 data、CRLF 和跨包 UTF-8。
class AssistantSseReader {
  /// 字符解码器保留跨包的汉字字节。
  private readonly decoder = new StringDecoder('utf8');
  /// 缓冲只保存尚未组成完整行的文本。
  private pending = '';
  /// 多行 data 按标准换行拼接。
  private data: string[] = [];
  /// 已累积事件长度限制多行绕过。
  private eventLength = 0;
  /// 事件解析回调只接收 JSON，不接受任意脚本或 HTML。
  constructor(private readonly consume: (event: unknown) => void) {}

  /// 解码新的有限字节块并提取完整行。
  push(chunk: Buffer): void { this.pending += this.decoder.write(chunk); this.readLines(); }

  /// 完整结束才处理最后的合法事件，半截 JSON 不被忽略。
  finish(): void {
    this.pending += this.decoder.end();
    this.readLines();
    if (this.pending) { this.readLine(this.pending); this.pending = ''; }
    this.dispatch();
  }

  /// 逐行处理，CRLF 在下一包中补齐也不会改变 data 内容。
  private readLines(): void {
    // 当前换行位置在每次截取后重新计算。
    let newline = this.pending.indexOf('\n');
    while (newline >= 0) {
      // CRLF 去掉行尾 CR，保留正文 JSON 内转义的换行。
      const line = this.pending.slice(0, newline).replace(/\r$/, '');
      this.pending = this.pending.slice(newline + 1);
      this.readLine(line);
      newline = this.pending.indexOf('\n');
    }
    if (this.pending.length + this.eventLength > MAX_EVENT_CHARACTERS) throw new AiProviderError('AI_RESPONSE_TOO_LARGE', true);
  }

  /// 无关字段及心跳注释不进入 JSON，事件内容必须由 data 提供。
  private readLine(line: string): void {
    if (!line) { this.dispatch(); return; }
    this.eventLength += line.length;
    if (this.eventLength > MAX_EVENT_CHARACTERS) throw new AiProviderError('AI_RESPONSE_TOO_LARGE', true);
    if (line.startsWith('data:')) this.data.push(line.slice(5).replace(/^ /, ''));
  }

  /// 完整事件一次解析，工具参数增量只作为资料而不被执行。
  private dispatch(): void {
    // SSE 终止标记不替代 response.completed 终态。
    const text = this.data.join('\n');
    this.data = []; this.eventLength = 0;
    if (!text || text === '[DONE]') return;
    // 供应商任意 JSON 均先作为未知类型处理。
    let event: unknown;
    try { event = JSON.parse(text); } catch { throw new AiProviderError('AI_INVALID_RESPONSE'); }
    this.consume(event);
  }
}

/// 完整输出只允许文本、函数调用和不透明 reasoning 续接项。
function readCompleted(value: unknown, provider: string, tools: Set<string>): AssistantModelResult {
  if (!isObject(value) || value.object !== 'response') throw new AiProviderError('AI_INVALID_RESPONSE');
  if (value.error != null || value.status === 'failed') throw new AiProviderError('AI_PROVIDER_REJECTED');
  if (value.status === 'incomplete' || value.incomplete_details != null) throw new AiProviderError(isObject(value.incomplete_details) && value.incomplete_details.reason === 'max_output_tokens' ? 'AI_OUTPUT_TRUNCATED' : 'AI_PROVIDER_REJECTED');
  if (value.status !== 'completed' || typeof value.id !== 'string' || !value.id || !Array.isArray(value.output)) throw new AiProviderError('AI_INVALID_RESPONSE');
  // 文本块顺序保持供应商响应中的自然段边界。
  const messages: string[] = [];
  // 工具调用返回结构化对象，不能直接把原始字符串透传业务执行。
  const functionCalls: AssistantFunctionCall[] = [];
  // 输出项保留完整协议结构，reasoning 仅供下次模型调用。
  const output: Record<string, unknown>[] = [];
  // 重复 call_id 不能让一个函数结果被错误归属于多个调用。
  const callIds = new Set<string>();
  for (const item of value.output as unknown[]) {
    if (!isObject(item) || typeof item.type !== 'string' || (item.status !== undefined && item.status !== 'completed')) throw new AiProviderError('AI_INVALID_RESPONSE');
    if (item.type === 'reasoning') { output.push(item); continue; }
    if (item.type === 'function_call') {
      if (typeof item.id !== 'string' || !item.id || typeof item.call_id !== 'string' || !item.call_id || typeof item.name !== 'string' || !tools.has(item.name) || typeof item.arguments !== 'string' || callIds.has(item.call_id) || functionCalls.length >= 32) throw new AiProviderError('AI_INVALID_FUNCTION_CALL');
      // 参数必须是完整 JSON 对象，数组、null 和半截字符串全部拒绝。
      let argumentsValue: unknown;
      try { argumentsValue = JSON.parse(item.arguments); } catch { throw new AiProviderError('AI_INVALID_FUNCTION_CALL'); }
      if (!isObject(argumentsValue)) throw new AiProviderError('AI_INVALID_FUNCTION_CALL');
      callIds.add(item.call_id);
      functionCalls.push({ id: item.id, callId: item.call_id, name: item.name, arguments: argumentsValue });
      output.push(item); continue;
    }
    if (item.type !== 'message' || item.role !== 'assistant' || item.status !== 'completed') throw new AiProviderError('AI_INVALID_RESPONSE');
    // 智谱兼容单个文本对象，其余供应商遵守标准内容数组。
    const parts: unknown[] = Array.isArray(item.content) ? item.content as unknown[] : provider === 'zhipu' && isObject(item.content) ? [item.content] : [];
    if (!Array.isArray(item.content) && !(provider === 'zhipu' && isObject(item.content))) throw new AiProviderError('AI_INVALID_RESPONSE');
    // 同一助手消息内文本块原样拼接，拒绝混入拒答或未知内容类型。
    const texts: string[] = [];
    for (const part of parts) {
      if (!isObject(part) || part.type !== 'output_text' || typeof part.text !== 'string') throw new AiProviderError(isObject(part) && part.type === 'refusal' ? 'AI_PROVIDER_REJECTED' : 'AI_INVALID_RESPONSE');
      texts.push(part.text);
    }
    messages.push(texts.join('')); output.push(item);
  }
  // 没有正文的纯工具调用是合法中间轮次，空回答不是成功。
  const text = messages.join('\n\n').trim();
  if (!text && !functionCalls.length) throw new AiProviderError('AI_EMPTY_OUTPUT');
  if (text.length > MAX_TEXT_CHARACTERS) throw new AiProviderError('AI_OUTPUT_TOO_LONG');
  // 用量缺失不推算为零，只有完整非负整数组合才进入回执。
  const usage = isObject(value.usage) && validTokens(value.usage.input_tokens) && validTokens(value.usage.output_tokens) && validTokens(value.usage.total_tokens) ? { inputTokens: value.usage.input_tokens, outputTokens: value.usage.output_tokens, totalTokens: value.usage.total_tokens } : null;
  return { responseId: value.id, text, functionCalls, output, usage };
}

/// 工具目录来自服务端固定函数，重复名称和供应商内建工具均拒绝。
function validateTools(tools: AssistantFunctionTool[]): Set<string> {
  if (!Array.isArray(tools) || tools.length > 128) throw new AiProviderError('AI_INVALID_REQUEST');
  // 预先去重，避免同一个名称对应两份参数定义。
  const names = new Set<string>();
  for (const tool of tools) {
    if (!isObject(tool) || tool.type !== 'function' || typeof tool.name !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(tool.name) || names.has(tool.name) || !isObject(tool.parameters)) throw new AiProviderError('AI_INVALID_REQUEST');
    names.add(tool.name);
  }
  return names;
}

/// 只验证未知 JSON 是否为普通对象，不依赖供应商类型声明。
function isObject(value: unknown): value is Record<string, unknown> { return typeof value === 'object' && value !== null && !Array.isArray(value); }

/// 用量必须为有限的非负安全整数。
function validTokens(value: unknown): value is number { return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0; }

/// 本地固定错误保留，未知网络或回调错误只标记不确定提交。
function providerError(error: unknown): AiProviderError { return error instanceof AiProviderError ? error : new AiProviderError('AI_SUBMISSION_UNKNOWN', true); }

/// HTTP 错误不回传服务商原文，也不自动切换供应商或重复计费。
function httpFailure(status: number): AiProviderError { return new AiProviderError(status === 401 || status === 403 ? 'AI_AUTH_FAILED' : status === 404 ? 'AI_MODEL_OR_URL_INVALID' : status === 429 ? 'AI_RATE_LIMITED' : status >= 500 ? 'AI_SUBMISSION_UNKNOWN' : 'AI_PROVIDER_REJECTED', status >= 500); }
