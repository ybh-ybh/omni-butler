# 个人多设备同步设计

本文说明当前测试阶段的同步边界、代码取舍和验证要求。目标是让同一个人在多台设备上离线修改结构化数据，再可靠地合并到同一个自托管服务。账号注册、多人权限、图片云存储不属于当前目标。

## 从问题确定需要保存的状态

设备离线时，服务器无法阻止本地修改；网络恢复时，请求可能重复、乱序或丢失响应。因此，服务器至少需要区分以下四件事：数据属于哪个部署、哪台设备有权访问、收到的是新事务还是旧事务重试、记录是尚未上传还是已经永久删除。

这分别对应 `SyncOwner`、`DeviceSession`、`SyncReceipt` 和 `SyncTombstone`。它们解决不同的问题，不能用一个“已同步”标记替代。业务表继续使用 `user_id` 作为归属外键，只是其目标已经变为内部 `sync_owners`，不再表示可登录账号。

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

首次连接提交 `SYNC_SECRET`，服务器生成 256 位随机设备凭证，数据库只保存 SHA-256 摘要。该凭证通过既有接口字段 `refreshToken` 返回；它现在是稳定、不轮换的设备 session 凭证，不是 JWT，也不再指向下一枚刷新令牌。

设备 session 默认固定有效 **30 天**，由 `REFRESH_TOKEN_TTL_SECONDS` 配置。到期时间在连接时确定，刷新访问令牌不会延长；到期后需要重新连接。访问令牌最长 15 分钟，且不会超过 API 设备 session 的剩余期限。

客户端把并发刷新合并成一次请求，并使用会话代次防止旧请求在断开之后写回凭证。临时网络故障保留本地凭证及缓存身份，明确的认证失效才清除会话。稳定凭证使“刷新已成功但响应丢失”可以安全重试。

断开设备会删除该 session，之后 API 检查会拒绝它已签发的访问令牌。PowerSync 独立校验 JWT，不逐次查询设备 session；已经签发的 PowerSync JWT 在断开后仍可能有效，窗口最长 **15 分钟**。这不是 API 撤销失效，而是当前独立验签方案明确保留的短期窗口；撤销不会清除设备已经下载的本地数据。

## 上传协议和冲突语义

一次请求包含 `clientId`、`transactionId` 和有序 `operations`：

- `clientId` 对应一份本地数据库的生命周期，保存于本地同步元数据；清空数据库后重新生成。
- `transactionId` 使用 PowerSync 原始本地事务编号。同一事务重试时，身份及操作内容保持不变。
- 上传使用 `getNextCrudTransaction()`，完整保留事务边界，不再按 200 条切断业务操作。
- 当前整事务限制为 100000 条操作及 32 MB。超过限制会明确失败，不通过拆分牺牲原子性。

服务器先校验表和列白名单，再取得当前 owner 的行锁。在同一 PostgreSQL 事务中检查回执、依序写业务数据、协调派生状态并保存回执。外键延迟到事务结束检查，使初始导入中的父子记录顺序不会造成中途失败。

回执键为 `(user_id, client_id, transaction_id)`。同身份、同内容的重试直接返回旧结果；同身份却换成不同操作内容返回冲突，不会第二次写入。回执记录的是提交结果，不承担业务历史展示功能。

| 操作 | 当前语义 | 不能据此假定的行为 |
| --- | --- | --- |
| `PUT` | 仅在身份不存在时创建；已经存在则忽略，保留首个实体 | 重试或另一端离线生成同一实体不会覆盖既有编辑 |
| `PATCH` | 对明确携带的字段按服务器到达顺序更新 | 不按设备 `updated_at` 排序，也不承诺自动保留同字段的并发编辑 |
| `DELETE` | 记录永久删除墓碑并删除记录；级联删除也写墓碑 | 后来的旧 `PUT` 不能重新创建被永久删除的身份 |

若 `PATCH` 的目标不存在且没有适用的删除墓碑，服务器返回 `SYNC_RECORD_MISSING`，不能把更新零行当作成功。引用已永久删除父实体的迟到写入按删除优先处理，现存子行也会实际删除并记录墓碑，不能留下永久无法编辑的行。每日名言槽位使用下文的可空引用例外。软删除仍使用业务表的 `deleted_at`，与不可复活的永久删除墓碑区分；回收站恢复仅针对软删除。

按 owner 串行提交会降低同一 owner 的并行写吞吐，但本项目只有个人多设备写入，换来的事务重放判定及派生状态一致性更有价值。当前不是为大量独立用户并行写入设计的服务。

首次把尚未绑定服务器的本地数据库接入同步时，客户端在一个事务中将历史待上传操作折叠为当前结构化数据的完整 PUT，并保存初始上传标记。不能把完整快照追加到旧队列末尾，否则旧字段和悬空引用会先阻塞上传；失败时旧队列与标记一起回滚。历史队列中的已下线列由上传连接器按明确清单移除，仅含已下线列的 PATCH 安全跳过；有效字段、操作顺序、事务身份和未知字段校验仍保留。已绑定 owner 的数据库不会反复导入；连接到另一个 owner 会明确拒绝，不能把旧队列悄悄发到另一套服务器。

## 同一业务实体与派生状态

历史客户端可能已经用不同随机 ID 创建同一天的每日选择。仅为新记录采用 UUIDv5 无法合并这些旧数据：服务端按 `(user_id, day_key)` 保留先存在的槽位，并在 `daily_quote_selection_aliases` 中保存旧 ID 到该槽位的映射。PUT 不覆盖已有选择，后续 PATCH/DELETE 按映射操作；日期不可改变。日签 DELETE 表示清空引用，不删除日历槽位。映射仅服务端使用且由复合外键隔离归属，不进入 PowerSync 发布。第 4 份增量迁移添加该映射，已有新基线部署无需清空数据库。

随机 UUID 适用于真正的新记录，不能解决“两个设备自动生成了同一个业务实体”。客户端为以下记录生成 UUIDv5：每日名言选择、内置名言、同名分类、同日期重复待办及其子任务、同会员同账期的自动续费账单、事件初始完成历史。

统一 URL 命名空间使用 `https://omni-butler.local/<kind>/<编码后的业务键>`，完整规则见客户端 `core/database/app_database.dart` 的 `stableBusinessId`。同名分类软删除后重建优先恢复原身份；原身份已因重命名被占用时，用确定性后继身份避免覆盖原记录。人工付款仍生成独立随机身份，不能因金额、日期相同而被误去重。

服务器在上传事务结尾协调跨记录关系：

- 事件 `last_completed_at` 从未删除、未撤销的完成历史取最大值。客户端编辑器的初始完成时间也进入 `source='initial'` 历史；旧本地记录首次导入时，在没有任何历史的情况下补初始历史。
- 待办只允许主任务及直属子任务两层，拒绝自引用、循环和更深层级。已删除父任务后来收到的有效孩子继承父任务删除时间，使其进入同一恢复语义。
- 未删除父任务根据最终有效子任务集合计算完成状态。客户端重新打开父任务时，同一事务重新打开有效子任务，避免下次同步又被派生值标成完成。没有有效子任务时保留主任务自身的手工状态。
- 自动续费通过“会员 + 账期起点”推导的 UUID 识别，不依赖备注文本。重复账单 `PUT` 不再次创建；相关会员日期不能被旧设备回退。人工编辑保持其明确修改意图。

每日选择是持续存在的日历槽位，`quote_id` 允许为空。软删或永久删除名言只清空选择引用，之后重新选择仍修改同一槽位，不把当天身份写成永久删除墓碑。复合外键通过 SQL 迁移实现 `ON DELETE SET NULL (quote_id)`，保留非空 `user_id`；Prisma 目前不能表达该列子集，后续生成迁移时必须保留此定制约束。迟到的已删除名言引用同样归一为空；所有名言都不可用时首页显示空状态，不重新生成已永久删除的内置名言。

这里保留的是有事实来源的派生字段。它们可以用于现有界面和查询，但最终值必须来自服务器看到的完整记录集合，不能只信任某个设备的局部快照。

## 删除的设计负担及字段依据

当前没有注册、邮箱登录、账号角色切换。因此删去账号 `email`、`password_hash`、`role`、`token_version`，保留最小数据归属身份。刷新令牌轮换链、后继令牌关系和 Argon2 随之移除：当前凭证是随机高熵设备密钥，不是需要抗字典攻击的人类密码。

图片现在仅在本机使用，因此删除服务端 COS 模块及依赖、服务端 attachment/banner 表及图片关联字段。客户端的本地图片文件、attachment/banner 元数据和本地图片关联仍用于展示，继续保留；它们不进入同步白名单。这次没有承诺跨设备图片可见。

没有被调用的 seed 命令不再保留。服务启动只初始化随机内部 owner，PowerSync publication 随数据库迁移创建且只发布业务表，不再每次启动检查/创建全表发布。内部 owner 和设备 session 没有被读取的创建时间也已删除；会话仍保留真正用于授权的失效时间。

RSA 密钥首次启动自动生成并复用持久化卷；本地开发同样使用 `.local/keys` 自动管理，重复的手工生成脚本已删除。明确需要自备密钥时仍可成对提供环境变量。

以下六个业务字段已删除，其依据是当前业务没有读取或展示需求，而非仅因为某处搜索命中较少：

| 字段 | 删除依据与替代来源 |
| --- | --- |
| `daily_quote_selections.is_manual` | 选择结果由 `quote_id` 表达，当前没有按手动/自动标记分流的行为 |
| `taxonomy_entries.normalized_name` | 名称规范化可从 `name.trim().toLowerCase()` 推导，稳定业务身份直接使用推导值 |
| `taxonomy_entries.icon_code_point` | 没有实际图标展示消费者，仅默认写入和编辑透传 |
| `memberships.payment_method` | 当前没有支付方式的有效录入、展示或计算需求 |
| `memberships.is_favorite` | 当前没有依赖该标记的收藏展示和排序行为 |
| `membership_payments.billing_cycle` | 单笔账单的事实由金额、付款时间和有效期表达；自动续费周期来自会员自身 `billing_cycle` |

会员自身 `billing_cycle` 继续决定续费计算。时间记录的 `entry_date`、`start_minute`、`end_minute` 仍参与现有自然日切片、统计及展示；`started_at`、`ended_at` 表达绝对区间和进行中状态，两组字段当前均有消费者，未在本次顺手删除。

## 15 项审查问题与验证映射

下表编号对应 `output/sync-audit/后端多端同步审查.md`。最后一列列出各问题对应的验证场景，实际执行结果见下方“本轮验证结果”。客户端路径以 `apps/client/lib/` 为起点，服务端路径以 `apps/server/` 为起点。

| 编号及原问题 | 现实现文件 | 必须验证的场景 |
| --- | --- | --- |
| 1. ARGB 超出 int32 | `prisma/schema.prisma`、`prisma/migrations/20260925000100_sync_invariants/migration.sql` | 从空库执行迁移，上传 `0xFF477087` 等默认不透明颜色，确认持久化和下发值不变 |
| 2. 每日名言自然键冲突 | 客户端 `core/database/app_database.dart` | 两份独立数据库同日首次打开首页，生成同一选择身份；双端上传后各自队列可清空 |
| 3. 分类唯一约束漂移及同名冲突 | `prisma/schema.prisma`、新迁移基线；客户端 `core/taxonomy/taxonomy_repository.dart` | 两端生成默认分类、同名分类；删除后重建；重命名后再次使用旧名 |
| 4. 重试覆盖和永久删除复活 | `src/sync/sync.service.ts`、`src/sync/sync-sql.builder.ts`、墓碑迁移 | 提交后丢响应，再有另一端更新或删除，重放旧事务不能覆盖/复活；级联孩子删除也有墓碑 |
| 5. 刷新令牌分叉及撤销竞态 | `src/auth/auth.service.ts`、`src/auth/jwt.strategy.ts` | 同凭证并发刷新不创建后继；断开后所有该 session 的 API token 被拒绝，其他设备不受影响 |
| 6. 旧本地数据没有初始上传、PATCH 假成功 | 客户端 `core/sync/omni_sync_runtime.dart`；`src/sync/sync.service.ts` | 无队列旧库首次接入补 PUT；再次打开不重复导入；不存在记录 PATCH 返回明确冲突 |
| 7. 物品购买平台漏下发 | `../../../deploy/powersync/sync-config.yaml` | 设备 A 保存购买平台，设备 B 经真实复制读取相同值 |
| 8. 离线启动不恢复同步 | 客户端 `core/auth/auth_repository.dart`、`core/sync/sync_providers.dart` | 已登录设备离线重启，凭证保留；恢复网络后无需重开页面即可恢复同步 |
| 9. 200 条上限切断事务 | 客户端 `core/sync/omni_powersync_connector.dart`；`src/sync/dto/sync-batch.dto.ts` | 同一事务 201 条以上只发一个完整请求；后半段错误时整批回滚，队列不提前确认 |
| 10. 重复待办各端重复生成 | 客户端 `features/todos/data/todo_repository.dart` | 同系列、同日期双端生成相同主子身份，服务器只保留一棵树 |
| 11. 自动续费重复记账 | 客户端 `features/memberships/data/membership_repository.dart`；`src/sync/sync-consistency.ts` | 双端对同账期续费只产生一笔自动账单；迟到请求不回退日期；人工付款仍可独立记账 |
| 12. 事件汇总与完成历史矛盾 | 客户端 `features/events/data/event_repository.dart`；`src/sync/sync-consistency.ts` | 两端历史乱序上传后汇总取最大；编辑初始时间、撤销和删除历史后正确重算 |
| 13. 分别完成子任务后父状态不更新 | `src/sync/sync-consistency.ts` | 双端各完成不同孩子，最终父完成；重开孩子后父重开；空子集合保留手工状态 |
| 14. 父删除与新增孩子竞争 | `src/sync/sync-consistency.ts`、墓碑迁移 | 软删除父后迟到孩子进入相同删除组；永久删除后迟到孩子不复活；拒绝非法深层树 |
| 15. 刷新响应丢失及并发误清会话 | `src/auth/auth.service.ts`；客户端 `core/auth/auth_repository.dart` | 刷新响应丢失可重试；并发 401 共用刷新；临时网络错误不清凭证，断开期间旧请求不写回 |

可重复执行的仓库检查：

```powershell
# 在 apps/server 执行。
npm run prisma:generate
npm test
npm run build
npm run lint
```

```powershell
# 在 apps/client 执行。
flutter analyze
flutter test test/business_sync_identity_test.dart test/database_migration_test.dart test/business_repositories_test.dart test/todo_repository_test.dart test/taxonomy_repository_test.dart
flutter test test/auth_repository_test.dart test/powersync_runtime_test.dart test/sync_upload_protocol_test.dart
```

SQL 不变量必须在从当前迁移创建的隔离 PostgreSQL 中实际验证，不能只依赖 Prisma 类型检查或 mock。API、PowerSync 复制和两个真实本地数据库的完整链路使用 `test/powersync_server_e2e_test.dart`，显式开启 `OMNI_SYNC_E2E` 并指定隔离 API 地址及测试密钥；默认跳过该测试不算通过。容器健康检查成功也不能替代数据实际下发断言。

## 本轮验证结果（2026-09-25）

- 服务端 `npm test`：33 项单元测试通过；`npm run lint`、`npm run build` 通过。
- 真实 PostgreSQL 集成：18 项全部通过，使用空隔离库执行全部三份迁移，验证事务原子性、201 条事务、回执重放、墓碑、复合外键隔离、派生状态、自动续费和每日选择删除后重选。
- 最终 Docker 镜像从空卷启动成功；实际查询 publication 仅含 11 张业务表，daily 复合外键为 `ON DELETE SET NULL (quote_id) DEFERRABLE INITIALLY DEFERRED`。
- 真实 API 连接、8 个并发刷新、断开后的访问令牌和刷新凭证拒绝均通过。
- 最终真实双设备 E2E 通过：生产 runtime/connector、独立设备会话、201 条原始事务、提交后丢响应重试、checkpoint 完成、购买平台和 ARGB 下发、离线稳定身份合并。
- Flutter 全量静态分析通过。全量测试 162 项通过、1 项默认跳过的外部服务 E2E（已另行显式运行通过）、3 项既有界面测试失败：事件布局的“完成历史”断言，以及分类管理器的两个 Golden 像素差。未为通过测试而改写这些既有界面或截图基线。
- 本次验证仅创建、重置并清理 `omni-sync-fix-test` 隔离 Compose 项目及 `omni_sync_integration` 测试库，未清理其他部署或用户日常客户端数据。

## Android 历史日签兼容修复（2026-09-25）

真实 Android 队列中的旧随机日签 ID 与桌面端同一天的 ID 不同，触发服务端日期唯一约束，阻塞整个上传事务。新增第四份增量迁移保存旧 ID 到现有槽位的映射，后续 PATCH 和 DELETE 也能正确解析。已有前三份新基线迁移的部署可以直接升级，保留现有数据。

仅修复上传还不够：服务端下发规范 ID 时，本地旧 ID 仍占用同一天，默认 RawTable 按主键写入也会触发 SQLite 唯一约束。客户端每日选择采用专用下行 UPSERT，按主键或日期冲突归并到服务端 ID；保留 inferred schema 和原有上传触发器，旧 ID 的下行删除只按 ID 匹配。

- 服务端真实 PostgreSQL 集成扩展至 22 项，通过旧数据迁移保留、跨事务别名编辑、重放、所有者隔离及回滚验证；33 项单元测试、lint、build 通过。
- 隔离双设备 E2E 两项全部通过，覆盖原同步链路及同日旧随机 ID、离线 PATCH、下行归并、再次切换、队列清零和 checkpoint 完成。
- 客户端 SQLite/runtime 5 项测试及修改文件静态分析通过。
- 实际 `deploy` 保留数据升级成功，模拟器重新安装启动后原 16 条积压操作处理完成，队列为 0，checkpoint 成功。11 张同步表共 155 行的 ID 集合和数量与服务端一致，本机图片元数据逐行不变；备份及核对结果保存在 `output/android-sync-recovery/20260925-131259/`。

## 测试阶段基线和重置范围

旧服务端迁移已折叠为新空库基线及同步不变量迁移。此处重置要求仅针对尚未切换到前三份新基线迁移的旧版后端，不提供该旧版的数据原地升级路径。已经采用新基线的部署应直接执行后续增量迁移，无须清空数据。

测试切换需要停止本项目测试服务，清空**本项目专属**的服务端测试数据库和 PowerSync 测试复制状态，再清理参与验证的客户端测试数据及设备会话，重新初始化并连接。这里的客户端数据包括旧上传队列、旧 owner 绑定和旧 `clientId`，只清业务表不足以完成重置。

用户已经授权本轮测试数据重置，但授权范围不包含其他项目数据库、其他 Docker 项目的卷或未经确认的真实个人数据。重置前必须先核对 Compose 项目名、数据库连接目标、卷名和客户端数据库绝对路径；本说明不提供跨项目批量清理命令。新的随机 owner 会使未清理的旧客户端绑定明确报错，这是防止旧队列发往新服务的预期保护。

客户端本地迁移仍保留已有必要字段，用于正常本地使用和针对迁移行为的测试；这不代表旧后端协议、旧凭证、旧复制检查点可以与新服务混用。
