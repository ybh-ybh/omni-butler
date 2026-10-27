import { EventEmitter } from 'node:events';
import { WebSocket } from 'ws';
import { AssistantSpeechSession } from '../src/assistant/speech/assistant-speech-session';

/// 内存 socket 只替换网络，不替换真实转写合并与生命周期逻辑。
class SpeechSocket extends EventEmitter {
  /// 模拟已建立的 WebSocket 传输层。
  readyState: number = WebSocket.OPEN;
  /// 可控待发送数据量用于验证背压。
  bufferedAmount = 0;
  /// 捕获 JSON 和二进制消息。
  readonly sent: Array<string | Buffer> = [];

  /// 模拟成功发送并立即执行发送回调。
  send(data: string | Buffer, options?: unknown, callback?: (error?: Error) => void): void {
    this.sent.push(data);
    if (typeof options === 'function') (options as () => void)();
    callback?.();
  }

  /// 正常关闭会触发真实会话清理路径。
  close(): void {
    this.readyState = WebSocket.CLOSED;
    this.emit('close');
  }

  /// 强制关闭也走相同的幂等清理逻辑。
  terminate(): void {
    this.close();
  }

  /// 注入一条明确的应用消息。
  receive(value: unknown): void {
    this.emit('message', Buffer.from(JSON.stringify(value)), false);
  }

  /// 读取返回客户端的受控事件。
  events(): Array<Record<string, unknown>> {
    return this.sent.filter((value): value is string => typeof value === 'string').map((value) => JSON.parse(value) as Record<string, unknown>);
  }
}

/// 真实单次录音状态机的异常、结束顺序与计费资源释放约束。
describe('AssistantSpeechSession', () => {
  // 每个测试独立创建的生命周期。
  let session: AssistantSpeechSession;
  // 可观察客户端和上游传输。
  let client: SpeechSocket;
  // 腾讯应用层消息注入点。
  let upstream: SpeechSocket;
  // 设备名额必须仅释放一次。
  let release: jest.Mock;
  // 可模拟撤权或数据库失败的身份复验。
  let revalidate: jest.Mock<Promise<void>, []>;

  beforeEach((): void => {
    jest.useFakeTimers();
    client = new SpeechSocket();
    upstream = new SpeechSocket();
    release = jest.fn();
    revalidate = jest.fn<Promise<void>, []>().mockResolvedValue(undefined);
    session = new AssistantSpeechSession(client as unknown as WebSocket, upstream as unknown as WebSocket, revalidate, release);
  });
  afterEach((): void => {
    session.close();
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
  });

  it('传输层 open 不发 ready，应用握手之后才允许 PCM', (): void => {
    expect(client.events()).toEqual([]);
    upstream.receive({ code: 0 });
    expect(client.events()).toEqual([{ type: 'ready' }]);
    client.emit('message', Buffer.alloc(6400), true);
    expect(upstream.sent).toEqual([Buffer.alloc(6400)]);
  });

  it('按句替换临时文本，稳定句与乱序重复结果不重复追加', (): void => {
    upstream.receive({ code: 0 });
    upstream.receive({ code: 0, result: { index: 0, slice_type: 0, voice_text_str: '今' } });
    upstream.receive({ code: 0, result: { index: 0, slice_type: 1, voice_text_str: '今天' } });
    upstream.receive({ code: 0, result: { index: 1, slice_type: 2, voice_text_str: '很好。' } });
    upstream.receive({ code: 0, result: { index: 0, slice_type: 2, voice_text_str: '今天天气' } });
    upstream.receive({ code: 0, result: { index: 0, slice_type: 1, voice_text_str: '迟到错误' } });
    expect(client.events().at(-1)).toEqual({ type: 'transcript', text: '今天天气很好。' });
  });

  it('end 仅发送一次，final 才成功并保留完整最终文本', (): void => {
    upstream.receive({ code: 0 });
    client.receive({ type: 'end', reason: 'manual' });
    client.receive({ type: 'end', reason: 'manual' });
    expect(upstream.sent).toEqual(['{"type":"end"}']);
    expect(client.events().some((event) => event.type === 'completed')).toBe(false);
    upstream.receive({ code: 0, result: { index: 0, slice_type: 2, voice_text_str: '完成。' } });
    upstream.receive({ code: 0, final: 1 });
    expect(client.events().at(-1)).toEqual({ type: 'completed', text: '完成。', reason: 'manual' });
    expect(release).toHaveBeenCalledTimes(1);
  });

  it('上游 close 不能冒充最终完成，取消不回 completed', (): void => {
    upstream.receive({ code: 0 });
    client.receive({ type: 'end', reason: 'manual' });
    upstream.close();
    expect(client.events().at(-1)).toMatchObject({ type: 'error', code: 'ASSISTANT_SPEECH_INTERRUPTED' });
    expect(client.events().some((event) => event.type === 'completed')).toBe(false);
    session.close();
    expect(release).toHaveBeenCalledTimes(1);
  });

  it('显式取消关闭两端并忽略迟到 final', (): void => {
    upstream.receive({ code: 0 });
    client.receive({ type: 'cancel' });
    upstream.receive({ code: 0, final: 1 });
    expect(client.events()).toEqual([{ type: 'ready' }]);
    expect(upstream.readyState).toBe(WebSocket.CLOSED);
    expect(release).toHaveBeenCalledTimes(1);
  });

  it.each([6402, 1, 0])('拒绝无效 PCM 包大小 %i', (length): void => {
    upstream.receive({ code: 0 });
    client.emit('message', Buffer.alloc(length), true);
    expect(client.events().at(-1)).toMatchObject({ code: 'ASSISTANT_SPEECH_AUDIO_INVALID' });
    expect(upstream.sent).toEqual([]);
  });

  it('准备前 PCM、发送过快和上游背压都会终止', (): void => {
    client.emit('message', Buffer.alloc(2), true);
    expect(client.events().at(-1)).toMatchObject({ code: 'ASSISTANT_SPEECH_PROTOCOL' });
  });

  it('发送累计音频不能领先真实时长一秒以上', (): void => {
    upstream.receive({ code: 0 });
    // 同一毫秒发送六包，累计音频超过一秒容忍量。
    for (let index = 0; index < 6; index += 1) client.emit('message', Buffer.alloc(6400), true);
    expect(client.events().at(-1)).toMatchObject({ code: 'ASSISTANT_SPEECH_RATE_LIMIT' });
  });

  it('上游背压不会缓存无限 PCM', (): void => {
    upstream.receive({ code: 0 });
    upstream.bufferedAmount = 65_537;
    client.emit('message', Buffer.alloc(2), true);
    expect(client.events().at(-1)).toMatchObject({ code: 'ASSISTANT_SPEECH_BACKPRESSURE' });
  });

  it('握手十秒、断流五秒和最终十秒均有有限等待', (): void => {
    jest.advanceTimersByTime(10_000);
    expect(client.events().at(-1)).toMatchObject({ code: 'ASSISTANT_SPEECH_TIMEOUT' });
  });

  it('ready 后无音频五秒终止', (): void => {
    upstream.receive({ code: 0 });
    jest.advanceTimersByTime(5000);
    expect(client.events().at(-1)).toMatchObject({ code: 'ASSISTANT_SPEECH_AUDIO_TIMEOUT' });
  });

  it('结束后十秒仍没有 final 则失败', async (): Promise<void> => {
    upstream.receive({ code: 0 });
    client.receive({ type: 'end', reason: 'manual' });
    await jest.advanceTimersByTimeAsync(10_000);
    expect(client.events().at(-1)).toMatchObject({ code: 'ASSISTANT_SPEECH_FINAL_TIMEOUT' });
  });

  it('持续录音五分钟主动收尾，final 返回 limit', async (): Promise<void> => {
    upstream.receive({ code: 0 });
    // 每四秒发送一段静音 PCM，避免触发独立断流保护。
    for (let index = 0; index < 75; index += 1) {
      client.emit('message', Buffer.alloc(2), true);
      await jest.advanceTimersByTimeAsync(4000);
    }
    expect(upstream.sent.at(-1)).toBe('{"type":"end"}');
    upstream.receive({ code: 0, final: 1 });
    expect(client.events().at(-1)).toEqual({ type: 'completed', text: '', reason: 'limit' });
  });

  it('设备撤权终止并且不自动重连', async (): Promise<void> => {
    revalidate.mockRejectedValue(new Error('revoked'));
    upstream.receive({ code: 0 });
    client.receive({ type: 'end', reason: 'manual' });
    await jest.advanceTimersByTimeAsync(5000);
    expect(client.events().at(-1)).toMatchObject({ code: 'ASSISTANT_SPEECH_UNAUTHORIZED' });
    expect(release).toHaveBeenCalledTimes(1);
  });

  it('腾讯原始错误和异常数据不会透传秘密或标记成功', (): void => {
    upstream.receive({ code: 4002, message: 'secret-value', url: 'secret-url' });
    expect(JSON.stringify(client.events())).not.toContain('secret-');
    expect(client.events().at(-1)).toMatchObject({ type: 'error', code: 'ASSISTANT_SPEECH_PROVIDER_ERROR' });
  });
});
