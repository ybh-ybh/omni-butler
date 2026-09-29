import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { ImageObjectStore, MinioImageObjectStore } from './image-object-store';
import { ImagesController } from './images.controller';
import { ImagesService } from './images.service';

/// 单开关图片服务模块；关闭时不产生外部存储连接。
@Module({
  imports: [AuthModule],
  controllers: [ImagesController],
  providers: [
    ImagesService,
    { provide: ImageObjectStore, useClass: MinioImageObjectStore },
  ],
})
export class ImagesModule {}
