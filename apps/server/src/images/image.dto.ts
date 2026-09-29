import { IsIn, IsOptional, IsString, IsUUID, Matches } from 'class-validator';

/// 图片写入幂等和比较交换参数。
export class ImageUploadDto {
  /// 离线重试保持同一个操作身份。
  @IsUUID() operationId: string;
  /// 本地稳定附件身份。
  @IsUUID() attachmentId: string;
  /// multipart 空串代表服务器从未设置过图片。
  @IsString()
  @Matches(
    /^(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?$/,
  )
  expectedRevision: string;
  /// 历史补传不能覆盖服务端图片或显式移除标记。
  @IsIn(['true', 'false']) onlyIfMissing: string;
  /// 原文件完整摘要。
  @Matches(/^[a-f0-9]{64}$/) sha256: string;
}

/// 显式移除也产生持久同步标记。
export class ImageRemoveDto {
  /// 重试保持同一操作身份。
  @IsUUID() operationId: string;
  /// 当前服务器版本；null 表示尚无任何标记。
  @IsOptional() @IsUUID() expectedRevision: string | null;
}
