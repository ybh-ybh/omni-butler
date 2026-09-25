# Omni Butler Server

NestJS 11 + Prisma 7 + PowerSync 的个人自托管同步 API。服务不提供注册、邮箱登录或用户管理；设备通过 `SYNC_SECRET` 建立独立设备会话，使用短期访问令牌请求 API。

## 本地验证

1. 执行 `npm ci`。
2. 准备启用 `wal_level=logical` 的 PostgreSQL，复制 `.env.example` 为 `.env` 并填写连接地址、同步密钥和对外地址。迁移连接须有创建 publication 的权限。
3. 执行 `npm run prisma:generate`、`npm run prisma:migrate:deploy`、`npm run dev`。密钥自动写入 `.local/keys`，无需手工生成。
4. 打开 `http://127.0.0.1:3000/api/v1/docs` 查看 OpenAPI。

空数据库会自动创建随机内部归属标识，用于 `user_id` 隔离和客户端防止误连其他服务器；没有邮箱、密码或角色。

当前是重整后的测试基线，旧版服务器数据库不可原地套用。测试数据可清空后重建业务库与 PowerSync 状态库，并在客户端清除旧测试数据、重新连接；不要对其他项目的数据执行清理。

## 设备连接接口

- `POST /api/v1/auth/connect`：提交 `syncKey`，建立设备会话。
- `POST /api/v1/auth/refresh`：使用稳定设备凭证换取新访问令牌；不轮换凭证、不延长固定会话期限。
- `POST /api/v1/auth/disconnect`：删除当前设备会话，后续 API 请求即失效；已签发的 PowerSync JWT 最多仍有效 15 分钟。
- `POST /api/v1/auth/powersync-token`：获取短期 PowerSync JWT。

## 同步协议与验证

`POST /api/v1/sync/operations` 接收 `{clientId, transactionId, operations}`。事务重试必须保留身份和内容；每个本地事务整体提交，最大 100000 条、32 MB。PUT 只创建，PATCH 修改已有记录，DELETE 保留永久删除墓碑。缺失记录 PATCH 返回 409，不能假确认成功。

- `npm test`：单元测试，未配置隔离数据库时集成套件跳过。
- `npm run test:integration`：先将 `OMNI_TEST_DATABASE_URL` 指向独立空库（库名以 `_test` 或 `_integration` 结尾），执行真实 PostgreSQL 回归；测试会创建并清理该库的测试表。
- Flutter 真实双设备测试见 `apps/client/test/powersync_server_e2e_test.dart`。

完整 Docker 部署步骤见 `deploy/README.md`；保留/删除依据、字段审计、15 项修复映射见 [同步设计说明](docs/sync-design.md)。图片仍只保存在客户端本机，服务器 COS 实现已删除。
