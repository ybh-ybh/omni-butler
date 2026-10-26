# 笔记模块维护指南

本指南说明当前客户端的笔记结构、保存边界与验证入口。产品规则见[笔记 PRD](../../../spec/笔记功能PRD.md)，部署与升级见[部署说明](../../../deploy/README.md)。路径除另行说明外均相对 `apps/client/`。

## 代码入口

| 职责 | 主要源码 |
|---|---|
| 页面状态、数据订阅与平台分流 | `lib/features/notes/presentation/notes_page.dart` |
| Windows 列表、输入、侧栏 | `windows_notes_view.dart`、`windows_note_body.dart`、`windows_note_tags.dart`、`windows_note_tag_picker.dart` |
| Android 输入、录音与历史编辑 | `android_notes_view.dart`、`android_note_composer_surface.dart`、`android_note_editor.dart`、`android_note_recording.dart`、`android_note_history_surface.dart` |
| Android 侧栏、标签与统计 | `android_note_sidebar.dart`、`android_note_sidebar_tags.dart`、`android_note_tag_pages.dart`、`android_note_statistics.dart` |
| 搜索与筛选 | `data/note_search_filter.dart`、`data/note_search_history.dart`；呈现为 `windows_note_search_*.dart`、`android_note_search*.dart` |
| 正式笔记与本机草稿 | `data/note_repository.dart`、`data/note_editor_controller.dart`、`data/note_local_draft_repository.dart` |
| 记录日期、统计、标签操作 | `data/note_record_time.dart`、`data/note_statistics.dart`、`data/note_tag_actions.dart` |
| 富文本与受限 Markdown | `presentation/note_rich_editor.dart`、`markdown/note_markdown.dart` |
| 图片与原音 | `data/note_image_repository.dart`、`data/note_audio_transfer_service.dart`、`audio/` |

表中未带目录的页面文件位于 `lib/features/notes/presentation/`，`data/`、`audio/` 和 `markdown/` 位于 `lib/features/notes/`。

## 保存与冲突边界

文字、图片与新增原音先进入本机草稿，发布或保存才提交正式笔记。Windows 双击历史卡片原地编辑，切回新建时保留历史草稿；Android 新建主动发布，历史编辑通过左上操作或真正退出时保存。Android 系统返回先关闭日期、工具或键盘，提交失败或冲突时留在原页；无修改保存不制造正文版本。

正文并发冲突保留完整候选版本，由用户选择恢复或另存。迟到的转写不得覆盖人工正文；标签、置顶与记录时间使用独立更新，普通正文保存不回写未修改字段。草稿的取消、永久删除和源切换需要处理异步代次及墓碑，避免迟到录音或暂存事件复活已删除内容。

本机草稿表不进入 PowerSync 下行或服务器暂存。采用本机数据换服时携带并校验草稿与真实附件，采用服务器数据时旧草稿留在原数据源及备份。笔记回收站与其他业务隔离；类别在笔记模块退休，使用标签、日期及关键词查找。

## 列表、日期与标签

正式笔记先按置顶分组，组内按记录日期、秒数倒序及 ID 稳定排序。置顶独立立即保存，软删与恢复保留置顶状态，不改变正文版本和统计。记录时间与真实创建、修改、原音采集时间分开，范围为 1970 年至当前时刻，跨时区保留墙钟显示；列表、热图、筛选和统计共用 `dayKey`。

Windows 使用可拖动及隐藏的统计／热图／标签侧栏、新建输入区与单列历史卡片；窄窗改为抽屉。正文超过两行可展开，阅读展开与双击编辑互相独立。`Ctrl+F` 聚焦笔记搜索；组合筛选的实现见 `note_search_filter.dart`，本机搜索历史不跨设备同步。

Android 使用紧凑输入表面与全屏历史编辑。历史菜单提供编辑、复制、详情、版本、置顶和删除；版本恢复只替换对应草稿正文，仍需保存。搜索使用独立页面，避免改变主列表正在编辑的草稿及其他篇录音。

标签置顶、名称、emoji 和持久排序可跨设备同步。Windows 输入区选中标签移至前方只改变呈现，不写回持久顺序；Android 排序页面在保存时提交排序，等待拖动真实落位后再保存。emoji 使用[离线目录](../assets/emoji/README.md)，不依赖在线选择器，也不提供标签颜色编辑。

标签删除提供“仅删除标签”与“删除标签和笔记”。前者只解除关联；后者在同一事务内回收关联笔记及附件、解除关联并删除标签，多标签笔记整篇回收。删除须复核数据源、笔记集合及录音状态，失败保留草稿及原件。

统计只计算正式、未回收的笔记，不受列表筛选影响；草稿和版本不计入。纯录音计篇数和天数，字数为零；正文统计使用统一可见文字。选中统计日期后退出统计与抽屉，清理遮挡当天记录的筛选，保留当前草稿及原音状态。

## 富文本、图片与音频

编辑器使用 Flutter Quill 维护选区、输入法和撤销，持久正文为受限 Markdown，支持加粗、下划线、高亮及单层列表。codec 保留换行与非目标语法，打开或移动选区不重写正文；标题、搜索与统计使用统一可见文字。

图片导入后复制到私有目录，正式附件使用独立 `note_images` 身份，通过图片服务存入 MinIO。保存按增删差量合并，纯图片可发布，图片变化不制造正文版本；取消、另存、回收与迟到响应必须保护仍被引用的原件。

Windows 使用 PCM WAV，Android 使用原生麦克风前台服务与通知操作。同一设备只允许一段录音，暂停不计时，单段最多 30 分钟、单篇累计最多 60 分钟。手动结束 Windows 录音先排空暂存，再发布或保存当前篇；失败保留草稿和原件。暂停取消只丢弃本段，其他正文和附件保留。

录音和文字可离线使用。自动转文字需要明确授权，授权不追溯历史片段或其他草稿，未发布片段不提交供应商。原始转写、AI 整理结果与正式正文分别保存；成功的整理结果由客户端按正文版本与采用范围自动写回；失败保留原文，已有本机草稿或版本冲突时保留候选，明确确认后可追加。新的提示词不自动重跑旧结果。连接错误恢复只查询或复用原操作身份，提交结果未知时不得自动重建计费尝试。

回听、拖动与导出均核验真实文件和摘要；导出保存副本，不移动原件。异常退出的原音通过未确认清单恢复。服务端能力、腾讯适配器和公网长音频配置见[笔记原音说明](../../server/src/notes/README.md)。

## 数据版本与升级

版本定义以 `lib/core/database/app_database.dart` 的 `schemaVersion`、`lib/core/auth/auth_repository.dart` 的同步版本常量，以及 `lib/core/sync/sync_snapshot.dart` 的快照与换服协议常量为准；这些版本分别管理，不应按笔记界面版本推断。

升级前备份 PostgreSQL、MinIO 数据卷、凭据卷及客户端原音；先应用数据库增量迁移、API 和 PowerSync 投影，再升级全部客户端。图片同步关闭仍需备份笔记原音。旧持久队列身份及原始负载摘要不得随兼容转换重建；旧快照兼容在 `SyncSnapshot.fromJson` 中维护。

## 验证入口

按改动范围选择测试，在 `apps/client` 串行执行 Flutter 测试，避免 SQLite DLL 锁冲突：

```powershell
flutter analyze --no-pub
dart tool/check_ui_style.dart
flutter test --no-pub test/features/notes
flutter test --no-pub test/notes_integration_test.dart test/notes_redesign_migration_test.dart test/notes_powersync_draft_test.dart test/note_record_time_migration_test.dart test/note_polish_migration_test.dart
flutter build windows --release --no-pub
./tool/preview_notes_redesign.ps1
```

布局复验包括从首页进入笔记后动态启用减少动画、放大至 1.6 倍字号并缩窗至 700×480 的组合场景；需同时观察被保活的首页与笔记布局。

数据与协议变更还需运行数据库升级、同步上传、换服及对应服务端测试；真实数据库集成必须使用独占测试环境。普通测试跳过的外部集成不算真实同步验证。

预览脚本使用生产页面、内存数据库、真实中文字体和录音替身，默认输出 `build/notes-redesign-preview`。预览用于检查布局和中文，不代替真实系统键盘、麦克风、相机、读屏或双设备网络同步验收。

### Windows 原生无障碍

动态 Tooltip 和音频滑块分别通过 `OmniWindowsSemanticsBoundary` 与局部 Overlay 保持稳定语义子树。保留原生 Slider 的键盘、进度读屏与 24dp 高度，不应通过关闭语义或吞日志规避 AXTree 错误。卡片阅读态局部使用透明悬停色，保留内嵌菜单、音频及双击操作反馈。

`tool/notes_windows_accessibility_probe.dart` 使用内存数据并创建自己的窗口。可选择 `--anchors-only`、`--editor-only`、`--tags-only`、`--history-only`，并加 `--dark --narrow`；`--unguarded` 只用于锚点负向对照。

```powershell
flutter build windows --debug --no-pub --target tool/notes_windows_accessibility_probe.dart
# 在独立探针 bundle 目录执行，并保存 stdout、stderr。
.\omni_butler.exe --history-only --dark --narrow
# 回到 apps/client 后恢复生产入口。
flutter build windows --debug --no-pub --target lib/main.dart
```

构建前确认目标目录没有被正在运行的客户端占用，必要时使用独立构建目录。检查 stdout 中 `PROBE_NATIVE_AX_ACTIVE:true` 与 `PROBE_COMPLETE`，并检查 stderr 中的 `Failed to update ui::AXTree`、框架异常及 `PROBE_FAILURE`；单看退出码或 Dart `ensureSemantics` 不足以验证原生辅助功能桥。

## 发布人工验收

发布需单独覆盖 Android 实体设备后台／锁屏／来电、系统键盘与返回手势、实际 30／60 分钟录音、公网 HTTPS 长音频和真实双设备同步；Windows 还需验证系统输入法、读屏、多 DPI 与连续原生鼠标操作。隔离预览、模拟器、替身测试和构建各自只说明其覆盖范围，不能据此认定全部发布条件已满足。
