# Omni Butler 自托管同步服务

这一部署只面向个人多设备同步，不提供注册、邮箱登录或用户管理。Windows 与 Android 客户端使用“服务器地址 + 同步密钥”建立设备会话。

## 快速部署

1. 安装 Docker Desktop 或 Docker Engine，并进入本目录。
2. 复制 `.env.example` 为 `.env`。
3. 至少替换 `POSTGRES_PASSWORD`、`SYNC_SECRET`、`PS_ADMIN_TOKEN` 与两项 RSA 密钥。
4. 把 `POWERSYNC_PUBLIC_URL` 改成手机可访问的地址，例如 `http://192.168.1.10:8080`。
5. 执行 `docker compose up -d --build`。

API 会在首次启动时自动执行 Prisma 迁移，并创建一个仅用于数据库隔离的内部数据所有者。它不是可登录账号，也没有用户界面。

客户端中开启“多端数据同步”，填写：

- 服务器 URL：局域网示例 `http://192.168.1.10:3000/api/v1`
- 同步密钥：`.env` 中的 `SYNC_SECRET`

## RSA 密钥

在 `apps/server` 目录执行 `npm run keys:generate`，把输出写入 `.env` 的 `JWT_PRIVATE_KEY_BASE64` 和 `JWT_PUBLIC_KEY_BASE64`。不要提交真实密钥。

## 网络边界

- 局域网 HTTP 仅适合可信家庭网络；同步密钥会经过该网络传输。
- 公网部署必须使用 HTTPS 反向代理，并只暴露 API 与 PowerSync 所需端口。
- `5432` 没有映射到宿主机，PostgreSQL 默认只供 Compose 内部服务访问。
- 当前 MVP 不同步图片，也不启用腾讯云 COS。

## 常用检查

```powershell
docker compose ps
docker compose logs api powersync
Invoke-WebRequest http://127.0.0.1:3000/api/v1/health
```

目标服务器、HTTPS、备份恢复、WAL/复制槽监控和安全加固的未完成项统一见根目录 `未完成任务.md`。
