import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, createHmac } from 'node:crypto';
import { SpeechProviderError, SpeechRecognitionProvider, type SpeechPollResult } from './speech-provider';

/// 腾讯云 API 3.0 TC3 签名；不引入厂商 SDK 到笔记领域。
export function tencentHeaders(secretId: string, secretKey: string, action: string, payload: string, timestamp: number): Record<string, string> {
  // 腾讯云录音文件识别固定域名。
  const host = 'asr.tencentcloudapi.com';
  // UTC 日期作为签名范围。
  const date = new Date(timestamp * 1000).toISOString().slice(0, 10);
  // 与实际发送完全相同的 Content-Type。
  const contentType = 'application/json; charset=utf-8';
  // 规范请求包含 action，防止跨操作重放。
  const signedHeaders = 'content-type;host;x-tc-action';
  // 规范请求中的实际负载摘要。
  const canonical = `POST\n/\n\ncontent-type:${contentType}\nhost:${host}\nx-tc-action:${action.toLowerCase()}\n\n${signedHeaders}\n${createHash('sha256').update(payload).digest('hex')}`;
  // 服务商签名凭证范围。
  const scope = `${date}/asr/tc3_request`;
  // 待签名文本。
  const toSign = `TC3-HMAC-SHA256\n${timestamp}\n${scope}\n${createHash('sha256').update(canonical).digest('hex')}`;
  // 逐级派生的 HMAC 密钥，不输出到日志。
  const dateKey = createHmac('sha256', `TC3${secretKey}`).update(date).digest();
  // 当前服务密钥。
  const serviceKey = createHmac('sha256', dateKey).update('asr').digest();
  // 最终签名密钥。
  const signingKey = createHmac('sha256', serviceKey).update('tc3_request').digest();
  // 当前请求的签名。
  const signature = createHmac('sha256', signingKey).update(toSign).digest('hex');
  return {
    Authorization: `TC3-HMAC-SHA256 Credential=${secretId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
    'Content-Type': contentType,
    'X-TC-Action': action,
    'X-TC-Version': '2019-06-14',
    'X-TC-Timestamp': String(timestamp),
  };
}

/// 腾讯云录音文件识别适配器；只接受内置私有链接或已校验的文件。
@Injectable()
export class TencentSpeechProvider extends SpeechRecognitionProvider {
  /// 稳定服务商标识。
  readonly name = 'tencent';
  /// 注入服务端配置，客户端永远拿不到 SecretId/SecretKey。
  constructor(private readonly config: ConfigService) { super(); }
  /// 只有服务商和完整凭证同时配置才可提交。
  configured(): boolean { return this.config.get<string>('NOTE_ASR_PROVIDER') === this.name && !!this.config.get<string>('TENCENT_ASR_SECRET_ID') && !!this.config.get<string>('TENCENT_ASR_SECRET_KEY'); }
  /// 不附加付费语义润色、摘要或其他非首版能力。
  async submit(input: { model: string; audioUrl?: string; bytes?: Buffer }): Promise<string> {
    if (!this.configured()) throw new SpeechProviderError('ASR_NOT_CONFIGURED');
    if (!input.audioUrl && (!input.bytes || input.bytes.length > 5 * 1024 * 1024)) throw new SpeechProviderError('ASR_PUBLIC_URL_REQUIRED');
    // 腾讯云录音识别参数，保留原语气词和标点。
    const parameters = { EngineModelType: input.model, ChannelNum: 1, ResTextFormat: 0, SourceType: input.audioUrl ? 0 : 1, ...(input.audioUrl ? { Url: input.audioUrl } : { Data: input.bytes!.toString('base64'), DataLen: input.bytes!.length }), FilterModal: 0, FilterPunc: 0, FilterDirty: 0 };
    // 创建结果，数字任务身份不作为本系统业务主键。
    const result = await this.request('CreateRecTask', parameters, true);
    // 服务商实际返回的远端身份。
    const taskId = result.Data?.TaskId;
    if (!Number.isSafeInteger(taskId) || !taskId || taskId < 0) throw new SpeechProviderError('ASR_INVALID_TASK_RESPONSE', true);
    return String(taskId);
  }
  /// 仅查询同一任务，不创建替代任务。
  async poll(taskId: string): Promise<SpeechPollResult> {
    // 持久化远端任务标识。
    const numericId = Number(taskId);
    if (!Number.isSafeInteger(numericId) || numericId <= 0) throw new SpeechProviderError('ASR_INVALID_TASK_ID');
    // 查询结果。
    const result = await this.request('DescribeTaskStatus', { TaskId: numericId }, false);
    if (!result.Data || ![0, 1, 2, 3].includes(result.Data.Status ?? -1)) throw new SpeechProviderError('ASR_INVALID_POLL_RESPONSE');
    if (result.Data.Status === 2) return { status: 'succeeded', transcript: (result.Data.Result ?? '').split('\n').map((line) => line.replace(/^\[\d+:\d+(?:\.\d+)?,\d+:\d+(?:\.\d+)?\]\s*/, '')).join('\n').trim() };
    if (result.Data.Status === 3) return { status: 'failed', errorCode: 'ASR_RECOGNITION_FAILED' };
    return { status: 'processing' };
  }
  /// 一次 HTTP 调用不自动重试；异常只暴露固定错误码。
  private async request(action: string, parameters: object, submitting: boolean): Promise<TencentResponse> {
    // 实际签名的 JSON 字节。
    const payload = JSON.stringify(parameters);
    // 当前 UTC 秒数。
    const timestamp = Math.floor(Date.now() / 1000);
    // 实际网络响应。
    let response: Response;
    try {
      response = await fetch('https://asr.tencentcloudapi.com', { method: 'POST', headers: tencentHeaders(this.config.getOrThrow<string>('TENCENT_ASR_SECRET_ID'), this.config.getOrThrow<string>('TENCENT_ASR_SECRET_KEY'), action, payload, timestamp), body: payload, signal: AbortSignal.timeout(30000) });
    } catch { throw new SpeechProviderError('ASR_NETWORK_ERROR', submitting); }
    // 不信任代理返回 HTML 或截断响应。
    let envelope: { Response?: TencentResponse };
    try { envelope = await response.json() as { Response?: TencentResponse }; } catch { throw new SpeechProviderError('ASR_INVALID_RESPONSE', submitting); }
    if (envelope.Response?.Error?.Code) throw new SpeechProviderError(envelope.Response.Error.Code);
    if (!response.ok || !envelope.Response) throw new SpeechProviderError('ASR_HTTP_ERROR', submitting);
    return envelope.Response;
  }
}

/// 只读取需要使用的服务商响应字段，原正文和鉴权信息不进入错误日志。
interface TencentResponse {
  /// 服务商明确失败。
  Error?: { Code: string };
  /// 任务身份及轮询结果。
  Data?: { TaskId?: number; Status?: number; Result?: string };
}
