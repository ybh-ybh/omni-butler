import { Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtModule } from '@nestjs/jwt';
import { PassportModule } from '@nestjs/passport';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { JwksService } from './jwks.service';
import { JwtAuthGuard } from './jwt-auth.guard';
import { JwtStrategy } from './jwt.strategy';
import { SyncOwnerService } from './sync-owner.service';

/// 同步密钥、设备会话 JWT 与内部数据所有者模块。
@Module({
  imports: [
    PassportModule.register({ defaultStrategy: 'jwt' }),
    JwtModule.registerAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => ({
        privateKey: Buffer.from(
          config.getOrThrow<string>('JWT_PRIVATE_KEY_BASE64'),
          'base64',
        ).toString('utf8'),
        signOptions: {
          algorithm: 'RS256' as const,
          keyid: config.getOrThrow<string>('JWT_KEY_ID'),
          issuer: config.getOrThrow<string>('JWT_ISSUER'),
        },
      }),
    }),
  ],
  controllers: [AuthController],
  providers: [
    AuthService,
    JwtStrategy,
    JwtAuthGuard,
    JwksService,
    SyncOwnerService,
  ],
  exports: [AuthService, JwtAuthGuard],
})
export class AuthModule {}
