import { Module } from '@nestjs/common';
import { MinioConnection } from './minio-connection';

/// 同一个Nest模块在图片和笔记间共享单一懒加载连接。
@Module({ providers: [MinioConnection], exports: [MinioConnection] })
export class StorageModule {}
