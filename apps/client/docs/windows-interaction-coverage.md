# Windows 菜单与点击反馈验收

## 范围与统一入口

操作菜单走 `showOmniMenu`；按钮走 `OmniPressBinding` 和原生 `WidgetStatesController`，只通过 `foregroundBuilder` 变换前景；点击行走 `OmniInkWell`。动画值集中在 `OmniMotion`，操作菜单尺寸和材质集中在 `OmniMenuMetrics`。布局、命中和业务提交时机不随动画变化。

| 入口类别 | 接入位置与保留行为 |
|---|---|
| 三个点、更多、右键及长按菜单 | `OmniPopupMenuButton`、`OmniContextMenu`；首页和待办直接菜单收口到 `showOmniMenu`；不新增业务操作或层级 |
| 多行管理切换及颜色网格 | `desktop_management_switcher.dart`、`taxonomy_manager_dialog.dart`；保留 288dp 特殊宽度、多行说明、勾选和独立色块操作 |
| 共享主次按钮和图标 | `OmniButton`、`OmniIconButton`、`OmniTextButton`、`OmniOutlinedButton`、`OmniFilledButton`；保留原生裁剪、主题、尺寸和焦点 |
| 列表、卡片及嵌套按钮 | `OmniListTile`、`OmniPanel`、`OmniInkWell`；独立行内按钮不带动父项，禁用操作不穿透 |
| 侧栏和窄窗导航 | `responsive_shell.dart`；侧栏行、底部导航和窄窗 Rail 内容缩放，选中背景固定 |
| 设置和同步操作 | `settings_page.dart`、`theme_palette_selector.dart`、`sync_maintenance_boundary.dart`；选择标签、外观和连接操作保留原提交行为 |
| 首页 | `home_page.dart`、`home_card_manager.dart`、`home_context_card.dart`、`home_time_status_card.dart`；待办、卡片设置和图例操作 |
| 待办 | `todos_page.dart`、`todo_progress_panel.dart`、`todo_progress_widgets.dart`、`todo_completion_checkbox.dart`、`todo_editor_dialog.dart`；父子项、步骤、加一、历史和编辑；完成框不叠加旧缩放 |
| 笔记 | `notes_page.dart`、`windows_notes_view.dart`、`windows_note_tags.dart`、笔记输入及音频共享操作；双击编辑交给原 InkWell，保留稳定 Windows 语义边界；热图在悬停尺度上叠加按压 |
| 时间 | `timeline_review.dart`、`time_entry_time_picker.dart`、共享分段和日期时间控件；统计、日期、类别及编辑入口 |
| 物品、搬家、会员、事件 | 对应 presentation 页面、搬家对话框和 `OmniSegmentedButton`；保留原业务、筛选和特殊布局 |
| 选择控件 | `OmniCheckbox`、`OmniRadioListTile`、`OmniChoiceChip`、`OmniFilterChip`、`OmniSwitch`、`OmniTaxonomyChip`；三态、RadioGroup、选中语义和唯一操作节点 |
| 自绘标题栏与悬浮窗 | `windows_title_bar.dart`、`floating_window_page.dart`；窗口按钮、紧凑按钮、任务和选择入口；拖动和调整大小不缩放 |
| 表单选择器 | `OmniDropdown`、`OmniDateTimePicker`；只增加前景点击反馈，选择面板样式和 Enter 行为保留 |

文本输入、文字编辑上下文菜单、滚动条、Slider/RangeSlider、拖动分隔线、坐标图表操作、系统托盘及系统原生窗口不加入缩放。Android 专属首页、管理、待办及拆分悬浮按钮继续原实现；跨平台适配组件在 Android 不增加 Windows 绘制变换。

## 验证证据

- `omni_windows_press_feedback_test.dart`：14 项，检查实际中间尺寸、90/160ms 时机、左右键快速点击、取消、反向接管、嵌套排他、禁用、语义和键盘、三态与 RadioGroup、减少动画、Android 及原生几何对照；上下文右键保持背景且只消费一次反馈。
- `omni_windows_menu_test.dart`：13 项，包括整体过渡、退出屏蔽、逐帧hover颜色、危险和禁用、菜单项右键、键盘与焦点、卸载与缩窗、多行/网格、32dp 自定义热区；长菜单在全部配色和明暗、360×480、1.6 倍字号下滚动到初始项并确认。
- `omni_windows_segmented_button_test.dart`：5 项，检查与原生段的几何、颜色、禁用、边缘命中和唯一语义操作。
- `windows_press_entrypoints_test.dart`：2 项，在真实内存仓储和路由下检查 1440 浅色、700 深色业务入口、父子与加一嵌套、背景固定、边缘命中及业务执行次数。
- 最新全客户端 `flutter test --no-pub`：1056 通过、5 跳过、6 项既有失败，日志 `build/menu-hover-fix/full-tests.log`。首次统一重构日志在 `build/windows-interaction-full-tests-final.log`；长菜单矩阵日志在 `build/windows-interaction-final-menu-matrix.log`。
- 六项失败均在未修改 HEAD `f639d85` 的 `build/windows-interaction-baseline/apps/client` 副本复现：四项固定日期提醒样例已过期；物品、会员两张旧 Golden 各有相同 641px 差异。基线日志为该副本下的 `windows-interaction-baseline-tests.log`、`windows-interaction-baseline-extra.log`。未改业务或刷新这两张旧基线。
- 首次统一重构只更新两张审阅过的截图：事件菜单关闭后触发器的焦点字形颜色；分类编辑测试等待按压回弹和焦点装饰静止后的输入框边框。本次hover及右键修复不更新Golden；日期、时间选择器基线保持不变。
- `tool/windows_interaction_probe.dart` 在独立 Windows 原生窗口运行，启用真实 AX 桥，使用 Pointer 和引擎 KeyData 驱动；明暗均验证按住/释放/取消/连点、嵌套操作、选择、笔记双击、菜单 hover/Escape/方向键及右键。内存状态断言通过，错误列表为空。`build/windows-interaction-probe` 和 `build/windows-interaction-probe-dark` 保存截图、真实时间戳、结果和视频。
- 系统锁屏遮挡了首次屏幕捕获，未交付该片段。最终视频连续捕获探针自身实际原生渲染图层，并依据真实帧时间编码；不使用静态目标属性补造帧，也不录制桌面。隔离探针不初始化生产数据库、偏好、麦克风或同步。
- 既有笔记原生无障碍探针二十轮完成，退出码 0，原生 AX 已启用，没有 AXTree 错误；日志为 `build/windows-interaction-notes-ax.stdout.log` 和 `.stderr.log`。探针仅调整双击入口定位以匹配当前 `KeyedSubtree`/`OmniPanel`，不改验证流程或关闭辅助功能。
- 同一原生探针的 `--anchors-only` 隔离锚点二十轮也完成，退出码 0、无 AXTree 错误；日志为 `build/windows-interaction-notes-anchors.stdout.log` 和 `.stderr.log`。
- `flutter analyze --no-pub` 无问题；`dart tool/check_ui_style.dart` 通过，28 项受控例外；生产 `flutter build windows --release --no-pub` 通过，产物为 `build/windows/x64/runner/Release/omni_butler.exe`，日志为 `build/windows-interaction-release-build.log`。生产入口仍为 `lib/main.dart`，隔离探针只在独立短路径 Debug 目录构建。

## 2026-10-15 闪烁与右键回归

2026-10-15 用户录屏回归：菜单退场保留同一底色RGB，仅改变alpha，修复与透明黑插值的中途闪暗；上下文原手势通过`OmniSecondaryPressScope`交给行内容，特殊首页行用`OmniSecondaryPressContent`标记边界，不压缩背景、不叠加后代、不延迟原菜单。菜单项右键仅反馈，左键业务和关闭逻辑保持。两项缺陷修前测试失败，修后59项共享/真实路由/Android定向验证通过，日志为`build/menu-hover-fix/regression-before.log`与`regression-after.log`。

新增原生明暗视频与证据在`build/menu-hover-fix/native-light`、`native-dark`：包含45/110ms交替的快速反向hover、菜单项右键按住及上下文条目右键按住/打开。`menu-hover-right.mp4`由实际原生渲染帧及真实时间戳编码；`hover-pixels.json`检查快速跨行期间两行远离文字的实际背景像素，要求始终在完整悬停色与面板色之间，不能以目标属性代替像素。

明暗各15帧的实际背景像素检查通过，原生AX开启、errors为空且无AXTree日志；笔记动态及隔离锚点各20轮重新通过，日志`build/menu-hover-fix/notes-ax.*.log`、`notes-anchors.*.log`。静态分析、28项样式检查与正式Release构建通过，日志`build/menu-hover-fix/analyze.log`、`release-build.log`。

## 可重复执行

### 2026-10-15 三个点取消后的卡片底色

Windows 菜单按钮不再在打开前无条件 `requestFocus`，改由 Navigator 恢复打开前的焦点。鼠标打开并点击遮罩取消后，不会凭空给祖先 `OmniPanel` 留下品牌色焦点墨水；Tab 聚焦后用 Enter 打开、Escape 关闭仍恢复触发器。未关闭焦点样式或无障碍，也没有在回调后调用全局 unfocus。

`omni_menu_focus_test.dart` 检查明暗、图标／自定义入口、连续两次鼠标取消后的真实 RGBA 像素和已有输入焦点，并检查选择后业务弹窗的焦点及唯一回调。完整测试在隔离副本恢复旧代码后再次复现像素差异，见 `build/menu-dismiss-focus-fix/regression-before-final.log`；修后共享菜单／点击反馈／Windows 和 Android 入口／事件布局共 74 项通过，见 `shared-final.log`，笔记页原有回归也全部通过，见 `regression-after.log`（其中新像素测试初版未等待父卡双击仲裁，修正等待后在 `shared-final.log` 通过）。

事件历史截图仅 14×14 区域的 124 个图标像素变化，已检查为取消菜单后正常灰色字形替代此前强制焦点深色字形，仅更新该基线。检查图为 `build/menu-dismiss-focus-fix/event-golden-review.png`。静态分析无问题，样式检查29项受控例外通过。

独立原生窗口明暗各三次“笔记三个点→外部关闭”的实际 RGBA 像素严格等于打开前：浅色 `0xffffffff`、深色 `0x242529ff`；截图及 `results.json` 保存在 `build/menu-dismiss-focus-fix/native-light`、`native-dark`。两轮均开启原生 AX、退出0、errors为空，键盘恢复／菜单选择／右键反馈／嵌套与笔记双击轨迹全部通过，无AXTree错误。探针等待父卡原有双击仲裁，不修改生产手势时机；不操作个人数据。

正式入口 `lib/main.dart` 的 Windows Release 构建成功（63.7秒），日志 `build/menu-dismiss-focus-fix/release-build.log`；产物 `build/windows/x64/runner/Release/omni_butler.exe`。正在运行的用户 Debug 实例保持运行。

在 `apps/client` 运行 `dart tool/check_ui_style.dart`、`flutter analyze --no-pub` 和上述测试。Windows 动效探针以 `tool/windows_interaction_probe.dart` 为入口，使用 `OMNI_INTERACTION_PROBE_OUTPUT` 指定证据目录，`OMNI_INTERACTION_PROBE_DARK=true` 指定深色；采样清单 `frames.ffconcat` 可用 FFmpeg 编码视频。已有 `tool/notes_windows_accessibility_probe.dart` 继续用于真实笔记动态语义二十轮回归。

此轮覆盖源码入口、自动交互和独立原生运行时；不把隔离演示扩大解释为所有生产业务数据状态的人工验收，也不以 Windows 验证代替 Android 实体设备手感验证。
