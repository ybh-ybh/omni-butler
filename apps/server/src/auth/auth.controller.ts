import {
  Body,
  Controller,
  Get,
  HttpCode,
  Post,
  UseGuards,
} from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { AuthService } from './auth.service';
import type { AuthUser, TokenPair } from './auth.types';
import { CurrentUser } from './current-user.decorator';
import { ConnectSyncDto } from './dto/connect-sync.dto';
import { RefreshTokenDto } from './dto/refresh-token.dto';
import { JwksService } from './jwks.service';
import { JwtAuthGuard } from './jwt-auth.guard';

/// 设备同步会话与 PowerSync 凭证接口。
@ApiTags('auth')
@Controller('auth')
export class AuthController {
  /// 注入认证与 JWKS 服务。
  constructor(
    private readonly auth: AuthService,
    private readonly jwks: JwksService,
  ) {}

  /// 使用部署密钥连接同步服务。
  @Post('connect')
  @HttpCode(200)
  @ApiOperation({ summary: '使用同步密钥建立设备会话' })
  connect(@Body() input: ConnectSyncDto): Promise<TokenPair> {
    return this.auth.connect(input.syncKey);
  }

  /// 使用稳定设备凭证刷新访问令牌。
  @Post('refresh')
  @HttpCode(200)
  @ApiOperation({ summary: '刷新 Access Token，设备凭证保持不变' })
  refresh(@Body() input: RefreshTokenDto): Promise<TokenPair> {
    return this.auth.refresh(input.refreshToken);
  }

  /// 删除当前设备会话并使其 API 访问凭证失效。
  @Post('disconnect')
  @HttpCode(204)
  @ApiOperation({ summary: '断开当前设备会话' })
  disconnect(@Body() input: RefreshTokenDto): Promise<void> {
    return this.auth.disconnect(input.refreshToken);
  }

  /// 返回当前设备会话的内部同步身份。
  @Get('session')
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: '检查当前设备同步会话' })
  session(@CurrentUser() user: AuthUser): AuthUser {
    return user;
  }

  /// 签发 PowerSync 短期连接令牌。
  @Post('powersync-token')
  @UseGuards(JwtAuthGuard)
  @HttpCode(200)
  @ApiBearerAuth()
  @ApiOperation({ summary: '获取 PowerSync 短期 JWT 和服务地址' })
  powersyncToken(
    @CurrentUser() user: AuthUser,
  ): ReturnType<AuthService['issuePowerSyncToken']> {
    return this.auth.issuePowerSyncToken(user);
  }

  /// 返回 PowerSync 与 API 共用的公开验签密钥。
  @Get('jwks')
  @ApiOperation({ summary: '公开 RS256 JWKS' })
  jwksKeys(): ReturnType<JwksService['getKeys']> {
    return this.jwks.getKeys();
  }
}
