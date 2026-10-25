import { inflateRawSync } from 'node:zlib';
import { Readable } from 'node:stream';
import * as mammoth from 'mammoth';
import * as ExcelJS from 'exceljs';
import * as sharp from 'sharp';
import { createCanvas } from '@napi-rs/canvas';
import { splitAttachmentText } from './attachment-output';
import {
  ATTACHMENT_LIMITS as limits,
  AttachmentParseError,
  type AttachmentChunk,
  type ParsedAttachment,
} from './attachment.types';

/// 压缩包预检同时限制声明体积和实际展开体积，拒绝加密及路径穿越。
export function inspectOfficeArchive(bytes: Buffer, extension: string): void {
  // ZIP尾目录必须位于文件末尾的有限窗口内。
  let end = -1;
  for (
    let offset = bytes.length - 22;
    offset >= Math.max(0, bytes.length - 65557);
    offset--
  ) {
    if (
      bytes.readUInt32LE(offset) === 0x06054b50 &&
      offset + 22 + bytes.readUInt16LE(offset + 20) === bytes.length
    ) {
      end = offset;
      break;
    }
  }
  if (end < 0 || bytes.readUInt16LE(end + 4) || bytes.readUInt16LE(end + 6))
    throw new AttachmentParseError('ATTACHMENT_INVALID_ARCHIVE');
  // 不支持ZIP64及分卷，常规Office文件不需要它们。
  const count = bytes.readUInt16LE(end + 10);
  // 目录游标只能在中央目录范围内递增。
  let cursor = bytes.readUInt32LE(end + 16);
  // 累计展开量覆盖所有项目，包括嵌入资源。
  let expanded = 0;
  // 去重后的项目名用于验证真正的Office容器。
  const names = new Set<string>();
  if (
    !count ||
    count > 2048 ||
    cursor >= end ||
    bytes.readUInt16LE(end + 8) !== count
  )
    throw new AttachmentParseError('ATTACHMENT_ARCHIVE_LIMIT');
  for (let index = 0; index < count; index++) {
    if (cursor + 46 > end || bytes.readUInt32LE(cursor) !== 0x02014b50)
      throw new AttachmentParseError('ATTACHMENT_INVALID_ARCHIVE');
    // 中央目录给出可靠的压缩尺寸，实际展开仍单独校验。
    const flags = bytes.readUInt16LE(cursor + 8);
    // 仅允许标准的无压缩与deflate。
    const method = bytes.readUInt16LE(cursor + 10);
    // 输入输出大小均不可超过固定预算。
    const compressedSize = bytes.readUInt32LE(cursor + 20);
    // 实际展开长度必须与该声明一致。
    const uncompressedSize = bytes.readUInt32LE(cursor + 24);
    // 文件名长度不参与可变路径访问。
    const nameLength = bytes.readUInt16LE(cursor + 28);
    // 中央目录额外段长度。
    const extraLength = bytes.readUInt16LE(cursor + 30);
    // 注释长度仅用于跳过。
    const commentLength = bytes.readUInt16LE(cursor + 32);
    // 本地头位置必须落在原始缓冲区内。
    const local = bytes.readUInt32LE(cursor + 42);
    // 名称仅检查合法性，不用于写入磁盘。
    const name = bytes
      .subarray(cursor + 46, cursor + 46 + nameLength)
      .toString('utf8');
    if (flags & 1) throw new AttachmentParseError('ATTACHMENT_ENCRYPTED');
    if (
      ![0, 8].includes(method) ||
      !name ||
      name.includes('\\') ||
      name.startsWith('/') ||
      name.includes('\0') ||
      name.split('/').includes('..') ||
      names.has(name)
    )
      throw new AttachmentParseError('ATTACHMENT_INVALID_ARCHIVE');
    names.add(name);
    expanded += uncompressedSize;
    if (
      expanded > limits.maxExpandedBytes ||
      uncompressedSize > limits.maxExpandedBytes ||
      uncompressedSize > Math.max(1024 * 1024, compressedSize * 200)
    )
      throw new AttachmentParseError('ATTACHMENT_ARCHIVE_LIMIT');
    if (local + 30 > cursor || bytes.readUInt32LE(local) !== 0x04034b50)
      throw new AttachmentParseError('ATTACHMENT_INVALID_ARCHIVE');
    // 本地正文起点由有限头字段推导。
    const dataStart =
      local +
      30 +
      bytes.readUInt16LE(local + 26) +
      bytes.readUInt16LE(local + 28);
    if (dataStart + compressedSize > cursor)
      throw new AttachmentParseError('ATTACHMENT_INVALID_ARCHIVE');
    // 解压在子进程内进行，maxOutputLength防止伪造声明后的膨胀。
    const compressed = bytes.subarray(dataStart, dataStart + compressedSize);
    // 不保存展开内容；后续解析器只接收已验证的原容器。
    const unpacked =
      method === 0
        ? compressed
        : inflateRawSync(compressed, {
            maxOutputLength: Math.max(1, uncompressedSize),
          });
    if (
      unpacked.length !== uncompressedSize ||
      (/\.xml$|\.rels$/i.test(name) &&
        /<!DOCTYPE|<!ENTITY/i.test(
          unpacked.toString('utf8').replace(/\0/g, ''),
        ))
    )
      throw new AttachmentParseError('ATTACHMENT_INVALID_ARCHIVE');
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  if (
    cursor !== end ||
    !names.has('[Content_Types].xml') ||
    !names.has(extension === 'docx' ? 'word/document.xml' : 'xl/workbook.xml')
  )
    throw new AttachmentParseError('ATTACHMENT_INVALID_ARCHIVE');
}

/// 文本分块保留来源定位，同时限制总字符数。
function appendText(
  result: ParsedAttachment,
  value: string,
  location: Omit<AttachmentChunk, 'text' | 'index'>,
): void {
  // 只清除NUL，不执行任何文档内容。
  const text = value.replace(/\0/g, '').trim();
  // 已有分块长度决定整个文件预算。
  const existing = result.chunks.reduce(
    (sum, chunk) => sum + chunk.text.length,
    0,
  );
  if (existing + text.length > limits.maxTextCharacters)
    throw new AttachmentParseError('ATTACHMENT_TEXT_LIMIT');
  for (const chunk of splitAttachmentText(text)) {
    if (result.chunks.length >= limits.maxChunks)
      throw new AttachmentParseError('ATTACHMENT_TEXT_LIMIT');
    result.chunks.push({
      index: result.chunks.length + 1,
      text: chunk,
      ...location,
    });
  }
}

/// 图片转换移除元数据，只保留有界JPEG供视觉模型读取。
async function imageVersion(bytes: Buffer): Promise<Buffer> {
  // 在调用原生解码器前只允许静态PNG、JPEG或WebP魔数，SVG不会进入解析器。
  const signature = bytes.subarray(0, 12);
  if (
    !(
      signature
        .subarray(0, 8)
        .equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) ||
      signature.subarray(0, 3).equals(Buffer.from([255, 216, 255])) ||
      (signature.subarray(0, 4).toString('ascii') === 'RIFF' &&
        signature.subarray(8, 12).toString('ascii') === 'WEBP')
    )
  )
    throw new AttachmentParseError('ATTACHMENT_INVALID_IMAGE');
  // 像素限制先于解码，防止小文件超大画布。
  const source = sharp(bytes, {
    limitInputPixels: 25_000_000,
    animated: false,
    failOn: 'error',
  });
  // 真实格式检查避免把SVG等主动内容伪装成图片。
  const metadata = await source.metadata();
  if (
    !metadata.format ||
    !['png', 'jpeg', 'webp'].includes(metadata.format) ||
    !metadata.width ||
    !metadata.height
  )
    throw new AttachmentParseError('ATTACHMENT_INVALID_IMAGE');
  return source
    .rotate()
    .resize({
      width: 1600,
      height: 1600,
      fit: 'inside',
      withoutEnlargement: true,
    })
    .flatten({ background: '#ffffff' })
    .jpeg({ quality: 82 })
    .toBuffer();
}

/// 图片总量独立限额，扫描文档不会无限扩张。
function appendImage(
  result: ParsedAttachment,
  bytes: Buffer,
  page?: number,
): void {
  // 内存传输预算包含base64展开前的实际字节。
  const total = result.images.reduce(
    (sum, item) => sum + Buffer.byteLength(item.data, 'base64'),
    bytes.length,
  );
  if (
    bytes.length > 2 * 1024 * 1024 ||
    total > 12 * 1024 * 1024 ||
    result.images.length >= limits.maxScanPages
  )
    throw new AttachmentParseError('ATTACHMENT_IMAGE_LIMIT');
  result.images.push({
    ...(page === undefined ? {} : { page }),
    data: bytes.toString('base64'),
    mimeType: 'image/jpeg',
  });
  result.requiresVision = true;
}

/// 表格只读取显示值，不计算公式、不访问外部链接。
function appendWorkbook(
  result: ParsedAttachment,
  workbook: ExcelJS.Workbook,
): void {
  // 非空单元格数量跨工作表累计。
  let cells = 0;
  if (workbook.worksheets.length > limits.maxSheets)
    throw new AttachmentParseError('ATTACHMENT_SHEET_LIMIT');
  result.units = workbook.worksheets.length;
  for (const sheet of workbook.worksheets) {
    if (sheet.rowCount > limits.maxCells || sheet.columnCount > 1000)
      throw new AttachmentParseError('ATTACHMENT_CELL_LIMIT');
    sheet.eachRow((row, rowNumber) => {
      // 行内值转换为明文，地址用于定位而非执行。
      const values: string[] = [];
      row.eachCell((cell) => {
        if (++cells > limits.maxCells)
          throw new AttachmentParseError('ATTACHMENT_CELL_LIMIT');
        values.push(`${cell.address}: ${cell.text}`);
      });
      appendText(result, values.join('\t'), {
        sheet: sheet.name,
        rowStart: rowNumber,
        rowEnd: rowNumber,
      });
    });
  }
}

/// PDF按页提取；无可选文本的页生成图片，不进行OCR或访问模型。
async function parsePdf(
  bytes: Buffer,
  result: ParsedAttachment,
): Promise<void> {
  // Node24支持CommonJS加载该ESM模块，不需要动态代码生成。
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  // 解析任务的生命周期始终在finally释放。
  const loading = pdfjs.getDocument({
    data: Uint8Array.from(bytes),
    useWorkerFetch: false,
    useSystemFonts: false,
    stopAtErrors: true,
  });
  try {
    // 加密文件不提供密码，库将拒绝。
    const document = await loading.promise;
    if (document.numPages > limits.maxPages)
      throw new AttachmentParseError('ATTACHMENT_PAGE_LIMIT');
    result.units = document.numPages;
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber++) {
      // 每页处理后立即释放资源。
      const page = await document.getPage(pageNumber);
      try {
        // 文本项只能用作资料，不执行注释、脚本或表单动作。
        const content = await page.getTextContent();
        // PDF文字顺序遵循库的页面项顺序。
        const text = content.items
          .map((item) => ('str' in item ? item.str : ''))
          .join(' ')
          .trim();
        if (text) appendText(result, text, { page: pageNumber });
        else {
          // 限制渲染画布最长边与像素面积。
          const natural = page.getViewport({ scale: 1 });
          // 不接受零或异常尺寸页面。
          const scale = Math.min(
            2,
            1600 / Math.max(natural.width, natural.height),
          );
          if (!Number.isFinite(scale) || scale <= 0)
            throw new AttachmentParseError('ATTACHMENT_INVALID_PDF');
          // 原图仍通过JPEG压缩和总图片预算。
          const viewport = page.getViewport({ scale });
          // 原生画布不会启动浏览器或执行页面脚本。
          const canvas = createCanvas(
            Math.max(1, Math.ceil(viewport.width)),
            Math.max(1, Math.ceil(viewport.height)),
          );
          await page.render({
            canvasContext: canvas.getContext(
              '2d',
            ) as unknown as CanvasRenderingContext2D,
            viewport,
            canvas: canvas as never,
          }).promise;
          appendImage(result, canvas.toBuffer('image/jpeg'), pageNumber);
        }
      } finally {
        page.cleanup();
      }
    }
  } catch (error) {
    if (error instanceof AttachmentParseError) throw error;
    if (error instanceof Error && error.name === 'PasswordException')
      throw new AttachmentParseError('ATTACHMENT_ENCRYPTED');
    throw new AttachmentParseError('ATTACHMENT_INVALID_PDF');
  } finally {
    await loading.destroy();
  }
}

/// 该入口只由受时间与内存限制的子进程调用。
export async function parseAttachment(
  bytes: Buffer,
  extension: string,
): Promise<ParsedAttachment> {
  if (!bytes.length || bytes.length > limits.maxFileBytes)
    throw new AttachmentParseError('ATTACHMENT_FILE_LIMIT');
  // 解析结果的所有字段都有明确持久化用途。
  const result: ParsedAttachment = {
    kind: 'document',
    requiresVision: false,
    chunks: [],
    images: [],
    units: 1,
  };
  if (['png', 'jpg', 'jpeg', 'webp'].includes(extension)) {
    result.kind = 'image';
    appendImage(result, await imageVersion(bytes));
  } else if (extension === 'pdf') {
    if (!bytes.subarray(0, 1024).includes(Buffer.from('%PDF-')))
      throw new AttachmentParseError('ATTACHMENT_INVALID_PDF');
    await parsePdf(bytes, result);
  } else if (extension === 'docx') {
    inspectOfficeArchive(bytes, extension);
    // Mammoth默认禁止外部文件读取；只提取正文不生成可执行HTML。
    const extracted = await mammoth.extractRawText({ buffer: bytes });
    extracted.value
      .split(/\n\s*\n/)
      .forEach((paragraph, index) =>
        appendText(result, paragraph, { paragraph: index + 1 }),
      );
  } else if (extension === 'xlsx' || extension === 'csv') {
    // 工作簿只存在于当前隔离进程内。
    const workbook = new ExcelJS.Workbook();
    if (extension === 'xlsx') {
      inspectOfficeArchive(bytes, extension);
      await workbook.xlsx.load(bytes as never);
    } else await workbook.csv.read(Readable.from([bytes]));
    appendWorkbook(result, workbook);
  } else if (extension === 'txt' || extension === 'md') {
    // 不猜测任意编码，支持UTF-8及带BOM的UTF-16LE。
    const text = new TextDecoder(
      bytes[0] === 0xff && bytes[1] === 0xfe ? 'utf-16le' : 'utf-8',
      { fatal: true },
    ).decode(bytes);
    if (text.includes('\0'))
      throw new AttachmentParseError('ATTACHMENT_INVALID_TEXT');
    text
      .split(/\n\s*\n/)
      .forEach((paragraph, index) =>
        appendText(result, paragraph, { paragraph: index + 1 }),
      );
  } else throw new AttachmentParseError('ATTACHMENT_UNSUPPORTED_TYPE');
  return result;
}
