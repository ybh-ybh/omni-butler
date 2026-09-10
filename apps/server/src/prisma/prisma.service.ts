import { Injectable, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient } from '../generated/prisma/client';

/// 应用共享的 Prisma 客户端。
@Injectable()
export class PrismaService
  extends PrismaClient
  implements OnModuleInit, OnModuleDestroy
{
  /// 使用 PostgreSQL 驱动适配器创建 Prisma 客户端。
  constructor(config: ConfigService) {
    // PostgreSQL 连接字符串。
    const connectionString = config.getOrThrow<string>('DATABASE_URL');
    // Prisma PostgreSQL 驱动适配器。
    const adapter = new PrismaPg({ connectionString });
    super({ adapter });
  }

  /// 应用启动时建立数据库连接。
  async onModuleInit(): Promise<void> {
    await this.$connect();
  }

  /// 应用关闭时释放数据库连接。
  async onModuleDestroy(): Promise<void> {
    await this.$disconnect();
  }
}
