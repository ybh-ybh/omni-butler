import { UnauthorizedException } from '@nestjs/common';
import type { ConfigService } from '@nestjs/config';
import type { JwtService } from '@nestjs/jwt';
import { AuthService } from '../src/auth/auth.service';
import type { PrismaService } from '../src/prisma/prisma.service';

/// 创建认证服务及其最小依赖替身。
function createService(): {
  service: AuthService;
  prisma: {
    user: { findFirst: jest.Mock };
    refreshToken: { create: jest.Mock };
  };
} {
  // 固定的内部数据所有者。
  const owner = {
    id: '2ef5581f-33d7-4b13-a0f0-743532f5b1c9',
    email: 'sync-owner@localhost.invalid',
    role: 'ADMIN',
    tokenVersion: 0,
  };
  // Prisma 查询与写入替身。
  const prisma = {
    user: { findFirst: jest.fn().mockResolvedValue(owner) },
    refreshToken: { create: jest.fn().mockResolvedValue({}) },
  };
  // JWT 签发替身。
  const jwt = {
    signAsync: jest
      .fn()
      .mockResolvedValueOnce('access-token')
      .mockResolvedValueOnce('refresh-token'),
  };
  // 配置读取替身。
  const config = {
    getOrThrow: jest.fn((key: string) => {
      // 测试所需的配置值。
      const values: Record<string, string | number> = {
        SYNC_SECRET: 'correct-sync-key',
        JWT_AUDIENCE: 'omni-api',
        REFRESH_TOKEN_TTL_SECONDS: 3600,
      };
      return values[key];
    }),
  };
  // 被测试的同步会话服务。
  const service = new AuthService(
    prisma as unknown as PrismaService,
    jwt as unknown as JwtService,
    config as unknown as ConfigService,
  );
  return { service, prisma };
}

/// 同步密钥设备连接测试。
describe('AuthService.connect', () => {
  it('拒绝错误同步密钥且不查询数据所有者', async () => {
    // 被测试服务与数据库替身。
    const { service, prisma } = createService();

    await expect(service.connect('incorrect-sync-key')).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
    expect(prisma.user.findFirst).not.toHaveBeenCalled();
  });

  it('正确同步密钥会签发并保存设备会话令牌', async () => {
    // 被测试服务与数据库替身。
    const { service, prisma } = createService();

    await expect(service.connect('correct-sync-key')).resolves.toMatchObject({
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      expiresIn: 900,
    });
    expect(prisma.user.findFirst).toHaveBeenCalledWith({
      orderBy: { createdAt: 'asc' },
    });
    expect(prisma.refreshToken.create).toHaveBeenCalledTimes(1);
  });
});
