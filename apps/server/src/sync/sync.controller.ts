import {
  Body,
  Controller,
  Headers,
  HttpCode,
  Post,
  Get,
  Param,
  UseGuards,
} from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import type { AuthUser } from '../auth/auth.types';
import { CurrentUser } from '../auth/current-user.decorator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { SyncBatchDto } from './dto/sync-batch.dto';
import { SyncService } from './sync.service';
import { requireSyncSchemaVersion } from './sync-schema';

/// PowerSync 客户端离线操作上传接口。
@ApiTags('sync')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('sync')
export class SyncController {
  /// 注入同步落库服务。
  constructor(private readonly sync: SyncService) {}

  /// 已认证设备查看持久冲突摘要，MCP令牌不能访问。
  @Get('write-conflicts')
  conflicts(@CurrentUser() user: AuthUser): ReturnType<SyncService['listWriteConflicts']> { return this.sync.listWriteConflicts(user.sub); }

  /// 用户选择前重新读取完整本机意图及服务器事实。
  @Get('write-conflicts/:id')
  conflict(@CurrentUser() user: AuthUser, @Param('id') id: string): ReturnType<SyncService['getWriteConflict']> { return this.sync.getWriteConflict(user.sub, id); }

  /// 决策只能由设备界面提交，不能把普通重试当成授权覆盖。
  @Post('write-conflicts/:id/resolve')
  @HttpCode(200)
  resolveConflict(@CurrentUser() user: AuthUser, @Param('id') id: string, @Body() value: unknown): ReturnType<SyncService['resolveWriteConflict']> { return this.sync.resolveWriteConflict(user, id, value); }

  /// 原子应用一批 PowerSync CRUD 操作。
  @Post('operations')
  @HttpCode(200)
  @ApiOperation({ summary: '批量上传 PowerSync 本地 CRUD 操作' })
  applyBatch(
    @CurrentUser() user: AuthUser,
    @Body() input: SyncBatchDto,
    @Headers('x-omni-sync-schema') version?: string,
  ): ReturnType<SyncService['applyBatch']> {
    requireSyncSchemaVersion(version);
    return this.sync.applyBatch(user.sub, input);
  }
}
