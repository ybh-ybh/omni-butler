import 'dart:async';

/// 合并连续指针事件，并阻止 SetWindowPos 等待绘制时发生重入缩放。
class FloatingResizeScheduler {
  /// 创建约一帧提交一次的尺寸更新器。
  FloatingResizeScheduler(this.applyResize);

  /// 读取最新鼠标位置并提交原生矩形的操作。
  final void Function() applyResize;

  /// 当前尚未提交的帧定时器。
  Timer? _timer;

  /// 是否正在原生尺寸更新中，原生消息循环可能重新进入 Dart。
  bool _isApplying = false;

  /// 关闭后不再允许排队或提交尺寸。
  bool _disposed = false;

  /// 将高频事件合并为下一帧的最新尺寸。
  void schedule() {
    if (_disposed || _timer != null) {
      return;
    }
    _timer = Timer(const Duration(milliseconds: 16), flush);
  }

  /// 松开时立即提交最后位置，重入时延至下一帧。
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) {
      return;
    }
    if (_isApplying) {
      schedule();
      return;
    }
    _isApplying = true;
    try {
      applyResize();
    } finally {
      _isApplying = false;
    }
  }

  /// 取消待提交事件，避免关闭后的旧回调操作失效句柄。
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
