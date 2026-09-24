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
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/features/floating/data/floating_window_preferences.dart';
import 'package:omni_butler/features/floating/platform/floating_window_placement.dart';
import 'package:omni_butler/features/floating/platform/windows_tray_service.dart';
import 'package:omni_butler/features/floating/presentation/floating_window_page.dart';
import 'package:omni_butler/features/settings/data/feature_preferences.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:win32/win32.dart' as win32;

/// 悬浮窗缩窄后的固定逻辑宽度。
const double _floatingWindowWidth = 294;

/// 悬浮窗首次创建时的逻辑尺寸。
const Size _floatingWindowInitialSize = Size(_floatingWindowWidth, 420);

/// 悬浮窗允许的最小逻辑高度。
const double _floatingWindowMinHeight = 240;

/// 悬浮窗允许的最大逻辑高度。
const double _floatingWindowMaxHeight = floatingWindowMaxContentHeight;

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
      constraints: const BoxConstraints(minWidth: 512, minHeight: 512),
      title: 'Omni Butler',
      delegate: _mainWindowDelegate,
    );
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
    with ScreenListener {
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

  @override
  void initState() {
    super.initState();
    widget.mainWindowDelegate.onCloseRequested = _handleMainCloseRequested;
    widget.mainWindowDelegate.onDestroyed = _handleMainWindowDestroyed;
    _trayService.onOpen = _showMainWindow;
    _trayService.onToggle = _toggleFloatingFromTray;
    _trayService.onExit = () => _queueOperation(_exitApplication);
    screenRetriever.addListener(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _windowRegistry = WindowRegistry.of(context);
  }

  @override
  void dispose() {
    screenRetriever.removeListener(this);
    widget.mainWindowDelegate.onCloseRequested = null;
    widget.mainWindowDelegate.onDestroyed = null;
    _trayService.onOpen = null;
    _trayService.onToggle = null;
    _trayService.onExit = null;
    unawaited(_disposeTray());
    _floatingNative = null;
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
    return widget.child;
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
    if (_floatingController != null) {
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
    controller = RegularWindowController(
      size: _floatingWindowInitialSize,
      constraints: const BoxConstraints(
        minWidth: _floatingWindowWidth,
        maxWidth: _floatingWindowWidth,
        minHeight: _floatingWindowMinHeight,
        maxHeight: _floatingWindowMaxHeight,
      ),
      title: 'Omni Butler · 今日',
      delegate: delegate,
    );
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
        onPreferredHeightChanged: _handleFloatingPreferredHeightChanged,
      ),
    );
    _floatingController = controller;
    _floatingEntry = entry;
    registry.register(entry);

    // 新窗口原生句柄需要等待首帧挂载完成。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _floatingController != controller) {
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

  /// 销毁当前悬浮窗口。
  Future<void> _hideFloatingWindow() async {
    // 待移除的悬浮窗条目。
    final WindowEntry? entry = _floatingEntry;
    // 待销毁的悬浮窗控制器。
    final RegularWindowController? controller = _floatingController;
    if (entry == null || controller == null) {
      return;
    }
    _floatingEntry = null;
    _floatingController = null;
    _floatingNative = null;
    _windowRegistry?.unregister(entry);
    controller.destroy();
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
    _floatingNative = null;
    controller?.dispose();
  }

  /// 从卡片关闭入口停用悬浮窗并恢复主窗口。
  Future<void> _disableFloatingFromCard() async {
    _showMainWindow();
    await ref.read(floatingWindowPreferenceProvider.notifier).setEnabled(false);
  }

  /// 恢复或重新约束悬浮窗位置。
  Future<void> _restoreFloatingPlacement({
    FloatingWindowPreference? preference,
  }) async {
    // 当前原生悬浮窗操作器。
    final _WindowsFloatingWindowNative? native = _floatingNative;
    if (native == null) {
      return;
    }
    // 当前设备保存的悬浮窗偏好。
    final FloatingWindowPreference resolvedPreference =
        preference ?? ref.read(floatingWindowPreferenceProvider);
    // 当前屏幕列表。
    final List<Display> displays = await _displayService.getAllDisplays(
      widget.mainWindowController.rootView.devicePixelRatio,
    );
    if (displays.isEmpty) {
      return;
    }
    // 当前系统主显示器。
    final Display primaryDisplay = await _displayService.getPrimaryDisplay(
      widget.mainWindowController.rootView.devicePixelRatio,
    );
    // 恢复目标显示器。
    final Display display = _findPreferredDisplay(
      displays,
      resolvedPreference.displayId,
      primaryDisplay,
    );
    // 恢复目标的逻辑坐标。
    final Offset desiredPosition = resolvedPreference.hasPlacement
        ? Offset(resolvedPreference.positionX!, resolvedPreference.positionY!)
        : _defaultPlacement(display);
    // 已保存位置贴边恢复，首次位置保留默认呼吸间距。
    final double placementMargin = resolvedPreference.hasPlacement
        ? 0
        : _floatingWindowMargin;
    // 限制并吸附到当前显示器工作区内的逻辑坐标。
    final Offset clampedPosition = snapFloatingPlacement(
      desiredPosition: desiredPosition,
      workAreaSize: display.visibleSize ?? display.size,
      windowSize: native.logicalSize,
      threshold: _floatingWindowSnapThreshold,
      margin: placementMargin,
    );
    native.moveToDisplayPosition(display, clampedPosition);
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
  Offset _defaultPlacement(Display display) {
    // 显示器可用工作区尺寸。
    final Size workAreaSize = display.visibleSize ?? display.size;
    return Offset(
      workAreaSize.width -
          _floatingWindowInitialSize.width -
          _floatingWindowMargin,
      workAreaSize.height -
          _floatingWindowInitialSize.height -
          _floatingWindowMargin,
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
    await _saveCurrentFloatingPlacement();
  }

  /// 按页面实际内容高度调整悬浮窗，并保持窗口位于工作区内。
  void _handleFloatingPreferredHeightChanged(double preferredHeight) {
    _queueOperation(() => _resizeFloatingWindow(preferredHeight));
  }

  /// 将悬浮窗调整为目标内容高度。
  Future<void> _resizeFloatingWindow(double preferredHeight) async {
    // 当前悬浮窗控制器。
    final RegularWindowController? controller = _floatingController;
    if (controller == null) {
      return;
    }
    // 受窗口约束限制后的目标高度。
    final double targetHeight = preferredHeight.clamp(
      _floatingWindowMinHeight,
      _floatingWindowMaxHeight,
    );
    // 当前原生悬浮窗操作器。
    final _WindowsFloatingWindowNative? native = _floatingNative;
    // 当前悬浮窗内容尺寸。
    final Size currentSize = native?.logicalSize ?? controller.contentSize;
    if ((currentSize.width - _floatingWindowWidth).abs() < 0.5 &&
        (currentSize.height - targetHeight).abs() < 0.5) {
      return;
    }
    // 目标悬浮窗逻辑尺寸。
    final Size targetSize = Size(_floatingWindowWidth, targetHeight);
    if (native == null) {
      controller.setSize(targetSize);
    } else {
      native.resizeToLogicalSize(targetSize);
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _floatingController != controller) {
      return;
    }
    await _saveCurrentFloatingPlacement();
  }

  /// 保存当前悬浮窗口所在显示器及相对位置。
  Future<void> _saveCurrentFloatingPlacement() async {
    // 当前原生悬浮窗操作器。
    final _WindowsFloatingWindowNative? native = _floatingNative;
    if (native == null) {
      return;
    }
    // 当前屏幕列表。
    final List<Display> displays = await _displayService.getAllDisplays(
      widget.mainWindowController.rootView.devicePixelRatio,
    );
    if (displays.isEmpty) {
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
    await ref
        .read(floatingWindowPreferenceProvider.notifier)
        .savePlacement(
          displayId: display.id,
          positionX: clampedPosition.dx,
          positionY: clampedPosition.dy,
        );
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
    _queueOperation(_exitApplication);
  }

  /// 隐藏主窗口到托盘。
  void _hideMainWindow() {
    _mainWindowHidden = true;
    _WindowsWindowVisibility.hide(widget.mainWindowController);
  }

  /// 恢复并激活主窗口。
  void _showMainWindow() {
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
    unawaited(
      ServicesBinding.instance.exitApplication(ui.AppExitType.required),
    );
  }

  /// 确保系统托盘已经创建并同步开关状态。
  Future<void> _ensureTray(bool floatingEnabled) async {
    if (_trayCreated) {
      await _trayService.setFloatingEnabled(floatingEnabled);
      return;
    }
    await _trayService.initialize(floatingEnabled: floatingEnabled);
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
  Future<void> _exitApplication() async {
    if (_isExiting) {
      return;
    }
    _isExiting = true;
    await _hideFloatingWindow();
    await _disposeTray();
    widget.mainWindowController.destroy();
    await ServicesBinding.instance.exitApplication(ui.AppExitType.required);
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
    required this.onPreferredHeightChanged,
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

  /// 内容期望高度变化回调。
  final ValueChanged<double> onPreferredHeightChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前主题模式。
    final ThemeMode themeMode = ref.watch(themeControllerProvider).mode;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(brightness: Brightness.light),
      darkTheme: AppTheme.build(brightness: Brightness.dark),
      themeMode: themeMode,
      home: FloatingWindowPage(
        onClose: onClose,
        onOpenRoute: onOpenRoute,
        onDragStart: onDragStart,
        onDragUpdate: onDragUpdate,
        onDragEnd: onDragEnd,
        onPreferredHeightChanged: onPreferredHeightChanged,
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

  /// 当前窗口所在显示器的缩放比例。
  double _currentScaleFactor = 1;

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
    // 隐藏任务栏入口并允许整窗半透明的扩展样式。
    final int floatingExtendedStyle =
        (currentExtendedStyle & ~win32.WS_EX_APPWINDOW) |
        win32.WS_EX_TOOLWINDOW |
        win32.WS_EX_LAYERED;
    win32.SetWindowLongPtr(
      _windowHandle,
      win32.GWL_EXSTYLE,
      floatingExtendedStyle,
    );
    win32.SetLayeredWindowAttributes(
      _windowHandle,
      const win32.COLORREF(0),
      246,
      win32.LWA_ALPHA,
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
    // 桌面宿主句柄。
    final win32.HWND? desktopHandle = _desktopHandle;
    // 目标原生坐标。
    final Pointer<win32.POINT> point = calloc<win32.POINT>();
    try {
      point.ref.x = screenPosition.dx.round();
      point.ref.y = screenPosition.dy.round();
      if (desktopHandle != null) {
        win32.ScreenToClient(desktopHandle, point);
      }
      // 移动时需要保持的当前窗口物理尺寸。
      final Size currentPhysicalSize = physicalSize;
      win32.SetWindowPos(
        _windowHandle,
        win32.HWND_TOP,
        point.ref.x,
        point.ref.y,
        currentPhysicalSize.width.round(),
        currentPhysicalSize.height.round(),
        win32.SWP_NOACTIVATE,
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
