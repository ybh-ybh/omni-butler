import { UnauthorizedException } from '@nestjs/common';
import type { ConfigService } from '@nestjs/config';
import type { JwtService } from '@nestjs/jwt';
import { generateKeyPairSync } from 'node:crypto';
import { AuthService } from '../src/auth/auth.service';
import { JwtStrategy } from '../src/auth/jwt.strategy';
import type { AuthUser } from '../src/auth/auth.types';
import type { PrismaService } from '../src/prisma/prisma.service';

/// 仅用于测试的会话记录。
interface TestSession {
  /// 会话标识。
  id: string;
  /// 所有者标识。
  userId: string;
  /// 凭证摘要。
  tokenHash: string;
  /// 固定到期时间。
  expiresAt: Date;
}
/// Passport 配置用的一次性测试公钥。
const { publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

/// 创建当前服务与无副作用的可观察依赖。
function createService(): {
  service: AuthService;
  strategy: JwtStrategy;
  sessions: Map<string, TestSession>;
  owner: { id: string };
  jwt: { signAsync: jest.Mock<Promise<string>, [object, object]> };
  prisma: {
    syncOwner: { findFirst: jest.Mock };
    deviceSession: {
      create: jest.Mock;
      findUnique: jest.Mock;
      deleteMany: jest.Mock;
    };
  };
} {
  // 内存设备会话表。
  const sessions = new Map<string, TestSession>();
  // 当前部署的独立所有者。
  const owner = { id: '2ef5581f-33d7-4b13-a0f0-743532f5b1c9' };
  // Prisma 操作替身。
  const prisma = {
    syncOwner: { findFirst: jest.fn().mockResolvedValue(owner) },
    deviceSession: {
      create: jest.fn(({ data }: { data: TestSession }) => {
        sessions.set(data.id, data);
        return Promise.resolve({ ...data });
      }),
      findUnique: jest.fn(({ where }: { where: { id: string } }) => {
        // 查询返回独立快照，与真实数据库一致。
        const value = sessions.get(where.id);
        return Promise.resolve(value ? { ...value } : null);
      }),
      deleteMany: jest.fn(({ where }: { where: { id: string } }) =>
        Promise.resolve({
          count: sessions.delete(where.id) ? 1 : 0,
        }),
      ),
    },
  };
  // 签发替身保留业务字段。
  const jwt = {
    signAsync: jest.fn((payload: object, options: object) =>
      Promise.resolve(JSON.stringify({ ...payload, ...options })),
    ),
  };
  // 当前测试配置。
  const values: Record<string, string | number> = {
    SYNC_SECRET: 'correct-sync-key',
    JWT_AUDIENCE: 'api',
    JWT_ISSUER: 'omni',
    JWT_PUBLIC_KEY_BASE64: Buffer.from(publicKey).toString('base64'),
    POWERSYNC_AUDIENCE: 'powersync',
    POWERSYNC_URL: 'https://sync.example.invalid',
    REFRESH_TOKEN_TTL_SECONDS: 3600,
  };
  // 配置服务替身。
  const config = { getOrThrow: (key: string) => values[key] } as ConfigService;
  // 当前认证服务。
  const service = new AuthService(
    prisma as unknown as PrismaService,
    jwt as unknown as JwtService,
    config,
  );
  // 当前设备访问校验策略。
  const strategy = new JwtStrategy(config, prisma as unknown as PrismaService);
  return { service, strategy, prisma, jwt, sessions, owner };
}

/// 覆盖固定会话的重试、并发和撤销边界。
describe('AuthService 设备会话', () => {
  it('错误同步密钥不查询所有者', async () => {
    // 当前服务和数据库替身。
    const { service, prisma } = createService();
    await expect(service.connect('incorrect-sync-key')).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
    expect(prisma.syncOwner.findFirst).not.toHaveBeenCalled();
  });
  it('设备凭证只保存摘要，JWT 不含旧账号字段', async () => {
    // 当前服务与会话表。
    const { service, sessions } = createService();
    // 新设备凭证。
    const pair = await service.connect('correct-sync-key');
    // 已存会话。
    const session = [...sessions.values()][0]!;
    expect(pair.refreshToken).toMatch(/^[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/);
    expect(session.tokenHash).toMatch(/^[0-9a-f]{64}$/);
    expect(session.tokenHash).not.toContain(pair.refreshToken.split('.')[1]);
    expect(JSON.parse(pair.accessToken)).toMatchObject({
      sid: session.id,
      typ: 'access',
      subject: session.userId,
    });
    expect(pair.accessToken).not.toMatch(/email|role|version/);
  });
  it('丢失刷新响应后重试成功且固定到期时间不延长', async () => {
    // 当前服务及内存数据库。
    const { service, sessions, prisma } = createService();
    // 初始凭证。
    const first = await service.connect('correct-sync-key');
    // 初始到期时间。
    const expiresAt = [...sessions.values()][0]!.expiresAt;
    await service.refresh(first.refreshToken);
    await expect(service.refresh(first.refreshToken)).resolves.toMatchObject({
      refreshToken: first.refreshToken,
    });
    expect([...sessions.values()][0]!.expiresAt).toEqual(expiresAt);
    expect(prisma.deviceSession.create).toHaveBeenCalledTimes(1);
  });
  it('并发刷新不创建后继会话', async () => {
    // 当前服务及写入替身。
    const { service, prisma } = createService();
    // 初始凭证。
    const first = await service.connect('correct-sync-key');
    // 并发刷新结果。
    const results = await Promise.all(
      Array.from({ length: 8 }, () => service.refresh(first.refreshToken)),
    );
    expect(
      results.every((result) => result.refreshToken === first.refreshToken),
    ).toBe(true);
    expect(prisma.deviceSession.create).toHaveBeenCalledTimes(1);
  });
  it('断开同时使访问和刷新失效，其他设备不受影响', async () => {
    // 当前服务、策略与所有者。
    const { service, strategy, owner } = createService();
    // 首个设备。
    const first = await service.connect('correct-sync-key');
    // 第二设备。
    const second = await service.connect('correct-sync-key');
    await service.disconnect(first.refreshToken);
    await service.disconnect(first.refreshToken);
    await expect(service.refresh(first.refreshToken)).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
    await expect(
      strategy.validate({
        sub: owner.id,
        sid: first.refreshToken.split('.')[0]!,
        typ: 'access',
      }),
    ).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(service.refresh(second.refreshToken)).resolves.toBeDefined();
  });
  it('刷新过程中断开，晚返回的访问令牌仍被拒绝', async () => {
    // 当前服务与签发替身。
    const { service, strategy, jwt, owner } = createService();
    // 初始会话。
    const first = await service.connect('correct-sync-key');
    // 签发屏障的释放函数。
    let release!: () => void;
    // 刷新通过校验的通知函数。
    let notify!: () => void;
    // 可控签发屏障。
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    // 已开始签发的通知。
    const started = new Promise<void>((resolve) => {
      notify = resolve;
    });
    jwt.signAsync.mockImplementationOnce(async (payload, options) => {
      notify();
      await gate;
      return JSON.stringify({ ...payload, ...options });
    });
    // 正在进行的刷新。
    const pending = service.refresh(first.refreshToken);
    await started;
    await service.disconnect(first.refreshToken);
    release();
    await pending;
    await expect(
      strategy.validate({
        sub: owner.id,
        sid: first.refreshToken.split('.')[0]!,
        typ: 'access',
      }),
    ).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(service.refresh(first.refreshToken)).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
  });
  it('知道会话标识但猜错秘密不能撤销或刷新', async () => {
    // 当前服务。
    const { service } = createService();
    // 有效设备凭证。
    const pair = await service.connect('correct-sync-key');
    // 相同标识的伪造秘密。
    const forged = `${pair.refreshToken.split('.')[0]}.${'a'.repeat(43)}`;
    await expect(service.refresh(forged)).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
    await service.disconnect(forged);
    await expect(service.refresh(pair.refreshToken)).resolves.toBeDefined();
  });
  it('会话到期后访问及刷新都拒绝', async () => {
    // 当前服务与会话表。
    const { service, strategy, sessions, owner } = createService();
    // 有效设备凭证。
    const pair = await service.connect('correct-sync-key');
    // 改为到期状态的会话。
    const session = [...sessions.values()][0]!;
    session.expiresAt = new Date(Date.now() - 1000);
    await expect(service.refresh(pair.refreshToken)).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
    await expect(
      strategy.validate({ sub: owner.id, sid: session.id, typ: 'access' }),
    ).rejects.toBeInstanceOf(UnauthorizedException);
  });
  it('拒绝所有者不匹配和不含 sid 的旧令牌', async () => {
    // 当前服务和策略。
    const { service, strategy } = createService();
    // 有效设备凭证。
    const pair = await service.connect('correct-sync-key');
    await expect(
      strategy.validate({
        sub: 'other',
        sid: pair.refreshToken.split('.')[0]!,
        typ: 'access',
      }),
    ).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(
      strategy.validate({ sub: 'owner', typ: 'access' } as AuthUser),
    ).rejects.toBeInstanceOf(UnauthorizedException);
  });
  it('撤销遇到数据库故障不会伪装成功', async () => {
    // 当前服务与数据库替身。
    const { service, prisma } = createService();
    // 有效设备凭证。
    const pair = await service.connect('correct-sync-key');
    prisma.deviceSession.deleteMany.mockRejectedValueOnce(
      new Error('database unavailable'),
    );
    await expect(service.disconnect(pair.refreshToken)).rejects.toThrow(
      'database unavailable',
    );
  });
});
