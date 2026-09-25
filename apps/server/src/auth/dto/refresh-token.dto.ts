import { ApiProperty } from '@nestjs/swagger';
import { IsString, Matches } from 'class-validator';

/// 刷新或断开设备会话请求。
export class RefreshTokenDto {
  /// 会话 UUID 与 256 位随机秘密组成的稳定凭证。
  @ApiProperty()
  @IsString()
  @Matches(
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.[A-Za-z0-9_-]{43}$/,
  )
  refreshToken!: string;
}
