import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import type { SyncBatchDto } from './dto/sync-batch.dto';
import { SyncSqlBuilder } from './sync-sql.builder';

/// PowerSync 离线写入落库服务。
@Injectable()
export class SyncService {
  /// SQL 白名单构建器。
  private readonly sqlBuilder = new SyncSqlBuilder();

  /// 注入 Prisma 数据访问服务。
  constructor(private readonly prisma: PrismaService) {}

  /// 在同一事务内按顺序应用客户端操作。
  async applyBatch(
    userId: string,
    batch: SyncBatchDto,
  ): Promise<{
    applied: number;
  }> {
    await this.prisma.$transaction(async (transaction) => {
      for (const operation of batch.operations) {
        // 当前操作的参数化 SQL。
        const statement = this.sqlBuilder.build(operation, userId);
        await transaction.$executeRawUnsafe(statement.sql, ...statement.values);
      }
    });
    return { applied: batch.operations.length };
  }
}
