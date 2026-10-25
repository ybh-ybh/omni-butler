import * as ExcelJS from 'exceljs';
import * as sharp from 'sharp';
import * as childProcess from 'node:child_process';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { AttachmentProcess } from '../src/assistant/attachments/attachment-process';
import {
  inspectOfficeArchive,
  parseAttachment,
} from '../src/assistant/attachments/attachment-parser';
import {
  attachmentDocx,
  attachmentPdf,
  attachmentZip,
} from './assistant-attachment-fixtures';

/// 真实格式解析和独立子进程边界，不访问数据库、MinIO或模型。
describe('助手附件受限解析', () => {
  jest.setTimeout(45000);

  it('解析超时先杀进程并等待close，非零退出不能发布成功JSON', async () => {
    // 可控子进程边界验证资源收尾，不等待真实30秒。
    const child = Object.assign(new EventEmitter(), {
      stdin: new PassThrough(),
      stdout: new PassThrough(),
      kill: jest.fn(() => true),
    });
    // 只替换操作系统进程创建，父进程状态机保持真实。
    const spawning = jest
      .spyOn(childProcess, 'spawn')
      .mockImplementation((() => child) as never);
    jest.useFakeTimers();
    try {
      // 超时之后Promise必须等close才结束。
      const pending = new AttachmentProcess().parse(Buffer.from('x'), 'txt');
      // 观察Promise是否过早释放调用方。
      let settled = false;
      void pending.then(
        () => {
          settled = true;
        },
        () => {
          settled = true;
        },
      );
      jest.advanceTimersByTime(30000);
      await Promise.resolve();
      expect(child.kill).toHaveBeenCalledWith('SIGKILL');
      expect(settled).toBe(false);
      child.emit('close', null, 'SIGKILL');
      await expect(pending).rejects.toMatchObject({
        code: 'ATTACHMENT_PARSE_TIMEOUT',
      });
    } finally {
      spawning.mockRestore();
      jest.useRealTimers();
    }
    // 异常退出即使留下完整JSON，也不能作为解析成功。
    const crashed = Object.assign(new EventEmitter(), {
      stdin: new PassThrough(),
      stdout: new PassThrough(),
      kill: jest.fn(() => true),
    });
    // 新进程隔离上一调用的事件监听。
    const again = jest
      .spyOn(childProcess, 'spawn')
      .mockImplementation((() => crashed) as never);
    try {
      // 成功外形必须与正常退出一起成立。
      const pending = new AttachmentProcess().parse(Buffer.from('x'), 'txt');
      crashed.stdout.emit(
        'data',
        Buffer.from(
          JSON.stringify({ ok: true, result: { chunks: [], images: [] } }),
        ),
      );
      crashed.emit('close', 1, null);
      await expect(pending).rejects.toMatchObject({
        code: 'ATTACHMENT_PARSE_FAILED',
      });
    } finally {
      again.mockRestore();
    }
  });

  it('UTF-8中文段落按来源分块，不能把二进制伪装成文本', async () => {
    // 各段保持独立定位。
    const parsed = await parseAttachment(Buffer.from('第一段\n\n第二段'), 'md');
    expect(parsed.chunks).toEqual([
      { index: 1, paragraph: 1, text: '第一段' },
      { index: 2, paragraph: 2, text: '第二段' },
    ]);
    await expect(
      parseAttachment(Buffer.from([0xff, 0x80]), 'txt'),
    ).rejects.toThrow();
    await expect(
      parseAttachment(Buffer.from('正文\0二进制'), 'txt'),
    ).rejects.toMatchObject({ code: 'ATTACHMENT_INVALID_TEXT' });
  });

  it('Word真正提取段落，旧doc和伪造Office容器不能通过', async () => {
    expect(
      (await parseAttachment(attachmentDocx(), 'docx')).chunks[0],
    ).toMatchObject({ text: '附件中的中文段落', paragraph: 1 });
    await expect(
      parseAttachment(Buffer.from('old-doc'), 'doc'),
    ).rejects.toMatchObject({ code: 'ATTACHMENT_UNSUPPORTED_TYPE' });
    expect(() =>
      inspectOfficeArchive(attachmentZip({ 'unknown.xml': '<root/>' }), 'docx'),
    ).toThrow('ATTACHMENT_INVALID_ARCHIVE');
  });

  it('ZIP拒绝目录穿越、实体、加密和伪造巨大展开声明', () => {
    expect(() =>
      inspectOfficeArchive(attachmentZip({ '../escape': 'x' }), 'docx'),
    ).toThrow('ATTACHMENT_INVALID_ARCHIVE');
    expect(() =>
      inspectOfficeArchive(
        attachmentZip({
          'word/document.xml': '<!DOCTYPE root [<!ENTITY boom "x">]><root/>',
        }),
        'docx',
      ),
    ).toThrow('ATTACHMENT_INVALID_ARCHIVE');
    // 精确修改中央目录标志，验证加密文件在解压前被拒绝。
    const encrypted = attachmentDocx();
    // 中央记录签名定位仅作用于本例合成包。
    const central = encrypted.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
    encrypted.writeUInt16LE(1, central + 8);
    expect(() => inspectOfficeArchive(encrypted, 'docx')).toThrow(
      'ATTACHMENT_ENCRYPTED',
    );
    // 声明大体积但实际文件很小，不能触发无界分配。
    const bomb = attachmentDocx();
    bomb.writeUInt32LE(
      70 * 1024 * 1024,
      bomb.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02])) + 24,
    );
    expect(() => inspectOfficeArchive(bomb, 'docx')).toThrow(
      'ATTACHMENT_ARCHIVE_LIMIT',
    );
  });

  it('Excel保留工作表及行范围，公式只读取缓存结果而不执行', async () => {
    // 工作簿由真实ExcelJS生成，检验解析兼容性。
    const workbook = new ExcelJS.Workbook();
    // 本例数据表包含普通值和公式缓存值。
    const sheet = workbook.addWorksheet('销售');
    sheet.addRow(['名称', '金额']);
    sheet.addRow(['书籍', { formula: '1+1', result: 2 }]);
    // 字节经过与上传相同的ZIP预检。
    const bytes = Buffer.from(await workbook.xlsx.writeBuffer());
    // 单元格坐标用于后续模型引用。
    const result = await parseAttachment(bytes, 'xlsx');
    expect(result.chunks[1]).toMatchObject({
      sheet: '销售',
      rowStart: 2,
      rowEnd: 2,
      text: 'A2: 书籍\tB2: 2',
    });
    expect(
      (await parseAttachment(Buffer.from('名称,金额\n书籍,18'), 'csv'))
        .chunks[1]?.text,
    ).toContain('18');
  });

  it('图片生成有限JPEG，拒绝SVG伪装与损坏字节', async () => {
    // 真PNG在派生图中转换成去元数据JPEG。
    const bytes = await sharp({
      create: { width: 10, height: 10, channels: 3, background: 'red' },
    })
      .png()
      .toBuffer();
    // 限量派生图只存在返回值的内存中。
    const result = await parseAttachment(bytes, 'png');
    expect(result).toMatchObject({ kind: 'image', requiresVision: true });
    expect(
      Buffer.from(result.images[0]!.data, 'base64').subarray(0, 2),
    ).toEqual(Buffer.from([0xff, 0xd8]));
    await expect(
      parseAttachment(
        Buffer.from(
          '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>',
        ),
        'png',
      ),
    ).rejects.toMatchObject({ code: 'ATTACHMENT_INVALID_IMAGE' });
    await expect(parseAttachment(Buffer.from('bad'), 'png')).rejects.toThrow();
  });

  it('真实子进程提取PDF页正文，空白扫描页只转图不伪造OCR结果', async () => {
    // 子进程调用使用生产入口、真实PDFJS与原生画布。
    const process = new AttachmentProcess();
    // 文本PDF保留页号。
    const text = await process.parse(attachmentPdf('Attachment text'), 'pdf');
    expect(text.chunks[0]).toMatchObject({ page: 1, text: 'Attachment text' });
    expect(text.requiresVision).toBe(false);
    // 没有文本的页必须明确要求视觉模型。
    const scan = await process.parse(attachmentPdf(), 'pdf');
    expect(scan.chunks).toEqual([]);
    expect(scan).toMatchObject({
      requiresVision: true,
      images: [{ page: 1, mimeType: 'image/jpeg' }],
    });
    await expect(
      process.parse(Buffer.from('bad pdf'), 'pdf'),
    ).rejects.toMatchObject({ code: 'ATTACHMENT_INVALID_PDF' });
  });
});
