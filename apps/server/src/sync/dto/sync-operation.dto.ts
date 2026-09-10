import { ApiProperty } from '@nestjs/swagger';
import {
  IsIn,
  IsObject,
  IsOptional,
  IsUUID,
  ValidateIf,
} from 'class-validator';

/// PowerSync 本地 CRUD 操作。
export class SyncOperationDto {
  /// PowerSync 操作类型。
  @ApiProperty({ enum: ['PUT', 'PATCH', 'DELETE'] })
  @IsIn(['PUT', 'PATCH', 'DELETE'])
  op!: 'PUT' | 'PATCH' | 'DELETE';

  /// 目标同步表。
  @ApiProperty()
  @IsIn([
    'todo_items',
    'quotes',
    'daily_quote_selections',
    'banner_settings',
    'attachments',
    'taxonomy_entries',
    'record_taxonomy_links',
    'events',
    'event_completions',
    'inventory_items',
    'time_entries',
    'memberships',
    'membership_payments',
  ])
  table!: string;

  /// 目标记录 UUID。
  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  id!: string;

  /// PUT 或 PATCH 操作携带的列值。
  @ApiProperty({ type: Object, required: false })
  @ValidateIf((input: SyncOperationDto) => input.op !== 'DELETE')
  @IsObject()
  @IsOptional()
  data?: Record<string, unknown>;
}
