# 应用内助手

Windows/Android 使用设备 JWT 访问 `/omni-butler/api/v1/assistant`，独立于外部 MCP 连接。助手默认关闭、模型独立选择已有 AI 配置。公开 MCP 仍为 v3/65 工具，业务数据继续走 PowerSync。

## 编排与执行

`AssistantRunner → LangGraph StateGraph → Responses Function Calling → ActionExecutor → BusinessModule`。

- 只读工具可以循环执行，写工具先登记意图，完整任务结束后才真实预演。当前顶层请求没有明确业务写指令时不提供对应写工具；资料、检索和记忆不能扩大写范围。无法确定时澄清。
- 单个独立业务对象直接提交；两个及以上对象通过原生卡片确认。确认绑定任务、版本和预览摘要，修改方案使旧确认失效。
- `stage_changes` 可登记最多64步完整清单。每批最多8步/200条实际变化；超过8步的完整预演在保存点中全部回滚，确认后逐批执行。每批提交、幂等回执、进度和下一批基线在同一事务保存；外部修改导致停止。跨批不具备原子性。
- checkpoint 只保存图阶段指针；会话、确认、运行租约、模型请求和执行回执分别持久保存。任务来源不能从模型或客户端参数指定。
- `mcp_actions` 保留物理表和历史动作，新增 `source/source_id` 隔离助手与 MCP，持续使用 `protectedRecords`。删除聊天不删除这些业务回执或同步保护。
- 供应商请求 `stream:true/store:false`，完整终态及参数校验后才处理函数。模型请求发送前记录 attempt；不确定请求不自动重付费，成功响应优先复用。停止不撤销已保存业务。

## API

所有路径相对于 `/assistant`；请求体严格校验，归属来自 JWT。

| 路径 | 方法与行为 |
|---|---|
| `/settings` | GET / PUT；`revision,enabled,profileId,memoryReadEnabled,memoryWriteEnabled,timeZone` |
| `/test` | POST `{profileId}`；固定文本和 echo 工具两轮探测，不发送业务数据 |
| `/conversations` | GET `?cursor=` / POST `{title?}` |
| `/conversations/:id` | PATCH `{title}` / DELETE；仅删除聊天及派生状态 |
| `/conversations/:id/messages` | GET `?before=`；POST `{clientMessageId,content,timeZone?,selection?,reference?}` |
| `/runs/:id` | GET；只返回状态、公开计划与可操作能力 |
| `/runs/:id/events` | GET `?after=seq` SSE；`seq,type,runId,data` |
| `/runs/:id/stop` | POST；取消未提交动作，保留实际结果 |
| `/runs/:id/retry` | POST；显式新付费尝试，沿用原任务及业务身份 |
| `/runs/:id/takeover` | POST；同owner其他设备明确接管 |
| `/runs/:id/undo` | POST；单条新增10分钟内的软删除补偿，不支持批量通用撤销 |
| `/plans/:taskId` | GET；固定参数、前后变化和关联影响 |
| `/plans/:taskId/decision` | POST `{version,previewHash,decision:"confirm"或"cancel"}` |
| `/memories` | GET `?cursor=` / POST / DELETE清空 |
| `/memories/:id` | PATCH完整内容及revision / DELETE |
| `/entities/:module/:id` | GET；七模块精确服务器快照，未同步到本机也可查看 |

`selection` 仅能引用当前澄清卡片；`reference` 仅能引用本会话真实结果卡片，二者格式均为 `{id,module}`。未知 POST 结果按原 `clientMessageId` 核实，不生成新身份。

SSE事件包括 `message.delta`、`message.completed`、`plan.ready`、`run.updated`、`error`。事件与序号同事务保存，流最长一分钟后可带游标续接；断开流不会停止任务。客户端仍须逐事件核对服务器及认证代次。

## 上下文、记忆与限制

- 总输入按128KiB保守字节预算管理，先扣系统指令和工具定义；70%水位压缩旧资料。摘要是标明覆盖范围和省略的确定性摘录，不增加付费摘要请求。当前要求、完整工具组、对象引用、计划和实际回执独立保留。
- 显式“记住”才开放记忆写工具；管理页支持查看、编辑、停用、到期和清空。凭据类内容拒绝保存。记忆在 PostgreSQL 按结构及关键词检索，权限和删除过滤先行。
- 记忆变更推进版本，使关联摘要、源消息输入、旧运行状态和checkpoint失效；已发送到第三方的请求不能撤回数据。业务记录不会随删除聊天或记忆自动删除。
- 每轮最多8次工具调用/12次模型请求，累计执行120秒、单次模型60秒；等待确认不计时。未知计费响应只能显式重试。
- `ASSISTANT_CONTEXT_PROVIDERS` 是后续 Skills 的受控资料扩展点，当前默认无实现。扩展资料不改变工具权限、确认规则或运行身份。
- 仅处理服务器已接收的数据；本机写前建立同步检查点，未发布草稿不发送。只读来源卡最多20条，不能把引用数量解释为统计覆盖量。

## 持久化与上线

部署迁移 `20261023010000_assistant`，包含助手私有表及固定版本的 `assistant_graph` checkpoint schema。SQLite业务库、PowerSync协议、业务快照版本不因这些私有表递增。客户端使用单独助手缓存库，按服务器地址及owner分区；缓存不携带执行授权。

停止旧 API → 备份数据库及 `api-keys` 等全部现有持久卷 → 执行迁移 → 启动新 API → 更新客户端。服务端数据库备份包含聊天和记忆，客户端“迁移备份”不包含服务端助手数据；首版不导入跨服务器聊天授权。

**完整灾备恢复**必须先停 API，恢复数据库和密钥卷，再执行 `deploy/assistant-restore-safety.sql`，确认助手关闭、旧设备/MCP连接及未完成任务失效后启动。保留业务记录、聊天正文、记忆、历史回执和保护事实，重新连接设备及开启助手。仅恢复数据库不能被视为已安全恢复执行授权。

真实供应商流式工具能力、两台真实设备和真人自然语言效果需分别验收；测试模型网络替身、数据库集成、Widget测试及Release编译不能代替这些验收。
