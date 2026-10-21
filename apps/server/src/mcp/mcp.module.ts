import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { BusinessModule } from '../business/business.module';
import { PrismaModule } from '../prisma/prisma.module';
import { McpCatalog } from './mcp-catalog';
import { McpController, McpManagementController } from './mcp.controller';
import { McpReviewService } from './mcp-review.service';
import { McpService } from './mcp.service';

/// 两种认证边界独立，业务服务和现有同步继续复用。
@Module({
  imports: [AuthModule, BusinessModule, PrismaModule],
  controllers: [McpController, McpManagementController],
  providers: [McpCatalog, McpService, McpReviewService],
  exports: [McpService],
})
export class McpModule {}
