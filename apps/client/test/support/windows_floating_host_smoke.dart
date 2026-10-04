// ignore_for_file: implementation_imports, invalid_use_of_internal_member

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
  }
}
