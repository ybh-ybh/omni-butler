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

  /// 校验令牌用途、用户存在性和版本。
  async validate(payload: AuthUser): Promise<AuthUser> {
    if (payload.typ !== 'access') {
      throw new UnauthorizedException('令牌用途无效');
    }
    // 当前数据库内部数据所有者。
    const user = await this.prisma.user.findUnique({
      where: { id: payload.sub },
      select: { id: true, email: true, role: true, tokenVersion: true },
    });
    if (!user || user.tokenVersion !== payload.version) {
      throw new UnauthorizedException('设备同步会话已失效');
    }
    return {
      sub: user.id,
      email: user.email,
      role: user.role,
      typ: 'access',
      version: user.tokenVersion,
    };
  }
}
