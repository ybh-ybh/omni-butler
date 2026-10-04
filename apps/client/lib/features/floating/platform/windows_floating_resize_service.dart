import 'package:flutter/services.dart';

/// 在 Windows 原生消息线程更新矩形，不从 Dart FFI 同步等待新帧。
class WindowsFloatingResizeService {
  /// 悬浮窗尺寸专用通道，独立于托盘生命周期。
  static const MethodChannel channel = MethodChannel('omni/windows_floating');

  /// 提交屏幕物理矩形；完成响应意味着窗口已经应用最终尺寸。
  Future<void> setBounds(int handle, Rect rect) =>
      channel.invokeMethod<void>('setBounds', <String, int>{
        'handle': handle,
        'left': rect.left.round(),
        'top': rect.top.round(),
        'width': rect.right.round() - rect.left.round(),
        'height': rect.bottom.round() - rect.top.round(),
      });
}
