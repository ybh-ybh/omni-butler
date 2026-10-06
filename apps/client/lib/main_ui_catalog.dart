// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:omni_butler/dev/ui_catalog.dart';

/// 启动不读取业务数据库和本机偏好的独立组件展示应用。
void main() {
  // 产品的 Windows runner 只创建引擎，展示入口也必须显式创建首个窗口。
  if (Platform.isWindows) {
    isWindowingEnabled = true;
    WidgetsFlutterBinding.ensureInitialized();
    runWidget(const _CatalogWindow());
    return;
  }
  runApp(const OmniUiCatalogApp());
}

/// 为纯内存组件目录提供独立窗口，不初始化主应用的业务协调器。
class _CatalogWindow extends StatefulWidget {
  /// 创建目录窗口。
  const _CatalogWindow();

  /// 创建窗口生命周期状态。
  @override
  State<_CatalogWindow> createState() => _CatalogWindowState();
}

/// 管理组件目录的唯一原生窗口。
class _CatalogWindowState extends State<_CatalogWindow> {
  /// 只负责目录窗口，不连接托盘或悬浮窗偏好。
  late final RegularWindowController _controller;

  /// 创建与产品 runner 兼容的首个 Flutter View。
  @override
  void initState() {
    super.initState();
    _controller = RegularWindowController(
      title: 'Omni UI · 组件展示',
      size: const Size(1280, 900),
      constraints: const BoxConstraints(minWidth: 520, minHeight: 520),
      delegate: _CatalogWindowDelegate(),
    );
    // Windows 引擎宿主不会自动显示新窗口，完成创建后主动激活。
    _controller.activate();
  }

  /// 释放窗口控制资源。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 在真实窗口中复用同一个可测试组件目录。
  @override
  Widget build(BuildContext context) => RegularWindow(
    controller: _controller,
    child: WindowManager(child: const OmniUiCatalogApp()),
  );
}

/// 目录关闭后退出独立预览进程，不留下没有窗口的引擎。
class _CatalogWindowDelegate with RegularWindowControllerDelegate {
  /// 响应原生窗口关闭请求。
  @override
  void onWindowCloseRequested(RegularWindowController controller) {
    controller.destroy();
  }

  /// 唯一窗口已经销毁，结束纯内存预览进程。
  @override
  void onWindowDestroyed() => exit(0);
}
