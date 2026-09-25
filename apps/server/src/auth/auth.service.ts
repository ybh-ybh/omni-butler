import {
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from 'node:crypto';
import { PrismaService } from '../prisma/prisma.service';
import type { DeviceSession } from '../generated/prisma/client';
import type { AuthUser, TokenPair } from './auth.types';

/// 同步密钥校验、固定设备会话与 PowerSync 凭证服务。
@Injectable()
export class AuthService {
  /// 访问令牌最长有效秒数。
  private readonly accessTokenSeconds = 900;

  /// 注入认证所需服务。
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
  ) {}

  /// 使用部署同步密钥创建一个有固定到期时间的设备会话。
  async connect(syncKey: string): Promise<TokenPair> {
    // 配置密钥的定长摘要。
    const expectedDigest = this.digest(
      this.config.getOrThrow<string>('SYNC_SECRET'),
    );
    // 请求密钥的定长摘要。
    const suppliedDigest = this.digest(syncKey);
    if (!timingSafeEqual(expectedDigest, suppliedDigest)) {
      throw new UnauthorizedException('同步密钥错误');
    }
    // 单人部署对应的内部数据所有者。
    const owner = await this.prisma.syncOwner.findFirst();
    if (!owner) {
      throw new ServiceUnavailableException('同步服务尚未完成初始化');
    }
    // 设备会话标识。
    const id = randomUUID();
    // 256 位随机凭证，仅摘要进入数据库。
    const refreshToken = `${id}.${randomBytes(32).toString('base64url')}`;
    // 设备会话固定到期时间，刷新不会延长。
    const expiresAt = new Date(
      Date.now() +
        this.config.getOrThrow<number>('REFRESH_TOKEN_TTL_SECONDS') * 1000,
    );
    // 已持久化的设备会话。
    const session = await this.prisma.deviceSession.create({
      data: {
        id,
        userId: owner.id,
        tokenHash: this.digest(refreshToken).toString('hex'),
        expiresAt,
      },
    });
    return this.issueTokenPair(session, refreshToken);
  }

  /// 使用稳定会话凭证刷新访问令牌，重试和并发均不会创建后继会话。
  async refresh(refreshToken: string): Promise<TokenPair> {
    // 已验证且尚未到期的设备会话。
    const session = await this.verifySession(refreshToken);
    return this.issueTokenPair(session, refreshToken);
  }

  /// 删除经过凭证校验的设备会话，重复断开保持幂等。
  async disconnect(refreshToken: string): Promise<void> {
    try {
      // 当前设备会话；不能仅凭公开会话标识撤销其他设备。
      const session = await this.verifySession(refreshToken);
      await this.prisma.deviceSession.deleteMany({ where: { id: session.id } });
    } catch (error) {
      if (!(error instanceof UnauthorizedException)) {
        throw error;
      }
    }
  }

  /// 为 PowerSync 签发短期专用令牌。
  async issuePowerSyncToken(user: AuthUser): Promise<{
    token: string;
    endpoint: string;
    expiresIn: number;
    userId: string;
  }> {
    // 连接凭证有效秒数。
    const expiresIn = this.accessTokenSeconds;
    // PowerSync 仅需所有者标识，不携带旧账号字段。
    const token = await this.jwt.signAsync(
      { typ: 'powersync' },
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

  /// 返回短期访问令牌与原设备凭证，避免丢包时丢失刷新能力。
  private async issueTokenPair(
    session: { id: string; userId: string; expiresAt: Date },
    refreshToken: string,
  ): Promise<TokenPair> {
    // 访问令牌不得晚于设备会话到期。
    const expiresIn = Math.min(
      this.accessTokenSeconds,
      Math.floor((session.expiresAt.getTime() - Date.now()) / 1000),
    );
    if (expiresIn <= 0) {
      throw new UnauthorizedException('设备同步会话已到期');
    }
    // 每次 API 请求还会检查此 sid 对应的会话，删除后立即失效。
    const accessToken = await this.jwt.signAsync(
      { typ: 'access', sid: session.id },
      {
        subject: session.userId,
        audience: this.config.getOrThrow<string>('JWT_AUDIENCE'),
        expiresIn,
      },
    );
    return { accessToken, refreshToken, expiresIn };
  }

  /// 读取会话并恒定时间校验高熵刷新凭证。
  private async verifySession(refreshToken: string): Promise<DeviceSession> {
    // 提取严格格式的 UUID 标识，避免非法数据库参数。
    const match =
      /^([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.[A-Za-z0-9_-]{43}$/.exec(
        refreshToken,
      );
    if (!match) {
      throw new UnauthorizedException('设备同步凭证无效');
    }
    // 会话当前状态。
    const session = await this.prisma.deviceSession.findUnique({
      where: { id: match[1] },
    });
    if (!session || session.expiresAt <= new Date()) {
      throw new UnauthorizedException('设备同步会话已失效');
    }
    // 数据库存储的摘要。
    const expected = Buffer.from(session.tokenHash, 'hex');
    // 当前传入凭证的摘要。
    const supplied = this.digest(refreshToken);
    if (
      expected.length !== supplied.length ||
      !timingSafeEqual(expected, supplied)
    ) {
      throw new UnauthorizedException('设备同步凭证无效');
    }
    return session;
  }

  /// 对高熵凭证生成定长 SHA-256 摘要。
  private digest(value: string): Buffer {
    return createHash('sha256').update(value).digest();
  }
}
