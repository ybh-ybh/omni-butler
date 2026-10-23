import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { BusinessModule } from '../business/business.module';
import { PrismaModule } from '../prisma/prisma.module';
import { ActionExecutor } from './action-executor';
import { McpCatalog } from './mcp-catalog';
import { McpController, McpManagementController } from './mcp.controller';
import { McpReviewService } from './mcp-review.service';
import { McpService } from './mcp.service';
import { McpEditTokenService } from './mcp-edit-token.service';

/// 两种认证边界独立，业务服务和现有同步继续复用。
@Module({
  imports: [AuthModule, BusinessModule, PrismaModule],
  controllers: [McpController, McpManagementController],
  providers: [
    ActionExecutor,
    McpCatalog,
    McpService,
    McpReviewService,
    McpEditTokenService,
  ],
  exports: [McpService, ActionExecutor, McpReviewService],
})
export class McpModule {}
