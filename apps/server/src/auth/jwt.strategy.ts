import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PassportStrategy } from '@nestjs/passport';
import { ExtractJwt, Strategy } from 'passport-jwt';
import { PrismaService } from '../prisma/prisma.service';
import type { AuthUser } from './auth.types';

/// 验证设备会话 Access Token 并读取内部数据所有者。
@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  /// 使用 RSA 公钥配置 Passport JWT。
  constructor(
    config: ConfigService,
    private readonly prisma: PrismaService,
  ) {
    // RSA 公钥 PEM。
    const publicKey = Buffer.from(
      config.getOrThrow<string>('JWT_PUBLIC_KEY_BASE64'),
      'base64',
    ).toString('utf8');
    super({
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(),
      ignoreExpiration: false,
      secretOrKey: publicKey,
      algorithms: ['RS256'],
      issuer: config.getOrThrow<string>('JWT_ISSUER'),
      audience: config.getOrThrow<string>('JWT_AUDIENCE'),
    });
  }

  /// 校验令牌用途、所属设备会话与固定到期时间。
  async validate(payload: AuthUser): Promise<AuthUser> {
    if (
      payload.typ !== 'access' ||
      typeof payload.sid !== 'string' ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
        payload.sid,
      )
    ) {
      throw new UnauthorizedException('令牌用途无效');
    }
    // 每次请求读取会话，断开后已经签发的访问令牌也不能重新授权。
    const session = await this.prisma.deviceSession.findUnique({
      where: { id: payload.sid },
    });
    if (
      !session ||
      session.userId !== payload.sub ||
      session.expiresAt <= new Date()
    ) {
      throw new UnauthorizedException('设备同步会话已失效');
    }
    return {
      sub: session.userId,
      sid: session.id,
      typ: 'access',
    };
  }
}
