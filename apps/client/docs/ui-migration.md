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
| `/todos`；`lib/features/todos/presentation/todos_page.dart`、`todo_mobile_dashboard.dart` | 进行中四象限、单象限聚焦、父子任务树、完成历史；移动端状态恢复、完成/撤销、进度操作；桌面拖拽/移动 | Windows 宽/窄窗、Android 紧凑/宽屏 | Android 紧凑使用完整文字下划线导航、父任务数量角标、平铺分组和独立分类分页；首尾/顶部/FAB不接力一级页；历史为保活进行中的本地二级页，顶部/系统返回恢复原位置。任务行、进度、历史与仓储复用原实现，其他布局保持 | `todo_mobile_dashboard_test.dart`、`todo_quadrant_ui_test.dart`、`android_primary_navigation_swipe_test.dart`、`todo_progress_entrypoints_test.dart`、`todo_quadrant_golden_test.dart` | 本轮最终证据见文末；既有无关桌面Golden滞后不在更新范围 |
| `/timeline`；`lib/features/timeline/presentation/timeline_page.dart`、`timeline_review.dart` | 复盘/明细、日/周/月指纹、分类结构/趋势、日时间轴、进行中记录；冲突提示、补记/结束、跨日记录 | Windows 宽/窄窗、Android | 共享模式/周期滑块及日期导航；Android周期菜单和原有悬浮拆分按钮；指纹轻量化与明细浅色块，保留统计和表单业务 | `timeline_layout_test.dart`、`timeline_fingerprint_test.dart`、`timeline_editor_test.dart`、`timeline_android_ui_test.dart`、`time_entry_interval_test.dart` | 自动化通过；人工矩阵待验 |
| `/events`；`lib/features/events/presentation/events_page.dart` | 事件列表/卡片、状态筛选、归档、周期提醒；记录完成、历史、撤销 | Windows 宽/窄窗、Android 管理聚合 | 页面与编辑器接共享主题、表单、按钮、菜单、开关、日期时间；保留事件业务状态色 | `events_layout_test.dart`、`management_compact_cards_test.dart`、`business_repositories_test.dart` | 自动化通过；人工矩阵待验 |
| `/inventory`；`lib/features/inventory/presentation/inventory_page.dart` | 物品卡片、搜索/分类/位置/状态筛选、统计、详情、配套物品、批量迁移；继承位置、附件状态 | Windows 宽/窄窗、Android 管理聚合 | 通用控件接 Omni；详情卡和统计图保留专用布局；详情翻转及新增拆分菜单列为专用浮层 | `inventory_layout_test.dart`、`inventory_move_dialog_test.dart`、`management_compact_cards_test.dart` | 自动化通过；人工矩阵待验 |
| `/memberships`；`lib/features/memberships/presentation/memberships_page.dart` | 会员卡片、搜索/类别/状态筛选、支出统计、到期时间轴、缴费历史；永久/到期/续费/提醒状态 | Windows 宽/窄窗、Android 管理聚合 | 共享面板、表单、日期、开关、菜单和消息；会员状态信息/图表维持业务语义 | `memberships_layout_test.dart`、`management_compact_cards_test.dart`、`business_repositories_test.dart` | 自动化通过；人工矩阵待验 |
| `/settings`；`lib/features/settings/presentation/settings_page.dart` | 首页设置、功能管理、外观与主题、通知提醒、数据同步、回收站；Android 概览→详情→返回；断开/重连/清空/恢复状态 | Windows 宽/窄窗、Android | Android 六色入口图标，首页设置两端实底分组；同步连接、备份、断开操作独立分组，窄屏整行排列；保留既有设置导航与危险操作边界 | `settings_layout_test.dart`、`home_mobile_settings_test.dart`、`theme_settings_test.dart`、`feature_preferences_test.dart`、`android_settings_transition_test.dart`、`sync_connection_dialog_test.dart` | 自动化与中文明暗预览通过；人工矩阵待验 |
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
| D11 | `_AbsoluteTimeEntryDialog`；同上；`time_entry_time_picker.dart` | 半屏/全屏开始记录、完整补记/编辑、结束进行中、Android五分钟滚轮/跨日日期、时间冲突、类别逐项颜色、备注折叠 | Android 开始记录使用 Omni 可展开底部面板，横线独立拖拽/点击，顶部固定取消/开始；半屏只显示活动和类别，全屏才增加开始时间与描述，收起保留输入，键盘避让不改变展开状态；提交期间锁定关闭/拖拽。Android 新增补记与已完成记录编辑共用 OmniFullscreenFormScaffold 根导航全屏弹窗，顶部固定取消/居中业务标题/保存和灰色小时摘要，正文以时间卡片及活动/类别/备注分组呈现，保存期间保护返回、失败保留草稿；补记/已完成编辑保留 Android 双列时分滚轮与 Windows 精确输入/双手柄、连续跨日扩展、占用边界阻挡回弹和默认最近空闲段；共享日期/表单/下拉保留类别左侧色点；结束流程保留原遮罩关闭限制 | `start_time_entry_sheet_test.dart`、`time_entry_dialog_test.dart`、`time_entry_interval_test.dart`、`timeline_android_ui_test.dart`、`timeline_editor_test.dart`、`windows_dialog_enter_save_test.dart` | 自动化、真实中文截图及 API 36 独立包交互通过；实体设备手感/读屏待验 |
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
| D22 | `_SyncConnectionDialog`；`lib/features/settings/presentation/sync_connection_dialog.dart` | 连接表单→数据处理预览、保留/替换策略、返回、提交中不可关闭、失败 | Windows 统一侧栏，Android 补记同款根导航全屏容器；统一表单、单选、图标和按钮，顶部固定操作、正文键盘避让、确认文案完整呈现；保留两阶段确认与 `PopScope` | `sync_connection_dialog_test.dart`、`settings_layout_test.dart`、`sync_connection_coordinator_test.dart` | 自动化与中文明暗预览通过；人工矩阵待验 |
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
| 移动新增拆分菜单 | 事件、时间页使用 `OmniSplitActionButton`；时间页菜单补记与分类，主操作开始/结束；物品仍有专用新增拆分菜单 | 点主按钮与菜单互不混淆、取消、菜单方向键、减少动效、屏边 | `timeline_android_ui_test.dart`、`events_layout_test.dart`、`inventory_layout_test.dart` | 自动化通过；人工矩阵待验 |
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
- 时间指纹标签按类别背景亮度选择黑/白前景并以真实像素空间控制显示，已移除固定浅灰颜色例外；时间页的两个原生分段按钮改为Omni共享滑块，对应例外一并移除。首页时间卡片仅保留空态“开始记录”的一处 `TextButton` 例外。

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

## 2026-10-08 安卓待办平铺分页与数量角标

- 仅 Android 宽度小于720改为分类文字下划线导航、连续背景和无卡片分组。完整标签可横滚，四分类右上角按进行中根任务树计数（只显示非零数量），子任务和完成历史不计入；全部不加角标。空组在全部页压缩为一行，单分类仍有空态与添加入口。
- 独立PageView只平移，首尾、顶部、空白和悬浮按钮隔离一级横滑；五分类各自保留纵向位置，父任务展开状态共享。历史为待办内二级页，保活进行中子树，顶部与系统返回恢复原分类和位置，日期在同一会话保留；窄屏大字号改完整短日期或分两行。任务树、进度、编辑器、完成反馈和历史操作沿用业务实现。
- 四个相关测试文件共 **38项通过**，覆盖320/360/390、短屏、双倍字号、明暗、连续反向/快滑/连续点按、边界隔离、分类/树/历史状态、路由分类、减少动画、根计数实时更新及读屏点击。另两项Android目标Golden定向复测通过，合计40项；只更新两张AndroidPNG。原有桌面浅/深色四象限与完成提示3张基线仍有既知差异，未刷新桌面PNG。证据：`output/todo-mobile-final-tests.log`、`output/todo-mobile-final-golden.log`、`output/todo-mobile-golden-before.log`。
- 全量`flutter analyze --no-pub`、UI样式检查（42项既有受控例外，无新增绕过）、定向格式检查和`git diff --check`通过。明暗Android中文预览生成通过，已审查全部、单分类及历史；图片在`output/ui-pages-preview/`。日志：`output/todo-mobile-final-analyze.log`、`output/todo-mobile-final-style.log`、`output/todo-mobile-final-preview.log`。
- API36模拟器使用独立`com.omnibutler.todopreview`内存包，复用真实生产页面、路由与仓储；已验证分类点击/正文双向和边界、顶部/FAB隔离、共享折叠、进度推进、父子完成与历史重新打开、日期保留/返回、底栏滚动恢复、新增编辑器与末项避让。新增角标复测确认子任务完成数量不变、父任务完成减1、历史重开恢复；320dp短屏双倍字号日期完整显示并可系统返回。
- 模拟器额外发现启动零宽视口的标签滚动会被隐藏Ticker冻结，首次进入后恢复旧动画并隐藏全部标签。已跳过零宽、废弃过期回调，并在目标已可见时取消旧动画；新增回归修前复现52.2px偏移，修后通过，真实引擎冷启动也保持offset=0。证据：`output/todo-mobile-tabs-startup-before.log`、`output/todo-mobile-runtime/badge-scroll-stack-logcat.txt`、`output/todo-mobile-runtime/60-final-cold-todos-all.png`；详细操作/构建与清理记录见`output/todo-mobile-runtime/verification.txt`。
- 本轮未连接Android实体设备；实际TalkBack、中文输入法与滑动手感仍待人工验收，模拟器证据不涵盖正式认证/同步、通知或发布签名。
- 同日按追加反馈隐藏数量为0的顶部分类角标，同时移除其宽度预留；数量从0变为1、完成最后一项变为0、重新打开变为1的真实订阅回归通过。两文件24项相关回归、2项AndroidGolden、静态分析及样式检查通过；明暗中文预览已重新生成并审图，只再次更新进行中Android基线。证据为`output/todo-zero-badge-*.log`；本次小幅调整未重新构建或运行模拟器，前述模拟器APK/截图对应隐藏零角标之前的版本。

## 2026-10-08 安卓管理平铺与下拉统计

- 仅 Android 宽度小于720dp改造事件、会员、物品三分区：连续主题背景、文字短下划线导航、平铺记录与行间细线；保留原业务字段、右下角新增和管理菜单。物品图片64dp、标题最多两行，行高随内容增长；桌面及Android宽屏保持原布局。
- 管理宿主按 `ManagementSection` 保持独立PageView身份，三条路由仍共用原页面身份；保活搜索、已应用筛选、业务展开和纵向位置。横滑首尾、顶部及悬浮操作停留管理内，底栏负责离开。标签、外部路由、功能开关与分页双向同步；离开期间中断动画，恢复时对齐稳定分区。
- 共用摘要容器默认一行胶囊，仅摘要、展开标题和底部把手可以拖动面板。展开使用原分页弹簧，逐帧同步面板高度、正文平移及0至0.32的遮罩；正文视口尺寸保持不变。完整统计按自然内容定高，上限为可用高度70%，详情独立滚动；快速反向拖动可接管动画，减少动画时点击直接落位。统计展开期间隔离背景触控、键盘焦点和读屏语义，并隐藏悬浮操作；遮罩、系统返回、分区或底栏切换均可收起。
- 三页常驻搜索和独立筛选按钮；事件新增名称、描述搜索。筛选改为底部草稿面板，重置只改草稿，应用统一提交，返回或遮罩取消；已应用条件可逐个移除。短屏、双倍字号和实际键盘inset下空结果可滚动，搜索输入时隐藏悬浮操作以保留清除入口。
- 统计使用当前分区全量数据，不受搜索筛选影响。事件保留近期应做、超期及七天分布、状态和月度完成比较；会员保留月度/年度支出、支付次数、趋势与三天自动续费；物品保留主物品和配套数量、购入总值、状态比例和分类价值。复用原日期与金额口径，加载失败与零数据分别显示，支持重试；无数据库、服务端或仓储接口变更。
- 12个相关测试文件统一 **74项通过**，覆盖三页业务、搜索筛选、状态保留、真实拖动中间帧、反向接管、取消、返回、减少动画、短屏双倍字号、键盘空态、桌面管理和首页回归。9张管理Golden经审查后更新，包含三页收起、展开及筛选，未刷新桌面基线。证据：`output/management-final-tests.log`。
- 最终语义审查另补3项回归并先红后绿，两个完整测试文件19项通过，累计77项不同相关回归通过。管理根、摘要外层及遮罩移除无用左右滚动语义，保留独立按钮边界以及把手/遮罩的读屏点击收起。证据：`output/management-semantics-{red,green,full}.log`；实际问题为多余滚动操作，未复现按钮读屏边界扩大。
- 最终明暗中文预览生成 **2项通过**，已审查三页平铺、展开统计、详情滚动和筛选；中文预览位于 `output/ui-pages-preview/android-{light,dark}-390-{events,memberships,inventory}*.png`，测试字体Golden仅用于结构回归。证据：`output/management-final-preview.log`。
- 全量静态分析、UI样式检查及 `git diff --check` 通过；样式仍为42项既有受控例外。共用底部面板经 `showOmniModalBottomSheet` 入口统一主题及减少动画。证据：`output/management-final-analyze.log`、`output/management-final-style.log`。
- API36模拟器使用纯内存业务数据、生产页面及路由，专用包 `com.omnibutler.managementpreview` 已验证三页统计、内部滚动、系统返回、筛选应用/取消、首尾隔离、展开时标签切换、分区/底栏状态恢复，以及320dp短屏双倍字号。最终语义版APK重新构建安装后冷启动、下拉和返回烟测通过，功能和最终运行日志无Flutter异常或溢出。测试入口为 `test/support/management_mobile_runtime_smoke.dart`，详细证据见 `output/management-mobile-runtime/verification.txt`。
- 验收后已卸载测试包、清理设备临时文件并恢复分辨率/密度/字号；正式包版本与安装时间元数据前后一致。设备原输入法为浮动模式，真实输入及返回关闭已验证；停靠键盘inset行为由Widget测试覆盖。实体设备连续拖动手感、中文输入法候选窗和实际TalkBack需单独验收。
- 同日按追加反馈，会员和物品移动平铺行移除可见更多按钮，改为整行长按打开原操作菜单；读屏长按也能打开。会员续费移到名称行右侧，沿用非自动续费、非永久会员的显示条件；物品配套入口及数量移到名称行右侧，仅有配套时显示，取消底部重复入口，无配套时仍可通过长按菜单管理/新增配套。桌面按钮保持原布局，菜单项与业务回调共用。
- 追加调整的7个相关文件 **36项回归通过**，覆盖快捷按钮位置和48dp触控区域、触屏/读屏长按、会员续费和支付历史、配套详情及空配套、旧点击/搜索/筛选/导航、窄屏双倍字号和桌面布局。审查后更新会员/物品6张目标Golden，9张管理基线最终通过；静态分析、样式检查（仍42项既有例外）、定向格式及diff检查通过。证据：`output/management-row-actions-{tests,analyze,style}.log`。
- 追加调整的明暗中文预览2项生成通过，已查看会员/物品常态和长按菜单，新增 `android-{light,dark}-390-{memberships,inventory}-more.png`；预览夹具补充一个配套，用于实际查看右上角按钮。证据：`output/management-row-actions-preview.log`、`output/ui-pages-preview/`。本次入口调整未重新构建或安装模拟器APK，前述模拟器包证据对应追加调整前版本。


## 2026-10-08 Windows 首页入口迁移与 Android 首页设置统一

- Windows 首页移除“今日工作台／管理卡片”整行，并把释放的高度交还给卡片网格；管理入口位于“设置 → 首页设置”。完整卡片增删排序及首页空态恢复入口继续共用原偏好，其他平台宽屏工具栏保持既有行为。
- Android 紧凑首页设置由侧滑面板改为设置分类二级页，复用通知提醒的居中标题、返回按钮、主题背景和持久底栏；横幅、已添加模块与可添加模块使用统一实底圆角列表及分隔线。名言独立开关、内容排序和功能依赖条件继续沿用 `home.cards.order`，功能管理入口在设置内直接切换分类。
- 9 个相关测试文件共 **63 项通过**，覆盖 Windows 入口迁移及配置保存、网格缩放/滚动、Android 名言开关与增删、真实连续拖拽与键盘排序、360 小屏 1.5 倍字号明暗主题、系统返回、底栏状态及既有设置分类。仅更新两张受影响的 Windows 首页 Golden；Android 首页 Golden 保持不变。证据：`output/home-settings-final-tests.log`。
- 全量静态分析、样式检查（43 项既有受控例外）和 `git diff --check` 通过。证据：`output/home-settings-final-analyze.log`、`output/home-settings-final-style.log`。中文业务预览四组生成通过，逐图检查 Windows 首页/首页设置及 Android 首页设置首屏/底部的明暗外观，图片位于 `output/ui-pages-preview/`。本轮未构建或安装运行包，实体设备交互手感未验收。

## 2026-10-08 Android 会员与物品记录布局优化

- 按用户参考图调整Android小于720dp管理记录行：物品图片由64dp增至96dp，名称与浅色状态标签在上方，位置/数量和使用时长/价格分别在底部左右排列；自然行高随内容增加。
- 会员图标旁分层展示名称、浅色状态标签和中性色分类描述，价格及周期优先在右侧同排；进度条下起始日期、剩余时间和到期日期优先左中右分列。按实际字体宽度判断价格排布，窄屏、长金额及大字号保留完整信息并换行。
- 保留整行触屏/读屏长按原菜单、原手动续费条件和有配套时的快捷入口；大字号下配套按钮空间不足时换行靠右。桌面、仓储、统计口径及业务回调沿用现状。
- 37项相关回归通过：6文件27项最终运行、追加1项320dp双倍字号长金额与续费、9项管理导航；覆盖320/360/390dp、短屏、自然增高、旧操作流程与桌面布局。9张管理Golden最终匹配，审查后仅更新会员/物品6张基线，事件3张内容保持相同。证据：output/management-row-layout-{final-tests,long-price-tests,navigation,golden-update}.log。
- 全量静态分析无问题、样式检查通过（43项既有受控例外）、定向格式和diff检查通过。真实中文明暗预览2项通过，已查看两页明暗常态；图片位于output/ui-pages-preview/android-{light,dark}-390-{memberships,inventory}.png。证据：output/management-row-layout-{analyze,style,preview}.log。本轮未重新打包安装，实体设备与实际TalkBack未复验。
- 扩展运行还发现设置页的既有“Android 更多页展示分组设置并支持二级返回”测试查找旧group-features标识；HEAD设置页已在首页设置迁移后改为group-home，源码与本轮无关。记录至agent_memory/bugs.md，未修改设置页或其旧测试；其余9项管理导航定向运行通过。

## 2026-10-08 设置界面与同步操作布局

- Android 六个一级入口补齐图标，分别使用蓝、青、紫、橙、绿、红语义色并适配明暗主题。删除首页设置排序和立即保存的常驻提示，Windows 已添加、可添加及空态补上实底圆角分组，保留完整卡片顺序和持久化键。
- Android 连接服务器沿用补记的根导航全屏弹窗、安全区与固定顶部操作；两侧按文字实测宽度保持标题居中，窄屏及大字号操作换行。正文避让键盘，返回修改保留草稿；预检和提交期间禁止返回、取消与重复提交，数据处理策略和实际连接仍由原协调器负责。
- 数据同步将连接操作、迁移备份、断开分组，桌面左对齐横排，窄屏及大字号整行纵排；按钮32px视觉高度、Android48px热区有实际尺寸断言。
- 9个相关测试文件共 **87项通过**，覆盖两端首页卡片真实拖动、增删与键盘排序、Windows1200/512与Android390/320双倍字号的同步四状态、全屏连接键盘避让/草稿/预检/确认/防重、主题和回收站回归。证据：`output/settings-final-tests.log`。24张中文明暗预览生成，主要入口、卡片、表单及同步常态/离线布局已审图；图片位于`output/settings-preview/`，生成记录`output/settings-preview-final.log`。
- 样式检查通过，新增一项有明确理由的Android全屏容器例外；源码颜色、尺寸和控件继续复用Omni。未构建安装包，实体设备输入法、TalkBack与交互手感仍待人工复验。

## 2026-10-08 首页设置、Android 主题选择与回收站细化

- 两端首页设置移除顶部横幅、已添加和可添加标题右侧的数量；卡片开关、增删与排序逻辑沿用原实现。
- Android 外观页将主题色收为可点击的当前配色入口；复用 Omni 弹窗展示六种主题的完整名称、色块与选中标记，选择即时保存，关闭或系统返回不改偏好。Windows 页面内选择器保持原有呈现。
- Android 回收站保留期说明独立一行，一键清空靠右；每条记录的恢复和永久删除均靠右，窄屏大字号允许自然换行。仓储、保留期、确认与操作防重逻辑保持原规则。
- 4个相关测试文件共 **55项回归通过**，覆盖两端数量移除及原卡片排序、六款主题即时保存与取消、实际全局主题切换、回收站布局和真实恢复/清空。证据：`output/settings-refinement-tests.log`。中文预览生成另有8项设置与10项回收站通过，21张明暗PNG位于`output/settings-refinement-preview/`；已检查两端首页、Android主题入口/弹窗、回收站及320dp双倍字号主要界面。生成记录：`output/settings-refinement-preview.log`、`output/settings-refinement-recycle-preview.log`。
- 全量静态分析无问题，UI样式检查通过（42项受控例外，无新增），定向格式与diff检查通过。证据：`output/settings-refinement-analyze.log`、`output/settings-refinement-style.log`。本轮未打包安装，实体设备触控与TalkBack尚未复验。

## 2026-10-08 Windows / Android 时间管理界面重整

- 默认周复盘和原统计口径保持；移除重复大标题与四列统计面板，只将完整自然周期覆盖率放在指纹标题旁。宽屏导航/直接记录操作和周期/日期分层，窄Windows窗口整组换行不隐藏；Android紧凑顶部使用模式滑块和周期选择器，底栏上方直接提供补记、开始/结束及分类菜单，正文按操作组实际高度动态避让。
- 指纹保留类别原色、真实横向坐标、短段最小宽度及原点击范围，弱化底轨/刻度，垂直内缩2px并使用共享小圆角，标签按真实字体空间和类别背景对比度显示；月历保留结构且大字号允许日期格自然增高。类别结构/比较/趋势内容与宽屏布局沿用。明细保持24小时真实比例与记录清单，浅类别底色/原色侧线/主题文字、紧凑摘要保留已记录和空白时长；短块完整信息由提示和清单提供。记录表单、仓储和公开业务接口未改。
- 9个相关测试文件共 **92项回归通过**，包含开始/补记/结束/分类、普通和冲突进行中、模式/周期/日期导航、缩放状态、末项避让、短段点击/连续区间/跨午夜/空数据、六套主题明暗标签对比度，以及原趋势、时间区间与表单回归。Windows覆盖1440/1024/640/512；Android覆盖390/320双倍字号/719/720。证据：`output/timeline-redesign-final-tests.log`。
- 仅审查更新时间页3张Golden并在最终回归中复测通过。真实中文明暗预览4项生成通过，16张Windows/Android日/周/月/明细PNG已人工审图，预览脚本显式断言各周期，避免误点月历星期标签。图片：`output/timeline-redesign-preview/`；证据：`output/timeline-redesign-final-preview.log`、`output/timeline-redesign-final-visual.log`。
- 全量`flutter analyze --no-pub`、UI样式检查、定向格式检查及`git diff --check`通过；移除时间页原生分段按钮和指纹固定灰色两项许可，当前41项受控例外。证据：`output/timeline-redesign-final-{analyze,style}.log`。已同步`style.md`和任务记忆；未运行全仓自动修复lint。
- 本轮未重新打包安装或复验实体设备触控/TalkBack。320dp双倍字号完整应用暴露隐藏预载首页的既有溢出（`home_page.dart:1160`），未扩大修改；该尺寸时间页通过独立生产页面验证日/周/月、明细和动态避让，其余尺寸使用真实应用路由。该隔离结果不代表320dp双倍字号全应用无溢出。

## 2026-10-08 Android时间页按钮与周期菜单追加调整

- 按反馈恢复原OmniSplitActionButton外观与三横线菜单：主操作为空闲时开始、进行中结束记录；菜单依次为补记时间与分类。保留实测按钮高度的正文避让，Windows和Android宽屏沿用直接操作组。
- 周期菜单仅选中项绘制勾，其余项在同一16px图标位置留空，文字保持对齐；切换后勾同步更新。OmniPopupMenuItem允许显式空图标，原有传图标调用方保持行为。
- 4文件33项回归通过，覆盖原主操作/菜单流程、普通和冲突进行中、周期空位及切换、320dp双倍字号/719/720与Windows边界、末项避让、共享下拉及开始表单。只更新Android时间页1张目标Golden，桌面两张复测保持匹配；证据output/timeline-action-refinement-final-tests.log和timeline-action-refinement-golden.log。
- 中文明暗预览4项生成通过，补充Android周期菜单两张，共18PNG，已审查按钮及菜单明暗外观；图片output/timeline-redesign-preview/，证据output/timeline-action-refinement-preview.log。全量静态分析无问题，样式检查42项受控例外通过，定向格式与diff检查通过；证据output/timeline-action-refinement-{analyze,style}.log。本轮未打包安装或复验实体设备。

## 2026-10-08 安卓新增会员、物品、事件及一键搬家

- 新增 `OmniFullscreenFormScaffold` 及实底分组、外置标签行、保值折叠组件。仅 Android 新增会员、主物品和事件经根导航打开全屏表单，固定取消、居中标题及主题色底白字保存；空间不足时标题与操作分行。正文独立滚动，避让安全区和键盘，首次打开不自动聚焦。编辑、配套新增、其他平台及现有补记/待办保持原呈现。
- 名称、分类和主要业务字段默认展示；会员的描述/平台/官网、物品的平台/链接/保修/备注、事件的说明/备注默认收起。完整草稿校验会展开并定位错误字段，折叠与失败均保值；提交冻结正文并拦截返回和重复操作，成功退出前保持锁。普通保存异常使用正文顶部行内错误，可立即原样重试。
- Android 一键搬家各宽度统一选择物品、确认迁移两步；目标在迁移清单之前，保留位置管理及移除。摘要统计自动跟随配套的记录数和件数；系统返回或上一步保留选择，取消退出。加载/空态/读取错误仍有顶栏，读取失败可重试，目标失效与空选择禁用迁移；继承位置、同位置跳过及结果反馈沿用仓储规则。
- 4个专项文件 **33项通过**，桌面/Windows Enter/业务仓储3文件 **20项通过**，真实Android导航入口定向 **3项通过**，合计56项不同回归；安全区断言追加后共享3项复测通过。覆盖根导航遮盖、固定顶栏、取消/返回、折叠保值、完整校验定位、实际落库、错误立即重试、防重、搬家两步往返/自动配套/数量/失效目标/加载重试，以及旧编辑和配套入口。证据：`output/android-four-forms-{focused,compat,navigation,safearea}-tests.log`。未运行与本次无关且有已记录旧设置断言的整份管理导航测试。
- 预览工具 `tool/android_four_forms_preview_test.dart` 使用生产页面与隔离内存数据，8项生成通过，共24张中文PNG；已审查四弹窗明暗默认、补充展开/搬家确认，以及320dp双倍字号键盘场景。390和Android宽屏另有布局测试；六款主题明暗主操作普通/悬停/按下的白字对比度通过。图片在 `output/android-four-forms-preview/`，生成证据 `output/android-four-forms-preview.log`；未刷新任何Golden。
- `flutter analyze --no-pub`、UI样式检查（42项既有例外，无新增绕过）、定向格式及差异检查通过，保留开始前已有时间页/下拉/文档改动。本轮不构建或安装APK，实体设备中文输入法、TalkBack及键盘动画尚未验证。320dp双倍字号采用独立生产页面验证，本次不扩大修复隐藏预载首页的既有溢出，不据此宣称整应用该尺寸通过。

## 2026-10-09 安卓条目按下动画统一

- 范围为4个界面、8类已有长按条目：待办普通父任务、子任务、进度任务，首页相同三类，紧凑管理的物品行、会员行。3套手势封装接入共享OmniPressSurface；首页与待办覆盖Android宽屏，物品/会员只覆盖原有紧凑长按入口。
- 从实际触点开始280ms固定圆心扩散，中性灰#808080浅色4%至12%、深色6%至18%；120ms缩至98%。视觉变换不改变占位和子控件命中。释放/滚动取消/菜单打开后180ms恢复，保留当前扩散半径淡出，重复释放幂等；禁用和卸载清理动画，减少动画只有即时静态灰色。
- 原点击、长按菜单、语义与行内完成/续费/配套操作保持。旧按下highlight只在接入条目的Android分支关闭；OmniListRow新增可选highlightColor且保留原默认值。全局NoSplash和桌面悬停/右键/键盘菜单继续沿用原行为。新增代码遵循中文注释要求。
- 10个测试文件共94项不同回归通过：共享22项、真实页面紧凑/宽屏与明暗4项、原业务及桌面兼容8文件68项。共享像素回归覆盖偏心扩散、逐渐加深、释放不倒放、圆角、缩放后原区域命中；真实手势覆盖短按、菜单、双向滚动取消、连续按下、多指、禁用/卸载、减少动画与辅助服务导航。恢复重复计时回归先红后绿。
- 中文预览另运行相同4组页面检查，生成112张完整页面采样，4张对照拼图已人工审查，位于output/android-press-preview/。紧凑布局8类、宽屏6类均含未按下、60ms、280ms、恢复后；保留原始PNG和条目坐标JSON，不修改Golden。图标和中文字体仅预览模式加载本机资源。
- flutter analyze --no-pub无问题；UI样式检查42项既有例外无新增，定向格式与diff检查通过。证据：output/android-press-{component,entrypoints,existing}-tests.log、android-press-{preview,analyze,style}.log。本轮未构建或安装APK，Android实体设备手感与TalkBack仍待人工验收。
- 追加长按菜单振动：OmniPressSurface在Android触屏长按触发原菜单前请求一次系统LONG_PRESS触觉反馈，不等待平台返回，保留菜单弹出时机；短按、取消、禁用、松手不振动，减少动画仍保留触觉反馈。共享组件与真实页面2文件30项回归通过，新增4项覆盖Android/Windows与减少动画开关、触发顺序和单次振动。证据：output/android-press-haptic-tests.log；实际振感待Android实体设备验收。

## 2026-10-09 安卓编辑时间记录与补记统一

- Android已完成记录编辑复用补记的根导航全屏路由、灰色小时摘要和时间/活动/类别/备注分组，标题保留“编辑时间记录”，保存仍为主题底白字。
- 两种入口复用OmniFullscreenFormScaffold固定顶栏，长标题在窄屏大字号下与操作分行；原始分钟、类别、已有备注和按原ID保存保持一致。Windows与进行中编辑沿用原流程。
- 4个相关测试文件 **57项通过**；定向分析与样式检查通过，删除时间页不再使用的Dialog例外，现为41项。中文普通编辑与双倍字号键盘预览已审查，未更新Golden。
- 证据：`output/time-entry-edit-tests.log`、`output/time-entry-edit-entrypoints-tests.log`、`output/time-entry-edit-preview/`。本轮未构建安装APK，实体设备验收待进行。

## 2026-10-09 上次记录横幅与五分钟滚轮

- Android补记与已完成记录编辑共用常驻灰色横幅，格式为“上一次记录 · MM/dd HH:mm - MM/dd HH:mm · 事件名称”。按结束时间选择最近已结束的有效记录，排除当前编辑项、软删除、未来结束及进行中记录；与横幅记录重叠时只变红，文案不变。其他记录的冲突继续单独说明且禁止保存。
- 右侧接续按钮将开始日期和时刻设为上条实际结束，保留秒级边界及当前结束时间；接续产生无效区间时继续显示时间错误并禁用保存。无已结束记录常驻空态并禁用按钮。
- 分钟滚轮改为五分钟刻度，起止端及读屏增减共同采用00、05至55；打开和接续时保留非整五分钟值，用户手动调整分钟后进入固定刻度。Windows及开始/进行中/结束流程沿用原规则。
- 5个相关测试文件共 **75项通过**，定向分析与样式检查通过；真实中文补记/编辑、灰红状态、明暗及大字号键盘预览已查看。证据：`output/backfill-previous-entry-final-tests.log`、`output/backfill-previous-entry-preview/`。未构建安装APK，实体设备手感与TalkBack仍待验收。

## 2026-10-09 安卓首页模块导航与象限展开

- Android小于720的首页删除待办、时间、脉络及可选刻度页重复的模块标题行。导航改为待办同款圆角底槽与胶囊背景，选中模块展开图标及文字，其余模块仅图标；背景、项宽和文字展开随正文分页同步，保留完整读屏标签、48dp触控范围、系统字号和导航自身滚动。
- 待办子任务批量展开／收起移到每个象限标题右侧，仅处理该象限实际显示的全部可展开父项，无未完成子项时隐藏按钮；与单项展开联动，修复旧批量逻辑仍限制前三个父项的问题。桌面和Android宽屏沿用原展示。
- 6个相关测试文件 **68项通过**，覆盖标题删除、批量作用域、第四父项、数据更新隐藏、跟手与反向拖动、320dp双倍字号导航、减少动画、模块增删重排、滚动与展开保留。首页 **3项Golden通过**，仅更新Android紧凑基线；全量静态分析及样式检查通过。
- 首页隔离中文预览 **2项通过**，已查看明暗四模块及子任务展开／折叠截图。证据：`output/home-header-tabs-tests.log`、`output/home-header-tabs-golden.log`、`output/home-header-tabs-analyze.log`、`output/home-header-tabs-preview-scoped.log`，图片位于`output/ui-pages-preview/`。未构建安装APK，未做实体Android设备动效或TalkBack验收。
