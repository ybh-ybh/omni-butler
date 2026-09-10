import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { CosController } from './cos.controller';
import { CosService } from './cos.service';

/// 腾讯云 COS 临时授权模块。
@Module({
  imports: [AuthModule],
  controllers: [CosController],
  providers: [CosService],
})
export class CosModule {}
