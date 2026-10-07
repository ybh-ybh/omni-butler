// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/floating/data/floating_window_preferences.dart';
import 'package:omni_butler/features/floating/platform/windows_floating_resize_service.dart';
import 'package:omni_butler/features/floating/platform/windows_window_host.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart' as win32;

/// 每种模式持续秒数，可用 --dart-define=OMNI_PROBE_MODE_SECONDS=12 配置。
const int _modeSeconds = int.fromEnvironment(
  'OMNI_PROBE_MODE_SECONDS',
  defaultValue: 12,
);

/// 探针总时长，可用 --dart-define=OMNI_PROBE_TOTAL_SECONDS=180 配置。
const int _totalSeconds = int.fromEnvironment(
  'OMNI_PROBE_TOTAL_SECONDS',
  defaultValue: 180,
);

/// 仅使用内存数据，对照旧整窗透明层、合成等待与修复后的非 layered 宿主。
Future<void> main() async {
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // 本测试独立的偏好对象。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 不连接用户数据库的内存实例。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 生产窗口使用的隔离状态容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
    ],
  );
  // 当前测试创建的卡片。
  win32.HWND card = win32.HWND(nullptr);
  // 当前测试创建的可截图顶层宿主。
  win32.HWND wrapper = win32.HWND(nullptr);
  // 清理时恢复的卡片原始父级。
  win32.HWND originalParent = win32.HWND(nullptr);
  // 清理时恢复的卡片扩展样式。
  int originalStyle = 0;
  runWidget(
    UncontrolledProviderScope(
      container: container,
      child: const WindowsWindowHost(),
    ),
  );
  try {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await container
          .read(floatingWindowPreferenceProvider.notifier)
          .setEnabledFromSettings(true);
      // 有界轮询本测试进程卡片完成创建，避免碰到其他实例。
      for (int attempt = 0; attempt < 100 && card == nullptr; attempt += 1) {
        card = _findOwnWindow(title: 'Omni Butler · 今日', desktop: true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (card == nullptr) throw StateError('未找到本测试进程的悬浮卡片');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      originalParent = win32.GetParent(card).value;
      originalStyle = win32.GetWindowLongPtr(card, win32.GWL_EXSTYLE).value;
      // 按实际窗口 DPI 换算测试逻辑尺寸。
      final double scale = win32.GetDpiForWindow(card) / 96;
      // 宿主物理宽度，限定在当前主屏幕内。
      final int width = math.min(
        (850 * scale).round(),
        win32.GetSystemMetrics(win32.SM_CXSCREEN) - 120,
      );
      // 宿主物理高度，预留标题栏及桌面边距。
      final int height = math.min(
        (550 * scale).round(),
        win32.GetSystemMetrics(win32.SM_CYSCREEN) - 160,
      );
      wrapper = _createWrapper(width, height);
      win32.SetParent(card, wrapper);
      win32.SetWindowPos(
        card,
        win32.HWND_TOP,
        0,
        0,
        0,
        0,
        win32.SWP_NOMOVE |
            win32.SWP_NOSIZE |
            win32.SWP_NOACTIVATE |
            win32.SWP_SHOWWINDOW,
      );
      if (win32.GetParent(card).value != wrapper) {
        throw StateError('测试卡片未挂载到可观察宿主');
      }
      // 宿主客户区尺寸缓冲区。
      final Pointer<win32.RECT> client = calloc<win32.RECT>();
      // 客户区原点对应的屏幕坐标。
      final Pointer<win32.POINT> origin = calloc<win32.POINT>();
      try {
        win32.GetClientRect(wrapper, client);
        win32.ClientToScreen(wrapper, origin);
        // 固定的屏幕右边界。
        final double right = (origin.ref.x + client.ref.right - 20).toDouble();
        // 固定的屏幕顶边界。
        final double top = (origin.ref.y + 20).toDouble();
        // 缩放最大宽度和卡片高度均限制在宿主客户区内。
        final double maxWidth = math.min(800 * scale, client.ref.right - 40.0);
        // 最小宽度使用产品常见的窄卡片尺寸。
        final double minWidth = math.min(320 * scale, maxWidth);
        // 固定高度，避免引入竖向变量。
        final double cardHeight = math.min(
          450 * scale,
          client.ref.bottom - 40.0,
        );
        // 总运行时钟，确保探针可以自动结束。
        final Stopwatch elapsed = Stopwatch()..start();
        // 顺序运行的模式序号。
        int modeIndex = 0;
        while (elapsed.elapsed.inSeconds < math.max(1, _totalSeconds)) {
          await _runMode(
            card,
            wrapper,
            originalStyle,
            modeIndex % 3,
            right,
            top,
            minWidth,
            maxWidth,
            cardHeight,
            math.min(
              math.max(3, _modeSeconds) * 1000,
              math.max(1, _totalSeconds) * 1000 - elapsed.elapsedMilliseconds,
            ),
          );
          modeIndex += 1;
        }
      } finally {
        calloc.free(client);
        calloc.free(origin);
      }
    } finally {
      if (card != nullptr && win32.IsWindow(card)) {
        win32.ShowWindow(card, win32.SW_HIDE);
        _restoreStyle(card, originalStyle);
        win32.SetParent(card, originalParent);
      }
      if (wrapper != nullptr && win32.IsWindow(wrapper)) {
        win32.ShowWindow(wrapper, win32.SW_HIDE);
      }
    }
    // 仅向本测试进程的托盘发送生产退出命令。
    final win32.HWND tray = _findOwnWindow(className: 'OmniButlerTrayWindow');
    if (tray == nullptr) throw StateError('未找到本测试进程的托盘窗口');
    stdout.writeln('PASS: visual probe completed; requesting own tray exit');
    win32.SendMessage(
      tray,
      win32.WM_COMMAND,
      const win32.WPARAM(41003),
      const win32.LPARAM(0),
    );
    await Future<void>.delayed(const Duration(seconds: 5));
    throw StateError('本测试进程未在五秒内退出');
  } catch (error, stackTrace) {
    stderr.writeln('FAIL: $error\n$stackTrace');
    exit(1);
  }
}

/// 复用本进程的 Flutter 主窗口，避免 STATIC 没有可捕获的合成表面。
win32.HWND _createWrapper(int width, int height) {
  // 标题带本进程 ID，避免与其他测试实例混淆。
  final Pointer<Utf16> title =
      'Omni Floating Resize Probe [${win32.GetCurrentProcessId()}]'
          .toNativeUtf16();
  try {
    // 主窗口属于隔离测试进程，不能按可见标题操作生产实例。
    final win32.HWND window = _findOwnWindow(title: 'Omni Butler');
    if (window == nullptr) throw StateError('未找到测试主窗口');
    win32.SetWindowText(window, win32.PCWSTR(title));
    win32.SetWindowPos(
      window,
      win32.HWND_TOP,
      60,
      60,
      width,
      height,
      win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW,
    );
    win32.ShowWindow(window, win32.SW_SHOWNOACTIVATE);
    return window;
  } finally {
    calloc.free(title);
  }
}

/// 每次通道完成后继续往返缩放，并在模式首尾各静止一秒。
Future<void> _runMode(
  win32.HWND card,
  win32.HWND wrapper,
  int originalStyle,
  int mode,
  double right,
  double top,
  double minWidth,
  double maxWidth,
  double height,
  int durationMilliseconds,
) async {
  // 当前模式名称，供外部观察窗口标题。
  final String name = <String>[
    'legacy-layered',
    'layered-DwmFlush',
    'no-layered',
  ][mode];
  // 临时标题字符串。
  final Pointer<Utf16> title =
      'Omni Floating Resize Probe [${win32.GetCurrentProcessId()}] - $name'
          .toNativeUtf16();
  try {
    win32.SetWindowText(wrapper, win32.PCWSTR(title));
  } finally {
    calloc.free(title);
  }
  // 即使生产实现已移除 layered，前两组仍显式还原旧路径作为阳性对照。
  _restoreStyle(
    card,
    mode == 2
        ? originalStyle & ~win32.WS_EX_LAYERED
        : originalStyle | win32.WS_EX_LAYERED,
  );
  stdout.writeln('MODE: $name; duration=${durationMilliseconds}ms');
  // 复用生产异步尺寸提交入口。
  final WindowsFloatingResizeService service = WindowsFloatingResizeService();
  // 当前模式的运行时钟。
  final Stopwatch elapsed = Stopwatch()..start();
  while (elapsed.elapsedMilliseconds < durationMilliseconds) {
    if (!win32.IsWindow(wrapper) || !win32.IsWindow(card)) {
      throw StateError('测试窗口被提前关闭');
    }
    // 首尾保持最大宽度，中间按固定周期往返移动左边缘。
    final int activeMilliseconds = (elapsed.elapsedMilliseconds - 1000).clamp(
      0,
      math.max(0, durationMilliseconds - 2000),
    );
    // 两秒完成一次缩小及放大的往返。
    final double phase = (activeMilliseconds % 2000) / 1000;
    // 三角波宽度变化，不改变屏幕右边界。
    final double width =
        maxWidth - (maxWidth - minWidth) * (phase <= 1 ? phase : 2 - phase);
    await service.setBounds(
      card.address,
      Rect.fromLTWH(right - width, top, width, height),
    );
    if (mode == 1) win32.DwmFlush();
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  _restoreStyle(card, originalStyle);
}

/// 恢复生产透明样式，使每种模式从相同状态开始。
void _restoreStyle(win32.HWND card, int style) {
  win32.SetWindowLongPtr(card, win32.GWL_EXSTYLE, style);
  if ((style & win32.WS_EX_LAYERED) != 0) {
    win32.SetLayeredWindowAttributes(
      card,
      const win32.COLORREF(0),
      246,
      win32.LWA_ALPHA,
    );
  }
}

/// 限定当前进程查找卡片或托盘，不操作用户正在运行的实例。
win32.HWND _findOwnWindow({
  String? className,
  String? title,
  bool desktop = false,
}) {
  // 可选窗口类名。
  final Pointer<Utf16>? nativeClass = className?.toNativeUtf16();
  // 可选窗口标题。
  final Pointer<Utf16>? nativeTitle = title?.toNativeUtf16();
  // 桌面宿主窗口类名。
  final Pointer<Utf16> workerClass = 'WorkerW'.toNativeUtf16();
  // 桌面回退宿主类名。
  final Pointer<Utf16> progmanClass = 'Progman'.toNativeUtf16();
  // 分层桌面图标视图也可能直接承载本进程卡片。
  final Pointer<Utf16> desktopViewClass = 'SHELLDLL_DefView'.toNativeUtf16();
  // 进程归属检查缓冲区。
  final Pointer<Uint32> processId = calloc<Uint32>();
  try {
    // 查找范围限定为桌面子窗口或顶层及消息窗口。
    final List<win32.HWND?> parents = desktop
        ? <win32.HWND?>[]
        : <win32.HWND?>[null, win32.HWND_MESSAGE];
    if (desktop) {
      // 当前遍历到的桌面宿主。
      win32.HWND worker = win32.FindWindowEx(
        null,
        null,
        win32.PCWSTR(workerClass),
        null,
      ).value;
      while (worker != nullptr) {
        parents.add(worker);
        worker = win32.FindWindowEx(
          null,
          worker,
          win32.PCWSTR(workerClass),
          null,
        ).value;
      }
      parents.add(win32.FindWindow(win32.PCWSTR(progmanClass), null).value);
      for (final win32.HWND? host in List<win32.HWND?>.of(parents)) {
        if (host == null || host == nullptr) continue;
        final win32.HWND view = win32.FindWindowEx(
          host,
          null,
          win32.PCWSTR(desktopViewClass),
          null,
        ).value;
        if (view != nullptr) parents.add(view);
      }
    }
    // 按各候选父级遍历，但最终仍以进程归属为准。
    for (final win32.HWND? parent in parents) {
      // 当前匹配标题或类名的候选窗口。
      win32.HWND match = win32.FindWindowEx(
        parent,
        null,
        nativeClass == null ? null : win32.PCWSTR(nativeClass),
        nativeTitle == null ? null : win32.PCWSTR(nativeTitle),
      ).value;
      while (match != nullptr) {
        win32.GetWindowThreadProcessId(match, processId);
        if (processId.value == win32.GetCurrentProcessId()) return match;
        match = win32.FindWindowEx(
          parent,
          match,
          nativeClass == null ? null : win32.PCWSTR(nativeClass),
          nativeTitle == null ? null : win32.PCWSTR(nativeTitle),
        ).value;
      }
    }
    return win32.HWND(nullptr);
  } finally {
    if (nativeClass != null) calloc.free(nativeClass);
    if (nativeTitle != null) calloc.free(nativeTitle);
    calloc.free(workerClass);
    calloc.free(progmanClass);
    calloc.free(desktopViewClass);
    calloc.free(processId);
  }
}
