import { Body, Controller, Post, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import type { AuthUser } from '../auth/auth.types';
import { CurrentUser } from '../auth/current-user.decorator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { CosService } from './cos.service';
import { CreateDownloadCredentialDto } from './dto/create-download-credential.dto';
import { CreateUploadCredentialDto } from './dto/create-upload-credential.dto';

/// 腾讯云 COS 客户端直传接口。
@ApiTags('attachments')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('attachments')
export class CosController {
  /// 注入 COS 临时密钥服务。
  constructor(private readonly cos: CosService) {}

  /// 为当前附件申请最小权限临时密钥。
  @Post('upload-credential')
  @ApiOperation({ summary: '获取单附件 COS 直传临时密钥' })
  createUploadCredential(
    @CurrentUser() user: AuthUser,
    @Body() input: CreateUploadCredentialDto,
  ): ReturnType<CosService['createUploadCredential']> {
    return this.cos.createUploadCredential(user, input);
  }

  /// 为当前用户的一条私有附件申请下载临时密钥。
  @Post('download-credential')
  @ApiOperation({ summary: '获取单附件 COS 下载临时密钥' })
  createDownloadCredential(
    @CurrentUser() user: AuthUser,
    @Body() input: CreateDownloadCredentialDto,
  ): ReturnType<CosService['createDownloadCredential']> {
    return this.cos.createDownloadCredential(user, input);
  }
}
