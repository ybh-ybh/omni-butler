import { ApiProperty } from '@nestjs/swagger';
import { IsJWT } from 'class-validator';

/// 刷新或断开设备会话请求。
export class RefreshTokenDto {
  /// 当前刷新令牌。
  @ApiProperty()
  @IsJWT()
  refreshToken!: string;
}
