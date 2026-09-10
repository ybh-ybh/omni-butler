import { ValidationPipe } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import helmet from 'helmet';
import { AppModule } from './app.module';

/// 启动 NestJS HTTP 服务。
async function bootstrap(): Promise<void> {
  // 应用实例。
  const app = await NestFactory.create(AppModule);
  // 应用配置服务。
  const config = app.get(ConfigService);
  // API 全局路径前缀。
  const prefix = config.getOrThrow<string>('API_PREFIX');
  // 允许跨域的来源列表。
  const origins = config
    .getOrThrow<string>('CORS_ORIGINS')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);

  app.use(helmet());
  app.enableCors({ origin: origins, credentials: false });
  app.setGlobalPrefix(prefix);
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
  SwaggerModule.setup(`${prefix}/docs`, app, document);

  // 服务监听端口。
  const port = config.getOrThrow<number>('PORT');
  await app.listen(port, '0.0.0.0');
}

void bootstrap();
