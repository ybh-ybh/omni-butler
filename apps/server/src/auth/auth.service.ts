import {
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import * as argon2 from 'argon2';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { PrismaService } from '../prisma/prisma.service';
import type { AuthUser, TokenPair } from './auth.types';

/// 同步密钥校验、设备令牌轮换与 PowerSync 凭证服务。
@Injectable()
export class AuthService {
  /// Access Token 有效秒数。
  private readonly accessTokenSeconds = 900;

  /// 注入认证所需服务。
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
  ) {}

  /// 使用部署时设置的同步密钥建立设备会话。
  async connect(syncKey: string): Promise<TokenPair> {
    // 配置中的同步密钥摘要。
    const expectedDigest = createHash('sha256')
      .update(this.config.getOrThrow<string>('SYNC_SECRET'))
      .digest();
    // 请求中的同步密钥摘要。
    const suppliedDigest = createHash('sha256').update(syncKey).digest();
    if (!timingSafeEqual(expectedDigest, suppliedDigest)) {
      throw new UnauthorizedException('同步密钥错误');
    }
    // 单人部署对应的内部数据所有者。
    const owner = await this.prisma.user.findFirst({
      orderBy: { createdAt: 'asc' },
    });
    if (!owner) {
      throw new ServiceUnavailableException('同步服务尚未完成初始化');
    }
    return this.issueTokenPair(owner);
  }

  /// 校验并轮换刷新令牌。
  async refresh(refreshToken: string): Promise<TokenPair> {
    // 已解码刷新令牌主体。
    const payload = await this.verifyRefreshToken(refreshToken);
    if (!payload.jti) {
      throw new UnauthorizedException('刷新令牌无效');
    }
    // 数据库存储的刷新令牌。
    const stored = await this.prisma.refreshToken.findUnique({
      where: { id: payload.jti },
      include: { user: true },
    });
    if (
      !stored ||
      stored.revokedAt ||
      stored.expiresAt <= new Date() ||
      !(await argon2.verify(stored.tokenHash, refreshToken)) ||
      stored.user.tokenVersion !== payload.version
    ) {
      throw new UnauthorizedException('刷新令牌已失效');
    }
    // 新令牌组。
    const next = await this.issueTokenPair(stored.user);
    // 新刷新令牌主体。
    const nextPayload = this.jwt.decode<AuthUser>(next.refreshToken);
    await this.prisma.refreshToken.update({
      where: { id: stored.id },
      data: { revokedAt: new Date(), replacedById: nextPayload?.jti },
    });
    return next;
  }

  /// 撤销指定设备会话的刷新令牌。
  async disconnect(refreshToken: string): Promise<void> {
    try {
      // 已解码刷新令牌主体。
      const payload = await this.verifyRefreshToken(refreshToken);
      if (payload.jti) {
        await this.prisma.refreshToken.updateMany({
          where: { id: payload.jti, revokedAt: null },
          data: { revokedAt: new Date() },
        });
      }
    } catch {
      // 断开接口保持幂等，不向调用方泄露令牌存在性。
    }
  }

  /// 为 PowerSync 签发短期专用令牌。
  async issuePowerSyncToken(user: AuthUser): Promise<{
    token: string;
    endpoint: string;
    expiresIn: number;
    userId: string;
  }> {
    // PowerSync 访问令牌有效秒数。
    const expiresIn = 900;
    // PowerSync 专用令牌。
    const token = await this.jwt.signAsync(
      {
        email: user.email,
        role: user.role,
        typ: 'powersync',
        version: user.version,
      },
      {
        subject: user.sub,
        audience: this.config.getOrThrow<string>('POWERSYNC_AUDIENCE'),
        expiresIn,
      },
    );
    return {
      token,
      endpoint: this.config.getOrThrow<string>('POWERSYNC_URL'),
      expiresIn,
      userId: user.sub,
    };
  }

  /// 签发新的访问与刷新令牌组。
  private async issueTokenPair(user: {
    id: string;
    email: string;
    role: string;
    tokenVersion: number;
  }): Promise<TokenPair> {
    // 刷新令牌唯一标识。
    const refreshId = randomUUID();
    // 公共 JWT 业务字段。
    const common = {
      email: user.email,
      role: user.role,
      version: user.tokenVersion,
    };
    // 短期访问令牌。
    const accessToken = await this.jwt.signAsync(
      { ...common, typ: 'access' },
      {
        subject: user.id,
        audience: this.config.getOrThrow<string>('JWT_AUDIENCE'),
        expiresIn: this.accessTokenSeconds,
      },
    );
    // 刷新令牌有效秒数。
    const refreshSeconds = this.config.getOrThrow<number>(
      'REFRESH_TOKEN_TTL_SECONDS',
    );
    // 可轮换刷新令牌。
    const refreshToken = await this.jwt.signAsync(
      { ...common, typ: 'refresh' },
      {
        jwtid: refreshId,
        subject: user.id,
        audience: this.config.getOrThrow<string>('JWT_AUDIENCE'),
        expiresIn: refreshSeconds,
      },
    );
    // 刷新令牌 Argon2id 哈希。
    const tokenHash = await argon2.hash(refreshToken, {
      type: argon2.argon2id,
    });
    await this.prisma.refreshToken.create({
      data: {
        id: refreshId,
        userId: user.id,
        tokenHash,
        expiresAt: new Date(Date.now() + refreshSeconds * 1000),
      },
    });
    return {
      accessToken,
      refreshToken,
      expiresIn: this.accessTokenSeconds,
    };
  }

  /// 验证刷新令牌签名、用途和受众。
  private async verifyRefreshToken(token: string): Promise<AuthUser> {
    try {
      // 已验证的刷新令牌主体。
      const payload = await this.jwt.verifyAsync<AuthUser>(token, {
        audience: this.config.getOrThrow<string>('JWT_AUDIENCE'),
      });
      if (payload.typ !== 'refresh') {
        throw new UnauthorizedException('令牌用途无效');
      }
      return payload;
    } catch {
      throw new UnauthorizedException('刷新令牌无效');
    }
  }
}
