import 'package:flutter/services.dart';

/// 将标题栏主题交给原生宿主，统一处理设置更新及系统主题消息。
class WindowsTitleBarService {
  /// 主窗口标题栏的专用平台通道。
  static const MethodChannel _channel = MethodChannel('omni/windows_title_bar');

  /// 异步请求最小化，避免在 Dart 绘制线程同步调用 ShowWindow。
  Future<void> minimize(int windowHandle) => _channel.invokeMethod<void>(
    'minimize',
    <String, Object>{'windowHandle': windowHandle},
  );

  /// 由原生窗口消息循环切换最大化或还原，允许 Flutter 同步绘制新帧。
  Future<void> toggleMaximize(int windowHandle) => _channel.invokeMethod<void>(
    'toggleMaximize',
    <String, Object>{'windowHandle': windowHandle},
  );

  /// 同步主窗口颜色；返回 false 时由 Flutter 绘制兼容标题栏。
  Future<bool> applyTheme({
    required int windowHandle,
    required bool dark,
    required Color background,
    required Color foreground,
    required int captionHeight,
    required int captionButtonsWidth,
  }) async {
    return await _channel.invokeMethod<bool>('applyTheme', <String, Object>{
          'windowHandle': windowHandle,
          'dark': dark,
          'background': _toColorRef(background),
          'foreground': _toColorRef(foreground),
          'captionHeight': captionHeight,
          'captionButtonsWidth': captionButtonsWidth,
        }) ??
        false;
  }

  /// 将 Flutter ARGB 转成 Windows 使用的不含透明度的 BGR COLORREF。
  static int _toColorRef(Color color) {
    // 使用八位通道值避免浮点转换造成一阶色差。
    final int argb = color.toARGB32();
    return ((argb & 0xff) << 16) | (argb & 0xff00) | ((argb >> 16) & 0xff);
  }
}
