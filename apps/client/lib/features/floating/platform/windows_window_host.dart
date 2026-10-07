// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/app_chrome_colors.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_theme_palette.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/app/theme/windows_theme_transition.dart';
import 'package:omni_butler/features/floating/data/floating_window_preferences.dart';
import 'package:omni_butler/features/floating/platform/floating_window_placement.dart';
import 'package:omni_butler/features/floating/platform/floating_resize_scheduler.dart';
import 'package:omni_butler/features/floating/platform/windows_desktop_card_controller.dart';
import 'package:omni_butler/features/floating/platform/windows_floating_resize_service.dart';
import 'package:omni_butler/features/floating/platform/windows_tray_service.dart';
import 'package:omni_butler/features/floating/platform/windows_title_bar_service.dart';
import 'package:omni_butler/features/floating/presentation/floating_window_page.dart';
import 'package:omni_butler/features/floating/presentation/windows_title_bar.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_cleanup_coordinator.dart';
import 'package:omni_butler/core/sync/sync_maintenance_boundary.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:win32/win32.dart' as win32;

/// 主窗口最小客户区尺寸，交给系统按当前 DPI 换算拖拽下限。
const BoxConstraints _mainWindowConstraints = BoxConstraints(
  minWidth: 512,
  minHeight: 512,
);

/// 悬浮窗默认逻辑宽度。
const double _floatingWindowWidth = 294;

/// 悬浮窗默认及最小逻辑高度。
const double _floatingWindowMinHeight = floatingWindowDefaultHeight;

/// 悬浮窗默认尺寸，同时也是允许的最小尺寸。
const Size _floatingWindowInitialSize = Size(
  _floatingWindowWidth,
  _floatingWindowMinHeight,
);

/// 悬浮窗与工作区边缘的默认间距。
const double _floatingWindowMargin = 24;

/// 悬浮窗触发边缘吸附的逻辑距离。
const double _floatingWindowSnapThreshold = 24;

/// Windows 主窗口与多窗口管理入口。
class WindowsWindowHost extends StatefulWidget {
  /// 创建 Windows 窗口宿主。
  const WindowsWindowHost({super.key});

  @override
  State<WindowsWindowHost> createState() => _WindowsWindowHostState();
}

/// Windows 窗口宿主状态。
class _WindowsWindowHostState extends State<WindowsWindowHost> {
  /// 主窗口生命周期代理。
  late final _MainWindowDelegate _mainWindowDelegate;

  /// 主窗口控制器。
  late final RegularWindowController _mainWindowController;

  @override
  void initState() {
    super.initState();
    _mainWindowDelegate = _MainWindowDelegate();
    _mainWindowController = RegularWindowController(
      size: const Size(1280, 720),
      constraints: _mainWindowConstraints,
      title: 'Omni Butler',
      delegate: _mainWindowDelegate,
    );
    // 当前实验性 Windows 引擎未保存创建约束，创建后显式同步原生缩放限制。
    _mainWindowController.setConstraints(_mainWindowConstraints);
  }

  @override
  void dispose() {
    _mainWindowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RegularWindow(
      controller: _mainWindowController,
      child: WindowManager(
        child: _WindowsWindowCoordinator(
          mainWindowController: _mainWindowController,
          mainWindowDelegate: _mainWindowDelegate,
          child: const OmniButlerApp(),
        ),
      ),
    );
  }
}

/// 主窗口生命周期代理。
class _MainWindowDelegate with RegularWindowControllerDelegate {
  /// 当前关闭请求处理器。
  void Function(RegularWindowController controller)? onCloseRequested;

  /// 当前窗口销毁处理器。
  VoidCallback? onDestroyed;

  @override
  void onWindowCloseRequested(RegularWindowController controller) {
    // 已注册的业务关闭处理器。
    final void Function(RegularWindowController controller)? handler =
        onCloseRequested;
    if (handler != null) {
      handler(controller);
      return;
    }
    controller.destroy();
  }

  @override
  void onWindowDestroyed() {
    onDestroyed?.call();
    super.onWindowDestroyed();
  }
}

/// 悬浮窗口生命周期代理。
class _FloatingWindowDelegate with RegularWindowControllerDelegate {
  /// 创建悬浮窗口代理。
  _FloatingWindowDelegate({required this.onClose, required this.onDestroyed});

  /// 用户发起关闭时的处理器。
  final Future<void> Function() onClose;

  /// 窗口完成销毁时的处理器。
  final VoidCallback onDestroyed;

  @override
  void onWindowCloseRequested(RegularWindowController controller) {
    onClose();
  }

  @override
  void onWindowDestroyed() {
    onDestroyed();
    super.onWindowDestroyed();
  }
}

/// 协调主窗口、悬浮窗、托盘与偏好状态。
class _WindowsWindowCoordinator extends ConsumerStatefulWidget {
  /// 创建 Windows 窗口协调器。
  const _WindowsWindowCoordinator({
    required this.mainWindowController,
    required this.mainWindowDelegate,
    required this.child,
  });

  /// 主窗口控制器。
  final RegularWindowController mainWindowController;

  /// 主窗口生命周期代理。
  final _MainWindowDelegate mainWindowDelegate;

  /// 主窗口业务内容。
  final Widget child;

  @override
  ConsumerState<_WindowsWindowCoordinator> createState() =>
      _WindowsWindowCoordinatorState();
}

/// Windows 窗口协调器状态。
class _WindowsWindowCoordinatorState
    extends ConsumerState<_WindowsWindowCoordinator>
    with ScreenListener, WidgetsBindingObserver {
  /// 当前窗口注册表。
  WindowRegistry? _windowRegistry;

  /// 当前悬浮窗口条目。
  WindowEntry? _floatingEntry;

  /// 当前悬浮窗口控制器。
  RegularWindowController? _floatingController;

  /// 当前悬浮窗口原生操作器。
  _WindowsFloatingWindowNative? _floatingNative;

  /// 系统托盘是否已经创建。
  bool _trayCreated = false;

  /// Windows Runner 内置托盘服务。
  final WindowsTrayService _trayService = WindowsTrayService();

  /// 同步主题并处理原生系统消息的标题栏服务。
  final WindowsTitleBarService _titleBarService = WindowsTitleBarService();

  /// 支持 Flutter 多窗口的显示器查询服务。
  final _WindowsDisplayService _displayService = const _WindowsDisplayService();

  /// 主窗口是否已经隐藏到托盘。
  bool _mainWindowHidden = false;

  /// 是否正在退出整个应用。
  bool _isExiting = false;

  /// 串行化窗口与托盘状态变更。
  Future<void> _pendingOperation = Future<void>.value();

  /// 上一次提交协调的目标状态。
  (bool, bool, bool)? _lastRequestedState;

  /// 上一次同步的实际明暗模式与主题配色。
  (Brightness, AppThemePalette)? _lastTitleBarTheme;

  /// 旧版 Windows 不支持原生精确配色时使用同色自绘标题栏。
  bool _usesCustomTitleBar = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.mainWindowDelegate.onCloseRequested = _handleMainCloseRequested;
    widget.mainWindowDelegate.onDestroyed = _handleMainWindowDestroyed;
    _trayService.onOpen = _showMainWindow;
    _trayService.onToggle = _toggleFloatingFromTray;
    _trayService.onExit = () => unawaited(_exitApplication());
    screenRetriever.addListener(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _windowRegistry = WindowRegistry.of(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    screenRetriever.removeListener(this);
    widget.mainWindowDelegate.onCloseRequested = null;
    widget.mainWindowDelegate.onDestroyed = null;
    _trayService.onOpen = null;
    _trayService.onToggle = null;
    _trayService.onExit = null;
    unawaited(_disposeTray());
    _floatingNative?.dispose();
    _floatingNative = null;
    _floatingController?.destroy();
    _floatingController?.dispose();
    super.dispose();
  }

  @override
  void onScreenEvent(String eventName) {
    if (_floatingNative == null) {
      return;
    }
    _queueOperation(_restoreFloatingPlacement);
  }

  @override
  Widget build(BuildContext context) {
    // 当前设备主题偏好，手动切换时同步原生标题栏。
    final ThemePreference themePreference = ref.watch(themeControllerProvider);
    _syncMainWindowTheme(themePreference);
    // 停用时立即移除窗口，不排在显示器查询或托盘初始化之后。
    ref.listen(floatingWindowPreferenceProvider, (previous, next) {
      if (previous?.enabled != next.enabled) {
        // 同一帧内关闭再开启不能被上次构建的目标状态去重掉。
        _lastRequestedState = null;
      }
      if (!next.enabled) {
        unawaited(_hideFloatingWindow());
      }
    });
    // 当前悬浮窗偏好。
    final FloatingWindowPreference floatingPreference = ref.watch(
      floatingWindowPreferenceProvider,
    );
    // 当前功能启用偏好。
    final FeaturePreference featurePreference = ref.watch(
      featurePreferenceProvider,
    );
    // 待办模块是否启用。
    final bool todosEnabled = featurePreference.isEnabled(AppFeature.todos);
    // 时间模块是否启用。
    final bool timelineEnabled = featurePreference.isEnabled(
      AppFeature.timeline,
    );
    // 本次需要协调的目标状态。
    final (bool, bool, bool) requestedState = (
      floatingPreference.enabled,
      todosEnabled,
      timelineEnabled,
    );
    if (_lastRequestedState != requestedState) {
      _lastRequestedState = requestedState;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted) {
          return;
        }
        _queueOperation(
          () => _reconcileWindows(
            floatingPreference: ref.read(floatingWindowPreferenceProvider),
            featurePreference: ref.read(featurePreferenceProvider),
          ),
        );
      });
    }
    return WindowsThemeTransition(
      themeKey: (
        _resolveMainWindowBrightness(themePreference),
        themePreference.palette,
      ),
      child: Column(
        children: <Widget>[
          if (_usesCustomTitleBar)
            Directionality(
              textDirection: TextDirection.ltr,
              child: Theme(
                data: AppTheme.build(
                  brightness: _resolveMainWindowBrightness(themePreference),
                  palette: themePreference.palette,
                ),
                child: ListenableBuilder(
                  listenable: widget.mainWindowController,
                  builder: (BuildContext context, Widget? child) =>
                      WindowsTitleBar(
                        colors: OmniChromeColors.of(context),
                        maximized: widget.mainWindowController.isMaximized,
                        onMinimize: () => _requestWindowAction(minimize: true),
                        onToggleMaximize: () =>
                            _requestWindowAction(minimize: false),
                        onClose: () => _handleMainCloseRequested(
                          widget.mainWindowController,
                        ),
                      ),
                ),
              ),
            ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }

  /// 按钮只提交异步原生命令，不在 Dart 调用栈内同步改变窗口尺寸。
  void _requestWindowAction({required bool minimize}) {
    if (_isExiting) return;
    // 使用主窗口自身句柄，避免误操作当前焦点窗口或悬浮窗。
    final int handle =
        (widget.mainWindowController as RegularWindowControllerWin32)
            .windowHandle
            .address;
    unawaited(
      (minimize
              ? _titleBarService.minimize(handle)
              : _titleBarService.toggleMaximize(handle))
          .catchError((Object error, StackTrace stackTrace) {
            debugPrint('Windows 标题栏按钮操作失败：$error\n$stackTrace');
          }),
    );
  }

  /// 系统明暗变化时按应用当前模式更新标题栏。
  @override
  void didChangePlatformBrightness() {
    // 引擎可能先将标题栏重置为系统主题，固定模式也必须重新应用。
    _syncMainWindowTheme(ref.read(themeControllerProvider), force: true);
    if (mounted) setState(() {});
  }

  /// 将手动或跟随系统的偏好解析为实际窗口亮度。
  Brightness _resolveMainWindowBrightness(ThemePreference preference) =>
      switch (preference.mode) {
        ThemeMode.dark => Brightness.dark,
        ThemeMode.light => Brightness.light,
        ThemeMode.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
      };

  /// 将主题的导航底色与可读文字同步到实际主窗口的原生标题栏。
  void _syncMainWindowTheme(ThemePreference preference, {bool force = false}) {
    if (_isExiting) return;
    // 跟随系统时采用 Flutter 收到的系统明暗状态。
    final Brightness brightness = _resolveMainWindowBrightness(preference);
    // 配色变化也需要更新标题栏，不能只对明暗模式去重。
    final (Brightness, AppThemePalette) requestedTheme = (
      brightness,
      preference.palette,
    );
    if (!force && _lastTitleBarTheme == requestedTheme) return;
    // 与左侧导航共用同一主题解析结果，避免标题栏出现独立色差。
    final OmniChromeColors chrome = AppTheme.build(
      brightness: brightness,
      palette: preference.palette,
    ).extension<OmniChromeColors>()!;
    // 多窗口控制器对应的主窗口句柄，不依赖当前焦点或隐式 Flutter View。
    final RegularWindowControllerWin32 controller =
        widget.mainWindowController as RegularWindowControllerWin32;
    // 标题栏按钮按实际底色选择明暗，浅色页面也可能使用深色导航。
    final bool isDark =
        ThemeData.estimateBrightnessForColor(chrome.background) ==
        Brightness.dark;
    // 同一通道按发送顺序应用主题，先记录目标避免普通重建重复发送。
    _lastTitleBarTheme = requestedTheme;
    unawaited(
      _titleBarService
          .applyTheme(
            windowHandle: controller.windowHandle.address,
            dark: isDark,
            background: chrome.background,
            foreground: chrome.foreground,
            captionHeight: WindowsTitleBar.height.round(),
            captionButtonsWidth: (WindowsTitleBar.buttonWidth * 3).round(),
          )
          .then<void>((bool exactColorsApplied) {
            if (mounted &&
                !_isExiting &&
                _usesCustomTitleBar == exactColorsApplied) {
              setState(() => _usesCustomTitleBar = !exactColorsApplied);
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            // 失败仅撤销仍对应当前请求的去重记录，不覆盖之后的新主题。
            if (_lastTitleBarTheme == requestedTheme) {
              _lastTitleBarTheme = null;
            }
            debugPrint('Windows 标题栏主题同步失败：$error\n$stackTrace');
          }),
    );
  }

  /// 将窗口相关异步操作加入串行队列。
  void _queueOperation(Future<void> Function() operation) {
    _pendingOperation = _pendingOperation.then((_) => operation()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      debugPrint('Windows 悬浮窗状态同步失败：$error\n$stackTrace');
    });
  }

  /// 根据偏好同步悬浮窗口与托盘。
  Future<void> _reconcileWindows({
    required FloatingWindowPreference floatingPreference,
    required FeaturePreference featurePreference,
  }) async {
    if (!mounted || _isExiting) {
      return;
    }
    // 当前是否至少有一个悬浮窗业务模块启用。
    final bool hasVisibleModule =
        featurePreference.isEnabled(AppFeature.todos) ||
        featurePreference.isEnabled(AppFeature.timeline);
    // 当前是否应该显示悬浮窗。
    final bool shouldShowFloating =
        floatingPreference.enabled && hasVisibleModule;

    if (shouldShowFloating) {
      await _showFloatingWindow(floatingPreference);
      await _ensureTray(floatingPreference.enabled);
    } else {
      await _hideFloatingWindow();
      if (floatingPreference.enabled || _mainWindowHidden) {
        await _ensureTray(floatingPreference.enabled);
      } else {
        await _disposeTray();
      }
    }
    _updateTrayToggle(floatingPreference.enabled);
  }

  /// 创建并显示悬浮窗。
  Future<void> _showFloatingWindow(FloatingWindowPreference preference) async {
    if (_isExiting ||
        !ref.read(floatingWindowPreferenceProvider).enabled ||
        _floatingController != null) {
      return;
    }
    // 当前窗口注册表。
    final WindowRegistry? registry = _windowRegistry;
    if (registry == null) {
      return;
    }
    // 新建的悬浮窗控制器。
    late final RegularWindowController controller;
    // 悬浮窗生命周期代理。
    final _FloatingWindowDelegate delegate = _FloatingWindowDelegate(
      onClose: _disableFloatingFromCard,
      onDestroyed: () => _handleFloatingWindowDestroyed(controller),
    );
    // 按应用重启前保存的值恢复，首次或设置重置后使用默认尺寸。
    final Size initialSize = _resolveFloatingSize(preference);
    controller = WindowsDesktopCardController(
      size: initialSize,
      constraints: const BoxConstraints(
        minWidth: _floatingWindowWidth,
        minHeight: _floatingWindowMinHeight,
      ),
      title: 'Omni Butler · 今日',
      delegate: delegate,
    );
    // 原生创建会轮询消息；若期间用户停用或退出，不再登记迟到的窗口。
    if (!mounted ||
        _isExiting ||
        !ref.read(floatingWindowPreferenceProvider).enabled) {
      controller.destroy();
      return;
    }
    // 悬浮窗注册条目。
    late final WindowEntry entry;
    entry = WindowEntry(
      controller: controller,
      builder: (BuildContext context) => _FloatingWindowSurface(
        onClose: _disableFloatingFromCard,
        onOpenRoute: _openMainRoute,
        onDragStart: _handleFloatingDragStart,
        onDragUpdate: _handleFloatingDragUpdate,
        onDragEnd: _handleFloatingDragEnd,
        onResizeStart: _handleFloatingResizeStart,
        onResizeUpdate: _handleFloatingResizeUpdate,
        onResizeEnd: _handleFloatingResizeEnd,
      ),
    );
    _floatingController = controller;
    _floatingEntry = entry;
    registry.register(entry);

    // 新窗口原生句柄需要等待首帧挂载完成。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _isExiting || _floatingController != controller) {
      return;
    }
    // Windows 悬浮窗口原生操作器。
    final _WindowsFloatingWindowNative native = _WindowsFloatingWindowNative(
      controller,
    );
    _floatingNative = native;
    native.configureAsDesktopCard();
    await _restoreFloatingPlacement(preference: preference);
  }

  /// 返回满足最小约束的已保存尺寸，缺失时使用默认尺寸。
  Size _resolveFloatingSize(FloatingWindowPreference preference) {
    if (!preference.hasSize) {
      return _floatingWindowInitialSize;
    }
    return Size(
      preference.width!.clamp(
        _floatingWindowInitialSize.width,
        double.infinity,
      ),
      preference.height!.clamp(
        _floatingWindowInitialSize.height,
        double.infinity,
      ),
    );
  }

  /// 销毁当前悬浮窗口。
  Future<void> _hideFloatingWindow() async {
    // 待移除的悬浮窗条目。
    final WindowEntry? entry = _floatingEntry;
    // 待销毁的悬浮窗控制器。
    final RegularWindowController? controller = _floatingController;
    _floatingNative?.dispose();
    _floatingEntry = null;
    _floatingController = null;
    _floatingNative = null;
    if (controller != null) {
      // 先隐藏真实宿主，避免注册表更新或资源清理期间残留最后一帧。
      _WindowsWindowVisibility.hide(controller);
      controller.destroy();
    }
    if (entry != null) {
      _windowRegistry?.unregister(entry);
    }
  }

  /// 响应悬浮窗销毁并清理注册状态。
  void _handleFloatingWindowDestroyed(
    RegularWindowController destroyedController,
  ) {
    if (_floatingController != destroyedController) {
      destroyedController.dispose();
      return;
    }
    // 已销毁窗口对应的条目。
    final WindowEntry? entry = _floatingEntry;
    if (entry != null) {
      _windowRegistry?.unregister(entry);
    }
    // 已销毁窗口对应的控制器。
    final RegularWindowController? controller = _floatingController;
    _floatingEntry = null;
    _floatingController = null;
    _floatingNative?.dispose();
    _floatingNative = null;
    controller?.dispose();
  }

  /// 从卡片关闭入口停用悬浮窗并恢复主窗口。
  Future<void> _disableFloatingFromCard() async {
    if (!mounted || _isExiting) {
      return;
    }
    // 偏好先同步失效，正在排队的显示请求不能重新创建关闭中的窗口。
    final Future<void> saving = ref
        .read(floatingWindowPreferenceProvider.notifier)
        .setEnabled(false);
    _showMainWindow();
    await saving;
  }

  /// 恢复或重新约束悬浮窗位置。
  Future<void> _restoreFloatingPlacement({
    FloatingWindowPreference? preference,
  }) async {
    // 当前原生悬浮窗操作器。
    final _WindowsFloatingWindowNative? native = _floatingNative;
    if (native == null || _isExiting) {
      return;
    }
    // 当前设备保存的悬浮窗偏好。
    final FloatingWindowPreference resolvedPreference =
        preference ?? ref.read(floatingWindowPreferenceProvider);
    // 当前屏幕列表。
    final List<Display> displays = await _displayService.getAllDisplays(
      widget.mainWindowController.rootView.devicePixelRatio,
    );
    if (displays.isEmpty ||
        !mounted ||
        _isExiting ||
        _floatingNative != native) {
      return;
    }
    // 当前系统主显示器。
    final Display primaryDisplay = await _displayService.getPrimaryDisplay(
      widget.mainWindowController.rootView.devicePixelRatio,
    );
    if (!mounted || _isExiting || _floatingNative != native) {
      return;
    }
    // 恢复目标显示器。
    final Display display = _findPreferredDisplay(
      displays,
      resolvedPreference.displayId,
      primaryDisplay,
    );
    // 本次需要恢复的悬浮窗逻辑尺寸。
    final Size targetSize = _resolveFloatingSize(resolvedPreference);
    // 恢复目标的逻辑坐标。
    final Offset desiredPosition = resolvedPreference.hasPlacement
        ? Offset(resolvedPreference.positionX!, resolvedPreference.positionY!)
        : _defaultPlacement(display, targetSize);
    // 已保存位置贴边恢复，首次位置保留默认呼吸间距。
    final double placementMargin = resolvedPreference.hasPlacement
        ? 0
        : _floatingWindowMargin;
    // 限制并吸附到当前显示器工作区内的逻辑坐标。
    final Offset clampedPosition = snapFloatingPlacement(
      desiredPosition: desiredPosition,
      workAreaSize: display.visibleSize ?? display.size,
      windowSize: targetSize,
      threshold: _floatingWindowSnapThreshold,
      margin: placementMargin,
    );
    native.moveToDisplayPosition(display, clampedPosition);
    native.resizeToLogicalSize(targetSize);
    await ref
        .read(floatingWindowPreferenceProvider.notifier)
        .savePlacement(
          displayId: display.id,
          positionX: clampedPosition.dx,
          positionY: clampedPosition.dy,
        );
  }

  /// 返回保存的显示器，显示器已移除时回退到主屏。
  Display _findPreferredDisplay(
    List<Display> displays,
    String? displayId,
    Display primaryDisplay,
  ) {
    for (final Display display in displays) {
      if (display.id == displayId) {
        return display;
      }
    }
    return primaryDisplay;
  }

  /// 计算默认的右下角位置。
  Offset _defaultPlacement(Display display, Size windowSize) {
    // 显示器可用工作区尺寸。
    final Size workAreaSize = display.visibleSize ?? display.size;
    return Offset(
      workAreaSize.width - windowSize.width - _floatingWindowMargin,
      workAreaSize.height - windowSize.height - _floatingWindowMargin,
    );
  }

  /// 开始拖动悬浮窗。
  void _handleFloatingDragStart() {
    _floatingNative?.beginDrag();
  }

  /// 持续拖动悬浮窗。
  void _handleFloatingDragUpdate() {
    _floatingNative?.updateDrag();
  }

  /// 结束拖动并保存新位置。
  Future<void> _handleFloatingDragEnd() async {
    await _saveCurrentFloatingState();
  }

  /// 开始从左下角调整悬浮窗尺寸。
  void _handleFloatingResizeStart() {
    _floatingNative?.beginResizeFromBottomLeft();
  }

  /// 按鼠标当前位置持续调整悬浮窗尺寸。
  void _handleFloatingResizeUpdate() {
    _floatingNative?.updateResizeFromBottomLeft();
  }

  /// 结束调整并保存悬浮窗的位置与尺寸。
  Future<void> _handleFloatingResizeEnd() async {
    await _floatingNative?.endResizeFromBottomLeft();
    await _saveCurrentFloatingState();
  }

  /// 保存当前悬浮窗口所在显示器、相对位置与尺寸。
  Future<void> _saveCurrentFloatingState() async {
    // 当前原生悬浮窗操作器。
    final _WindowsFloatingWindowNative? native = _floatingNative;
    if (native == null || _isExiting) {
      return;
    }
    // 当前屏幕列表。
    final List<Display> displays = await _displayService.getAllDisplays(
      widget.mainWindowController.rootView.devicePixelRatio,
    );
    if (displays.isEmpty ||
        !mounted ||
        _isExiting ||
        _floatingNative != native) {
      return;
    }
    // 当前窗口左上角物理坐标。
    final Offset screenPosition = native.screenPosition;
    // 当前窗口中心点物理坐标。
    final Offset centerPosition =
        screenPosition +
        Offset(native.physicalSize.width / 2, native.physicalSize.height / 2);
    // 当前窗口所在显示器。
    final Display display = _displayContainingPhysicalPoint(
      displays,
      centerPosition,
    );
    // 当前显示器缩放比例。
    final double scaleFactor = (display.scaleFactor ?? 1).toDouble();
    // 当前显示器工作区物理起点。
    final Offset workAreaPhysicalOrigin =
        (display.visiblePosition ?? Offset.zero) * scaleFactor;
    // 窗口相对显示器工作区的逻辑坐标。
    final Offset relativeLogicalPosition =
        (screenPosition - workAreaPhysicalOrigin) / scaleFactor;
    // 约束并吸附后的窗口逻辑坐标。
    final Offset clampedPosition = snapFloatingPlacement(
      desiredPosition: relativeLogicalPosition,
      workAreaSize: display.visibleSize ?? display.size,
      windowSize: native.logicalSize,
      threshold: _floatingWindowSnapThreshold,
      margin: 0,
    );
    native.moveToDisplayPosition(display, clampedPosition);
    // 在异步写入之前快照尺寸，不能再读取可能已被关闭的窗口。
    final Size logicalSize = native.logicalSize;
    await ref
        .read(floatingWindowPreferenceProvider.notifier)
        .savePlacement(
          displayId: display.id,
          positionX: clampedPosition.dx,
          positionY: clampedPosition.dy,
        );
    if (!mounted || _isExiting || _floatingNative != native) {
      return;
    }
    await ref
        .read(floatingWindowPreferenceProvider.notifier)
        .saveSize(width: logicalSize.width, height: logicalSize.height);
  }

  /// 查找包含给定物理坐标的显示器。
  Display _displayContainingPhysicalPoint(
    List<Display> displays,
    Offset physicalPoint,
  ) {
    for (final Display display in displays) {
      // 当前显示器缩放比例。
      final double scaleFactor = (display.scaleFactor ?? 1).toDouble();
      // 当前显示器工作区的物理矩形。
      final Rect physicalRect = Rect.fromLTWH(
        (display.visiblePosition?.dx ?? 0) * scaleFactor,
        (display.visiblePosition?.dy ?? 0) * scaleFactor,
        (display.visibleSize?.width ?? display.size.width) * scaleFactor,
        (display.visibleSize?.height ?? display.size.height) * scaleFactor,
      );
      if (physicalRect.contains(physicalPoint)) {
        return display;
      }
    }
    return displays.first;
  }

  /// 处理主窗口关闭请求。
  void _handleMainCloseRequested(RegularWindowController controller) {
    // 当前悬浮窗是否保持启用。
    final bool floatingEnabled = ref.read(
      floatingWindowPreferenceProvider.select(
        (FloatingWindowPreference preference) => preference.enabled,
      ),
    );
    if (floatingEnabled) {
      _queueOperation(() async {
        await _ensureTray(true);
        if (mounted) {
          _hideMainWindow();
        }
      });
      return;
    }
    unawaited(_exitApplication());
  }

  /// 隐藏主窗口到托盘。
  void _hideMainWindow() {
    _mainWindowHidden = true;
    _WindowsWindowVisibility.hide(widget.mainWindowController);
  }

  /// 恢复并激活主窗口。
  void _showMainWindow() {
    if (_isExiting) {
      return;
    }
    _mainWindowHidden = false;
    _WindowsWindowVisibility.show(widget.mainWindowController);
    widget.mainWindowController.activate();
    if (!ref.read(floatingWindowPreferenceProvider).enabled) {
      _queueOperation(_disposeTray);
    }
  }

  /// 打开主窗口并跳转到指定业务路由。
  Future<void> _openMainRoute(String location) async {
    _showMainWindow();
    // 主应用共享的路由器。
    final GoRouter router = ref.read(appRouterProvider);
    router.go(location);
  }

  /// 响应主窗口销毁。
  void _handleMainWindowDestroyed() {
    if (_isExiting) {
      return;
    }
    unawaited(_exitApplication(mainAlreadyDestroyed: true));
  }

  /// 确保系统托盘已经创建并同步开关状态。
  Future<void> _ensureTray(bool floatingEnabled) async {
    if (_isExiting) {
      return;
    }
    if (_trayCreated) {
      await _trayService.setFloatingEnabled(floatingEnabled);
      return;
    }
    await _trayService.initialize(floatingEnabled: floatingEnabled);
    if (_isExiting) {
      await _trayService.destroy();
      return;
    }
    _trayCreated = true;
  }

  /// 同步托盘中的悬浮窗勾选状态。
  void _updateTrayToggle(bool enabled) {
    if (!_trayCreated) {
      return;
    }
    unawaited(_trayService.setFloatingEnabled(enabled));
  }

  /// 从托盘切换悬浮窗启用状态。
  void _toggleFloatingFromTray() {
    // 点击前的当前悬浮窗偏好。
    final bool currentlyEnabled = ref
        .read(floatingWindowPreferenceProvider)
        .enabled;
    if (currentlyEnabled && _mainWindowHidden) {
      _showMainWindow();
    }
    unawaited(
      ref
          .read(floatingWindowPreferenceProvider.notifier)
          .setEnabled(!currentlyEnabled),
    );
  }

  /// 释放托盘及其菜单资源。
  Future<void> _disposeTray() async {
    if (!_trayCreated) {
      return;
    }
    _trayCreated = false;
    await _trayService.destroy();
  }

  /// 销毁所有窗口并退出应用。
  Future<void> _exitApplication({bool mainAlreadyDestroyed = false}) async {
    if (_isExiting) {
      return;
    }
    _isExiting = true;
    // 捕获清理排空任务；先关闭可见窗口，再等待事务完成才退出进程。
    final Future<void>? recycleCleanup = ref
        .read(recycleBinCleanupProvider)
        ?.stop();
    // 拖动/缩放结束已保存状态，退出不等待屏幕查询和磁盘写入才关闭界面。
    if (!mainAlreadyDestroyed) {
      _WindowsWindowVisibility.hide(widget.mainWindowController);
    }
    await _hideFloatingWindow();
    if (!mainAlreadyDestroyed) {
      widget.mainWindowController.destroy();
    }
    try {
      await _disposeTray();
    } finally {
      await recycleCleanup;
      await ServicesBinding.instance.exitApplication(ui.AppExitType.required);
    }
  }
}

/// 绕开 screen_retriever 单视图假设的 Windows 显示器查询服务。
class _WindowsDisplayService {
  /// 创建 Windows 显示器查询服务。
  const _WindowsDisplayService();

  /// screen_retriever Windows 插件使用的方法通道。
  static const MethodChannel _methodChannel = MethodChannel(
    'dev.leanflutter.plugins/screen_retriever',
  );

  /// 查询当前全部显示器。
  Future<List<Display>> getAllDisplays(double devicePixelRatio) async {
    // 插件返回的显示器集合数据。
    final Object? result = await _methodChannel.invokeMethod<Object?>(
      'getAllDisplays',
      _arguments(devicePixelRatio),
    );
    if (result is! Map<Object?, Object?>) {
      throw StateError('无法读取 Windows 显示器列表。');
    }
    // 原生层返回的显示器列表。
    final Object? rawDisplays = result['displays'];
    if (rawDisplays is! List<Object?> || rawDisplays.isEmpty) {
      throw StateError('Windows 没有返回可用显示器。');
    }
    return rawDisplays.map(_decodeDisplay).toList(growable: false);
  }

  /// 查询当前主显示器。
  Future<Display> getPrimaryDisplay(double devicePixelRatio) async {
    // 插件返回的主显示器数据。
    final Object? result = await _methodChannel.invokeMethod<Object?>(
      'getPrimaryDisplay',
      _arguments(devicePixelRatio),
    );
    return _decodeDisplay(result);
  }

  /// 创建带有明确像素比例的方法通道参数。
  Map<String, double> _arguments(double devicePixelRatio) {
    return <String, double>{'devicePixelRatio': devicePixelRatio};
  }

  /// 将原生显示器数据转换为插件显示器模型。
  Display _decodeDisplay(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw StateError('Windows 返回了无效的显示器数据。');
    }
    // 转换后的字符串键显示器数据。
    final Map<String, dynamic> displayData = value.cast<String, dynamic>();
    return Display.fromJson(displayData);
  }
}

/// 为悬浮窗提供独立主题与 Material 上下文。
class _FloatingWindowSurface extends ConsumerWidget {
  /// 创建悬浮窗口主题表面。
  const _FloatingWindowSurface({
    required this.onClose,
    required this.onOpenRoute,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  /// 关闭悬浮窗回调。
  final Future<void> Function() onClose;

  /// 打开主应用路由回调。
  final FloatingRouteCallback onOpenRoute;

  /// 开始拖动回调。
  final VoidCallback onDragStart;

  /// 拖动更新回调。
  final VoidCallback onDragUpdate;

  /// 结束拖动回调。
  final Future<void> Function() onDragEnd;

  /// 开始调整窗口尺寸回调。
  final VoidCallback onResizeStart;

  /// 持续调整窗口尺寸回调。
  final VoidCallback onResizeUpdate;

  /// 结束调整窗口尺寸回调。
  final Future<void> Function() onResizeEnd;

  /// 构建与主窗口共享配色和明暗模式的悬浮窗。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前设备的完整主题偏好。
    final ThemePreference preference = ref.watch(themeControllerProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(
        brightness: Brightness.light,
        palette: preference.palette,
      ),
      darkTheme: AppTheme.build(
        brightness: Brightness.dark,
        palette: preference.palette,
      ),
      themeMode: preference.mode,
      home: FloatingWindowPage(
        onClose: onClose,
        onOpenRoute: onOpenRoute,
        onDragStart: onDragStart,
        onDragUpdate: onDragUpdate,
        onDragEnd: onDragEnd,
        onResizeStart: onResizeStart,
        onResizeUpdate: onResizeUpdate,
        onResizeEnd: onResizeEnd,
      ),
      builder: (BuildContext context, Widget? child) => SyncMaintenanceBoundary(
        compact: true,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}

/// Windows 悬浮窗原生样式、位置与拖拽操作器。
class _WindowsFloatingWindowNative {
  /// 创建原生悬浮窗操作器。
  _WindowsFloatingWindowNative(RegularWindowController controller)
    : _windowHandle = win32.HWND(
        (controller as WindowControllerWin32).windowHandle,
      );

  /// 悬浮窗原生句柄。
  final win32.HWND _windowHandle;

  /// 桌面宿主原生句柄。
  win32.HWND? _desktopHandle;

  /// 开始拖动时鼠标物理坐标。
  Offset? _dragCursorOrigin;

  /// 开始拖动时窗口物理坐标。
  Offset? _dragWindowOrigin;

  /// 开始调整尺寸时鼠标物理坐标。
  Offset? _resizeCursorOrigin;

  /// 开始调整尺寸时窗口物理矩形。
  Rect? _resizeWindowRect;

  /// 最新指针事件算出的矩形，松开时仍保留以供重入延迟提交。
  Rect? _resizeTargetRect;

  /// 当前窗口所在显示器的缩放比例。
  double _currentScaleFactor = 1;

  /// 高频鼠标事件对应的原生缩放提交器。
  late final FloatingResizeScheduler _resizeScheduler = FloatingResizeScheduler(
    _applyPendingResize,
  );

  /// 通过原生消息线程提交窗口矩形的服务。
  final WindowsFloatingResizeService _resizeService =
      WindowsFloatingResizeService();

  /// 关闭前取消尺寸更新，避免旧窗口的待提交请求继续执行。
  void dispose() {
    _resizeScheduler.dispose();
    _resizeCursorOrigin = null;
    _resizeWindowRect = null;
    _resizeTargetRect = null;
  }

  /// 当前窗口左上角的屏幕物理坐标。
  Offset get screenPosition {
    // 窗口原生矩形。
    final Pointer<win32.RECT> rect = calloc<win32.RECT>();
    try {
      if (!win32.GetWindowRect(_windowHandle, rect).value) {
        return Offset.zero;
      }
      return Offset(rect.ref.left.toDouble(), rect.ref.top.toDouble());
    } finally {
      calloc.free(rect);
    }
  }

  /// 当前窗口物理尺寸。
  Size get physicalSize {
    // 窗口原生矩形。
    final Pointer<win32.RECT> rect = calloc<win32.RECT>();
    try {
      if (!win32.GetWindowRect(_windowHandle, rect).value) {
        return _floatingWindowInitialSize;
      }
      return Size(
        (rect.ref.right - rect.ref.left).toDouble(),
        (rect.ref.bottom - rect.ref.top).toDouble(),
      );
    } finally {
      calloc.free(rect);
    }
  }

  /// 当前窗口按所在显示器缩放换算后的逻辑尺寸。
  Size get logicalSize {
    // 当前窗口物理尺寸。
    final Size currentPhysicalSize = physicalSize;
    return currentPhysicalSize / _currentScaleFactor;
  }

  /// 应用无边框、工具窗口、半透明与桌面父级样式。
  void configureAsDesktopCard() {
    _enableAcrylicBackdrop();
    // 当前窗口基础样式。
    final int currentStyle = win32.GetWindowLongPtr(
      _windowHandle,
      win32.GWL_STYLE,
    ).value;
    // 移除系统标题栏和调整大小能力后的样式。
    final int framelessStyle =
        (currentStyle &
            ~win32.WS_CAPTION &
            ~win32.WS_THICKFRAME &
            ~win32.WS_MINIMIZEBOX &
            ~win32.WS_MAXIMIZEBOX &
            ~win32.WS_SYSMENU &
            ~win32.WS_POPUP) |
        win32.WS_CHILD;
    win32.SetWindowLongPtr(_windowHandle, win32.GWL_STYLE, framelessStyle);

    // 当前窗口扩展样式。
    final int currentExtendedStyle = win32.GetWindowLongPtr(
      _windowHandle,
      win32.GWL_EXSTYLE,
    ).value;
    // 不使用整窗 layered 缓存：它会在左扩时短暂搬移旧尺寸的 Flutter 画面。
    // 半透明仍由 Flutter 卡片背景和原生毛玻璃提供，避免两套合成路径叠加。
    // 宿主从右侧定位子视图，保持左扩过程的右边界。
    // 禁止布局继承：Flutter 子视图仍使用正常的文字、绘制和鼠标坐标。
    final int floatingExtendedStyle =
        (currentExtendedStyle & ~win32.WS_EX_APPWINDOW & ~win32.WS_EX_LAYERED) |
        win32.WS_EX_TOOLWINDOW |
        win32.WS_EX_LAYOUTRTL |
        win32.WS_EX_NOINHERITLAYOUT;
    win32.SetWindowLongPtr(
      _windowHandle,
      win32.GWL_EXSTYLE,
      floatingExtendedStyle,
    );
    // 位于普通应用下方、桌面图标上方的实际桌面宿主。
    final win32.HWND? desktopHandle = _findDesktopHost();
    if (desktopHandle != null) {
      _desktopHandle = desktopHandle;
      win32.SetParent(_windowHandle, desktopHandle);
    }
    win32.SetWindowPos(
      _windowHandle,
      win32.HWND_TOP,
      0,
      0,
      0,
      0,
      win32.SWP_FRAMECHANGED |
          win32.SWP_NOMOVE |
          win32.SWP_NOSIZE |
          win32.SWP_NOACTIVATE |
          win32.SWP_SHOWWINDOW,
    );
  }

  /// 为悬浮窗启用 Windows Acrylic 毛玻璃背景。
  void _enableAcrylicBackdrop() {
    // Acrylic 背景策略。
    final Pointer<win32.ACCENT_POLICY> accentPolicy =
        calloc<win32.ACCENT_POLICY>();
    // 窗口合成属性参数。
    final Pointer<win32.WINDOWCOMPOSITIONATTRIBDATA> compositionData =
        calloc<win32.WINDOWCOMPOSITIONATTRIBDATA>();
    try {
      accentPolicy.ref
        ..AccentState = win32.ACCENT_ENABLE_ACRYLICBLURBEHIND
        ..AccentFlags = 2
        ..GradientColor = 0xB8F6F3EF
        ..AnimationId = 0;
      compositionData.ref
        ..Attrib = win32.WCA_ACCENT_POLICY
        ..pvData = accentPolicy.cast()
        ..cbData = sizeOf<win32.ACCENT_POLICY>();
      // 当前系统是否成功启用 Acrylic。
      final bool acrylicEnabled = win32.SetWindowCompositionAttribute(
        _windowHandle,
        compositionData,
      );
      if (!acrylicEnabled) {
        _enableLegacyBlurBackdrop();
      }
    } finally {
      calloc.free(accentPolicy);
      calloc.free(compositionData);
    }
  }

  /// Acrylic 不可用时启用传统 DWM Blur Behind。
  void _enableLegacyBlurBackdrop() {
    // 传统 DWM 模糊参数。
    final Pointer<win32.DWM_BLURBEHIND> blurBehind =
        calloc<win32.DWM_BLURBEHIND>();
    try {
      blurBehind.ref
        ..dwFlags = win32.DWM_BB_ENABLE
        ..fEnable = true
        ..hRgnBlur = win32.HRGN(nullptr)
        ..fTransitionOnMaximized = false;
      win32.DwmEnableBlurBehindWindow(_windowHandle, blurBehind);
    } catch (error, stackTrace) {
      debugPrint('Windows 悬浮窗毛玻璃启用失败：$error\n$stackTrace');
    } finally {
      calloc.free(blurBehind);
    }
  }

  /// 查找承载桌面图标的 WorkerW，找不到时回退到 Progman。
  win32.HWND? _findDesktopHost() {
    // Windows 桌面工作窗口类名。
    final Pointer<Utf16> workerClassName = 'WorkerW'.toNativeUtf16();
    // Windows 桌面图标视图类名。
    final Pointer<Utf16> desktopViewClassName = 'SHELLDLL_DefView'
        .toNativeUtf16();
    // Windows 桌面管理窗口类名。
    final Pointer<Utf16> programManagerClassName = 'Progman'.toNativeUtf16();
    try {
      // 当前遍历到的顶层 WorkerW。
      win32.HWND workerHandle = win32.FindWindowEx(
        null,
        null,
        win32.PCWSTR(workerClassName),
        null,
      ).value;
      while (workerHandle != nullptr) {
        // 当前 WorkerW 内的桌面图标视图。
        final win32.HWND desktopViewHandle = win32.FindWindowEx(
          workerHandle,
          null,
          win32.PCWSTR(desktopViewClassName),
          null,
        ).value;
        if (desktopViewHandle != nullptr) {
          return workerHandle;
        }
        workerHandle = win32.FindWindowEx(
          null,
          workerHandle,
          win32.PCWSTR(workerClassName),
          null,
        ).value;
      }
      // 未找到图标宿主时使用传统 Progman 桌面窗口。
      final win32.HWND programManagerHandle = win32.FindWindow(
        win32.PCWSTR(programManagerClassName),
        null,
      ).value;
      return programManagerHandle == nullptr ? null : programManagerHandle;
    } finally {
      calloc.free(workerClassName);
      calloc.free(desktopViewClassName);
      calloc.free(programManagerClassName);
    }
  }

  /// 将窗口移动到显示器工作区内的逻辑坐标。
  void moveToDisplayPosition(Display display, Offset logicalPosition) {
    // 当前显示器缩放比例。
    final double scaleFactor = (display.scaleFactor ?? 1).toDouble();
    _currentScaleFactor = scaleFactor;
    // 当前显示器工作区逻辑起点。
    final Offset logicalWorkAreaOrigin = display.visiblePosition ?? Offset.zero;
    // 目标屏幕物理坐标。
    final Offset physicalScreenPosition =
        (logicalWorkAreaOrigin + logicalPosition) * scaleFactor;
    _moveToScreenPosition(physicalScreenPosition);
  }

  /// 记录拖动开始时的鼠标与窗口位置。
  void beginDrag() {
    // 当前鼠标物理坐标。
    final Offset? cursorPosition = _readCursorPosition();
    if (cursorPosition == null) {
      return;
    }
    _dragCursorOrigin = cursorPosition;
    _dragWindowOrigin = screenPosition;
  }

  /// 根据当前鼠标位置更新窗口位置。
  void updateDrag() {
    // 拖动起始鼠标坐标。
    final Offset? cursorOrigin = _dragCursorOrigin;
    // 拖动起始窗口坐标。
    final Offset? windowOrigin = _dragWindowOrigin;
    // 当前鼠标坐标。
    final Offset? currentCursor = _readCursorPosition();
    if (cursorOrigin == null || windowOrigin == null || currentCursor == null) {
      return;
    }
    _moveToScreenPosition(windowOrigin + currentCursor - cursorOrigin);
  }

  /// 记录左下角尺寸调整开始时的鼠标和窗口矩形。
  void beginResizeFromBottomLeft() {
    // 当前鼠标物理坐标。
    final Offset? cursorPosition = _readCursorPosition();
    if (cursorPosition == null) {
      return;
    }
    // 当前窗口物理位置。
    final Offset currentPosition = screenPosition;
    // 当前窗口物理尺寸。
    final Size currentSize = physicalSize;
    _resizeCursorOrigin = cursorPosition;
    _resizeWindowRect = currentPosition & currentSize;
    _resizeTargetRect = null;
  }

  /// 根据当前鼠标位置从左下角调整窗口宽高。
  void updateResizeFromBottomLeft() {
    // 调整尺寸起始鼠标坐标。
    final Offset? cursorOrigin = _resizeCursorOrigin;
    // 调整尺寸起始窗口矩形。
    final Rect? initialRect = _resizeWindowRect;
    // 当前鼠标坐标。
    final Offset? currentCursor = _readCursorPosition();
    if (cursorOrigin == null || initialRect == null || currentCursor == null) {
      return;
    }
    // 当前显示器缩放后的最小物理尺寸。
    final Size minimumPhysicalSize =
        _floatingWindowInitialSize * _currentScaleFactor;
    // 左下角拖动后的目标物理矩形。
    final Rect targetRect = resizeFloatingRectFromBottomLeft(
      initialRect: initialRect,
      pointerDelta: currentCursor - cursorOrigin,
      minimumSize: minimumPhysicalSize,
    );
    _resizeTargetRect = targetRect;
    unawaited(_resizeScheduler.schedule().catchError(_handleResizeError));
  }

  /// 原生更新完成后才提交最新矩形，不在 Dart 手势栈内同步更新窗口。
  Future<void> _applyPendingResize() async {
    // 本轮合并后的最终窗口矩形。
    final Rect? targetRect = _resizeTargetRect;
    if (targetRect != null) {
      await _resizeService.setBounds(_windowHandle.address, targetRect);
    }
  }

  /// 应用最后一次尺寸变化并清理拖拽起点。
  Future<void> endResizeFromBottomLeft() async {
    updateResizeFromBottomLeft();
    // 先结束本轮手势，等待期间开始的新手势不能被旧结束回调清除。
    _resizeCursorOrigin = null;
    _resizeWindowRect = null;
    await _resizeScheduler.flush();
  }

  /// 记录提交错误，避免手势回调留下未处理的异步异常。
  void _handleResizeError(Object error, StackTrace stackTrace) {
    debugPrint('Windows 悬浮窗尺寸更新失败：$error\n$stackTrace');
  }

  /// 读取当前鼠标的屏幕物理坐标。
  Offset? _readCursorPosition() {
    // 鼠标原生坐标。
    final Pointer<win32.POINT> point = calloc<win32.POINT>();
    try {
      if (!win32.GetCursorPos(point).value) {
        return null;
      }
      return Offset(point.ref.x.toDouble(), point.ref.y.toDouble());
    } finally {
      calloc.free(point);
    }
  }

  /// 将桌面子窗口移动到指定屏幕物理坐标。
  void _moveToScreenPosition(Offset screenPosition) {
    // 移动时需要保持的当前窗口物理尺寸。
    final Size currentPhysicalSize = physicalSize;
    _setBoundsAtScreenRect(screenPosition & currentPhysicalSize);
  }

  /// 仅移动桌面子窗口，尺寸更新统一走异步原生通道。
  void _setBoundsAtScreenRect(Rect screenRect) {
    // 四舍五入后的目标屏幕左坐标。
    final int targetLeft = screenRect.left.round();
    // 四舍五入后的目标屏幕顶坐标。
    final int targetTop = screenRect.top.round();
    // 四舍五入后的目标物理宽度。
    final int targetWidth = screenRect.width.round();
    // 四舍五入后的目标物理高度。
    final int targetHeight = screenRect.height.round();
    // 当前窗口原生矩形。
    final Pointer<win32.RECT> currentRect = calloc<win32.RECT>();
    try {
      // 左边缘移动会让 Flutter 手势坐标系同步变化；忽略该反馈产生的重复更新。
      if (win32.GetWindowRect(_windowHandle, currentRect).value &&
          currentRect.ref.left == targetLeft &&
          currentRect.ref.top == targetTop &&
          currentRect.ref.right == targetLeft + targetWidth &&
          currentRect.ref.bottom == targetTop + targetHeight) {
        return;
      }
    } finally {
      calloc.free(currentRect);
    }
    // 桌面宿主句柄。
    final win32.HWND? desktopHandle = _desktopHandle;
    // 目标原生坐标。
    final Pointer<win32.POINT> point = calloc<win32.POINT>();
    // 本次窗口位置更新使用的原生标志。
    final win32.SET_WINDOW_POS_FLAGS positionFlags =
        win32.SWP_NOACTIVATE |
        win32.SWP_NOZORDER |
        win32.SWP_NOOWNERZORDER |
        win32.SWP_NOSIZE;
    try {
      point.ref.x = targetLeft;
      point.ref.y = targetTop;
      if (desktopHandle != null) {
        win32.ScreenToClient(desktopHandle, point);
      }
      win32.SetWindowPos(
        _windowHandle,
        null,
        point.ref.x,
        point.ref.y,
        targetWidth,
        targetHeight,
        positionFlags,
      );
    } finally {
      calloc.free(point);
    }
  }

  /// 按逻辑尺寸直接调整无边框原生窗口，避免沿用创建前的系统边框宽度。
  void resizeToLogicalSize(Size logicalSize) {
    // 目标物理尺寸。
    final Size physicalTargetSize = logicalSize * _currentScaleFactor;
    win32.SetWindowPos(
      _windowHandle,
      win32.HWND_TOP,
      0,
      0,
      physicalTargetSize.width.round(),
      physicalTargetSize.height.round(),
      win32.SWP_NOMOVE | win32.SWP_NOACTIVATE,
    );
  }
}

/// 主窗口原生显示与隐藏工具。
abstract final class _WindowsWindowVisibility {
  /// 隐藏指定窗口。
  static void hide(RegularWindowController controller) {
    // 指定窗口原生句柄。
    final win32.HWND windowHandle = win32.HWND(
      (controller as WindowControllerWin32).windowHandle,
    );
    win32.ShowWindow(windowHandle, win32.SW_HIDE);
  }

  /// 恢复并显示指定窗口。
  static void show(RegularWindowController controller) {
    // 指定窗口原生句柄。
    final win32.HWND windowHandle = win32.HWND(
      (controller as WindowControllerWin32).windowHandle,
    );
    win32.ShowWindow(windowHandle, win32.SW_RESTORE);
    win32.ShowWindow(windowHandle, win32.SW_SHOW);
  }
}
