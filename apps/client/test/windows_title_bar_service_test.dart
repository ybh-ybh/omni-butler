import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/features/floating/platform/windows_title_bar_service.dart';

/// 验证 Dart 与原生标题栏通道的句柄、颜色格式及错误传递。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 生产服务的原生通道名。
  const MethodChannel channel = MethodChannel('omni/windows_title_bar');
  tearDown(() {
    WindowsTitleBarService().stopObservingVoiceLifecycle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('系统最小化在语音和草稿清理完成前不回复原生', () async {
    // 模拟实际仍在等待的采集关闭及保存。
    final Completer<void> flushed = Completer<void>();
    // 主窗口拥有的通道服务。
    final WindowsTitleBarService service = WindowsTitleBarService();
    service.observeVoiceLifecycle(() => flushed.future);
    // 原生发来的系统最小化请求。
    const StandardMethodCodec codec = StandardMethodCodec();
    // 收到回包后原生才允许执行最小化。
    final Completer<ByteData?> response = Completer<ByteData?>();
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      codec.encodeMethodCall(const MethodCall('beforeMinimize')),
      response.complete,
    );
    await Future<void>.delayed(Duration.zero);
    expect(response.isCompleted, isFalse);
    flushed.complete();
    expect(codec.decodeEnvelope((await response.future)!), isNull);
  });

  test('系统隐藏回调的保存失败向原生返回失败以保留窗口', () async {
    // 主窗口生命周期服务。
    final WindowsTitleBarService service = WindowsTitleBarService();
    service.observeVoiceLifecycle(() async => throw StateError('保存失败'));
    // 原生请求及回包。
    const StandardMethodCodec codec = StandardMethodCodec();
    // 捕获通道返回的实际错误 envelope。
    final Completer<ByteData?> response = Completer<ByteData?>();
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      codec.encodeMethodCall(const MethodCall('beforeMinimize')),
      response.complete,
    );
    // 平台得到失败时不会继续系统最小化。
    final ByteData? result = await response.future;
    expect(
      () => codec.decodeEnvelope(result!),
      throwsA(isA<PlatformException>()),
    );
  });

  test('窗口按钮通过异步原生通道提交且保留64位句柄', () async {
    // 本次窗口操作实际提交的消息顺序。
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
    // 同一服务同时承担标题栏和窗口按钮的原生桥接。
    final WindowsTitleBarService service = WindowsTitleBarService();
    await service.toggleMaximize(0x123456789);
    await service.minimize(0x123456789);
    expect(calls.map((MethodCall call) => call.method), <String>[
      'toggleMaximize',
      'minimize',
    ]);
    for (final MethodCall call in calls) {
      expect(call.arguments, <String, Object>{'windowHandle': 0x123456789});
    }
  });

  test('保留64位主窗口句柄并将颜色编码成原生COLORREF', () async {
    // 原生端实际收到的方法调用。
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          received = call;
          return true;
        });
    await WindowsTitleBarService().applyTheme(
      windowHandle: 0x123456789,
      dark: true,
      background: const Color(0xFF54647D),
      foreground: Colors.white,
      captionHeight: 28,
      captionButtonsWidth: 138,
    );
    expect(received?.method, 'applyTheme');
    expect(received?.arguments, <String, Object>{
      'windowHandle': 0x123456789,
      'dark': true,
      'background': 0x7D6454,
      'foreground': 0xFFFFFF,
      'captionHeight': 28,
      'captionButtonsWidth': 138,
    });
  });

  test('旧系统未支持精确配色时通知宿主启用兼容标题栏', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => false);
    // 原生端返回 false 时必须保留这个结果，宿主据此显示自绘标题栏。
    final bool exactColorsApplied = await WindowsTitleBarService().applyTheme(
      windowHandle: 1,
      dark: false,
      background: Colors.white,
      foreground: Colors.black,
      captionHeight: 28,
      captionButtonsWidth: 138,
    );
    expect(exactColorsApplied, isFalse);
  });

  test('原生失败向协调器传递以便撤销去重状态', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          throw PlatformException(code: 'invalid_window');
        });
    await expectLater(
      WindowsTitleBarService().applyTheme(
        windowHandle: 1,
        dark: false,
        background: Colors.white,
        foreground: Colors.black,
        captionHeight: 28,
        captionButtonsWidth: 138,
      ),
      throwsA(isA<PlatformException>()),
    );
  });
}
