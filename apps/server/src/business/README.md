# 可复用后端业务接口

七模块业务方法由 BusinessModule 注册并导出。Codex MCP 与应用内助手作为独立适配层调用同一组服务，提供七模块查询、统计及业务写入。MCP 按连接权限执行，单条直接提交、批量在 Codex 对话确认；助手使用设备 JWT 与应用内确认卡。业务同步及原音/图片传输使用各自入口。外部接入、权限和跨端基线保护见 [MCP README](../mcp/README.md)，应用内对话与 Function Calling 见[助手说明](../assistant/README.md)。

## 调用约定

本文件描述内部领域方法，不能把方法参数直接视为公开 MCP 协议。MCP v3 在适配层统一统计、回收站和恢复入口，单条业务工具自动完成预演与提交；批量使用 `prepare_batch → commit_action`。完整公开清单见 `spec/mcp-tools.json`，共 65 个工具，按连接权限进一步筛选。MCP 用稳定 `requestId` 定位原动作，再按动作身份和步骤序号派生领域 `operationId`；调用方重试必须复用请求身份。

- 每个方法的第一个参数为认证层提供的 AuthUser，第二个参数为普通 JSON 对象；get 的第二个参数直接为 UUID。
- AuthUser 只能由可信认证上下文提供。方法在数据库事务内再次核对设备会话、归属和到期时间；模型输入不能提供 userId、sub、sid 或任意数据库字段。
- 公开方法自行校验参数，不依赖 HTTP ValidationPipe。未知字段、错误类型、失效记录和越权引用会被拒绝。
- 写方法都带 operationId（UUID）。执行层为一次用户动作分配身份，网络重试保留身份；一次新的用户动作使用新身份。同身份不同动作/内容返回 BUSINESS_OPERATION_CONFLICT。
- 业务副作用及结果回执在同一事务提交，使用现有 owner 行锁与离线同步串行。成功回执重放返回原结果，不重新改动后来编辑或删除的记录；撤权后也不能读取旧回执。
- 日期时间结果统一为 ISO 字符串；金额以整数分值表示。普通标量字段缺省表示保留，允许清空的字段用 null；不是所有字段都允许 null。
- 普通删除方法为 trash，进入现有回收站。永久删除继续使用原流程；数据库触发器维护已发生永久删除的多态关联清理。

operationId 同时用于避免幂等字段更新的迟到重放覆盖后续编辑。普通元数据仍沿用原离线同步覆盖语义，不能把该回执视为全端版本保护。笔记正文继续使用独立修订基线。

## 查询和结果边界

list、history、payments、versions、ongoing 支持 limit（默认 50，最大 200）及 offset，返回 items、hasMore、nextOffset。offset 指当前稳定排序下的偏移，不提供跨多次请求的冻结快照承诺。

statistics 直接读取完整授权集合，不从分页列表推算总数。引用 ID 或正文材料最多返回 200 条，使用 sourcesTruncated/selectionsTruncated 明确截断；complete 表示统计覆盖完整的声明口径，不能把截断的材料当成完整事实明细。

范围使用 from/to（带时区 ISO 时间点），采用左闭右开区间，最长十年。时间列表窗口成对可选，不再接收无效的 timeZone/asOf；自然日统计仍需 timeZone（IANA 地区或 UTC）。只有时间、待办、会员和事件统计接受可选 asOf，用于进行中时长、完成/支付截止及状态计算；日签、笔记和物品统计不接收或回显该字段。DATE/笔记 dayKey 数据按指定地区的自然日起点归属窗口；月/周窗口应传实际当地日界。当前数据查询不重建历史库存或会员状态快照。

每个统计对象返回自己的口径。例如：

- 时间：完整相交区间裁剪后按秒统计，含分类和业务自然日；DST 日界按真实 23/25 小时处理。
- 待办：计划数量和完成数量分开，根任务/子任务/步骤分开。includesUnmaterializedRecurring=false 明确仅统计已保存实例。
- 物品：默认主物品，includeAccessories=true 才包含配件。购买金额是每条记录总额，不能再乘 quantity；有范围时按 purchaseDate 筛选，basis 明确区分购买事实与当前列表。
- 会员：支付日优先 validFrom，旧记录用 paidAt 的业务地区日期；父会员进入回收站后，其账目不计入支出。
- 事件：有效、未撤销完成历史计数，包含归档事件，排除回收站父事件。
- 笔记：按记录自然日统计正式篇数、记录天数及受限 Markdown 可见字素，不计本机草稿。
- 名言：读取已有日签和名言库数量，不初始化日签、不生成缺失日期。

## 七模块方法

### QuotesService

| 方法 | 输入和行为 |
|---|---|
| list | query、isEnabled、分页；搜索 content/source |
| get | UUID；有效名言详情 |
| create | operationId、content，选填 source、isEnabled |
| update | operationId、id，选填 content/source/isEnabled；未选择字段保持 |
| trash | operationId、id；软删除，保留日期槽位 |
| daily | day（YYYY-MM-DD）；已有选择，不存在时 quote=null |
| statistics | 范围；库数量、有效日签数量及有限材料 |

### TimeEntriesService

| 方法 | 输入和行为 |
|---|---|
| list | status=ongoing/finished/all（默认all）、分页，选填成对from/to；有窗口时返回相交记录 |
| get | UUID；详情 |
| ongoing | 内部兼容方法，委托list(status=ongoing)；MCP不再单独暴露 |
| start | operationId、timeZone，选填 startedAt/activity/categoryId/category/notes；省略 startedAt 表示首次执行时的现在 |
| create | operationId、timeZone、startedAt、endedAt、activity，选填 categoryId/category/notes |
| update | operationId、id、timeZone，选填 startedAt/endedAt/activity/categoryId/category/notes |
| finish | operationId、id、timeZone，选填 endedAt/activity/categoryId/category/notes；原记录须进行中，最终活动不能为空；省略 endedAt 表示现在 |
| trash | operationId、id |
| statistics | 范围；完整裁剪时长、分类与按日汇总 |

新建/普通编辑检查区间重叠与当前进行中记录。结束既有进行中记录保留原冲突收尾通路，允许用户逐条处理离线同步形成的多条进行中记录。

分类首选 `categoryId`：事务内检查同 owner、timeline 模块、category 类型、未删除且启用，然后将真实名称存入原 `category` 文本列；未新增关系或同步字段。`categoryId: null` 明确清空，省略分类参数保留已有分类。内部兼容 `category` 名称输入，但拒绝 UUID 字符串；两个字段不能同时提供。MCP 只公开 categoryId，先查询分类，在完整列表中唯一匹配名称，重名或缺失须澄清。预览、回执和统计使用真实名称，分类改名或失效仍会触发 MCP 既有基线保护。

### InventoryService

| 方法 | 输入和行为 |
|---|---|
| list | query、status、includeAccessories、parentItemId、分页；默认主物品，配件命中可返回父项 |
| get | UUID；详情、有效直属配件、规范分类位置身份 |
| create | operationId、name，选填物品字段、categoryIds/locationIds；名称和数量/金额/链接校验 |
| update | operationId、id 和所选字段；parentItemId=null 明确解除配件关系 |
| move | operationId、ids、destinationLocationId；返回 moved/followed/unchanged/missing 身份集合 |
| trash | operationId、id；本体及直属有效配件同批软删 |
| statistics | includeAccessories，选填完整范围；数量/金额及分类、位置、状态分布 |

物品字段包括 quantity、purchasePriceCents、purchaseDate、purchaseUrl、purchasePlatform、status、warrantyExpiration、tags（文字数组）、parentItemId、notes。分类/位置首选categoryIds/locationIds，与对应category/location文字互斥，空数组清空，缺省保留。旧文字和tags不能填写UUID；旧名称唯一匹配同归属有效分类/位置时同步关联，重名拒绝，无匹配则保留兼容名称并解除该种类旧关联，不新建分类。其他种类关系保持。配件只允许两层，不能自引用、循环或把带配件主项挂到另一主项下。

上述文字分类、位置和文字 tags 仅为内部领域兼容参数；MCP v3 只公开 categoryIds/locationIds，历史文字继续可读。未指定分类的新增按 MCP 提示规则从已有项选最合适的一项，没有合适项留空；后端不为此调用模型或新建分类。

### MembershipsService

| 方法 | 输入和行为 |
|---|---|
| list | timeZone，选填 query/asOf、分页；按到期排序并返回状态 |
| get | UUID；详情及规范关系 |
| create | operationId、timeZone、name、purchaseDate；周期会员还须 expirationDate；选填会员字段及 categoryIds/tagIds |
| update | operationId、id 和所选会员字段；不接收timeZone，不会重新生成首购 |
| recordPayment | operationId、membershipId、amountCents、timeZone，选填 paidAt/billingCycle/validUntil/notes |
| deletePayment | operationId、membershipId、paymentId、timeZone；准确回退账期，区分首购与稳定自动账期 |
| payments | membershipId、分页 |
| trash | operationId、id；保留支付历史 |
| statistics | 范围；整数分值支出、账目计数、当前有效会员状态 |

会员字段包括 provider/category/description/websiteUrl/purchasePlatform/priceCents/billingCycle/baseStatus/purchaseDate/expirationDate/isPermanent/autoRenew/renewalDate/needsRenewal、提醒配置、cancelGuide/notes。永久与到期日期互斥；提醒提前天数须为正、日内分钟在 0—1439。

MCP v3 的永久属性只接受 billingCycle=permanent，由适配层维护领域 isPermanent，防止模型重复填写矛盾状态。MCP 不再接受文字 category，只允许 categoryIds/tagIds；领域兼容参数仍保留。首购、记账和删除账目需要业务时区，基础编辑不需要。

保存主表、首购和分类标签是一个事务。标准续费从当前到期日叠加，账目 validFrom 使用支付业务日；自定义周期 validUntil 必须晚于支付日。记账不执行真实扣费，改续费标记不执行供应商退订；现有客户端自动补账调度继续使用原路径。

categoryIds与category互斥。规范ID推导展示名称，旧名称按物品相同规则替换或解除分类关系，不能遗留旧类别；UUID误填文字被拒绝。单独修改分类不影响tagIds，修改其他字段不重写分类关系。

### EventsService

| 方法 | 输入和行为 |
|---|---|
| list | timeZone，选填 query/isArchived/asOf、分页；返回应做时间及状态 |
| get | UUID；有效事件 |
| create/update | operationId，编辑还需 id；name、category、intervalValue/intervalUnit、提醒、isArchived、notes；initialCompletedAt 明确表示初始历史，不接受 lastCompletedAt 直接赋值 |
| complete | operationId、eventId，选填 completedAt/notes；省略 completedAt 表示现在 |
| history | eventId、分页；包含未删除的已撤销历史 |
| updateHistory | operationId、eventId、completionId，选填 completedAt/notes；编辑会清撤销标记 |
| undoCompletion/deleteHistory | operationId、eventId、completionId；撤销或软删指定记录后重算 |
| trash | operationId、id |
| statistics | 范围；有效历史计数与事件分布 |

category 是自由文本。日/周为固定时长，月/年为业务地区日历运算并截断月底。服务端复用同步的有效历史最大值重算；旧的仅汇总事件在首个历史操作时补保留初始事实。已永久删除初始身份不能借 update 恢复，需要明确新增一次完成记录。

### TodosService

| 方法 | 输入和行为 |
|---|---|
| list | query/fromDay/toDay/completed、分页；纯读取，不物化重复实例 |
| get | UUID；当前任务、有效直属孩子与步骤 |
| create | operationId、title、scheduledDate；选填 taskType/description/dueAt/reminderAt/priorityQuadrant/parentId/progressUnit/repeatRule；进度任务需 steps（name 对象数组） |
| update | operationId、id、所选基本字段；scope=single/future；未来编辑移动时钟须 timeZone，不平移各实例计划日期 |
| setCompleted | operationId、id、completed；进度任务全满才可确认，普通根任务对孩子对称级联 |
| setQuadrant | operationId、id、priorityQuadrant；选择孩子也移动整树 |
| setStepsCompleted | operationId、todoId、stepIds、completed；满格不自动确认，返回条件撤销事实 |
| undoSteps | operationId、changeOperationId；从原可信回执读取旧状态，后续修改后拒绝覆盖 |
| replaceSteps | operationId、todoId、steps、baseline；结构由 id/name/顺序校验，保留原步骤完成事实 |
| ensureRepeatedInstances | 内部兼容入口；MCP不再暴露手动生成工具，后台调度共用同一生成规则 |
| trash | operationId、id，scope=single/future；未来仅删未完成实例，主任务写 stopped，子任务不停止主系列 |
| statistics | 范围；计划与完成日分别计数，明确只含已保存重复实例 |

普通树只有两层；进度任务独立、不重复、不能转型。创建/新增步骤上限 1000，已合并超限结构可保留/减少。结构 baseline 不含完成状态，状态修改不导致无关结构编辑误冲突；步骤撤销则要求原步骤的状态及更新时间仍精确匹配。

MCP 只在创建时公开 taskType；替换步骤先调用 get_todo 取得 editToken，原样回传，由适配层提供读取时的结构 baseline。新步骤省略 id，不传 null。不得在冲突后自动读取最新基线覆盖。

步骤 editToken 保存原有序结构的签名摘要。准备阶段在 owner 锁内读取当前结构，摘要相同才传入领域 baseline；摘要不同直接拒绝，不能把最新结构冒充已读基线。这样无需把全部步骤名称复制进令牌，完成状态仍与结构编辑分离。令牌有效 24 小时，绑定 owner、连接和对象；持久签名密钥使其可跨进程重启验证，密钥轮换后失效。相同 requestId 和原参数先重放已有 MCP 动作，旧令牌过期不会阻断原回执查询或重放，授权和动作状态仍须校验。

TodoRecurrenceService 在服务启动及每 30 秒运行，以持久游标补齐各系列到今天。游标保存锚点、时区与规则变化签名；排程变化会重新检查，新增同规则实例不会反复重置断点。每轮最多 10 个 owner、每个 4 个系列、每系列 7 天；单系列失败在保存点内回滚并退避 60 秒，不阻止健康系列提交，失败期间不会误报已追平。实例、游标与保护身份在同一 owner 锁事务保存，停机后继续推进，不生成未来日期，不因查询或统计产生写入。

时区来自该 owner 有效待办读写连接的显式设置，经 IANA 别名规范化后必须唯一。无授权、无明确时区或时区冲突时暂停，条件恢复后自动继续。有待办读权限的 MCP 连接可从 get_capabilities.todoRecurrence 读取最近检查的 status/timeZone/reason/checkedAt，包括 not_checked、idle、catching_up、blocked_authorization、blocked_timezone、error；此查询不触发调度。

客户端与后端共用规则段锚点语义：连续同规则实例不改变周期起点，频率改变以变更日重新起算，null 表示单次例外。scope=future 关闭主系列保存 stopped，普通编辑保留既有终止标记。Windows/Android 使用相同的停止规则、永久墓碑和稳定实例身份。

迁移 `20261022010000_todo_recurrence_worker` 提供私有调度状态及游标；迁移 `20261022020000_todo_recurrence_protection` 提供 todo_recurrence_protections。生成根项和子项时同事务记录保护身份，同步上传复用既有字段前值检查及关联删除冲突检查，避免旧离线 PATCH/DELETE 覆盖后台生成内容。保护不依赖伪 MCP 回执，撤销连接或删除记录后仍保留，仅删除 owner 时级联清理；私有表不发布到 PowerSync 或业务快照。

priorityQuadrant完全沿用客户端0–3：0不紧急不重要，1紧急不重要，2重要不紧急（缺省），3重要且紧急。新增、编辑及整树移动均接受0并拒绝4；已有非法4不自动重映射，须核对后显式更新，不能经父项继承、未来编辑或重复实例生成继续传播。

### NotesBusinessService

| 方法 | 输入和行为 |
|---|---|
| list | query/fromDay/toDay/tagIds/excludeTagIds/withoutTags/isPinned/hasAudio/hasImages、分页；返回预览和身份，不默认发送整库正文 |
| get | UUID；正式正文及有效原音/图片关联 |
| create | operationId、body、timeZone，选填 tags/isPinned、完整记录时间组 |
| update | operationId、id；正文修改带 body/expectedRevision，标签修改带 tags/tagsBase，选填 isPinned/完整记录时间组 |
| append | operationId、id、text、expectedRevision；事务内生成新修订，重试不再追加 |
| versions | id、分页；不可变版本历史 |
| trash | operationId、id；本体、版本、音频、图片同批软删 |
| statistics | 范围；记录日篇数、可见字素、记录天数 |

正文最多 20,000 UTF-16 码元，与客户端长度校验一致。标签最多 10 个同归属有效笔记标签；相对 tagsBase 合并，清理已存失效标签残留。创建时间和创建时区由服务端固定且不可编辑。

记录时间组为 dayKey、recordTimeSeconds、recordUtcOffsetMinutes，必须整体提供，范围沿用现有 1970 年至当前时刻限制。正文基线失效时返回 status=conflict、当前 note 和 candidateRevision，候选已经提交，不能当成 saved；成功返回 status=saved。标签/元数据不使用正文 revision 提供全端保护。

上述时间组和 expectedRevision/tagsBase 为内部领域协议。MCP v3 只接收带偏移的 recordedAt 和详情返回的 editToken，适配层拆出记录日期、日内秒、偏移，并使用读取时的正文/标签基线。recordedAt 新增省略取当前时刻，更新省略保留；get_note 返回的 editToken 必须原样回传，不可自造或用提交时最新值替代。令牌沿用上述 24 小时、持久签名和原 requestId 重放规则。正式正文冲突仍保存候选，标签仍保留并发新增。

追加冲突基于真正的历史正文构造候选；历史基线不存在时返回 NOTE_BASE_MISSING。历史正文恢复可读取 versions，再以当前 expectedRevision 调用普通 update 生成新修订。ASR/AI 整理成功不等于正式正文已采用；结果由客户端依据录音顺序、正文版本和采用范围写回，服务器不会直接覆盖正文。

## 迁移、验证与发布边界

迁移 `20261020010000_business_operations` 包含一张内部业务回执表，物品/时间/会员三类永久删除触发器，并清理这三类已有的孤立分类关系。软删除但仍存在的业务记录及其关系保留。这些业务回执为后端私有状态，不进入 PowerSync 发布。

增量同步与快照迁移共用现有多态模块映射。增量事务在最终状态检查关系闭包，允许链接先于业务父行上传；父项的永久墓碑优先于迟到的新链接身份。同步原始负载摘要、回执及批次顺序保持。

发布前备份数据库、对象存储及密钥卷，停止旧 API 请求后执行全部待应用迁移，再启动 API 并更新客户端；详见[部署说明](../../../../deploy/README.md)。后台保护身份须随数据库备份，不能作为日志清理。客户端仍通过同步入口传输业务记录，同步 schema 为 12；本地数据库与备份版本见[客户端说明](../../../client/README.md)。

验证入口为 `test/business-input.spec.ts`、`test/business.integration.spec.ts`。集成测试只读取显式 `OMNI_BUSINESS_TEST_DATABASE_URL`，要求 `127.0.0.1`、库名以 `_test` 结尾且 public 无既有表；不读取应用 `DATABASE_URL`，也不清理用户数据库。
