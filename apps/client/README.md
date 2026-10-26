# Omni Butler Client

Flutter 客户端，当前支持 Windows 桌面布局和 Android 紧凑布局。应用本地优先：业务模块直接写入 SQLite；用户可在设置中显式连接自托管同步服务。

## 依赖与发布验证

`pubspec.lock` 统一使用 `https://pub.dev`，本机验证与 CI 必须使用相同版本和归档摘要。在 PowerShell 中先设置 `$env:PUB_HOSTED_URL = 'https://pub.dev'`，再运行 `flutter pub get --enforce-lockfile`；依赖就绪后，分析、测试及构建均添加 `--no-pub`。包源不匹配或锁文件校验失败时应停止发布，不删除锁文件重新解析依赖。

Android 原生插件依赖使用锁定版本；调整依赖或混淆配置后，发布验收需包含最终签名 APK 的真机冷启动与再次启动。Widget 测试或构建成功不能替代原生插件启动验证。

## 当前能力

- 首页、每日待办、事件管理、物品管理、24 小时时间记录、会员管理、笔记、AI 助手和设置。
- Drift 管理本地数据；开启同步后，PowerSync 与 Drift 访问同一 SQLite 文件。
- 待办支持普通任务和进度任务：可命名步骤、跳序记录、满进度后手动确认，规则与升级说明见 [进度任务](docs/progress-todos.md)。
- 统一 Omni 组件与克制 Apple 风格；保留六套配色及跟随系统、浅色和深色模式。
- 物品与会员主图在服务器开启图片同步后自动补传、下载到本机缓存；首页背景始终仅保存在本机。图片通过已认证 API 传输，不进入 PowerSync Schema。
- 设置中的服务器连接先预检，再选择首次合并、以本机覆盖服务器或使用服务器数据；跨数据源时保留旧库，候选库确认同步检查点后才启用。
- Windows 与 Android 本地通知框架；发布时需在目标设备验证权限、触发与后台行为。

## 笔记

支持本机草稿、显式发布／保存、历史编辑、置顶、标签、记录日期、组合搜索、统计、图片、录音、转写及 AI 整理。Windows 双击卡片原位编辑；Android 历史笔记使用全屏编辑，退出时保存，提交失败保留原页。原音与转写独立保存，迟到结果不覆盖人工正文，未知计费回执沿用原操作身份恢复。

架构、平台交互、保存冲突、数据升级和回归入口见[笔记模块维护指南](docs/notes-redesign.md)，产品规则见[笔记 PRD](../../spec/笔记功能PRD.md)，服务端音频能力见[笔记原音说明](../server/src/notes/README.md)。数据版本以数据库、认证同步和快照源码中的常量为准，升级先备份并部署数据库／API／PowerSync，再更新客户端。

### 本机测试笔记维护

`tool/clear_note_test_data_test.dart` 是一次性开发维护入口，默认仅预览，没有产品清空按钮。仅适用于用户已明确授权且服务器不存在这些笔记数据的本机测试库；不能用于已有服务器笔记的设备，否则服务器下行可能重新带回数据。

先从托盘菜单正常退出所有安装版、调试版客户端，等待保存、录音及同步任务结束。工具从 Documents 的 `omni_butler_connection.sqlite` 读取活动库；未完成迁移时拒绝执行。必须显式提供安装应用实际 Support 目录，不能采用 Flutter 测试宿主的目录。以下命令在 `apps/client` 中运行，路径需按实际安装调整：

```powershell
# 本机应用数据目录，不采用测试宿主的Support目录。
$noteCleanupSupport = Join-Path $env:APPDATA 'com.omnibutler\omni_butler'
flutter test --no-pub tool/clear_note_test_data_test.dart --concurrency=1 --reporter expanded "--dart-define=NOTE_TEST_CLEANUP_SUPPORT=$noteCleanupSupport"
```

预览核对活动库、录音目录及数量后，同一命令加 `--dart-define=NOTE_TEST_CLEANUP_EXECUTE=true` 执行。可用 `NOTE_TEST_CLEANUP_DOCUMENTS` 显式指定 Documents 根目录。

执行前通过真实 PowerSync 的 `VACUUM INTO` 保存一致性数据库备份，并复制原音和未确认恢复清单至 `Documents/note-test-cleanup-backups/<UUID>`。`manifest.json` 保存源路径、文件摘要和阶段：`backed-up`、`database-cleaned`、`completed`；失败会报错，不能把中间阶段视为完成。恢复时先关闭全部客户端，将 `database.sqlite` 还原到清单中的原业务库路径，并按文件清单还原原件；一并移除本次对应笔记的录音删除标记，保留其他标记。保持活动索引不变，不覆盖历史迁移备份。

维护范围为全部笔记、版本、原音元数据、本机转写状态、当前源原音缓存和未确认录音；持久删除标记防止恢复清单复活记录。只移除 `ps_crud` 中三张笔记同步表的操作，逐行核对其他模块数据、类别/标签定义、设备元数据及其他队列的内容、ID、事务身份保持一致。完成后再次以默认预览运行，全部笔记计数应为零。

## 常用命令

```powershell
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter run -d windows --no-pub
flutter build windows --release --no-pub
```

需要真实同步链路的测试依赖 PostgreSQL、NestJS 与 PowerSync 服务，配置见[部署指南](../../deploy/README.md)。项目概览见[仓库说明](../../README.md)，架构设计见[系统架构设计](../../spec/系统架构设计.md)。

## 界面规范与组件预览

新增页面、弹窗和控件遵守根目录 [style.md](../../style.md)，优先从 `shared/ui/omni_ui.dart` 选择公共组件。入口、受控例外与验收范围见 [UI 入口与回归指南](docs/ui-migration.md)。

```powershell
flutter run --no-pub -t lib/main_ui_catalog.dart -d windows
dart tool/check_ui_style.dart
flutter test --no-pub test/ui_catalog_test.dart
```

组件目录只使用内存状态，不连接业务数据库。`flutter test --no-pub tool/ui_pages_preview_test.dart` 可生成带真实中文字体的业务预览；字体配置见 `style.md`。CI 会检查新增绕过公共控件的入口及组件契约。

## 更换服务器与迁移恢复

在「设置 → 数据同步」选择「更换服务器」，也可以先断开并保留本机数据，再连接新服务器。地址、端口和密钥预检不保存新会话、不改变现有数据。首次连接合并双方数据；已经绑定其他数据源时，必须明确选择保留本机还是保留服务器。相同 owner 继续原增量同步。

以本机覆盖服务器会在服务端一个事务内替换业务数据及 owner，旧设备会话失效。只导入此刻本机已有数据，包括未上传修改、软删除记录与历史，不要求旧服务器在线。采用服务器数据不会上传旧本机队列。两种策略都保留应用设置；采用服务器时，物品/会员图片仅按相同类型和记录 ID 恢复，其他图片在原库备份中保留。

候选库持久记录已经完成数据初始化，打开页面或重启不会重新添加默认名言和时间分类。采用空服务器后业务库保持为空，后续由用户正常新增数据。

迁移期间主窗口、悬浮窗和数据库写入门禁暂停业务编辑，自动续费和通知协调暂停。网络或进程中断后，下次启动显示迁移恢复页面，点击「继续迁移」复用原操作身份。只有尚未发送可能改变服务器的请求时才能取消；提交结果未知时不会重新创建迁移 ID 或再次清库。完成条件包含上传回执和当前服务器检查点，不以网络已连接代替完成。

本地文档目录中的 `omni_butler_connection.sqlite` 保存活动库和会话键引用；业务库最初仍为 `omni_butler.sqlite`，迁移候选及完整逻辑快照位于 `sync_migrations/<迁移ID>/`。密钥只在系统安全存储中保存。设置里的「迁移备份」可查看确切路径并手动清理旧数据库和快照，当前数据库及共享图片不被清理。不要仅复制正在写入的 SQLite 主文件作为备份，也不要手动修改控制库或迁移快照。

新迁移协议需先升级后端，PowerSync 服务至少 1.24.0；仓库固定镜像为 1.25.0。完整上传上限为 100000 条、32 MB，服务端事务上限 60 秒。空间检查和候选库准备失败时不会发起服务器替换。

## 图片同步

服务端通过 `IMAGE_SYNC_ENABLED=false` 控制图片业务。改为 `true` 后，沿用 `docker compose up -d --build --wait` 启用图片同步；MinIO 是笔记与图片共用的常驻服务。客户端自动发现能力，无需填写对象存储地址或密钥。关闭后只停止图片传输，笔记音频仍可用，并保留本机文件、服务器对象及凭据，再开启继续同步。

已有图片自动补传；服务器已经存在的图片及明确清空标记优先于旧设备图片。用户换图、移除图片以编辑时见到的版本提交；并发冲突采用服务器版本，保留原本机文件并显示失败状态。待处理操作写入本机 SQLite，断网或重启后继续；每 30 秒检查远端清单并将图片下载到私有目录，校验摘要后展示，离线仍可使用缓存。单张图片上限 20 MiB，支持 PNG、JPEG、WebP、GIF。

更换服务器时，本机可用图片随新数据集补传；目标已有图片仍优先。仅存在于旧服务器、尚未缓存的图片不会阻塞业务数据迁移，确认页、完成后的设置页及备份详情显示缺图记录。图片传输停止并排空后才拍摄迁移快照。回收站图片在服务器保留，永久删除业务记录后由后台清理不再引用的对象。

图片集成回归需要隔离的 `omni-image-test` Docker 项目，显式运行 `flutter test --no-pub test/image_sync_e2e_test.dart --dart-define=OMNI_IMAGE_E2E=true`；普通测试跳过不代表真实链路已通过。

## 迁移回归

在仓库根目录启动专属隔离环境（不会使用日常部署卷）：

```powershell
docker compose -p omni-migration-e2e -f deploy/compose.migration-test.yml up -d --build --wait
```

在 `apps/client` 显式运行真实链路：

```powershell
flutter test --no-pub test/powersync_migration_e2e_test.dart --dart-define=OMNI_MIGRATION_E2E=true
```

测试只允许 `127.0.0.1:35430` 的专属 API，使用测试配置中的公开测试密钥。它会重建该测试数据源，覆盖三客户端、丢响应恢复、真实下行延迟、图片关联及冷启动。普通 `flutter test --no-pub` 会跳过此外部测试，跳过不代表已验证。清理前核对容器和卷的 Compose 项目标签仅为 `omni-migration-e2e`，禁止清理 `deploy` 或其他项目卷。
