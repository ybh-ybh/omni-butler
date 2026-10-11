import { ConfigService } from '@nestjs/config';
import { TencentSpeechProvider, tencentHeaders } from '../src/notes/tencent-speech.provider';

/// 测试只替换网络边界，不读取部署或用户密钥。
describe('TencentSpeechProvider', () => {
  // 明确非用户秘密的占位配置。
  const provider = new TencentSpeechProvider(new ConfigService({ NOTE_ASR_PROVIDER: 'tencent', TENCENT_ASR_SECRET_ID: 'example-id', TENCENT_ASR_SECRET_KEY: 'example-secret' }));
  // 捕获真实厂商请求。
  let mockedFetch: jest.SpyInstance;
  beforeEach(() => { mockedFetch = jest.spyOn(globalThis, 'fetch'); });
  afterEach(() => { mockedFetch.mockRestore(); });
  it('签名绑定服务、日期、action和负载', () => {
    // 固定UTC秒数，保证签名结果可重复。
    const headers = tencentHeaders('example-id', 'example-secret', 'CreateRecTask', '{"a":1}', 1728000000);
    expect(headers.Authorization).toMatch(/^TC3-HMAC-SHA256 Credential=example-id\/2024-10-04\/asr\/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature=[a-f0-9]{64}$/);
    expect(headers.Authorization).not.toBe(tencentHeaders('example-id', 'example-secret', 'CreateRecTask', '{"a":2}', 1728000000).Authorization);
    expect(headers.Authorization).not.toBe(tencentHeaders('example-id', 'example-secret', 'DescribeTaskStatus', '{"a":1}', 1728000000).Authorization);
  });
  it('只提交一次且不附加付费语义润色', async () => {
    mockedFetch.mockResolvedValue(new Response(JSON.stringify({ Response: { Data: { TaskId: 12345 } } })));
    await expect(provider.submit({ model: '16k_zh', bytes: Buffer.from('test-audio') })).resolves.toBe('12345');
    expect(mockedFetch).toHaveBeenCalledTimes(1);
    // 发往服务商的实际参数。
    const calls = mockedFetch.mock.calls as [string, RequestInit][];
    // 单次请求的已知字符串 JSON。
    const options = calls[0]![1];
    expect(JSON.parse(options.body as string)).toMatchObject({ SourceType: 1, DataLen: 10, ResTextFormat: 0, ChannelNum: 1, FilterModal: 0 });
    expect(options.headers).toMatchObject({ 'X-TC-Action': 'CreateRecTask' });
  });
  it('超过5MB无URL拒绝且不发送请求', async () => {
    await expect(provider.submit({ model: '16k_zh', bytes: Buffer.alloc(5 * 1024 * 1024 + 1) })).rejects.toMatchObject({ code: 'ASR_PUBLIC_URL_REQUIRED', submissionUncertain: false });
    expect(mockedFetch).not.toHaveBeenCalled();
  });
  it('提交断网是未知结果且绝不自动重复计费', async () => {
    mockedFetch.mockRejectedValue(new Error('timeout'));
    await expect(provider.submit({ model: '16k_zh', bytes: Buffer.from('audio') })).rejects.toMatchObject({ code: 'ASR_NETWORK_ERROR', submissionUncertain: true });
    expect(mockedFetch).toHaveBeenCalledTimes(1);
    mockedFetch.mockResolvedValue(new Response(JSON.stringify({ Response: { Error: { Code: 'AuthFailure.SecretIdNotFound' } } })));
    await expect(provider.submit({ model: '16k_zh', bytes: Buffer.from('audio') })).rejects.toMatchObject({ code: 'AuthFailure.SecretIdNotFound', submissionUncertain: false });
  });
  it('完成查询只使用原TaskId且不提交新任务', async () => {
    mockedFetch.mockResolvedValue(new Response(JSON.stringify({ Response: { Data: { Status: 2, Result: '今天完成日报。' } } })));
    await expect(provider.poll('12345')).resolves.toEqual({ status: 'succeeded', transcript: '今天完成日报。' });
    // 实际轮询请求。
    const calls = mockedFetch.mock.calls as [string, RequestInit][];
    // 实际查询请求的配置。
    const options = calls[0]![1];
    expect(options.headers).toMatchObject({ 'X-TC-Action': 'DescribeTaskStatus' });
    expect(JSON.parse(options.body as string)).toEqual({ TaskId: 12345 });
  });
});
