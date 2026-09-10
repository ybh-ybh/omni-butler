import { Global, Module } from '@nestjs/common';
import { PrismaService } from './prisma.service';
import { PowerSyncPublicationService } from './powersync-publication.service';

/// 全局 Prisma 数据访问模块。
@Global()
@Module({
  providers: [PrismaService, PowerSyncPublicationService],
  exports: [PrismaService],
})
export class PrismaModule {}
