import { crc32 } from 'node:zlib';

/// 构造标准无压缩ZIP用于真实Office解析，不依赖运行外部Office应用。
export function attachmentZip(entries: Record<string, string>): Buffer {
  // 本地文件头与正文按顺序排列。
  const bodies: Buffer[] = [];
  // 中央目录持有每个文件的真实CRC和偏移。
  const directory: Buffer[] = [];
  // 下一个本地头偏移。
  let offset = 0;
  for (const [name, value] of Object.entries(entries)) {
    // UTF-8路径仅用于ZIP内部目录。
    const path = Buffer.from(name);
    // XML正文保持原字节便于验证提取结果。
    const content = Buffer.from(value);
    // 标准ZIP本地头。
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x800, 6);
    local.writeUInt32LE(crc32(content), 14);
    local.writeUInt32LE(content.length, 18);
    local.writeUInt32LE(content.length, 22);
    local.writeUInt16LE(path.length, 26);
    // 标准ZIP中央记录。
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x800, 8);
    central.writeUInt32LE(crc32(content), 16);
    central.writeUInt32LE(content.length, 20);
    central.writeUInt32LE(content.length, 24);
    central.writeUInt16LE(path.length, 28);
    central.writeUInt32LE(offset, 42);
    bodies.push(local, path, content);
    directory.push(central, path);
    offset += local.length + path.length + content.length;
  }
  // 尾目录固定条目数和中央目录边界。
  const ending = Buffer.alloc(22);
  ending.writeUInt32LE(0x06054b50, 0);
  ending.writeUInt16LE(directory.length / 2, 8);
  ending.writeUInt16LE(directory.length / 2, 10);
  ending.writeUInt32LE(Buffer.concat(directory).length, 12);
  ending.writeUInt32LE(offset, 16);
  return Buffer.concat([...bodies, ...directory, ending]);
}

/// 最小Word容器包含真实包关系与段落，可由mammoth直接读取。
export function attachmentDocx(text = '附件中的中文段落'): Buffer {
  return attachmentZip({
    '[Content_Types].xml':
      '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    '_rels/.rels':
      '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
    'word/document.xml': `<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>${text}</w:t></w:r></w:p></w:body></w:document>`,
  });
}

/// 真实PDF页结构与xref，空白页用于验证扫描页图片化。
export function attachmentPdf(text?: string): Buffer {
  // 页内容保持小且不含外部资源。
  const stream = text ? `BT /F1 12 Tf 20 80 Td (${text}) Tj ET` : '';
  // 五个间接对象组成单页PDF。
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`,
  ];
  // xref以实际字节偏移计算。
  const offsets = [0];
  // PDF纯ASCII测试正文。
  let body = '%PDF-1.4\n';
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(body));
    body += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  // xref自身位置。
  const xref = Buffer.byteLength(body);
  body += `xref\n0 6\n0000000000 65535 f \n${offsets
    .slice(1)
    .map((offset) => `${String(offset).padStart(10, '0')} 00000 n \n`)
    .join('')}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(body);
}
