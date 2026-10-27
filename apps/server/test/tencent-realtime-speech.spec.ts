import { ConfigService } from '@nestjs/config';
import { createHmac } from 'node:crypto';
import { TencentRealtimeSpeechProvider, tencentRealtimeUrl } from '../src/assistant/speech/tencent-realtime-speech.provider';

/// 实时签名格式与配置能力检查，不发起任何厂商网络请求。
describe('TencentRealtimeSpeechProvider', () => {
  it('签名使用固定主机与有序未编码参数，特殊签名字符经过 URL 编码', (): void => {
    // 完全公开的测试参数，没有实际云账号凭据。
    const url = new URL(tencentRealtimeUrl('1234567890', 'example-id', 'example-key', 1_700_000_000, 123, 'test-voice'));
    // 独立写出的固定规范签名输入，检查漏字段和参数排序变化。
    const canonical = 'asr.cloud.tencent.com/asr/v2/1234567890?engine_model_type=16k_zh&expired=1700000600&filter_dirty=0&filter_modal=0&filter_punc=0&needvad=1&nonce=123&secretid=example-id&timestamp=1700000000&voice_format=1&voice_id=test-voice';
    expect(url.searchParams.get('signature')).toBe(createHmac('sha1', 'example-key').update(canonical).digest('base64'));
    expect(url.protocol).toBe('wss:');
    expect(url.host).toBe('asr.cloud.tencent.com');
    expect(url.searchParams.get('engine_model_type')).toBe('16k_zh');
    expect(url.toString()).not.toContain('example-key');
    expect(url.searchParams.has('emotion_recognition')).toBe(false);
    expect(url.toString()).toContain('%3D');
  });

  it('实时识别要求三项既有凭据，缺少 APP_ID 不尝试连接', (): void => {
    // 只允许使用明确的非真实占位凭据。
    const config = new ConfigService({ NOTE_ASR_PROVIDER: 'tencent', TENCENT_ASR_SECRET_ID: 'example-id', TENCENT_ASR_SECRET_KEY: 'example-key' });
    // 固定供应商适配器，不触发 connect 的有效配置路径。
    const provider = new TencentRealtimeSpeechProvider(config);
    expect(provider.configured()).toBe(false);
    expect(() => provider.connect()).toThrow('ASSISTANT_SPEECH_NOT_CONFIGURED');
    config.set('TENCENT_ASR_APP_ID', '1234567890');
    expect(provider.configured()).toBe(true);
    config.set('NOTE_ASR_PROVIDER', 'none');
    expect(provider.configured()).toBe(false);
  });
});
