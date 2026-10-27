import { Injectable, type OnApplicationBootstrap, type OnModuleDestroy } from '@nestjs/common';
import { HttpAdapterHost } from '@nestjs/core';
import type { IncomingMessage, Server } from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocketServer } from 'ws';
import type { AuthUser } from '../../auth/auth.types';
import { AssistantSpeechAuth } from './assistant-speech-auth.service';
import { AssistantSpeechSession } from './assistant-speech-session';
import { TencentRealtimeSpeechProvider } from './tencent-realtime-speech.provider';

/// 仅此精确路径接受实时 PCM，不创建新端口或第二套身份体系。
const speechPath = '/omni-butler/api/v1/assistant/speech/stream';

/// 连接名额在等待上游期间仍被保留，避免并行握手绕过限制。
interface Reservation {
  /// 已通过当前 JWT 策略认证的设备身份。
  actor: AuthUser;
  /// 升级成功后绑定的语音生命周期。
  session?: AssistantSpeechSession;
}

/// 在既有 Nest HTTP 服务上接管原生 WebSocket upgrade。
@Injectable()
export class AssistantSpeechGateway implements OnApplicationBootstrap, OnModuleDestroy {
  /// 不开启压缩，单帧最大值留出固定控制消息余量。
  private readonly sockets = new WebSocketServer({ noServer: true, perMessageDeflate: false, maxPayload: 8192 });
  /// 设备和 owner 并发限制均包含尚未 ready 的连接。
  private readonly reservations = new Set<Reservation>();
  /// 既有 Nest HTTP 服务，关闭时移除本模块监听。
  private server?: Server;
  /// 服务销毁后拒绝迟到的认证结果。
  private destroyed = false;
  /// 监听引用保持稳定，支持移除而不影响其他 upgrade 处理器。
  private readonly upgrade = (request: IncomingMessage, socket: Duplex, head: Buffer): void => {
    if (request.url?.split('?')[0] !== speechPath) {
      // Node 存在 upgrade 监听后不再自动关闭未知路径；保留其他模块接管机会。
      if (this.server?.listenerCount('upgrade') === 1) socket.destroy();
      return;
    }
    void this.handleUpgrade(request, socket, head);
  };

  /// 认证和供应商均可替换，测试不访问真实腾讯云。
  constructor(
    private readonly adapter: HttpAdapterHost,
    private readonly auth: AssistantSpeechAuth,
    private readonly provider: TencentRealtimeSpeechProvider,
  ) {}

  /// 应用启动后绑定真实 HTTP server，HTTP 路由和 SSE 保持原行为。
  onApplicationBootstrap(): void {
    this.server = this.adapter.httpAdapter.getHttpServer() as Server;
    this.server.on('upgrade', this.upgrade);
  }

  /// 应用销毁同时停止所有计费上游与客户端长连接。
  onModuleDestroy(): void {
    this.destroyed = true;
    this.server?.off('upgrade', this.upgrade);
    for (const reservation of this.reservations) reservation.session?.close();
    this.reservations.clear();
    this.sockets.close();
  }

  /// 身份校验在协议升级和厂商连接之前完成。
  private async handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): Promise<void> {
    // 认证发生阻塞时也及时关闭尚未升级的连接。
    const timeout = setTimeout((): void => { socket.destroy(); }, 10_000);
    timeout.unref();
    // 网络错误仅清理连接，不打印包含 Bearer 的请求。
    const onError = (): void => { socket.destroy(); };
    socket.on('error', onError);
    try {
      // 不接受查询参数中的令牌或任意签名配置。
      if (request.url !== speechPath) {
        this.reject(socket, 400, 'Bad Request');
        return;
      }
      // 全部校验复用已注册 Passport JwtStrategy。
      const actor = await this.auth.authenticate(request);
      if (this.destroyed || socket.destroyed) return;
      if (!this.provider.configured()) {
        this.reject(socket, 503, 'Service Unavailable');
        return;
      }
      // 两端可各有一条录音，同一设备不能重复占用收费连接。
      const active = [...this.reservations];
      if (active.some((entry) => entry.actor.sid === actor.sid) || active.filter((entry) => entry.actor.sub === actor.sub).length >= 2) {
        this.reject(socket, 429, 'Too Many Requests');
        return;
      }
      // 从此处到 handleUpgrade 同步预占，不能被并行请求穿透。
      const reservation: Reservation = { actor };
      this.reservations.add(reservation);
      // ws 对非法握手可能直接关闭而不执行回调，仍须释放预占名额。
      socket.once('close', (): void => { this.reservations.delete(reservation); });
      try {
        this.sockets.handleUpgrade(request, socket, head, (client): void => {
          try {
            reservation.session = new AssistantSpeechSession(
              client,
              this.provider.connect(),
              async (): Promise<void> => {
                // 同一请求携带的原 token 也会到期，不静默更换设备身份。
                const current = await this.auth.authenticate(request);
                if (current.sub !== actor.sub || current.sid !== actor.sid) throw new Error('identity changed');
              },
              (): void => { this.reservations.delete(reservation); },
            );
          } catch {
            this.reservations.delete(reservation);
            client.close(1011, 'Speech service unavailable');
          }
        });
      } catch {
        this.reservations.delete(reservation);
        socket.destroy();
      }
    } catch {
      this.reject(socket, 401, 'Unauthorized');
    } finally {
      clearTimeout(timeout);
      socket.once('close', (): void => { socket.off('error', onError); });
    }
  }

  /// 升级前固定状态码拒绝，不泄露内部错误或供应商凭据。
  private reject(socket: Duplex, status: number, description: string): void {
    if (socket.destroyed) return;
    socket.end(`HTTP/1.1 ${status} ${description}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  }
}
