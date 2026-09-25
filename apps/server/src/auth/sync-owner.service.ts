import { Injectable, OnApplicationBootstrap } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

/// 初始化只用于同步数据归属的内部所有者，无账号或密码。
@Injectable()
export class SyncOwnerService implements OnApplicationBootstrap {
  /// 注入数据库服务。
  constructor(private readonly prisma: PrismaService) {}

  /// 为单人部署幂等创建唯一所有者。
  async onApplicationBootstrap(): Promise<void> {
    await this.prisma.$transaction(async (transaction) => {
      // 初始化事务锁，避免多个进程同时创建不同所有者。
      await transaction.$executeRaw`SELECT pg_advisory_xact_lock(1573090401)`;
      // 保留每个部署独立的随机所有者标识。
      const owner = await transaction.syncOwner.findFirst();
      if (!owner) {
        await transaction.syncOwner.create({ data: {} });
      }
    });
  }
}
