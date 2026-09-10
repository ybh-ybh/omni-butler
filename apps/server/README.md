# Omni Butler Server

NestJS 11 + Prisma 7 + PowerSync 的个人自托管同步 API。服务不提供注册、邮箱登录或用户管理；设备通过部署者设置的 `SYNC_SECRET` 建立可轮换的短期会话。

## 本地验证

1. 执行 `npm ci`。
2. 准备 PostgreSQL，并参考仓库 `deploy/.env.example` 配置服务端必填环境变量；`SYNC_SECRET` 至少 16 字符。
3. 执行 `npm run keys:generate`，把输出写入 `JWT_PRIVATE_KEY_BASE64` 和 `JWT_PUBLIC_KEY_BASE64`。
4. 执行 `npm run prisma:generate`、`npm run prisma:migrate:deploy`、`npm run dev`。
5. 打开 `http://127.0.0.1:3000/api/v1/docs` 查看 OpenAPI。

空数据库会自动创建一个内部数据所有者。它只用于现有表的 `user_id` 隔离，不是用户账号，也不能通过密码访问。

## 设备连接接口

- `POST /api/v1/auth/connect`：提交 `syncKey`，建立设备会话。
- `POST /api/v1/auth/refresh`：轮换设备会话令牌。
- `POST /api/v1/auth/disconnect`：撤销当前设备的刷新令牌。
- `POST /api/v1/auth/powersync-token`：获取短期 PowerSync JWT。

完整的 Docker Compose 部署步骤见仓库 `deploy/README.md`。当前 MVP 的图片只保存在客户端本机，COS 模块不在运行时注册；生产化缺口统一见根目录 `未完成任务.md`。
