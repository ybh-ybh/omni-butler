import { Module } from '@nestjs/common';
import { AuthModule } from '../../auth/auth.module';
import { PrismaModule } from '../../prisma/prisma.module';
import { StorageModule } from '../../storage/storage.module';
import { AssistantAttachmentsController } from './assistant-attachments.controller';
import { AssistantAttachmentsService } from './assistant-attachments.service';
import { AttachmentProcess } from './attachment-process';
import {
  AttachmentObjectStore,
  MinioAttachmentObjectStore,
} from './attachment-object-store';

/// 独立模块可由助手模块直接导入，不需要重写主控制器。
@Module({
  imports: [AuthModule, PrismaModule, StorageModule],
  controllers: [AssistantAttachmentsController],
  providers: [
    AssistantAttachmentsService,
    AttachmentProcess,
    { provide: AttachmentObjectStore, useClass: MinioAttachmentObjectStore },
  ],
  exports: [AssistantAttachmentsService],
})
export class AssistantAttachmentsModule {}
