# 可复用后端业务接口

七模块业务方法由 BusinessModule 注册并导出。Codex MCP 已作为独立适配层注入并调用同一个服务，提供七模块查询、统计及按连接写权限执行的写入（单条直接执行，批量在Codex对话确认）；当前 HTTP、PowerSync 和原音/图片传输继续使用现有入口。接入、权限、跨端基线保护和上线说明见 [MCP README](../mcp/README.md)，应用内对话及 Function Calling 尚未接入。

## 调用约定

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

范围统一使用 from/to（带时区 ISO 时间点）、timeZone（IANA 地区或 UTC）、可选 asOf，采用左闭右开区间，最长十年。DATE/笔记 dayKey 数据按指定地区的自然日起点归属窗口；月/周窗口应传实际当地日界。当前数据查询不重建历史快照：asOf 用于进行中时长、完成/支付截止及状态计算，不能推断过去的库存或会员状态版本。

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
| list | 范围、分页；返回相交记录 |
| get | UUID；详情 |
| ongoing | 分页；展示所有已保存进行中记录，不掩盖同步冲突 |
| start | operationId、timeZone，选填 startedAt/activity/category/notes；省略 startedAt 表示首次执行时的现在 |
| create | operationId、timeZone、startedAt、endedAt、activity，选填 category/notes |
| update | operationId、id、timeZone，选填 startedAt/endedAt/activity/category/notes |
| finish | operationId、id、timeZone，选填 endedAt/activity/category/notes；原记录须进行中，最终活动不能为空；省略 endedAt 表示现在 |
| trash | operationId、id |
| statistics | 范围；完整裁剪时长、分类与按日汇总 |

新建/普通编辑检查区间重叠与当前进行中记录。结束既有进行中记录保留原冲突收尾通路，允许用户逐条处理离线同步形成的多条进行中记录。

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

物品字段包括 quantity、purchasePriceCents、purchaseDate、purchaseUrl、purchasePlatform、status、warrantyExpiration、tags（文字数组）、parentItemId、notes；category/location 旧文字仍可读写，明确提供规范 ID 时优先同步维护展示文字。配件只允许两层，不能自引用、循环或把带配件主项挂到另一主项下。

### MembershipsService

| 方法 | 输入和行为 |
|---|---|
| list | timeZone，选填 query/asOf、分页；按到期排序并返回状态 |
| get | UUID；详情及规范关系 |
| create | operationId、timeZone、name、purchaseDate；周期会员还须 expirationDate；选填会员字段及 categoryIds/tagIds |
| update | operationId、id、timeZone 和所选会员字段；不会重新生成首购 |
| recordPayment | operationId、membershipId、amountCents、timeZone，选填 paidAt/billingCycle/validUntil/notes |
| deletePayment | operationId、membershipId、paymentId、timeZone；准确回退账期，区分首购与稳定自动账期 |
| payments | membershipId、分页 |
| trash | operationId、id；保留支付历史 |
| statistics | 范围；整数分值支出、账目计数、当前有效会员状态 |

会员字段包括 provider/category/description/websiteUrl/purchasePlatform/priceCents/billingCycle/baseStatus/purchaseDate/expirationDate/isPermanent/autoRenew/renewalDate/needsRenewal、提醒配置、cancelGuide/notes。永久与到期日期互斥；提醒提前天数须为正、日内分钟在 0—1439。

保存主表、首购和分类标签是一个事务。标准续费从当前到期日叠加，账目 validFrom 使用支付业务日；自定义周期 validUntil 必须晚于支付日。记账不执行真实扣费，改续费标记不执行供应商退订；现有客户端自动补账调度继续使用原路径。

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
| ensureRepeatedInstances | operationId、day、timeZone；显式生成该日实例，与客户端使用相同稳定身份并尊重停止和永久墓碑 |
| trash | operationId、id，scope=single/future；未来仅删未完成实例，主任务写 stopped，子任务不停止主系列 |
| statistics | 范围；计划与完成日分别计数，明确只含已保存重复实例 |

普通树只有两层；进度任务独立、不重复、不能转型。创建/新增步骤上限 1000，已合并超限结构可保留/减少。结构 baseline 不含完成状态，状态修改不导致无关结构编辑误冲突；步骤撤销则要求原步骤的状态及更新时间仍精确匹配。

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

追加冲突基于真正的历史正文构造候选；历史基线不存在时返回 NOTE_BASE_MISSING。历史正文恢复可读取 versions，再以当前 expectedRevision 调用普通 update 生成新修订。ASR/AI 整理成功仍不等于正式正文已采用；服务器整理采用与跨端去重留待该能力接入时实施。

## 迁移、验证与发布边界

新增迁移 20261020010000_business_operations：一张内部业务回执表，物品/时间/会员三类永久删除触发器，并清理这三类已有的孤立分类关系。软删除但仍存在的业务记录及其关系保留。PowerSync 发布表和字段、客户端 schema/本地数据库版本未改变。

增量同步与快照迁移共用现有多态模块映射。增量事务在最终状态检查关系闭包，允许链接先于业务父行上传；父项的永久墓碑优先于迟到的新链接身份。同步原始负载摘要、回执及批次顺序保持。

发布前按现有流程备份数据库、对象存储及密钥卷，再部署数据库迁移和 API。本轮只在专用空测试库执行迁移，运行中的应用数据库未更新。Flutter 现有 Repository 没有切换调用方式；后端新会员保存路径已原子化，客户端原有独立事务问题仍需在客户端工作中处理。

验证入口：test/business-input.spec.ts、test/business.integration.spec.ts。集成测试只读取显式 OMNI_BUSINESS_TEST_DATABASE_URL，要求 127.0.0.1、库名以 _test 结尾且 public 无既有表；不读取应用 DATABASE_URL，也不清理用户数据库。通过的具体用例、全套服务端回归及外部存储跳过项以本轮 output/business-backend-20261020/ 测试记录为准。
