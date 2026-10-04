// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:flutter/widgets.dart';
import 'package:flutter/src/widgets/_window_win32.dart';

/// 固定真实宿主句柄，避免挂到 WorkerW 后 GA_ROOT 返回 Explorer 的窗口。
class WindowsDesktopCardController extends RegularWindowControllerWin32 {
  /// 在修改原生父级之前记录 Flutter 创建的宿主窗口。
  WindowsDesktopCardController({
    required super.size,
    required super.constraints,
    required super.title,
    required super.delegate,
  }) : super(
         owner: WidgetsBinding.instance.windowingOwner as WindowingOwnerWin32,
         resizable: true,
       ) {
    _hostHandle = super.windowHandle;
  }

  /// 创建时的实际宿主句柄，不随桌面父窗口变化。
  late final HWND _hostHandle;

  /// 所有控制器操作始终指向本应用窗口，而不是桌面宿主。
  @override
  HWND get windowHandle => _hostHandle;
}
