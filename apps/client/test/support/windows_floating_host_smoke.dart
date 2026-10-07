// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/floating/data/floating_window_preferences.dart';
import 'package:omni_butler/features/floating/platform/windows_window_host.dart';
import 'package:omni_butler/features/floating/platform/windows_floating_resize_service.dart';
import 'package:omni_butler/features/floating/platform/floating_resize_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart' as win32;

/// 在独立内存数据上验证生产协调器的设置关闭、卡片关闭和托盘退出。
Future<void> main() async {
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // 独立的偏好存储，不触碰用户设备配置。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 独立的内存数据库，不连接生产库和同步服务。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 生产界面和测试操作共用的独立状态容器。
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
    ],
  );
  runWidget(
    UncontrolledProviderScope(
      container: container,
      child: const WindowsWindowHost(),
    ),
  );
  try {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (int cycle = 0; cycle < 3; cycle += 1) {
      await container
          .read(floatingWindowPreferenceProvider.notifier)
          .setEnabledFromSettings(true);
      // 本周期创建的真实桌面卡片。
      final win32.HWND card = await _waitForCard();
      if (cycle == 0) {
        _checkDesktopCompositionHost(card);
        await _checkResizeBounds(card);
      }
      await container
          .read(floatingWindowPreferenceProvider.notifier)
          .setEnabledFromSettings(false);
      if (win32.IsWindow(card)) {
        throw StateError('设置关闭后仍有残留窗口，周期 $cycle');
      }
      await container
          .read(floatingWindowPreferenceProvider.notifier)
          .setEnabled(true);
      // 右上角关闭和原生 WM_CLOSE 共用的生产关闭入口。
      final win32.HWND closeCard = await _waitForCard();
      win32.SendMessage(
        closeCard,
        win32.WM_CLOSE,
        const win32.WPARAM(0),
        const win32.LPARAM(0),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (win32.IsWindow(closeCard) ||
          container.read(floatingWindowPreferenceProvider).enabled) {
        throw StateError('卡片关闭后窗口或偏好未清理，周期 $cycle');
      }
    }
    await container
        .read(floatingWindowPreferenceProvider.notifier)
        .setEnabled(true);
    await _waitForCard();
    // 仅查找本测试进程的托盘消息窗口，不能操作用户正在运行的实例。
    win32.HWND tray = win32.HWND(nullptr);
    for (int attempt = 0; attempt < 100 && tray == nullptr; attempt += 1) {
      tray = _findOwnWindow('OmniButlerTrayWindow');
      if (tray == nullptr) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (tray == nullptr) {
      throw StateError('未找到本测试进程的托盘窗口');
    }
    stdout.writeln(
      'PASS: 3 settings-close + 3 card-close cycles; requesting real tray exit',
    );
    win32.SendMessage(
      tray,
      win32.WM_COMMAND,
      const win32.WPARAM(41003),
      const win32.LPARAM(0),
    );
    // 若正常退出未发生，五秒后以明确失败终止测试，避免留下测试窗口。
    await Future<void>.delayed(const Duration(seconds: 5));
    throw StateError('托盘退出五秒内未结束进程');
  } catch (error, stackTrace) {
    stderr.writeln('FAIL: $error\n$stackTrace');
    exit(1);
  }
}

/// 分层桌面图标视图内的卡片必须与图标进入同一合成窗口树。
void _checkDesktopCompositionHost(win32.HWND card) {
  // 桌面视图类名，用于检查真实父级对应的合成路径。
  final Pointer<Utf16> viewClass = 'SHELLDLL_DefView'.toNativeUtf16();
  try {
    // 直接父级可能是传统桌面宿主，也可能是分层图标视图。
    final win32.HWND parent = win32.GetParent(card).value;
    // 以图标视图为父级时，外层才是 WorkerW/Progman。
    final win32.HWND outerHost = win32.GetParent(parent).value;
    // 传统挂载和新版挂载都需要查询相应宿主的直接图标视图。
    win32.HWND desktopView = win32.FindWindowEx(
      parent,
      null,
      win32.PCWSTR(viewClass),
      null,
    ).value;
    if (desktopView == nullptr && outerHost != nullptr) {
      desktopView = win32.FindWindowEx(
        outerHost,
        null,
        win32.PCWSTR(viewClass),
        null,
      ).value;
    }
    if (desktopView != nullptr &&
        (win32.GetWindowLongPtr(desktopView, win32.GWL_EXSTYLE).value &
                win32.WS_EX_LAYERED) !=
            0 &&
        parent != desktopView) {
      throw StateError('非 layered 卡片仍挂在分层桌面图标视图外，可能不可见');
    }
  } finally {
    calloc.free(viewClass);
  }
}

/// 验证连续横/竖及斜向缩放中宿主和内部视图同步，且右/上边界不漂移。
Future<void> _checkResizeBounds(win32.HWND card) async {
  // 首帧已挂到桌面不代表异步显示器查询和初始位置恢复已完成。
  await Future<void>.delayed(const Duration(milliseconds: 500));
  // 初始窗口屏幕矩形。
  final Pointer<win32.RECT> bounds = calloc<win32.RECT>();
  // Flutter 渲染子窗口类名。
  final Pointer<Utf16> contentClass = 'FLUTTERVIEW'.toNativeUtf16();
  // 子视图客户区尺寸缓冲区。
  final Pointer<win32.RECT> client = calloc<win32.RECT>();
  // 原生异步尺寸通道。
  final WindowsFloatingResizeService service = WindowsFloatingResizeService();
  try {
    win32.GetWindowRect(card, bounds);
    // 缩放时保持的右边缘物理坐标。
    final int right = bounds.ref.right;
    // 缩放时保持的顶边缘物理坐标。
    final int top = bounds.ref.top;
    // 原始物理宽度。
    final int baseWidth = bounds.ref.right - bounds.ref.left;
    // 原始物理高度。
    final int baseHeight = bounds.ref.bottom - bounds.ref.top;
    // 本进程卡片的实际内部视图。
    final win32.HWND content = win32.FindWindowEx(
      card,
      null,
      win32.PCWSTR(contentClass),
      null,
    ).value;
    if (content == nullptr) throw StateError('悬浮窗缺少 Flutter 子视图');
    if ((win32.GetWindowLongPtr(card, win32.GWL_EXSTYLE).value &
            win32.WS_EX_LAYERED) !=
        0) {
      throw StateError('悬浮窗重新启用了会导致横向抖动的整窗透明层');
    }
    if ((win32.GetWindowLongPtr(card, win32.GWL_EXSTYLE).value &
            win32.WS_EX_LAYOUTRTL) ==
        0) {
      throw StateError('宿主没有按固定右边缘定位渲染子视图');
    }
    if ((win32.GetWindowLongPtr(content, win32.GWL_EXSTYLE).value &
            win32.WS_EX_LAYOUTRTL) !=
        0) {
      throw StateError('Flutter 子视图错误继承了宿主镜像布局');
    }
    // 高频指针更新只覆盖最新目标。
    Rect target = Rect.fromLTWH(
      (right - baseWidth).toDouble(),
      top.toDouble(),
      baseWidth.toDouble(),
      baseHeight.toDouble(),
    );
    // 累计已完成并检查的原生缩放数量。
    int checked = 0;
    // 使用与生产手势完全相同的串行尺寸提交器。
    final FloatingResizeScheduler scheduler = FloatingResizeScheduler(() async {
      // 本次原生提交的稳定快照。
      final Rect submitted = target;
      await service.setBounds(card.address, submitted);
      win32.GetWindowRect(card, bounds);
      win32.GetClientRect(content, client);
      if (bounds.ref.left != submitted.left.round() ||
          bounds.ref.top != top ||
          bounds.ref.right != right ||
          bounds.ref.bottom != submitted.bottom.round() ||
          client.ref.left != 0 ||
          client.ref.top != 0 ||
          client.ref.right != submitted.width.round() ||
          client.ref.bottom != submitted.height.round()) {
        throw StateError(
          '父子窗口边界不同步或固定边缘漂移：'
          'target=${submitted.left},${submitted.top},${submitted.right},${submitted.bottom}; '
          'host=${bounds.ref.left},${bounds.ref.top},${bounds.ref.right},${bounds.ref.bottom}; '
          'client=${client.ref.left},${client.ref.top},${client.ref.right},${client.ref.bottom}',
        );
      }
      // 子视图屏幕边界必须与宿主一致，不能只验证客户区宽高。
      final Pointer<win32.RECT> contentBounds = calloc<win32.RECT>();
      // 鼠标坐标仍从子视图左上角开始，而非宿主的右侧原点。
      final Pointer<win32.POINT> pointer = calloc<win32.POINT>();
      try {
        win32.GetWindowRect(content, contentBounds);
        pointer.ref
          ..x = contentBounds.ref.left + 20
          ..y = contentBounds.ref.top + 30;
        win32.ScreenToClient(content, pointer);
        if (contentBounds.ref.left != bounds.ref.left ||
            contentBounds.ref.right != bounds.ref.right ||
            contentBounds.ref.top != bounds.ref.top ||
            contentBounds.ref.bottom != bounds.ref.bottom ||
            pointer.ref.x != 20 ||
            pointer.ref.y != 30) {
          throw StateError('右锚定改变了子视图的位置或鼠标坐标');
        }
      } finally {
        calloc.free(contentBounds);
        calloc.free(pointer);
      }
      checked += 1;
    });
    try {
      // 分别覆盖横向、竖向和斜向往返，并重复反向，模拟录屏的快速拖动。
      for (int axis = 0; axis < 3; axis += 1) {
        // 一个方向内连续提交的指针事件序号。
        for (int step = 0; step < 40; step += 1) {
          // 每二十次事件反转方向，包含放大和缩小。
          final int delta = (step < 20 ? step : 39 - step) * 12;
          target = Rect.fromLTWH(
            (right - baseWidth - (axis == 1 ? 0 : delta)).toDouble(),
            top.toDouble(),
            (baseWidth + (axis == 1 ? 0 : delta)).toDouble(),
            (baseHeight + (axis == 0 ? 0 : delta)).toDouble(),
          );
          // 观察更新失败，同时继续发送高频事件，让提交器覆盖过期目标。
          unawaited(
            scheduler.schedule().catchError((Object error) {
              stderr.writeln('FAIL: $error');
              exit(1);
            }),
          );
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await scheduler.flush();
      }
      stdout.writeln(
        'PASS: $checked synchronized resize frames from 120 updates',
      );
    } finally {
      scheduler.dispose();
    }
  } finally {
    calloc.free(bounds);
    calloc.free(client);
    calloc.free(contentClass);
  }
}

/// 等待生产协调器完成首帧挂载及桌面父级设置。
Future<win32.HWND> _waitForCard() async {
  for (int attempt = 0; attempt < 100; attempt += 1) {
    // 本进程已经挂到桌面的卡片窗口。
    final win32.HWND card = _findOwnWindow(
      null,
      title: 'Omni Butler · 今日',
      searchDesktop: true,
    );
    if (card != nullptr) {
      return card;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('五秒内未创建桌面卡片');
}

/// 按原生窗口类/标题查找，但始终限制为当前测试进程。
win32.HWND _findOwnWindow(
  String? className, {
  String? title,
  bool searchDesktop = false,
}) {
  // 原生窗口类字符串。
  final Pointer<Utf16>? nativeClass = className?.toNativeUtf16();
  // 原生窗口标题字符串。
  final Pointer<Utf16>? nativeTitle = title?.toNativeUtf16();
  // 用于校验所属进程的缓冲区。
  final Pointer<Uint32> processId = calloc<Uint32>();
  // 桌面窗口类名。
  final Pointer<Utf16> workerClass = 'WorkerW'.toNativeUtf16();
  // 桌面回退窗口类名。
  final Pointer<Utf16> progmanClass = 'Progman'.toNativeUtf16();
  // 新版 Windows 的卡片可能位于图标视图内部。
  final Pointer<Utf16> desktopViewClass = 'SHELLDLL_DefView'.toNativeUtf16();
  try {
    // 需要搜索的原生父窗口，null 表示顶层/消息窗口。
    final List<win32.HWND?> parents = searchDesktop
        ? <win32.HWND?>[]
        : <win32.HWND?>[null, win32.HWND_MESSAGE];
    if (searchDesktop) {
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
    for (final win32.HWND? parent in parents) {
      // 同父级下当前遍历到的匹配窗口。
      win32.HWND match = win32.FindWindowEx(
        parent,
        null,
        nativeClass == null ? null : win32.PCWSTR(nativeClass),
        nativeTitle == null ? null : win32.PCWSTR(nativeTitle),
      ).value;
      while (match != nullptr) {
        win32.GetWindowThreadProcessId(match, processId);
        if (processId.value == win32.GetCurrentProcessId()) {
          return match;
        }
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
    calloc.free(processId);
    calloc.free(workerClass);
    calloc.free(progmanClass);
    calloc.free(desktopViewClass);
  }
}
