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
import { AssistantModelExecutor } from './assistant-model-executor';
import { AssistantAttachmentsModule } from './attachments/assistant-attachments.module';
import { BusinessModule } from '../business/business.module';
import { AssistantEntityEditor } from './assistant-entity-editor.service';
import { AssistantMessageNotes } from './assistant-message-notes.service';
import { AssistantSpeechGateway } from './speech/assistant-speech.gateway';
import { AssistantSpeechAuth } from './speech/assistant-speech-auth.service';
import { TencentRealtimeSpeechProvider } from './speech/tencent-realtime-speech.provider';

/// 助手私有状态与业务工具共享，不引入第二套领域CRUD。
@Module({
  imports: [AuthModule, AiModule, McpModule, PrismaModule, AssistantAttachmentsModule, BusinessModule],
  controllers: [AssistantController],
  providers: [
    AssistantStore,
    AssistantRunner,
    AssistantPresentation,
    AssistantEntityEditor,
    AssistantMessageNotes,
    AssistantContextService,
    AssistantBatchService,
    AssistantModelExecutor,
    AssistantSpeechGateway,
    AssistantSpeechAuth,
    TencentRealtimeSpeechProvider,
  ],
  exports: [AssistantStore],
})
export class AssistantModule {}
