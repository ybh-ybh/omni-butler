import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { SyncController } from './sync.controller';
import { SyncService } from './sync.service';

/// PowerSync 离线写入模块。
@Module({
  imports: [AuthModule],
  controllers: [SyncController],
  providers: [SyncService],
})
export class SyncModule {}
