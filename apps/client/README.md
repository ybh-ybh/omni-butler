# Omni Butler Client

Flutter 客户端，当前支持 Windows 桌面布局和 Android 紧凑布局。应用本地优先：第一期六个业务模块直接写入 SQLite；用户可在设置中显式连接自托管同步服务。

## 当前能力

- 首页、每日待办、事件管理、物品管理、24 小时时间记录、会员管理和设置共 7 个路由。
- Drift 管理本地数据；开启同步后，PowerSync 与 Drift 访问同一 SQLite 文件。
- 单一飞书蓝语义主题，支持跟随系统、浅色和深色。
- 本地图片只保存在应用私有目录，不进入当前 PowerSync Schema。
- Windows 与 Android 本地通知框架；发布包与真机验收状态见根目录 `未完成任务.md`。

## 常用命令

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
flutter build windows --release
```

需要真实同步链路的测试依赖根目录 `deploy/` 中的 PostgreSQL、NestJS 与 PowerSync 服务。项目范围、架构和剩余工作分别见根目录 `需求书.md`、`系统架构设计.md` 与 `未完成任务.md`。
