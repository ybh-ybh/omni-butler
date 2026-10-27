import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 在同一应用容器内按所有者身份互斥麦克风，不随数据源切换重建。
class MicrophoneCoordinator {
  /// 当前占用者；只比较身份，旧会话不能释放新会话。
  Object? _owner;

  /// 启动、暂停和实际设备停止前均视为占用。
  bool get isOccupied => _owner != null;

  /// 同步预占设备，避免两个功能在权限请求期间同时启动。
  bool tryAcquire(Object owner) {
    if (_owner != null && !identical(_owner, owner)) return false;
    _owner = owner;
    return true;
  }

  /// 只有持有当前令牌的调用者可以释放设备。
  void release(Object owner) {
    if (identical(_owner, owner)) _owner = null;
  }
}

/// 由窗口宿主触发语音取消和草稿落盘，不依赖具体助手实现。
class VoiceInputLifecycle {
  /// 页面按身份注册的停止及保存回调。
  final Map<Object, Future<void> Function()> _callbacks =
      Map<Object, Future<void> Function()>.identity();

  /// 合并窗口隐藏、系统后台与退出同时触发的取消。
  Future<void>? _cancelling;

  /// 注册当前页面的取消和草稿持久化过程。
  void register(Object owner, Future<void> Function() cancelAndFlush) {
    _callbacks[owner] = cancelAndFlush;
  }

  /// 页面销毁只移除自己的回调，不影响新页面。
  void unregister(Object owner) => _callbacks.remove(owner);

  /// 等待已注册语音全部停止并保存草稿，失败向关闭流程传播。
  Future<void> cancelAll() {
    if (_cancelling != null) return _cancelling!;
    // 固定当前回调，允许页面在取消过程中销毁或注销。
    final List<Future<void> Function()> callbacks = _callbacks.values.toList();
    // 同步建立唯一任务，重复原生事件不会重复执行取消。
    final Completer<void> completion = Completer<void>();
    _cancelling = completion.future;
    unawaited(() async {
      try {
        await Future.wait<void>([
          for (final Future<void> Function() callback in callbacks)
            Future<void>.sync(callback),
        ]);
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      } finally {
        _cancelling = null;
      }
    }());
    return completion.future;
  }
}

/// 根容器共享的麦克风锁，不监听认证或同步数据源。
final Provider<MicrophoneCoordinator> microphoneCoordinatorProvider =
    Provider<MicrophoneCoordinator>((Ref ref) => MicrophoneCoordinator());

/// 根容器共享的语音窗口生命周期桥。
final Provider<VoiceInputLifecycle> voiceInputLifecycleProvider =
    Provider<VoiceInputLifecycle>((Ref ref) => VoiceInputLifecycle());
