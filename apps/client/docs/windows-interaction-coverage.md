# Windows 菜单与点击反馈回归指南

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

## 交互约束

菜单退场保留同一底色 RGB，仅改变 alpha，避免与透明黑插值产生中途闪暗。上下文手势通过 `OmniSecondaryPressScope` 交给行内容，特殊行用 `OmniSecondaryPressContent` 标记边界；背景和子孙操作不能重复缩放，也不能延迟原业务菜单。菜单项右键只提供反馈，左键按原业务选择并关闭。

鼠标打开菜单不应无条件请求触发器焦点。关闭时恢复打开前的焦点，避免给祖先卡片遗留焦点底色；键盘 Tab／Enter 打开、Escape 关闭仍需恢复触发器。保留真实焦点和无障碍，不通过全局 unfocus 清除错误表象。

`OmniDisclosureToggle` 标记的展开入口保留原生语义、焦点和回调，不做按压缩放；标记仅由最近交互宿主消费，行内普通按钮仍各自提供独立反馈。

## 自动回归入口

以下文件位于 `test/`，按改动范围组合执行：

| 测试 | 覆盖职责 |
|---|---|
| `omni_windows_press_feedback_test.dart` | 实际中间尺寸、按住/释放/取消/反向接管、嵌套排他、禁用、键盘/语义、减少动画与 Android 对照 |
| `omni_windows_menu_test.dart` | 整体过渡、退出屏蔽、逐帧 hover、危险/禁用、右键、键盘和焦点、缩窗、长菜单、多行/网格及大字号 |
| `omni_windows_segmented_button_test.dart` | 原生段的几何、颜色、禁用、边缘命中和唯一语义操作 |
| `windows_press_entrypoints_test.dart` | 真实内存仓储及路由中的宽/窄窗入口、父子/加一嵌套、背景固定、边缘命中及唯一业务执行 |
| `omni_menu_focus_test.dart` | 明暗、图标/自定义入口、连续鼠标取消后的实际像素、已有输入焦点、业务弹窗焦点与唯一回调 |
| `omni_note_audio_seek_bar_test.dart` | 音频滑块尺寸、唯一语义、键盘及读屏操作 |

在 `apps/client` 执行：

```powershell
dart tool/check_ui_style.dart
flutter analyze --no-pub
flutter test --no-pub test/omni_windows_press_feedback_test.dart test/omni_windows_menu_test.dart test/omni_windows_segmented_button_test.dart test/omni_menu_focus_test.dart test/windows_press_entrypoints_test.dart
```

视觉回归须采样实际合成像素，检查点击后鼠标仍停留原处、快速反向悬停及菜单取消后的状态，不能只读取目标颜色属性。基线变更逐张审查，先排除焦点、布局和业务回归，再决定是否更新。

## 原生运行时探针

`tool/windows_interaction_probe.dart` 在独立 Windows 窗口运行，使用内存状态与真实辅助功能桥；Pointer 与引擎 KeyData 驱动按住、释放、取消、连点、嵌套、选择、笔记双击、菜单悬停、Escape、方向键及右键。它不初始化生产数据库、偏好、麦克风或同步。

构建入口为 `tool/windows_interaction_probe.dart`，用 `--dart-define=OMNI_INTERACTION_PROBE_OUTPUT=<绝对目录>` 指定证据目录，`--dart-define=OMNI_INTERACTION_PROBE_DARK=true` 选择深色；采样清单 `frames.ffconcat` 可由 FFmpeg 编码视频。帧和视频应来自实际原生渲染并保留真实时间戳。

笔记动态语义与提示锚点使用 `tool/notes_windows_accessibility_probe.dart` 复验，具体参数见[笔记维护指南](notes-redesign.md)。原生错误未必转换为 Dart 异常，必须捕捉 stdout/stderr：确认原生 AX 已启用、探针完成，同时排除 AXTree、框架异常与 `PROBE_FAILURE`，不能只检查退出码。

探针应在独立且未占用的构建目录运行；验证后用 `--target lib/main.dart` 恢复生产入口，不覆盖或终止正在运行的客户端。

原生探针覆盖固定演示轨迹，不代表所有生产业务状态已人工验收。发布仍需在目标 Windows 环境验证真实读屏、多窗口焦点和连续操作，Android 实体设备的手势、输入法与读屏另行验收。
