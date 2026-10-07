import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  Equals,
  IsArray,
  IsString,
  IsUUID,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { SyncOperationDto } from './sync-operation.dto';

/// 通过部署密钥授权预检，不创建临时设备会话。
export class ConnectionPreviewDto {
  /// 目标部署同步密钥。
  @IsString()
  @MinLength(16)
  syncKey!: string;
}

/// 查询持久迁移回执的请求。
export class MigrationStatusDto extends ConnectionPreviewDto {
  /// 客户端在发送前持久化的迁移身份。
  @IsUUID()
  migrationId!: string;
}

/// 用完整当前状态替换目标服务器的请求。
export class SyncMigrationDto extends MigrationStatusDto {
  /// 预检确认且允许覆盖的目标归属。
  @IsUUID()
  expectedOwnerId!: string;

  /// 当前严格快照协议版本。
  @Equals(2)
  snapshotVersion!: number;

  /// 所有同步表的完整 PUT；空数组表示明确用空库覆盖。
  @IsArray()
  @ArrayMaxSize(100000)
  @ValidateNested({ each: true })
  @Type(() => SyncOperationDto)
  operations!: SyncOperationDto[];
}
