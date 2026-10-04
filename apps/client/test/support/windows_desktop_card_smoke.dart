// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:omni_butler/features/floating/platform/windows_desktop_card_controller.dart';
import 'package:win32/win32.dart' as win32;

/// 独立原生回归入口：不初始化生产数据库和用户偏好。
void main() {
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  runWidget(const _SmokeHost());
}

/// 提供原生多窗口回归宿主。
class _SmokeHost extends StatefulWidget {
  /// 创建回归宿主。
  const _SmokeHost();

  /// 创建宿主状态。
  @override
  State<_SmokeHost> createState() => _SmokeHostState();
}

/// 创建并反复销毁真实桌面子窗口。
class _SmokeHostState extends State<_SmokeHost> {
  /// 保持引擎运行的独立主窗口。
  late final RegularWindowController _main = RegularWindowController(
    size: const Size(512, 512),
    title: 'Omni floating lifecycle smoke',
  );

  /// 包含待测窗口的注册表。
  WindowRegistry? _registry;

  /// 构建主视图并开始检查。
  @override
  Widget build(BuildContext context) => RegularWindow(
    controller: _main,
    child: WindowManager(
      child: Builder(
        builder: (BuildContext context) {
          if (_registry == null) {
            _registry = WindowRegistry.of(context);
            unawaited(_checkLifecycle());
          }
          return const SizedBox.shrink();
        },
      ),
    ),
  );

  /// 不依赖 assert（Profile 会禁用），明确检查每次销毁的实际 Win32 状态。
  Future<void> _checkLifecycle() async {
    // 桌面父窗口类名。
    final Pointer<Utf16> className = 'Progman'.toNativeUtf16();
    try {
      // Windows Explorer 的实际桌面窗口。
      final win32.HWND desktop = win32.FindWindow(
        win32.PCWSTR(className),
        null,
      ).value;
      if (desktop == nullptr) {
        throw StateError('未找到桌面，无法验证跨进程 SetParent');
      }
      for (int cycle = 0; cycle < 5; cycle += 1) {
        // 当前周期的真实悬浮窗控制器。
        final WindowsDesktopCardController controller =
            WindowsDesktopCardController(
              size: const Size(294, 500),
              constraints: const BoxConstraints(minWidth: 294, minHeight: 500),
              title: 'Omni desktop card smoke $cycle',
              delegate: const _SmokeDelegate(),
            );
        // 创建时的真实宿主句柄。
        final win32.HWND host = win32.HWND(controller.windowHandle);
        // 对应的视图注册条目。
        final WindowEntry entry = WindowEntry(
          controller: controller,
          builder: (BuildContext context) =>
              const ColoredBox(color: Colors.blue),
        );
        _registry!.register(entry);
        await WidgetsBinding.instance.endOfFrame;
        // 挂载到桌面时使用的原生样式。
        final int style = win32.GetWindowLongPtr(host, win32.GWL_STYLE).value;
        win32.SetWindowLongPtr(
          host,
          win32.GWL_STYLE,
          (style & ~win32.WS_POPUP) | win32.WS_CHILD,
        );
        win32.SetParent(host, desktop);
        if (win32.GetAncestor(host, win32.GA_ROOT) != desktop ||
            win32.HWND(controller.windowHandle) != host) {
          throw StateError('桌面父级变化后控制器没有保持真实句柄');
        }
        // 连续左扩时始终读取本窗口客户区尺寸，不能读到桌面尺寸。
        final Pointer<win32.RECT> clientRect = calloc<win32.RECT>();
        try {
          for (int width = 350; width <= 550; width += 10) {
            win32.SetWindowPos(
              host,
              null,
              700 - width,
              100,
              width,
              500,
              win32.SWP_NOACTIVATE | win32.SWP_NOZORDER | win32.SWP_NOCOPYBITS,
            );
            win32.GetClientRect(host, clientRect);
            if ((controller.contentSize.width *
                            controller.rootView.devicePixelRatio -
                        clientRect.ref.right)
                    .abs() >
                1) {
              throw StateError('缩放时控制器读取了错误父窗口的尺寸');
            }
          }
        } finally {
          calloc.free(clientRect);
        }
        win32.ShowWindow(host, win32.SW_HIDE);
        controller.destroy();
        _registry!.unregister(entry);
        if (win32.IsWindow(host)) {
          throw StateError('第 $cycle 次关闭仍残留原生窗口');
        }
        controller.dispose();
        await WidgetsBinding.instance.endOfFrame;
      }
      stdout.writeln(
        'PASS: 5 desktop-parented windows destroyed without residue',
      );
      _main.destroy();
      await ServicesBinding.instance.exitApplication(ui.AppExitType.required);
    } catch (error, stackTrace) {
      stderr.writeln('FAIL: $error\n$stackTrace');
      exit(1);
    } finally {
      calloc.free(className);
    }
  }
}

/// 回归使用的默认关闭委托。
class _SmokeDelegate with RegularWindowControllerDelegate {
  /// 创建关闭委托。
  const _SmokeDelegate();
}
