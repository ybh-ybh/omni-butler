import { ConfigService } from '@nestjs/config';
import { HeadObjectCommand } from '@aws-sdk/client-s3';
import { createServer, request as proxyRequest, type Server } from 'node:http';
import { randomUUID } from 'node:crypto';
import { MinioConnection } from '../src/storage/minio-connection';
import { MinioNoteAudioStore, NOTE_AUDIO_BUCKET } from '../src/notes/note-audio-store';
import { MinioImageObjectStore } from '../src/images/image-object-store';

/// 只访问父任务明确提供的隔离本机MinIO；默认不尝试连接正式部署。
const endpoint = process.env.OMNI_NOTES_TEST_MINIO_ENDPOINT;
/// 凭证只从忽略的本机测试文件读取，不打印内容。
const credentialsFile = process.env.OMNI_NOTES_TEST_MINIO_CREDENTIALS_FILE;
/// 没有资源明确跳过，不把外部存储跳过当作已通过。
const integration = endpoint && credentialsFile ? describe : describe.skip;

integration('真实隔离MinIO私有原音存储', () => {
  jest.setTimeout(60000);
  // 每例独立客户端生命周期。
  let connection: MinioConnection;
  // 本例所有对象只使用随机独立身份，结束精确清理。
  let keys: string[];
  // 仅本例监听的断连注入代理。
  let proxy: Server | undefined;

  beforeAll(() => { if (new URL(endpoint!).hostname !== '127.0.0.1' || new URL(endpoint!).protocol !== 'http:') throw new Error('MinIO集成只允许明确的本机HTTP隔离实例'); });
  beforeEach(() => { connection = new MinioConnection(new ConfigService({ MINIO_ENDPOINT: endpoint, MINIO_CREDENTIALS_FILE: credentialsFile })); keys = []; });
  afterEach(async () => {
    // 只清理本例创建的键，不删除桶或其他任务对象。
    const notes = new MinioNoteAudioStore(connection);
    for (const key of keys) await notes.delete(key);
    connection.onModuleDestroy();
    if (proxy) { proxy.closeAllConnections(); await new Promise<void>((resolve, reject) => proxy!.close((error) => error ? reject(error) : resolve())); proxy = undefined; }
  });

  /// 随机键符合生产对象路径，无测试公共前缀绕过权限检查。
  function key(): string { return `${randomUUID()}/${randomUUID()}/${'a'.repeat(64)}`; }

  it('图片关闭时原音真实上传与读出、MIME持久化、匿名拒绝、删除幂等', async () => {
    // 图片关闭不影响原音独立初始化。
    const notes = new MinioNoteAudioStore(connection);
    // 本例原音的唯一对象身份。
    const objectKey = key(); keys.push(objectKey);
    // 真实WAV容器头部仅验证字节存储，不调用ASR。
    const bytes = Buffer.from('RIFF-real-minio-storage-WAVE');
    await notes.put(objectKey, bytes, 'audio/wav');
    expect(await notes.get(objectKey)).toEqual(bytes);
    // 使用签名S3请求读取实际对象元数据。
    const client = await connection.forBucket(NOTE_AUDIO_BUCKET);
    expect((await client.send(new HeadObjectCommand({ Bucket: NOTE_AUDIO_BUCKET, Key: objectKey }))).ContentType).toBe('audio/wav');
    expect((await fetch(`${endpoint}/${NOTE_AUDIO_BUCKET}/${objectKey}`)).status).toBe(403);
    await notes.delete(objectKey); await notes.delete(objectKey);
    await expect(notes.get(objectKey)).rejects.toMatchObject({ name: 'NoSuchKey' });
  });
  it('图片启用后仍共享同一客户端且分别存储私有桶，不混用领域键', async () => {
    // 共用生产连接，但两个领域对象桶各自固定。
    const images = new MinioImageObjectStore(new ConfigService({ IMAGE_SYNC_ENABLED: true }), connection);
    // 图片只清理本例独立UUID键。
    const imageKey = `${randomUUID()}/${randomUUID()}/${randomUUID()}`;
    try {
      await images.put(imageKey, Buffer.from('private-image'), 'image/png');
      expect(await images.get(imageKey)).toEqual(Buffer.from('private-image'));
      expect((await fetch(`${endpoint}/omni-butler-images/${imageKey}`)).status).toBe(403);
      expect(await connection.forBucket('omni-butler-images')).toBe(await connection.forBucket(NOTE_AUDIO_BUCKET));
      await expect(new MinioNoteAudioStore(connection).get(imageKey)).rejects.toThrow('非法原音对象键');
    } finally { await images.delete(imageKey); }
  });
  it('真实TCP代理断连令初始化和对象读取失败，恢复后同实例重试可用且不落盘', async () => {
    // 仅代理本测试请求，绝不停止或修改共享MinIO容器。
    let offline = true;
    proxy = createServer((incoming, outgoing) => {
      if (offline) { incoming.socket.destroy(); return; }
      // S3签名的原Host保持不变，让后端验证真实签名而非测试替身。
      const forwarded = proxyRequest(new URL(incoming.url!, endpoint), { method: incoming.method, headers: incoming.headers }, (response) => { outgoing.writeHead(response.statusCode!, response.headers); response.pipe(outgoing); });
      forwarded.on('error', () => outgoing.destroy()); incoming.pipe(forwarded);
    });
    await new Promise<void>((resolve) => proxy!.listen(0, '127.0.0.1', resolve));
    // 只为本例创建代理客户端，退出释放连接池。
    const proxied = new MinioConnection(new ConfigService({ MINIO_ENDPOINT: `http://127.0.0.1:${(proxy.address() as { port: number }).port}`, MINIO_CREDENTIALS_FILE: credentialsFile }));
    // 同一存储实例跨断连恢复验证失败缓存清理。
    const notes = new MinioNoteAudioStore(proxied);
    // 即使初次失败也将本例身份放入精确清理清单。
    const objectKey = key(); keys.push(objectKey);
    try {
      await expect(notes.put(objectKey, Buffer.from('recoverable-audio'), 'audio/wav')).rejects.toBeDefined();
      offline = false; await notes.put(objectKey, Buffer.from('recoverable-audio'), 'audio/wav');
      expect(await notes.get(objectKey)).toEqual(Buffer.from('recoverable-audio'));
      offline = true; await expect(notes.get(objectKey)).rejects.toBeDefined();
      offline = false; expect(await notes.get(objectKey)).toEqual(Buffer.from('recoverable-audio'));
    } finally { proxied.onModuleDestroy(); }
  });
});
