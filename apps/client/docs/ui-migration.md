# 统一 UI 迁移清单

盘点日期：2026-10-06。范围为 `apps/client/lib` 的应用内界面，依据实际路由、组件类和浮层调用点整理。表中路径均相对 `apps/client/`，测试名均相对 `test/`。

本清单区分代码迁移、自动化验证和人工验收。代码迁移已完成，现有客户端测试全量通过；表中的“自动化通过”只覆盖列出的测试断言，不表示所有必验状态、全部主题与平台组合或实机手感已经人工验收。实际覆盖及待验矩阵见末尾。

## 盘点口径与统一基础

- 主导航有 **7 个路由**，另有 Windows 独立悬浮窗；Android 管理聚合器和设置详情属于既有路由内的二级界面。
- 有 **24 个具名业务弹窗/侧栏组件**。同一组件的新增、编辑、开始、结束等状态合并计数；`State` 类、基础 `OmniDialogScaffold` 和内联确认框不重复计数。
- 所有界面均需检查：正常、加载、空态、失败、禁用/只读、提交中、保存失败；只有相关界面才需构造对应状态，不能用空页面代替表单或列表验收。
- 主题矩阵为六套配色 × 浅色/深色，另验跟随系统切换；平台矩阵为 Windows 宽窗/窄窗、Android 紧凑布局、Windows 悬浮窗专用尺寸。
- 统一设计参数来自 `lib/app/theme/app_tokens.dart`，语义颜色和原生控件兜底来自 `lib/app/theme/app_theme.dart`；组件出口为 `lib/shared/ui/omni_ui.dart`，规范为仓库根目录 `style.md`。
- 基础输入、图标按钮、复选框、单选项已提供 `OmniTextField`、`OmniTextFormField`、`OmniIconButton`、`OmniCheckbox`、`OmniRadioListTile`；日期、时间、下拉、菜单、消息和弹窗继续升级现有 Omni 实现。

## 页面、二级界面与状态

| 入口与源码 | 必验界面/状态 | 平台 | 当前统一路径与迁移状态 | 验证入口 | 验证状态 |
|---|---|---|---|---|---|
| `/home`；`lib/features/home/presentation/home_page.dart`、`home_mobile_dashboard.dart` | 今日待办、事件关注、时间图例、名言/背景；模块隐藏/排序、完成/撤销、窗口缩放 | Windows 宽/窄窗、Android | Windows 保留卡片网格；Android 紧凑首页使用顶部名言、下划线导航、横向平铺分页与独立正文滚动，首尾不接力一级导航；短屏头部可收起，首页设置独立管理名言与内容顺序；业务控件与图表保留 | `home_mobile_dashboard_test.dart`、`home_mobile_viewport_test.dart`、`home_mobile_settings_test.dart`、`home_dashboard_test.dart`、`home_golden_test.dart`、`home_context_card_test.dart`、`home_window_resize_test.dart`、`home_todo_scroll_test.dart` | 本轮最终验收见文末；实体设备手感待验 |
| `/todos`；`lib/features/todos/presentation/todos_page.dart` | 进行中四象限、单象限聚焦、父子任务树、完成历史；拖拽/移动、展开收起、完成/撤销、重复系列影响范围 | Windows 宽/窄窗、Android 横滑 | 共享按钮/输入/菜单/日期/消息；分段导航接共享主题或 Omni 控件；树线、象限拖拽为专用交互；回收站确认改为统一语义按钮 | `todo_quadrant_ui_test.dart`、`todo_quadrant_golden_test.dart`、`todo_repository_test.dart` | 自动化通过；人工矩阵待验 |
| `/timeline`；`lib/features/timeline/presentation/timeline_page.dart`、`timeline_review.dart` | 复盘/明细、日/周/月指纹、分类结构/趋势、日时间轴、进行中记录；冲突提示、补记/结束、跨日记录 | Windows 宽/窄窗、Android | 共享分段、日期时间、下拉、表单和消息；时间轴、占用区间滑块保留业务图形 | `timeline_layout_test.dart`、`timeline_editor_test.dart`、`timeline_android_ui_test.dart`、`time_entry_interval_test.dart` | 自动化通过；人工矩阵待验 |
| `/events`；`lib/features/events/presentation/events_page.dart` | 事件列表/卡片、状态筛选、归档、周期提醒；记录完成、历史、撤销 | Windows 宽/窄窗、Android 管理聚合 | 页面与编辑器接共享主题、表单、按钮、菜单、开关、日期时间；保留事件业务状态色 | `events_layout_test.dart`、`management_compact_cards_test.dart`、`business_repositories_test.dart` | 自动化通过；人工矩阵待验 |
| `/inventory`；`lib/features/inventory/presentation/inventory_page.dart` | 物品卡片、搜索/分类/位置/状态筛选、统计、详情、配套物品、批量迁移；继承位置、附件状态 | Windows 宽/窄窗、Android 管理聚合 | 通用控件接 Omni；详情卡和统计图保留专用布局；详情翻转及新增拆分菜单列为专用浮层 | `inventory_layout_test.dart`、`inventory_move_dialog_test.dart`、`management_compact_cards_test.dart` | 自动化通过；人工矩阵待验 |
| `/memberships`；`lib/features/memberships/presentation/memberships_page.dart` | 会员卡片、搜索/类别/状态筛选、支出统计、到期时间轴、缴费历史；永久/到期/续费/提醒状态 | Windows 宽/窄窗、Android 管理聚合 | 共享面板、表单、日期、开关、菜单和消息；会员状态信息/图表维持业务语义 | `memberships_layout_test.dart`、`management_compact_cards_test.dart`、`business_repositories_test.dart` | 自动化通过；人工矩阵待验 |
| `/settings`；`lib/features/settings/presentation/settings_page.dart` | 功能管理、外观与主题、通知提醒、数据同步、数据与存储；Android 概览→详情→返回；断开/重连/清空/恢复状态 | Windows 宽/窄窗、Android | 共享开关/下拉/单选/表单/按钮/弹窗；保留既有设置导航与危险操作边界 | `theme_settings_test.dart`、`feature_preferences_test.dart`、`android_settings_transition_test.dart`、`sync_connection_dialog_test.dart` | 自动化通过；人工矩阵待验 |
| `FloatingWindowPage`；`lib/features/floating/presentation/floating_window_page.dart` | 待办象限/子任务、快速新增、开始记录/补记、进行中、撤销；拖动、缩放、唤起主窗口 | Windows 独立悬浮窗 | 共享语义色、输入、下拉、按钮和消息；紧凑行高、宿主窗口拖拽/缩放及浮层材质为受控差异 | `floating_window_page_test.dart`、`floating_resize_scheduler_test.dart`、`windows_floating_resize_service_test.dart`、`support/windows_floating_host_smoke.dart` | 自动化通过；人工矩阵待验 |
| `ResponsiveShell`、管理聚合器；`lib/shared/layout/responsive_shell.dart`、`lib/features/management/presentation/` | 侧栏/导航轨、桌面管理切换、底部导航、Android 主页面/管理分区横滑、同步状态入口 | Windows、Android | 共享主题、图标操作与菜单；导航关系、预加载和手势协调保持既有契约 | `desktop_management_navigation_test.dart`、`android_management_navigation_test.dart`、`android_primary_navigation_swipe_test.dart`、`responsive_shell_sync_status_test.dart` | 自动化通过；人工矩阵待验 |

## 24 个具名业务弹窗与侧栏

“居中”均通过应用内 `showOmniDialog`，不会因 Flutter Windows 实验多窗口能力变成独立原生窗口。“侧栏”通过 `showOmniSideSheet`，紧凑宽度保持既有全宽形态。以下“已接入”仅描述源码路径。

| 编号 | 组件/入口与源码 | 必验状态与平台差异 | 当前统一路径与迁移状态 | 验证入口 | 验证状态 |
|---|---|---|---|---|---|
| D01 | `TaxonomyManagerDialog`；`lib/shared/taxonomy/taxonomy_manager_dialog.dart` | 新增、重命名、颜色、删除/撤销、重复名称、保存失败、拖拽；Android 全屏/桌面居中 | 已接 Omni 输入、按钮、图标、操作菜单；名称编辑自适应换行；保留分类颜色网格 | `taxonomy_manager_dialog_test.dart`、`taxonomy_repository_test.dart` | 自动化通过；人工矩阵待验 |
| D02 | `GlobalSearchDialog`；`lib/shared/search/global_search_dialog.dart` | 空查询、搜索中、无结果、失败、多类型结果、功能关闭后的过滤 | 居中 `OmniDialogScaffold` + `OmniTextField` + `OmniListRow`，已接入 | 共享 `omni_overlay_accessibility_test.dart`；搜索结果专项需手工验收 | 共享/仓储回归通过；界面专项待验 |
| D03 | `AttachmentPickerDialog`；`lib/shared/attachments/attachment_picker_dialog.dart` | 无图、预览、选图取消、上传/同步状态、移除、恢复默认背景、读取失败 | 已有 `OmniDialogScaffold` / `OmniButton`；原生文件选择器为系统例外 | `attachment_repository_test.dart`、`image_sync_service_test.dart`；界面需手工验收 | 共享/仓储回归通过；界面专项待验 |
| D04 | `AttachmentCropDialog`；`lib/shared/attachments/attachment_crop_dialog.dart` | 图片解码、移动/缩放裁剪框、确认/取消、保存失败 | 已有统一弹窗与按钮；图像遮罩/白色裁剪手柄保留，以图片对比度为准 | 共享浮层测试；图片裁剪手感/导出专项需手工验收 | 共享/仓储回归通过；界面专项待验 |
| D05 | `_HomeCardManagerSheet` / `showHomeCardManager`；`lib/features/home/presentation/home_card_manager.dart` | 已添加/可添加/不可用卡片、拖拽、键盘排序、空集合 | 已接 `OmniSideSheetScaffold`、共享列表和图标按钮；原排序语义保留 | `home_dashboard_test.dart`、`home_card_preferences_test.dart` | 自动化通过；人工矩阵待验 |
| D06 | `QuoteLibraryDialog`；`lib/features/home/presentation/quote_library_dialog.dart` | 列表、搜索、空态、删除/撤销、导入/导出菜单 | 已接统一弹窗、输入、图标、菜单和消息 | `quote_library_dialog_test.dart` | 自动化通过；人工矩阵待验 |
| D07 | `QuoteImportPreviewDialog`；同上 | 导入预览、追加/覆盖模式、确认/取消、格式错误 | 已接统一弹窗、单选选项和按钮；导入数据规则保留 | `quote_library_dialog_test.dart`、`quote_json_transfer_test.dart` | 自动化通过；人工矩阵待验 |
| D08 | `_QuoteEditorDialog`；同上 | 新增/编辑、正文多行、作者、必填/保存状态 | 已接统一侧栏、表单字段和按钮 | `quote_library_dialog_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化通过；人工矩阵待验 |
| D09 | `TodoEditorDialog`；`lib/features/todos/presentation/todo_editor_dialog.dart` | 新建/编辑/子任务、日期时间、提醒、重复规则、进度结构、重复系列范围、保存失败 | 统一侧栏和控件；时间设置外置标签、空值入口等宽与折叠摘要；进度设置基础字段并排、步骤行内操作/窄屏菜单、短列表完整展示、添加定位聚焦，均适配大字号 | `todo_editor_time_settings_test.dart`、`todo_progress_editor_layout_test.dart`、`todo_progress_ui_test.dart`、`todo_quadrant_ui_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化与中文宽窄屏预览通过；真机手感及完整人工矩阵待验 |
| D10 | `_TimeEntryEditorDialog`；`lib/features/timeline/presentation/timeline_page.dart` | 区间编辑、日期/分类、备注、多段占用冲突、拖动范围、保存失败 | 共享侧栏/输入/选择；业务范围滑块与冲突图形保留 | `timeline_editor_test.dart`、`timeline_layout_test.dart` | 自动化通过；人工矩阵待验 |
| D11 | `_AbsoluteTimeEntryDialog`；同上；`time_entry_time_picker.dart` | 半屏/全屏开始记录、完整补记/编辑、结束进行中、逐分钟/跨日日期、时间冲突、类别逐项颜色、备注折叠 | Android 开始记录使用 Omni 可展开底部面板，横线独立拖拽/点击，顶部固定取消/开始；半屏只显示活动和类别，全屏才增加开始时间与描述，收起保留输入，键盘避让不改变展开状态；提交期间锁定关闭/拖拽。Android 新增补记改为根导航全屏弹窗，顶部固定取消/补记/保存和灰色小时摘要，正文以时间卡片及活动/类别/备注分组呈现，保存期间保护返回、失败保留草稿；补记/已完成编辑保留 Android 双列时分滚轮与 Windows 精确输入/双手柄、连续跨日扩展、占用边界阻挡回弹和默认最近空闲段；共享日期/表单/下拉保留类别左侧色点；结束流程保留原遮罩关闭限制 | `start_time_entry_sheet_test.dart`、`time_entry_dialog_test.dart`、`time_entry_interval_test.dart`、`timeline_android_ui_test.dart`、`timeline_editor_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化、真实中文截图及 API 36 独立包交互通过；实体设备手感/读屏待验 |
| D12 | `_EventEditorDialog`；`lib/features/events/presentation/events_page.dart` | 新增/编辑、周期单位/间隔、提醒开关/时间、必填和保存失败 | 已接共享侧栏、表单、下拉、开关和按钮 | `events_layout_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化通过；人工矩阵待验 |
| D13 | `_EventHistoryDialog`；同上 | 历史列表、分组、空态、编辑/删除记录 | 已接统一居中弹窗、操作菜单和确认/消息 | `events_layout_test.dart` | 自动化通过；人工矩阵待验 |
| D14 | `_EventHistoryEditorDialog`；同上 | 历史时间、备注、保存/取消 | 已接统一居中弹窗、日期时间和文本字段 | `events_layout_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化通过；人工矩阵待验 |
| D15 | `_InventoryEditorDialog`；`lib/features/inventory/presentation/inventory_page.dart` | 新增/编辑/配套物品、状态/类别/位置、金额数量、购入/保修日期、位置继承 | 已接统一侧栏、表单、下拉、日期和开关；原业务校验保留 | `inventory_layout_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化通过；人工矩阵待验 |
| D16 | `_InventoryDetailDialog`；同上 | 物品信息、图片、编辑/配套跳转、空字段、窄屏 | 专用卡片详情保留 `showGeneralDialog`；内容接共享语义色/图标/按钮；专用转场须单独验收 | `inventory_layout_test.dart` | 自动化通过；人工矩阵待验 |
| D17 | `_AccessoriesDialog`；同上 | 配套列表、空态、新增配套、统计/位置继承 | 居中 `OmniDialogScaffold`，子编辑器走统一侧栏 | `inventory_layout_test.dart`、`business_repositories_test.dart` | 自动化通过；人工矩阵待验 |
| D18 | `InventoryMoveDialog`；`lib/features/inventory/presentation/inventory_move_dialog.dart` | 物品选择/全选、随主物品自动选中、目的位置、新建位置、迁移结果/失败 | 已接统一弹窗、输入、复选框、下拉、按钮和消息 | `inventory_move_dialog_test.dart` | 自动化通过；人工矩阵待验 |
| D19 | `_MembershipEditorDialog`；`lib/features/memberships/presentation/memberships_page.dart` | 新增/编辑、计费周期、永久/到期、自动续费、提醒与分类 | 已接统一侧栏、表单、日期、下拉、开关 | `memberships_layout_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化通过；人工矩阵待验 |
| D20 | `_PaymentHistoryDialog`；同上 | 缴费历史、空态、添加/编辑/删除、汇总 | 已接统一居中弹窗与确认/消息；列表沿用主题 | `memberships_layout_test.dart`、`business_repositories_test.dart` | 自动化通过；人工矩阵待验 |
| D21 | `_PaymentEditorDialog`；同上 | 缴费金额/日期、周期、有效期、保存失败 | 已接统一居中弹窗、输入、下拉、日期和按钮 | `windows_dialog_enter_save_test.dart`、`memberships_layout_test.dart` | 自动化通过；人工矩阵待验 |
| D22 | `_SyncConnectionDialog`；`lib/features/settings/presentation/sync_connection_dialog.dart` | 连接表单→数据处理预览、保留/替换策略、返回、提交中不可关闭、失败 | 已接统一侧栏、表单、单选、图标和按钮；保留两阶段确认与 `PopScope` | `sync_connection_dialog_test.dart`、`sync_connection_coordinator_test.dart` | 自动化通过；人工矩阵待验 |
| D23 | `_SyncBackupDialog`；`lib/features/settings/presentation/sync_backup_dialog.dart` | 备份列表、加载/失败、删除确认/执行中 | 已接统一居中弹窗和按钮；旧库/快照删除范围不变 | `sync_maintenance_boundary_test.dart`；备份界面专项需手工验收 | 共享/仓储回归通过；界面专项待验 |
| D24 | `TodoProgressPanel`；`lib/features/todos/presentation/todo_progress_panel.dart` | 跳序记录、批量预览、即时保存/失败重试、六秒撤销、满进度待确认、历史只读与重开；首页/待办/悬浮窗共用 | 统一侧栏、按钮、输入、消息与语义主题；顶部下一个步骤与完成操作同排，批量短输入框及外置标签，空间不足按字号分行，错误整行展示；只读分段条为业务图形，无拖动手势 | `todo_progress_ui_test.dart`、`todo_progress_entrypoints_test.dart`、`todo_progress_panel_layout_test.dart`、`test/support/todo_progress_runtime_smoke.dart` | 六配色×明暗像素、键盘、读屏语义与宽窄屏通过；Windows/Android模拟器真实引擎点击闭环通过；本轮顶部布局验收记录见进度面板专项测试；实体设备读屏/输入法体验待人工验收 |

## 内联浮层、选择器、消息与受控例外

| 类别与调用位置 | 当前统一路径/迁移状态 | 必验行为 | 验证入口 | 验证状态 |
|---|---|---|---|---|
| 短确认：分类删除、事件历史删除、会员缴费删除、名言删除、首页删除、设置清理 | `showOmniConfirmDialog` + `OmniDialogScaffold` + 危险操作变体；共享动作区可换行 | 取消/确认结果、Esc/返回/遮罩、正文滚动、关闭焦点恢复 | `omni_overlay_accessibility_test.dart`、`taxonomy_manager_dialog_test.dart`、相关业务测试 | 自动化通过；人工矩阵待验 |
| 待办移动象限、移入回收站及重复系列范围 | 已使用应用内 `showOmniDialog`；部分内容为受主题控制的 `SimpleDialog` / `AlertDialog`，重复编辑用 `OmniDialogScaffold`；回收站操作使用 OmniButton 的次要和危险变体 | 当前象限禁用、父子任务范围、仅本次/以后、撤销，不因外观迁移改变结果 | `todo_quadrant_ui_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化通过；人工矩阵待验 |
| 同步断开与备份删除的内联确认 | `showOmniDialog` + `OmniDialogScaffold`，保留原数据处理选项与破坏性操作确认 | 保留/删除本机数据、取消、执行中禁止重复提交 | `sync_connection_dialog_test.dart`、`sync_maintenance_boundary_test.dart`；备份清理手工验收 | 自动化通过；人工矩阵待验 |
| 日期选择：待办、时间、事件历史、物品、会员 | `OmniDatePickerButton` / `MenuAnchor`；共享圆角/表面，触控日历更宽且保持六行，日期有完整语义标签 | 日期范围、月份/年份切换、选中/今天、取消、触控网格、减少动效 | `omni_date_time_picker_test.dart`、`omni_overlay_accessibility_test.dart` | 自动化通过；人工矩阵待验 |
| 时间选择：提醒、历史、时间记录 | `OmniTimePickerButton` / `MenuAnchor`；保留原非步长时间，菜单项目跟随平台密度/文字放大 | 既有分钟值、滚动定位、选中与关闭后焦点 | `omni_date_time_picker_test.dart`、`omni_overlay_accessibility_test.dart` | 自动化通过；人工矩阵待验 |
| 普通/表单下拉：业务筛选、类别/位置/状态、主题、重复规则 | `OmniDropdownButton` / `OmniDropdownButtonFormField`；选中勾位置可配置；键盘展开聚焦当前项，关闭回触发器 | 空值、禁用、表单错误、Enter/Space/上下键、Tab、触控实际热区 | `omni_dropdown_test.dart`、`omni_overlay_accessibility_test.dart` | 自动化通过；人工矩阵待验 |
| 常规操作菜单：列表更多、分类、名言导入导出、导航主题/管理切换 | `OmniPopupMenuButton` / `OmniPopupMenuItem`；共用主题、动作图标、危险色和减少动效 | 选中/取消、禁用项、打开后返回、键盘与边缘定位 | `omni_dropdown_test.dart`、`taxonomy_manager_dialog_test.dart`、导航专项测试 | 自动化通过；人工矩阵待验 |
| 分类颜色选择 | Omni 菜单入口；一个底层 `PopupMenuItem` 承载自定义颜色网格，颜色格增加语义与触控区域 | 颜色名称、已选标记、键盘/触控选择、取消 | `taxonomy_manager_dialog_test.dart` | 自动化通过；人工矩阵待验 |
| 首页待办右键/长按菜单 | 指针定位 `showMenu` + `OmniPopupMenuItem`，保留调用位置定位能力；主题统一 | 右键/长按、不重复开启、编辑/子任务/删除、菜单关闭 | `home_todo_context_menu_test.dart` | 自动化通过；人工矩阵待验 |
| 每日待办普通/进度任务菜单及首页进度快捷操作 | `TodoTaskContextMenu` 指针定位 `showMenu` + `OmniPopupMenuItem`，移除更多按钮；添加子任务与完成下一个共用按钮尺寸；进度快捷按钮使用“+1”直接完成首个未完成步骤，正文仍打开面板 | Windows 单击展开/收起、右键；Android 单击、长按、横滑；编辑/移动/回收站、键盘菜单键/Shift+F10；进度提交防重、失败恢复、精确撤销、满进度仍需确认 | `todo_progress_entrypoints_test.dart`、`todo_progress_quick_action_test.dart`、`todo_quadrant_ui_test.dart` | 自动化通过；人工矩阵待验 |
| 移动新增拆分菜单 | 时间/事件等使用 `OmniSplitActionButton`；物品仍有专用新增拆分菜单，均保留按钮上方锚定/展开语义 | 点主按钮与菜单互不混淆、取消、菜单方向键、减少动效、屏边 | `timeline_android_ui_test.dart`、`events_layout_test.dart`、`inventory_layout_test.dart` | 自动化通过；人工矩阵待验 |
| 页面顶部操作反馈/完成撤销 | `showOmniMessage`；成功/警告/错误/信息共用结构；内容相对弹窗垂直居中，撤销保持同行；鼠标、键盘或读屏焦点停留暂停，辅助服务开启本身不永久暂停 | 替换/关闭、倒计时、操作只执行一次、撤销时限、辅助服务开启时仍自动关闭、正文及按钮读屏焦点暂停/继续、宽窄窗口与两倍字号对齐、长文案换行、减少动效 | `omni_message_test.dart`、`omni_overlay_accessibility_test.dart`、业务撤销测试 | 自动化通过；真实中文宽窄窗、长文案和删除提示预览通过；人工矩阵待验 |
| 文本输入/表单校验 | `OmniTextField` / `OmniTextFormField` 保留 Flutter 文本编辑、输入法、焦点及验证能力；业务拥有校验规则 | 中文输入法组合态、复制粘贴、多行 Enter、错误/只读/禁用/提交中、焦点顺序 | `omni_form_controls_test.dart`、`omni_windows_enter_submit_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化通过；人工矩阵待验 |
| 分段切换、统计轮播与手势 | `OmniSlidingSegmentedControl`、共享分段主题、`OmniStatisticsCarousel`；Android 页面/象限横滑继续既有手势协调 | 连续快速切换、中途反向、跟手索引、减少动效、返回 | `omni_sliding_segmented_control_test.dart`、`omni_statistics_carousel_test.dart`、`android_primary_navigation_swipe_test.dart` | 自动化通过；人工矩阵待验 |
| 附件选图、名言 JSON 导入/导出 | `FilePicker.pickFile` / `FilePicker.saveFile` 系统窗口保留；应用内调用入口与返回反馈统一 | 原生取消、不支持文件、路径/文件错误、焦点回到应用 | `quote_library_dialog_test.dart`、`quote_json_transfer_test.dart`、Windows/Android 实机 | 自动化通过；人工矩阵待验 |
| 操作系统通知、托盘和窗口外框 | `core/notifications/local_notification_service.dart`、Windows 托盘/悬浮窗宿主；系统控制的显示不伪装为应用弹窗 | 通知可用/失败、托盘唤起、窗口位置和关闭；系统若请求权限则保留系统授权界面 | `notification_plan_builder_test.dart`、`windows_tray_service_test.dart`、宿主烟测与实机 | 自动化通过；人工矩阵待验 |

## 验收记录与回归约束

- 组件展示入口是 `lib/dev/ui_catalog.dart`；先对共享组件审查 12 种配色明暗组合，再审业务界面。`omni_theme_test.dart`、`omni_button_test.dart`、`omni_form_controls_test.dart`、`ui_catalog_test.dart` 是基础验证入口。
- 现有 golden 使用 Flutter 测试字体，主要证明布局、尺寸与裁切。中文可读性必须另外查看加载真实中文字体的预览或实机；不能将方块字截图标成中文验收通过。
- 日期 golden 画布由 420×420 扩展为 420×520，以容纳触控菜单与完整阴影。此尺寸调整不能替代真实小视口的布局测试。
- 基线只在逐张查看候选图、确认差异来源之后更新；测试失败必须先区分预期视觉变化与业务/焦点/布局回归。
- 没有对应专项自动化的搜索、附件裁剪、备份清理界面需要显式保留手工验收项。实机验证还包括中文输入法、屏幕阅读器、字体放大、滚动/拖拽流畅度与 Android 返回。
- 自定义绘制的图表、象限树线、裁剪遮罩及系统窗口属于有明确目的的差异，不因出现 `CustomPaint`、`Material` 或底层 Flutter 控件而机械替换。新增普通控件应优先经 Omni 入口和共享参数，新增例外须补充本清单及规范说明。
- 周时间指纹的类别标签在业务分类色块上保留固定浅灰 `Color(0xFFD6D6D6)` 和 0.85 透明度，属于专用图表标注；仅在 `timeline_review.dart` 登记一处受控例外，不扩展至普通文字或品牌控件。首页时间卡片移除“查看全部”后，仅保留空态“开始记录”的一处 `TextButton` 例外。

### 最终集成结果

执行日期：2026-10-06。环境：Windows、本机 Flutter 3.47.2 / Dart 3.13.2；Android 平台运行检查使用 API 36 模拟器。以下日志及 PNG 位于仓库 `output/`（本机验收产物，不随源码提交）。

| 验证 | 实际结果 | 证据 |
|---|---|---|
| `dart tool/check_ui_style.dart` | 通过；40 项按文件/类型登记的受控例外，无新增绕过入口 | `tool/ui_style_exceptions.json`、CI `ui-checks.yml` |
| `flutter analyze --no-pub` | 全量客户端静态分析通过 | `output/ui-analyze-verified.log` |
| `flutter test --no-pub` | **427 通过、4 跳过、0 失败** | `output/ui-test-verified.log` |
| 组件展示回归 | 13 测试通过；六套配色明暗、Windows 宽/窄窗、Android 紧凑布局、两档文字缩放；表单校验/浮层保存 | `test/ui_catalog_test.dart`、`output/ui-catalog-preview-test.log` |
| 中文组件预览 | 24 张；十二配色明暗组合 × 桌面/触控；人工抽查字体、布局、按钮及状态，最终复查经典蓝明暗和海盐深色 | `output/ui-preview/` |
| 中文业务预览 | 4 组生成测试通过，共 36 张：Windows/Android × 明暗 × 七页面、事件编辑、分类管理；全部实际看图审查，修复并复查首页待办字体 | `tool/ui_pages_preview_test.dart`、`output/ui-pages-preview/` |
| Golden 结构回归 | 逐对审查后刷新 28 张基线，全量测试通过；保留测试字体，未用方块图代替中文审查 | `test/goldens/`、`output/ui-test-verified.log` |
| Windows 平台运行 | 独立纯内存组件宿主：开关正反切换、菜单选择、表单错误/中文文本、多层弹窗保存关闭、配色/明暗/放大文字通过 | `output/ui-runtime-windows.log` |
| 项目组件展示入口 | `flutter run -d windows -t lib/main_ui_catalog.dart` 冷启动通过；沿用产品的引擎宿主，显式创建并激活组件目录窗口，未初始化业务服务 | `lib/main_ui_catalog.dart`、`output/ui-catalog-host-smoke.log` |
| Android 平台运行 | API 36 模拟器上的独立包 `dev.omnibutler.ui_preview` 同组交互通过；未覆盖已安装生产应用，结束后确认预览包已不存在 | `output/ui-runtime-android.log` |
| 正式应用构建 | Windows Release 与 Android Debug APK 构建通过；仅构建，不启动带真实数据的业务入口 | `output/ui-build-windows.log`、`output/ui-build-android.log` |

四项跳过均为明确需要隔离后端的既有同步/迁移/图片 E2E：`powersync_server_e2e_test.dart` 两项、`powersync_migration_e2e_test.dart` 一项、`image_sync_e2e_test.dart` 一项。本轮没有服务端、数据库结构或业务仓储变更。

本轮回归覆盖了跨页待办完成与撤销、父子任务/拖拽、表单校验与重复提交、Windows Enter 与中文组合态、多行输入、菜单方向键/焦点恢复、Android 横滑/返回、窗口尺寸变化、减少动效、读屏语义节点，以及触控编辑器在软键盘展开后的输入/保存可达性。原有业务断言继续执行；仅在统一设计改变尺寸、控件入口或外观契约时调整对应断言。

### 仍需人工验收的明确范围

- Android **实体设备**上的 IME 候选窗、硬件返回、读屏和滑动手感；目前的平台证据来自模拟器，不能替代这些体验。
- Windows 实际读屏、右键连续操作、多个真实宿主窗口间的焦点切换，以及桌面悬浮窗 Acrylic/阴影/连续拖动与缩放流畅度。已有宿主服务与布局测试通过，不等于此轮真实悬浮宿主体验验收。
- 搜索无结果/失败、附件选择/裁剪与系统文件窗口、同步备份清理的完整界面专项；相关基础组件及仓储测试通过，但未逐项走完所有 UI 状态。
- 业务界面全部“六套配色 × 明暗 × 尺寸 × 失败/空态/加载/大字号”的人工矩阵尚未穷举；六套配色的完整矩阵目前覆盖共享组件。已查看的业务预览采用经典蓝明暗，不扩大表述为所有组合通过。

新增功能应先运行组件展示和边界检查；迁移清单的人工项完成后逐项记录平台、场景与结果，不以更新基线代替验收。

### 2026-10-08 安卓开始记录面板验收

- 首页和时间页共用半屏/全屏底部面板；13 项专项回归覆盖拖拽、反向接管、输入保留、键盘避让、旋转、大字号、关闭保护、失败重试和实际保存。最终 9 个相关测试文件合计 **92 项通过**，包含 Windows、补记及结束记录回归。
- `flutter analyze --no-pub` 与 UI 样式检查通过；当前 41 项既有受控例外，无新增绕过入口。独立内存预览宿主 Android Debug APK 构建通过。证据：`output/start-sheet-tests.log`、`output/start-sheet-analyze.log`、`output/start-sheet-build.log`。
- 已查看真实中文半屏、全屏、明暗、大字号和横屏键盘预览；PNG 位于 `output/start-sheet-preview/` 与 `output/start-sheet-android-*.png`，未更新既有 Golden。
- API 36 模拟器使用独立 `dev.omnibutler.ui_preview` 内存包验证上拉/下拉、输入、返回和半屏提交，确认活动与描述跨状态保留并保存；结束后已卸载预览包并恢复键盘显示设置。实体设备中文输入法、读屏与拖拽手感仍待人工验收。
- 同日按截图反馈收紧开始按钮：蓝色视觉高度从 48px 调至 32px，保留原字号、水平间距及 48px 触控热区。后续 20 项相关回归、静态分析及样式检查通过，并重新查看中文半屏预览；证据：`output/start-sheet-button-tests.log`、`output/start-sheet-button-analyze.log`、`output/start-sheet-preview/android-half.png`。本次尺寸微调未重复运行模拟器。


## 2026-10-08 安卓补记全屏布局

- 右上角保存采用主题主色实底与白色文字，复用 Omni 主按钮的禁用/加载规则。补记专项 36 项、定向 analyze 和样式检查通过，浅/深色中文预览已查看（`output/backfill-save-color-tests.log`）。
- 时间合法性错误在滚轮上方替换“调整开始时间/调整结束时间”，不在滚轮下重复展示；恢复有效区间后恢复正常提示。补记专项 36 项回归、定向 analyze 和样式检查通过，错误态中文预览已查看（`output/backfill-error-position-tests.log`、`output/backfill-fullscreen-preview/android-invalid-time.png`）。
- 首页、时间页菜单及时间轴预填补记采用覆盖根导航的全屏弹窗，顶部固定取消/补记/保存，灰色总时长按小时显示；表单为时间与活动/类别/备注两组圆角卡片。
- 复用既有分钟滚轮、跨天日期、类别颜色、默认空闲段及保存逻辑；提交时禁止返回，失败保留草稿可重试。修复字号变化引发滚轮像素偏移误改时间的问题。
- 7 个相关测试文件共 **72 项通过**，补记专项中文预览 **36 项通过**；浅色、深色、安全区、类别菜单和双倍字号键盘截图已查看。未更新既有 Golden。
- 全量 `flutter analyze --no-pub` 和 UI 样式检查通过。新增一处精确限定的 `Dialog.fullscreen` 例外（共 42 项），原因是顶部固定操作与总时长的专用全屏结构；仍经 `showOmniDialog` 路由并复用 Omni 控件/主题。
- 证据：`output/backfill-fullscreen-tests.log`、`output/backfill-fullscreen-preview.log`、`output/backfill-fullscreen-analyze.log`、`output/backfill-fullscreen-style.log`、`output/backfill-fullscreen-preview/`。本轮未构建安装 APK，实体设备输入法/读屏/手感待验。

## 2026-10-08 安卓首页平铺分页

- 仅 Android 紧凑首页改为顶部名言、文字下划线标签和独立 `PageView`。待办、时间、脉络及重新启用后的刻度平铺显示；沿用完整业务内容、计时弹窗、悬浮操作与五个底栏入口。
- 模块按 `HomeCardId` 保留身份、纵向位置与交互状态；会话内记住当前模块，冷启动从已有偏好的首个可用模块开始。横滑首尾不接力一级导航，顶部和空态也隔离一级横滑。
- 首页设置将名言独立为顶部开关，内容增删排序继续使用 `home.cards.order`，不迁移或重置隐藏状态。标准视口顶部固定；短屏/大字号下顶部可以滚出，标签停在正文上方，名言保持自然尺寸。
- 19 个相关测试文件共覆盖 **139 项**：集成首轮 137 项通过；另两项分别是旧测试对固定标题按钮调用 `ensureVisible` 引发横向偏移，以及预期的 Android 首页视觉变化。修正定位方式并审查候选图后，失败业务项与全部 3 项首页 Golden 定向复测通过。未变更其他业务断言，未刷新桌面基线。证据：`output/home-mobile-regression.log`、`output/home-mobile-fixed-test.log`、`output/home-mobile-golden-verified.log`。
- 专项覆盖真实横滑/连续反向/斜向拖动、首尾/单页/空态、隐藏/新增末页/重排、底栏返回、展开和图例保留、末项避让、360px 深色、短屏/双倍字号、视口模式往返以及 Windows 原布局。共享组件和原导航、时间记录、进度待办回归包含在上述集合中。
- 最终审查另补充 2 项悬浮按钮起手横拖回归：主按钮与菜单区域原先都会误切一级页，已将安卓首页整个 `Scaffold` 纳入水平手势边界；修后两个区域横拖均留在首页，正常点按仍打开原面板/菜单。纯手势消费层设置 `excludeFromSemantics`，避免“开始记录”读屏节点扩大到整个首页；新增真实语义节点尺寸检查，修前宽度 390 超过 FAB 的 129.2，修后恢复正常。首页分页整文件 14 项通过，合计涉及 141 项不同回归；证据：`output/home-fab-swipe-before.log`、`output/home-fab-swipe-after.log`、`output/home-fab-semantics-before.log`、`output/home-mobile-dashboard-semantics-final.log`。
- `flutter analyze --no-pub`、UI 样式检查（42 项既有受控例外，无新增绕过）及 `git diff --check` 通过。日志：`output/home-mobile-analyze.log`、`output/home-mobile-style.log`。
- 中文业务预览 4 组生成测试通过，共 44 张；本轮逐图审查 Android 待办/时间/脉络/首页设置的明暗两套，以及 Windows 首页明暗两图。其余页面仅复用原预览生成，不扩大人工验收结论。入口：`tool/ui_pages_preview_test.dart`；图片：`output/ui-pages-preview/`。
- Android API36 模拟器采用独立 `com.omnibutler.homepreview` 内存测试包，复用生产首页、路由与业务仓储；构建和操作证据位于 `output/home-mobile-runtime/`，操作明细见该目录 `verification.md`。此包只用于验收，不是正式升级包。
- 本轮未连接 Android 实体设备；实体设备连续拖动手感、中文输入法与读屏体验仍待人工验收。

## 2026-10-08 安卓首页工具栏与设置入口调整

- 删除 Android 紧凑首页最上方“今日工作台／首页设置”整行，名言直接位于顶部并保留原有尺寸及操作。首页空态仍保留恢复模块的设置入口。
- 底栏“更多”改为“设置”，未选中与选中状态均使用齿轮图标；“首页设置”位于设置页第一组，沿用现有模块管理器和本机偏好。其余平台及宽屏布局保持原有行为。
- 8 个相关文件共 50 项测试通过，覆盖入口完整路径、修改偏好、返回首页保留当前分页、导航手势、短屏/双倍字号及桌面首页；仅更新 Android 首页受影响的视觉基线。日志：`output/home-header-settings-verified.log`。
- 全量静态分析及样式检查通过，中文预览 4 组生成通过，共 44 张，审查 Android 首页、设置主页及首页设置浮层的明暗外观。证据：`output/home-header-settings-analyze-final.log`、`output/home-header-settings-style-final.log`、`output/home-header-settings-preview.log`；图片：`output/ui-pages-preview/`。
- 额外每日待办 Golden 检查有 4 张基线不匹配（桌面浅/深色四象限、移动四象限、完成提示），差异位于本次未改动的待办行和提示内部，未刷新这些基线；日志：`output/home-header-settings-final-tests.log`。本次入口调整未重做 Android 模拟器包验收，上一节运行包和截图仅对应调整前版本。
