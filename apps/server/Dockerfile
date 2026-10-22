# 使用 BuildKit 内置前端，避免构建前额外从 Docker Hub 拉取语法镜像。
FROM node:24-bookworm-slim AS base
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

FROM base AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
# 腾讯云轻量服务器默认使用国内 npm 镜像，可通过构建参数覆盖。
ARG NPM_REGISTRY=https://registry.npmmirror.com
RUN npm config set registry ${NPM_REGISTRY} && npm ci

FROM dependencies AS build
COPY nest-cli.json tsconfig.json tsconfig.build.json prisma.config.ts ./
COPY prisma ./prisma
COPY src ./src
RUN DATABASE_URL=postgresql://placeholder:placeholder@127.0.0.1:5432/omni_butler npm run prisma:generate
RUN npm run build

FROM base AS production-dependencies
WORKDIR /app
COPY package.json package-lock.json ./
ARG NPM_REGISTRY=https://registry.npmmirror.com
RUN npm config set registry ${NPM_REGISTRY} && npm ci --omit=dev

FROM base AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=production-dependencies /app/node_modules ./node_modules
# 复用构建阶段已下载的迁移引擎，避免非 root 启动时补下载到只读依赖目录。
COPY --from=build /app/node_modules/@prisma/engines/schema-engine-* ./node_modules/@prisma/engines/
COPY --from=build /app/dist ./dist
COPY --from=build /app/prisma ./prisma
COPY --from=build /app/prisma.config.ts ./prisma.config.ts
COPY --from=build /app/package.json ./package.json
# 为非 root 运行用户预建密钥目录，首次挂载命名卷时沿用其权限。
RUN mkdir -p /app/keys && chown node:node /app/keys && chmod 700 /app/keys
USER node
EXPOSE 3000
CMD ["sh", "-c", "npx prisma migrate deploy && node dist/main.js"]
