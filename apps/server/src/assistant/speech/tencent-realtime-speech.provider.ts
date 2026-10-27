import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHmac, randomInt, randomUUID } from 'node:crypto';
import { WebSocket } from 'ws';

/// 实时语音签名只留在服务端，与录音文件识别共用部署凭据。
export function tencentRealtimeUrl(
  appId: string,
  secretId: string,
  secretKey: string,
  timestamp: number,
  nonce: number,
  voiceId: string,
): string {
  // 固定中文普通引擎，不开启额外付费功能。
  const parameters: Record<string, string | number> = {
    engine_model_type: '16k_zh',
    expired: timestamp + 600,
    filter_dirty: 0,
    filter_modal: 0,
    filter_punc: 0,
    needvad: 1,
    nonce,
    secretid: secretId,
    timestamp,
    voice_format: 1,
    voice_id: voiceId,
  };
  // 腾讯要求对未编码参数按字典序签名，再编码查询参数。
  const names = Object.keys(parameters).sort();
  // 固定目标域名，客户端无法指定任意转发地址。
  const path = `asr.cloud.tencent.com/asr/v2/${appId}`;
  // 签名原文不得进入日志或客户端响应。
  const source = `${path}?${names.map((name) => `${name}=${parameters[name]}`).join('&')}`;
  // 实时 API 使用 HMAC-SHA1，与文件 API 的 TC3 签名不同。
  const signature = createHmac('sha1', secretKey).update(source).digest('base64');
  // 含凭据的短期 URL 仅用于服务端上游连接。
  const query = names.map((name) => `${name}=${encodeURIComponent(String(parameters[name]))}`).join('&');
  return `wss://${path}?${query}&signature=${encodeURIComponent(signature)}`;
}

/// 腾讯实时识别网络边界，测试替换此边界而不调用真实计费服务。
@Injectable()
export class TencentRealtimeSpeechProvider {
  /// 复用既有 ASR 环境配置，不向客户端下发凭据。
  constructor(private readonly config: ConfigService) {}

  /// 缺少 APP_ID 仅禁用实时识别，不影响既有文件识别或服务器启动。
  configured(): boolean {
    return this.config.get<string>('NOTE_ASR_PROVIDER') === 'tencent'
      && /^\d+$/.test(this.config.get<string>('TENCENT_ASR_APP_ID')?.trim() ?? '')
      && !!this.config.get<string>('TENCENT_ASR_SECRET_ID')?.trim()
      && !!this.config.get<string>('TENCENT_ASR_SECRET_KEY')?.trim();
  }

  /// 每次显式录音新建唯一上游连接，失败不自动重试。
  connect(): WebSocket {
    if (!this.configured()) throw new Error('ASSISTANT_SPEECH_NOT_CONFIGURED');
    // 不读取文件识别模型，实时 PCM 始终匹配固定 16k 引擎。
    const url = tencentRealtimeUrl(
      this.config.getOrThrow<string>('TENCENT_ASR_APP_ID').trim(),
      this.config.getOrThrow<string>('TENCENT_ASR_SECRET_ID').trim(),
      this.config.getOrThrow<string>('TENCENT_ASR_SECRET_KEY').trim(),
      Math.floor(Date.now() / 1000),
      randomInt(1, 10_000_000_000),
      randomUUID(),
    );
    return new WebSocket(url, { handshakeTimeout: 10_000, perMessageDeflate: false, maxPayload: 65_536 });
  }
}
