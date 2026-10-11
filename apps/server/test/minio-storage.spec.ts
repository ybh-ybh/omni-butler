import { ConfigService } from '@nestjs/config';
import { DeleteBucketPolicyCommand, GetObjectCommand, HeadBucketCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { MinioConnection } from '../src/storage/minio-connection';
import { MinioNoteAudioStore, NOTE_AUDIO_BUCKET } from '../src/notes/note-audio-store';
import { IMAGE_BUCKET, MinioImageObjectStore } from '../src/images/image-object-store';

/// 只模拟外部S3网络，凭证读取、领域守卫与连接生命周期执行真实实现。
describe('共享私有MinIO存储', () => {
  // 每例独立凭证目录，不能读取正式部署凭证。
  let directory: string;
  // 实际配置与懒加载连接。
  let config: ConfigService;
  // 测试生命周期内唯一共享连接。
  let connection: MinioConnection;
  // SDK网络边界，命令类型和真实参数保持可观察。
  let send: jest.SpyInstance<Promise<unknown>, [unknown]>;

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), 'omni-minio-unit-'));
    writeFileSync(join(directory, 'credentials.json'), JSON.stringify({ accessKeyId: 'test-only', secretAccessKey: 'test-only-secret' }));
    config = new ConfigService({ MINIO_ENDPOINT: 'http://127.0.0.1:9000', MINIO_CREDENTIALS_FILE: join(directory, 'credentials.json'), IMAGE_SYNC_ENABLED: false });
    connection = new MinioConnection(config);
    send = jest.spyOn(S3Client.prototype, 'send').mockImplementation(((): Promise<unknown> => Promise.resolve({})) as never) as unknown as jest.SpyInstance<Promise<unknown>, [unknown]>;
  });
  afterEach(() => { connection.onModuleDestroy(); send.mockRestore(); rmSync(directory, { recursive: true, force: true }); });

  it('实例创建不读凭证且图片关闭不发网络请求，笔记独立创建私有桶', async () => {
    // 图片开关拒绝发生在共享连接使用前。
    const images = new MinioImageObjectStore(config, connection);
    await expect(images.get(`${randomUUID()}/${randomUUID()}/${randomUUID()}`)).rejects.toThrow('图片同步未启用');
    expect(send).not.toHaveBeenCalled();
    // 图片关闭不影响原音真实MIME写入。
    const notes = new MinioNoteAudioStore(connection);
    await notes.put(`${randomUUID()}/${randomUUID()}/${'a'.repeat(64)}`, Buffer.from('audio'), 'audio/wav');
    expect(send.mock.calls.map(([command]) => (command as object).constructor.name)).toEqual(['HeadBucketCommand', 'DeleteBucketPolicyCommand', 'PutObjectCommand']);
    expect((send.mock.calls[2]![0] as PutObjectCommand).input).toMatchObject({ Bucket: NOTE_AUDIO_BUCKET, ContentType: 'audio/wav' });
  });
  it('并发两个领域共享一个客户端，每桶只初始化一次并保留图片开关', async () => {
    // 同时请求两个固定桶和相同原音桶。
    const [audio, image, replay] = await Promise.all([connection.forBucket(NOTE_AUDIO_BUCKET), connection.forBucket(IMAGE_BUCKET), connection.forBucket(NOTE_AUDIO_BUCKET)]);
    expect(audio).toBe(image); expect(replay).toBe(audio);
    expect(send.mock.calls.filter(([command]) => command instanceof HeadBucketCommand)).toHaveLength(2);
    expect(send.mock.calls.filter(([command]) => command instanceof DeleteBucketPolicyCommand)).toHaveLength(2);
    rmSync(join(directory, 'credentials.json'));
    expect(await connection.forBucket(NOTE_AUDIO_BUCKET)).toBe(audio);
  });
  it('断连建桶失败后能重试，不缓存失败初始化或把对象写入磁盘', async () => {
    send.mockRejectedValueOnce(new Error('offline')).mockRejectedValueOnce(new Error('offline')).mockRejectedValueOnce(new Error('offline'));
    // 第一次没有有效桶，上传不能伪装成功。
    const notes = new MinioNoteAudioStore(connection);
    // 服务端生成的稳定对象身份。
    const key = `${randomUUID()}/${randomUUID()}/${'a'.repeat(64)}`;
    await expect(notes.put(key, Buffer.from('audio'), 'audio/wav')).rejects.toThrow('offline');
    expect(send.mock.calls.filter(([command]) => command instanceof PutObjectCommand)).toHaveLength(0);
    await notes.put(key, Buffer.from('audio'), 'audio/wav');
    expect(send.mock.calls.filter(([command]) => command instanceof PutObjectCommand)).toHaveLength(1);
  });
  it('移除匿名策略失败时禁止使用该桶，随后恢复可以重新初始化', async () => {
    send.mockResolvedValueOnce({}).mockRejectedValueOnce(new Error('policy denied'));
    await expect(connection.forBucket(NOTE_AUDIO_BUCKET)).rejects.toThrow('policy denied');
    await expect(connection.forBucket(NOTE_AUDIO_BUCKET)).resolves.toBeInstanceOf(S3Client);
    expect(send.mock.calls.filter(([command]) => command instanceof DeleteBucketPolicyCommand)).toHaveLength(2);
  });
  it('凭证损坏只报固定错误不包含秘密，修复后重新读取', async () => {
    writeFileSync(join(directory, 'credentials.json'), 'this-is-a-sensitive-test-value');
    await expect(connection.forBucket(NOTE_AUDIO_BUCKET)).rejects.toThrow('MinIO 凭证文件无法读取或解析');
    writeFileSync(join(directory, 'credentials.json'), JSON.stringify({ accessKeyId: 'test-only', secretAccessKey: 'test-only-secret' }));
    await expect(connection.forBucket(NOTE_AUDIO_BUCKET)).resolves.toBeInstanceOf(S3Client);
  });
  it('非法对象键在连接前被拒绝，原音和图片不能穿越相对路径', async () => {
    // 两个领域均验证内部键格式。
    const notes = new MinioNoteAudioStore(connection);
    // 图片此处显式启用，确保非法键拒绝不是由开关掩盖。
    const images = new MinioImageObjectStore(new ConfigService({ IMAGE_SYNC_ENABLED: true }), connection);
    for (const key of ['../secret', `${randomUUID()}/${randomUUID()}/${'a'.repeat(64)}/extra`, `${'x'.repeat(36)}/${randomUUID()}/${'a'.repeat(64)}`]) {
      await expect(notes.get(key)).rejects.toThrow('非法原音对象键');
      await expect(images.get(key)).rejects.toThrow('非法图片对象键');
    }
    expect(send).not.toHaveBeenCalled();
  });
  it('完整原音从对象体读出，停机只销毁唯一客户端且不能再次连接', async () => {
    // SDK读出体与原始字节一致。
    send.mockImplementation((command: unknown): Promise<unknown> => Promise.resolve(command instanceof GetObjectCommand ? { Body: { transformToByteArray: (): Promise<Uint8Array> => Promise.resolve(new Uint8Array([1, 2, 3])) } } : {}));
    // 已初始化的生命周期客户端。
    const client = await connection.forBucket(NOTE_AUDIO_BUCKET);
    // 观察唯一客户端资源释放。
    const destroy = jest.spyOn(client, 'destroy');
    expect(await new MinioNoteAudioStore(connection).get(`${randomUUID()}/${randomUUID()}/${'a'.repeat(64)}`)).toEqual(Buffer.from([1, 2, 3]));
    connection.onModuleDestroy(); expect(destroy).toHaveBeenCalledTimes(1);
    await expect(connection.forBucket(NOTE_AUDIO_BUCKET)).rejects.toThrow('正在关闭');
  });
});
