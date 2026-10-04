import 'dart:async';

/// 单次原生更新完成后才提交最新矩形，不使用与显示帧率脱节的定时器。
class FloatingResizeScheduler {
  /// 创建等待原生尺寸更新完成的提交器。
  FloatingResizeScheduler(this.applyResize);

  /// 在原生消息线程完成矩形更新的异步操作。
  final Future<void> Function() applyResize;

  /// 当前完整的串行提交任务。
  Future<void>? _operation;

  /// 原生更新期间是否又收到新矩形。
  bool _pending = false;

  /// 关闭后不再提交任何新请求。
  bool _disposed = false;

  /// 同一事件轮合并请求，执行期间只保留最新矩形。
  Future<void> schedule() {
    if (_disposed) return Future<void>.value();
    _pending = true;
    return _operation ??= Future<void>.microtask(_drain);
  }

  /// 松开鼠标后等待最后一个矩形真正应用，再读取位置和尺寸。
  Future<void> flush() => schedule();

  /// 顺序提交原生请求，让 Dart 等待期间仍可处理新帧。
  Future<void> _drain() async {
    try {
      while (_pending && !_disposed) {
        _pending = false;
        await applyResize();
      }
    } finally {
      _operation = null;
    }
  }

  /// 关闭时丢弃待提交的矩形，已发往原生的请求由句柄校验保护。
  void dispose() {
    _disposed = true;
    _pending = false;
  }
}
