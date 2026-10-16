# Windows 笔记重构交付与验证

更新：2026-10-16。需求以 [笔记 PRD v2.14](../../../spec/笔记功能PRD.md) 为准，本轮没有部署正式服务、操作真实用户数据库或启动新的付费转写。

## 实现

v2.14按两段参考视频重构Windows笔记右上角搜索栏：删除全局搜索、本机草稿、外观模式三个顶栏按钮；默认260×43.2dp灰底无边框，悬停细描边，聚焦白底并向左展开至400dp。最近5条本机搜索历史支持点击／方向键选择和Enter，Escape／外点关闭；只记已提交的完整查询，去空白、去重、最近优先，中文组合输入不提前记忆。

右侧过滤菜单使用现有Omni菜单路由；时间永久展开且没有折叠箭头，标签／包含内容点击展开。标题默认灰字，悬停／键盘导航／有效条件仅文字及箭头使用正文色，整行背景始终透明。选项按钮统一为居中文字、浅灰底与细描边；选中为浅主题色底、主题色文字和边框，无额外图标或勾选。搜索按钮为实主题色，重置为灰色文字。时间按归档自然日且含首尾，近7／30天包括今天；标签支持包含／排除／无标签，空查询不展示候选，输入后仅显示匹配的井号小按钮；选择后清空查询，已选项留在输入区并可独立移除，模式切换保留未提交选择；内容使用正式图片关系、正文HTTP(S)链接和有效语音片段的交集。菜单编辑独立草稿，搜索才应用、重置只清草稿、取消保持已应用值。热图选日替换快捷时间条件，全部笔记／统计选日／外部定位清理新增筛选，排除标签不误显示为侧栏已选。没有来源字段，因此不展示来源；无数据库和同步迁移。

### v2.14 验证记录

2026-10-16截图对齐补充：搜索组件21项、历史6项、菜单／焦点22项及生产页面筛选2项，共51项相关测试通过。组件覆盖六套配色明暗矩阵、选中前后文字居中及无额外图标、空查询不枚举标签、搜索／添加／移除／模式切换／重开／重置、时间不可折叠，以及标题hover前／中／后真实RGBA像素不出现整行填色。证据位于`build/notes-search-refinement/`，中文实际字体预览见`preview/`；本轮静态分析无问题，样式检查通过（29项受控例外），2个Dart文件格式及diff检查通过；Windows Release以lib/main.dart构建成功（59.4秒，windows-release.log退出0）。生产程序仍位于build/windows/x64/runner/Release/omni_butler.exe，未停止用户Debug或操作真实数据库；原生窗口及系统输入法未人工验收。

首轮重构相关回归共112项通过：笔记页78项、菜单及焦点22项、本机历史6项、搜索组件6项。组合批次111项通过（`build/notes-search/regression.log`）；新增日期嵌套浮层后搜索组件最终6项通过（`search-preview-test.log`），覆盖缺少日期、倒序校验、选择和逐层Escape。热图替换时间范围及排除标签侧栏状态最后以生产页面2项复验通过（`search-page-final-test.log`）。中文组合输入不提前记录、历史点击替换组合文字、取消菜单不应用、深色320dp／1.6字号均有组件验证。

改动文件静态分析无问题，UI样式检查29项受控例外、无新增绕过入口；8个Dart文件格式与diff检查通过。真实中文字体7张预览位于`build/notes-search/preview/`，已检查常态、悬停、展开历史、过滤折叠／选择、深色窄窗及完整生产页面。`lib/main.dart` Windows Release构建成功（71.6秒），程序位于`build/windows/x64/runner/Release/omni_butler.exe`，日志`build/notes-search/windows-release.log`。本轮未启动原生程序做人工键鼠／系统中文输入法验收，组件模拟与编译不能代替该项；用户运行中的Debug程序未停止。

v2.13新增Windows标签跨设备置顶与删除二级菜单。置顶区位于全部标签上方，空时隐藏，沿用规范排序；同一标签仍在全部列表，两处选择及计数一致，搜索／收起只影响全部列表。菜单按“置顶／取消置顶、编辑名称、分隔线、删除标签”排列；删除悬停／点击展开“仅删除标签”“删除标签和笔记”。主子面板均240dp宽、同路由，保持键鼠、焦点恢复、边缘避让与读屏。

删除标签和笔记使用NoteTagActions组合既有仓储，集合确认、笔记及附件回收、全部关联解除与标签删除在同一事务内；多标签笔记整篇回收，已回收记录不刷新期限。prepareForDeletion(action:)覆盖整个事务门禁，只停止相关录音并排空暂存，保留本机草稿；失败不回收，集合变化重新确认。原音失败必须先恢复，成功提交／取消／恢复会按草稿代次清理对应失败事实。

当前SQLite21、同步schema6、本机快照6、换服wire3。标签is_pinned默认false；旧快照1–5补0，旧PATCH不补默认值，改名／排序与置顶互不覆盖。升级顺序：备份→PostgreSQL增量迁移20261015010000→API和PowerSync投影→全部Windows/Android客户端；旧schema客户端受既有门禁限制同步。

### v2.13 验证记录

客户端笔记／迁移／同步组合149项、删除与草稿保护35项、菜单及共享模型兼容48项全部通过。上传协议最终14项通过，新增真实PowerSync事务验证：末步失败时无CRUD／请求，重试成功时正文、版本、图片、录音、标签只上传一个事务，tags_base保留实际前值。菜单覆盖退出动画中立即／30ms重开，避免ExcludeFocus尚未解除时丢失子项焦点；关联删除后的恢复会立即通知编辑器解除只读。

服务端常规135项通过、87项外部环境测试跳过；真实隔离PostgreSQL新增迁移／跨设备字段差量2项通过，完整同步集成42项通过、2项旧断言失败：测试仍期待15表及不含note_images的publication，已有图片迁移已增加该表，本轮未扩大范围修改这两处。服务端构建与改动文件ESLint通过；客户端完整analyze、29项受控样式检查、格式及diff检查通过。尚未执行真实两台物理设备联网的完整PowerSync下行，不能将本机队列与PostgreSQL验证视为该项人工验收。

中文实际字体明暗置顶及二级菜单、窄窗1.6字号预览4项通过，位于`build/notes-tags/preview/`。预览临时启用真实阴影并恢复测试设置，避免Flutter测试框架将菜单阴影画成粗描边。用户Debug程序占用原生DLL，所有本轮最终运行验证使用`D:/ob-tags-1015`隔离副本，不停止用户程序、不操作真实数据。

原生`tool/notes_windows_accessibility_probe.dart --tags-only`覆盖真实鼠标置顶、两分区菜单、跨面板、两种删除确认取消及键盘两级退出。浅色宽窗串行20轮、深色窄窗20轮均以退出0完成，`PROBE_NATIVE_AX_ACTIVE:true`、`PROBE_COMPLETE`齐全，stderr无框架／AXTree错误。最初并行运行时浅色第8轮后出现导航焦点断言，独立串行20轮复验通过；原生交互验证后续串行，失败尝试日志保留，不将并行失败当作通过。首次隔离NuGet下载重试后使用与CMake锁定SHA256一致的本机缓存构建成功，未修改依赖或全局设置。

最终恢复正式`lib/main.dart`入口的Windows Release构建成功（57.4秒、退出0），完整产物已同步回`build/windows/x64/runner/Release/`，exe及`data/app.so`与隔离构建SHA256一致。没有启动生产程序，用户原Debug进程保持运行。原生日志、组合回归、预览、分析及服务端常规测试证据集中于`build/notes-tags/`；正式服务未部署。

v2.12（2026-10-15）Windows 使用 Flutter Quill 11.6.0 维护可视选区、输入法与撤销；持久正文仍为受限 Markdown。支持 `**加粗**`、`<u>下划线</u>`、`==高亮==`、单层 `- `／`1. ` 列表及正文范围内 Ctrl+B／Ctrl+U。自有 codec 保留换行和非目标语法，打开和移动选区不重写 body。标题、搜索与统计使用统一可见文字；列表开头不抽走首项，普通标题和两行正文展开沿用。

底部左侧顺序为井号、图片、分隔线、Aa、无序、有序；悬停独立绘制浅灰背景、前景加深，避免 Ink 固定 alpha 黑底。Aa 使用统一窗口内菜单路由，横向三个动作，保留选区、焦点恢复和无障碍。窄窗工具与发布组自然换行。

2026-10-15 Aa 默认高亮修复：首项 B 由菜单自动取得焦点，原按钮把鼠标模式下的焦点也画成选中背景，正文实际未加粗。格式按钮现在遵循共享菜单的最近输入方式：鼠标只显示当前悬停，键盘导航显示当前焦点；保留真实焦点、选区与格式操作。明暗实际像素回归修前均失败、修后通过，9 项编辑栏及15项菜单回归通过；静态分析、样式检查及正式入口 Windows Release 构建通过。证据位于 `build/notes-format-focus-fix/`，预览为 `preview/windows-format-menu-no-default-{light,dark}.png`。

同日按界面反馈收紧 Aa 弹层：三个图标从24dp缩至18dp，移除条目与面板叠加的上下留白，高度52dp降为36dp，宽度116dp；按钮36dp点击区域和与入口8dp间隔保持。9项编辑栏回归、静态分析、样式检查及正式入口Windows Release构建通过，实际明暗预览与日志位于 `build/notes-format-compact/`。

图片按钮多选 PNG／JPEG／WebP，首张后显示 68dp 缩略图、8dp 间隔、右上删除及末尾虚线加号；零图不占位，阅读可放大。草稿文件复制到本机私有目录；正式图片通过现有图片服务最终存入 MinIO，断网保留待传，跨设备下载经长度和 SHA 校验。每图 note_images 独立身份映射 noteImage 业务槽位，保存按增删差量合并，不制造正文版本；纯图可发布，取消／另存／回收站／迟到响应均保护原件。

v2.12当时版本为SQLite20、同步schema5、本机快照5，换服wire3；当前版本见上方v2.13。旧服务端未声明supportedBusinessTypes时只接受原有两类图片，笔记图片待升级后补传；Android无新增编辑界面但共享保存不会删除图片。

### v2.12 验证记录

笔记、图片、真实 SQLite 升级、PowerSync 草稿与快照相关 Flutter 回归 245 项通过；最终界面专项 7 项通过，覆盖悬停实际像素、鼠标原位点击、明暗主题、640dp 窄窗、1.6 倍字号、减少动画、快捷键、弹层关闭与焦点、列表、图片导入／删除／纯图发布／放大。文本组件最终 15 项通过，包含 100 项有序列表在大字号与系统缩放下的编号宽度。预览在 `build/notes-toolbar-preview/`，回归日志为 `build/notes-toolbar-regression.log`、`build/notes-toolbar-final-ui.log`。

服务端常规测试 134 项通过，84 项需外部环境的测试跳过；另在独占 PostgreSQL／MinIO 中运行图片集成 17 项、JWT 笔记同步集成 23 项并全部通过，包含两图独立上传／下载／删除及双设备图片增删差量。测试结束已停止隔离存储，没有操作正式部署或真实用户数据。Nest 构建、改动文件 ESLint、Flutter 静态分析和 UI 样式检查通过。

Windows Release 及原生探针验证见下方入口。操作系统中文输入法候选窗与真实两台 Windows 经 PowerSync 的完整人工验收仍待执行；组件测试覆盖中文／emoji／组合输入，真实 MinIO 与模拟双设备 API 集成不能代替这两项人工验收。

原生编辑专项使用 Release 构建 `tool/notes_windows_accessibility_probe.dart` 并带 `--editor-only` 运行，真实启用 Windows 辅助功能桥。最终 20 轮快捷键／格式／列表操作完成，`PROBE_NATIVE_AX_ACTIVE:true`、`PROBE_COMPLETE`，退出码 0，stderr 无框架或 AXTree 错误；随后恢复 `--target lib/main.dart` 构建，最终程序位于 `build/windows/x64/runner/Release/omni_butler.exe`。日志为 `build/notes-toolbar-native.{stdout,stderr}.log` 与 `build/notes-toolbar-release-final.log`。没有终止或覆盖用户正在运行的 Debug 程序。

2026-10-15悬停补充：年份入口去掉hover、按下与焦点底色；月／年均使用手形，未选中项悬停时为深灰背景、选中项保持滑块原色。分段控件提供可选光标及未选中悬停色，使用独立动画背景保留RGB且仅改变alpha，避免切换选中项时InkHighlight残留不透明黑色，其他使用方未启用时沿用原行为。

v2.11 三项侧栏统计变为同一个记录统计弹窗入口，120ms文字渐色及右箭头淡入轻移，不改变数字对齐；保留键盘、统一按压和减少动画。弹窗使用窗口内Omni路由，局部居中标题、月年切换、年份菜单及轻模糊遮罩；最大1120×780dp，窄窗和大字号自然改为两列／单列，正文滚动。无分享、更多或统计分析跳转。

日月年统计由`NoteStatistics`从`notesProvider`派生，按dayKey与正文可见字符聚合；纯录音计篇数和天数，字数零，草稿、版本和回收站不计入。当前年月倒序显示月卡，历史年完整十二月；年度三图保留01–12及右侧整数刻度。日期格单独实现：空日主题描边、普通光标、无操作；有效日提示篇数／字数并返回dayKey。页面清除其他条件、退出回收站、关闭抽屉并显示当天全部记录，原编辑与原音状态保留。旧侧栏热图沿用。

年份只列有效年份，默认当前年或最新有记录年份；监听正式流，选中年份消失时回退，真实全空隐藏菜单，加载和失败不误判为空集合。日期读屏说明放在独立Windows语义边界内，与点击动作同属可访问节点，提示避免重复朗读。

v2.10 输入标签合并为单行，超宽横向滚动。选中移到最前，取消回到未选区规范位置，两个分区内均保持管理器原顺序，不写回持久排序。复用原生Flex测量自然宽高并插值实际布局位置，每个标签保留同一语义父节点，避免改序时重挂；读屏及键盘顺序同步。约220ms移位和显隐均可从当前画面反向，减少动画即时更新；已选常驻、未选井号展开及草稿保存协议沿用。

v2.9 Windows输入框去掉管理标签按钮，侧栏原排序入口改为管理标签，沿用现有新增／改名／删除／拖动排序管理器。输入标签使用与物品筛选一致的紧凑圆角、描边和无勾选外观，保留多选和笔记主题色。已选常驻；未选通过井号显示或隐藏，220ms高度、透明度与轻微缩放可反向打断；隐藏立即停用命中、焦点和读屏。当前草稿和正式关联继续使用原有保存协议，Android呈现不变。

AXTree修复采用Windows提示锚点隔离与笔记动态区域固定父节点：`OmniWindowsSemanticsBoundary`覆盖共享图标／菜单和笔记输入按钮，热图提示也使用同一边界。保留读屏及提示，不禁用语义或吞日志。依据本机Flutter 3.47.2源码和原生验证；[上游同类问题](https://github.com/flutter/flutter/issues/182444)及[机制讨论](https://github.com/flutter/flutter/pull/190344)可供参考。本轮没有修改或升级Flutter SDK。

v2.8正文超过两行时添加灰色展开／收起入口，悬停主题蓝字与手形指针、无背景；约220ms连续高度动画，所有笔记只有一个完整阅读展开身份，与双击编辑分离。编辑进入时收起其他正文，阅读另一篇时先暂存当前编辑。

历史编辑复用浅灰音频条，更多展开后增加插入正文和右侧红色删除录音，插入优先候选；保存图标左侧显示取消。取消恢复正式正文与原音，删除保存前仅落本机草稿，重启可恢复；保存时只删除本篇所选元数据，另存排除选中原音并保留原篇。沿用本机pendingInsertions JSON增加deletedAudioIds数组，兼容原有布尔标记，不更改数据库／同步结构；既有引用清理保护共享原件。新增草稿原音在历史编辑同样紧凑展示，发布前不能重新识别。

笔记侧栏每个标签和回收站与“全部笔记”统一实际行高，默认视觉40dp、行间4dp；移除叠加在菜单36dp热区上的纵向留白，名称单行省略。窄窗、长名称、1.6倍字号及悬停／折叠状态保持一致行高，右侧菜单点击区沿用。

收缩历史笔记取消边框描边，圆角、主题底色和内边距保持一致；只在此处使用OmniPanel.showBorder=false，其余面板默认外观沿用原逻辑。历史笔记编辑时主题色边框常驻，点击搜索等区域失焦后也保持，直到取消或结束编辑。

v2.7收缩卡片按音频参考截图补齐浅灰播放条：播放／暂停、细进度线、MM:SS时长及更多；约220ms向下展开灰色12dp原始转写，仅保留重新识别和下载。每张历史卡片读取自身有效原音，播放与原件SHA核查复用现有服务，重新识别沿用授权与未知回执保护；下载用现有file_picker保存校验后的WAV副本，取消不改动原件。创建时间改为灰色10dp，操作菜单灰色至主题正文色悬停；菜单、播放与文字操作显式手形指针，文字操作悬停浅灰圆角背景。Android保留完整音频管理布局，Windows历史编辑使用上述v2.8音频条。

主区输入卡片按四张补充截图改为独立圆角白色表面、浅灰常态边框、聚焦细主题色轮廓和轻阴影，占位“现在的想法是...”；正文无悬停背景和分隔线。左侧工具按上方 v2.12 扩展，非聚焦极浅灰；右侧48×30dp按钮为20dp白色发布／麦克风图标，有文字／有效原音时主题色发布，空白时主题色麦克风。聚焦显示可见字符数，失焦隐藏；新建卡片无取消按钮、日期或常驻状态／更多工具。正文与工具共享点击区域，点击标签不丢正文焦点。历史编辑使用相同卡片和图标保存，切回新建暂存历史修改。独立`OmniNoteComposerButton`避免普通图标默认内缩轮廓和样式优先级覆盖业务外观，不修改共享普通按钮。深色模式保留主题表面及可读灰色，Android原有编辑呈现与自动保存继续沿用。

Windows 页面采用统计／8–12周热图／标签／回收站侧栏、新建草稿与单列卡片，双击原地展开，搜索位于右上角。侧栏默认264dp，拖动范围220–340dp，对应8–12列；分隔线仅分隔热区悬停显示浅灰、按下立即显示主题色，上下各留24dp空白，闲置透明。全侧栏含底部空白悬停显示隐藏按钮，隐藏后主区标题左侧显示恢复入口，当前草稿、筛选和宽度保留。三项统计分别左／中／右对齐，月份使用完整中文，移除近13周说明。首行派生标题，摘要最多两行。Ctrl+F 从正文或导航轨都聚焦笔记搜索；普通编辑保留筛选，外部定位清除遮挡条件。可用宽度不足900dp使用抽屉，减少动画时跳过卡片动画。

标签区域悬停显示管理、搜索和篇数，标题悬停强调并显示折叠箭头；标签搜索只筛选标签名称，关闭或Escape恢复全部。管理器提供新增、重命名、删除和持久化拖动排序，移除侧栏临时排序菜单。标签行悬停显示只有删除／改名的菜单，改名使用紧凑Omni弹窗，删除仅解除关联并移除失效筛选。热图提示恢复为`YYYY-MM-DD·N 篇笔记`。

按补充视频统一悬停入口120ms原位淡入／淡出，保留占位与子树，中途反向连续，隐藏立即排除点击／焦点／语义；减少动画即时切换。Windows共享普通图标、Popup菜单及原生主题图标采用28dp圆角方形背景、36dp布局及热区、18dp字形、零内边距，灰色在图标自身悬停／焦点时转正文色，保留业务颜色及嵌入约束，Android仍48dp。标签标题无灰底，左边缘对齐回收站图标；列表220ms向下展开／向上收起、中途反向连续，减少动画即时切换，窄栏大字号工具换行保持四字标题完整；搜索为36dp高、12dp圆角浅灰填充且无焦点描边，两侧图标在输入框内；三个点字形、方形背景和行内容实际中心一致，选中标签使用浅主题底色。

Windows 文字与原音只写本机草稿，发布／保存才原子提升为正式笔记及版本；Android 保持自动保存。取消或本机永久删除仅留下无正文、标签、基线与时间信息的草稿身份墓碑，阻止迟到事件复活。已补录音结束后延迟暂存、保存中切换、清理与新增草稿交错、录音启动中取消等竞态回归。

笔记类别只在notes模块退休。回收站查询／清空支持general、notes、all；到期清理覆盖all。历史 v2.5 基线为 SQLite19／schema4／本机快照4，当前 v2.12 已升为20／5／5，服务器迁移协议3分别管理；旧队列身份及原始负载摘要不改，服务端执行副本兼容退休类别。草稿原音备份和换服复制使用独立校验文件，选择服务器数据不会混入旧源草稿。

## 验证

2026-10-15点击残留修复：新增“点击后鼠标始终原位”像素断言，修前确实绘制纯黑，证据`build/notes-statistics-click-before.log`。原悬停测试在点击后移开鼠标，未覆盖该状态。自定义hover改为独立动画背景，Ink的hover恒透明；年份局部取消focus／highlight／splash填色，菜单关闭后仍保留真实焦点及键盘行为。明暗双向切换、年份按住／取消／选择后像素回归及共享组件共36项通过，`notes-statistics-click-after.log`；分析无问题、29项样式及格式／diff检查通过。

本次最终原生AX启用并完成20轮，`build/notes-statistics-click-native/{stdout,stderr}.log`无AXTree、框架异常或PROBE_FAILURE，探针已退出。生产Release83.0秒完成，`build/notes-statistics-click-release.log`；隔离副本生产Debug恢复main.dart入口，18.9秒成功，日志`build/notes-statistics-click-debug.log`，两份改动控件及展示源码与工作区一致。未操作用户正在运行的Debug进程。

2026-10-15悬停补充验收：统计弹窗、共享分段及组件展示共34项通过，`build/notes-statistics-hover-tests.log`；新增明暗实际像素采样与真实MouseTracker检查年份无hover底、月年手形、仅未选中项深灰以及切换／移出恢复。分析无问题、29项样式检查通过；生产Release重新构建51.1秒成功，`build/notes-statistics-hover-release.log`。本次局部调整未重跑原生AX，前阶段证据保留。

2026-10-15 v2.11记录统计验收：笔记相关179项全部通过，日志`build/notes-statistics-regression.log`；最终方块几何与纵轴样式调整后，17项弹窗回归和17项生产页面统计回归再次通过，见`notes-statistics-final-{dialog,ui}-tests.log`。覆盖归档跨年／闰日、正文Unicode／空白／纯录音、删除与草稿隔离、年份菜单与实时变化、加载失败重试、真实鼠标／键盘／读屏、筛选清理、抽屉关闭和草稿保留。

六套主题明暗、512×512与1.6字号及减少动画均通过；中文月历、年份菜单和年度预览位于`build/notes-statistics-preview`，24图总览`contact-sheet.png`已审阅。最终静态分析无问题，样式检查29项受控例外通过，新增1项仅用于专用Dialog布局；9个代码文件格式检查及diff检查通过。

Windows原生AX专项20轮完成，`PROBE_NATIVE_AX_ACTIVE:true`、`PROBE_COMPLETE`，没有AXTree错误、框架异常或PROBE_FAILURE；证据`build/notes-statistics-native/final-{stdout,stderr}.log`。探针使用内存数据库与录音替身，循环月历提示、年份菜单、月年切换及选择／关闭，不访问生产数据；进程已退出。

生产入口Windows Release构建55.2秒成功，`build/windows/x64/runner/Release`；用户运行中的Debug目录被占用，生产Debug改在`D:/ob-stats-1015`隔离源码副本构建，27.5秒成功，产物`D:/ob-stats-1015/build/windows/x64/runner/Debug`。6份本轮生产／探针源码SHA256与工作区一致；两份最终构建日志见`build/notes-statistics-{debug,release}-build.log`。原生探针保存在隔离副本的`native-final`，生产Debug已恢复`lib/main.dart`入口。

2026-10-15 v2.10：134项笔记回归通过（`build/notes-tag-row-regression.log`）；新增普通／减少动画的单行排序、70ms中途取消、精确归位、语义节点身份及700dp／1.6字号长标签横滚回归通过。静态分析无问题，UI样式检查28项受控例外通过。原生探针增加选中／中途取消标签，真实Windows辅助功能桥已启用，20轮完成、AXTree错误0、无PROBE_FAILURE（`build/notes-tag-row-native/{stdout,stderr}.log`）。生产Debug 17.6秒、Release 56.0秒构建完成，入口均为`lib/main.dart`；探针仅保留在独立build/notes-tag-row-native目录。

- v2.9专项155项全部通过（70秒），包括新建草稿预选常驻、多选显隐、反向与减少动画、隐藏语义排除、显式发布关联、侧栏管理／查询／改名删除及共享控件回归。最终静态分析无问题，样式仍44项受控例外；日志`build/notes-tags-ax-regression.log`、`build/notes-tags-ax-analyze.log`、`build/notes-tags-ax-style.log`。
- 原生Windows辅助功能桥已通过WM_GETOBJECT开启：相邻Tooltip负向对照20轮产生136条同类AXTree错误，使用边界后20轮0条；生产NotesPage多篇长文、标签与正文显隐、提示、编辑／取消、侧栏折叠、视口裁剪20轮0条。均有`PROBE_NATIVE_AX_ACTIVE:true`及`PROBE_COMPLETE`，同时检查stdout、stderr；不是仅以程序退出判断通过。日志`build/notes-ax-anchors-before.*.log`、`notes-ax-anchors-after.*.log`、`notes-ax-notes-after.*.log`。全部数据为进程内存与私有mock偏好，不读用户笔记，不启用设备或识别。
- 全客户端1022项通过、5项外部跳过、6项失败（132秒）。未修改HEAD `dc47339`在隔离目录复现相同6项：4项待办固定提醒时间在2026-10-14已过期，物品／会员2项旧Golden失败均为相同按钮边缘641px差异。本轮未更新无关截图或待办逻辑；日志`build/notes-tags-ax-all-client.log`与`build/notes-tags-ax-head-baseline.log`。
- 最终生产入口Debug通过（44.7秒），Release通过（61.0秒），恢复为`lib/main.dart`；两个常规构建均不含探针入口。日志`build/notes-tags-ax-debug.log`与`build/notes-tags-ax-release.log`，产物仍在`build/windows/x64/runner/Debug`和`Release`。没有关闭用户客户端或操作真实数据库。

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

v2.11预览：`build/notes-statistics-preview/windows-statistics-{palette}-{light|dark}-{month|menu|year}.png`为生产页面与虚构正式笔记数据；`windows-statistics-filtered-day.png`验证选日后仅显示当天记录且草稿保留。月／年各12图汇总在`contact-sheet.png`。

v2.10生产根应用预览在`apps/client/build/notes-tag-row-preview`：`windows-tags-single-row.png`、`windows-tags-selected-first.png`、`windows-tags-single-row-narrow.png`，已核对单行、选中前置及长名称横滚。

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

### 原生无障碍回归入口

`tool/notes_windows_accessibility_probe.dart`仅用于Windows内存数据验证，创建并退出自己的窗口。构建前确认Debug运行目录没有被占用，或复制生成的bundle到独立目录后运行；不要终止用户进程。运行探针后应以`--target lib/main.dart`恢复常规构建。

```powershell
flutter build windows --debug --no-pub --target tool/notes_windows_accessibility_probe.dart
# 以下在探针bundle所在目录执行，负向对照预期出现原生AXTree错误。
.\omni_butler.exe --anchors-only --unguarded
.\omni_butler.exe --anchors-only
.\omni_butler.exe
# 回到apps/client目录后恢复生产入口。
flutter build windows --debug --no-pub --target lib/main.dart
```

必须捕捉stderr检查`Failed to update ui::AXTree`和其他框架异常，并确认stdout有原生桥已启用及完成标记。单纯`ensureSemantics`只生成Dart语义树，不能代替Windows辅助功能桥验证。

v2.9中文预览在`build/notes-tags-picker-preview`：`windows-composer-selected-tags.png`、`windows-composer-tags-expanded.png`及`windows-tags-management.png`，已核对选中常驻、弹出选项及侧栏管理入口。

### 双击编辑音频与卡片悬停修复（2026-10-15）

带音频历史卡片在阅读／编辑切换时，Material Slider 的窗口级 OverlayPortal 可能序列化孤立语义节点，触发原生 AXTree 更新失败。Windows 的 `OmniNoteAudioSeekBar` 现在通过 `Overlay.wrap(alwaysSizeToContent: true, clipBehavior: Clip.none)` 将浮层留在同一控件子树；保留原生 Slider、24dp 高度、进度读屏和键盘操作。Android 沿用原有结构。相关上游记录见 [Flutter Slider 原生 AXTree 问题](https://github.com/flutter/flutter/issues/190357)，本项目修复以本机前后对照为验收依据。

历史阅读卡片局部使用 `OmniPanel.hoverColor: Colors.transparent`，鼠标进入不改变整卡背景；菜单、音频等内嵌操作的反馈及双击编辑继续保留。

`tool/notes_windows_accessibility_probe.dart --history-only` 使用内存库、无麦克风数据，轮换纯文字／标签／两段音频／标签加音频四组笔记，通过真实鼠标双击20轮，覆盖滚动裁剪、编辑聚焦、标签展开与取消。原生 AX 始终开启：同一轨迹修前371条AXTree错误，修后0条且完成／退出0。证据为 `build/notes-ax-hover-fix/{before,after}.{stdout,stderr}.log`。原生错误不会转成 Dart 异常，必须检查 stderr，不能只检查进程退出码。

`notes_page_test.dart` 新增明暗、普通／音频卡片的实际合成像素检查与双击／取消回归，修前hover白底变灰、修后通过（`hover-before.log`／`final-hover.log`）。`omni_note_audio_seek_bar_test.dart` 两端检查24dp尺寸、唯一滑块语义、键盘和读屏各执行一次，2项通过（`final-seek.log`）。原有笔记／音频／菜单回归98项通过（`regression.log` 中新增用例的初版测试宿主已在上述最终日志修正并通过）。本次不更新视觉基线。

补充 `--history-only --dark --narrow` 的780×900深色窗口20轮同样完成、原生AX开启、0错误（`dark-narrow.*.log`）。合计修后40轮原生鼠标验证通过；`flutter analyze --no-pub`、29项受控样式检查及格式检查通过。正式入口 `lib/main.dart` Windows Release 构建成功（58.7秒，`release-build.log`），产物 `build/windows/x64/runner/Release/omni_butler.exe`；用户正在运行的Debug实例未停止。
