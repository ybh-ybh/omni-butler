import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { AiModule } from '../ai/ai.module';
import { McpModule } from '../mcp/mcp.module';
import { PrismaModule } from '../prisma/prisma.module';
import { AssistantController } from './assistant.controller';
import { AssistantStore } from './assistant-store.service';
import { AssistantRunner } from './assistant-runner.service';
import { AssistantPresentation } from './assistant-presentation.service';
import { AssistantContextService } from './assistant-context.service';
import { AssistantBatchService } from './assistant-batch.service';

/// 助手私有状态与业务工具共享，不引入第二套领域CRUD。
@Module({
  imports: [AuthModule, AiModule, McpModule, PrismaModule],
  controllers: [AssistantController],
  providers: [
    AssistantStore,
    AssistantRunner,
    AssistantPresentation,
    AssistantContextService,
    AssistantBatchService,
  ],
  exports: [AssistantStore],
})
export class AssistantModule {}
