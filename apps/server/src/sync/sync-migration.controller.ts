import { Body, Controller, HttpCode, Post } from '@nestjs/common';
import {
  ConnectionPreviewDto,
  MigrationStatusDto,
  SyncMigrationDto,
} from './dto/sync-migration.dto';
import { SyncMigrationService } from './sync-migration.service';

/// 部署密钥授权的连接预检和快照替换入口。
@Controller('sync')
export class SyncMigrationController {
  /// 注入独立快照替换服务。
  constructor(private readonly migrations: SyncMigrationService) {}

  /// 读取目标身份和覆盖范围，不创建会话。
  @Post('connection-preview')
  @HttpCode(200)
  preview(
    @Body() input: ConnectionPreviewDto,
  ): ReturnType<SyncMigrationService['preview']> {
    return this.migrations.preview(input.syncKey);
  }

  /// 原子替换目标快照，重复请求返回既有回执。
  @Post('migrations')
  @HttpCode(200)
  replace(
    @Body() input: SyncMigrationDto,
  ): ReturnType<SyncMigrationService['replace']> {
    return this.migrations.replace(input);
  }

  /// 查询提交结果，不把暂时不存在解释为请求已经终止。
  @Post('migrations/status')
  @HttpCode(200)
  status(
    @Body() input: MigrationStatusDto,
  ): ReturnType<SyncMigrationService['status']> {
    return this.migrations.status(input);
  }
}
