# 统一 UI 入口与回归指南

本指南按页面、弹窗和控件定位源码及回归入口。路径均相对 `apps/client/`，测试名均相对 `test/`；列出的测试是复验入口，不代表当前工作区已执行或所有人工状态已验收。

## 盘点口径与统一基础

- 路由定义见 `lib/app/router/app_router.dart`，包括首页、待办、时间、笔记、事件、物品、会员、设置和助手；Windows 悬浮窗使用独立宿主，Android 管理与设置详情由各自容器协调。
- 下面列出常用业务弹窗和侧栏；同一组件的新增、编辑等状态合并说明，专用笔记界面见[笔记模块维护指南](notes-redesign.md)。
- 所有界面均需检查：正常、加载、空态、失败、禁用/只读、提交中、保存失败；只有相关界面才需构造对应状态，不能用空页面代替表单或列表验收。
- 主题矩阵为六套配色 × 浅色/深色，另验跟随系统切换；平台矩阵为 Windows 宽窗/窄窗、Android 紧凑布局、Windows 悬浮窗专用尺寸。
- 统一设计参数来自 `lib/app/theme/app_tokens.dart`，语义颜色和原生控件兜底来自 `lib/app/theme/app_theme.dart`；组件出口为 `lib/shared/ui/omni_ui.dart`，规范为仓库根目录 `style.md`。
- 基础输入、图标按钮、复选框、单选项已提供 `OmniTextField`、`OmniTextFormField`、`OmniIconButton`、`OmniCheckbox`、`OmniRadioListTile`；日期、时间、下拉、菜单、消息和弹窗复用现有 Omni 实现。

## 页面、二级界面与状态

| 入口与源码 | 必验界面/状态 | 平台 | 统一路径与平台约束 | 验证入口 |
|---|---|---|---|---|
| `/home`；`lib/features/home/presentation/home_page.dart`、`home_mobile_dashboard.dart` | 今日待办、事件关注、时间图例、名言/背景；模块隐藏/排序、完成/撤销、窗口缩放 | Windows 宽/窄窗、Android | Windows 保留卡片网格；Android 紧凑首页使用可随纵向滚动退出的顶部名言、选中项展开图标与文字的胶囊导航、横向平铺分页与独立正文滚动，首尾不接力一级导航；首页设置独立管理名言与内容顺序；业务控件与图表保留 | `home_mobile_dashboard_test.dart`、`home_mobile_viewport_test.dart`、`home_mobile_settings_test.dart`、`home_dashboard_test.dart`、`home_golden_test.dart`、`home_context_card_test.dart`、`home_window_resize_test.dart`、`home_todo_scroll_test.dart` |
| `/todos`；`lib/features/todos/presentation/todos_page.dart`、`todo_mobile_dashboard.dart` | 进行中四象限、单象限聚焦、父子任务树、完成历史；移动端状态恢复、完成/撤销、进度操作；桌面拖拽/移动 | Windows 宽/窄窗、Android 紧凑/宽屏 | Android 紧凑使用选中项展开文字的图标胶囊导航、非零父任务数量角标、固定历史入口、平铺分组和独立分类分页；首尾/顶部/FAB不接力一级页；历史为保活进行中的本地二级页，顶部/系统返回恢复原位置。任务行、进度、历史与仓储复用原实现，其他布局保持 | `todo_mobile_dashboard_test.dart`、`todo_quadrant_ui_test.dart`、`android_primary_navigation_swipe_test.dart`、`todo_progress_entrypoints_test.dart`、`todo_quadrant_golden_test.dart` |
| `/timeline`；`lib/features/timeline/presentation/timeline_page.dart`、`timeline_review.dart` | 复盘/明细、日/周/月指纹、分类结构/趋势、日时间轴、进行中记录；冲突提示、补记/结束、跨日记录 | Windows 宽/窄窗、Android | 共享模式/周期滑块及日期导航；Android周期菜单和原有悬浮拆分按钮；指纹轻量化与明细浅色块，保留统计和表单业务 | `timeline_layout_test.dart`、`timeline_fingerprint_test.dart`、`timeline_editor_test.dart`、`timeline_android_ui_test.dart`、`time_entry_interval_test.dart` |
| `/events`；`lib/features/events/presentation/events_page.dart` | 事件列表/卡片、状态筛选、归档、周期提醒；记录完成、历史、撤销 | Windows 宽/窄窗、Android 管理聚合 | 页面与编辑器接共享主题、表单、按钮、菜单、开关、日期时间；保留事件业务状态色 | `events_layout_test.dart`、`management_compact_cards_test.dart`、`business_repositories_test.dart` |
| `/inventory`；`lib/features/inventory/presentation/inventory_page.dart` | 物品卡片、搜索/分类/位置/状态筛选、统计、详情、配套物品、批量迁移；继承位置、附件状态 | Windows 宽/窄窗、Android 管理聚合 | 通用控件接 Omni；详情卡和统计图保留专用布局；详情翻转列为专用浮层，Android 新增为独立主按钮 | `inventory_layout_test.dart`、`inventory_move_dialog_test.dart`、`management_compact_cards_test.dart` |
| `/memberships`；`lib/features/memberships/presentation/memberships_page.dart` | 会员卡片、搜索/类别/状态筛选、支出统计、到期时间轴、缴费历史；永久/到期/续费/提醒状态 | Windows 宽/窄窗、Android 管理聚合 | 共享面板、表单、日期、开关、菜单和消息；会员状态信息/图表维持业务语义 | `memberships_layout_test.dart`、`management_compact_cards_test.dart`、`business_repositories_test.dart` |
| `/notes`；`lib/features/notes/presentation/notes_page.dart`、`note_audio_card.dart` | 本机草稿与显式发布、历史退出保存、组合筛选、标签与置顶、录音/回听/转写、失败与版本候选 | Windows 并排/窄窗、Android | 共享 Omni 控件与受限 Markdown 编辑器；Windows 原位编辑、Android 全屏历史编辑；草稿、媒体及原生语义约束见笔记维护指南 | `features/notes/notes_page_test.dart`、`features/notes/note_audio_card_test.dart` |
| `/settings`；`lib/features/settings/presentation/settings_page.dart` | 首页设置、功能管理、外观与主题、通知提醒、数据同步、回收站；Android 概览→详情→返回；断开/重连/清空/恢复状态 | Windows 宽/窄窗、Android | Android 六色入口图标，首页设置两端实底分组；同步连接、备份、断开操作独立分组，窄屏整行排列；保留既有设置导航与危险操作边界 | `settings_layout_test.dart`、`home_mobile_settings_test.dart`、`theme_settings_test.dart`、`feature_preferences_test.dart`、`android_settings_transition_test.dart`、`sync_connection_dialog_test.dart` |
| `FloatingWindowPage`；`lib/features/floating/presentation/floating_window_page.dart` | 待办象限/子任务、快速新增、开始记录/补记、进行中、撤销；拖动、缩放、唤起主窗口 | Windows 独立悬浮窗 | 共享语义色、输入、下拉、按钮和消息；紧凑行高、宿主窗口拖拽/缩放及浮层材质为受控差异 | `floating_window_page_test.dart`、`floating_resize_scheduler_test.dart`、`windows_floating_resize_service_test.dart`、`support/windows_floating_host_smoke.dart` |
| `ResponsiveShell`、管理聚合器；`lib/shared/layout/responsive_shell.dart`、`lib/features/management/presentation/` | 侧栏/导航轨、桌面管理切换、底部导航、Android 主页面/管理分区横滑、同步状态入口 | Windows、Android | 共享主题、图标操作与菜单；导航关系、预加载和手势协调保持既有契约 | `desktop_management_navigation_test.dart`、`android_management_navigation_test.dart`、`android_primary_navigation_swipe_test.dart`、`responsive_shell_sync_status_test.dart` |
| `/assistant`、`/assistant/memories`；`lib/features/assistant/presentation/` | 会话、附件、流式回答、结果操作、保存笔记、记忆列表及失败重试 | Windows、Android | 桌面助手侧栏与窄窗适配；业务表单、结果卡片和消息渲染使用各自共享组件 | `windows_assistant_test.dart`、`assistant_result_form_test.dart`、`assistant_result_card_test.dart`、`assistant_save_note_test.dart` |

## 业务弹窗与侧栏

“居中”均通过应用内 `showOmniDialog`，不会因 Flutter Windows 实验多窗口能力变成独立原生窗口。“侧栏”通过 `showOmniSideSheet`，紧凑宽度保持既有全宽形态。以下“已接入”仅描述源码路径。

| 编号 | 组件/入口与源码 | 必验状态与平台差异 | 统一路径与平台约束 | 验证入口 |
|---|---|---|---|---|
| D01 | `TaxonomyManagerDialog`；`lib/shared/taxonomy/taxonomy_manager_dialog.dart` | 新增、重命名、颜色、删除/撤销、重复名称、保存失败、拖拽；Android 全屏/桌面居中 | 已接 Omni 输入、按钮、图标、操作菜单；名称编辑自适应换行；保留分类颜色网格 | `taxonomy_manager_dialog_test.dart`、`taxonomy_repository_test.dart` |
| D02 | `GlobalSearchDialog`；`lib/shared/search/global_search_dialog.dart` | 空查询、搜索中、无结果、失败、多类型结果、功能关闭后的过滤 | 居中 `OmniDialogScaffold` + `OmniTextField` + `OmniListRow`，已接入 | 共享 `omni_overlay_accessibility_test.dart`；搜索结果专项需手工验收 |
| D03 | `AttachmentPickerDialog`；`lib/shared/attachments/attachment_picker_dialog.dart` | 无图、预览、选图取消、上传/同步状态、移除、恢复默认背景、读取失败 | 已有 `OmniDialogScaffold` / `OmniButton`；原生文件选择器为系统例外 | `attachment_repository_test.dart`、`image_sync_service_test.dart`；界面需手工验收 |
| D04 | `AttachmentCropDialog`；`lib/shared/attachments/attachment_crop_dialog.dart` | 图片解码、移动/缩放裁剪框、确认/取消、保存失败 | 已有统一弹窗与按钮；图像遮罩/白色裁剪手柄保留，以图片对比度为准 | 共享浮层测试；图片裁剪手感/导出专项需手工验收 |
| D05 | `HomeCardManagerContent` / `showHomeCardManager`；`lib/features/home/presentation/home_card_manager.dart` | 已添加/可添加/不可用卡片、拖拽、键盘排序、空集合 | 已接 `OmniSideSheetScaffold`、共享列表和图标按钮；原排序语义保留 | `home_dashboard_test.dart`、`home_card_preferences_test.dart` |
| D06 | `QuoteLibraryDialog`；`lib/features/home/presentation/quote_library_dialog.dart` | 列表、搜索、空态、删除/撤销、导入/导出菜单 | 已接统一弹窗、输入、图标、菜单和消息 | `quote_library_dialog_test.dart` |
| D07 | `QuoteImportPreviewDialog`；同上 | 导入预览、追加/覆盖模式、确认/取消、格式错误 | 已接统一弹窗、单选选项和按钮；导入数据规则保留 | `quote_library_dialog_test.dart`、`quote_json_transfer_test.dart` |
| D08 | `_QuoteEditorDialog`；同上 | 新增/编辑、正文多行、作者、必填/保存状态 | 已接统一侧栏、表单字段和按钮 | `quote_library_dialog_test.dart`、`windows_dialog_enter_save_test.dart` |
| D09 | `TodoEditorDialog`；`lib/features/todos/presentation/todo_editor_dialog.dart` | 新建/编辑/子任务、日期时间、提醒、重复规则、进度结构、重复系列范围、保存失败 | 统一侧栏和控件；时间设置外置标签、空值入口等宽与折叠摘要；进度设置基础字段并排、步骤行内操作/窄屏菜单、短列表完整展示、添加定位聚焦，均适配大字号 | `todo_editor_time_settings_test.dart`、`todo_progress_editor_layout_test.dart`、`todo_progress_ui_test.dart`、`todo_quadrant_ui_test.dart`、`windows_dialog_enter_save_test.dart` |
| D10 | `_TimeEntryEditorDialog`；`lib/features/timeline/presentation/timeline_page.dart` | 区间编辑、日期/分类、备注、多段占用冲突、拖动范围、保存失败 | 共享侧栏/输入/选择；业务范围滑块与冲突图形保留 | `timeline_editor_test.dart`、`timeline_layout_test.dart` |
| D11 | `_AbsoluteTimeEntryDialog`；同上；`time_entry_time_picker.dart` | 半屏/全屏开始记录、完整补记/编辑、结束进行中、Android五分钟滚轮/跨日日期、时间冲突、类别逐项颜色、备注折叠 | Android 开始记录使用 Omni 可展开底部面板，横线独立拖拽/点击，顶部固定取消/开始；半屏只显示活动和类别，全屏才增加开始时间与描述，收起保留输入，键盘避让不改变展开状态；提交期间锁定关闭/拖拽。Android 新增补记、已完成记录编辑与结束记录共用 OmniFullscreenFormScaffold 根导航全屏弹窗，顶部固定取消/居中业务标题/保存和灰色小时摘要，正文以时间卡片及活动/类别/备注分组呈现，保存期间保护返回、失败保留草稿；补记/已完成编辑保留 Android 双列时分滚轮与 Windows 精确输入/双手柄、连续跨日扩展、占用边界阻挡回弹和默认最近空闲段；共享日期/表单/下拉保留类别左侧色点；安卓结束记录保持开始端只读、默认逐分钟调整结束端，并保留原关闭与保存保护 | `start_time_entry_sheet_test.dart`、`time_entry_dialog_test.dart`、`time_entry_interval_test.dart`、`timeline_android_ui_test.dart`、`timeline_editor_test.dart`、`windows_dialog_enter_save_test.dart` |
| D12 | `_EventEditorDialog`；`lib/features/events/presentation/events_page.dart` | 新增/编辑、周期单位/间隔、提醒开关/时间、必填和保存失败 | 已接共享侧栏、表单、下拉、开关和按钮 | `events_layout_test.dart`、`windows_dialog_enter_save_test.dart` |
| D13 | `_EventHistoryDialog`；同上 | 历史列表、分组、空态、编辑/删除记录 | 已接统一居中弹窗、操作菜单和确认/消息 | `events_layout_test.dart` |
| D14 | `_EventHistoryEditorDialog`；同上 | 历史时间、备注、保存/取消 | 已接统一居中弹窗、日期时间和文本字段 | `events_layout_test.dart`、`windows_dialog_enter_save_test.dart` |
| D15 | `_InventoryEditorDialog`；`lib/features/inventory/presentation/inventory_page.dart` | 新增/编辑/配套物品、状态/类别/位置、金额数量、购入/保修日期、位置继承 | 已接统一侧栏、表单、下拉、日期和开关；原业务校验保留 | `inventory_layout_test.dart`、`windows_dialog_enter_save_test.dart` |
| D16 | `_InventoryDetailDialog`；同上 | 物品信息、图片、编辑/配套跳转、空字段、窄屏 | 专用卡片详情保留 `showGeneralDialog`；内容接共享语义色/图标/按钮；专用转场须单独验收 | `inventory_layout_test.dart` |
| D17 | `_AccessoriesDialog`；同上 | 配套列表、空态、新增配套、统计/位置继承 | 居中 `OmniDialogScaffold`，子编辑器走统一侧栏 | `inventory_layout_test.dart`、`business_repositories_test.dart` |
| D18 | `InventoryMoveDialog`；`lib/features/inventory/presentation/inventory_move_dialog.dart` | 物品选择/全选、随主物品自动选中、目的位置、新建位置、迁移结果/失败 | 已接统一弹窗、输入、复选框、下拉、按钮和消息 | `inventory_move_dialog_test.dart` |
| D19 | `_MembershipEditorDialog`；`lib/features/memberships/presentation/memberships_page.dart` | 新增/编辑、计费周期、永久/到期、自动续费、提醒与分类 | 已接统一侧栏、表单、日期、下拉、开关 | `memberships_layout_test.dart`、`windows_dialog_enter_save_test.dart` |
| D20 | `_PaymentHistoryDialog`；同上 | 缴费历史、空态、添加/编辑/删除、汇总 | 已接统一居中弹窗与确认/消息；列表沿用主题 | `memberships_layout_test.dart`、`business_repositories_test.dart` |
| D21 | `_PaymentEditorDialog`；同上 | 缴费金额/日期、周期、有效期、保存失败 | 已接统一居中弹窗、输入、下拉、日期和按钮 | `windows_dialog_enter_save_test.dart`、`memberships_layout_test.dart` |
| D22 | `_SyncConnectionDialog`；`lib/features/settings/presentation/sync_connection_dialog.dart` | 连接表单→数据处理预览、保留/替换策略、返回、提交中不可关闭、失败 | Windows 统一侧栏，Android 补记同款根导航全屏容器；统一表单、单选、图标和按钮，顶部固定操作、正文键盘避让、确认文案完整呈现；保留两阶段确认与 `PopScope` | `sync_connection_dialog_test.dart`、`settings_layout_test.dart`、`sync_connection_coordinator_test.dart` |
| D23 | `_SyncBackupDialog`；`lib/features/settings/presentation/sync_backup_dialog.dart` | 备份列表、加载/失败、删除确认/执行中 | 已接统一居中弹窗和按钮；旧库/快照删除范围不变 | `sync_maintenance_boundary_test.dart`；备份界面专项需手工验收 |
| D24 | `TodoProgressPanel`；`lib/features/todos/presentation/todo_progress_panel.dart` | 跳序记录、批量预览、即时保存/失败重试、六秒撤销、满进度待确认、历史只读与重开；首页/待办/悬浮窗共用 | 统一侧栏、按钮、输入、消息与语义主题；顶部下一个步骤与完成操作同排，批量短输入框及外置标签，空间不足按字号分行，错误整行展示；只读分段条为业务图形，无拖动手势 | `todo_progress_ui_test.dart`、`todo_progress_entrypoints_test.dart`、`todo_progress_panel_layout_test.dart`、`test/support/todo_progress_runtime_smoke.dart` |

## 内联浮层、选择器、消息与受控例外

| 类别与调用位置 | 统一路径与平台约束 | 必验行为 | 验证入口 |
|---|---|---|---|
| 短确认：分类删除、事件历史删除、会员缴费删除、名言删除、首页删除、设置清理 | `showOmniConfirmDialog` + `OmniDialogScaffold` + 危险操作变体；共享动作区可换行 | 取消/确认结果、Esc/返回/遮罩、正文滚动、关闭焦点恢复 | `omni_overlay_accessibility_test.dart`、`taxonomy_manager_dialog_test.dart`、相关业务测试 |
| 待办移动象限、移入回收站及重复系列范围 | 已使用应用内 `showOmniDialog`；部分内容为受主题控制的 `SimpleDialog` / `AlertDialog`，重复编辑用 `OmniDialogScaffold`；回收站操作使用 OmniButton 的次要和危险变体 | 当前象限禁用、父子任务范围、仅本次/以后、撤销，不因外观迁移改变结果 | `todo_quadrant_ui_test.dart`、`windows_dialog_enter_save_test.dart` |
| 同步断开与备份删除的内联确认 | `showOmniDialog` + `OmniDialogScaffold`，保留原数据处理选项与破坏性操作确认 | 保留/删除本机数据、取消、执行中禁止重复提交 | `sync_connection_dialog_test.dart`、`sync_maintenance_boundary_test.dart`；备份清理手工验收 |
| 日期选择：待办、时间、事件历史、物品、会员 | `OmniDatePickerButton` / `MenuAnchor`；共享圆角/表面，触控日历更宽且保持六行，日期有完整语义标签 | 日期范围、月份/年份切换、选中/今天、取消、触控网格、减少动效 | `omni_date_time_picker_test.dart`、`omni_overlay_accessibility_test.dart` |
| 时间选择：提醒、历史、时间记录 | `OmniTimePickerButton` / `MenuAnchor`；保留原非步长时间，菜单项目跟随平台密度/文字放大 | 既有分钟值、滚动定位、选中与关闭后焦点 | `omni_date_time_picker_test.dart`、`omni_overlay_accessibility_test.dart` |
| 普通/表单下拉：业务筛选、类别/位置/状态、主题、重复规则 | `OmniDropdownButton` / `OmniDropdownButtonFormField`；选中勾位置可配置；键盘展开聚焦当前项，关闭回触发器 | 空值、禁用、表单错误、Enter/Space/上下键、Tab、触控实际热区 | `omni_dropdown_test.dart`、`omni_overlay_accessibility_test.dart` |
| 常规操作菜单：列表更多、分类、名言导入导出、导航主题/管理切换 | `OmniPopupMenuButton` / `OmniPopupMenuItem`；共用主题、动作图标、危险色和减少动效 | 选中/取消、禁用项、打开后返回、键盘与边缘定位 | `omni_dropdown_test.dart`、`taxonomy_manager_dialog_test.dart`、导航专项测试 |
| 分类颜色选择 | Omni 菜单入口；一个底层 `PopupMenuItem` 承载自定义颜色网格，颜色格增加语义与触控区域 | 颜色名称、已选标记、键盘/触控选择、取消 | `taxonomy_manager_dialog_test.dart` |
| 首页待办右键/长按菜单 | 指针定位 `showOmniMenu` + `OmniPopupMenuItem`，保留调用位置定位能力；主题统一 | 右键/长按、不重复开启、编辑/子任务/删除、菜单关闭 | `home_todo_context_menu_test.dart` |
| 每日待办普通/进度任务菜单及首页进度快捷操作 | `TodoTaskContextMenu` 指针定位 `showOmniMenu` + `OmniPopupMenuItem`，移除更多按钮；添加子任务与完成下一个共用按钮尺寸；进度快捷按钮使用“+1”直接完成首个未完成步骤，正文仍打开面板 | Windows 单击展开/收起、右键；Android 单击、长按、横滑；编辑/移动/回收站、键盘菜单键/Shift+F10；进度提交防重、失败恢复、精确撤销、满进度仍需确认 | `todo_progress_entrypoints_test.dart`、`todo_progress_quick_action_test.dart`、`todo_quadrant_ui_test.dart` |
| 移动新增拆分菜单 | 时间页使用 `OmniSplitActionButton`，菜单提供补记与分类、主操作开始/结束；Android 事件、会员、物品使用独立新增按钮，管理操作位于摘要更多菜单 | 点主按钮与菜单互不混淆、取消、菜单方向键、减少动效、屏边 | `timeline_android_ui_test.dart`、`events_layout_test.dart`、`inventory_layout_test.dart` |
| 页面顶部操作反馈/完成撤销 | `showOmniMessage`；成功/警告/错误/信息共用结构；内容相对弹窗垂直居中，撤销保持同行；鼠标、键盘或读屏焦点停留暂停，辅助服务开启本身不永久暂停 | 替换/关闭、倒计时、操作只执行一次、撤销时限、辅助服务开启时仍自动关闭、正文及按钮读屏焦点暂停/继续、宽窄窗口与两倍字号对齐、长文案换行、减少动效 | `omni_message_test.dart`、`omni_overlay_accessibility_test.dart`、业务撤销测试 |
| 文本输入/表单校验 | `OmniTextField` / `OmniTextFormField` 保留 Flutter 文本编辑、输入法、焦点及验证能力；业务拥有校验规则 | 中文输入法组合态、复制粘贴、多行 Enter、错误/只读/禁用/提交中、焦点顺序 | `omni_form_controls_test.dart`、`omni_windows_enter_submit_test.dart`、`windows_dialog_enter_save_test.dart` |
| 分段切换、统计轮播与手势 | `OmniSlidingSegmentedControl`、共享分段主题、`OmniStatisticsCarousel`；Android 页面/象限横滑继续既有手势协调 | 连续快速切换、中途反向、跟手索引、减少动效、返回 | `omni_sliding_segmented_control_test.dart`、`omni_statistics_carousel_test.dart`、`android_primary_navigation_swipe_test.dart` |
| 附件选图、名言 JSON 导入/导出 | `FilePicker.pickFile` / `FilePicker.saveFile` 系统窗口保留；应用内调用入口与返回反馈统一 | 原生取消、不支持文件、路径/文件错误、焦点回到应用 | `quote_library_dialog_test.dart`、`quote_json_transfer_test.dart`、Windows/Android 实机 |
| 操作系统通知、托盘和窗口外框 | `core/notifications/local_notification_service.dart`、Windows 托盘/悬浮窗宿主；系统控制的显示不伪装为应用弹窗 | 通知可用/失败、托盘唤起、窗口位置和关闭；系统若请求权限则保留系统授权界面 | `notification_plan_builder_test.dart`、`windows_tray_service_test.dart`、宿主烟测与实机 |

## 回归约束

- 组件展示入口是 `lib/dev/ui_catalog.dart`；先对共享组件审查 12 种配色明暗组合，再审业务界面。`omni_theme_test.dart`、`omni_button_test.dart`、`omni_form_controls_test.dart`、`ui_catalog_test.dart` 是基础验证入口。
- 现有 golden 使用 Flutter 测试字体，主要证明布局、尺寸与裁切。中文可读性必须另外查看加载真实中文字体的预览或实机；不能将方块字截图标成中文验收通过。
- 基线只在逐张查看候选图、确认差异来源之后更新；测试失败必须先区分预期视觉变化与业务/焦点/布局回归。
- 没有对应专项自动化的搜索、附件裁剪、备份清理界面需要显式保留手工验收项。实机验证还包括中文输入法、屏幕阅读器、字体放大、滚动/拖拽流畅度与 Android 返回。
- 自定义绘制的图表、象限树线、裁剪遮罩及系统窗口属于有明确目的的差异，不因出现 `CustomPaint`、`Material` 或底层 Flutter 控件而机械替换。新增普通控件应优先经 Omni 入口和共享参数，新增例外须补充本清单及规范说明。
- 时间指纹标签按类别背景亮度选择黑/白前景。具体受控例外以 `tool/ui_style_exceptions.json` 为准，由 `tool/check_ui_style.dart` 检查，文档不重复维护例外数量。


## Android 页面与手势约束

- 首页与待办使用随正文连续移动的胶囊导航，选中项展开文字，未选中项收起文字并保留图标；首页、待办和管理页的内部横向分页不接力一级导航；顶部、空态与悬浮操作也需隔离。分区切换及返回保留各自的列表位置、查询、筛选与展开状态。首页模块身份和顺序来自 `HomeCardId` 与 `home.cards.order`，首页设置入口在设置页，空首页保留恢复入口。
- 管理页使用固定分区标签、随内容滚动的搜索、轻量摘要与独立记录列表。物品、会员整行长按打开原操作菜单，续费及配套入口保留原显示条件；新增位于右下角独立按钮，管理能力位于摘要更多菜单。
- 管理统计使用分区全量数据，不受列表搜索和筛选影响；展开时隔离背景触控、焦点与读屏，遮罩、系统返回及分区切换可收起。拖动需可反向接管，减少动画时即时落位。
- 管理筛选采用草稿：重置只改草稿，勾号才应用，取消或系统返回保留原条件。顶栏向下取消、中间标题、右侧应用，非默认草稿显示重置；选项保持至少 48dp 触区，大字号按内容增高。
- 时间开始记录使用可展开底部面板；补记、已完成编辑与结束记录使用统一全屏表单。开始端只读、默认时间粒度、连续跨日范围与占用边界属于业务规则，不随表单布局变化。提交期间阻止重复提交和退出，失败保留输入。

## 常用验证

在 `apps/client` 执行，按改动范围选取相关业务测试：

```powershell
dart tool/check_ui_style.dart
flutter analyze --no-pub
flutter test --no-pub test/ui_catalog_test.dart test/omni_overlay_accessibility_test.dart
flutter test --no-pub tool/ui_pages_preview_test.dart
flutter run --no-pub -t lib/main_ui_catalog.dart -d windows
```

组件目录使用内存状态，不连接业务库。中文字体和预览配置见根目录[界面规范](../../../style.md)。Windows 菜单、按压与原生探针见[交互回归指南](windows-interaction-coverage.md)。

人工验收应覆盖 Android 实体设备的系统 IME、硬件返回、TalkBack 与滑动手感，Windows 读屏、连续右键、多窗口焦点和悬浮宿主拖动／缩放，以及系统文件选择、裁剪、备份清理等原生边界。六套配色、明暗、宽窄窗、大字号、减少动画及加载／空／失败状态按受影响界面组合复验；模拟器或组件预览不能代替这些原生体验。
