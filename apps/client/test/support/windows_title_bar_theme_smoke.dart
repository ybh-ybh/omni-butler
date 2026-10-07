// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_chrome_colors.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/app/theme/windows_theme_transition.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/floating/platform/windows_window_host.dart';
import 'package:omni_butler/features/floating/presentation/windows_title_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart' as win32;

/// 使用生产多窗口宿主与独立内存数据验证真实 Windows 标题栏属性。
Future<void> main() async {
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{
    'appearance.theme_mode': 'dark',
  });
  // 独立偏好，不读写用户配置。
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // 独立数据库，不访问用户数据或同步服务器。
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  // 生产窗口和验证操作共用的测试状态。
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
    await Future<void>.delayed(const Duration(milliseconds: 600));
    // 仅匹配本进程的真实主窗口，避免操作用户正在运行的实例。
    final win32.HWND mainWindow = _findOwnMainWindow();
    if (mainWindow == nullptr) throw StateError('未找到测试主窗口');
    // 原生创建与首帧主题回调分属不同消息阶段，等待实际兼容标题栏挂载。
    for (int attempt = 0; attempt < 30; attempt += 1) {
      try {
        _expectTitleBar(mainWindow, container.read(themeControllerProvider));
        break;
      } catch (_) {
        if (attempt == 29) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    _expectTitleBar(mainWindow, container.read(themeControllerProvider));
    _expectMinimumWindowSize(mainWindow);
    // 可选导出生产窗口的主题动画帧，不读取或改变用户数据。
    final String? themeCapture =
        Platform.environment['OMNI_THEME_TRANSITION_CAPTURE'];
    if (themeCapture != null) {
      await _captureThemeTransitions(container, Directory(themeCapture));
    }
    if (Platform.environment['OMNI_TITLE_BAR_MONITORS'] == '1') {
      await _expectMonitorMaximization(mainWindow);
    }
    if (Platform.environment['OMNI_TITLE_BAR_DRAG'] == '1') {
      await _waitForExternalDrag(mainWindow, container);
    }
    await _expectWindowControls(mainWindow);
    _expectMinimumWindowSize(mainWindow);
    if (Platform.environment['OMNI_TITLE_BAR_TRANSITIONS'] == '1') {
      await container
          .read(themeControllerProvider.notifier)
          .setThemeMode(ThemeMode.light);
      await container
          .read(themeControllerProvider.notifier)
          .setThemePalette(AppThemePalette.slate);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      stdout.writeln('RECORD:${mainWindow.address}');
      await Future<void>.delayed(const Duration(seconds: 2));
      // 重复真实按钮操作，供外部录制中间帧而非只截最终尺寸。
      for (int transition = 0; transition < 6; transition += 1) {
        // 记录按钮回调是否仍同步阻塞到原生 resize 等待超时。
        final Stopwatch buttonTimer = Stopwatch()..start();
        _findCustomTitleBar(WidgetsBinding.instance.rootElement!)!
            .onToggleMaximize();
        stdout.writeln(
          'TOGGLE:$transition:callback=${buttonTimer.elapsedMicroseconds}us',
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
        _expectCaptionHitAreas(mainWindow);
      }
      stdout.writeln('RECORD_DONE');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    // 每个配色都在浅色和深色下检查真实原生背景、文字及按钮明暗。
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      await container.read(themeControllerProvider.notifier).setThemeMode(mode);
      // 配色切换不改变明暗模式，也必须触发原生标题栏更新。
      for (final AppThemePalette palette in AppThemePalette.values) {
        await container
            .read(themeControllerProvider.notifier)
            .setThemePalette(palette);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        _expectTitleBar(mainWindow, container.read(themeControllerProvider));
        if (Platform.environment['OMNI_TITLE_BAR_CAPTURE'] == '1' &&
            (palette == AppThemePalette.slate ||
                palette == AppThemePalette.seaSalt)) {
          stdout.writeln(
            'CAPTURE:${mainWindow.address}:${palette.id}-${mode.name}',
          );
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    }
    // 连续切换验证应用模式优先于系统明暗配置。
    for (final ThemeMode mode in <ThemeMode>[
      ThemeMode.light,
      ThemeMode.dark,
      ThemeMode.light,
      ThemeMode.system,
    ]) {
      await container.read(themeControllerProvider.notifier).setThemeMode(mode);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _expectTitleBar(mainWindow, container.read(themeControllerProvider));
    }
    // 系统亮度通知在固定浅色或深色模式下也不能覆盖应用偏好。
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      await container.read(themeControllerProvider.notifier).setThemeMode(mode);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // 模拟引擎先将原生标题栏重置为系统主题的真实窗口消息。
      win32.SendMessage(
        mainWindow,
        win32.WM_DWMCOLORIZATIONCOLORCHANGED,
        const win32.WPARAM(0),
        const win32.LPARAM(0),
      );
      // 只改系统强调色不会触发 Flutter 亮度回调，原生宿主也必须自行恢复。
      _expectTitleBar(mainWindow, container.read(themeControllerProvider));
      WidgetsBinding.instance.handlePlatformBrightnessChanged();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _expectTitleBar(mainWindow, container.read(themeControllerProvider));
    }
    stdout.writeln(
      'PASS: cold start; 6 palettes x 2 modes with native/custom caption colors; '
      'light/dark/system switches; brightness notifications; drag hit areas; '
      'maximize/restore/minimize; maximized client work area; non-topmost',
    );
    exit(0);
  } catch (error, stackTrace) {
    stderr.writeln('FAIL: $error\n$stackTrace');
    exit(1);
  }
}

/// 在实际 Windows 引擎上导出明暗和配色过渡，复用生产宿主和内存数据库。
Future<void> _captureThemeTransitions(
  ProviderContainer container,
  Directory output,
) async {
  await output.create(recursive: true);
  // 与生产设置入口使用同一个偏好控制器。
  final ThemeController controller = container.read(
    themeControllerProvider.notifier,
  );
  await controller.setThemePalette(AppThemePalette.seaSalt);
  await controller.setThemeMode(ThemeMode.light);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await _saveThemeFrame(output, '01-light');
  await controller.setThemeMode(ThemeMode.dark);
  await WidgetsBinding.instance.endOfFrame;
  await _saveThemeFrame(output, '02-dark-start');
  await Future<void>.delayed(const Duration(milliseconds: 180));
  await _saveThemeFrame(output, '03-dark-middle');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await _saveThemeFrame(output, '04-dark-end');
  await controller.setThemeMode(ThemeMode.light);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await controller.setThemePalette(AppThemePalette.slate);
  await WidgetsBinding.instance.endOfFrame;
  await _saveThemeFrame(output, '05-palette-start');
  await Future<void>.delayed(const Duration(milliseconds: 180));
  await _saveThemeFrame(output, '06-palette-middle');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await _saveThemeFrame(output, '07-palette-end');
  // 超过截图链上限多次，验证实际 Windows 栅格线程无迟到异常。
  for (int index = 0; index < 40; index += 1) {
    await controller.setThemeMode(
      index.isEven ? ThemeMode.dark : ThemeMode.light,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await _saveThemeFrame(output, '08-after-rapid-switches');
  stdout.writeln(
    'PASS: theme frames exported; 40 rapid theme switches settled',
  );
}

/// 读取主题过渡组件的实际复合图层，保存包括自绘标题栏在内的画面。
Future<void> _saveThemeFrame(Directory output, String name) async {
  await WidgetsBinding.instance.endOfFrame;
  // 只查找本次验证窗口中的生产主题过渡组件。
  Element? transition;
  // 遍历元素时不触发业务点击或额外主题重建。
  void findTransition(Element element) {
    if (element.widget is WindowsThemeTransition) {
      transition = element;
      return;
    }
    element.visitChildren(findTransition);
  }

  findTransition(WidgetsBinding.instance.rootElement!);
  // 第一层重绘边界包含活页面和前景旧图遮罩。
  RenderRepaintBoundary? boundary;
  // 从主题组件下寻找复合画面边界，避开更深层的活页面边界。
  void findBoundary(Element element) {
    if (boundary != null) return;
    // 当前元素对应的渲染对象。
    final RenderObject? renderObject = element.findRenderObject();
    if (renderObject is RenderRepaintBoundary) {
      boundary = renderObject;
      return;
    }
    element.visitChildren(findBoundary);
  }

  if (transition == null) throw StateError('主窗口未接入主题过渡');
  findBoundary(transition!);
  if (boundary == null) throw StateError('主窗口无可捕获的主题画面');
  // 使用引擎完成渲染后的图像，验证生产绘制链而不是模拟颜色。
  final ui.Image image = await boundary!.toImage();
  try {
    // PNG 字节只写入显式指定的验证目录。
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('${output.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

/// 保持测试窗口静止，等待外部工具完成真实拖动和过程录制。
Future<void> _waitForExternalDrag(
  win32.HWND window,
  ProviderContainer container,
) async {
  // 可选的绝对信号文件路径，由外部工具在完成拖动后创建。
  final String? gatePath = Platform.environment['OMNI_TITLE_BAR_DRAG_GATE'];
  // 不主动创建或删除信号文件，避免误读前一轮验证留下的状态。
  final File? gate = gatePath == null ? null : File(gatePath);
  if (gate != null && (!gate.isAbsolute || await gate.exists())) {
    throw StateError('拖动完成信号必须是尚不存在的绝对文件路径：$gatePath');
  }
  await container
      .read(themeControllerProvider.notifier)
      .setThemeMode(ThemeMode.light);
  await container
      .read(themeControllerProvider.notifier)
      .setThemePalette(AppThemePalette.slate);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('DRAG_READY:${window.address}');
  await stdout.flush();
  if (gate == null) {
    // 无信号文件时提供完整二十秒，由外部工具独占鼠标和窗口操作。
    await Future<void>.delayed(const Duration(seconds: 20));
  } else {
    // 使用异步计时保持 Flutter 和原生窗口消息循环继续运行。
    final Stopwatch waitTimer = Stopwatch()..start();
    while (!await gate.exists()) {
      if (waitTimer.elapsed >= const Duration(seconds: 30)) {
        throw StateError('等待外部拖动完成信号超时：$gatePath');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  stdout.writeln('DRAG_DONE:${window.address}');
}

/// 查找标题相同且属于本测试进程的主窗口。
win32.HWND _findOwnMainWindow() {
  // 原生标题字符串。
  final Pointer<Utf16> title = 'Omni Butler'.toNativeUtf16();
  // 用于筛除其他应用实例的进程标识。
  final Pointer<Uint32> processId = calloc<Uint32>();
  try {
    // 当前同名顶层窗口。
    win32.HWND match = win32.FindWindowEx(
      null,
      null,
      null,
      win32.PCWSTR(title),
    ).value;
    while (match != nullptr) {
      win32.GetWindowThreadProcessId(match, processId);
      if (processId.value == win32.GetCurrentProcessId()) return match;
      match = win32.FindWindowEx(null, match, null, win32.PCWSTR(title)).value;
    }
    return win32.HWND(nullptr);
  } finally {
    calloc.free(title);
    calloc.free(processId);
  }
}

/// 读取真实 DWM 属性确认标题栏已同步，而非只检查偏好状态。
void _expectTitleBar(win32.HWND window, ThemePreference preference) {
  // 真实应用在当前偏好下解析得到的明暗模式。
  final Brightness brightness = switch (preference.mode) {
    ThemeMode.dark => Brightness.dark,
    ThemeMode.light => Brightness.light,
    ThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
  };
  // 标题栏必须与 Flutter 导航使用同一语义颜色。
  final OmniChromeColors chrome = AppTheme.build(
    brightness: brightness,
    palette: preference.palette,
  ).extension<OmniChromeColors>()!;
  // 按钮明暗取决于导航实际底色，而不是内容区明暗模式。
  final bool isDark =
      ThemeData.estimateBrightnessForColor(chrome.background) ==
      Brightness.dark;
  // DWM 返回的四字节 Windows BOOL。
  final Pointer<Int32> actual = calloc<Int32>();
  try {
    win32.DwmGetWindowAttribute(
      window,
      win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
      actual,
      sizeOf<Int32>(),
    );
    if ((actual.value != 0) != isDark) {
      throw StateError('标题栏明暗不一致：实际 ${actual.value}，期望深色 $isDark');
    }
  } finally {
    calloc.free(actual);
  }
  if ((win32.GetWindowLongPtr(window, win32.GWL_STYLE).value &
          win32.WS_CAPTION) !=
      0) {
    _expectColorAttribute(window, win32.DWMWA_CAPTION_COLOR, chrome.background);
    _expectColorAttribute(window, win32.DWMWA_TEXT_COLOR, chrome.foreground);
  } else {
    // 在不支持 DWM 配色的系统上检查实际挂载的自绘标题栏。
    final WindowsTitleBar? caption = _findCustomTitleBar(
      WidgetsBinding.instance.rootElement!,
    );
    if (caption == null ||
        caption.colors.background != chrome.background ||
        caption.colors.foreground != chrome.foreground) {
      throw StateError(
        '兼容标题栏与当前主题不一致：caption=${caption?.colors.background}/${caption?.colors.foreground}，expected=${chrome.background}/${chrome.foreground}',
      );
    }
    _expectCaptionHitAreas(window);
  }
}

/// 查找已挂载的兼容标题栏，不能只检查单独生成的主题对象。
WindowsTitleBar? _findCustomTitleBar(Element element) {
  if (element.widget case final WindowsTitleBar caption) return caption;
  // 从实际窗口根元素向下查找。
  WindowsTitleBar? match;
  element.visitChildren((Element child) {
    match ??= _findCustomTitleBar(child);
  });
  return match;
}

/// 核对拖动区、按钮区、业务内容区以及覆盖父窗口的 Flutter 子视图。
void _expectCaptionHitAreas(win32.HWND window) {
  // 原生客户区矩形。
  final Pointer<win32.RECT> client = calloc<win32.RECT>();
  // 用于客户区到屏幕坐标转换的点。
  final Pointer<win32.POINT> point = calloc<win32.POINT>();
  try {
    win32.GetClientRect(window, client);
    // 当前窗口实际缩放比例。
    final double scale = win32.GetDpiForWindow(window) / 96;
    // 客户区左上角转为屏幕坐标，直接检查原生顶部没有额外条带。
    final Pointer<win32.RECT> outer = calloc<win32.RECT>();
    try {
      win32.GetWindowRect(window, outer);
      point.ref
        ..x = 0
        ..y = 0;
      win32.ClientToScreen(window, point);
      if (Platform.environment['OMNI_TITLE_BAR_BASELINE'] != '1' &&
          !win32.IsZoomed(window) &&
          point.ref.y != outer.ref.top) {
        throw StateError('自绘标题栏上方仍有非客户区条带');
      }
    } finally {
      calloc.free(outer);
    }
    // Flutter 绘制的直接子窗口。
    final win32.HWND child = win32.GetWindow(window, win32.GW_CHILD).value;
    // 三处命中位置与期望父窗口结果。
    final List<(int, int, int)> points = <(int, int, int)>[
      ((100 * scale).round(), (14 * scale).round(), win32.HTCAPTION),
      (
        client.ref.right - (23 * scale).round(),
        (14 * scale).round(),
        win32.HTCLIENT,
      ),
      if (Platform.environment['OMNI_TITLE_BAR_BASELINE'] != '1' &&
          !win32.IsZoomed(window)) ...<(int, int, int)>[
        ((100 * scale).round(), (2 * scale).round(), win32.HTTOP),
        ((2 * scale).round(), (2 * scale).round(), win32.HTTOPLEFT),
        (
          client.ref.right - (2 * scale).round(),
          (2 * scale).round(),
          win32.HTTOPRIGHT,
        ),
      ],
      ((100 * scale).round(), (80 * scale).round(), win32.HTCLIENT),
    ];
    for (final (int x, int y, int expected) in points) {
      point.ref
        ..x = x
        ..y = y;
      win32.ClientToScreen(window, point);
      // WM_NCHITTEST 使用带符号的两个十六位屏幕坐标。
      final win32.LPARAM position = win32.LPARAM(
        (point.ref.x & 0xffff) | ((point.ref.y & 0xffff) << 16),
      );
      if (win32.SendMessage(
            window,
            win32.WM_NCHITTEST,
            const win32.WPARAM(0),
            position,
          ).value !=
          expected) {
        throw StateError('标题栏原生命中区域错误：$x, $y');
      }
      if (child != nullptr &&
          expected != win32.HTCLIENT &&
          win32.SendMessage(
                child,
                win32.WM_NCHITTEST,
                const win32.WPARAM(0),
                position,
              ).value !=
              win32.HTTRANSPARENT) {
        throw StateError('Flutter 子视图拦截了标题栏原生拖动');
      }
    }
  } finally {
    calloc.free(client);
    calloc.free(point);
  }
}

/// 用本进程窗口消息验证双击标题栏及标准最小化命令继续有效。
Future<void> _expectWindowControls(win32.HWND window) async {
  if (win32.IsZoomed(window) || win32.IsIconic(window)) {
    // 外部拖动可能触发系统贴靠最大化，先恢复后再检查双击行为。
    win32.SendMessage(
      window,
      win32.WM_SYSCOMMAND,
      win32.WPARAM(win32.SC_RESTORE),
      const win32.LPARAM(0),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  win32.SendMessage(
    window,
    win32.WM_NCLBUTTONDBLCLK,
    win32.WPARAM(win32.HTCAPTION),
    const win32.LPARAM(0),
  );
  await Future<void>.delayed(const Duration(milliseconds: 200));
  if (!win32.IsZoomed(window)) throw StateError('标题栏双击没有最大化');
  _expectMaximizedWorkArea(window, 'double-click');
  win32.SendMessage(
    window,
    win32.WM_NCLBUTTONDBLCLK,
    win32.WPARAM(win32.HTCAPTION),
    const win32.LPARAM(0),
  );
  await Future<void>.delayed(const Duration(milliseconds: 200));
  if (win32.IsZoomed(window)) throw StateError('标题栏双击没有还原');
  // 兼容模式还需验证实际按钮与主窗口控制器的连接。
  final WindowsTitleBar? caption = _findCustomTitleBar(
    WidgetsBinding.instance.rootElement!,
  );
  if (caption != null) {
    caption.onToggleMaximize();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!win32.IsZoomed(window) ||
        !_findCustomTitleBar(WidgetsBinding.instance.rootElement!)!.maximized) {
      throw StateError('兼容标题栏最大化按钮或还原图标未同步');
    }
    _expectMaximizedWorkArea(window, 'caption-button');
    _findCustomTitleBar(WidgetsBinding.instance.rootElement!)!
        .onToggleMaximize();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (win32.IsZoomed(window)) throw StateError('兼容标题栏还原按钮无效');
    caption.onMinimize();
  } else {
    win32.SendMessage(
      window,
      win32.WM_SYSCOMMAND,
      win32.WPARAM(win32.SC_MINIMIZE),
      const win32.LPARAM(0),
    );
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  if (!win32.IsIconic(window)) throw StateError('最小化命令无效');
  win32.SendMessage(
    window,
    win32.WM_SYSCOMMAND,
    win32.WPARAM(win32.SC_RESTORE),
    const win32.LPARAM(0),
  );
  await Future<void>.delayed(const Duration(milliseconds: 200));
  // Alt+Space 对应的系统菜单命令必须在移除 WS_CAPTION 后仍可使用。
  win32.PostMessage(
    window,
    win32.WM_SYSCOMMAND,
    win32.WPARAM(win32.SC_KEYMENU),
    const win32.LPARAM(0x20),
  );
  await Future<void>.delayed(const Duration(milliseconds: 200));
  // 系统菜单运行在窗口所属的原生消息线程。
  final Pointer<win32.GUITHREADINFO> threadInfo = calloc<win32.GUITHREADINFO>();
  try {
    threadInfo.ref.cbSize = sizeOf<win32.GUITHREADINFO>();
    win32.GetGUIThreadInfo(
      win32.GetWindowThreadProcessId(window, nullptr),
      threadInfo,
    );
    // 先关闭本测试触发的菜单，再报告结果，避免遗留输入模式。
    final bool menuVisible = (threadInfo.ref.flags & win32.GUI_INMENUMODE) != 0;
    win32.PostMessage(
      window,
      win32.WM_CANCELMODE,
      const win32.WPARAM(0),
      const win32.LPARAM(0),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!menuVisible) throw StateError('兼容标题栏系统菜单命令无效');
  } finally {
    calloc.free(threadInfo);
  }
}

/// 在每块真实显示器上先放置窗口，再通过系统命令最大化并核对工作区。
Future<void> _expectMonitorMaximization(win32.HWND window) async {
  // 只枚举显示器，不调整分辨率、缩放或任务栏设置。
  final List<win32.HMONITOR> monitors = <win32.HMONITOR>[];
  // EnumDisplayMonitors 同步回调发生在当前线程。
  final NativeCallable<win32.MONITORENUMPROC> enumerate =
      NativeCallable<win32.MONITORENUMPROC>.isolateLocal((
        Pointer monitor,
        Pointer dc,
        Pointer<win32.RECT> rect,
        int data,
      ) {
        monitors.add(win32.HMONITOR(monitor));
        return 1;
      }, exceptionalReturn: 0);
  try {
    if (!win32.EnumDisplayMonitors(
      null,
      null,
      enumerate.nativeFunction,
      const win32.LPARAM(0),
    )) {
      throw StateError('无法枚举测试显示器');
    }
  } finally {
    enumerate.close();
  }
  // 测试结束后恢复本测试实例原来的窗口位置。
  final Pointer<win32.RECT> original = calloc<win32.RECT>();
  // 每轮实时读取目标显示器的物理工作区。
  final Pointer<win32.MONITORINFO> info = calloc<win32.MONITORINFO>();
  win32.GetWindowRect(window, original);
  try {
    for (final win32.HMONITOR monitor in monitors) {
      info.ref.cbSize = sizeOf<win32.MONITORINFO>();
      if (!win32.GetMonitorInfo(monitor, info)) {
        throw StateError('无法读取目标显示器工作区');
      }
      // 小于工作区的窗口化尺寸，用于模拟先拖到副屏再最大化。
      final win32.RECT work = info.ref.rcWork;
      win32.SetWindowPos(
        window,
        null,
        work.left + 40,
        work.top + 40,
        1000,
        800,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (win32.MonitorFromWindow(window, win32.MONITOR_DEFAULTTONEAREST) !=
          monitor) {
        throw StateError('测试窗口未进入目标显示器');
      }
      stdout.writeln(
        'MONITOR:${monitor.address}:dpi=${win32.GetDpiForWindow(window)}:'
        'work=(${work.left},${work.top},${work.right},${work.bottom})',
      );
      win32.PostMessage(
        window,
        win32.WM_SYSCOMMAND,
        win32.WPARAM(win32.SC_MAXIMIZE),
        const win32.LPARAM(0),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!win32.IsZoomed(window)) throw StateError('目标显示器未最大化');
      _expectMaximizedWorkArea(window, 'monitor-${monitor.address}');
      win32.PostMessage(
        window,
        win32.WM_SYSCOMMAND,
        win32.WPARAM(win32.SC_RESTORE),
        const win32.LPARAM(0),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _expectMinimumWindowSize(window);
    }
  } finally {
    if (win32.IsZoomed(window)) {
      win32.PostMessage(
        window,
        win32.WM_SYSCOMMAND,
        win32.WPARAM(win32.SC_RESTORE),
        const win32.LPARAM(0),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    win32.SetWindowPos(
      window,
      null,
      original.ref.left,
      original.ref.top,
      original.ref.right - original.ref.left,
      original.ref.bottom - original.ref.top,
      win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
    );
    calloc.free(original);
    calloc.free(info);
  }
}

/// 检查 Windows 拖拽使用的最小尺寸，覆盖创建时约束丢失的回归。
void _expectMinimumWindowSize(win32.HWND window) {
  // 系统在用户拖拽边框前查询的真实缩放限制。
  final Pointer<win32.MINMAXINFO> limits = calloc<win32.MINMAXINFO>();
  // 主窗口当前的外框及客户区，用于换算最小内容尺寸。
  final Pointer<win32.RECT> outer = calloc<win32.RECT>();
  // 标题栏和边框以内的实际绘制范围。
  final Pointer<win32.RECT> client = calloc<win32.RECT>();
  try {
    win32.SendMessage(
      window,
      win32.WM_GETMINMAXINFO,
      const win32.WPARAM(0),
      win32.LPARAM(limits.address),
    );
    win32.GetWindowRect(window, outer);
    win32.GetClientRect(window, client);
    // 原生尺寸是物理像素，主窗口约束使用逻辑像素。
    final double scale = win32.GetDpiForWindow(window) / 96;
    // 去除当前真实边框后的最小可用宽度。
    final int minWidth =
        limits.ref.ptMinTrackSize.x -
        (outer.ref.right - outer.ref.left - client.ref.right);
    // 去除当前真实边框后的最小可用高度。
    final int minHeight =
        limits.ref.ptMinTrackSize.y -
        (outer.ref.bottom - outer.ref.top - client.ref.bottom);
    stdout.writeln('MINIMUM_WINDOW:client=$minWidth,$minHeight;scale=$scale');
    if (minWidth < (512 * scale).round() || minHeight < (512 * scale).round()) {
      throw StateError('主窗口原生最小尺寸未生效：$minWidth × $minHeight');
    }
  } finally {
    calloc.free(limits);
    calloc.free(outer);
    calloc.free(client);
  }
}

/// 检查真实最大化客户区与当前显示器工作区，防止覆盖任务栏。
void _expectMaximizedWorkArea(win32.HWND window, String stage) {
  // Windows 报告的外部窗口矩形，用于排查边框扩展量。
  final Pointer<win32.RECT> outer = calloc<win32.RECT>();
  // 原生客户区相对窗口的矩形。
  final Pointer<win32.RECT> client = calloc<win32.RECT>();
  // 客户区左上角对应的屏幕物理位置。
  final Pointer<win32.POINT> topLeft = calloc<win32.POINT>();
  // 客户区右下角对应的屏幕物理位置。
  final Pointer<win32.POINT> bottomRight = calloc<win32.POINT>();
  // 当前显示器的完整范围及排除任务栏后的工作区。
  final Pointer<win32.MONITORINFO> monitorInfo = calloc<win32.MONITORINFO>();
  try {
    // 根据最大化窗口当前位置选择显示器，兼容副屏与负坐标布局。
    final win32.HMONITOR monitor = win32.MonitorFromWindow(
      window,
      win32.MONITOR_DEFAULTTONEAREST,
    );
    monitorInfo.ref.cbSize = sizeOf<win32.MONITORINFO>();
    if (!win32.GetWindowRect(window, outer).value ||
        !win32.GetClientRect(window, client).value ||
        !win32.GetMonitorInfo(monitor, monitorInfo)) {
      throw StateError('$stage 无法读取窗口与显示器工作区');
    }
    topLeft.ref
      ..x = client.ref.left
      ..y = client.ref.top;
    bottomRight.ref
      ..x = client.ref.right
      ..y = client.ref.bottom;
    if (!win32.ClientToScreen(window, topLeft) ||
        !win32.ClientToScreen(window, bottomRight)) {
      throw StateError('$stage 无法将最大化客户区转换为屏幕坐标');
    }
    // 当前工作区可能在任意屏幕边缘为任务栏留出空间。
    final win32.RECT work = monitorInfo.ref.rcWork;
    // 普通应用窗口不应通过置顶覆盖系统任务栏。
    final bool topmost =
        (win32.GetWindowLongPtr(window, win32.GWL_EXSTYLE).value &
            win32.WS_EX_TOPMOST) !=
        0;
    // 精确颜色可用时仍保留原生标题栏，其客户区自然不包含标题栏高度。
    final bool customCaption =
        (win32.GetWindowLongPtr(window, win32.GWL_STYLE).value &
            win32.WS_CAPTION) ==
        0;
    stdout.writeln(
      'MAXIMIZED_WORKAREA:$stage:'
      'outer=(${outer.ref.left},${outer.ref.top},${outer.ref.right},${outer.ref.bottom});'
      'client=(${topLeft.ref.x},${topLeft.ref.y},${bottomRight.ref.x},${bottomRight.ref.y});'
      'work=(${work.left},${work.top},${work.right},${work.bottom});'
      'topmost=$topmost;custom=$customCaption',
    );
    if (topmost) throw StateError('$stage 最大化窗口被错误设置为置顶');
    // 允许 DPI 和系统边框计算存在一个物理像素的取整差异。
    const int tolerance = 1;
    if (customCaption) {
      // 自绘标题栏属于客户区，最大化时四条边都必须与工作区一致。
      final List<(String, int, int)> edges = <(String, int, int)>[
        ('left', topLeft.ref.x, work.left),
        ('top', topLeft.ref.y, work.top),
        ('right', bottomRight.ref.x, work.right),
        ('bottom', bottomRight.ref.y, work.bottom),
      ];
      // 分别检查每条边，避免只比较宽高而遗漏整体偏移。
      for (final (String edge, int actual, int expected) in edges) {
        if ((actual - expected).abs() > tolerance) {
          throw StateError('$stage 最大化客户区 $edge 越出工作区：$actual != $expected');
        }
      }
    } else if (topLeft.ref.x < work.left - tolerance ||
        topLeft.ref.y < work.top - tolerance ||
        bottomRight.ref.x > work.right + tolerance ||
        bottomRight.ref.y > work.bottom + tolerance) {
      throw StateError('$stage 原生标题栏窗口的客户区越出工作区');
    }
  } finally {
    calloc.free(outer);
    calloc.free(client);
    calloc.free(topLeft);
    calloc.free(bottomRight);
    calloc.free(monitorInfo);
  }
}

/// 用 Win32 RGB 宏交叉校验生产代码的通道转换和原生属性写入。
void _expectColorAttribute(
  win32.HWND window,
  win32.DWMWINDOWATTRIBUTE attribute,
  Color expected,
) {
  // DWM 返回的实际 COLORREF。
  final Pointer<Uint32> actual = calloc<Uint32>();
  // 预期颜色的八位通道值。
  final int argb = expected.toARGB32();
  // 原生宏采用 R/G/B 参数顺序，与生产代码的位运算独立。
  final win32.COLORREF expectedNative = win32.RGB(
    (argb >> 16) & 0xff,
    (argb >> 8) & 0xff,
    argb & 0xff,
  );
  try {
    win32.DwmGetWindowAttribute(window, attribute, actual, sizeOf<Uint32>());
    if (actual.value != expectedNative) {
      throw StateError(
        '标题栏属性 $attribute 配色不一致：${actual.value} != $expectedNative',
      );
    }
  } finally {
    calloc.free(actual);
  }
}
