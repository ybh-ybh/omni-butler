import { ConflictException, NotFoundException } from '@nestjs/common';
import { EventEmitter } from 'node:events';
import type { ClientRequest, IncomingMessage, RequestOptions } from 'node:http';
import { request } from 'node:https';
import { TLSSocket } from 'node:tls';
import { Socket } from 'node:net';
import { resolveAiAddresses } from '../src/ai/ai-dns';
import { AiKeyStore } from '../src/ai/ai-key-store';
import { AiProvider, AiProviderError } from '../src/ai/ai-provider';
import { AiService } from '../src/ai/ai.service';
import { AssistantModelProvider } from '../src/ai/assistant-model.provider';
import { assistantCompatibility, createAssistantImagePart } from '../src/ai/assistant-model-policy';
import type { AssistantFunctionTool, AssistantProfileSnapshot } from '../src/ai/assistant-model.types';
import { PrismaService } from '../src/prisma/prisma.service';

jest.mock('node:https', () => ({ request: jest.fn() }));
jest.mock('../src/ai/ai-dns', () => ({ resolveAiAddresses: jest.fn() }));

/// 合成文本终态，不包含任何用户记录或真实凭据。
function textResponse(text = '已完成查询。'): Record<string, unknown> {
  return { id: 'resp_test', object: 'response', status: 'completed', error: null, incomplete_details: null, output: [{ id: 'msg_test', type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text }] }], usage: { input_tokens: 10, output_tokens: 4, total_tokens: 14 } };
}

/// 标准函数终态保留字符串参数，真实业务仍需 schema 校验。
function callResponse(argumentsText = '{"query":"学习"}', name = 'search'): Record<string, unknown> {
  return { ...textResponse(), output: [{ id: 'fc_test', type: 'function_call', call_id: 'call_test', name, arguments: argumentsText, status: 'completed' }] };
}

/// SSE 帧始终包含最终 Responses 对象。
function sse(response: Record<string, unknown>, events: Record<string, unknown>[] = []): string {
  return [...events, { type: 'response.completed', response }].map((event) => `data: ${JSON.stringify(event)}\r\n\r\n`).join('') + 'data: [DONE]\r\n\r\n';
}

/// 手动传输只暴露事件入口，允许交错异步落库与上游失败。
function controlledTransport(status = 200): { outgoing: ClientRequest; response: IncomingMessage } {
  // 全部响应来自内存，不建立 socket 或访问真实模型。
  const response = new EventEmitter() as IncomingMessage;
  response.statusCode = status; response.headers = {};
  // 构造与原生请求相同的关闭和错误事件顺序。
  const outgoing = new EventEmitter() as ClientRequest;
  outgoing.destroy = ((error?: Error): ClientRequest => { if (error) outgoing.emit('error', error); outgoing.emit('close'); return outgoing; });
  jest.mocked(request).mockImplementation(((url: URL, options: RequestOptions, callback: (response: IncomingMessage) => void): ClientRequest => {
    options.signal?.addEventListener('abort', () => outgoing.destroy(new Error('合成取消')), { once: true });
    outgoing.end = ((): ClientRequest => { callback(response); return outgoing; }) as ClientRequest['end'];
    return outgoing;
  }) as typeof request);
  return { outgoing, response };
}

describe('助手模型流式 Responses 与 Function Calling', () => {
  /// 固定快照的凭据保持密文，测试密钥只由替身解密。
  const snapshot: AssistantProfileSnapshot = { profileId: 'profile-test', profileRevision: 3, provider: 'custom', model: 'test-model', baseUrl: 'https://model.example.test/prefix/v1', encryptedApiKey: 'synthetic-cipher' };
  /// 工具目录只包含无副作用的合成查询。
  const tools: AssistantFunctionTool[] = [{ type: 'function', name: 'search', description: '查询合成资料。', parameters: { type: 'object', properties: { query: { type: 'string' } } } }];
  /// 模型请求只包含测试文本。
  const input = { instructions: '使用测试工具。', input: [{ role: 'user', content: '查找学习' }], tools };
  /// 同归属配置检查的独立替身。
  const profiles = { assertAssistantProfileAvailable: jest.fn<Promise<void>, [string, AssistantProfileSnapshot]>() };
  /// 不读真实密钥文件，测试解密仅返回固定字符串。
  const keys = { decrypt: jest.fn<string, [string]>() };
  /// 最近一次发送到模拟供应商的端点。
  let sentUrl: URL;
  /// 最近一次 TLS 请求参数。
  let sentOptions: RequestOptions;
  /// 每轮请求正文用于验证工具结果续接。
  let payloads: Record<string, unknown>[];
  /// 响应队列允许覆盖两轮固定能力测试。
  let responses: { status: number; body: string; byteChunks?: boolean; hanging?: boolean; headers?: Record<string, string> }[];
  /// 当前模拟请求用于验证超时、断流和取消。
  let currentRequest: ClientRequest;
  /// 每例测试独立创建适配器。
  let provider: AssistantModelProvider;

  beforeEach(() => {
    jest.clearAllMocks(); payloads = []; responses = [{ status: 200, body: sse(textResponse(), [{ type: 'response.output_text.delta', delta: '已完成查询。' }]) }];
    profiles.assertAssistantProfileAvailable.mockResolvedValue(); keys.decrypt.mockReturnValue('unit-only-key');
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }]);
    provider = new AssistantModelProvider(profiles as unknown as AiService, keys as unknown as AiKeyStore);
    jest.mocked(request).mockImplementation(((url: URL, options: RequestOptions, callback: (response: IncomingMessage) => void): ClientRequest => {
      sentUrl = url; sentOptions = options;
      // 事件替身保留请求生命周期，但永不建立真实网络连接。
      const outgoing = new EventEmitter() as ClientRequest;
      currentRequest = outgoing;
      outgoing.destroy = ((error?: Error): ClientRequest => { if (error) outgoing.emit('error', error); outgoing.emit('close'); return outgoing; });
      options.signal?.addEventListener('abort', () => outgoing.destroy(new Error('合成取消')), { once: true });
      outgoing.end = ((payload: string): ClientRequest => {
        payloads.push(JSON.parse(payload) as Record<string, unknown>);
        // 每个请求严格消耗一次响应，不能悄悄重试。
        const fixture = responses.shift();
        if (!fixture) throw new Error('意外重复模型请求');
        if (fixture.hanging) return outgoing;
        // Unicode 可按单字节拆包，验证 StringDecoder 不丢失中文。
        const response = new EventEmitter() as IncomingMessage;
        response.statusCode = fixture.status; response.headers = fixture.headers ?? {}; callback(response);
        // 所有网络数据来自合成 SSE 夹具。
        const buffer = Buffer.from(fixture.body);
        if (fixture.byteChunks) for (const byte of buffer) response.emit('data', Buffer.from([byte]));
        else response.emit('data', buffer);
        response.emit('end'); outgoing.emit('close'); return outgoing;
      }) as ClientRequest['end'];
      return outgoing;
    }) as typeof request);
  });

  it('固定公网 DNS、路径前缀、store:false，不继承笔记关闭思考参数', async () => {
    // 仅可见正文送达 UI，原始协议结构留给模型上下文。
    const onDelta = jest.fn();
    expect(await provider.complete('owner-test', snapshot, { ...input, onDelta })).toMatchObject({ text: '已完成查询。', functionCalls: [], usage: { inputTokens: 10, outputTokens: 4, totalTokens: 14 } });
    expect(onDelta).toHaveBeenCalledWith('已完成查询。');
    expect(payloads[0]).toEqual({ model: 'test-model', instructions: input.instructions, input: input.input, reasoning: { effort: 'none' }, tools: [{ ...tools[0], strict: false }], tool_choice: 'auto', max_output_tokens: 8192, stream: true, store: false });
    expect(sentUrl.pathname).toBe('/prefix/v1/responses');
    expect(sentOptions).toMatchObject({ agent: false, headers: { authorization: 'Bearer unit-only-key', accept: 'text/event-stream' } });
    // 请求解析器永远只能使用经过公网验证的唯一 IP。
    const lookup = jest.fn();
    sentOptions.lookup!('model.example.test', { all: true }, lookup);
    expect(lookup).toHaveBeenCalledWith(null, [{ address: '8.8.8.8', family: 4 }]);
    expect(profiles.assertAssistantProfileAvailable).toHaveBeenCalledTimes(3);
    expect(profiles.assertAssistantProfileAvailable).toHaveBeenCalledWith('owner-test', snapshot);
    expect(JSON.stringify(payloads)).not.toContain(snapshot.encryptedApiKey);
  });

  it('多行 SSE、CRLF 与逐字节中文拆包可正确解析', async () => {
    responses = [{ status: 200, byteChunks: true, body: ': 心跳\r\n\r\nevent: response.output_text.delta\r\ndata: {"type":"response.output_text.delta",\r\ndata: "delta":"中文内容"}\r\n\r\n' + sse(textResponse('中文内容')) }];
    // 输出增量中的中文不能在 UTF-8 边界损坏。
    const onDelta = jest.fn();
    await expect(provider.complete('owner-test', snapshot, { ...input, onDelta })).resolves.toMatchObject({ text: '中文内容' });
    expect(onDelta).toHaveBeenCalledWith('中文内容');
  });

  it('首轮没有推理项时，纯回答续轮省略工具目录并继续交付正文', async () => {
    responses = [
      { status: 200, body: sse(textResponse('你好')) },
      { status: 200, body: sse(textResponse('你好，有什么需要帮忙的？'), [{ type: 'response.output_text.delta', delta: '你好，' }, { type: 'response.output_text.delta', delta: '有什么需要帮忙的？' }]) },
    ];
    // 仅模拟供应商类型，网络与密钥仍使用当前用例的合成边界。
    const deepseek = { ...snapshot, provider: 'deepseek', model: 'deepseek-flash' };
    // 固定调用方目录用于检测适配器是否改写图运行器的请求身份。
    const originalTools = structuredClone(input.tools);
    // 首轮普通正文没有 reasoning 项，原始输出仍必须完整进入后续上下文。
    const first = await provider.complete('owner-test', deepseek, input);
    expect(first.output.map((item) => item.type)).toEqual(['message']);
    // 图运行器的工具目录保持原身份，适配器只调整本次出站请求。
    const continued = [...input.input, ...first.output, { role: 'developer', content: '请直接回答，不再调用工具。' }];
    // 纯回答仍需实际交付供应商的文本事件。
    const onDelta = jest.fn();
    await expect(provider.complete('owner-test', deepseek, { ...input, input: continued, toolChoice: 'none', onDelta })).resolves.toMatchObject({ text: '你好，有什么需要帮忙的？', functionCalls: [] });
    expect(payloads[0]).toMatchObject({ tool_choice: 'auto', tools: [{ ...tools[0], strict: false }] });
    expect(payloads[1]).not.toHaveProperty('tools');
    expect(payloads[1]).toMatchObject({ input: continued, tool_choice: 'none', stream: true, store: false });
    expect(payloads[1]).toHaveProperty('reasoning', { effort: 'none' });
    expect(onDelta.mock.calls).toEqual([['你好，'], ['有什么需要帮忙的？']]);
    expect(input.tools).toEqual(originalTools);
    expect(request).toHaveBeenCalledTimes(2);
  });

  it('纯回答阶段拒绝供应商意外返回原目录中的函数调用', async () => {
    responses = [{ status: 200, body: sse(callResponse()) }];
    await expect(provider.complete('owner-test', snapshot, { ...input, toolChoice: 'none' })).rejects.toMatchObject({ code: 'AI_INVALID_FUNCTION_CALL' });
    expect(payloads[0]).not.toHaveProperty('tools');
    expect(payloads[0]?.tool_choice).toBe('none');
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('供应商连接尚未结束时逐段交付正文，不等待完整回答', async () => {
    // 独立响应体允许测试控制每个网络片段的实际到达时机。
    const response = new EventEmitter() as IncomingMessage;
    // 模拟请求只连接上方内存响应，不访问任何供应商或密钥。
    const outgoing = new EventEmitter() as ClientRequest;
    outgoing.destroy = ((error?: Error): ClientRequest => {
      if (error) outgoing.emit('error', error);
      outgoing.emit('close');
      return outgoing;
    });
    jest.mocked(request).mockImplementation(((_url: URL, _options: RequestOptions, callback: (value: IncomingMessage) => void): ClientRequest => {
      outgoing.end = ((): ClientRequest => {
        response.statusCode = 200;
        callback(response);
        return outgoing;
      }) as ClientRequest['end'];
      return outgoing;
    }) as typeof request);
    // 在上游终态到达前观察正文回调，防止完整结果冒充实时流。
    const onDelta = jest.fn();
    // 完整模型结果必须等 response.completed 和 HTTP 结束。
    let completed = false;
    // 发送使用生产适配器，只有 HTTPS 网络驱动被替换。
    const pending = provider.complete('owner-test', snapshot, { ...input, onDelta }).then((result) => {
      completed = true;
      return result;
    });
    await new Promise<void>((resolve) => setImmediate(resolve));
    response.emit('data', Buffer.from('data: {"type":"response.output_text.delta","delta":"第一段"}\n\n'));
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(onDelta.mock.calls).toEqual([['第一段']]);
    expect(completed).toBe(false);
    response.emit('data', Buffer.from('data: {"type":"response.output_text.delta","delta":"第二段"}\n\n'));
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(onDelta.mock.calls).toEqual([['第一段'], ['第二段']]);
    expect(completed).toBe(false);
    response.emit('data', Buffer.from(sse(textResponse('第一段第二段'))));
    response.emit('end');
    outgoing.emit('close');
    await expect(pending).resolves.toMatchObject({ text: '第一段第二段' });
  });

  it('正文事件异步持久化严格有序，完整结果等待全部交付', async () => {
    responses = [{ status: 200, body: sse(textResponse('一二'), [{ type: 'response.output_text.delta', delta: '一' }, { type: 'response.output_text.delta', delta: '二' }]) }];
    // 独立完成闸门模拟第一条事件的数据库事务。
    let release: () => void = (): void => undefined;
    // 事件交付次序作为外部可观察结果。
    const delivered: string[] = [];
    // 第一条落库未完成前，第二条不能开始处理。
    const gate = new Promise<void>((resolve) => { release = resolve; });
    // 模型终态即使已经读完，也必须等待正文事件持久化。
    let completed = false;
    // 真实异步回调不会因 SSE 流结束而被丢弃。
    const pending = provider.complete('owner-test', snapshot, { ...input, onDelta: async (text): Promise<void> => { if (text === '一') await gate; delivered.push(text); } }).then((result) => { completed = true; return result; });
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(delivered).toEqual([]); expect(completed).toBe(false);
    release(); await pending;
    expect(delivered).toEqual(['一', '二']); expect(completed).toBe(true);
  });

  it('正文事件持久化失败时停止后续交付并隐藏回调敏感错误', async () => {
    responses = [{ status: 200, body: sse(textResponse('一二'), [{ type: 'response.output_text.delta', delta: '一' }, { type: 'response.output_text.delta', delta: '二' }]) }];
    // 模拟下游数据库错误，但不能把错误正文带入公开错误。
    const onDelta = jest.fn((): Promise<void> => Promise.reject(new Error('合成敏感错误 unit-only-key')));
    await expect(provider.complete('owner-test', snapshot, { ...input, onDelta })).rejects.toMatchObject({ code: 'AI_SUBMISSION_UNKNOWN', message: 'AI_SUBMISSION_UNKNOWN', uncertain: true });
    expect(onDelta).toHaveBeenCalledTimes(1); expect(request).toHaveBeenCalledTimes(1);
  });

  it.each(['failed', 'aborted', 'network', 'cancelled', 'closed'] as const)('%s 关闭交付队列并等待在途正文收尾才拒绝', async (kind) => {
    // 手动控制上游，确保第一段已经开始而第二段尚未进入回调。
    const transport = controlledTransport();
    // 用户取消与网络失败共用同一结算入口。
    const controller = new AbortController();
    // 阻塞真实异步回调，而不是只验证同步 mock 调用次数。
    let release!: () => void;
    // 每个 Promise 均在拒绝前安装处理器，避免未处理异常。
    const gate = new Promise<void>((resolve) => { release = resolve; });
    // 轨迹记录真正开始执行的正文回调。
    const delivered: string[] = [];
    // 外层不能在在途回调尚未收尾时提前通知运行器失败。
    let rejected = false;
    // 请求保持单次付费身份，测试不触发实际重试。
    const pending = provider.complete('owner-test', snapshot, { ...input, signal: controller.signal, onDelta: async (text): Promise<void> => { delivered.push(text); await gate; } });
    void pending.catch(() => { rejected = true; });
    await new Promise<void>((resolve) => setImmediate(resolve));
    transport.response.emit('data', Buffer.from('data: {"type":"response.output_text.delta","delta":"一"}\n\n'));
    await Promise.resolve();
    transport.response.emit('data', Buffer.from('data: {"type":"response.output_text.delta","delta":"二"}\n\n'));
    if (kind === 'failed') transport.response.emit('data', Buffer.from('data: {"type":"response.failed","response":{"usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}\n\n'));
    else if (kind === 'aborted') transport.response.emit('aborted');
    else if (kind === 'network') transport.outgoing.emit('error', new Error('合成敏感错误'));
    else if (kind === 'closed') transport.outgoing.emit('close');
    else controller.abort();
    await Promise.resolve();
    expect(rejected).toBe(false); expect(delivered).toEqual(['一']);
    release();
    await expect(pending).rejects.toMatchObject({ facts: { submission: 'unknown', retryable: false } });
    expect(delivered).toEqual(['一']); expect(request).toHaveBeenCalledTimes(1);
    if (kind === 'failed') await expect(pending).rejects.toMatchObject({ facts: { usage: { inputTokens: 3, outputTokens: 2, totalTokens: 5 } } });
  });

  it('只在完整成功终态返回完整函数参数，reasoning 不进入正文增量', async () => {
    // 不透明 reasoning 项仅为下一轮供应商协议续接保留。
    const reasoning = { id: 'rs_test', type: 'reasoning', summary: [{ type: 'summary_text', text: '内部资料' }], encrypted_content: 'synthetic-opaque' };
    // 最终对象含完整参数，中途参数片段绝不能变成工具执行。
    const final = callResponse();
    final.output = [reasoning, ...(final.output as Record<string, unknown>[])];
    responses = [{ status: 200, body: sse(final, [{ type: 'response.reasoning_text.delta', delta: '内部思考' }, { type: 'response.function_call_arguments.delta', delta: '{"query":' }]) }];
    // 可见文本回调不接触思维链、工具参数或密文续接资料。
    const onDelta = jest.fn();
    // 只有最终返回值才包含可交给业务 schema 校验的参数对象。
    const result = await provider.complete('owner-test', snapshot, { ...input, onDelta });
    expect(result.functionCalls).toEqual([{ id: 'fc_test', callId: 'call_test', name: 'search', arguments: { query: '学习' } }]);
    expect(result.output[0]).toEqual(reasoning);
    expect(onDelta).not.toHaveBeenCalled();
  });

  it.each([false, true])('助手按固定思考开关%s发送none或high', async (thinkingEnabled) => {
    await provider.complete('owner-test', { ...snapshot, thinkingEnabled }, input);
    expect(payloads[0]).toHaveProperty('reasoning', { effort: thinkingEnabled ? 'high' : 'none' });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('官方OpenAI开启思考时请求公开摘要，保持无状态续接协议', async () => {
    await provider.complete('owner-test', { ...snapshot, baseUrl: 'https://api.openai.com/v1', thinkingEnabled: true }, input);
    expect(payloads[0]).toHaveProperty('reasoning', { effort: 'high', summary: 'auto' });
    expect(payloads[0]).toHaveProperty('store', false);
    expect(payloads[0]).not.toHaveProperty('include');
  });

  it.each(['summary', 'content', 'streamOnly'] as const)('可读思考%s独立流式交付，终态及正文不混淆', async (kind) => {
    // 原始协议中的密文仍完整保留供下轮续接，但不进入思考回调。
    const reasoning = { id: 'rs_visible', type: 'reasoning', encrypted_content: 'private-cipher', ...(kind === 'summary' ? { summary: [{ type: 'summary_text', text: '先检查待办。' }] } : { content: [{ type: 'reasoning_text', text: '先检查待办。' }] }) };
    // 模拟既有终态格式，供应商可以只在增量中给出思考文字。
    const response = textResponse('这是最终答案。');
    if (kind !== 'streamOnly') response.output = [reasoning, ...(response.output as unknown[])];
    responses = [{ status: 200, body: sse(response, [{ type: kind === 'summary' ? 'response.reasoning_summary_text.delta' : 'response.reasoning_text.delta', item_id: 'rs_visible', delta: '先检查待办。' }, { type: 'response.output_text.delta', delta: '这是最终答案。' }]) }];
    // 两条交付通道分别记录，不能把思考当作答案或工具参数。
    const onDelta = jest.fn();
    // 思考交付使用累计快照，重复回补不会重复拼接。
    const onReasoning = jest.fn();
    const result = await provider.complete('owner-test', snapshot, { ...input, onDelta, onReasoning });
    expect(result).toMatchObject({ text: '这是最终答案。', reasoning: { text: '先检查待办。' } });
    expect(onDelta.mock.calls).toEqual([['这是最终答案。']]);
    expect(onReasoning).toHaveBeenLastCalledWith({ text: '先检查待办。' });
    expect(JSON.stringify(onReasoning.mock.calls)).not.toContain('private-cipher');
  });

  it.each(['failed', 'cancelled'] as const)('思考交付在%s后等待在途结束且不启动排队回调', async (kind) => {
    // 真正控制传输生命周期，避免同步mock掩盖迟到交付。
    const transport = controlledTransport();
    // 用户可在第一段思考落库期间取消。
    const controller = new AbortController();
    // 控制在途回调收尾，不通过睡眠猜测完成。
    let release!: () => void;
    // 取消或失败前已经启动的回调必须先完成。
    const gate = new Promise<void>((resolve) => { release = resolve; });
    // 只记录真正启动的回调。
    const delivered: string[] = [];
    const pending = provider.complete('owner-test', snapshot, { ...input, signal: controller.signal, onReasoning: async (value) => { delivered.push(value.text); await gate; } });
    void pending.catch(() => undefined);
    await new Promise<void>((resolve) => setImmediate(resolve));
    transport.response.emit('data', Buffer.from('data: {"type":"response.reasoning_text.delta","delta":"一"}\n\n'));
    await Promise.resolve();
    transport.response.emit('data', Buffer.from(`data: ${JSON.stringify({ type: 'response.reasoning_text.delta', delta: '二'.repeat(512) })}\n\n`));
    if (kind === 'failed') transport.response.emit('data', Buffer.from('data: {"type":"response.failed"}\n\n'));
    else controller.abort();
    release();
    await expect(pending).rejects.toMatchObject({ facts: { submission: 'unknown', retryable: false } });
    expect(delivered).toEqual(['一']);
    expect(request).toHaveBeenCalledTimes(1);
  });

  it.each(['{"query":', 'null', '[]', '"text"'])('拒绝损坏或非对象参数 %s', async (argumentsText) => {
    responses = [{ status: 200, body: sse(callResponse(argumentsText)) }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_INVALID_FUNCTION_CALL' });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('拒绝不在允许目录中的函数与重复 call_id', async () => {
    responses = [{ status: 200, body: sse(callResponse('{}', 'unauthorized_write')) }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_INVALID_FUNCTION_CALL' });
    // 第二种损坏响应故意重复同一调用身份。
    const duplicated = callResponse();
    duplicated.output = [...(duplicated.output as unknown[]), ...(duplicated.output as unknown[])];
    responses = [{ status: 200, body: sse(duplicated) }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_INVALID_FUNCTION_CALL' });
  });

  it('工具参数到达但缺少完整终态时标记未知提交，不自动重试', async () => {
    responses = [{ status: 200, body: 'data: {"type":"response.function_call_arguments.done","arguments":"{}"}\n\ndata: [DONE]\n\n' }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_SUBMISSION_UNKNOWN', uncertain: true });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it.each([
    [{ ...callResponse(), status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } }, 'AI_OUTPUT_TRUNCATED'],
    [{ ...callResponse(), status: 'failed', error: { message: '合成敏感正文 unit-only-key' } }, 'AI_PROVIDER_REJECTED'],
    [{ ...callResponse(), output: [] }, 'AI_EMPTY_OUTPUT'],
    [{ ...textResponse(), usage: undefined }, null],
  ])('验证 Responses 终态，不把部分结果当成成功 %#', async (response, code) => {
    responses = [{ status: 200, body: sse(response) }];
    if (code) await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code });
    else await expect(provider.complete('owner-test', snapshot, input)).resolves.toMatchObject({ usage: null });
  });

  it.each([[401, 'AI_AUTH_FAILED', false], [403, 'AI_AUTH_FAILED', false], [404, 'AI_MODEL_OR_URL_INVALID', false], [429, 'AI_RATE_LIMITED', false], [500, 'AI_SUBMISSION_UNKNOWN', true], [302, 'AI_PROVIDER_REJECTED', false]] as const)('HTTP %s只返回固定错误，不重试或跟随重定向', async (status, code, uncertain) => {
    responses = [{ status, body: '敏感供应商资料 unit-only-key' }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code, message: code, uncertain });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('拒绝混入私网的 DNS 解析，不解密密钥或发送模型请求', async () => {
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }, { address: '127.0.0.1', family: 4 }]);
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ response: { code: 'AI_PRIVATE_URL' } });
    expect(keys.decrypt).not.toHaveBeenCalled(); expect(request).not.toHaveBeenCalled();
  });

  it('配置在发送前或等待期间撤回时拒绝使用快照', async () => {
    profiles.assertAssistantProfileAvailable.mockRejectedValueOnce(new ConflictException({ code: 'AI_CONFIGURATION_UNAVAILABLE' }));
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toThrow(ConflictException);
    expect(request).not.toHaveBeenCalled();
    profiles.assertAssistantProfileAvailable.mockResolvedValueOnce().mockResolvedValueOnce().mockRejectedValueOnce(new ConflictException({ code: 'AI_CONFIGURATION_UNAVAILABLE' }));
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toThrow(ConflictException);
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('总超时、在途取消都保留未知提交身份，不重复请求', async () => {
    jest.useFakeTimers();
    try {
      responses = [{ status: 200, body: '', hanging: true }];
      // 在推进时钟前观察拒绝，避免未处理 Promise。
      const pending = expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_SUBMISSION_UNKNOWN', uncertain: true });
      await jest.advanceTimersByTimeAsync(60000); await pending;
      expect(request).toHaveBeenCalledTimes(1); expect(jest.getTimerCount()).toBe(0);
    } finally { jest.useRealTimers(); }
    responses = [{ status: 200, body: '', hanging: true }];
    // 独立信号模拟用户停止，允许 DNS 与两次配置校验先完成。
    const controller = new AbortController();
    // 请求发送后才取消，不能声称供应商未收费。
    const pending = expect(provider.complete('owner-test', snapshot, { ...input, signal: controller.signal })).rejects.toMatchObject({ code: 'AI_SUBMISSION_UNKNOWN', uncertain: true });
    await new Promise<void>((resolve) => setImmediate(resolve));
    controller.abort(); await pending;
    expect(currentRequest).toBeDefined(); expect(request).toHaveBeenCalledTimes(2);
  });

  it('流字节、单事件和可见正文都有界限', async () => {
    responses = [{ status: 200, body: 'data: ' + 'x'.repeat(2 * 1024 * 1024 + 1) }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_RESPONSE_TOO_LARGE' });
    responses = [{ status: 200, body: sse(textResponse('x'.repeat(80001))) }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_OUTPUT_TOO_LONG' });
  });

  it('固定两轮能力测试回传函数结果，真实检测正文增量', async () => {
    responses = [{ status: 200, body: sse(callResponse('{"text":"连接测试"}', 'assistant_capability_echo')) }, { status: 200, body: sse(textResponse('连接成功'), [{ type: 'response.output_text.delta', delta: '连接成功' }]) }];
    await expect(provider.testCapability('owner-test', snapshot)).resolves.toEqual({ ok: true, message: '助手流式回答与工具调用测试成功', capabilities: { version: 1, streaming: true, functionCalling: true, imageInput: 'unknown' } });
    expect(payloads[0]).toMatchObject({ tool_choice: { type: 'function', name: 'assistant_capability_echo' }, store: false });
    expect(payloads[1]).not.toHaveProperty('tools');
    expect(payloads[1]).toMatchObject({ tool_choice: 'none', input: expect.arrayContaining([{ type: 'function_call_output', call_id: 'call_test', output: '{"text":"连接测试"}' }]) });
    expect(request).toHaveBeenCalledTimes(2);
  });

  it('只有完整正文而没有流事件时能力测试不能误报通过', async () => {
    responses = [{ status: 200, body: sse(callResponse('{"text":"连接测试"}', 'assistant_capability_echo')) }, { status: 200, body: sse(textResponse('连接成功')) }];
    await expect(provider.testCapability('owner-test', snapshot)).rejects.toMatchObject({ code: 'AI_STREAMING_UNSUPPORTED' });
  });

  it.each([
    ['rate_limit_exceeded', 'rate_limit_error', true],
    ['insufficient_quota', 'rate_limit_error', false],
    ['vendor_unknown', 'rate_limit_error', false],
  ])('完整429仅明确临时限流可重试：%s', async (code, type, retryable) => {
    responses = [{ status: 429, body: JSON.stringify({ error: { code, type, message: '合成敏感原文' } }), headers: { 'x-request-id': 'req_test-123', 'retry-after': '2' } }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: code === 'insufficient_quota' ? 'AI_QUOTA_EXHAUSTED' : 'AI_RATE_LIMITED', uncertain: false, facts: { submission: 'rejected', retryable, httpStatus: 429, providerRequestId: 'req_test-123', retryAfterMs: 2000 } });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('未完整收到429与5xx始终未知，不因限流形状自动重试', async () => {
    // 429 必须完整结束，否则不能证明是完整拒绝。
    const transport = controlledTransport(429);
    // 尽早安装拒绝处理器，随后故意模拟连接中断。
    const pending = expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ facts: { submission: 'unknown', retryable: false, httpStatus: 429 } });
    await new Promise<void>((resolve) => setImmediate(resolve));
    transport.response.emit('data', Buffer.from('{"error":{"code":"rate_limit_exceeded"}}'));
    transport.response.emit('aborted'); await pending;
  });

  it.each([
    [400, 'context_length_exceeded', 'AI_CONTEXT_TOO_LARGE', 'rejected'],
    [400, 'context_window_exceeded', 'AI_CONTEXT_TOO_LARGE', 'rejected'],
    [429, 'insufficient_quota', 'AI_QUOTA_EXHAUSTED', 'rejected'],
    [400, 'unsupported_parameter', 'AI_INVALID_REQUEST', 'rejected'],
    [500, 'context_length_exceeded', 'AI_SUBMISSION_UNKNOWN', 'unknown'],
  ])('完整HTTP错误仅从受限code分类：%s/%s', async (status, providerCode, code, submission) => {
    responses = [{ status, body: JSON.stringify({ error: { code: providerCode, message: '合成敏感原文' } }) }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code, facts: { submission, retryable: false } });
  });

  it.each([false, true])('Responses上下文拒绝有生成增量=%s时保留准确提交边界', async (partial) => {
    // 工具参数增量与可见正文同样属于模型已工作证据。
    const prefix = partial ? 'data: {"type":"response.function_call_arguments.delta","delta":"{"}\n\n' : '';
    responses = [{ status: 200, body: prefix + 'data: {"type":"response.failed","response":{"error":{"code":"context_length_exceeded","message":"合成敏感原文"}}}\n\n' }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_CONTEXT_TOO_LARGE', facts: { submission: partial ? 'unknown' : 'rejected', retryable: false } });
  });

  it('DNS前置失败可明确未提交，TLS前连接拒绝与握手后断线区别处理', async () => {
    jest.mocked(resolveAiAddresses).mockRejectedValueOnce(new Error('合成 DNS 故障'));
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_DNS_FAILED', uncertain: false, facts: { submission: 'notSubmitted', retryable: true } });
    expect(request).not.toHaveBeenCalled();
    // 未连接的 TLS 对象只用于阶段事件，从不调用 connect。
    const socket = new TLSSocket(new Socket());
    // 每个阶段使用相同合成网络错误，区别仅来自握手事实。
    const connectionError = Object.assign(new Error('合成拒绝'), { code: 'ECONNREFUSED' });
    try {
      // 不发送响应头，模拟应用请求仍被 HTTPS 握手门禁缓冲。
      const outgoing = new EventEmitter() as ClientRequest;
      outgoing.destroy = ((): ClientRequest => { outgoing.emit('close'); return outgoing; });
      outgoing.end = ((): ClientRequest => { outgoing.emit('socket', socket); outgoing.emit('error', connectionError); return outgoing; }) as ClientRequest['end'];
      jest.mocked(request).mockReturnValue(outgoing);
      await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_CONNECTION_FAILED', uncertain: false, facts: { submission: 'notSubmitted', retryable: true } });
      // 握手一旦完成，请求是否计费不能再从同一错误码推断。
      outgoing.end = ((): ClientRequest => { outgoing.emit('socket', socket); socket.emit('secureConnect'); outgoing.emit('error', connectionError); return outgoing; }) as ClientRequest['end'];
      await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ facts: { submission: 'unknown', retryable: false } });
    } finally { socket.destroy(); }
  });

  it('完整请求预算在出站前执行，包含中文JSON字节', async () => {
    // 小预算使测试无需分配真实二十兆附件。
    const bounded = { ...snapshot, compatibility: { ...assistantCompatibility(), maxRequestBytes: 1024 } };
    await expect(provider.complete('owner-test', bounded, { ...input, input: [{ role: 'user', content: '中文'.repeat(300) }] })).rejects.toMatchObject({ code: 'AI_INPUT_TOO_LARGE', facts: { submission: 'notSubmitted', retryable: false } });
    expect(request).not.toHaveBeenCalled();
  });

  it('DNS和校验耗尽总预算后不创建模型HTTP请求', async () => {
    // 合成时钟只推进预处理时长，不产生任何真实等待。
    const now = jest.spyOn(Date, 'now').mockReturnValue(0);
    jest.mocked(resolveAiAddresses).mockImplementationOnce(async () => {
      now.mockReturnValue(60001);
      await Promise.resolve();
      return [{ address: '8.8.8.8', family: 4 }];
    });
    try {
      await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_RETRY_BUDGET_EXHAUSTED', facts: { submission: 'notSubmitted', retryable: false } });
      expect(request).not.toHaveBeenCalled();
    } finally { now.mockRestore(); }
  });

  it('完整4xx携带生成用量时仍不允许自动压缩或重试', async () => {
    responses = [{ status: 400, body: JSON.stringify({ error: { code: 'context_length_exceeded' }, usage: { input_tokens: 3, output_tokens: 2, total_tokens: 5 } }) }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ code: 'AI_CONTEXT_TOO_LARGE', facts: { submission: 'unknown', retryable: false, usage: { inputTokens: 3, outputTokens: 2, totalTokens: 5 } } });
  });

  it.each(['priorUsage', 'outputItem', 'failedOutput'] as const)('失败前已有%s证据时不能因最后事件缺delta误判安全', async (kind) => {
    // 三种非正文证据都证明不能承诺模型尚未开始处理。
    const prefix = kind === 'priorUsage' ? 'data: {"type":"response.in_progress","response":{"usage":{"input_tokens":3,"output_tokens":0,"total_tokens":3}}}\n\n' : kind === 'outputItem' ? 'data: {"type":"response.output_item.added","item":{"type":"reasoning"}}\n\n' : '';
    // 失败终态不复述此前用量，验证适配器没有丢掉已知证据。
    const response = { error: { code: 'context_length_exceeded' }, ...(kind === 'failedOutput' ? { output: [{ type: 'reasoning' }] } : {}) };
    responses = [{ status: 200, body: prefix + `data: ${JSON.stringify({ type: 'response.failed', response })}\n\n` }];
    await expect(provider.complete('owner-test', snapshot, input)).rejects.toMatchObject({ facts: { submission: 'unknown', retryable: false } });
  });

  it.each(['supported', 'unsupported'] as const)('文本工具测试保留配置声明%s且不发送图片探测', async (imageInput) => {
    responses = [{ status: 200, body: sse(callResponse('{"text":"连接测试"}', 'assistant_capability_echo')) }, { status: 200, body: sse(textResponse('连接成功'), [{ type: 'response.output_text.delta', delta: '连接成功' }]) }];
    await expect(provider.testCapability('owner-test', { ...snapshot, compatibility: { ...assistantCompatibility(), imageInput } })).resolves.toMatchObject({ message: '助手流式回答与工具调用测试成功', capabilities: { imageInput } });
    expect(request).toHaveBeenCalledTimes(2);
    expect(JSON.stringify(payloads)).not.toContain('input_image');
    expect(JSON.stringify(payloads)).not.toContain('data:image');
  });

  it('旧图片快照在当前多模态关闭后不能出站，不创建付费请求', async () => {
    // 模拟旧任务已经持有supported，第二次当前配置核验发现开关关闭。
    const image = createAssistantImagePart('old-image', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/b6cAAAAASUVORK5CYII=');
    profiles.assertAssistantProfileAvailable.mockResolvedValueOnce().mockRejectedValueOnce(new AiProviderError('AI_IMAGE_INPUT_UNSUPPORTED'));
    await expect(provider.complete('owner-test', { ...snapshot, compatibility: { ...assistantCompatibility(), imageInput: 'supported' } }, { ...input, input: [{ role: 'user', content: [image] }] })).rejects.toMatchObject({ code: 'AI_IMAGE_INPUT_UNSUPPORTED', facts: { submission: 'notSubmitted', retryable: false } });
    expect(profiles.assertAssistantProfileAvailable).toHaveBeenLastCalledWith('owner-test', expect.any(Object), true);
    expect(request).not.toHaveBeenCalled();
  });

  it('拒绝未hydrate图片以及未知模型图像输入，不发送外部URL', async () => {
    await expect(provider.complete('owner-test', snapshot, { ...input, input: [{ role: 'user', content: [{ type: 'input_image', image_url: 'https://private.example.test/image' }] }] })).rejects.toMatchObject({ code: 'AI_INVALID_IMAGE_INPUT', facts: { submission: 'notSubmitted' } });
    // 固定 PNG 只校验输入品牌，不调用任何图像服务。
    const image = createAssistantImagePart('test-image', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/b6cAAAAASUVORK5CYII=');
    await expect(provider.complete('owner-test', snapshot, { ...input, input: [{ role: 'user', content: [image] }] })).rejects.toMatchObject({ code: 'AI_IMAGE_INPUT_UNSUPPORTED' });
    expect(request).not.toHaveBeenCalled();
    await expect(provider.complete('owner-test', { ...snapshot, compatibility: { ...assistantCompatibility(), imageInput: 'supported' } }, { ...input, input: [{ role: 'user', content: [image] }] })).resolves.toMatchObject({ text: '已完成查询。' });
    expect(JSON.stringify(payloads[0])).not.toContain('test-image');
  });
});

describe('助手配置撤回的同事务保护', () => {
  /// 所有存储均为合成边界，正式服务负责判定何时撤回。
  const userId = 'owner-test';
  /// 密钥轮换前后使用不同合成密文，不读实际加密文件。
  const profile = { id: 'profile-test', userId, revision: 3, provider: 'custom', name: '模型', model: 'unit-model', baseUrl: 'https://model.example.test/v1', encryptedApiKey: 'old-cipher', createdAt: new Date(0) };
  /// 可观察共享事务边界。
  let transaction: {
    $queryRaw: jest.Mock;
    aiProfile: { findFirst: jest.Mock; update: jest.Mock; deleteMany: jest.Mock; findMany: jest.Mock };
    aiSettings: { upsert: jest.Mock; findUniqueOrThrow: jest.Mock; update: jest.Mock };
    assistantSettings: { updateMany: jest.Mock };
    assistantRun: { findMany: jest.Mock; updateMany: jest.Mock };
    assistantTask: { updateMany: jest.Mock };
    mcpAction: { updateMany: jest.Mock };
  };
  /// 当前测试使用的正式配置服务。
  let service: AiService;

  beforeEach(() => {
    transaction = {
      $queryRaw: jest.fn().mockResolvedValue([]),
      aiProfile: { findFirst: jest.fn().mockResolvedValue({ ...profile }), update: jest.fn().mockResolvedValue({ ...profile, revision: 4 }), deleteMany: jest.fn().mockResolvedValue({ count: 1 }), findMany: jest.fn().mockResolvedValue([]) },
      aiSettings: { upsert: jest.fn().mockResolvedValue({ revision: 0, activeProfileId: null, notePolishEnabled: false }), findUniqueOrThrow: jest.fn().mockResolvedValue({ activeProfileId: null }), update: jest.fn().mockResolvedValue({}) },
      assistantSettings: { updateMany: jest.fn().mockResolvedValue({ count: 1 }) },
      assistantRun: { findMany: jest.fn().mockResolvedValue([{ id: 'run-a', taskId: 'task-a' }, { id: 'run-b', taskId: 'task-a' }]), updateMany: jest.fn().mockResolvedValue({ count: 2 }) },
      assistantTask: { updateMany: jest.fn().mockResolvedValue({ count: 1 }) },
      mcpAction: { updateMany: jest.fn().mockResolvedValue({ count: 1 }) },
    };
    // 每个事务回调都收到同一存储对象，便于检查原子撤回。
    const prisma = { $transaction: (work: (value: unknown) => Promise<unknown>): Promise<unknown> => work(transaction) } as unknown as PrismaService;
    service = new AiService(prisma, { encrypt: (): string => 'replacement-cipher' } as unknown as AiKeyStore, {} as AiProvider);
  });

  it.each([{ apiKey: 'replacement-key' }, { removeApiKey: true }])('替换或清除密钥取消旧任务及待执行动作 %#', async (change) => {
    await service.saveProfile(userId, { revision: 0, name: profile.name, provider: 'custom', model: profile.model, baseUrl: profile.baseUrl, ...change }, profile.id);
    expect(transaction.assistantSettings.updateMany).toHaveBeenCalledWith({ where: { userId, profileId: profile.id }, data: { enabled: false, revision: { increment: 1 } } });
    expect(transaction.mcpAction.updateMany).toHaveBeenCalledWith({ where: { userId, source: 'assistant', sourceId: { in: ['task-a'] }, status: 'pending' }, data: { status: 'cancelled' } });
    expect(transaction.assistantTask.updateMany).toHaveBeenCalledWith(expect.objectContaining({ data: { status: 'cancelled', approvedHash: null } }));
    expect(transaction.assistantRun.updateMany).toHaveBeenCalledWith(expect.objectContaining({ data: expect.objectContaining({ status: 'cancelled', leaseOwner: null, leaseUntil: null, errorCode: 'AI_CONFIGURATION_UNAVAILABLE' }) }));
    expect(transaction.$queryRaw).toHaveBeenCalledTimes(1);
  });

  it('删除配置清除助手选择，普通名称编辑不撤回任务', async () => {
    await service.deleteProfile(userId, profile.id, 0);
    expect(transaction.assistantSettings.updateMany).toHaveBeenCalledWith({ where: { userId, profileId: profile.id }, data: { enabled: false, revision: { increment: 1 }, profileId: null } });
    transaction.assistantRun.findMany.mockClear(); transaction.assistantSettings.updateMany.mockClear();
    await service.saveProfile(userId, { revision: 0, name: '新名称', provider: 'custom', model: profile.model, baseUrl: profile.baseUrl }, profile.id);
    expect(transaction.assistantRun.findMany).not.toHaveBeenCalled(); expect(transaction.assistantSettings.updateMany).not.toHaveBeenCalled();
  });
});

describe('助手独立配置快照', () => {
  /// 所有资料都是合成数据库行，不创建真实加密文件。
  const profile = { id: 'profile-test', revision: 3, provider: 'custom', model: 'unit-model', baseUrl: 'https://model.example.test/v1/responses', encryptedApiKey: 'synthetic-cipher' };
  /// 查询替身记录 owner 条件，禁止直接用 UUID 读取配置。
  const findFirst = jest.fn();
  /// 只提供本组测试使用的数据库入口。
  const prisma = { aiProfile: { findFirst } } as unknown as PrismaService;
  /// 配置读取与可用性检查不需要解密密钥。
  const service = new AiService(prisma, {} as AiKeyStore, {} as AiProvider);
  beforeEach(() => { findFirst.mockReset(); findFirst.mockResolvedValue(profile); });

  it('固定profile版本及密文，按归属查询且不依赖笔记开关', async () => {
    expect(await service.captureAssistantProfile('owner-test', profile.id)).toEqual({ profileId: profile.id, profileRevision: 3, provider: 'custom', model: 'unit-model', baseUrl: 'https://model.example.test/v1', encryptedApiKey: 'synthetic-cipher', thinkingEnabled: false, compatibility: { ...assistantCompatibility(), imageInput: 'unsupported' } });
    expect(findFirst).toHaveBeenCalledWith({ where: { id: profile.id, userId: 'owner-test' } });
  });

  it('配置不存在、未配置密钥均明确拒绝', async () => {
    findFirst.mockResolvedValueOnce(null);
    await expect(service.captureAssistantProfile('other-owner', profile.id)).rejects.toThrow(NotFoundException);
    findFirst.mockResolvedValueOnce({ ...profile, encryptedApiKey: null });
    await expect(service.captureAssistantProfile('owner-test', profile.id)).rejects.toMatchObject({ response: { code: 'AI_PROFILE_REQUIRED' } });
  });

  it('普通配置修订保留原目标，删除或替换密钥使快照失效', async () => {
    // 固定任务版本不随之后的普通配置编辑改变。
    const snapshot = await service.captureAssistantProfile('owner-test', profile.id);
    findFirst.mockResolvedValueOnce({ ...profile, revision: 4 });
    await expect(service.assertAssistantProfileAvailable('owner-test', snapshot)).resolves.toBeUndefined();
    for (const current of [null, { encryptedApiKey: null }, { encryptedApiKey: 'replacement-cipher' }]) {
      findFirst.mockResolvedValueOnce(current);
      await expect(service.assertAssistantProfileAvailable('owner-test', snapshot)).rejects.toThrow(ConflictException);
    }
  });

  it('图片出站必须核对当前多模态开关，关闭不影响纯文字请求', async () => {
    // 旧运行快照可能来自历史测试，不能替代当前配置开关。
    const snapshot = await service.captureAssistantProfile('owner-test', profile.id);
    findFirst.mockResolvedValueOnce({ ...profile, multimodal: false });
    await expect(service.assertAssistantProfileAvailable('owner-test', snapshot, true)).rejects.toMatchObject({ code: 'AI_IMAGE_INPUT_UNSUPPORTED' });
    findFirst.mockResolvedValueOnce({ ...profile, multimodal: true });
    await expect(service.assertAssistantProfileAvailable('owner-test', snapshot, true)).resolves.toBeUndefined();
    findFirst.mockResolvedValueOnce({ ...profile, multimodal: false });
    await expect(service.assertAssistantProfileAvailable('owner-test', snapshot)).resolves.toBeUndefined();
  });
});
