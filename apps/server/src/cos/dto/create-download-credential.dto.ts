import { ApiProperty } from '@nestjs/swagger';
import { IsString, Matches, MaxLength } from 'class-validator';

/// 客户端下载私有 COS 附件的临时凭证请求。
export class CreateDownloadCredentialDto {
  /// PowerSync 已同步到本机的 COS 对象键。
  @ApiProperty({
    example:
      'users/0198d570-c3f7-7000-8000-000000000001/inventoryImage/0198d570-c3f7-7000-8000-000000000002/0198d570-c3f7-7000-8000-000000000003.jpg',
  })
  @IsString()
  @MaxLength(512)
  @Matches(/^[a-zA-Z0-9/_-]+\.[a-zA-Z0-9]{1,8}$/)
  objectKey!: string;
}
