import { ConfigService } from '@nestjs/config';
import { BadRequestException } from '@nestjs/common';
import { EventEmitter } from 'node:events';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { request } from 'node:https';
import type { ClientRequest, IncomingMessage, RequestOptions } from 'node:http';
import { resolveAiAddresses } from '../src/ai/ai-dns';
import { AiKeyStore } from '../src/ai/ai-key-store';
import { AI_PRESETS, AiProvider, aiFailure, isPublicAiAddress, normalizeAiBaseUrl } from '../src/ai/ai-provider';
import type { NotePolishContext } from '../src/ai/ai-provider';

jest.mock('node:https', () => ({ request: jest.fn() }));
jest.mock('../src/ai/ai-dns', () => ({ resolveAiAddresses: jest.fn() }));

/// 生成标准非流式 Responses 助手消息，全部正文均为合成数据。
function completedResponse(content: unknown = [{ type: 'output_text', text: '今天记录了 3 件事情，不确定是否完成。' }]): Record<string, unknown> {
  return { object: 'response', status: 'completed', error: null, incomplete_details: null, output: [{ type: 'message', role: 'assistant', status: 'completed', content }] };
}

describe('AI Responses 公网协议与正文边界', () => {
  /// 有效模型输入不包含真实用户数据或凭据。
  const input = { provider: 'custom', baseUrl: 'https://model.example.test/prefix/v1', model: 'unit-model', apiKey: 'unit-only-key' };
  /// Stable recorded time used to verify dynamic polish instructions.
  const noteContext: NotePolishContext = { dayKey: '2026-10-31', recordTimeSeconds: 14 * 3600 + 5 * 60 + 59, utcOffsetMinutes: 480 };
  /// 最近一次固定网络地址，验证请求时不再次解析 DNS。
  let sentOptions: RequestOptions;
  /// 本次实际请求的模型端点。
  let sentUrl: URL;
  /// 最近一次模型请求正文，用于验证原文与提示词隔离。
  let sentPayload: string;
  /// 响应状态与正文只来自测试夹具。
  let status: number;
  /// Responses 对象只来自测试夹具。
  let body: unknown;
  /// 用于模拟损坏 JSON 或响应大小超限的原始 HTTP 正文。
  let rawBody: string | undefined;
  /// 未完成响应用于验证总超时与取消，不连接真实供应商。
  let hanging: boolean;

  beforeEach(() => {
    jest.clearAllMocks(); status = 200; body = completedResponse(); rawBody = undefined; hanging = false;
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }]);
    jest.mocked(request).mockImplementation(((url: URL, options: RequestOptions, callback: (response: IncomingMessage) => void): ClientRequest => {
      sentOptions = options;
      sentUrl = url;
      // 事件模拟保留真实请求的结束、错误与关闭生命周期。
      const outgoing = new EventEmitter() as ClientRequest;
      outgoing.destroy = ((error?: Error): ClientRequest => { if (error) outgoing.emit('error', error); outgoing.emit('close'); return outgoing; });
      options.signal?.addEventListener('abort', () => outgoing.destroy(new Error('合成取消信号')), { once: true });
      outgoing.end = ((payload: string): ClientRequest => {
        sentPayload = payload;
        if (hanging) return outgoing;
        // 响应只有有限字节，不使用实际外部网络。
        const response = new EventEmitter() as IncomingMessage;
        response.statusCode = status;
        callback(response);
        response.emit('data', Buffer.from(rawBody ?? JSON.stringify(body)));
        response.emit('end'); outgoing.emit('close');
        return outgoing;
      }) as ClientRequest['end'];
      return outgoing;
    }) as typeof request);
  });

  it('保留自定义路径，基址与完整 responses 地址只拼接一次', async () => {
    expect(normalizeAiBaseUrl(' https://example.com/prefix/v1/responses/ ')).toBe('https://example.com/prefix/v1');
    expect(normalizeAiBaseUrl('https://example.com/')).toBe('https://example.com');
    await new AiProvider().test({ ...input, baseUrl: `${input.baseUrl}/responses/` });
    expect(sentUrl.pathname).toBe('/prefix/v1/responses');
  });

  it.each(['http://example.com', 'https://user:key@example.com', 'https://example.com?a=1', 'https://example.com/#a', 'https://localhost/v1', 'https://127.0.0.1', 'https://[::1]', 'https://example.com/v1/chat/completions', 'https://example.com/v1/chat/completions/', 'https://example.com/v1/%63hat/completions'])('拒绝危险 URL 或旧协议地址 %s', (url) => {
    expect(() => normalizeAiBaseUrl(url)).toThrow(BadRequestException);
  });

  it.each(['0.0.0.0', '10.1.2.3', '100.64.1.1', '127.0.0.1', '169.254.169.254', '172.16.0.1', '192.168.0.1', '198.18.0.1', '224.0.0.1', '::1', '::ffff:127.0.0.1', 'fe80::1', 'fc00::1', '2001:db8::1', '2001:0db8::1', '2001:1::1', '2002:7f00:1::', '3fff::1'])('拒绝非公网解析 %s', (address) => {
    expect(isPublicAiAddress(address)).toBe(false);
  });

  it('公网地址可用，并把解析结果固定到本次 TLS 连接', async () => {
    expect(isPublicAiAddress('8.8.8.8')).toBe(true); expect(isPublicAiAddress('2606:4700:4700::1111')).toBe(true);
    // 原文中的否定、数字和不确定表达完整进入数据消息。
    const source = '嗯，今天，今天 3 件事情，不确定，不确定是否完成。';
    expect(await new AiProvider().polish(input, source, noteContext)).toContain('3');
    expect(sentUrl.pathname).toBe('/prefix/v1/responses');
    expect(JSON.parse(sentPayload)).toEqual({ model: input.model, instructions: expect.stringContaining('不得推断补充事实'), input: source, max_output_tokens: 12000, stream: false, store: false, reasoning: { effort: 'none' } });
    // 正式请求必须同时表达通顺改写、卡顿清理和保留有意义限定，不能只做删词。
    const instructions = (JSON.parse(sentPayload) as { instructions: string }).instructions;
    expect(instructions).toContain('通顺的文章或笔记');
    expect(instructions).toContain('卡顿词、结巴、机械重复、反复起句');
    expect(instructions).toContain('允许调整语序、整合零碎句子');
    expect(instructions).toContain('仅在不承载实际含义时删除');
    expect(instructions).toContain('不能把猜测写成定论');
    expect(instructions).toContain('不得把完整记录缩成摘要');
    expect(instructions).toContain('当前笔记记录时间：2026年10月31日 14时05分（UTC+08:00）');
    expect(instructions).toContain('第一行必须直接是这篇笔记的简洁标题');
    expect(instructions).toContain('标题后空一行');
    expect(instructions).toContain('日报 - 2026年10月31日');
    expect(instructions).toContain('一般的当日工作记录不得推测为日报');
    // 验证 lookup 不使用未校验的新 DNS 结果。
    const callback = jest.fn();
    sentOptions.lookup!('model.example.test', {}, callback);
    expect(callback).toHaveBeenCalledWith(null, '8.8.8.8', 4);
    // Node 新版本可能请求全部地址，仍只能得到已固定的唯一公网地址。
    const allCallback = jest.fn();
    sentOptions.lookup!('model.example.test', { all: true }, allCallback);
    expect(allCallback).toHaveBeenCalledWith(null, [{ address: '8.8.8.8', family: 4 }]);
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('记录时间精确到分钟并保留负的非整小时 UTC 偏移', async () => {
    // Seconds are omitted, natural dates are unpadded, and clock fields remain padded.
    const context: NotePolishContext = { dayKey: '2026-01-02', recordTimeSeconds: 3 * 3600 + 4 * 60 + 59, utcOffsetMinutes: -330 };
    await new AiProvider().polish(input, '这是一篇日报。', context);
    // Recorded time belongs only to instructions and must not alter transcript input.
    const payload = JSON.parse(sentPayload) as { instructions: string; input: string };
    expect(payload.instructions).toContain('当前笔记记录时间：2026年1月2日 03时04分（UTC-05:30）');
    expect(payload.instructions).toContain('日报 - 2026年1月2日');
    expect(payload.input).toBe('这是一篇日报。');
    expect(payload.input).not.toContain('2026年1月2日 03时04分');
  });

  it.each(AI_PRESETS)('$provider 入口只发送 Responses 字段及对应推理参数', async (preset) => {
    // 自定义服务地址和模型仍由用户填写。
    const current = { ...input, provider: preset.provider, baseUrl: preset.baseUrl || input.baseUrl, model: preset.model || input.model };
    await expect(new AiProvider().test(current)).resolves.toEqual({ ok: true, message: '模型服务连接成功' });
    expect(sentUrl.toString()).toBe(`${current.baseUrl}/responses`);
    expect(JSON.parse(sentPayload)).toEqual({ model: current.model, instructions: '只回复“连接成功”。', input: '连接测试', max_output_tokens: 256, stream: false, store: false, reasoning: { effort: 'none' } });
    expect(sentOptions.headers).toMatchObject({ authorization: `Bearer ${input.apiKey}`, 'content-length': Buffer.byteLength(sentPayload) });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it.each(AI_PRESETS)('$provider 开启思考后连接测试和笔记整理均发送high，不额外探测', async (preset) => {
    // 只改变用户开关，其余仍走真实Responses序列化与模拟HTTPS。
    const current = { ...input, provider: preset.provider, baseUrl: preset.baseUrl || input.baseUrl, thinkingEnabled: true };
    await new AiProvider().test(current);
    expect(JSON.parse(sentPayload)).toMatchObject({ reasoning: { effort: 'high' }, max_output_tokens: 2048 });
    await new AiProvider().polish(current, '待整理正文', noteContext);
    expect(JSON.parse(sentPayload)).toMatchObject({ reasoning: { effort: 'high' }, max_output_tokens: 12000 });
    expect(request).toHaveBeenCalledTimes(2);
  });

  it('官方预设使用新的 Responses 基址和默认模型', () => {
    expect(AI_PRESETS).toEqual([
      { provider: 'zhipu', name: '智谱', baseUrl: 'https://open.bigmodel.cn/api/v1', model: 'glm-5.3' },
      { provider: 'deepseek', name: 'DeepSeek', baseUrl: 'https://api.deepseek.com', model: 'deepseek-flash' },
      { provider: 'custom', name: '自定义 Responses API 服务', baseUrl: '', model: '' },
    ]);
  });

  it('按序拼接助手文本块和消息，思维链及工具项不进入正文', async () => {
    body = { ...completedResponse(), output_text: '不得使用的SDK辅助字段', output: [
      { type: 'reasoning', summary: [{ type: 'summary_text', text: '内部思考' }] },
      { type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: '今天 ' }, { type: 'output_text', text: '3 件事。' }] },
      { type: 'function_call', arguments: '不得进入正文' },
      { type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: '尚未确认。' }] },
    ] };
    await expect(new AiProvider().polish(input, '合成原文', noteContext)).resolves.toBe('今天 3 件事。\n\n尚未确认。');
  });

  it('智谱支持官方单对象正文，其他服务仍要求标准内容数组', async () => {
    body = completedResponse({ type: 'output_text', text: '智谱整理正文' });
    await expect(new AiProvider().polish({ ...input, provider: 'zhipu' }, '原文', noteContext)).resolves.toBe('智谱整理正文');
    await expect(new AiProvider().polish(input, '原文', noteContext)).rejects.toMatchObject({ code: 'AI_INVALID_RESPONSE' });
  });

  it('同一域名出现任意私网解析时拒绝发送', async () => {
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }, { address: '127.0.0.1', family: 4 }]);
    await expect(new AiProvider().polish(input, '文本', noteContext)).rejects.toThrow(BadRequestException);
    expect(request).not.toHaveBeenCalled();
  });

  it('DoH失败时不发送模型Key，也不将解析失败标记为已计费', async () => {
    jest.mocked(resolveAiAddresses).mockRejectedValue(new Error('敏感网络详情'));
    await expect(new AiProvider().test(input)).rejects.toMatchObject({ code: 'AI_DNS_FAILED', uncertain: false });
    expect(request).not.toHaveBeenCalled();
  });

  it('上层取消信号传入DoH解析，模型连接禁用全局连接池', async () => {
    // 独立取消控制器只用于测试。
    const controller = new AbortController();
    await new AiProvider().polish(input, '文本', noteContext, controller.signal);
    expect(resolveAiAddresses).toHaveBeenCalledWith('model.example.test', controller.signal);
    expect(sentOptions.agent).toBe(false);
  });

  it.each([
    [{ ...completedResponse(), status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } }, 'AI_OUTPUT_TRUNCATED'],
    [{ ...completedResponse(), status: 'incomplete', incomplete_details: { reason: 'content_filter' } }, 'AI_PROVIDER_REJECTED'],
    [{ ...completedResponse(), status: 'failed', error: { message: '敏感服务商详情' } }, 'AI_PROVIDER_REJECTED'],
    [{ ...completedResponse(), error: { message: '不能采用同时携带的部分正文' } }, 'AI_PROVIDER_REJECTED'],
    [{ ...completedResponse(), status: 'in_progress' }, 'AI_INVALID_RESPONSE'],
    [{ ...completedResponse(), status: 'queued' }, 'AI_INVALID_RESPONSE'],
    [{ ...completedResponse(), status: undefined }, 'AI_INVALID_RESPONSE'],
    [{ ...completedResponse(), output: [{ type: 'message', role: 'assistant', status: 'incomplete', content: [{ type: 'output_text', text: '部分正文' }] }] }, 'AI_OUTPUT_TRUNCATED'],
    [completedResponse([{ type: 'refusal', refusal: '拒绝回答' }]), 'AI_PROVIDER_REJECTED'],
    [completedResponse([{ type: 'output_text', text: '有效片段' }, { type: 'refusal', refusal: '仍然拒绝' }]), 'AI_PROVIDER_REJECTED'],
    [completedResponse([{ type: 'output_text', text: '  ' }]), 'AI_EMPTY_OUTPUT'],
    [completedResponse([{ type: 'output_text', text: '字'.repeat(20001) }]), 'AI_OUTPUT_TOO_LONG'],
    [completedResponse([{ type: 'output_text', text: 123 }]), 'AI_INVALID_RESPONSE'],
    [completedResponse([null]), 'AI_INVALID_RESPONSE'],
    [completedResponse('文本不能代替内容数组'), 'AI_INVALID_RESPONSE'],
    [{ ...completedResponse(), output: [] }, 'AI_EMPTY_OUTPUT'],
    [{ ...completedResponse(), output: null, output_text: '辅助字段不作为降级' }, 'AI_INVALID_RESPONSE'],
    [{ ...completedResponse(), output: [null] }, 'AI_INVALID_RESPONSE'],
    [{ choices: [{ finish_reason: 'stop', message: { content: '旧协议正文' } }] }, 'AI_INVALID_RESPONSE'],
    [null, 'AI_INVALID_RESPONSE'],
    [[], 'AI_INVALID_RESPONSE'],
  ])('不采用失败、拒绝、不完整或非Responses结果 %#', async (response, code) => {
    body = response;
    await expect(new AiProvider().polish(input, '原文', noteContext)).rejects.toMatchObject({ code });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('损坏JSON只返回固定错误，不泄漏正文与密钥', async () => {
    rawBody = `损坏的JSON ${input.apiKey}`;
    await expect(new AiProvider().test(input)).rejects.toMatchObject({ code: 'AI_INVALID_RESPONSE', message: 'AI_INVALID_RESPONSE' });
    expect(JSON.stringify(aiFailure(new Error(input.apiKey)).getResponse())).not.toContain(input.apiKey);
  });

  it('达到正文长度边界的完整内容仍可采用', async () => {
    body = completedResponse([{ type: 'output_text', text: '字'.repeat(20000) }]);
    await expect(new AiProvider().polish(input, '原文', noteContext)).resolves.toHaveLength(20000);
  });

  it('响应超过字节上限时中断请求，不自动重试', async () => {
    rawBody = 'x'.repeat(1024 * 1024 + 1);
    await expect(new AiProvider().test(input)).rejects.toMatchObject({ code: 'AI_RESPONSE_TOO_LARGE' });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('总超时视作未知提交，保持单次调用边界', async () => {
    jest.useFakeTimers();
    try {
      hanging = true;
      // 在推进时间前观察拒绝，避免测试制造未处理异常。
      const pending = expect(new AiProvider().test(input)).rejects.toMatchObject({ code: 'AI_TIMEOUT', uncertain: true });
      await jest.advanceTimersByTimeAsync(60000);
      await pending;
      expect(request).toHaveBeenCalledTimes(1);
      expect(jest.getTimerCount()).toBe(0);
    } finally { jest.useRealTimers(); }
  });

  it('在途取消会中断模型请求并保留未知提交语义', async () => {
    hanging = true;
    // 只发送合成取消事件，不调用真实模型。
    const controller = new AbortController();
    // 等微任务将DoH结果传入HTTPS，再发起取消。
    const pending = expect(new AiProvider().polish(input, '原文', noteContext, controller.signal)).rejects.toMatchObject({ code: 'AI_SUBMISSION_UNKNOWN', uncertain: true });
    await Promise.resolve();
    controller.abort();
    await pending;
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('不跟随重定向，也不回显供应商错误正文', async () => {
    status = 302; body = { error: `sensitive ${input.apiKey}` };
    await expect(new AiProvider().test(input)).rejects.toMatchObject({ code: 'AI_PROVIDER_REJECTED', message: 'AI_PROVIDER_REJECTED' });
    expect(request).toHaveBeenCalledTimes(1);
    expect(JSON.parse(sentPayload)).toMatchObject({ max_output_tokens: 256, instructions: '只回复“连接成功”。', input: '连接测试' });
  });

  it.each([400, 200])('HTTP %s明确说明关闭思考不受支持，不修改参数或自动重试', async (httpStatus) => {
    status = httpStatus;
    // 供应商原文故意混入合成密钥，公开提示只能来自本地固定描述。
    const error = { code: 'invalid_request', message: `该模型始终思考，不支持关闭思考；请使用 low、high 或 max。${input.apiKey}` };
    body = httpStatus === 400 ? { error } : { ...completedResponse(), status: 'failed', error };
    // 实际网络适配器异常经过业务API统一转换，不能泄漏原始错误正文。
    const failure = await new AiProvider().test({ ...input, provider: 'zhipu', model: 'glm-5.3' }).catch((cause: unknown) => aiFailure(cause));
    expect(failure).toMatchObject({ getResponse: expect.any(Function) });
    expect('getResponse' in failure && failure.getResponse()).toEqual({ code: 'AI_REASONING_UNSUPPORTED', message: '该模型始终开启思考，不支持关闭思考（reasoning.effort=none）。' });
    expect(JSON.stringify(failure)).not.toContain(input.apiKey);
    expect(JSON.parse(sentPayload)).toMatchObject({ reasoning: { effort: 'none' } });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it.each([
    { error: { code: 'invalid_request', message: '其他敏感参数错误 unit-only-key' } },
    { error: { code: 'other_error', message: '不支持关闭思考 unit-only-key' } },
    { error: { code: 'invalid_request', message: null } },
    { error: null },
    null,
  ])('未知HTTP400错误不误判且不透传敏感正文 %#', async (response) => {
    status = 400; body = response;
    await expect(new AiProvider().test(input)).rejects.toMatchObject({ code: 'AI_PROVIDER_REJECTED', message: 'AI_PROVIDER_REJECTED' });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('HTTP400损坏JSON保持固定拒绝提示', async () => {
    status = 400; rawBody = `invalid ${input.apiKey}`;
    await expect(new AiProvider().test(input)).rejects.toMatchObject({ code: 'AI_PROVIDER_REJECTED', message: 'AI_PROVIDER_REJECTED' });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it.each([[401, 'AI_AUTH_FAILED'], [403, 'AI_AUTH_FAILED'], [404, 'AI_MODEL_OR_URL_INVALID'], [429, 'AI_RATE_LIMITED'], [500, 'AI_PROVIDER_REJECTED']] as const)('HTTP %s只返回稳定错误且不回退旧协议', async (httpStatus, code) => {
    status = httpStatus; body = { error: { message: input.apiKey } };
    await expect(new AiProvider().test(input)).rejects.toMatchObject({ code, message: code });
    expect(sentUrl.pathname).toBe('/prefix/v1/responses');
    expect(request).toHaveBeenCalledTimes(1);
  });
});

describe('AI 独立持久加密密钥', () => {
  /// 每个测试都使用独立临时目录，不读取生产密钥。
  let directory: string;
  beforeEach(() => { directory = mkdtempSync(join(tmpdir(), 'omni-ai-keys-')); });
  afterEach(() => { rmSync(directory, { recursive: true, force: true }); });

  it('密文随机且可跨实例解密，GCM 篡改明确失败', () => {
    // 仅将测试临时目录交给配置服务。
    const config = new ConfigService({ JWT_KEYS_DIR: directory });
    // 独立实例共享同一份加密密钥文件。
    const first = new AiKeyStore(config);
    // 第二份密文使用不同 nonce。
    const encrypted = first.encrypt('unit-only-key');
    expect(encrypted).not.toContain('unit-only-key'); expect(first.encrypt('unit-only-key')).not.toBe(encrypted);
    expect(new AiKeyStore(config).decrypt(encrypted)).toBe('unit-only-key');
    expect(readFileSync(join(directory, 'ai-encryption-key-v1')).length).toBe(32);
    expect(() => first.decrypt(`${encrypted.slice(0, -4)}AAAA`)).toThrow('模型密钥无法解密');
  });

  it('持久密钥损坏不覆盖或重新生成', () => {
    writeFileSync(join(directory, 'ai-encryption-key-v1'), 'damaged');
    expect(() => new AiKeyStore(new ConfigService({ JWT_KEYS_DIR: directory })).encrypt('test')).toThrow('AI 独立加密密钥无法读取');
    expect(readFileSync(join(directory, 'ai-encryption-key-v1'), 'utf8')).toBe('damaged');
  });

  it('历史密文解密遇到密钥丢失时不创建替代文件', () => {
    // 原始实例只用于生成测试密文。
    const config = new ConfigService({ JWT_KEYS_DIR: directory });
    // 模拟备份只恢复数据库却丢失加密卷。
    const encrypted = new AiKeyStore(config).encrypt('unit-only-key');
    // 文件位置明确限定为本测试临时目录中的单个密钥文件。
    const path = join(directory, 'ai-encryption-key-v1');
    rmSync(path);
    expect(() => new AiKeyStore(config).decrypt(encrypted)).toThrow('模型密钥无法解密');
    expect(existsSync(path)).toBe(false);
    // 用户主动重新填写密钥才允许生成新加密文件。
    expect(new AiKeyStore(config).encrypt('replacement-test-key')).toMatch(/^v1\./);
    expect(existsSync(path)).toBe(true);
  });
});
