import { Body, Controller, Delete, Get, Param, ParseUUIDPipe, Post, Put, UseGuards } from '@nestjs/common';
import type { AuthUser } from '../auth/auth.types';
import { CurrentUser } from '../auth/current-user.decorator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { AiProfileDto, AiRevisionDto, AiSettingsDto, AiTestDto } from './ai.dto';
import { AiService } from './ai.service';

/// 模型设置沿用现有设备 JWT，仅操作当前 owner 数据。
@Controller('ai')
@UseGuards(JwtAuthGuard)
export class AiController {
  /// 配置和测试都通过统一领域服务执行。
  constructor(private readonly ai: AiService) {}
  /// 两端读取后端唯一共享快照。
  @Get('settings')
  settings(@CurrentUser() user: AuthUser): ReturnType<AiService['settings']> { return this.ai.settings(user.sub); }
  /// 选择当前模型与开启整理共用版本号。
  @Put('settings')
  updateSettings(@CurrentUser() user: AuthUser, @Body() input: AiSettingsDto): ReturnType<AiService['updateSettings']> { return this.ai.updateSettings(user.sub, input); }
  /// 首个配置自动设为当前使用，整理开关由用户独立控制。
  @Post('profiles')
  create(@CurrentUser() user: AuthUser, @Body() input: AiProfileDto): ReturnType<AiService['saveProfile']> { return this.ai.saveProfile(user.sub, input); }
  /// 空 Key 保留，显式标记才删除。
  @Put('profiles/:id')
  update(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() input: AiProfileDto): ReturnType<AiService['saveProfile']> { return this.ai.saveProfile(user.sub, input, id); }
  /// 删除当前配置会同时关闭整理。
  @Delete('profiles/:id')
  remove(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() input: AiRevisionDto): ReturnType<AiService['deleteProfile']> { return this.ai.deleteProfile(user.sub, id, input.revision); }
  /// 测试只发送固定短文本，不保存输入。
  @Post('test')
  test(@CurrentUser() user: AuthUser, @Body() input: AiTestDto): ReturnType<AiService['test']> { return this.ai.test(user.sub, input); }
}
