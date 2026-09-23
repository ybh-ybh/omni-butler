# Omni Butler 自托管同步服务

这一部署只面向个人多设备同步，不提供注册、邮箱登录或用户管理。Windows 与 Android 客户端使用“服务器地址 + 同步密钥”建立设备会话。

## 架构概览

`docker-compose.yml` 编排了三个服务：

| 服务 | 镜像 / 来源 | 端口 | 职责 |
| --- | --- | --- | --- |
| `postgres` | `postgres:17-bookworm` | 仅 Compose 内部 | 业务库 + PowerSync 状态库 |
| `api` | `../apps/server` 构建 | `3000` | NestJS API、设备认证、Prisma 迁移、启动自举 |
| `powersync` | `journeyapps/powersync-service` | `8080` | 通过逻辑复制流把变更推送到客户端 |

三者的启动顺序由健康检查串起来：`postgres` 就绪 → `api` 就绪 → `powersync` 启动。

## 部署前提

- 安装 Docker Desktop 或 Docker Engine（含 Compose）。
- 生成 RSA 密钥需要临时使用 Node.js（见下文）；生成后的密钥只写进 `.env`，不随镜像分发。
- 客户端能访问到服务器 IP：局域网用内网 IP，公网用域名 + HTTPS 反向代理。

## 部署步骤

1. 进入本目录（`deploy/`）。

2. 复制环境变量模板：

   ```powershell
   Copy-Item .env.example .env
   ```

3. 替换 `.env` 中的必填项：

   - `POSTGRES_PASSWORD`：数据库密码，长随机串。
   - `SYNC_SECRET`：设备同步密钥，至少 16 字符。
   - `PS_ADMIN_TOKEN`：PowerSync 管理令牌，长随机串。

4. 生成 RSA 密钥（在 `apps/server` 目录执行，需已安装 Node.js）：

   ```powershell
   cd ../apps/server
   npm run keys:generate
   cd ../../deploy
   ```

   把输出中的 `JWT_PRIVATE_KEY_BASE64` 与 `JWT_PUBLIC_KEY_BASE64` 写入 `deploy/.env`。不要提交真实密钥。

5. 设置对外地址：

   - 局域网：`POWERSYNC_PUBLIC_URL=http://<服务器IP>:8080`
   - 公网：放在 HTTPS 反向代理后，填 `https://sync.example.com`

6. 构建并启动：

   ```powershell
   docker compose up -d --build
   ```

## 首次启动会自动发生什么

- **数据库初始化**：`postgres/init.sql` 创建 `powersync_storage` 库，并授予 `omni_butler` 角色 `REPLICATION` 权限；PostgreSQL 以 `wal_level=logical` 启动，作为 PowerSync 的复制源。
- **Prisma 迁移**：`api` 容器启动命令为 `npx prisma migrate deploy && node dist/main.js`，即先应用 `apps/server/prisma/migrations` 下的全部迁移再启动服务。
- **内部数据所有者**：`api` 启动自举（`SyncOwnerService`）在空库时创建一个 `sync-owner@localhost.invalid` 的内部用户，仅用于现有表的 `user_id` 隔离，不是可登录账号。
- **逻辑复制发布**：`api` 自举（`PowerSyncPublicationService`）幂等地创建 `pg_publication 'powersync' FOR ALL TABLES`，供 PowerSync 订阅。
- **PowerSync 接入**：`powersync` 通过 `PS_DATA_SOURCE_URI` 读业务库逻辑复制流，通过 `PS_STORAGE_URI` 写自己的状态库，并从 `api` 的 JWKS 端点（`http://api:3000/api/v1/auth/jwks`）校验客户端令牌。

API 的 OpenAPI 文档位于 `http://<服务器>:3000/api/v1/docs`。

## 客户端连接

在客户端开启“多端数据同步”，填写：

- 服务器 URL：局域网示例 `http://192.168.1.10:3000/api/v1`
- 同步密钥：`.env` 中的 `SYNC_SECRET`

设备连接接口（均挂在 `POST /api/v1/auth` 下）：

- `connect`：提交 `syncKey`，建立设备会话
- `refresh`：轮换设备会话令牌
- `disconnect`：撤销当前设备的刷新令牌
- `powersync-token`：获取短期 PowerSync JWT

## 环境变量说明

| 变量 | 用途 | 备注 |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | 业务库与状态库密码 | 首次部署前必须替换 |
| `SYNC_SECRET` | 设备同步密钥 | 首次部署前必须替换 |
| `PS_ADMIN_TOKEN` | PowerSync 管理令牌 | 首次部署前必须替换 |
| `POWERSYNC_PUBLIC_URL` | PowerSync 对外地址 | 客户端会连接此地址 |
| `PS_JWKS_URL` | PowerSync 校验 JWT 的 JWKS 地址 | 默认 `http://api:3000/api/v1/auth/jwks` |
| `PS_PORT` | PowerSync 监听端口 | 默认 8080 |
| `POWERSYNC_AUDIENCE` | PowerSync JWT 受众 | 默认 `omni-butler-powersync` |
| `PORT` / `API_PREFIX` | API 端口与路径前缀 | 默认 3000 / `api/v1` |
| `CORS_ORIGINS` | 允许的跨域来源，逗号分隔 | 公网填实际前端域名 |
| `JWT_PRIVATE_KEY_BASE64` | RSA 私钥（Base64） | 由 `keys:generate` 生成 |
| `JWT_PUBLIC_KEY_BASE64` | RSA 公钥（Base64） | 由 `keys:generate` 生成 |
| `JWT_KEY_ID` / `JWT_ISSUER` / `JWT_AUDIENCE` | JWT 元信息 | 公网部署需与域名一致 |
| `REFRESH_TOKEN_TTL_SECONDS` | 刷新令牌有效期 | 默认 2592000（30 天） |

## 常用运维命令

```powershell
# 查看容器状态
docker compose ps

# 查看 API 与 PowerSync 日志
docker compose logs -f api powersync

# API 健康检查（含数据库连通性）
Invoke-WebRequest http://127.0.0.1:3000/api/v1/health

# PowerSync 存活探针
Invoke-WebRequest http://127.0.0.1:8080/probes/liveness

# 更新代码后重建并拉起（迁移会自动应用）
docker compose up -d --build

# 停止服务（数据卷会被保留）
docker compose down
```

## 数据与备份

- 业务数据与 PowerSync 状态分别存放在 `postgres` 的两个库里，统一落在命名卷 `postgres-data`。
- 备份在宿主机执行：`docker compose exec -T postgres pg_dump -U omni_butler omni_butler > backup.sql`。
- 恢复、自动备份策略与 WAL / 复制槽监控尚未落地，见根目录 `未完成任务.md`。

## 网络与安全

- 局域网 HTTP 仅适合可信家庭网络；同步密钥会经过该网络传输。
- 公网部署必须使用 HTTPS 反向代理，并只暴露 API 与 PowerSync 所需端口。
- `5432` 没有映射到宿主机，PostgreSQL 默认只供 Compose 内部服务访问。
- 当前 MVP 不同步图片，也不启用腾讯云 COS。

目标服务器、HTTPS、备份恢复、WAL/复制槽监控和安全加固的未完成项统一见根目录 `未完成任务.md`。