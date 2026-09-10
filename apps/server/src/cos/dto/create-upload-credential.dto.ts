import { ApiProperty } from '@nestjs/swagger';
import {
  IsIn,
  IsInt,
  IsString,
  IsUUID,
  Matches,
  MaxLength,
  Min,
} from 'class-validator';

/// 客户端直传 COS 的临时凭证请求。
export class CreateUploadCredentialDto {
  /// 本地附件标识。
  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  attachmentId!: string;

  /// 所属业务类型。
  @ApiProperty({
    enum: ['quoteBanner', 'inventoryImage', 'membershipImage'],
  })
  @IsIn(['quoteBanner', 'inventoryImage', 'membershipImage'])
  businessType!: 'quoteBanner' | 'inventoryImage' | 'membershipImage';

  /// 所属业务记录标识。
  @ApiProperty({ example: '0198d570-c3f7-7000-8000-000000000001' })
  @IsString()
  @Matches(
    /^(?:home-banner|[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/i,
  )
  businessId!: string;

  /// 原始文件名，仅用于提取扩展名。
  @ApiProperty({ example: 'cover.jpg' })
  @IsString()
  @MaxLength(255)
  fileName!: string;

  /// 文件 MIME 类型。
  @ApiProperty({ example: 'image/jpeg' })
  @IsString()
  @MaxLength(128)
  mimeType!: string;

  /// 文件字节数。
  @ApiProperty({ minimum: 1, maximum: 20971520 })
  @IsInt()
  @Min(1)
  sizeBytes!: number;
}
