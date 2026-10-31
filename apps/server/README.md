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

数据库升级应执行仓库现有的增量迁移并保留数据。早于 `20260925000000_sync_baseline` 的旧基线没有原地升级路径；这类部署的兼容边界见[同步设计说明](docs/sync-design.md#数据库迁移兼容边界)。

笔记标签颜色已退休：`20261016010000_retire_note_tag_colors` 仅清空 `module=notes AND kind=tag` 的 `color_value`（含软删除记录），并添加数据库 CHECK 约束，防止再次写入。共享颜色列保留，物品、时间与会员模块的颜色不受影响。旧笔记标签 PUT、PATCH 和换服快照在执行副本上归一为 `null`，不修改原始幂等负载。升级时先备份并执行增量迁移，再更新 API、PowerSync 规则和全部客户端；同步版本以本文“同步协议与验证”为准。

## 笔记记录时间与置顶升级

`20261019000000_note_record_time` 增加记录秒数和设定偏移；`20261019010000_note_pinning` 增加 `note_entries.is_pinned BOOLEAN NOT NULL DEFAULT false`。置顶只修改元数据，不新增正文版本；旧正文 PATCH 缺失 `is_pinned` 时保留已有状态，显式状态必须为 JSON boolean。两端组内按记录日期时间倒序，置顶组排在普通组之前。

先完整备份 PostgreSQL、图片/原音及密钥，再执行增量迁移、发布 API 与 `deploy/powersync/sync-config.yaml`，最后升级全部客户端。换服 wire `snapshotVersion=3`；旧备份缺失置顶字段时按未置顶恢复。客户端当前版本见[客户端说明](../client/README.md)。

## 大模型设置与笔记 AI 整理

整理提示词要求清理无意义的填充词、卡顿、结巴、重复起句和口头自我修正，允许在保留原意的前提下调整语序、整合碎句和连贯分段，输出通顺的文章或笔记。版本 3 在提示词中注入笔记稳定记录时间（精确到分钟并携带 UTC 偏移），要求第一行为无 Markdown 前缀的纯文本标题、空一行后再输出完整正文；只有 ASR 原文明确将内容称为“日报”时才使用 `日报 - YYYY年M月D日` 标题，一般当日工作记录不推测为日报。事实细节、否定、条件和不确定性仍须完整保留，不机械删除有意义的“这个、然后”等词，不扩写事实或压缩成摘要。提示词变更只影响之后执行的整理与显式重试，不自动重跑已有结果。

执行增量迁移 `20261019020000_ai_note_polish` 后，在客户端“设置 → AI 设置”管理多套智谱、DeepSeek或自定义 Responses API 配置。没有模型服务时新增的首个配置自动设为当前使用，后续新增不切换已有选择；“笔记 AI 整理”由用户直接切换开关，保存成功后生效。API Base URL 和模型可修改；测试连接点击后直接发送固定短文本，不保存草稿配置，可能产生少量模型费用。

笔记整理与 AI 配置连接测试使用非流式 Responses API：向 `{baseUrl}/responses` 发送 `model`、`instructions`、`input`、`max_output_tokens`、`stream:false` 和 `store:false`，不回退 Chat Completions。所有供应商按配置的 `thinkingEnabled` 发送 `reasoning.effort=high` 或 `none`，默认关闭思考。测试连接上限为关闭思考时 256 tokens、开启时 2048 tokens，整理上限 12000 tokens；仅接受完整成功响应，并从助手消息的 `output_text` 内容块提取正文，智谱同时接受官方定义的单文本对象。失败、拒绝和截断保留原始转写，不自动重试可能计费的调用。

智谱预设基址为 `https://open.bigmodel.cn/api/v1`、模型 `glm-5.3`；DeepSeek 为 `https://api.deepseek.com`、模型 `deepseek-flash`；自定义入口需填写支持 Responses 的地址和模型。基址或完整 `/responses` 地址均可，保留自定义路径前缀并只拼接一次接口后缀；`/chat/completions` 地址明确拒绝。协议依据：[OpenAI迁移规范](https://developers.openai.com/api/docs/guides/migrate-to-responses)、[智谱Response API](https://docs.bigmodel.cn/cn/guide/develop/responses/introduction)、[DeepSeek Responses API](https://api-docs.deepseek.com/guides/responses_api/)。

供应商拒绝配置的思考模式时，测试连接和整理任务显示明确原因（`AI_REASONING_UNSUPPORTED`），保留现有参数，不自动切换思考强度或重试；供应商原始错误正文不直接透传，以免泄漏密钥。

AI 域名通过 DNS over HTTPS 独立解析，不依赖宿主机或 Docker 的系统 DNS。`open.bigmodel.cn` 固定使用 AliDNS `https://dns.alidns.com/resolve`（引导 IP `223.5.5.5`），其他域名使用 Cloudflare `https://cloudflare-dns.com/dns-query`（引导 IP `1.1.1.1`），均保持端点域名的 TLS 证书验证。A/AAAA 查询共用 5 秒总时限，单响应上限 64KiB；解析失败不回退系统 DNS，也不发送模型请求。服务器需能访问相应 DoH 端点；解析器只接收模型域名，不接收 API Key、模型请求路径或笔记正文。实现见 `src/ai/ai-dns.ts`。

模型服务仍必须使用公网 HTTPS；DoH 返回的全部地址继续检查内网与保留网段，模型请求固定使用通过校验的 IP、校验原域名证书且禁止重定向。IP 字面量仍按原规则校验。更新部署与模型配置后，可在客户端执行测试连接核对供应商兼容性。

API Key 只在后端以 AES-256-GCM 加密保存。首次保存模型 Key 时，独立主密钥 `ai-encryption-key-v1` 自动创建在 `JWT_KEYS_DIR`（Compose `/app/keys`，本机默认 `.local/keys`）；必须与 PostgreSQL 一起备份 `api-keys` 卷。密钥损坏或丢失时明确报错，不静默生成替代密钥解读既有配置。配置响应只返回已配置状态与掩码；明文 Key 不进入客户端偏好、PowerSync 或业务快照。

`GET /ai/settings` 返回总修订号、配置列表、预设、活动配置及开关；`PUT /ai/settings`、`POST /ai/profiles`、`PUT/DELETE /ai/profiles/:id` 使用修订号检测并发；`POST /ai/test` 测试当前草稿。所有接口相对固定 API 根路径并沿用设备 JWT。

新 ASR 任务固定当时的整理开关、模型及加密凭据快照。ASR 原文保存后排队整理，不追溯历史；`GET /notes/audio/:segmentId/polish?recognitionId=...` 读取持久状态，`POST /notes/audio/:segmentId/polish` 携带 `{operationId,recognitionId}` 显式重试。同身份重放不重复计费，超时或进程崩溃后的未知提交不自动重发。关闭整理、撤回识别及删除原记录都阻止迟到采用；正式原文保持不变。

客户端按录音顺序采用成功结果，失败时保留并使用原文；重试只在精确正文版本和范围匹配时替换。人工修改后保留候选供明确追加；候选预览指纹变化时要求重新预览。未发布草稿不被后台覆盖。

服务器换服 wire `snapshotVersion=3`，同步版本要求见下文。AI 私有表不进入 PowerSync publication，下行查询无需新增模型配置或任务字段。正式部署仍需备份→数据库迁移/API及配套PowerSync→全部客户端，旧客户端必须升级。

## 助手会话界面接口

`GET /assistant/conversations?query=<文字>&cursor=<会话UUID>` 按最近活动时间及 UUID 倒序分页，每页最多 100 条。可选 `query` 去除首尾空格后最多 200 字符，大小写无关地匹配当前用户的会话标题或用户/助手消息正文；`%`、`_`、反斜杠均按普通文字匹配，不检索内部状态、摘要或结果卡 JSON。不同查询必须从第一页重新加载。正文检索使用带归属约束的参数化 `EXISTS`，同会话多次命中仍只有一项；任意子串搜索仍可能扫描本用户相关正文，不承诺全文索引性能。

会话返回 `isPinned`。`PATCH /assistant/conversations/:id` 接受 `title`、`isPinned` 中的一项或两项，仍兼容旧的仅标题更新；仅置顶时保留 `updatedAt`。删除沿用原接口及业务回执保留规则。输入框模型列表及全局助手默认选择沿用 `/assistant/settings`，不会改变笔记整理的活动配置。

消息返回可空 `elapsedMs`：助手回答按稳定 `answerMessageId` 聚合同归属运行的已结算处理时间，不包含用户等待确认时间；没有可靠历史关联或当前执行段尚未结算时为 `null`。运行视图及 SSE 包含 `answerMessageId`、`elapsedMs`、`timingPending`；worker 持有有效租约时 `timingPending=true`，客户端须继续订阅，并在结算后的 `run.updated` 到达时刷新消息用时。`message.completed` 只确认正文，不代表计时已经结算。等待确认状态仍在结算时，确认接口返回可重试的 `409 ASSISTANT_PROCESSING`，客户端应暂禁确认直至最终事件；取消仍可立即执行。取消、接管或进程中断沿用已结算值，不推测尚未落库的处理时间；过期租约不使界面永久等待。

发布前执行 `20261023020000_assistant_desktop` 迁移：新增会话置顶字段和运行回答身份，并从合法旧状态回填；已被遗忘清理的历史保持无时长。上述字段属于助手私有表，不改变 PowerSync 或客户端业务 SQLite 版本。

## 设备连接接口

- `POST /omni-butler/api/v1/auth/connect`：提交 `syncKey`，建立设备会话。
- `POST /omni-butler/api/v1/auth/refresh`：使用稳定设备凭证换取新访问令牌；不轮换凭证、不延长固定会话期限。
- `POST /omni-butler/api/v1/auth/disconnect`：删除当前设备会话，后续 API 请求即失效；已签发的 PowerSync JWT 最多仍有效 15 分钟。
- `POST /omni-butler/api/v1/auth/powersync-token`：获取短期 PowerSync JWT。

## 同步协议与验证

`POST /omni-butler/api/v1/sync/operations` 接收 `{clientId, transactionId, operations}`。事务重试必须保留身份和内容；每个本地事务整体提交，最大 100000 条、32 MB。PUT 只创建，PATCH 修改已有记录，DELETE 保留永久删除墓碑。缺失记录 PATCH 返回 409，不能假确认成功。

当前同步结构为 `syncSchemaVersion=12`。增量上传、全量替换、PowerSync 凭证以及识别提交/结果查询均要求 `X-Omni-Sync-Schema: 12`，版本不兼容返回 `409 SYNC_SCHEMA_MISMATCH`；客户端必须保留本地数据及待上传事务并停止同步。预检、连接、刷新、会话与凭证响应包含当前版本。发布时先升级数据库、API 与 PowerSync 规则，再升级各客户端；增量迁移保留已有数据，无需重置数据库。识别撤回继续允许旧设备送达，避免因升级阻止停止付费任务。

标签图标使用可空 `taxonomy_entries.icon_emoji` 文本列，完整保存组合 emoji，`null` 表示默认 `#`。PATCH 缺失该列时保留已有图标，显式 `null` 才移除；名称、置顶和排序的独立更新不会覆盖图标。升级时先备份，再执行 `npm run prisma:migrate:deploy` 应用 `20261016000000_note_tag_icon_emoji`，更新 API 与 `deploy/powersync/sync-config.yaml` 的下行查询，最后升级参与同步的所有客户端。不满足当前同步版本要求的客户端会被拒绝写入和下行凭证，升级期间允许客户端保留本地离线操作。

客户端恢复缺失图标的历史快照时为标签补 `icon_emoji: null`。换服网络协议使用 `snapshotVersion=3`（无笔记旧请求仍支持 v2），完整标签行必须包含 `icon_emoji`；本地备份格式与换服协议版本独立。部署后在隔离环境验证一台设备设置组合 emoji，另一台设备接收、改名及清空，确认两个方向均生效后再推广客户端。

进度任务使用 `todo_items.task_type=progress` 和独立 `todo_progress_steps` 表，步骤只能属于同 owner 的进度根任务。满进度不自动完成；事务最后仅撤销不再满足满进度条件的已确认任务。父任务软删除保留步骤自身删除标记，恢复不会复活独立删除的步骤；永久删除级联步骤并记录墓碑。完整导入步骤之后再协调，保留合法的手动完成确认。

笔记使用 `note_entries`、`note_versions`、`note_audio_segments`、`note_images` 同步表，正文并发版本保留候选，原始录音通过独立的私有文件接口传输，生产原音及迁移暂存统一保存到 MinIO 私有桶 `omni-butler-note-audio`，图片开关不影响音频。语音厂商密钥只在后端，腾讯文件识别适配器与领域任务解耦。提交响应丢失时保留 `submissionUnknown`，绝不自动重复提交计费任务；只有查询已知任务允许自动网络重试。完整迁移必须先暂存真实原音，再在快照 v3 同一事务验证并接管；回收站绑定正文、原音和结果一起保留、恢复及永久清理。接口、环境变量、备份与故障语义见[笔记原音说明](src/notes/README.md)。

- `npm test`：单元测试，未配置隔离数据库时集成套件跳过。
- 服务端 CI 运行 `npm test`；未配置隔离数据库和对象存储时，相应集成测试会跳过。
- `npm run test:integration`：先将 `OMNI_TEST_DATABASE_URL` 指向独立空库（库名以 `_test` 或 `_integration` 结尾），执行 `sync.integration.spec.ts` 的真实 PostgreSQL 回归；测试会创建并清理该库的测试表，其他集成套件需按各自的专用环境变量运行。
- Flutter 真实双设备测试见 `apps/client/test/powersync_server_e2e_test.dart`。

完整 Docker 部署步骤见[部署说明](../../deploy/README.md)；同步边界、冲突语义和验证方式见 [同步设计说明](docs/sync-design.md)。服务器启用 `IMAGE_SYNC_ENABLED=true` 后，物品、会员及笔记图片通过共用的认证图片 API 同步到私有 MinIO；首页横幅仍只保存在客户端本机。Compose 中 MinIO 常驻，图片开关不影响笔记原音或独立的助手附件能力。
