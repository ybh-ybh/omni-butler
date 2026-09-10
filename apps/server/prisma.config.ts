import 'dotenv/config';
import { defineConfig, env } from 'prisma/config';

// Prisma CLI 与迁移统一读取的项目配置。
export default defineConfig({
  schema: 'prisma/schema.prisma',
  migrations: { path: 'prisma/migrations', seed: 'tsx prisma/seed.ts' },
  datasource: { url: env('DATABASE_URL') },
});
