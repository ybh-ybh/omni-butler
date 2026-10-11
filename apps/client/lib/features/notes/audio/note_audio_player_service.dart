import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

/// 原音播放服务；由录音服务共享并在启动采集前停止播放。
class NoteAudioPlayerService {
  /// 支持注入播放器以便集成测试。
  // 保留公开参数player，不能改成私有字段名的命名参数。
  // ignore: prefer_initializing_formals
  NoteAudioPlayerService({AudioPlayer? player}) : _player = player;

  /// 当前设备唯一原音播放器。
  AudioPlayer? _player;

  /// 当前播放的本机路径，多个录音卡片共享同一播放器。
  String? _currentPath;

  /// 音源身份变化广播，结束与停止后清空。
  final StreamController<String?> _currentPaths = StreamController.broadcast();

  /// 平台初始化前即可订阅的播放状态。
  final StreamController<PlayerState> _states = StreamController.broadcast();

  /// 平台初始化前即可订阅的播放位置。
  final StreamController<Duration> _positions = StreamController.broadcast();

  /// 平台初始化前即可订阅的文件时长。
  final StreamController<Duration> _durations = StreamController.broadcast();

  /// 平台初始化前即可订阅的播放结束。
  final StreamController<void> _completions = StreamController.broadcast();

  /// 真正回听后才建立的原生流订阅。
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// 多张卡片同时点击时按顺序切换真实音源，避免路径与声音错配。
  Future<void> _commands = Future.value();

  /// 当前回听原件身份。
  String? get currentPath => _currentPath;

  /// 回听原件身份广播。
  Stream<String?> get currentPaths => _currentPaths.stream;

  /// 录音服务注入的互斥检查，避免播放和采集并行。
  bool Function()? recordingActive;

  /// 当前播放状态广播。
  Stream<PlayerState> get states => _states.stream;

  /// 播放位置广播。
  Stream<Duration> get positions => _positions.stream;

  /// 文件总时长广播。
  Stream<Duration> get durations => _durations.stream;

  /// 回听结束广播。
  Stream<void> get completions => _completions.stream;

  /// 当前同步状态。
  PlayerState get state => _player?.state ?? PlayerState.stopped;

  /// 只有明确回听时创建播放器，预载和读取状态不调用平台通道。
  AudioPlayer _ensurePlayer() {
    // 本次实际回听使用的设备，注入的替身保持原实例。
    final AudioPlayer player = _player ??= AudioPlayer();
    if (_subscriptions.isEmpty) {
      _subscriptions.addAll([
        player.onPlayerStateChanged.listen(
          _states.add,
          onError: _states.addError,
        ),
        player.onPositionChanged.listen(
          _positions.add,
          onError: _positions.addError,
        ),
        player.onDurationChanged.listen(
          _durations.add,
          onError: _durations.addError,
        ),
        player.onPlayerComplete.listen(
          (_) {
            _setCurrentPath(null);
            _completions.add(null);
          },
          onError: (Object error, StackTrace stack) {
            _setCurrentPath(null);
            _completions.addError(error, stack);
          },
        ),
      ]);
    }
    return player;
  }

  /// 回听指定原音；调用方须传本机已下载的绝对路径。
  Future<void> play(String path) => _serial(() async {
    if (recordingActive?.call() ?? false) {
      throw StateError('请先结束录音，再回听原音');
    }
    _setCurrentPath(path);
    try {
      await _ensurePlayer().play(DeviceFileSource(path, mimeType: 'audio/wav'));
    } catch (_) {
      _setCurrentPath(null);
      rethrow;
    }
  });

  /// 暂停回听。
  Future<void> pause() => _serial(() async => _player?.pause());

  /// 继续回听时再次检查采集互斥。
  Future<void> resume() => _serial(() async {
    if (recordingActive?.call() ?? false) {
      throw StateError('请先结束录音，再回听原音');
    }
    await _player?.resume();
  });

  /// 调整回听位置。
  Future<void> seek(Duration position, {String? expectedPath}) =>
      _serial(() async {
        if (expectedPath != null && expectedPath != _currentPath) return;
        await _player?.seek(position);
      });

  /// 停止回听并释放当前音源。
  Future<void> stop() => _serial(() async {
    await _player?.stop();
    _setCurrentPath(null);
  });

  /// 应用级容器销毁时释放播放器。
  Future<void> dispose() async {
    await _commands;
    for (final StreamSubscription<dynamic> subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player?.dispose();
    await _currentPaths.close();
    await _states.close();
    await _positions.close();
    await _durations.close();
    await _completions.close();
  }

  /// 更新音源身份，在切换卡片和播放结束时保持一致。
  void _setCurrentPath(String? path) {
    _currentPath = path;
    if (!_currentPaths.isClosed) _currentPaths.add(path);
  }

  /// 保留每次操作的失败结果，失败后后续回听仍然可重试。
  Future<void> _serial(Future<void> Function() action) {
    // 向发起卡片交付真实结果。
    final result = _commands.then((_) => action());
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
