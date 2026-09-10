import { Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import { PrismaService } from './prisma.service';

/// 确保 PowerSync 所需的 PostgreSQL 逻辑复制发布存在。
@Injectable()
export class PowerSyncPublicationService implements OnApplicationBootstrap {
  /// 服务日志器。
  private readonly logger = new Logger(PowerSyncPublicationService.name);

  /// 注入数据库服务。
  constructor(private readonly prisma: PrismaService) {}

  /// 在 API 健康检查放行前创建幂等的全表发布。
  async onApplicationBootstrap(): Promise<void> {
    // 已存在的 PowerSync 发布记录。
    const publications = await this.prisma.$queryRawUnsafe<
      Array<{ exists: number }>
    >('SELECT 1 AS "exists" FROM pg_publication WHERE pubname = \'powersync\'');
    if (publications.length > 0) {
      return;
    }
    await this.prisma.$executeRawUnsafe(
      'CREATE PUBLICATION powersync FOR ALL TABLES',
    );
    this.logger.log('已创建 PowerSync 全表逻辑复制发布');
  }
}
