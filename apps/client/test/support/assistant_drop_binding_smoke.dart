// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/assistant/data/assistant_attachments.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_file_drop_area.dart';

/// 仅放开隔离窗口的编辑门禁，不连接认证、文件或网络。
class _SmokeAttachments extends AssistantAttachments {
  /// 初始化空白草稿，不创建真实聊天。
  _SmokeAttachments()
    : super(
        repository: null,
        scope: 'native-smoke',
        ensureConversation: () async => null,
        changed: () {},
        persist: () async {},
        frozen: () => false,
      ) {
    capabilities = <String, dynamic>{'enabled': true};
  }

  /// 当前合成草稿明确可编辑，原生绑定仍使用生产代码。
  @override
  bool get editable => true;
}

/// 使用与生产一致的先启动引擎、再创建 RegularWindow 模式，不访问用户数据。
void main() {
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  runWidget(const _DropBindingSmoke());
}

/// 窗口创建前插件已注册，用真实 viewId 验证延迟 OLE 绑定。
class _DropBindingSmoke extends StatefulWidget {
  /// 创建隔离验证窗口。
  const _DropBindingSmoke();

  /// 保存实际窗口控制器。
  @override
  State<_DropBindingSmoke> createState() => _DropBindingSmokeState();
}

/// 绑定失败必须让进程返回非零，不能把组件假事件当作系统注册成功。
class _DropBindingSmokeState extends State<_DropBindingSmoke> {
  /// 当前验证窗口，仅显示合成状态文字。
  final RegularWindowController _controller = RegularWindowController(
    size: const Size(512, 512),
    title: 'Omni file drop binding smoke',
  );

  /// 防止每次重建重复启动检查。
  bool _started = false;

  /// 实际生产投放组件的上下文，用于核对原生回执后已启用。
  final GlobalKey _dropKey = GlobalKey();

  /// 隔离的空附件状态。
  final AssistantAttachments _attachments = _SmokeAttachments();

  /// 查看真实元素树中的 DropTarget，不伪造进入或完成事件。
  bool _dropEnabled() {
    // 仅遍历测试自己的生产组件。
    final BuildContext? target = _dropKey.currentContext;
    if (target == null) return false;
    // 找到原生确认后实际参与事件订阅的目标。
    bool ready = false;
    // 深度优先检查组件状态，不读取其他窗口。
    void visit(Element element) {
      if (element.widget case final DropTarget drop) {
        ready = ready || drop.enable;
      }
      element.visitChildElements(visit);
    }

    visit(target as Element);
    return ready;
  }

  /// 原生插件的正式通道，不替换任何方法处理器。
  static const MethodChannel _channel = MethodChannel('desktop_drop');

  /// 窗口创建完成后检查注册、重复绑定和不存在的视图。
  Future<void> _check(int viewId) async {
    try {
      stdout.writeln(
        'DROP_BINDING_VIEW: actual=$viewId implicit=${PlatformDispatcher.instance.implicitView?.viewId}',
      );
      // 自动初始化必须成功，不能靠本测试下面的重复 RPC 才完成绑定。
      for (int attempt = 0; attempt < 50 && !_dropEnabled(); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (!_dropEnabled()) throw StateError('生产拖放组件未收到实际窗口注册成功回执');
      if (await _channel.invokeMethod<bool>('initializeView', viewId) != true) {
        throw StateError('未实际注册 OLE 文件拖放');
      }
      // 不存在的 viewId 不能使已有窗口绑定失效。
      bool rejected = false;
      try {
        await _channel.invokeMethod<bool>('initializeView', 0x7fffffffffffffff);
      } on PlatformException catch (error) {
        rejected = error.code == 'invalid_view';
      }
      if (!rejected ||
          await _channel.invokeMethod<bool>('initializeView', viewId) != true) {
        throw StateError('视图绑定隔离或幂等检查失败');
      }
      stdout.writeln(
        'DROP_BINDING_SMOKE_PASSED: actual multiview OLE registration',
      );
      exit(0);
    } catch (error, stack) {
      stderr.writeln('DROP_BINDING_SMOKE_FAILED: $error\n$stack');
      exit(1);
    }
  }

  /// 创建真实 Flutter 视图后安排检查，绝不查找用户的其他窗口。
  @override
  Widget build(BuildContext context) => RegularWindow(
    controller: _controller,
    child: Builder(
      builder: (BuildContext context) {
        if (!_started) {
          _started = true;
          // 从当前视图上下文获取原生窗口的唯一映射身份。
          final int viewId = View.of(context).viewId;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => unawaited(_check(viewId)),
          );
        }
        return MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: Scaffold(
            body: AssistantFileDropArea(
              key: _dropKey,
              attachments: _attachments,
              enabled: true,
              child: const Center(child: Text('文件拖放原生绑定验证')),
            ),
          ),
        );
      },
    ),
  );
}
