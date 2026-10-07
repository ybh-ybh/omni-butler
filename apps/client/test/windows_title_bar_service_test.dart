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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
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
