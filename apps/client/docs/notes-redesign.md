# Windows 笔记重构交付与验证

更新：2026-10-13。需求以 [笔记 PRD v2.8](../../../spec/笔记功能PRD.md) 为准，本轮没有部署正式服务、操作真实用户数据库或启动新的付费转写。

## 实现

v2.8正文超过两行时添加灰色展开／收起入口，悬停主题蓝字与手形指针、无背景；约220ms连续高度动画，所有笔记只有一个完整阅读展开身份，与双击编辑分离。编辑进入时收起其他正文，阅读另一篇时先暂存当前编辑。

历史编辑复用浅灰音频条，更多展开后增加插入正文和右侧红色删除录音，插入优先候选；保存图标左侧显示取消。取消恢复正式正文与原音，删除保存前仅落本机草稿，重启可恢复；保存时只删除本篇所选元数据，另存排除选中原音并保留原篇。沿用本机pendingInsertions JSON增加deletedAudioIds数组，兼容原有布尔标记，不更改数据库／同步结构；既有引用清理保护共享原件。新增草稿原音在历史编辑同样紧凑展示，发布前不能重新识别。

笔记侧栏每个标签和回收站与“全部笔记”统一实际行高，默认视觉40dp、行间4dp；移除叠加在菜单36dp热区上的纵向留白，名称单行省略。窄窗、长名称、1.6倍字号及悬停／折叠状态保持一致行高，右侧菜单点击区沿用。

收缩历史笔记取消边框描边，圆角、主题底色和内边距保持一致；只在此处使用OmniPanel.showBorder=false，其余面板默认外观和展开输入框边框沿用原逻辑。

v2.7收缩卡片按音频参考截图补齐浅灰播放条：播放／暂停、细进度线、MM:SS时长及更多；约220ms向下展开灰色12dp原始转写，仅保留重新识别和下载。每张历史卡片读取自身有效原音，播放与原件SHA核查复用现有服务，重新识别沿用授权与未知回执保护；下载用现有file_picker保存校验后的WAV副本，取消不改动原件。创建时间改为灰色10dp，操作菜单灰色至主题正文色悬停；菜单、播放与文字操作显式手形指针，文字操作悬停浅灰圆角背景。Android保留完整音频管理布局，Windows历史编辑使用上述v2.8音频条。

主区输入卡片按四张补充截图改为独立圆角白色表面、浅灰常态边框、聚焦细主题色轮廓和轻阴影，占位“现在的想法是...”；正文无悬停背景和分隔线。左侧只保留`#`，非聚焦极浅灰；右侧48×30dp按钮为20dp白色发布／麦克风图标，有文字／有效原音时主题色发布，空白时主题色麦克风。聚焦显示可见字符数，失焦隐藏；新建卡片无取消按钮、日期或常驻状态／更多工具。正文与工具共享点击区域，点击标签不丢正文焦点。历史编辑使用相同卡片和图标保存，切回新建暂存历史修改。独立`OmniNoteComposerButton`避免普通图标默认内缩轮廓和样式优先级覆盖业务外观，不修改共享普通按钮。深色模式保留主题表面及可读灰色，Android原有编辑呈现与自动保存继续沿用。

Windows 页面采用统计／8–12周热图／标签／回收站侧栏、新建草稿与单列卡片，双击原地展开，搜索位于右上角。侧栏默认264dp，拖动范围220–340dp，对应8–12列；分隔线仅分隔热区悬停显示浅灰、按下立即显示主题色，上下各留24dp空白，闲置透明。全侧栏含底部空白悬停显示隐藏按钮，隐藏后主区标题左侧显示恢复入口，当前草稿、筛选和宽度保留。三项统计分别左／中／右对齐，月份使用完整中文，移除近13周说明。首行派生标题，摘要最多两行。Ctrl+F 从正文或导航轨都聚焦笔记搜索；普通编辑保留筛选，外部定位清除遮挡条件。可用宽度不足900dp使用抽屉，减少动画时跳过卡片动画。

标签区域悬停显示排序、搜索和篇数，标题悬停强调并显示折叠箭头；标签搜索只筛选标签名称，关闭或Escape恢复全部。排序支持默认／名称／数量，保留持久化顺序。标签行悬停显示只有删除／改名的菜单，改名使用紧凑Omni弹窗，删除仅解除关联并移除失效筛选。热图提示恢复为`YYYY-MM-DD·N 篇笔记`。

按补充视频统一悬停入口120ms原位淡入／淡出，保留占位与子树，中途反向连续，隐藏立即排除点击／焦点／语义；减少动画即时切换。Windows共享普通图标、Popup菜单及原生主题图标采用28dp圆角方形背景、36dp布局及热区、18dp字形、零内边距，灰色在图标自身悬停／焦点时转正文色，保留业务颜色及嵌入约束，Android仍48dp。标签标题无灰底，左边缘对齐回收站图标；列表220ms向下展开／向上收起、中途反向连续，减少动画即时切换，窄栏大字号工具换行保持四字标题完整；搜索为36dp高、12dp圆角浅灰填充且无焦点描边，两侧图标在输入框内；三个点字形、方形背景和行内容实际中心一致，选中标签使用浅主题底色。

Windows 文字与原音只写本机草稿，发布／保存才原子提升为正式笔记及版本；Android 保持自动保存。取消或本机永久删除仅留下无正文、标签、基线与时间信息的草稿身份墓碑，阻止迟到事件复活。已补录音结束后延迟暂存、保存中切换、清理与新增草稿交错、录音启动中取消等竞态回归。

笔记类别只在notes模块退休。回收站查询／清空支持general、notes、all；到期清理覆盖all。SQLite19、同步schema4、本机快照4、服务器迁移协议3分别管理；旧队列身份及原始负载摘要不改，服务端执行副本兼容退休类别。草稿原音备份和换服复制使用独立校验文件，选择服务器数据不会混入旧源草稿。

## 验证

- 发布／麦克风图标微调：字形24dp→20dp，按钮仍48×30dp；输入四态生产回归1项、静态分析通过，最新Windows Release成功（56.9秒）。日志`build/notes-action-icon-test.log`、`build/notes-action-icon-analyze.log`、`build/notes-action-icon-release.log`。

- v2.8正文与历史编辑：130项笔记回归全部通过（58秒），包含正文展开／收起中间帧、唯一展开、真实鼠标悬停、减少动画、编辑音频插入／删除／取消、冻结保护、重启恢复删除、冲突及另存保留原篇、共享原件保护和已删新增录音清理。最终静态分析无问题，样式仍44项既有受控例外；Windows Release通过（50.6秒）。日志：`build/notes-body-edit-regression.log`、`build/notes-body-edit-analyze.log`、`build/notes-body-edit-style.log`、`build/notes-body-edit-release.log`。生产中文预览在`build/notes-body-edit-preview`，已检查正文收缩／展开／悬停和编辑音频展开；录音、播放器及系统保存边界使用替身。

- 侧栏统一行高补充：8项相关测试通过，长标签／1.6字号抽屉预览1项复验通过；覆盖相同行高、菜单悬停／点击、搜索排序、改名删除、正常／减少动画折叠及隐藏后抽屉恢复。静态分析无问题，样式仍44项原有受控例外。最新Release构建成功（48.8秒），日志`build/notes-sidebar-height-test.log`、`build/notes-sidebar-height-large-test.log`、`build/notes-sidebar-height-preview.log`、`build/notes-sidebar-height-analyze.log`、`build/notes-sidebar-height-release.log`；悬停与长名称抽屉生产预览已刷新检查。

- 收缩卡片无描边补充：实际Material.shape.side为BorderSide.none，双击展开／切回新建及音频展开2项定向测试通过；静态分析无问题，样式仍44项受控例外。最新Release再次构建成功（50.8秒），日志`build/notes-borderless-test.log`、`build/notes-borderless-analyze.log`、`build/notes-borderless-release.log`；音频三态中文预览已刷新并检查。

- v2.7主题按钮与音频条：124项笔记回归通过（53秒），含六套配色明暗下的48×30dp主题色发布／麦克风、音频向下展开中间帧、原始转写、播放暂停继续跳转、真实鼠标手形反馈、窄窗大字号、下载副本字节／摘要、取消及篡改保护、历史原音归属。静态分析无问题，样式扫描仍44项受控例外。Windows Release通过（50.9秒）；日志`build/notes-audio-regression.log`、`build/notes-audio-analyze.log`、`build/notes-audio-style.log`、`build/notes-audio-release.log`。中文生产预览在`build/notes-audio-preview`，音频收缩／展开／下载hover和输入四态已检查。系统保存边界与识别点击使用替身验证，未打开真实保存窗口、启动麦克风或调用付费转写。

- v2.6输入卡片：完整笔记回归118项通过（51秒），最终输入／录音／历史版本入口3项复验通过。覆盖四种状态、实际白色图标与64×40dp完整按钮背景、极浅灰井号、正文hover透明、标签不丢焦点、组合字符计数、图标发布、替身麦克风启停、真实测试WAV纯录音发布、Android沿用及六套明暗预览。全客户端静态分析无问题，样式检查仍44项原有受控例外。最终Windows Release更新通过（50.9秒），产物`build/windows/x64/runner/Release/omni_butler.exe`；日志`build/notes-composer-regression.log`、`build/notes-composer-final-interactions.log`、`build/notes-composer-analyze.log`、`build/notes-composer-release.log`。本轮录音启动由替身验证，没有采集真实麦克风。

- 标签与回收站间距补充：移除额外12dp区块留白；正常／减少动画布局回归2项通过，静态分析无问题。最新Windows Release更新通过（52.2秒），日志`build/notes-tags-spacing-release.log`。

- 标签搜索空结果补充：移除搜索中的提示文字及空态占位，搜索／关闭回归1项通过，全客户端静态分析无问题；最新Windows Release更新通过（55.3秒），日志`build/notes-empty-tag-search-release.log`。

- 当前v2.5 Windows Release构建通过（55.5秒），日志`build/notes-compact-release.log`；产物`build/windows/x64/runner/Release/omni_butler.exe`及`data/app.so`。未启动或终止用户客户端。

- v2.5背景与标签动画：生产页面37项、共享控件／主题／事件布局60项，共97项通过；最终背景预览单项再验通过。验证28dp背景与36dp热区分离、六套明暗图标反馈、嵌入按钮保护、主题轮廓过渡、220ms标签展开／收起中间帧、反向连续、回收站随动、收起命中关闭、减少动画及标题实际可见左边缘对齐。最小220dp侧栏与1.6字号下完整四字标题亦通过。全客户端静态分析无问题，UI样式44项原有受控例外、无新增绕过入口。本阶段未更改截图基线；日志为`build/notes-compact-final-page-test.log`及`build/notes-compact-shared-final.log`。

- v2.4阶段Windows Release构建通过（65秒），日志`build/notes-unified-buttons-release.log`，产物`build/windows/x64/runner/Release/omni_butler.exe`；此前各阶段构建时长仅为历史记录。

- 2026-10-13图标统一（v2.4）：笔记生产页面35项、共享图标／渐隐3项通过，覆盖7项要求、六套明暗颜色、反向动画、隐藏命中／焦点与Android热区。全客户端回归1006项通过、5项外部测试跳过，1项事件空态溢出已定位修复：统一按钮后短历史弹窗剩余133dp，固定内容135dp；改为可滚动空态，事件布局2项完整复验通过。18张受共享尺寸／颜色影响的截图基线逐张审阅更新。最终静态分析无问题、UI样式仍44项受控例外，无新增绕过入口。日志为`build/notes-unified-buttons-final-test.log`及`build/notes-shared-events-fixed.log`。

- 2026-10-13标签交互调整：生产页面34项与标签仓储／管理器8项，共42项全部通过（41秒）；最终标题悬停清理后，3项标签回归再次通过（9秒）。验证区域工具及篇数、标题折叠、独立搜索与关闭／Escape、三种排序、空白／重复名称、关闭放弃改名、删除取消及正文／版本／原音保留。分隔线按下即着色及上下24dp留白验证通过，最终预览补充复验通过。全客户端静态分析和UI样式44项原有受控例外通过；最新Windows Release复建通过（51.9秒），包含最终悬停清理。

- 2026-10-13动效调整：生产页面31项全部通过（36秒），全客户端静态分析及最终改动文件分析均无问题，UI样式仍为44项原有受控例外，最新Windows Release构建通过（55秒）。侧栏220ms左滑与淡出／淡入、主区同步扩宽，中途反向继续当前进度，隐藏时排除侧栏点击／焦点／语义。热图相邻间距8dp，悬停120ms放大1.2倍及手形光标；仅有笔记且非未来日期显示提示和主题光晕。覆盖中间帧位移／缩放、反向连续性、实际绘制光晕、空点击保留筛选、减动画回归；六套明暗及最终悬停／动效中文预览已刷新检查。
- 2026-10-13侧栏调整：生产页面28项回归全部通过（31秒），覆盖悬停留白、隐藏／恢复时草稿与筛选保留、分隔条闲置／悬停／拖动／取消、220–340dp边界及中间8–12列、跨年、最小宽度1.6字号、隐藏后窄窗抽屉及宽窗恢复。六套配色明暗和边界宽度中文预览已刷新检查；本轮静态分析和样式检查再次通过。
- 2026-10-13最新Windows Release构建通过（114秒），产物为 `build/windows/x64/runner/Release/omni_butler.exe`；已有Windows CMake修改保持完整，没有启动或终止用户客户端进程。
- 全客户端 `flutter analyze --no-pub`：无问题。
- `dart run tool/check_ui_style.dart`：44项原有受控例外，无新增绕过入口。
- 2026-10-12重构相关Flutter统一回归245项全部通过，含当时页面24项、本机草稿14项，以及录音／传输、真实SQLite及PowerSync升级、旧队列身份、草稿原音备份与换服、回收站隔离、分类和认证同步边界。最终日志为 `build/notes-redesign-regression.log`（33秒，退出码0）。
- 服务端定向单测28项通过，独占PostgreSQL实际增量迁移及JWT HTTP集成22项通过；全套174项通过、41项外部集成跳过；Nest构建及改动文件ESLint通过。隔离容器已清理。
- Windows Release构建通过，产物位于 `build/windows/x64/runner/Release`。初次构建发现既有CMake缓存将安装前缀解析为拼接的错误路径；仅将忽略目录中的CMAKE_INSTALL_PREFIX重设为Release绝对目录后复建成功，未修改Windows工程源码，也未覆盖或终止正在运行的Debug及安装版。
- 六套配色×明暗、原位展开、窄窗／短窗／1.6字号、抽屉和Android预览已生成并检查。

客户端复验（在apps/client执行，不并行启动多个Flutter测试以避免SQLite DLL锁）：

```powershell
flutter analyze --no-pub
dart run tool/check_ui_style.dart
flutter test test/features/notes test/notes_integration_test.dart test/notes_redesign_migration_test.dart test/notes_powersync_draft_test.dart test/database_migration_test.dart test/taxonomy_repository_test.dart test/taxonomy_manager_dialog_test.dart test/recycle_bin_repository_test.dart test/recycle_bin_settings_test.dart test/recycle_bin_cleanup_test.dart test/sync_connection_coordinator_test.dart test/sync_maintenance_boundary_test.dart test/sync_image_report_test.dart test/sync_disk_space_test.dart test/powersync_runtime_test.dart test/note_test_data_cleanup_test.dart test/responsive_shell_sync_status_test.dart test/sync_runtime_migration_test.dart test/sync_upload_protocol_test.dart test/auth_repository_test.dart
flutter build windows --release --no-pub
./tool/preview_notes_redesign.ps1
```

服务端常规复验（在apps/server执行）：`npm test`、`npm run build`。数据库集成必须指向独占测试PostgreSQL，不能将真实业务数据库地址用于测试。

## 中文预览

v2.8预览位于`apps/client/build/notes-body-edit-preview`：`windows-body-collapsed.png`、`windows-body-expanded.png`、`windows-body-hover.png`、`windows-body-switched.png`及`windows-edit-audio-collapsed.png`、`windows-edit-audio-expanded.png`。来自生产根应用，编辑态已等待原音核验并聚焦正文，能检查主题轮廓、字数、取消和录音四个操作。

v2.6输入区域预览位于`apps/client/build/notes-composer-preview`：`windows-composer-empty.png`、`windows-composer-focused-empty.png`、`windows-composer-focused-text.png`、`windows-composer-blurred-text.png`及`windows-composer-hover.png`。全部从生产根应用渲染，并复查空白及深色状态。

[复现脚本](../tool/preview_notes_redesign.ps1)使用生产页面、内存数据库、真实中文字体和录音替身；不采集真实麦克风或读取用户笔记。生成目录为 `apps/client/build/notes-redesign-preview`。

| 主题 | 浅色 | 深色 |
|---|---|---|
| classic_blue | windows-classic_blue-light.png | windows-classic_blue-dark.png |
| cloud | windows-cloud-light.png | windows-cloud-dark.png |
| sea_salt | windows-sea_salt-light.png | windows-sea_salt-dark.png |
| sky | windows-sky-light.png | windows-sky-dark.png |
| distant_mountain | windows-distant_mountain-light.png | windows-distant_mountain-dark.png |
| slate | windows-slate-light.png | windows-slate-dark.png |

另有windows-tags-collapsing.png、windows-tags-expanding.png、windows-tags-collapsed.png验证标签上下展开／收起及回收站随动；windows-tags-header-hover.png、windows-tags-search-style.png、windows-tag-menu-button-hover.png，验证标题无灰底、输入框内搜索／关闭图标与三个点居中；windows-tags-hover.png、windows-tags-search.png、windows-tags-menu.png、windows-tags-rename.png检查标签悬停／搜索／操作菜单／名称编辑；windows-divider-hover.png检查浅灰线及上下留白；windows-sidebar-hover.png、windows-sidebar-hidden.png、windows-sidebar-drag.png、windows-sidebar-min.png、windows-sidebar-max.png、windows-sidebar-min-large.png，用于检查悬停／隐藏／拖动／边界宽度／大字号；windows-sidebar-closing.png和windows-sidebar-reopening.png检查动画中间帧，windows-heatmap-empty-hover.png和windows-heatmap-filled-hover.png检查空／有效日期悬停；以及windows-expanded-edit.png、windows-narrow-large.png、windows-narrow-drawer.png、android-light.png、android-dark.png、android-320-large-editor.png和android-320-large-history.png。旧windows-light.png／windows-dark.png为早期预览，以带主题名的最终文件为准。

## 保留边界

Android真机后台／锁屏／来电、实际30／60分钟录音和公网HTTPS长音频转写仍待验收，本轮没有测试手机或公网地址；不能以替身测试和构建替代。

先访问首页再进入笔记，同时动态启用减少动画、字号1.6并缩窗至700×480，仍会触发未改动的 `home_page.dart:358` 中零时长AnimatedSize布局断言。已通过RenderObject祖先链定位到HomePage／_HomeDashboard；诊断保存在 `build/notes-motion-diagnostic.txt`。本轮未扩大修改首页，笔记减少动画冷启动以及独立字号／尺寸变化均通过。

部署须先备份数据库及全部原音，再发布PostgreSQL增量迁移、API和PowerSync配置，验证后升级两端客户端；详见 [部署说明](../../../deploy/README.md)。
