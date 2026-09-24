import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/features/floating/platform/windows_tray_service.dart';

/// 验证 Windows 托盘 MethodChannel 的命令与事件桥接。
void main() {
  // 测试使用的 Flutter 二进制消息绑定。
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  // 与生产代码一致的 Windows 托盘通道。
  const MethodChannel channel = MethodChannel('omni/windows_tray');

  test('托盘服务发送初始化状态并分发三个原生事件', () async {
    // 发往 Windows Runner 的方法调用记录。
    final List<MethodCall> outgoingCalls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      MethodCall call,
    ) async {
      outgoingCalls.add(call);
      return null;
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    // 测试用托盘桥接服务。
    final WindowsTrayService service = WindowsTrayService();
    // 收到的原生托盘事件顺序。
    final List<String> events = <String>[];
    service.onOpen = () => events.add('open');
    service.onToggle = () => events.add('toggle');
    service.onExit = () => events.add('exit');

    await service.initialize(floatingEnabled: true);
    await service.setFloatingEnabled(false);
    await service.destroy();

    expect(outgoingCalls.map((MethodCall call) => call.method), <String>[
      'initialize',
      'setFloatingEnabled',
      'destroy',
    ]);
    // 初始化时发送给 Runner 的参数。
    final Map<Object?, Object?> initializeArguments =
        outgoingCalls.first.arguments as Map<Object?, Object?>;
    expect(initializeArguments['floatingEnabled'], isTrue);
    expect(
      initializeArguments['iconPath'],
      endsWith('windows\\runner\\resources\\app_icon.ico'),
    );

    for (final String eventName in <String>['open', 'toggle', 'exit']) {
      // 模拟 Windows Runner 发回的托盘事件消息。
      final ByteData eventMessage = const StandardMethodCodec()
          .encodeMethodCall(MethodCall('event', eventName));
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        eventMessage,
        (_) {},
      );
    }
    expect(events, <String>['open', 'toggle', 'exit']);
  });
}
