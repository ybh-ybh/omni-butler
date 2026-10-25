import { ATTACHMENT_LIMITS } from './attachment.types';

/// 按Unicode码点和JSON实际编码成本切分，不能截断代理对或丢失转义字符。
export function splitAttachmentText(text: string): string[] {
  // 每段完整保留原字符，连接后得到原始正文。
  const chunks: string[] = [];
  // 当前块的字符内容。
  let chunk = '';
  // JSON字符串首尾引号也计入单块预算。
  let bytes = 2;
  for (const character of text) {
    // 控制字符、引号和反斜杠按JSON转义后的真实字节计算。
    const cost = Buffer.byteLength(JSON.stringify(character), 'utf8') - 2;
    if (bytes + cost > ATTACHMENT_LIMITS.maxChunkBytes) {
      chunks.push(chunk);
      chunk = '';
      bytes = 2;
    }
    chunk += character;
    bytes += cost;
  }
  if (chunk) chunks.push(chunk);
  return chunks;
}

/// 返回完整JSON的实际UTF-8大小，包装字段与正文共享同一预算。
export function attachmentOutputFits(output: Record<string, unknown>): boolean {
  return (
    Buffer.byteLength(JSON.stringify(output), 'utf8') <=
    ATTACHMENT_LIMITS.maxToolOutputBytes
  );
}
