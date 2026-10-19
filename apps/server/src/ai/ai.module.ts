import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { AiController } from './ai.controller';
import { AiKeyStore } from './ai-key-store';
import { AiProvider } from './ai-provider';
import { AiService } from './ai.service';

/// 独立模型接入模块，不依赖 Agent 框架或笔记 UI。
@Module({ imports: [AuthModule], controllers: [AiController], providers: [AiKeyStore, AiProvider, AiService], exports: [AiService] })
export class AiModule {}
