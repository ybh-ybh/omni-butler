// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/app_display_name.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/floating/data/floating_window_preferences.dart';
import 'package:omni_butler/features/floating/platform/windows_floating_resize_service.dart';
import 'package:omni_butler/features/floating/platform/windows_window_host.dart';
import 'package:omni_butler/features/timeline/data/time_entry_repository.dart';
import 'package:omni_butler/features/todos/data/todo_priority_quadrant.dart';
import 'package:omni_butler/features/todos/data/todo_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart' as win32;

/// Bound the lifetime of the isolated desktop probe.
const int _totalSeconds = int.fromEnvironment(
  'OMNI_GLASS_PROBE_SECONDS',
  defaultValue: 90,
);

/// Keep each still scene visible long enough for external screenshots.
const int _sceneSeconds = int.fromEnvironment(
  'OMNI_GLASS_PROBE_SCENE_SECONDS',
  defaultValue: 12,
);

/// Exercise real wallpaper composition with memory-only data and preferences.
/// Use direct screen capture: desktop DWM thumbnails can omit this backdrop.
Future<void> main() async {
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': 'light',
  });
  // Keep all preference writes in the test backend.
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // Never open the user's persistent database.
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // Use today's records so all production date filters stay active.
  final DateTime now = DateTime.now();
  await _seedRecords(database, now);
  // Share one isolated container with the production window coordinator.
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      appDatabaseProvider.overrideWithValue(database),
    ],
  );
  // Retain the discovered card without changing its parent or composition style.
  win32.HWND card = win32.HWND(nullptr);
  runWidget(
    UncontrolledProviderScope(
      container: container,
      child: const WindowsWindowHost(),
    ),
  );
  try {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await container
        .read(floatingWindowPreferenceProvider.notifier)
        .setEnabledFromSettings(true);
    card = await _waitForCard();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // Record the real desktop parent before any test work.
    final win32.HWND desktopParent = win32.GetParent(card).value;
    if (desktopParent == nullptr ||
        (win32.GetWindowLongPtr(card, win32.GWL_EXSTYLE).value &
                win32.WS_EX_LAYERED) !=
            0) {
      throw StateError(
        'The probe requires the production non-layered desktop card.',
      );
    }
    // Hide only the test application's main window, leaving user windows alone.
    final win32.HWND mainWindow = _findOwnWindow(title: appDisplayName);
    if (mainWindow != nullptr) {
      _setTitle(
        mainWindow,
        'Omni Glass Probe Main [${win32.GetCurrentProcessId()}]',
      );
      win32.ShowWindow(mainWindow, win32.SW_HIDE);
    }
    // Resolve the monitor from the restored production placement.
    final Rect originalBounds = _windowBounds(card);
    // Query the physical work area of that monitor.
    final Pointer<win32.MONITORINFO> monitorInfo = calloc<win32.MONITORINFO>();
    // Build deterministic test bounds inside the current work area.
    late final Rect testArea;
    try {
      monitorInfo.ref.cbSize = sizeOf<win32.MONITORINFO>();
      // Preserve the production card's monitor and DPI.
      final win32.HMONITOR monitor = win32.MonitorFromWindow(
        card,
        win32.MONITOR_DEFAULTTONEAREST,
      );
      if (!win32.GetMonitorInfo(monitor, monitorInfo)) {
        throw StateError('Unable to read the test monitor work area.');
      }
      testArea = Rect.fromLTRB(
        monitorInfo.ref.rcWork.left.toDouble(),
        monitorInfo.ref.rcWork.top.toDouble(),
        monitorInfo.ref.rcWork.right.toDouble(),
        monitorInfo.ref.rcWork.bottom.toDouble(),
      ).deflate(40);
    } finally {
      calloc.free(monitorInfo);
    }
    // Keep the production minimum dimensions and a moderate desktop preview width.
    final double scale = win32.GetDpiForWindow(card) / 96;
    // Fit the preview without changing the desktop's display configuration.
    final double width = math.min(360 * scale, testArea.width);
    // Preserve a full-height composition and its input controls.
    final double height = math.min(600 * scale, testArea.height);
    // Sample the real wallpaper at three positions without changing it.
    final List<Rect> placements = List<Rect>.generate(
      3,
      (int index) => Rect.fromLTWH(
        testArea.left + (testArea.width - width) * index / 2,
        testArea.center.dy - height / 2,
        width,
        height,
      ),
      growable: false,
    );
    // Retain the current still placement as the later resize anchor.
    Rect cardBounds = placements.first;
    // Use the same native resize service as production.
    final WindowsFloatingResizeService resizeService =
        WindowsFloatingResizeService();
    await resizeService.setBounds(card.address, cardBounds);
    stdout.writeln(
      'PROBE pid=${win32.GetCurrentProcessId()} card=${card.address} '
      'parent=${desktopParent.address} dpi=${win32.GetDpiForWindow(card)} '
      'original=$originalBounds preview=$cardBounds background=real-wallpaper',
    );
    // Track total time independently from per-scene waits.
    final Stopwatch elapsed = Stopwatch()..start();
    // Emit exactly one transition log per scene.
    int previousScene = -1;
    // Reserve the final interval for repeated resize motion.
    final int stillSeconds = math.min(
      math.max(6, _totalSeconds - 18),
      math.max(1, _sceneSeconds) * 6,
    );
    while (elapsed.elapsed.inSeconds < math.max(1, _totalSeconds)) {
      if (!win32.IsWindow(card) ||
          win32.GetParent(card).value != desktopParent) {
        throw StateError('The production card was closed or reparented.');
      }
      // Toggle the main app mode while the floating card must remain dark.
      final int scene = elapsed.elapsed.inSeconds < stillSeconds
          ? math.min(
              5,
              elapsed.elapsedMilliseconds * 6 ~/ (stillSeconds * 1000),
            )
          : 6;
      if (scene != previousScene) {
        previousScene = scene;
        // Keep the final dark theme during resize to isolate geometry changes.
        final ThemeMode theme = scene == 6 || scene.isOdd
            ? ThemeMode.dark
            : ThemeMode.light;
        await container
            .read(themeControllerProvider.notifier)
            .setThemeMode(theme);
        // The last scene keeps the rightmost placement as its fixed anchor.
        final int position = scene == 6 ? 2 : scene ~/ 2;
        cardBounds = placements[position];
        await resizeService.setBounds(card.address, cardBounds);
        _setTitle(
          card,
          'Omni Glass Probe [${win32.GetCurrentProcessId()}] '
          '${scene == 6 ? 'resize' : 'scene-${scene + 1}'} ${theme.name}',
        );
        stdout.writeln(
          'SCENE ${scene + 1}: theme=dark '
          'background=wallpaper-${<String>['left', 'center', 'right'][position]} appTheme=${theme.name} '
          'elapsed=${elapsed.elapsedMilliseconds} bounds=${_windowBounds(card)}',
        );
      }
      if (scene == 6) {
        // Move the left edge while preserving the right and top anchors.
        final double phase = (elapsed.elapsedMilliseconds % 4000) / 2000;
        // Keep the test within the current monitor, including larger DPI scales.
        final double minimumWidth = math.min(294 * scale, cardBounds.width);
        // Keep the entire resize inside the work area with an invariant right edge.
        final double maximumWidth = math.min(
          550 * scale,
          cardBounds.right - testArea.left,
        );
        // Apply a continuous triangular wave without touching user cursor input.
        final double animatedWidth =
            minimumWidth +
            (maximumWidth - minimumWidth) * (phase <= 1 ? phase : 2 - phase);
        await resizeService.setBounds(
          card.address,
          Rect.fromLTWH(
            cardBounds.right - animatedWidth,
            cardBounds.top,
            animatedWidth,
            cardBounds.height,
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    stdout.writeln(
      'PASS: probe scenes completed; inspect screen captures for transparency.',
    );
    await _exitOwnProcess();
  } catch (error, stackTrace) {
    stderr.writeln('FAIL: $error\n$stackTrace');
    exit(1);
  }
}

/// Seed representative task colors, progress, and an ongoing timer.
Future<void> _seedRecords(AppDatabase database, DateTime now) async {
  // Create records through production repositories in the isolated database.
  final TodoRepository todos = TodoRepository(database);
  // Use the local natural date for the floating window's active filter.
  final DateTime today = DateUtils.dateOnly(now);
  await todos.save(
    TodoDraft(
      title: '完成 Windows 悬浮窗设计',
      scheduledDate: today,
      priorityQuadrant: TodoPriorityQuadrant.urgentImportant,
    ),
  );
  await todos.save(
    TodoDraft(
      title: '阅读《设计心理学》',
      scheduledDate: today,
      taskType: TodoTaskType.progress,
      progressSteps: List<TodoProgressStepDraft>.generate(
        6,
        (int index) => TodoProgressStepDraft(name: '第 ${index + 1} 章'),
      ),
    ),
  );
  await todos.save(
    TodoDraft(
      title: '整理今天的会议笔记',
      scheduledDate: today,
      priorityQuadrant: TodoPriorityQuadrant.urgentNotImportant,
    ),
  );
  await TimeEntryRepository(database).save(
    TimeEntryDraft(
      activity: '专注工作',
      category: '工作',
      startedAt: now.subtract(const Duration(minutes: 25)),
    ),
  );
}

/// Read the physical bounds used in screenshot and resize diagnostics.
Rect _windowBounds(win32.HWND window) {
  // Release the native output buffer after copying it into a Dart value.
  final Pointer<win32.RECT> bounds = calloc<win32.RECT>();
  try {
    if (!win32.GetWindowRect(window, bounds).value) {
      throw StateError('Unable to read probe window bounds.');
    }
    return Rect.fromLTRB(
      bounds.ref.left.toDouble(),
      bounds.ref.top.toDouble(),
      bounds.ref.right.toDouble(),
      bounds.ref.bottom.toDouble(),
    );
  } finally {
    calloc.free(bounds);
  }
}

/// Annotate only a window already verified as belonging to this process.
void _setTitle(win32.HWND window, String value) {
  // Keep the native UTF-16 value alive only for the synchronous call.
  final Pointer<Utf16> title = value.toNativeUtf16();
  try {
    win32.SetWindowText(window, win32.PCWSTR(title));
  } finally {
    calloc.free(title);
  }
}

/// Wait for the card to be attached to the unchanged production desktop parent.
Future<win32.HWND> _waitForCard() async {
  for (int attempt = 0; attempt < 100; attempt += 1) {
    // The title is still the production title before the probe annotates it.
    final win32.HWND card = _findOwnWindow(
      title: '$appDisplayName · 今日',
      desktop: true,
    );
    if (card != nullptr) return card;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('No production desktop card appeared within five seconds.');
}

/// Request the production tray exit command only for this test process.
Future<void> _exitOwnProcess() async {
  // The tray is owned by the same production window coordinator as the card.
  final win32.HWND tray = _findOwnWindow(className: 'OmniButlerTrayWindow');
  if (tray == nullptr) throw StateError('The isolated tray window is missing.');
  win32.SendMessage(
    tray,
    win32.WM_COMMAND,
    const win32.WPARAM(41003),
    const win32.LPARAM(0),
  );
  await Future<void>.delayed(const Duration(seconds: 5));
  throw StateError(
    'The isolated application did not exit after its tray command.',
  );
}

/// Find only a matching window whose process ID equals this test process.
win32.HWND _findOwnWindow({
  String? className,
  String? title,
  bool desktop = false,
}) {
  // Allocate the optional native class name.
  final Pointer<Utf16>? nativeClass = className?.toNativeUtf16();
  // Allocate the optional native window title.
  final Pointer<Utf16>? nativeTitle = title?.toNativeUtf16();
  // Reuse a process ID buffer for every candidate.
  final Pointer<Uint32> processId = calloc<Uint32>();
  // Enumerate the traditional desktop hosts.
  final Pointer<Utf16> workerClass = 'WorkerW'.toNativeUtf16();
  // Include the fallback desktop host.
  final Pointer<Utf16> progmanClass = 'Progman'.toNativeUtf16();
  // Include the modern layered desktop icon subtree.
  final Pointer<Utf16> viewClass = 'SHELLDLL_DefView'.toNativeUtf16();
  try {
    // Search the real desktop tree only when explicitly requested.
    final List<win32.HWND?> parents = desktop
        ? <win32.HWND?>[]
        : <win32.HWND?>[null, win32.HWND_MESSAGE];
    if (desktop) {
      // Enumerate all existing WorkerW siblings without modifying Explorer.
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
      for (final win32.HWND? parent in List<win32.HWND?>.of(parents)) {
        if (parent == null || parent == nullptr) continue;
        // A modern card may live directly under SHELLDLL_DefView.
        final win32.HWND view = win32.FindWindowEx(
          parent,
          null,
          win32.PCWSTR(viewClass),
          null,
        ).value;
        if (view != nullptr) parents.add(view);
      }
    }
    for (final win32.HWND? parent in parents) {
      // Walk every title/class match until its process ID is verified.
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
    calloc.free(processId);
    calloc.free(workerClass);
    calloc.free(progmanClass);
    calloc.free(viewClass);
  }
}
