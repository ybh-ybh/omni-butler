import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { SyncController } from './sync.controller';
import { SyncService } from './sync.service';
import { SyncMigrationController } from './sync-migration.controller';
import { SyncMigrationService } from './sync-migration.service';

/// PowerSync 离线写入模块。
@Module({
  imports: [AuthModule],
  controllers: [SyncController, SyncMigrationController],
  providers: [SyncService, SyncMigrationService],
})
export class SyncModule {}
