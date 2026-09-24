import 'dart:io';

import 'package:flutter/services.dart';

/// Windows Runner 内置托盘与 Dart 业务状态之间的桥接服务。
class WindowsTrayService {
  /// 创建托盘桥接服务并注册原生事件处理器。
  WindowsTrayService() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// Windows Runner 托盘通道。
  static const MethodChannel _channel = MethodChannel('omni/windows_tray');

  /// 打开主界面事件处理器。
  void Function()? onOpen;

  /// 切换悬浮窗事件处理器。
  void Function()? onToggle;

  /// 退出应用事件处理器。
  void Function()? onExit;

  /// 创建托盘图标和菜单。
  Future<void> initialize({required bool floatingEnabled}) async {
    // 当前可执行文件所在目录。
    final String executableDirectory = File(Platform.resolvedExecutable)
        .parent
        .path;
    // 打包后的托盘图标绝对路径。
    final String iconPath = <String>[
      executableDirectory,
      'data',
      'flutter_assets',
      'windows',
      'runner',
      'resources',
      'app_icon.ico',
    ].join(Platform.pathSeparator);
    await _channel.invokeMethod<void>('initialize', <String, Object>{
      'iconPath': iconPath,
      'floatingEnabled': floatingEnabled,
    });
  }

  /// 同步托盘菜单中的悬浮窗勾选状态。
  Future<void> setFloatingEnabled(bool enabled) async {
    await _channel.invokeMethod<void>('setFloatingEnabled', enabled);
  }

  /// 销毁托盘图标及其隐藏消息窗口。
  Future<void> destroy() async {
    await _channel.invokeMethod<void>('destroy');
  }

  /// 分发 Windows Runner 发回的托盘菜单事件。
  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'event') {
      return;
    }
    // 原生托盘事件名称。
    final String? eventName = call.arguments as String?;
    switch (eventName) {
      case 'open':
        onOpen?.call();
      case 'toggle':
        onToggle?.call();
      case 'exit':
        onExit?.call();
    }
  }
}
