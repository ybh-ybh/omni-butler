import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Put,
  Query,
  Res,
  UploadedFile,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import type { Response } from 'express';
import type { AuthUser } from '../auth/auth.types';
import { CurrentUser } from '../auth/current-user.decorator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { ImageRemoveDto, ImageUploadDto } from './image.dto';
import { IMAGE_MAX_BYTES, ImagesService } from './images.service';

/// 与现有业务 API 共用会话及公网地址，MinIO 不对客户端暴露。
@Controller('images')
@UseGuards(JwtAuthGuard)
export class ImagesController {
  /// 注入图片领域服务。
  constructor(private readonly images: ImagesService) {}

  /// 自动发现服务器图片能力。
  @Get('capabilities')
  capabilities(): ReturnType<ImagesService['capabilities']> {
    return this.images.capabilities();
  }

  /// 获取包含移除标记的完整图片清单。
  @Get()
  list(@CurrentUser() user: AuthUser): ReturnType<ImagesService['list']> {
    return this.images.list(user);
  }

  /// 内存上传限制单文件大小、字段数量及表单字段大小。
  @Put(':businessType/:businessId')
  @UseInterceptors(
    FileInterceptor('file', {
      limits: {
        fileSize: IMAGE_MAX_BYTES,
        files: 1,
        fields: 5,
        fieldSize: 256,
        // 字段与文件分别限量；Busboy 的 partsLimit 在达到阈值时触发。
      },
    }),
  )
  upload(
    @CurrentUser() user: AuthUser,
    @Param('businessType') type: string,
    @Param('businessId') id: string,
    @Body() input: ImageUploadDto,
    @UploadedFile() file?: { buffer: Buffer },
  ): ReturnType<ImagesService['upload']> {
    if (!file?.buffer) throw new BadRequestException('缺少图片文件');
    return this.images.upload(user, type, id, input, file.buffer);
  }

  /// 移除业务图片并发布持久标记。
  @Delete(':businessType/:businessId')
  remove(
    @CurrentUser() user: AuthUser,
    @Param('businessType') type: string,
    @Param('businessId') id: string,
    @Body() input: ImageRemoveDto,
  ): ReturnType<ImagesService['remove']> {
    return this.images.remove(user, type, id, input);
  }

  /// 返回经过授权的当前版本，不允许公共缓存私有图片。
  @Get(':businessType/:businessId/file')
  async download(
    @CurrentUser() user: AuthUser,
    @Param('businessType') type: string,
    @Param('businessId') id: string,
    @Query('revision') revision: string,
    @Res() response: Response,
  ): Promise<void> {
    // 当前版本图片数据。
    const result = await this.images.download(user, type, id, revision);
    response.setHeader('Content-Type', result.mime);
    response.setHeader('Cache-Control', 'private, no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.send(result.bytes);
  }
}
