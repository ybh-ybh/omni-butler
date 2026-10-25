/// 上传与发送共用固定边界，不能依赖客户端检查。
export const ATTACHMENT_LIMITS = {
  maxFiles: 5,
  maxFileBytes: 20 * 1024 * 1024,
  maxTotalBytes: 50 * 1024 * 1024,
  maxExpandedBytes: 64 * 1024 * 1024,
  maxTextCharacters: 2_000_000,
  /// 包括JSON转义后的每块文本预算，避免单块已经超过工具输出上限。
  maxChunkBytes: 4 * 1024,
  /// 工具返回完整JSON的UTF-8预算，包含来源与分页包装。
  maxToolOutputBytes: 16 * 1024,
  maxChunks: 2000,
  maxPages: 100,
  maxScanPages: 20,
  maxCells: 50_000,
  maxSheets: 20,
  parseTimeoutMs: 30_000,
} as const;

/// 扩展名只选择解析器，真实内容仍由解析器验证。
export const ATTACHMENT_MIMES: Readonly<Record<string, string>> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  pdf: 'application/pdf',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  csv: 'text/csv',
  txt: 'text/plain',
  md: 'text/markdown',
};

/// 客户端仅获得安全元数据，不包含对象键或提取正文。
export interface AttachmentMetadata {
  /// 原上传的稳定UUID。
  id: string;
  /// 去除路径及控制字符后的文件名。
  name: string;
  /// 解析器固定的MIME。
  mimeType: string;
  /// 原始字节数。
  size: number;
  /// 文件生命周期。
  status: 'uploading' | 'processing' | 'ready' | 'failed';
  /// 图片与文档显示类别。
  kind: 'image' | 'document';
  /// 图片和扫描页需要模型具有视觉能力。
  requiresVision: boolean;
  /// 公开固定错误码。
  errorCode?: string;
}

/// 保留可引用的页、段落或表格范围。
export interface AttachmentChunk {
  /// 从一开始的稳定块编号。
  index: number;
  /// 资料正文，不具备指令权威。
  text: string;
  /// PDF页编号。
  page?: number;
  /// Word或文本段编号。
  paragraph?: number;
  /// 表格工作表名称。
  sheet?: string;
  /// 工作表起始行。
  rowStart?: number;
  /// 工作表结束行。
  rowEnd?: number;
}

/// 解析输出在子进程与主进程间短暂传输。
export interface ParsedAttachment {
  /// 原格式分类。
  kind: 'image' | 'document';
  /// 是否存在需要视觉模型读取的内容。
  requiresVision: boolean;
  /// 有界文本分块。
  chunks: AttachmentChunk[];
  /// 仅内存传输的压缩图片，持久化时只写对象存储。
  images: { page?: number; data: string; mimeType: 'image/jpeg' }[];
  /// 原文档页数或工作表数。
  units: number;
}

/// 工具读取按页、表或稳定分块编号限定范围。
export interface AttachmentReadRange {
  /// 起始块编号，默认一。
  start?: number;
  /// 结束块编号，最多十块。
  end?: number;
  /// 精确页号。
  page?: number;
  /// 精确工作表名。
  sheet?: string;
}

/// 图中仅保留图片引用，出站前才加载字节。
export interface AttachmentImageReference {
  /// 已绑定附件UUID。
  attachmentId: string;
  /// PDF扫描页号，普通图片省略。
  page?: number;
}

/// 解析器只传播固定错误码，避免把文档内容写入日志。
export class AttachmentParseError extends Error {
  /// 固定错误码会进入附件元数据。
  constructor(readonly code: string) {
    super(code);
  }
}
