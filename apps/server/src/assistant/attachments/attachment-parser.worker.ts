import { parseAttachment } from './attachment-parser';
import { ATTACHMENT_LIMITS, AttachmentParseError } from './attachment.types';

/// 子进程通过stdin接收有界字节，不接收文件路径或对象存储凭据。
async function run(): Promise<void> {
  // 格式来自服务器允许列表，不由文档内容决定。
  const extension = process.argv[2] ?? '';
  // 原始块仅在当前进程内累计。
  const chunks: Buffer[] = [];
  // 读取阶段也执行字节上限。
  let size = 0;
  try {
    for await (const chunk of process.stdin) {
      // 标准输入始终转换成二进制缓冲区。
      const bytes = Buffer.from(chunk as Uint8Array);
      size += bytes.length;
      if (size > ATTACHMENT_LIMITS.maxFileBytes)
        throw new AttachmentParseError('ATTACHMENT_FILE_LIMIT');
      chunks.push(bytes);
    }
    // 库的console诊断不进入协议输出，也不包含文档正文。
    console.log = (): void => undefined;
    console.warn = (): void => undefined;
    // 结果由父进程验证并分别写入私有对象。
    const result = await parseAttachment(Buffer.concat(chunks), extension);
    process.stdout.write(JSON.stringify({ ok: true, result }));
  } catch (error) {
    process.stdout.write(
      JSON.stringify({
        ok: false,
        code:
          error instanceof AttachmentParseError
            ? error.code
            : 'ATTACHMENT_PARSE_FAILED',
      }),
    );
    process.exitCode = 1;
  }
}

void run();
