import { ConfigService } from '@nestjs/config';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../src/auth/auth.types';
import type { AssistantAttachment } from '../src/generated/prisma/client';
import type { PrismaService } from '../src/prisma/prisma.service';
import { AssistantAttachmentsService } from '../src/assistant/attachments/assistant-attachments.service';
import type { AttachmentObjectStore } from '../src/assistant/attachments/attachment-object-store';
import type { AttachmentProcess } from '../src/assistant/attachments/attachment-process';
import { parseAttachment } from '../src/assistant/attachments/attachment-parser';
import { splitAttachmentText } from '../src/assistant/attachments/attachment-output';
import {
  ATTACHMENT_LIMITS,
  type AttachmentChunk,
} from '../src/assistant/attachments/attachment.types';

/// 隔离已授权清单读取，只验证真实解析分块与公开工具输出的字节边界。
describe('助手附件工具完整JSON预算', () => {
  /// 有效身份仅用于调用公开方法，授权存储边界由下方清单替身代替。
  const actor: AuthUser = {
    sub: randomUUID(),
    sid: randomUUID(),
    typ: 'access',
  };
  /// 当前会话的稳定测试身份。
  const conversationId = randomUUID();
  /// 当前附件身份用于验证分页不跳转到其他来源。
  const attachmentId = randomUUID();

  /// 仅替换持久清单加载，read/search本身执行真实实现。
  function fixture(
    chunks: AttachmentChunk[],
    // 图片和扫描PDF使用各自实际存储的页码形状。
    rowOverrides: Partial<AssistantAttachment> = {},
  ): AssistantAttachmentsService {
    // 不会访问这些依赖，私有清单边界在下一行被精确替换。
    const service = new AssistantAttachmentsService(
      {} as PrismaService,
      {} as AttachmentObjectStore,
      {} as AttachmentProcess,
      new ConfigService(),
    );
    // 名称使用长中文，以验证包装字段同样计入UTF-8预算。
    const row = {
      id: attachmentId,
      name: `${'中文'.repeat(80)}.txt`,
      chunkCount: chunks.length,
      imageKeys: null,
      kind: 'document',
      ...rowOverrides,
    } as unknown as AssistantAttachment;
    jest
      .spyOn(
        service as unknown as {
          manifest: () => Promise<{
            row: AssistantAttachment;
            manifest: { version: 1; chunks: AttachmentChunk[] };
          }>;
        },
        'manifest',
      )
      .mockResolvedValue({ row, manifest: { version: 1, chunks } });
    return service;
  }

  it('普通图片显式读取第1页返回规范图像引用，第2页仍拒绝', async () => {
    // 普通图片存储没有页号，不能把模型传入的第1页写进hydrate引用。
    const service = fixture([], {
      kind: 'image',
      name: '截图.png',
      imageKeys: [{ key: 'private-image-key' }],
    });
    // 默认读取与显式第1页必须获得同一个可hydrate身份。
    const defaultRead = await service.read(actor, conversationId, attachmentId);
    // 模型常把图片看作单页资料，这一参数应兼容普通图片。
    const firstPage = await service.read(actor, conversationId, attachmentId, {
      page: 1,
    });
    expect(defaultRead.images).toEqual([{ attachmentId }]);
    expect(firstPage.images).toEqual(defaultRead.images);
    expect(firstPage).toMatchObject({ page: 1, chunks: [], truncated: false });
    expect(JSON.stringify(firstPage)).not.toContain('private-image-key');
    await expect(
      service.read(actor, conversationId, attachmentId, { page: 2 }),
    ).rejects.toThrow('没有该读取范围');
  });

  it('扫描PDF只返回显式读取页的真实页码，不套用普通图片第1页兼容', async () => {
    // 文档可能仅部分页为扫描图，页号必须沿用解析产物。
    const service = fixture([], {
      kind: 'document',
      name: '扫描.pdf',
      imageKeys: [{ key: 'scan-page-two', page: 2 }],
    });
    expect(
      await service.read(actor, conversationId, attachmentId, { page: 2 }),
    ).toMatchObject({ images: [{ attachmentId, page: 2 }] });
    await expect(
      service.read(actor, conversationId, attachmentId, { page: 1 }),
    ).rejects.toThrow('没有该读取范围');
    expect(
      (await service.read(actor, conversationId, attachmentId)).images,
    ).toBeUndefined();
  });

  it('纯图片文本搜索明确无提取文字并引导读图，不把空匹配当作能力失败', async () => {
    // 保留较长名称，确认新增说明同样受完整JSON预算约束。
    const service = fixture([], {
      kind: 'image',
      imageKeys: [{ key: 'private-image-key' }],
    });
    // 仅搜索已提取文本，不自动OCR或把图片内容假造为匹配。
    const output = await service.search(
      actor,
      conversationId,
      attachmentId,
      '图片里的文字',
    );
    expect(output).toMatchObject({ matches: [], totalMatches: 0, truncated: false });
    expect(output.message).toContain('没有可检索的提取文字');
    expect(output.message).toContain('read_attachment');
    expect(
      Buffer.byteLength(JSON.stringify(output), 'utf8'),
    ).toBeLessThanOrEqual(ATTACHMENT_LIMITS.maxToolOutputBytes);
    expect(JSON.stringify(output)).not.toContain('private-image-key');
    expect(
      (await fixture([]).search(actor, conversationId, attachmentId, '文字')).message,
    ).toBeUndefined();
  });

  it('按Unicode码点和JSON转义成本分块，完整拼回中文、emoji和控制字符', () => {
    // 控制字符在JSON里比原始UTF-8字节更长。
    const source = `${'中文🙂"\\\u0001'.repeat(2500)}结尾`;
    // 不经过编码替换，因此原始字符必须逐个保留。
    const chunks = splitAttachmentText(source);
    expect(chunks.join('')).toBe(source);
    expect(chunks.length).toBeGreaterThan(2);
    for (const chunk of chunks) {
      expect(
        Buffer.byteLength(JSON.stringify(chunk), 'utf8'),
      ).toBeLessThanOrEqual(ATTACHMENT_LIMITS.maxChunkBytes);
      expect(Buffer.from(chunk).toString('utf8')).toBe(chunk);
    }
  });

  it('真实解析后的长中文可在16KiB完整JSON范围内逐块翻页，不丢正文', async () => {
    // 一段长文本同时包含多字节字符和需要JSON转义的字符。
    const source = `${'中文🙂"\\\u0001'.repeat(6000)}最后一字`;
    // 使用生产解析器建立稳定分块编号。
    const parsed = await parseAttachment(Buffer.from(source), 'txt');
    // 公共read方法仍负责来源筛选、实际范围与分页元数据。
    const service = fixture(parsed.chunks);
    // 已完整读出的正文按返回块顺序追加。
    const received: string[] = [];
    // 下一次请求始终使用服务返回的明确游标。
    let start = 1;
    // 页数必须有界，错误游标不能无限循环。
    let pages = 0;
    while (pages++ <= parsed.chunks.length) {
      // 与模型实际调用相同，只提交start，不猜测字节截断位置。
      const output = await service.read(actor, conversationId, attachmentId, {
        start,
      });
      expect(
        Buffer.byteLength(JSON.stringify(output), 'utf8'),
      ).toBeLessThanOrEqual(ATTACHMENT_LIMITS.maxToolOutputBytes);
      // 返回的块必须完整，实际end等于最后一块编号。
      const chunks = output.chunks as AttachmentChunk[];
      expect(chunks.length).toBeGreaterThan(0);
      expect(output.end).toBe(chunks.at(-1)!.index);
      received.push(...chunks.map((chunk) => chunk.text));
      if (!output.truncated) {
        expect(output.nextStart).toBeUndefined();
        break;
      }
      expect(output.nextStart).toBe(chunks.at(-1)!.index + 1);
      start = output.nextStart as number;
    }
    expect(pages).toBeGreaterThan(1);
    expect(pages).toBeLessThanOrEqual(parsed.chunks.length);
    expect(received.join('')).toBe(source);
  });

  it('search包含转义片段与来源包装时同样有界，并明确剩余匹配位置', async () => {
    // 同一短片段包含高转义成本文本，十条不能盲目按字符数返回。
    const chunks = Array.from({ length: 10 }, (_, index) => ({
      index: index + 1,
      sheet: '"'.repeat(200),
      rowStart: index + 1,
      rowEnd: index + 1,
      text: `${'\u0001'.repeat(300)}命中${'🙂'.repeat(400)}`,
    }));
    // 搜索保持实际来源编号，方便后续read_attachment读取全文。
    const result = await fixture(chunks).search(
      actor,
      conversationId,
      attachmentId,
      '命中',
    );
    expect(
      Buffer.byteLength(JSON.stringify(result), 'utf8'),
    ).toBeLessThanOrEqual(ATTACHMENT_LIMITS.maxToolOutputBytes);
    expect(result.truncated).toBe(true);
    // 只截取整个匹配结果，不截断序列化JSON。
    const matches = result.matches as AttachmentChunk[];
    expect(matches.length).toBeGreaterThan(0);
    expect(result.nextStart).toBe(matches.length + 1);
    expect(result.totalMatches).toBe(10);
    for (const match of matches)
      expect(Buffer.from(match.text).toString('utf8')).toBe(match.text);
  });
});
