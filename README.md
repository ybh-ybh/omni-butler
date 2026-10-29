# 知序

知序（Omni Butler）是本地优先的个人生活与效率工具，支持 Windows 和 Android。业务模块包括名言、待办、事件、物品、时间、会员和笔记；客户端可离线管理数据，按需连接自托管服务进行同步、语音识别和 AI 处理。

## 从这里开始

| 目标 | 文档 |
| --- | --- |
| 运行和开发 Flutter 客户端 | [客户端说明](apps/client/README.md) |
| 运行和开发 NestJS API | [服务端说明](apps/server/README.md) |
| 部署 PostgreSQL、API、PowerSync 和 MinIO | [部署指南](deploy/README.md) |
| 理解离线数据、上传事务和换服 | [同步设计](apps/server/docs/sync-design.md) |
| 理解七模块业务写入与幂等机制 | [业务层说明](apps/server/src/business/README.md) |
| 接入外部 MCP 或应用内助手 | [MCP](apps/server/src/mcp/README.md)、[助手](apps/server/src/assistant/README.md) |
| 修改界面和公共控件 | [界面规范](style.md) |

`apps/client` 使用 Flutter、Riverpod、Drift/SQLite 和 PowerSync；`apps/server` 使用 NestJS、Prisma 和 PostgreSQL。`deploy` 管理自托管服务，`spec` 保存产品与设计文档，`agent_memory` 保存开发过程上下文。

## 启动客户端

先安装仓库 CI 使用的 Flutter SDK（版本见 [UI 检查配置](.github/workflows/ui-checks.yml)），并准备对应平台的开发环境。在仓库根目录的 PowerShell 中运行：

```powershell
cd apps/client
$env:PUB_HOSTED_URL = 'https://pub.dev' # 与客户端锁文件及 CI 使用同一包源。
flutter pub get --enforce-lockfile # 校验锁定的依赖版本及摘要。
flutter run --no-pub -d windows
```

Android 开发先启动自己的模拟器或连接设备`emulator -avd omni_test -no-snapshot-load`，
用 `flutter devices` 查询实际设备 ID，再执行 `flutter run --no-pub -d <设备ID>`。`flutter run --no-pub -d emulator-5554`
客户端默认使用本机数据；需要服务器功能时，按部署指南配置服务并在设置中连接。

