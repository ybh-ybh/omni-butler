import { HttpAdapterHost } from '@nestjs/core';
import { createServer, request as httpRequest, type IncomingMessage, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocket, WebSocketServer, type RawData } from 'ws';
import type { AuthUser } from '../src/auth/auth.types';
import { AssistantSpeechAuth } from '../src/assistant/speech/assistant-speech-auth.service';
import { AssistantSpeechGateway } from '../src/assistant/speech/assistant-speech.gateway';
import { TencentRealtimeSpeechProvider } from '../src/assistant/speech/tencent-realtime-speech.provider';

/// 真实本地 WebSocket 双跳验证，厂商仅由本进程 mock 服务替代。
describe('AssistantSpeechGateway', () => {
  // 模拟已有 Nest HTTP 端口。
  let server: Server;
  // 本地厂商替身，不访问腾讯服务。
  let vendor: WebSocketServer;
  // 被测生命周期服务。
  let gateway: AssistantSpeechGateway;
  // 发往语音 upgrade 的完整地址。
  let url: string;
  // 当前测试创建的客户端连接。
  let clients: WebSocket[];
  // 从请求头派生设备身份的认证边界。
  let authenticate: jest.Mock<Promise<AuthUser>, [IncomingMessage]>;
  // 配置与连接次数可观察的供应商边界。
  let configured: jest.Mock<boolean, []>;
  // 供应商连接工厂在真实本地 WS 上执行。
  let connect: jest.Mock<WebSocket, []>;
  // 厂商实际收到的二进制包。
  let audio: Buffer[];

  beforeEach(async (): Promise<void> => {
    clients = [];
    audio = [];
    server = createServer();
    vendor = new WebSocketServer({ port: 0, host: '127.0.0.1' });
    await new Promise<void>((resolve): void => { vendor.once('listening', resolve); });
    vendor.on('connection', (socket): void => {
      socket.send(JSON.stringify({ code: 0 }));
      socket.on('message', (data: RawData, binary: boolean): void => {
        if (binary) audio.push(Buffer.from(data as Buffer));
        else {
          socket.send(JSON.stringify({ code: 0, result: { index: 0, slice_type: 2, voice_text_str: '本地转写完成。' } }));
          socket.send(JSON.stringify({ code: 0, final: 1 }));
        }
      });
    });
    authenticate = jest.fn<Promise<AuthUser>, [IncomingMessage]>().mockImplementation((request): Promise<AuthUser> => {
      if (request.headers.authorization === 'Bearer invalid') return Promise.reject(new Error('unauthorized'));
      return Promise.resolve({ sub: 'owner', sid: request.headers.authorization ?? 'device', typ: 'access' });
    });
    configured = jest.fn<boolean, []>().mockReturnValue(true);
    connect = jest.fn<WebSocket, []>().mockImplementation((): WebSocket => new WebSocket(`ws://127.0.0.1:${(vendor.address() as AddressInfo).port}`));
    gateway = new AssistantSpeechGateway(
      { httpAdapter: { getHttpServer: (): Server => server } } as HttpAdapterHost,
      { authenticate } as AssistantSpeechAuth,
      { configured, connect } as unknown as TencentRealtimeSpeechProvider,
    );
    gateway.onApplicationBootstrap();
    await new Promise<void>((resolve): void => { server.listen(0, '127.0.0.1', resolve); });
    url = `ws://127.0.0.1:${(server.address() as AddressInfo).port}/omni-butler/api/v1/assistant/speech/stream`;
  });

  afterEach(async (): Promise<void> => {
    gateway.onModuleDestroy();
    for (const client of clients) client.terminate();
    for (const socket of vendor.clients) socket.terminate();
    await Promise.all([
      new Promise<void>((resolve): void => { server.close((): void => resolve()); }),
      new Promise<void>((resolve): void => { vendor.close((): void => resolve()); }),
    ]);
  });

  /// 新建受当前测试管理的设备连接。
  function client(device: string, suffix = ''): WebSocket {
    // 错误由具体断言观察，避免预期握手失败产生未处理事件。
    const socket = new WebSocket(`${url}${suffix}`, { headers: { Authorization: `Bearer ${device}` } });
    socket.on('error', (): void => undefined);
    clients.push(socket);
    return socket;
  }

  /// 等待下一条真实服务端 JSON 事件。
  function next(socket: WebSocket): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject): void => {
      socket.once('message', (data: RawData): void => resolve(decode(data)));
      socket.once('error', reject);
    });
  }

  /// ws 二进制类型归一后解析受控测试 JSON。
  function decode(data: RawData): Record<string, unknown> {
    // 测试也支持 Buffer、ArrayBuffer 和分块数组。
    const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.isBuffer(data) ? data : Buffer.from(data);
    return JSON.parse(bytes.toString('utf8')) as Record<string, unknown>;
  }

  /// 捕获升级前明确拒绝的 HTTP 状态。
  function rejection(socket: WebSocket): Promise<number | undefined> {
    return new Promise((resolve): void => {
      socket.once('unexpected-response', (_request, response): void => {
        response.resume();
        resolve(response.statusCode);
        socket.terminate();
      });
    });
  }

  it('真实连接收到 ready，PCM 直达 mock 腾讯并在 final 后完成', async (): Promise<void> => {
    // 使用独立设备身份完成一条真实双跳连接。
    const socket = client('one');
    expect(await next(socket)).toEqual({ type: 'ready' });
    socket.send(Buffer.from([0, 0, 1, 0]));
    // end 触发上游最终文本与 final，收集两条有序结果。
    const events: Array<Record<string, unknown>> = [];
    // 等待正常关闭，保证 completed 没有被主动清理吞掉。
    const closed = new Promise<void>((resolve): void => { socket.once('close', resolve); });
    socket.on('message', (data: RawData): void => { events.push(decode(data)); });
    socket.send(JSON.stringify({ type: 'end', reason: 'manual' }));
    await closed;
    expect(audio).toEqual([Buffer.from([0, 0, 1, 0])]);
    expect(events).toEqual([{ type: 'transcript', text: '本地转写完成。' }, { type: 'completed', text: '本地转写完成。', reason: 'manual' }]);
    expect(connect).toHaveBeenCalledTimes(1);
  });

  it('无权限或缺配置在升级前拒绝，完全不连接厂商', async (): Promise<void> => {
    expect(await rejection(client('invalid'))).toBe(401);
    configured.mockReturnValue(false);
    expect(await rejection(client('one'))).toBe(503);
    expect(connect).not.toHaveBeenCalled();
  });

  it('拒绝查询参数令牌并限制同设备一路、同 owner 两路', async (): Promise<void> => {
    expect(await rejection(client('one', '?token=forbidden'))).toBe(400);
    expect(await next(client('one'))).toEqual({ type: 'ready' });
    expect(await rejection(client('one'))).toBe(429);
    expect(await next(client('two'))).toEqual({ type: 'ready' });
    expect(await rejection(client('three'))).toBe(429);
    expect(connect).toHaveBeenCalledTimes(2);
  });

  it('取消释放名额后同设备可显式开始下一次录音', async (): Promise<void> => {
    // 首次连接明确取消，下一次连接不是自动重试。
    const first = client('one');
    await next(first);
    // 关闭回执保证服务端已经释放相应名额。
    const closed = new Promise<void>((resolve): void => { first.once('close', resolve); });
    first.send(JSON.stringify({ type: 'cancel' }));
    await closed;
    expect(await next(client('one'))).toEqual({ type: 'ready' });
    expect(connect).toHaveBeenCalledTimes(2);
  });

  it('无效 WebSocket 握手不会永久占用设备名额', async (): Promise<void> => {
    // 手工构造缺少合法 Sec-WebSocket-Key 的 HTTP upgrade。
    const status = await new Promise<number | undefined>((resolve, reject): void => {
      // 同一设备随后应仍能正常开始一次录音。
      const request = httpRequest(url.replace('ws:', 'http:'), { headers: { Authorization: 'Bearer one', Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': 'invalid' } }, (response): void => {
        response.resume();
        response.once('end', (): void => resolve(response.statusCode));
      });
      request.on('error', reject);
      request.end();
    });
    expect(status).toBe(400);
    expect(connect).not.toHaveBeenCalled();
    expect(await next(client('one'))).toEqual({ type: 'ready' });
  });
});
