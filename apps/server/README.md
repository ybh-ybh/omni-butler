# Omni Butler Server

NestJS 11 + Prisma 7 + PowerSync 的个人自托管同步 API。服务不提供注册、邮箱登录或用户管理；设备通过 `SYNC_SECRET` 建立独立设备会话，使用短期访问令牌请求 API。

## 本地验证

1. 执行 `npm ci`。
2. 准备启用 `wal_level=logical` 的 PostgreSQL，复制 `.env.example` 为 `.env` 并填写连接地址、同步密钥和对外地址。迁移连接须有创建 publication 的权限。
3. 执行 `npm run prisma:generate`、`npm run prisma:migrate:deploy`、`npm run dev`。密钥自动写入 `.local/keys`，无需手工生成。
4. 打开 `http://127.0.0.1:3000/omni-butler/api/v1/docs` 查看 OpenAPI。

业务 API 路径固定为 `/omni-butler/api/v1/`，不从环境变量或客户端设置读取。Compose 健康检查、PowerSync 公钥地址和 Nginx 路由均使用这个固定前缀。

空数据库会自动创建随机内部归属标识，用于 `user_id` 隔离和客户端防止误连其他服务器；没有邮箱、密码或角色。

当前是重整后的测试基线，旧版服务器数据库不可原地套用。测试数据可清空后重建业务库与 PowerSync 状态库，并在客户端清除旧测试数据、重新连接；不要对其他项目的数据执行清理。

## 设备连接接口

- `POST /omni-butler/api/v1/auth/connect`：提交 `syncKey`，建立设备会话。
- `POST /omni-butler/api/v1/auth/refresh`：使用稳定设备凭证换取新访问令牌；不轮换凭证、不延长固定会话期限。
- `POST /omni-butler/api/v1/auth/disconnect`：删除当前设备会话，后续 API 请求即失效；已签发的 PowerSync JWT 最多仍有效 15 分钟。
- `POST /omni-butler/api/v1/auth/powersync-token`：获取短期 PowerSync JWT。

## 同步协议与验证

`POST /omni-butler/api/v1/sync/operations` 接收 `{clientId, transactionId, operations}`。事务重试必须保留身份和内容；每个本地事务整体提交，最大 100000 条、32 MB。PUT 只创建，PATCH 修改已有记录，DELETE 保留永久删除墓碑。缺失记录 PATCH 返回 409，不能假确认成功。

当前同步结构为 `syncSchemaVersion=2`。增量上传、全量替换和 PowerSync 凭证接口均要求 `X-Omni-Sync-Schema: 2`，版本不兼容返回 `409 SYNC_SCHEMA_MISMATCH`；客户端必须保留本地数据及待上传事务并停止同步。预检、连接、刷新、会话与凭证响应包含当前版本。发布时先升级数据库、API 与 PowerSync 规则，再升级各客户端；这次增量迁移保留已有数据，无需重置数据库。

进度任务使用 `todo_items.task_type=progress` 和独立 `todo_progress_steps` 表，步骤只能属于同 owner 的进度根任务。满进度不自动完成；事务最后仅撤销不再满足满进度条件的已确认任务。父任务软删除保留步骤自身删除标记，恢复不会复活独立删除的步骤；永久删除级联步骤并记录墓碑。快照协议为 v2，完整导入步骤之后再协调，保留合法的手动完成确认。

- `npm test`：单元测试，未配置隔离数据库时集成套件跳过。
- `npm run test:integration`：先将 `OMNI_TEST_DATABASE_URL` 指向独立空库（库名以 `_test` 或 `_integration` 结尾），执行真实 PostgreSQL 回归；测试会创建并清理该库的测试表。
- Flutter 真实双设备测试见 `apps/client/test/powersync_server_e2e_test.dart`。

完整 Docker 部署步骤见 `deploy/README.md`；保留/删除依据、字段审计和同步一致性修复见 [同步设计说明](docs/sync-design.md)。服务器启用 `IMAGE_SYNC_ENABLED=true` 后，物品和会员主图通过认证 API 与内置私有 MinIO 同步；首页横幅仍只保存在客户端本机。
