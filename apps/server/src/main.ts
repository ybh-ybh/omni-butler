import { ValidationPipe } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import helmet from 'helmet';
import { AppModule } from './app.module';

/// Omni Butler 业务 API 的固定全局前缀。
const API_PATH_PREFIX = 'omni-butler/api/v1';

/// 启动 NestJS HTTP 服务。
async function bootstrap(): Promise<void> {
  // 应用实例。
  const app = await NestFactory.create<NestExpressApplication>(AppModule);
  // 完整本地事务必须整体上传，允许初始导入而不按行截断。
  app.useBodyParser('json', { limit: '32mb' });
  // 应用配置服务。
  const config = app.get(ConfigService);
  app.use(helmet());
  app.setGlobalPrefix(API_PATH_PREFIX);
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );

  // OpenAPI 文档配置。
  const swaggerConfig = new DocumentBuilder()
    .setTitle('Omni Butler API')
    .setDescription('Windows 与 Android 设备同步及运行状态接口。')
    .setVersion('1.0')
    .addBearerAuth()
    .build();
  // OpenAPI 文档对象。
  const document = SwaggerModule.createDocument(app, swaggerConfig);
  SwaggerModule.setup(`${API_PATH_PREFIX}/docs`, app, document);

  // 服务监听端口。
  const port = config.getOrThrow<number>('PORT');
  await app.listen(port, '0.0.0.0');
}

void bootstrap();
