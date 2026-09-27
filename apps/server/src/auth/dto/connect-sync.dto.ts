import { IsOptional, IsString, IsUUID, MinLength } from 'class-validator';

/// 使用部署密钥建立设备同步会话的请求。
export class ConnectSyncDto {
  /// 自托管服务的同步密钥。
  @IsString()
  @MinLength(16)
  syncKey!: string;

  /// 候选连接预检时确认的数据归属，防止连接到已经重建的服务器。
  @IsOptional()
  @IsUUID()
  expectedOwnerId?: string;
}
