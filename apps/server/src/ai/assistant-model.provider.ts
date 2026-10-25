import { HttpException, Injectable } from '@nestjs/common';
import { request } from 'node:https';
import { StringDecoder } from 'node:string_decoder';
import type { ClientRequest } from 'node:http';
import { TLSSocket } from 'node:tls';
import { AiKeyStore } from './ai-key-store';
import { AiProviderError, resolveAiEndpoint } from './ai-provider';
import { AiService } from './ai.service';
import type { AssistantFunctionCall, AssistantFunctionTool, AssistantModelCapabilities, AssistantModelRequest, AssistantModelResult, AssistantProfileSnapshot } from './assistant-model.types';
import { AssistantModelFailure, assistantRejectionCode, assistantReportedUsage, assistantResponseMetadata, assistantTemporaryRateLimit } from './assistant-model-failure';
import type { AssistantModelFailureFacts } from './assistant-model-failure';
import { AssistantReasoningBuffer, assistantResponseReasoning } from './assistant-reasoning';
import { ASSISTANT_REQUEST_BUDGET_MS, assistantCompatibility, assertAssistantImageInputs } from './assistant-model-policy';

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
    // DNS和配置校验消耗同一预算，不在创建HTTPS请求时重新获得一分钟。
    const startedAt = Date.now();
    // 本地校验阶段尚未创建模型请求，不能与已提交网络失败混淆。
    let facts: AssistantModelFailureFacts = { submission: 'notSubmitted', retryable: false };
    try {
    await this.profiles.assertAssistantProfileAvailable(userId, snapshot);
    if (input.signal?.aborted) throw new AiProviderError('AI_CANCELLED');
    // 允许目录在本次请求前固定，供应商返回的陌生函数不可执行。
    const names = validateTools(input.tools);
    // 纯回答阶段没有可执行工具，即使供应商违约返回原目录函数也必须拒绝。
    if (input.toolChoice === 'none') names.clear();
    // 只接受受控预算，不透传供应商的任意选项。
    const compatibility = assistantCompatibility(snapshot.compatibility);
    // 旧快照使用保守画像，新快照只能在自身已声明预算内运行。
    const maxOutputTokens = input.maxOutputTokens ?? compatibility.maxOutputTokens;
    if (!Number.isSafeInteger(maxOutputTokens) || maxOutputTokens < 1 || maxOutputTokens > compatibility.maxOutputTokens) throw new AiProviderError('AI_INVALID_REQUEST');
    if (!Array.isArray(input.input) || !input.input.length || input.input.some((item) => !isObject(item))) throw new AiProviderError('AI_INVALID_REQUEST');
    if (typeof input.toolChoice === 'object' && (!input.toolChoice || input.toolChoice.type !== 'function' || !names.has(input.toolChoice.name))) throw new AiProviderError('AI_INVALID_REQUEST');
    // 复用校验遍历判断真实图片载荷，旧快照也须核对当前开关后才出站。
    const requiresMultimodal = assertAssistantImageInputs(input.input, compatibility);
    // 剩余预算由持久化调度器扣减等待时间后传入。
    const timeoutMs = input.timeoutMs ?? ASSISTANT_REQUEST_BUDGET_MS;
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > ASSISTANT_REQUEST_BUDGET_MS) throw new AiProviderError('AI_INVALID_REQUEST');
    // 固定快照中的地址仍须经过与笔记相同的公网解析及 TLS 边界。
    const { url, address } = await resolveAiEndpoint(snapshot.baseUrl, input.signal);
    await this.profiles.assertAssistantProfileAvailable(userId, snapshot, requiresMultimodal);
    if (input.signal?.aborted) throw new AiProviderError('AI_CANCELLED');
    // 解密结果只用于当前 HTTP 认证头，永不进入返回值或日志。
    const apiKey = this.keys.decrypt(snapshot.encryptedApiKey);
    if (!apiKey || /[\r\n\0]/.test(apiKey)) throw new AiProviderError('AI_KEY_INVALID');
    // 纯回答省略工具目录，避免供应商按工具续轮校验此阶段不需要的推理历史。
    // 思考开关固定在任务快照中；官方OpenAI路由显式申请公开摘要，其他服务只发送已确认兼容的effort。
    const payload = JSON.stringify({ model: snapshot.model.trim(), instructions: input.instructions, input: input.input, reasoning: { effort: snapshot.thinkingEnabled === true ? 'high' : 'none', ...(snapshot.thinkingEnabled && url.hostname === 'api.openai.com' ? { summary: 'auto' } : {}) }, ...(input.toolChoice === 'none' ? {} : { tools: input.tools.map((tool) => ({ ...tool, strict: false })) }), tool_choice: input.toolChoice ?? 'auto', max_output_tokens: maxOutputTokens, stream: true, store: false });
    if (Buffer.byteLength(payload) > compatibility.maxRequestBytes) throw new AiProviderError('AI_INPUT_TOO_LARGE');
    // 预处理耗尽预算时绝不创建可能付费的请求。
    const remainingMs = Math.floor(timeoutMs - (Date.now() - startedAt));
    if (remainingMs < 1) throw new AiProviderError('AI_RETRY_BUDGET_EXHAUSTED');
    // 网络提交后发生取消、断流、超时均不能推断为没有计费。
    // 流式可读思考只保留有界副本，独立于供应商完整回执。
    const reasoningBuffer = new AssistantReasoningBuffer();
    const completed = await new Promise<unknown>((resolve, reject) => {
      // 记录成功终态，仍需等 HTTP 完整结束后再释放函数调用。
      let terminal: unknown;
      // 传输字节、可见字符及事件缓冲各自都有独立上限。
      let receivedBytes = 0;
      // 正文流量单独计数，可读思考由有界缓冲与独立回调处理。
      let visibleCharacters = 0;
      // 低频交付累计思考，避免每个token都重写任务状态。
      let reasoningDeliveredAt = 0;
      // 已排队快照大小只用于合并节流，不作为模型内容可信度依据。
      let reasoningDeliveredLength = 0;
      // 推理和工具参数增量也证明上游已经开始工作，不能安全自动重发。
      let sawDelta = false;
      // 异步事件落库顺序与供应商增量顺序一致，结束前等待全部交付。
      let delivery = Promise.resolve();
      // 任意失败立即关闭新交付，但必须等已经开始的回调收尾。
      let failure: AssistantModelFailure | undefined;
      // 正常终态与失败共享一次结算身份，迟到事件不能反转结果。
      let settled = false;
      // HTTP 结束后不再接受新的正文，已排队交付仍需正常完成。
      let ended = false;
      // TLS 握手前 HTTPS 不会发送应用请求，可证明尚未提交。
      let tlsConnecting = false;
      // 请求对象允许在同步构造失败前保持为空。
      const transport: { outgoing?: ClientRequest; deadline?: ReturnType<typeof setTimeout> } = {};
      // 错误正文只暂存有限内存，用于识别明确临时限流。
      let errorBody = '';
      // 非成功正文超过诊断预算即不再尝试分类。
      let errorBodyTruncated = false;
      // 失败不向外泄露原始 cause，并等待在途数据库回调稳定后拒绝。
      const fail = (error: unknown, evidence = facts): void => {
        if (failure || settled) return;
        // 固定本次错误供异步拒绝使用，不捕获可变的可空属性。
        const currentFailure = error instanceof AssistantModelFailure ? error : new AssistantModelFailure(error instanceof AiProviderError ? error.code : 'AI_SUBMISSION_UNKNOWN', { ...evidence });
        failure = currentFailure;
        ended = true;
        if (transport.deadline) clearTimeout(transport.deadline);
        transport.outgoing?.destroy();
        void delivery.then(() => { if (!settled) { settled = true; reject(currentFailure); } });
      };
      // 流解析器支持 UTF-8 和 CRLF 在任意网络包边界拆开。
      const stream = new AssistantSseReader((event) => {
        if (failure || ended) return;
        if (!isObject(event) || typeof event.type !== 'string') throw new AiProviderError('AI_INVALID_RESPONSE');
        if (terminal !== undefined) throw new AiProviderError('AI_INVALID_RESPONSE');
        // 用量只投影三项受控整数，失败响应也不能丢失已知用量。
        const usage = isObject(event.response) ? assistantReportedUsage(event.response.usage) : null;
        if (usage) facts = { ...facts, usage };
        if (event.type.endsWith('.delta') || event.type.startsWith('response.output_item.') || event.type.startsWith('response.content_part.')) sawDelta = true;
        if (event.type === 'error' || event.type === 'response.failed') {
          // 明确输入拒绝且没有任何生成证据，才可供运行器压缩后重新提交。
          const code = assistantRejectionCode(event.response ?? event);
          // 完整失败对象也可能包含已生成输出，即使此前没有正文增量。
          const hasOutput = isObject(event.response) && Array.isArray(event.response.output) && event.response.output.length > 0;
          facts = { ...facts, submission: !sawDelta && !facts.usage && !hasOutput && code !== 'AI_PROVIDER_REJECTED' ? 'rejected' : 'unknown', retryable: false };
          throw new AiProviderError(code);
        }
        if (event.type === 'response.incomplete') throw new AiProviderError(isObject(event.response) && isObject(event.response.incomplete_details) && event.response.incomplete_details.reason === 'max_output_tokens' ? 'AI_OUTPUT_TRUNCATED' : 'AI_PROVIDER_REJECTED');
        if (event.type === 'response.completed') {
          terminal = event.response;
          // 最后一小段即使未达到节流阈值，也要在成功结算前交付。
          const reasoning = assistantResponseReasoning(isObject(event.response) ? event.response.output : undefined) ?? reasoningBuffer.snapshot();
          if (reasoning) delivery = delivery.then(async () => { if (failure) return; try { await input.onReasoning?.(reasoning); } catch { fail(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)); } });
          return;
        }
        if (event.type === 'response.reasoning_summary_text.delta' || event.type === 'response.reasoning_text.delta') {
          if (typeof event.delta !== 'string') throw new AiProviderError('AI_INVALID_RESPONSE');
          // 仅这两个协议事件能够进入可读思考，工具和加密增量继续忽略。
          const reasoning = reasoningBuffer.append(event);
          if (reasoning && (reasoningDeliveredAt === 0 || Date.now() - reasoningDeliveredAt >= 150 || reasoning.text.length - reasoningDeliveredLength >= 512)) {
            reasoningDeliveredAt = Date.now();
            reasoningDeliveredLength = reasoning.text.length;
            delivery = delivery.then(async () => { if (failure) return; try { await input.onReasoning?.(reasoning); } catch { fail(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)); } });
          }
          return;
        }
        if (event.type !== 'response.output_text.delta') return;
        if (typeof event.delta !== 'string') throw new AiProviderError('AI_INVALID_RESPONSE');
        visibleCharacters += event.delta.length;
        if (visibleCharacters > MAX_TEXT_CHARACTERS) throw new AiProviderError('AI_OUTPUT_TOO_LONG');
        // 异步闭包固定当前增量，不能在后续事件中复用可变字段。
        const delta = event.delta;
        delivery = delivery.then(async () => {
          if (failure) return;
          try { await input.onDelta?.(delta); } catch { fail(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)); }
        });
      });
      // lookup 固定已验证 IP，保留原域名的 SNI 与证书检查，禁止重定向。
      const outgoing = request(url, { method: 'POST', agent: false, headers: { 'content-type': 'application/json', accept: 'text/event-stream', 'content-length': Buffer.byteLength(payload), authorization: `Bearer ${apiKey}` }, family: address.family, lookup: (_name, options, callback) => options.all ? callback(null, [address]) : callback(null, address.address, address.family), timeout: remainingMs, signal: input.signal }, (response) => {
        // 状态码仅分类为本地稳定错误，不包含供应商敏感正文。
        const status = response.statusCode ?? 0;
        facts = { submission: 'unknown', retryable: false, ...(status ? { httpStatus: status } : {}), ...assistantResponseMetadata(response.headers ?? {}) };
        tlsConnecting = false;
        response.on('data', (chunk: Buffer) => {
          if (failure || ended) return;
          try {
            receivedBytes += chunk.length;
            if (receivedBytes > MAX_RESPONSE_BYTES) throw new AiProviderError('AI_RESPONSE_TOO_LARGE', true);
            if (status < 200 || status >= 300) {
              if (receivedBytes <= 16384) errorBody += chunk.toString('utf8'); else errorBodyTruncated = true;
              return;
            }
            stream.push(chunk);
          } catch (error: unknown) { fail(error); }
        });
        response.on('aborted', () => fail(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)));
        response.on('error', () => fail(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)));
        response.on('close', () => { if (!ended) fail(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)); });
        response.on('end', () => {
          if (failure || ended) return;
          try {
            if (status < 200 || status >= 300) {
              // 即使状态为4xx，正文带用量或输出也不能假定未执行。
              let generationEvidence = false;
              try {
                // 错误JSON受16KiB预算约束，所有原文字段仍不离开内存。
                const errorValue: unknown = errorBodyTruncated ? null : JSON.parse(errorBody);
                if (isObject(errorValue)) {
                  generationEvidence = 'usage' in errorValue || 'output' in errorValue || 'response' in errorValue;
                  // 已知用量单独投影，不能带出附加错误详情。
                  const usage = assistantReportedUsage(errorValue.usage);
                  if (usage) facts = { ...facts, usage };
                }
              } catch { /* 无法解析的错误不获得额外恢复能力。 */ }
              facts = { ...facts, submission: status >= 300 && status < 500 && !generationEvidence ? 'rejected' : 'unknown', retryable: status === 429 && !generationEvidence && !errorBodyTruncated && assistantTemporaryRateLimit(errorBody) };
              throw httpFailure(status, errorBodyTruncated ? '' : errorBody);
            }
            stream.finish();
            if (terminal === undefined) throw new AiProviderError('AI_SUBMISSION_UNKNOWN', true);
            ended = true;
            if (transport.deadline) clearTimeout(transport.deadline);
            // 完整结果在正文事件全部持久保存之后才交给图运行器。
            void delivery.then(() => { if (!failure && !settled) { settled = true; resolve(terminal); } });
          } catch (error: unknown) { fail(error); }
        });
      });
      transport.outgoing = outgoing;
      // 只信任真实 TLS socket，不能把没有阶段证据的未知错误标记未计费。
      outgoing.on('socket', (socket) => {
        if (socket instanceof TLSSocket && !socket.authorized) {
          tlsConnecting = true;
          socket.once('secureConnect', () => { tlsConnecting = false; });
        }
      });
      // 独立总时限同时限制不断滴流的供应商，不依赖 socket 空闲超时。
      const deadline = setTimeout(() => fail(new AiProviderError('AI_SUBMISSION_UNKNOWN', true), { ...facts, submission: tlsConnecting ? 'notSubmitted' : 'unknown', retryable: false }), remainingMs);
      transport.deadline = deadline;
      outgoing.on('close', () => { clearTimeout(deadline); if (!ended) fail(new AiProviderError('AI_SUBMISSION_UNKNOWN', true)); });
      outgoing.on('timeout', () => fail(new AiProviderError('AI_SUBMISSION_UNKNOWN', true), { ...facts, submission: tlsConnecting ? 'notSubmitted' : 'unknown', retryable: false }));
      outgoing.on('error', (error: Error & { code?: string }) => {
        // 拒绝连接或临时解析失败且 TLS 尚未建立，才确认为可重试未提交。
        const transient = tlsConnecting && !input.signal?.aborted && ['ECONNREFUSED', 'EAI_AGAIN', 'ENETUNREACH', 'EHOSTUNREACH', 'ECONNRESET'].includes(error.code ?? '');
        fail(new AiProviderError(transient ? 'AI_CONNECTION_FAILED' : 'AI_SUBMISSION_UNKNOWN', !tlsConnecting), { ...facts, submission: tlsConnecting ? 'notSubmitted' : 'unknown', retryable: transient });
      });
      // 请求排入传输后默认未知；只有真实 TLS 前置证据才能收窄为未提交。
      facts = { submission: 'unknown', retryable: false };
      outgoing.end(payload);
    });
    // 后台配置删除或换 Key 后，迟到结果也不可用于新工具计划。
    await this.profiles.assertAssistantProfileAvailable(userId, snapshot);
    // 某些服务只在增量中返回思考，另一些只在完整回执中返回。
    const result = readCompleted(completed, snapshot.provider, names);
    // 回执已包含可读内容时优先使用它，保持流和恢复的最终结果一致。
    const reasoning = assistantResponseReasoning(result.output) ?? reasoningBuffer.snapshot();
    return { ...result, ...(reasoning ? { reasoning } : {}) };
    } catch (error: unknown) {
      if (error instanceof AssistantModelFailure) throw error;
      if (error instanceof AiProviderError) throw new AssistantModelFailure(error.code, { ...facts, retryable: facts.submission === 'notSubmitted' && error.code === 'AI_DNS_FAILED' && !input.signal?.aborted });
      // 保留配置撤回和地址校验的既有 HTTP 语义，不把它们误判网络故障。
      if (error instanceof HttpException) throw error;
      throw new AssistantModelFailure(facts.submission === 'notSubmitted' ? 'AI_INVALID_REQUEST' : 'AI_SUBMISSION_UNKNOWN', { ...facts, retryable: false });
    }
  }

  /// 固定无业务副作用的两轮测试，验证函数参数、结果回传和真实正文流。
  async testCapability(userId: string, snapshot: AssistantProfileSnapshot): Promise<{ ok: true; message: string; capabilities: AssistantModelCapabilities }> {
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
    // 仅回传配置快照声明的图片能力，连接测试不能改变多模态开关。
    const capabilities: AssistantModelCapabilities = { version: 1, streaming: true, functionCalling: true, imageInput: assistantCompatibility(snapshot.compatibility).imageInput };
    return { ok: true, message: '助手流式回答与工具调用测试成功', capabilities };
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
  const usage = assistantReportedUsage(value.usage);
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

/// HTTP 错误不回传服务商原文，也不自动切换供应商或重复计费。
function httpFailure(status: number, body: string): AiProviderError {
  if (status >= 500 || status < 100) return new AiProviderError('AI_SUBMISSION_UNKNOWN', true);
  if (status === 401 || status === 403) return new AiProviderError('AI_AUTH_FAILED');
  if (status === 404) return new AiProviderError('AI_MODEL_OR_URL_INVALID');
  if (status === 402) return new AiProviderError('AI_QUOTA_EXHAUSTED');
  // 只有受限完整JSON的标准字段参与细分，未知正文不会出现在异常中。
  let code = 'AI_PROVIDER_REJECTED';
  try { if (status >= 400 && status < 500) code = assistantRejectionCode(JSON.parse(body)); } catch { /* 损坏错误正文保持通用分类。 */ }
  return new AiProviderError(code === 'AI_PROVIDER_REJECTED' && status === 429 ? 'AI_RATE_LIMITED' : code);
}
