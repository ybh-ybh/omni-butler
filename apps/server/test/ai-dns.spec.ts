import { EventEmitter } from 'node:events';
import { lookup } from 'node:dns/promises';
import type { ClientRequest, IncomingMessage, RequestOptions } from 'node:http';
import { request } from 'node:https';
import { resolveAiAddresses } from '../src/ai/ai-dns';

jest.mock('node:https', () => ({ request: jest.fn() }));
jest.mock('node:dns/promises', () => ({ lookup: jest.fn() }));

describe('AI DoH解析与网络边界', () => {
  /// 全部名称和应答为合成数据，不调用真实模型。
  const hostname = 'model.example.test';
  /// 本次查询实际使用的固定端点、地址和请求头。
  let calls: { url: URL; options: RequestOptions }[];
  /// 可控HTTP状态用于模拟拒绝与重定向。
  let status: number;
  /// 启用时模拟握手或持续响应未完成。
  let hanging: boolean;
  /// 每种查询类型可独立返回应答或损坏正文。
  let answer: (type: number) => unknown;
  /// 观察失败与超时是否真正关闭在途请求。
  let destroyed: number;

  beforeEach(() => {
    jest.clearAllMocks();
    calls = []; status = 200; hanging = false; destroyed = 0;
    answer = (type: number): unknown => ({
      Status: 0, TC: false, Question: [{ name: `${hostname}.`, type }],
      Answer: [{ name: hostname, type, data: type === 1 ? '8.8.8.8' : '2606:4700:4700::1111' }],
    });
    jest.mocked(request).mockImplementation(((url: URL, options: RequestOptions, callback: (response: IncomingMessage) => void): ClientRequest => {
      calls.push({ url, options });
      // 真实请求会在AbortSignal触发时结束并产生error事件。
      const outgoing = new EventEmitter() as ClientRequest;
      // 关闭标志避免重复取消产生额外错误。
      let closed = false;
      outgoing.destroy = ((error?: Error): ClientRequest => {
        if (!closed) { closed = true; destroyed++; outgoing.emit('error', error ?? new Error('aborted')); outgoing.emit('close'); }
        return outgoing;
      }) as ClientRequest['destroy'];
      // 显式绑定和清理取消监听，覆盖超时与调用方撤回。
      const abort = (): void => { outgoing.destroy(new Error('aborted')); };
      options.signal?.addEventListener('abort', abort, { once: true });
      outgoing.once('close', () => options.signal?.removeEventListener('abort', abort));
      outgoing.end = ((): ClientRequest => {
        if (options.signal?.aborted) { abort(); return outgoing; }
        if (hanging) return outgoing;
        // 只模拟响应事件，不在替身中重新实现解析规则。
        const response = new EventEmitter() as IncomingMessage;
        response.statusCode = status;
        response.resume = jest.fn().mockReturnValue(response);
        callback(response);
        if (!closed) {
          // 字符串夹具用于覆盖非JSON及过大的响应。
          const result = answer(Number(url.searchParams.get('type')));
          response.emit('data', Buffer.from(typeof result === 'string' ? result : JSON.stringify(result)));
          if (!closed) { response.emit('end'); closed = true; outgoing.emit('close'); }
        }
        return outgoing;
      }) as ClientRequest['end'];
      return outgoing;
    }) as typeof request);
  });

  afterEach(() => { jest.useRealTimers(); });

  it('绕过系统DNS，用固定引导地址查询A及AAAA且不发送模型凭据', async () => {
    expect(await resolveAiAddresses(hostname)).toEqual([
      { address: '8.8.8.8', family: 4 }, { address: '2606:4700:4700::1111', family: 6 },
    ]);
    expect(lookup).not.toHaveBeenCalled();
    expect(calls).toHaveLength(2);
    for (const call of calls) {
      expect(call.url.origin).toBe('https://cloudflare-dns.com');
      expect(call.url.pathname).toBe('/dns-query');
      expect(call.url.searchParams.get('name')).toBe(hostname);
      expect(call.options).toMatchObject({ method: 'GET', agent: false, family: 4, headers: { accept: 'application/dns-json' } });
      expect(call.options.headers).not.toHaveProperty('authorization');
      expect(call.options).not.toHaveProperty('rejectUnauthorized', false);
      // 系统即使返回Fake-IP，实际TLS连接也只采用引导公网IP。
      const callback = jest.fn();
      call.options.lookup!('cloudflare-dns.com', {}, callback);
      expect(callback).toHaveBeenCalledWith(null, '1.1.1.1', 4);
      // Node的all模式也只能得到固定地址。
      const allCallback = jest.fn();
      call.options.lookup!('cloudflare-dns.com', { all: true }, allCallback);
      expect(allCallback).toHaveBeenCalledWith(null, [{ address: '1.1.1.1', family: 4 }]);
    }
  });

  it('IP字面量不发送DNS查询，由供应商入口继续检查公网范围', async () => {
    expect(await resolveAiAddresses('8.8.8.8')).toEqual([{ address: '8.8.8.8', family: 4 }]);
    expect(await resolveAiAddresses('2606:4700:4700::1111')).toEqual([{ address: '2606:4700:4700::1111', family: 6 }]);
    expect(request).not.toHaveBeenCalled();
  });

  it.each(['open.bigmodel.cn', 'OPEN.BIGMODEL.CN.'])('智谱官方域名%s使用国内DoH节点并接受单对象问题', async (name) => {
    answer = (type: number): unknown => ({
      Status: 0, TC: false, Question: { name, type },
      Answer: type === 1 ? [
        { name, type: 5, data: 'cdn.example.test.' },
        { name: 'cdn.example.test.', type: 1, data: '39.108.102.11' },
      ] : [],
    });
    expect(await resolveAiAddresses(name)).toEqual([{ address: '39.108.102.11', family: 4 }]);
    expect(calls).toHaveLength(2);
    for (const call of calls) {
      expect(call.url.origin).toBe('https://dns.alidns.com');
      expect(call.url.pathname).toBe('/resolve');
      expect(call.options.headers).toEqual({ accept: 'application/dns-json' });
      expect(call.options).toMatchObject({ agent: false, family: 4 });
      expect(call.options).not.toHaveProperty('rejectUnauthorized', false);
      // 国内解析器也必须固定引导地址，不能退回系统Fake-IP。
      const callback = jest.fn();
      call.options.lookup!('dns.alidns.com', { all: true }, callback);
      expect(callback).toHaveBeenCalledWith(null, [{ address: '223.5.5.5', family: 4 }]);
    }
    expect(lookup).not.toHaveBeenCalled();
  });

  it.each([null, {}, { name: 'other.example.test', type: 1 }, { name: hostname, type: '1' }])('单对象问题仍严格验证名称和地址族 %#', async (question) => {
    answer = (): unknown => ({ Status: 0, TC: false, Question: question, Answer: [] });
    await expect(resolveAiAddresses('open.bigmodel.cn')).rejects.toThrow('AI_DNS_FAILED');
    expect(lookup).not.toHaveBeenCalled();
  });

  it('接受合法CNAME链及空AAAA结果，保留A记录的全部地址', async () => {
    answer = (type: number): unknown => ({
      Status: 0, TC: false, Question: [{ name: hostname, type }],
      Answer: type === 1 ? [
        { name: 'cdn.example.test.', type: 1, data: '8.8.8.8' },
        { name: `${hostname.toUpperCase()}.`, type: 5, data: 'cdn.example.test.' },
        { name: 'cdn.example.test.', type: 1, data: '1.1.1.1' },
      ] : [],
    });
    expect(await resolveAiAddresses(hostname)).toEqual([{ address: '8.8.8.8', family: 4 }, { address: '1.1.1.1', family: 4 }]);
  });

  it.each(['status', 'truncated', 'wrong-question', 'unrelated-address', 'wrong-family', 'alias-loop', 'malformed', 'oversized', 'empty'])('异常应答%s失败关闭且不回退系统解析', async (scenario) => {
    answer = (type: number): unknown => {
      if (scenario === 'malformed') return 'not-json';
      if (scenario === 'oversized') return 'x'.repeat(65537);
      // 不可信应答的可控副本。
      const result = {
        Status: scenario === 'status' ? 3 : 0,
        TC: scenario === 'truncated',
        Question: [{ name: scenario === 'wrong-question' ? 'other.example.test' : hostname, type }],
        Answer: scenario === 'empty' ? [] : [{ name: scenario === 'unrelated-address' ? 'other.example.test' : hostname, type, data: scenario === 'wrong-family' ? 'not-an-ip' : type === 1 ? '8.8.8.8' : '2606:4700:4700::1111' }],
      };
      if (scenario === 'alias-loop') result.Answer.push({ name: hostname, type: 5, data: `${hostname}.` });
      return result;
    };
    await expect(resolveAiAddresses(hostname)).rejects.toThrow('AI_DNS_FAILED');
    expect(lookup).not.toHaveBeenCalled();
  });

  it.each([302, 401, 500])('HTTP %s不能作为DNS结果或跟随重定向', async (httpStatus) => {
    status = httpStatus;
    await expect(resolveAiAddresses(hostname)).rejects.toThrow('AI_DNS_FAILED');
    expect(request).toHaveBeenCalledTimes(2);
  });

  it('总时限会中止两个在途查询，不能在超时后继续请求', async () => {
    jest.useFakeTimers(); hanging = true;
    // 先绑定拒绝观察，避免推进计时器后产生未处理拒绝。
    const failure = expect(resolveAiAddresses(hostname)).rejects.toThrow('AI_DNS_FAILED');
    await jest.advanceTimersByTimeAsync(5000);
    await failure;
    expect(destroyed).toBe(2);
    expect(jest.getTimerCount()).toBe(0);
  });

  it('调用方撤回立即中止两个查询并清理总时限', async () => {
    jest.useFakeTimers(); hanging = true;
    // 撤回由上层任务传入。
    const controller = new AbortController();
    // 撤回前开始两个查询。
    const failure = expect(resolveAiAddresses(hostname, controller.signal)).rejects.toThrow('AI_DNS_FAILED');
    controller.abort();
    await failure;
    expect(destroyed).toBe(2);
    expect(jest.getTimerCount()).toBe(0);
  });
});
