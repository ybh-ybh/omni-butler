import { Body, Controller, HttpCode, Post, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import type { AuthUser } from '../auth/auth.types';
import { CurrentUser } from '../auth/current-user.decorator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { SyncBatchDto } from './dto/sync-batch.dto';
import { SyncService } from './sync.service';

/// PowerSync 客户端离线操作上传接口。
@ApiTags('sync')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('sync')
export class SyncController {
  /// 注入同步落库服务。
  constructor(private readonly sync: SyncService) {}

  /// 原子应用一批 PowerSync CRUD 操作。
  @Post('operations')
  @HttpCode(200)
  @ApiOperation({ summary: '批量上传 PowerSync 本地 CRUD 操作' })
  applyBatch(
    @CurrentUser() user: AuthUser,
    @Body() input: SyncBatchDto,
  ): ReturnType<SyncService['applyBatch']> {
    return this.sync.applyBatch(user.sub, input);
  }
}
