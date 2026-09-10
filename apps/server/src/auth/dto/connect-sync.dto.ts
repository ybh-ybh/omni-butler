import { IsString, MinLength } from 'class-validator';

/// 使用部署密钥建立设备同步会话的请求。
export class ConnectSyncDto {
  /// 自托管服务的同步密钥。
  @IsString()
  @MinLength(16)
  syncKey!: string;
}
