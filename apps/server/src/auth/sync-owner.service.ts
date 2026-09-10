import { Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import * as argon2 from 'argon2';
import { randomUUID } from 'node:crypto';
import { PrismaService } from '../prisma/prisma.service';

/// 为单人部署初始化仅供数据库隔离使用的内部数据所有者。
@Injectable()
export class SyncOwnerService implements OnApplicationBootstrap {
  /// 服务日志器。
  private readonly logger = new Logger(SyncOwnerService.name);

  /// 注入数据库服务。
  constructor(private readonly prisma: PrismaService) {}

  /// 数据库没有所有者时创建一个不可用于密码登录的内部记录。
  async onApplicationBootstrap(): Promise<void> {
    // 当前内部所有者数量。
    const ownerCount = await this.prisma.user.count();
    if (ownerCount > 0) {
      return;
    }
    // 不可由用户获知或复用的随机占位密码哈希。
    const passwordHash = await argon2.hash(randomUUID(), {
      type: argon2.argon2id,
    });
    await this.prisma.user.create({
      data: {
        email: 'sync-owner@localhost.invalid',
        passwordHash,
        role: 'ADMIN',
      },
    });
    this.logger.log('已创建单人部署的内部数据所有者');
  }
}
