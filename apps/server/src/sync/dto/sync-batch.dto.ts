import { ApiProperty } from '@nestjs/swagger';
import { ArrayMaxSize, ArrayMinSize, ValidateNested } from 'class-validator';
import { Type } from 'class-transformer';
import { SyncOperationDto } from './sync-operation.dto';

/// PowerSync 一次上传的事务批次。
export class SyncBatchDto {
  /// 按客户端队列顺序排列的 CRUD 操作。
  @ApiProperty({ type: [SyncOperationDto], maxItems: 200 })
  @ArrayMinSize(1)
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => SyncOperationDto)
  operations!: SyncOperationDto[];
}
