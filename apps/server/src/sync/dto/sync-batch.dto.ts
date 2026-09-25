import { ApiProperty } from '@nestjs/swagger';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsString,
  IsUUID,
  MaxLength,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import { SyncOperationDto } from './sync-operation.dto';

/// PowerSync 一次上传的事务批次。
export class SyncBatchDto {
  /// 本地数据库安装身份，清空数据库后重新生成。
  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  clientId!: string;

  /// 原始本地事务标识，同一次重试必须保持不变。
  @ApiProperty()
  @IsString()
  @MinLength(1)
  @MaxLength(128)
  transactionId!: string;

  /// 按客户端队列顺序排列的 CRUD 操作。
  @ApiProperty({ type: [SyncOperationDto], maxItems: 100000 })
  @ArrayMinSize(1)
  @ArrayMaxSize(100000)
  @ValidateNested({ each: true })
  @Type(() => SyncOperationDto)
  operations!: SyncOperationDto[];
}
