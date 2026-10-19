# Omni Butler Server

NestJS 11 + Prisma 7 + PowerSync 的个人自托管同步 API。服务不提供注册、邮箱登录或用户管理；设备通过 `SYNC_SECRET` 建立独立设备会话，使用短期访问令牌请求 API。

## 本地验证

1. 执行 `npm ci`。
2. 准备启用 `wal_level=logical` 的 PostgreSQL，复制 `.env.example` 为 `.env` 并填写连接地址、同步密钥和对外地址。迁移连接须有创建 publication 的权限。
3. 执行 `npm run prisma:generate`、`npm run prisma:migrate:deploy`、`npm run dev`。密钥自动写入 `.local/keys`，无需手工生成。
4. 打开 `http://127.0.0.1:3000/omni-butler/api/v1/docs` 查看 OpenAPI。

业务 API 路径固定为 `/omni-butler/api/v1/`，不从环境变量或客户端设置读取。Compose 健康检查、PowerSync 公钥地址和 Nginx 路由均使用这个固定前缀。

同域名 HTTPS 部署可只配置 `PUBLIC_BASE_URL=https://butler.example.com`，自动生成 `POWERSYNC_URL=https://butler.example.com/omni-butler/powersync/` 和 `NOTE_ASR_PUBLIC_URL=https://butler.example.com/omni-butler/api/v1`。基础地址只接受 HTTPS 根地址，可带端口或末尾 `/`，不能包含凭据、额外路径、查询参数或片段。

非空的 `POWERSYNC_URL`、`NOTE_ASR_PUBLIC_URL` 独立覆盖优先，空值使用基础地址推导；升级使用新基础地址时应删除或注释旧覆盖值。Compose 使用的覆盖名称为 `POWERSYNC_PUBLIC_URL`，映射到后端 `POWERSYNC_URL`。本地示例保留 `POWERSYNC_URL=http://127.0.0.1:8080`，不配置基础地址即可继续使用局域网 HTTP 及独立端口；没有任何同步地址则拒绝启动。没有 ASR 公网地址时仍支持小文件内联识别；配置公网地址不会自动启用识别厂商。部署示例见 [部署说明](../../deploy/README.md)。

空数据库会自动创建随机内部归属标识，用于 `user_id` 隔离和客户端防止误连其他服务器；没有邮箱、密码或角色。

当前是重整后的测试基线，旧版服务器数据库不可原地套用。测试数据可清空后重建业务库与 PowerSync 状态库，并在客户端清除旧测试数据、重新连接；不要对其他项目的数据执行清理。

笔记标签颜色已退休：`20261016010000_retire_note_tag_colors` 仅清空 `module=notes AND kind=tag` 的 `color_value`（含软删除记录），并添加数据库 CHECK 约束，防止再次写入。共享颜色列保留，物品、时间与会员模块的颜色不受影响。旧笔记标签 PUT、PATCH 和换服快照在执行副本上归一为 `null`，不修改原始幂等负载。先备份并执行增量迁移，再更新 API、最后升级全部客户端到同步结构 v10；PowerSync 下行查询字段不变。

## 笔记记录时间与置顶升级

`20261019000000_note_record_time` 增加记录秒数和设定偏移；`20261019010000_note_pinning` 增加 `note_entries.is_pinned BOOLEAN NOT NULL DEFAULT false`。置顶只修改元数据，不新增正文版本；旧正文 PATCH 缺失 `is_pinned` 时保留已有状态，显式状态必须为 JSON boolean。两端组内按记录日期时间倒序，置顶组排在普通组之前。

先完整备份 PostgreSQL、图片/原音及密钥，再执行增量迁移、发布 API 与 `deploy/powersync/sync-config.yaml`，最后升级全部客户端。客户端 SQLite25、同步 schema10、本机快照10（兼容1–9），换服 wire `snapshotVersion=3` 保持；旧备份缺失置顶字段时按未置顶恢复。本轮仅交付实现与隔离测试，未代为执行正式迁移或联网同步验收。

## 设备连接接口

- `POST /omni-butler/api/v1/auth/connect`：提交 `syncKey`，建立设备会话。
- `POST /omni-butler/api/v1/auth/refresh`：使用稳定设备凭证换取新访问令牌；不轮换凭证、不延长固定会话期限。
- `POST /omni-butler/api/v1/auth/disconnect`：删除当前设备会话，后续 API 请求即失效；已签发的 PowerSync JWT 最多仍有效 15 分钟。
- `POST /omni-butler/api/v1/auth/powersync-token`：获取短期 PowerSync JWT。

## 同步协议与验证

`POST /omni-butler/api/v1/sync/operations` 接收 `{clientId, transactionId, operations}`。事务重试必须保留身份和内容；每个本地事务整体提交，最大 100000 条、32 MB。PUT 只创建，PATCH 修改已有记录，DELETE 保留永久删除墓碑。缺失记录 PATCH 返回 409，不能假确认成功。

当前同步结构为 `syncSchemaVersion=10`。增量上传、全量替换和 PowerSync 凭证接口均要求 `X-Omni-Sync-Schema: 10`，版本不兼容返回 `409 SYNC_SCHEMA_MISMATCH`；客户端必须保留本地数据及待上传事务并停止同步。预检、连接、刷新、会话与凭证响应包含当前版本。发布时先升级数据库、API 与 PowerSync 规则，再升级各客户端；这次增量迁移保留已有数据，无需重置数据库。

标签图标使用可空 `taxonomy_entries.icon_emoji` 文本列，完整保存组合 emoji，`null` 表示默认 `#`。PATCH 缺失该列时保留已有图标，显式 `null` 才移除；名称、置顶和排序的独立更新不会覆盖图标。升级时先备份，再执行 `npm run prisma:migrate:deploy` 应用 `20261016000000_note_tag_icon_emoji`，更新 API 与 `deploy/powersync/sync-config.yaml` 的下行查询，最后升级参与同步的所有客户端。服务端 v10 会拒绝 v9 及更旧客户端的写入和下行凭证，升级期间允许客户端保留本地离线操作。

客户端本地快照格式升至 v7，恢复 v1–v6 时由客户端为历史标签补 `icon_emoji: null`。换服网络协议继续使用 `snapshotVersion=3`（无笔记旧请求仍支持 v2），完整标签行必须包含 `icon_emoji`，不要将本地快照格式 v7 直接作为换服协议号。部署后在隔离环境验证一台设备设置组合 emoji，另一台设备接收、改名及清空，确认两个方向均生效后再推广客户端。

进度任务使用 `todo_items.task_type=progress` 和独立 `todo_progress_steps` 表，步骤只能属于同 owner 的进度根任务。满进度不自动完成；事务最后仅撤销不再满足满进度条件的已确认任务。父任务软删除保留步骤自身删除标记，恢复不会复活独立删除的步骤；永久删除级联步骤并记录墓碑。完整导入步骤之后再协调，保留合法的手动完成确认。

笔记使用 `note_entries`、`note_versions`、`note_audio_segments` 三张同步表，正文并发版本保留候选，原始录音通过独立的私有文件接口传输，生产原音及迁移暂存统一保存到 MinIO 私有桶 `omni-butler-note-audio`，图片开关不影响音频。语音厂商密钥只在后端，腾讯文件识别适配器与领域任务解耦。提交响应丢失时保留 `submissionUnknown`，绝不自动重复提交计费任务；只有查询已知任务允许自动网络重试。完整迁移必须先暂存真实原音，再在快照 v3 同一事务验证并接管；回收站绑定正文、原音和结果一起保留、恢复及永久清理。接口、环境变量、备份与故障语义见[笔记原音说明](src/notes/README.md)。

- `npm test`：单元测试，未配置隔离数据库时集成套件跳过。
- `npm run test:integration`：先将 `OMNI_TEST_DATABASE_URL` 指向独立空库（库名以 `_test` 或 `_integration` 结尾），执行真实 PostgreSQL 回归；测试会创建并清理该库的测试表。
- Flutter 真实双设备测试见 `apps/client/test/powersync_server_e2e_test.dart`。

完整 Docker 部署步骤见 `deploy/README.md`；保留/删除依据、字段审计和同步一致性修复见 [同步设计说明](docs/sync-design.md)。服务器启用 `IMAGE_SYNC_ENABLED=true` 后，物品和会员主图通过认证 API 与内置私有 MinIO 同步；首页横幅仍只保存在客户端本机。
