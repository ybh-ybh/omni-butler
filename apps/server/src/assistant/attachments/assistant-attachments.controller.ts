import {
  BadRequestException,
  Controller,
  Delete,
  Get,
  Param,
  Post,
  Put,
  Res,
  UploadedFile,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import type { Response } from 'express';
import type { AuthUser } from '../../auth/auth.types';
import { CurrentUser } from '../../auth/current-user.decorator';
import { JwtAuthGuard } from '../../auth/jwt-auth.guard';
import { AssistantAttachmentsService } from './assistant-attachments.service';
import { ATTACHMENT_LIMITS } from './attachment.types';

/// 附件全部经过现有JWT入口，MinIO地址和对象键永不公开。
@Controller('assistant')
@UseGuards(JwtAuthGuard)
export class AssistantAttachmentsController {
  /// 注入独立附件领域服务。
  constructor(private readonly attachments: AssistantAttachmentsService) {}

  /// 服务器开关与有限格式目录供客户端探测。
  @Get('attachments/capabilities')
  capabilities(): ReturnType<AssistantAttachmentsService['capabilities']> {
    return this.attachments.capabilities();
  }

  /// multipart只接受一个有限文件，不接收任意服务器路径。
  @Put('conversations/:conversationId/attachments/:uploadId')
  @UseInterceptors(
    FileInterceptor('file', {
      limits: {
        fileSize: ATTACHMENT_LIMITS.maxFileBytes,
        files: 1,
        fields: 0,
        fieldSize: 256,
      },
    }),
  )
  upload(
    @CurrentUser() actor: AuthUser,
    @Param('conversationId') conversationId: string,
    @Param('uploadId') uploadId: string,
    @UploadedFile() file?: { buffer: Buffer; originalname: string },
  ): ReturnType<AssistantAttachmentsService['upload']> {
    if (!file?.buffer) throw new BadRequestException('缺少附件文件');
    return this.attachments.upload(actor, conversationId, uploadId, file);
  }

  /// 无正文状态查询用于有界轮询。
  @Get('attachments/:id')
  metadata(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
  ): ReturnType<AssistantAttachmentsService['metadata']> {
    return this.attachments.metadata(actor, id);
  }

  /// 下载强制附件模式、私有缓存与nosniff，文档不能作为活动页面执行。
  @Get('attachments/:id/file')
  async file(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
    @Res() response: Response,
  ): Promise<void> {
    // 对象存储读取完成后服务会再次校验撤权。
    const file = await this.attachments.file(actor, id);
    response.setHeader('Content-Type', file.mimeType);
    response.setHeader(
      'Content-Disposition',
      `attachment; filename="attachment"; filename*=UTF-8''${encodeURIComponent(file.name)}`,
    );
    response.setHeader('Cache-Control', 'private, no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.send(file.bytes);
  }

  /// 解析失败复用原件重做，不创建模型请求。
  @Post('attachments/:id/retry')
  retry(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
  ): ReturnType<AssistantAttachmentsService['retry']> {
    return this.attachments.retry(actor, id);
  }

  /// 仅未发送附件允许独立移除。
  @Delete('attachments/:id')
  remove(
    @CurrentUser() actor: AuthUser,
    @Param('id') id: string,
  ): ReturnType<AssistantAttachmentsService['remove']> {
    return this.attachments.remove(actor, id);
  }
}
