# 个人多设备同步设计

本文说明同步边界、冲突语义和验证要求。目标是让同一个人在多台设备上离线修改结构化数据，再可靠地合并到同一个自托管服务。图片同步通过 `IMAGE_SYNC_ENABLED` 开关控制，Compose 中的私有 MinIO 常驻供图片、笔记原音和助手附件使用；账号注册、多人权限不属于当前目标。

## 从问题确定需要保存的状态

设备离线时，服务器无法阻止本地修改；网络恢复时，请求可能重复、乱序或丢失响应。因此，服务器至少需要区分以下四件事：数据属于哪个部署、哪台设备有权访问、收到的是新事务还是旧事务重试、记录是尚未上传还是已经永久删除。

这分别对应 `SyncOwner`、`DeviceSession`、`SyncReceipt` 和 `SyncTombstone`。它们解决不同的问题，不能用一个“已同步”标记替代。业务表使用 `user_id` 作为内部 `sync_owners` 的归属外键，不表示可登录账号。

| 保留项 | 为什么需要 | 主要实现 |
| --- | --- | --- |
| 部署同步密钥 | 首次连接时判断设备是否获得部署者授权 | `src/auth/auth.service.ts`、`src/config/environment.ts` |
| 随机 owner 身份 | 保持数据归属稳定；重建另一套服务产生不同身份，让客户端发现错连 | `src/auth/sync-owner.service.ts`、`prisma/schema.prisma` |
| 各设备独立、稳定的 session | 可以只断开一台设备；刷新重试不产生新的凭证链 | `src/auth/auth.service.ts`、`src/auth/jwt.strategy.ts` |
| RSA 签名与公开 JWKS | PowerSync 必须能在不查询 API 会话库的情况下验 JWT；只分发公钥即可验签 | `src/config/jwt-keys.ts`、`src/auth/jwks.service.ts` |
| PostgreSQL 事务、回执与删除墓碑 | 将业务写入、派生状态和提交结果一起持久化；阻止旧请求重复执行或复活删除记录 | `src/sync/sync.service.ts`、`prisma/migrations/20260925000100_sync_invariants/migration.sql` |
| 同步表和字段白名单 | 客户端可以提交业务值，不能自行修改归属、设备会话或同步内部表 | `src/sync/dto/sync-operation.dto.ts`、`src/sync/sync-sql.builder.ts` |
| PowerSync 复制 | 将 PostgreSQL 最终状态增量下发到各设备，并管理本地变更队列和重连 | `prisma/migrations/20260925000200_sync_publication/migration.sql`、`../../../deploy/powersync/sync-config.yaml`、客户端 `core/sync/` |

RSA 的保留理由是独立服务验签，不是需要一套账号密码体系。API 短期访问令牌也复用当前 RS256 签名配置，但 API 每次请求仍会查对应设备 session，不能只凭未过期的签名继续访问。

## 认证和撤销边界

首次连接提交 `SYNC_SECRET`，服务器生成 256 位随机设备凭证，数据库只保存 SHA-256 摘要。该凭证通过既有接口字段 `refreshToken` 返回；它是稳定、不轮换的设备 session 凭证，不是 JWT。

设备 session 固定有效 **30 天**，作为程序内部约定，不提供部署配置。到期时间在连接时确定，刷新访问令牌不会延长；到期后需要重新连接。访问令牌最长 15 分钟，且不会超过 API 设备 session 的剩余期限。

客户端把并发刷新合并成一次请求，并使用会话代次防止旧请求在断开之后写回凭证。临时网络故障保留本地凭证及缓存身份，明确的认证失效才清除会话。稳定凭证使“刷新已成功但响应丢失”可以安全重试。

断开设备会删除该 session，之后 API 检查会拒绝它已签发的访问令牌。PowerSync 独立校验 JWT，不逐次查询设备 session；已经签发的 PowerSync JWT 在断开后仍可能有效，窗口最长 **15 分钟**。这不是 API 撤销失效，而是当前独立验签方案明确保留的短期窗口；撤销不会清除设备已经下载的本地数据。

## 上传协议和冲突语义

### 保留本机数据更换服务器

客户端的本机快照是用户明确选择的迁移来源；普通连接仍执行既有首次 PUT 合并规则，显式覆盖服务器使用独立协议：

- `POST /sync/connection-preview` 使用 `syncKey` 返回 `protocolVersion=1`、`snapshotVersion=3`、`syncSchemaVersion=12`、`ownerId`、同步白名单各表的 `counts`、回收站 `deletedCount` 及大小限制，不创建设备会话。进度步骤和笔记图片不作为独立回收站记录计数。
- `POST /sync/migrations` 接收 `syncKey`、持久 `migrationId`、预检 `expectedOwnerId`、`snapshotVersion=3` 与完整 `operations`。所有行必须为 PUT，包含白名单全部同步列（可空列显式传 null）；零行快照合法。未知列、重复同表身份和快照外的外键引用均拒绝。无笔记的旧请求仍可使用 v2；含笔记记录时必须使用 v3，并先暂存音频文件，详见[笔记原音说明](../src/notes/README.md)。已经提交的迁移通过 status 查询原回执，不改写旧摘要。
- 服务端在与初始化和创建连接共用的全局事务锁内先查询迁移回执，再锁定 expected owner，与普通上传串行。删除 owner 级联清理业务数据、设备会话、普通同步回执、墓碑及日签别名；新 owner 下导入快照并执行既有派生协调，关系最终验证通过后提交独立迁移回执。
- `sync_migration_receipts` 不关联 owner、不进入 PowerSync publication。原请求摘要包含 expected owner、快照版本及按现有 canonicalize 规范化的操作；同迁移 ID 同摘要重试返回原结果，不再覆盖成功后的新编辑。不同内容拒绝。已被后续重建替代的回执返回 `superseded`。
- `POST /sync/migrations/status` 使用同步密钥和迁移 ID 查询 `committed`、`superseded` 或 `notFound`；notFound 只说明当前不存在回执，不能证明网络中的原请求永远不会提交。
- `POST /auth/connect` 可携带 `expectedOwnerId`，事务内核对再创建设备会话。覆盖成功后客户端使用新 owner 建立独立候选会话并重新下载；不能复用旧队列、clientId 和复制检查点。普通上传加锁后发现 owner 已删除返回 `SYNC_OWNER_CHANGED`。

上限为 100000 条操作、32 MB JSON 请求、60 秒数据库事务。超限预检失败或导入错误不提交 owner 变更，也不保存成功回执。数据库最终约束与派生状态协调仍可能拒绝输入，拒绝时整个替换回滚。当前不支持分片大快照。

迁移不清空 PowerSync storage 或复制槽；通过 CDC 传递业务表变化，新 owner 隔离新旧下行流。旧 API session 立即失效；旧 PowerSync JWT 仍有既有最多 15 分钟窗口，只能读取旧 owner 流，不能读取新 owner 数据。客户端应等待上传完成（首次合并）、请求检查点并等待同步完成、再次确认候选 session 归属后激活本地候选库。服务端导入可能补齐旧事件历史或重算派生时间，因此请求摘要是幂等证据，不是最终业务数据逐字相等的承诺。

一次请求包含 `clientId`、`transactionId` 和有序 `operations`：

- `clientId` 对应一份本地数据库的生命周期，保存于本地同步元数据；清空数据库后重新生成。
- `transactionId` 使用 PowerSync 原始本地事务编号。同一事务重试时，身份及操作内容保持不变。
- 上传使用 `getNextCrudTransaction()`，完整保留事务边界。
- 当前整事务限制为 100000 条操作及 32 MB。超过限制会明确失败，不通过拆分牺牲原子性。

服务器先校验表和列白名单，再取得当前 owner 的行锁。在同一 PostgreSQL 事务中检查回执、依序写业务数据、协调派生状态并保存回执。外键延迟到事务结束检查，使初始导入中的父子记录顺序不会造成中途失败。

回执键为 `(user_id, client_id, transaction_id)`。同身份、同内容的重试直接返回旧结果；同身份却换成不同操作内容返回冲突，不会第二次写入。回执记录的是提交结果，不承担业务历史展示功能。

下表描述普通同步行的基本语义。MCP、应用内助手及后台重复任务修改的受保护记录还需要字段前值和关联闭包检查；冲突保留整笔事务候选，由用户明确处理，详见[跨端基线保护](../src/mcp/README.md#跨端基线保护)。笔记正文和标签分别使用修订候选与差量合并。

| 操作 | 当前语义 | 不能据此假定的行为 |
| --- | --- | --- |
| `PUT` | 仅在身份不存在时创建；已经存在则忽略，保留首个实体 | 重试或另一端离线生成同一实体不会覆盖既有编辑 |
| `PATCH` | 对明确携带的字段按服务器到达顺序更新 | 不按设备 `updated_at` 排序，也不承诺自动保留同字段的并发编辑 |
| `DELETE` | 记录永久删除墓碑并删除记录；级联删除也写墓碑 | 后来的旧 `PUT` 不能重新创建被永久删除的身份 |

若 `PATCH` 的目标不存在且没有适用的删除墓碑，服务器返回 `SYNC_RECORD_MISSING`，不能把更新零行当作成功。引用已永久删除父实体的迟到写入按删除优先处理，现存子行也会实际删除并记录墓碑，不能留下永久无法编辑的行。每日名言槽位使用下文的可空引用例外。软删除仍使用业务表的 `deleted_at`，与不可复活的永久删除墓碑区分；回收站恢复仅针对软删除。

按 owner 串行提交会降低同一 owner 的并行写吞吐，但本项目只有个人多设备写入，换来的事务重放判定及派生状态一致性更有价值。当前不是为大量独立用户并行写入设计的服务。

首次把尚未绑定服务器的本地数据库接入同步时，客户端在一个事务中将历史待上传操作折叠为当前结构化数据的完整 PUT，并保存初始上传标记。不能把完整快照追加到旧队列末尾，否则旧字段和悬空引用会先阻塞上传；失败时旧队列与标记一起回滚。历史队列中的已下线列由上传连接器按明确清单移除，仅含已下线列的 PATCH 安全跳过；有效字段、操作顺序、事务身份和未知字段校验仍保留。已绑定 owner 的数据库不会反复导入；连接到另一个 owner 会明确拒绝，不能把旧队列悄悄发到另一套服务器。

## 同一业务实体与派生状态

为兼容同一天已有不同随机 ID 的每日选择，服务端按 `(user_id, day_key)` 保留先存在的槽位，并在 `daily_quote_selection_aliases` 中保存旧 ID 到该槽位的映射。PUT 不覆盖已有选择，后续 PATCH/DELETE 按映射操作；日期不可改变。日签 DELETE 表示清空引用，不删除日历槽位。映射仅服务端使用且由复合外键隔离归属，不进入 PowerSync 发布。

随机 UUID 适用于真正的新记录，不能解决“两个设备自动生成了同一个业务实体”。客户端为以下记录生成 UUIDv5：每日名言选择、内置名言、同名分类、同日期重复待办及其子任务、同会员同账期的自动续费账单、事件初始完成历史。

统一 URL 命名空间使用 `https://omni-butler.local/<kind>/<编码后的业务键>`，完整规则见客户端 `core/database/app_database.dart` 的 `stableBusinessId`。同名分类软删除后重建优先恢复原身份；原身份已因重命名被占用时，用确定性后继身份避免覆盖原记录。人工付款仍生成独立随机身份，不能因金额、日期相同而被误去重。

服务器在上传事务结尾协调跨记录关系：

- 事件 `last_completed_at` 从未删除、未撤销的完成历史取最大值。客户端编辑器的初始完成时间也进入 `source='initial'` 历史；旧本地记录首次导入时，在没有任何历史的情况下补初始历史。
- 待办只允许主任务及直属子任务两层，拒绝自引用、循环和更深层级。已删除父任务后来收到的有效孩子继承父任务删除时间，使其进入同一恢复语义。
- 普通父任务须手动完成，全部有效子任务完成后仍保持待办；同步保留父任务自身的手动完成状态和确认时间。存在未完成的有效子任务时撤销父任务完成；客户端手动完成或重新打开父任务时，同一事务级联有效子任务。没有有效子任务时保留父任务自身的手动状态。
- 自动续费通过“会员 + 账期起点”推导的 UUID 识别，不依赖备注文本。重复账单 `PUT` 不再次创建；相关会员日期不能被旧设备回退。人工编辑保持其明确修改意图。

每日选择是持续存在的日历槽位，`quote_id` 允许为空。软删或永久删除名言只清空选择引用，之后重新选择仍修改同一槽位，不把当天身份写成永久删除墓碑。复合外键通过 SQL 迁移实现 `ON DELETE SET NULL (quote_id)`，保留非空 `user_id`；Prisma 目前不能表达该列子集，后续生成迁移时必须保留此定制约束。迟到的已删除名言引用同样归一为空；所有名言都不可用时首页显示空状态，不重新生成已永久删除的内置名言。

这里保留的是有事实来源的派生字段。它们可以用于现有界面和查询，但最终值必须来自服务器看到的完整记录集合，不能只信任某个设备的局部快照。

## 认证与图片同步边界

服务不提供注册、邮箱登录或角色切换；`sync_owners` 仅保存内部归属身份。设备凭证使用高熵随机密钥，数据库保存其 SHA-256 摘要。

默认 `IMAGE_SYNC_ENABLED=false` 时，物品、会员及笔记图片不上传服务器。设为 `true` 并重建 API 后启用图片接口；开关不控制 MinIO 启停。Compose 始终启动私有 MinIO，并持久保存内部凭证与对象，供图片、笔记原音及助手附件共用。Compose 固定存储连接及桶配置，客户端通过 API 传输文件，不直接访问 MinIO。笔记原音不受图片开关影响，助手附件由 `ASSISTANT_ATTACHMENTS_ENABLED` 独立控制。

### 可选图片同步协议

- 共用图片接口支持 `inventoryImage`、`membershipImage` 和 `noteImage`。笔记每张图片以 `note_images` 子记录 ID 作为 `businessId`；该表元数据经 PowerSync 同步，文件仍通过图片接口传输。首页背景和缓存路径不进入同步。
- 所有图片接口位于 `/omni-butler/api/v1/images`，使用现有设备会话鉴权。`GET /capabilities` 返回 `enabled`、`maxBytes=20971520` 及三种 `supportedBusinessTypes`；关闭时其余图片接口返回 `IMAGE_SYNC_DISABLED`，已有对象和数据库记录继续保留。
- `GET /images` 返回当前 owner 的完整 `items` 清单。每条含 `businessType/businessId/attachmentId/revision/sha256/mimeType/sizeBytes`。移除后的 `attachmentId` 和文件属性为 null，仍保留新 revision，防止旧设备历史补传复活图片。
- `PUT /images/:businessType/:businessId` 接收 multipart `file` 与 `operationId/attachmentId/expectedRevision/onlyIfMissing/sha256` 五个字段。空 `expectedRevision` 表示从未设置过图片；历史补传设置 `onlyIfMissing=true`，任何服务端标记均优先。显式修改必须匹配 revision，冲突返回 `409 IMAGE_CONFLICT`。
- `DELETE` 同一路径接收 `operationId` 和可空 `expectedRevision`，产生持久移除标记。上传与移除均返回 `{status: applied|unchanged, image}`。同 operationId、同内容返回原回执；不同内容返回 `IMAGE_OPERATION_REUSED`。旧回执只返回历史结果，不再写库。
- `GET /images/:businessType/:businessId/file?revision=...` 只读取当前版本，使用真实 MIME 和私有禁止缓存响应。业务尚未上传时图片写入返回 `404 IMAGE_RECORD_NOT_FOUND`，客户端等待业务同步后重试。

文件先校验 20 MB 大小、SHA-256、真实 PNG/JPEG/WebP/GIF 内容及 4000 万像素限制，再存入私有桶 `omni-butler-images`。每次网络尝试使用独立不可变对象键。对象写入成功后，短 PostgreSQL 事务锁定 owner、有效设备会话和业务记录，复核版本并原子保存图片关联与幂等回执；网络不在业务事务内执行。owner 被替换或会话已撤销的迟到上传不能写入新数据源。

`business_images` 和 `image_operation_receipts` 随 owner 级联清理。独立的 `image_object_garbage` 不随 owner 删除：暂存对象在上传前登记为 24 小时后可回收，成功引用时删除任务；换图、永久删除业务和 owner 替换通过 PostgreSQL 触发器产生 1 小时后的回收任务。软删除继续保留图片。服务每分钟最多处理 20 条回收记录，失败延后 5 分钟重试，删除前再次检查业务引用。存储响应丢失、进程崩溃或数据库回滚不会造成被引用对象误删。

图片真实集成测试位于 `test/images.integration.spec.ts`，必须显式设置 `OMNI_IMAGE_TEST=true` 及隔离库 `OMNI_IMAGE_TEST_DATABASE_URL=postgresql://...@127.0.0.1:35539/omni_images_integration`；只接受空测试 schema，并连接 `omni-image-test-minio-1` 的 loopback 测试端口。默认跳过外部测试不代表验收通过。

服务启动初始化随机内部 owner，PowerSync publication 随数据库迁移创建且只发布业务表。RSA 密钥首次启动自动生成并复用持久化卷；本地开发使用 `.local/keys`。明确需要自备密钥时可成对提供环境变量。

## 验证方式

关键场景包括事务原子性、丢响应重放、永久删除墓碑、跨 owner 隔离、派生状态协调、稳定业务身份合并、凭证刷新及撤销。真实同步链路还应检查离线重启恢复、超过 200 条的完整事务、PowerSync 下行、旧日签 ID 归并和两个独立本地数据库的最终状态。对应入口为 `test/sync.integration.spec.ts`、客户端 `test/sync_upload_protocol_test.dart`、`test/powersync_runtime_test.dart` 和 `test/powersync_server_e2e_test.dart`。

可重复执行的仓库检查：

```powershell
# 在 apps/server 执行；生成客户端只需占位连接串，不连接数据库。
$env:DATABASE_URL = "postgresql://omni_generate:placeholder@127.0.0.1:5432/omni_generate?schema=public"
npm run prisma:generate
npm test
npm run build
npm run lint -- --no-fix
```

```powershell
# 在 apps/client 执行。
flutter analyze --no-pub
flutter test --no-pub test/business_sync_identity_test.dart test/database_migration_test.dart test/business_repositories_test.dart test/todo_repository_test.dart test/taxonomy_repository_test.dart
flutter test --no-pub test/auth_repository_test.dart test/powersync_runtime_test.dart test/sync_upload_protocol_test.dart
```

SQL 不变量必须在从当前迁移创建的隔离 PostgreSQL 中实际验证，不能只依赖 Prisma 类型检查或 mock。API、PowerSync 复制和两个真实本地数据库的完整链路使用 `test/powersync_server_e2e_test.dart`，显式开启 `OMNI_SYNC_E2E` 并指定隔离 API 地址及测试密钥；默认跳过该测试不算通过。容器健康检查成功也不能替代数据实际下发断言。

## 数据库迁移兼容边界

`20260925000000_sync_baseline` 是服务端空库基线；早于该基线的旧后端没有原地升级路径。已经采用该基线的部署应直接执行后续增量迁移，无需清空数据。数据库升级前备份 PostgreSQL、对象存储和密钥，按[部署说明](../../../deploy/README.md)执行。

如需重建专用测试环境，应先核对 Compose 项目名、数据库连接目标、卷名和客户端数据库路径。客户端需同时清理旧上传队列、owner 绑定、`clientId` 和复制检查点；只清业务表不能完成重置。新 owner 会拒绝旧客户端绑定，避免把旧队列发往新服务。不要将这一步骤用于日常部署升级或未经确认的真实个人数据。

客户端本地迁移用于恢复历史备份和维护本地库，不代表旧后端协议、旧凭证或旧复制检查点可以与新服务混用。
