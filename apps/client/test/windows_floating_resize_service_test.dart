import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/features/floating/platform/windows_floating_resize_service.dart';

/// 验证原生消息通道使用屏幕物理坐标和固定右/上边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('缩放请求保留右边界，避免小数缩放比例产生一像素往复跳变', () async {
    // 测试接收到的方法请求。
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsFloatingResizeService.channel, (
          MethodCall call,
        ) async {
          received = call;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WindowsFloatingResizeService.channel, null);
    });
    await WindowsFloatingResizeService().setBounds(
      12345,
      const Rect.fromLTRB(632.5, 14.6, 1000, 700.4),
    );
    expect(received!.method, 'setBounds');
    expect(received!.arguments, <String, int>{
      'handle': 12345,
      'left': 633,
      'top': 15,
      'width': 367,
      'height': 685,
    });
  });
}
