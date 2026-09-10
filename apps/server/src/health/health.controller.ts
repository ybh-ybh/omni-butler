import { Controller, Get } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { PrismaService } from '../prisma/prisma.service';

/// 服务健康检查控制器。
@ApiTags('health')
@Controller('health')
export class HealthController {
  /// 注入数据库服务。
  constructor(private readonly prisma: PrismaService) {}

  /// 返回 API 与数据库可用状态。
  @Get()
  @ApiOperation({ summary: '检查 API 与 PostgreSQL 状态' })
  async check(): Promise<{ status: 'ok'; database: 'ok'; time: string }> {
    await this.prisma.$queryRaw`SELECT 1`;
    return {
      status: 'ok',
      database: 'ok',
      time: new Date().toISOString(),
    };
  }
}
