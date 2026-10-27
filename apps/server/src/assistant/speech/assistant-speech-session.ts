import { WebSocket, type RawData } from 'ws';

/// 单次录音的明确结束原因，取消与错误不会产生 completed。
type EndReason = 'manual' | 'limit';

/// 一条识别句的当前内容；已稳定的句子不再被迟到结果覆盖。
interface Sentence {
  /// 该句完整文字，不是增量片段。
  text: string;
  /// 腾讯 slice_type=2 表示稳定结果。
  stable: boolean;
}

/// 双向实时流生命周期；仅在内存合并转写，不持久化音频或业务消息。
export class AssistantSpeechSession {
  /// 防止错误、关闭与超时重复释放连接名额。
  private closed = false;
  /// 腾讯应用握手成功后才允许客户端上传音频。
  private ready = false;
  /// 已请求收尾时停止接收新音频。
  private ending: EndReason | null = null;
  /// 首次 ready 的时间用于限制音频上传速度。
  private startedAt = 0;
  /// 本次已经接收的 PCM 字节总量。
  private audioBytes = 0;
  /// 已知句子按稳定序号合并。
  private readonly sentences = new Map<number, Sentence>();
  /// 所有业务定时器统一随连接释放。
  private readonly timers = new Set<NodeJS.Timeout>();
  /// 上游应用握手期限。
  private handshakeTimer?: NodeJS.Timeout;
  /// 未发送音频的期限，结束阶段不再使用。
  private idleTimer?: NodeJS.Timeout;
  /// 身份复验不并发堆积数据库请求。
  private validating = false;

  /// 注入两端 socket、共享认证和唯一名额释放回调。
  constructor(
    private readonly client: WebSocket,
    private readonly upstream: WebSocket,
    private readonly revalidate: () => Promise<void>,
    private readonly release: () => void,
  ) {
    client.on('message', (data: RawData, binary: boolean): void => this.receiveClient(data, binary));
    client.on('close', (): void => this.dispose());
    client.on('error', (): void => this.dispose());
    upstream.on('message', (data: RawData, binary: boolean): void => this.receiveUpstream(data, binary));
    upstream.on('close', (): void => this.fail('ASSISTANT_SPEECH_INTERRUPTED', '语音识别连接中断，已识别文字可继续编辑'));
    upstream.on('error', (): void => this.fail('ASSISTANT_SPEECH_NETWORK', '语音识别连接失败，请稍后重试'));
    this.handshakeTimer = this.later((): void => this.fail('ASSISTANT_SPEECH_TIMEOUT', '语音识别连接超时，请稍后重试'), 10_000);
  }

  /// 服务关闭或主动撤销会话时同时终止两端连接。
  close(): void {
    this.dispose();
  }

  /// 安排可统一清理的单次业务定时器。
  private later(action: () => void, delay: number): NodeJS.Timeout {
    // 回调结束后立即移除，避免长录音积累旧定时器。
    const timer = setTimeout((): void => {
      this.timers.delete(timer);
      if (!this.closed) action();
    }, delay);
    timer.unref();
    this.timers.add(timer);
    return timer;
  }

  /// 清除被刷新或提前完成的超时。
  private clear(timer: NodeJS.Timeout | undefined): void {
    if (!timer) return;
    clearTimeout(timer);
    this.timers.delete(timer);
  }

  /// 各种 ws RawData 统一转换为已受 maxPayload 限制的字节。
  private bytes(data: RawData): Buffer {
    return Array.isArray(data) ? Buffer.concat(data) : Buffer.isBuffer(data) ? data : Buffer.from(data);
  }

  /// 限定控制消息与 PCM 数据，禁止未知消息和无界音频缓存。
  private receiveClient(data: RawData, binary: boolean): void {
    if (this.closed) return;
    // ws 已完成分片合并，此处再次限制应用层长度和 PCM 对齐。
    const bytes = this.bytes(data);
    if (binary) {
      if (!this.ready || this.ending) {
        // 服务端限时已收尾时，忽略链路中正在飞行的最后一包。
        if (this.ending === 'limit') return;
        this.fail('ASSISTANT_SPEECH_PROTOCOL', '语音输入状态已改变，请重新开始');
        return;
      }
      if (!bytes.length || bytes.length > 6400 || bytes.length % 2 !== 0) {
        this.fail('ASSISTANT_SPEECH_AUDIO_INVALID', '录音格式不受支持，请重新开始');
        return;
      }
      this.audioBytes += bytes.length;
      if (this.audioBytes > ((Date.now() - this.startedAt) / 1000 + 1) * 32000) {
        this.fail('ASSISTANT_SPEECH_RATE_LIMIT', '录音发送过快，请重新开始');
        return;
      }
      if (this.upstream.readyState !== WebSocket.OPEN || this.upstream.bufferedAmount > 65_536) {
        this.fail('ASSISTANT_SPEECH_BACKPRESSURE', '网络较慢，语音输入已停止');
        return;
      }
      this.clear(this.idleTimer);
      this.idleTimer = this.later((): void => this.fail('ASSISTANT_SPEECH_AUDIO_TIMEOUT', '录音数据中断，已识别文字可继续编辑'), 5000);
      this.upstream.send(bytes, { binary: true }, (error?: Error): void => {
        if (error) this.fail('ASSISTANT_SPEECH_NETWORK', '语音识别连接失败，请稍后重试');
      });
      return;
    }
    if (bytes.length > 1024) {
      this.fail('ASSISTANT_SPEECH_PROTOCOL', '语音输入请求无效');
      return;
    }
    try {
      // 只接受固定协议字段，不向上游转发任意客户端 JSON。
      const value: unknown = JSON.parse(bytes.toString('utf8'));
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid');
      // 已完成最外层结构检查的控制消息。
      const message = value as Record<string, unknown>;
      if (message.type === 'cancel' && Object.keys(message).length === 1) this.dispose();
      else if (message.type === 'end' && Object.keys(message).length === 2 && (message.reason === 'manual' || message.reason === 'limit')) this.end(message.reason);
      else throw new Error('invalid');
    } catch {
      this.fail('ASSISTANT_SPEECH_PROTOCOL', '语音输入请求无效');
    }
  }

  /// 等待腾讯应用握手，按句序号覆盖临时结果，final 才视为成功。
  private receiveUpstream(data: RawData, binary: boolean): void {
    if (this.closed) return;
    try {
      if (binary) throw new Error('invalid');
      // 厂商消息经过结构校验，错误原文与连接 URL 不泄露到客户端。
      const value: unknown = JSON.parse(this.bytes(data).toString('utf8'));
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid');
      // 已通过基础对象检查的厂商结果。
      const message = value as Record<string, unknown>;
      if (typeof message.code !== 'number') throw new Error('invalid');
      if (message.code !== 0) {
        this.fail('ASSISTANT_SPEECH_PROVIDER_ERROR', '语音识别服务暂不可用，请检查腾讯云服务配置或稍后重试');
        return;
      }
      if (!this.ready) {
        if (message.final === 1 || message.result) throw new Error('invalid');
        this.ready = true;
        this.startedAt = Date.now();
        this.clear(this.handshakeTimer);
        this.emit({ type: 'ready' });
        if (this.closed) return;
        this.idleTimer = this.later((): void => this.fail('ASSISTANT_SPEECH_AUDIO_TIMEOUT', '没有收到录音数据，请检查麦克风后重试'), 5000);
        this.later((): void => this.end('limit'), 300_000);
        this.later((): void => { void this.checkIdentity(); }, 5000);
      }
      if (message.result !== undefined) this.updateSentence(message.result);
      if (message.final === 1) {
        if (!this.ending) throw new Error('invalid');
        this.emit({ type: 'completed', text: this.text(), reason: this.ending });
        this.dispose();
      }
    } catch {
      this.fail('ASSISTANT_SPEECH_RESPONSE_INVALID', '语音识别返回异常，已识别文字可继续编辑');
    }
  }

  /// 同句临时结果整体替换；稳定句不接受重复或迟到修改。
  private updateSentence(value: unknown): void {
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid');
    // 腾讯单句结果。
    const result = value as Record<string, unknown>;
    if (!Number.isSafeInteger(result.index) || (result.index as number) < 0 || (result.index as number) > 10_000 || ![0, 1, 2].includes(result.slice_type as number) || typeof result.voice_text_str !== 'string' || result.voice_text_str.length > 20_000) throw new Error('invalid');
    // 已验证范围的稳定句序号。
    const index = result.index as number;
    if (this.sentences.get(index)?.stable) return;
    this.sentences.set(index, { text: result.voice_text_str, stable: result.slice_type === 2 });
    if (this.text().length > 20_000) throw new Error('too long');
    this.emit({ type: 'transcript', text: this.text() });
  }

  /// 按识别句序号构造完整当前文字，不追加重复临时结果。
  private text(): string {
    return [...this.sentences.entries()].sort(([left], [right]) => left - right).map(([, sentence]) => sentence.text).join('');
  }

  /// 手动结束或上限都只发送一次 end，等待明确 final 回执。
  private end(reason: EndReason): void {
    if (this.closed || this.ending) return;
    if (!this.ready || this.upstream.readyState !== WebSocket.OPEN) {
      this.fail('ASSISTANT_SPEECH_NOT_READY', '语音识别尚未就绪，请重新开始');
      return;
    }
    this.ending = reason;
    this.clear(this.idleTimer);
    this.upstream.send(JSON.stringify({ type: 'end' }), (error?: Error): void => {
      if (error) this.fail('ASSISTANT_SPEECH_NETWORK', '语音识别连接失败，请稍后重试');
    });
    this.later((): void => this.fail('ASSISTANT_SPEECH_FINAL_TIMEOUT', '等待最终识别结果超时，已识别文字可继续编辑'), 10_000);
  }

  /// 长连接重复使用既有 JWT 和设备会话校验，不允许旧身份继续输出。
  private async checkIdentity(): Promise<void> {
    if (this.closed || this.validating) return;
    this.validating = true;
    // 数据库或认证故障同样不能无限延长现有录音权限。
    const timeout = this.later((): void => this.fail('ASSISTANT_SPEECH_UNAUTHORIZED', '设备连接已失效，请重新连接'), 5000);
    try {
      await this.revalidate();
      if (!this.closed) this.later((): void => { void this.checkIdentity(); }, 5000);
    } catch {
      this.fail('ASSISTANT_SPEECH_UNAUTHORIZED', '设备连接已失效，请重新连接');
    } finally {
      this.validating = false;
      this.clear(timeout);
    }
  }

  /// 只发送受控字段；慢客户端不会积累无界转写缓冲。
  private emit(message: Record<string, unknown>): void {
    if (this.closed) return;
    if (this.client.readyState !== WebSocket.OPEN || this.client.bufferedAmount > 65_536) {
      this.dispose();
      return;
    }
    this.client.send(JSON.stringify(message), (error?: Error): void => {
      if (error) this.dispose();
    });
  }

  /// 所有失败只发送一次固定错误，不标记 completed，不重连付费识别。
  private fail(code: string, message: string): void {
    if (this.closed) return;
    this.emit({ type: 'error', code, message });
    this.dispose();
  }

  /// 任一关闭路径释放麦克风链路、上游和名额，迟到事件全部失效。
  private dispose(): void {
    if (this.closed) return;
    this.closed = true;
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
    this.upstream.terminate();
    if (this.client.readyState === WebSocket.OPEN) this.client.close(1000);
    // close 保证最后一条事件先发送；不响应关闭握手的客户端最终强制释放。
    const closeTimer = setTimeout((): void => this.client.terminate(), 1000);
    closeTimer.unref();
    this.release();
  }
}
