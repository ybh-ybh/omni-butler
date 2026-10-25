import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/features/assistant/data/assistant_attachments.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Windows 聊天工作区接收系统文件，继续复用现有私有草稿链路。
class AssistantFileDropArea extends StatefulWidget {
  /// 当前来源和聊天的附件控制器。
  final AssistantAttachments attachments;

  /// 页面网络、模型设置及提交状态共同决定是否可接收。
  final bool enabled;

  /// 仅包裹聊天与输入区域，不包含左侧历史。
  final Widget child;

  /// 创建系统文件投放区域。
  const AssistantFileDropArea({
    required this.attachments,
    required this.enabled,
    required this.child,
    super.key,
  });

  /// 保存一次拖入对应的草稿身份。
  @override
  State<AssistantFileDropArea> createState() => _AssistantFileDropAreaState();
}

/// 拖入期间切换聊天或弹出窗口后，不把旧文件加到新的草稿。
class _AssistantFileDropAreaState extends State<AssistantFileDropArea> {
  /// 指针当前位于投放区域中。
  bool _hovered = false;

  /// 本次进入时固定的草稿代次；插件先发退出再发完成，因此单独保留。
  int? _draftToken;

  /// 本页正在绑定或已经绑定的真实视图身份。
  int? _viewId;

  /// 必须收到实际 OLE 注册成功回执，才启用拖放交互。
  bool _nativeReady = false;

  /// 已存在的插件通道继续承载事件，新增视图绑定请求。
  static const MethodChannel _channel = MethodChannel('desktop_drop');

  /// 多窗口宿主启动时尚无原生窗口，当前视图创建后显式绑定。
  void _initializeNative() {
    if (!widget.enabled || !widget.attachments.enabled) return;
    // View 的身份来自当前构建上下文，不使用前台窗口猜测。
    final int viewId = View.of(context).viewId;
    if (_viewId == viewId) return;
    _viewId = viewId;
    _nativeReady = false;
    unawaited(_bindView(viewId));
  }

  /// 回执到达前后都验证视图身份，关闭后的异步结果不能更新新页面。
  Future<void> _bindView(int viewId) async {
    try {
      // 只有成功注册对应 HWND 的原生目标才返回 true。
      final bool ready =
          await _channel.invokeMethod<bool>('initializeView', viewId) == true;
      if (mounted && _viewId == viewId) setState(() => _nativeReady = ready);
    } on PlatformException {
      debugPrint('Windows file drop registration failed');
    } on MissingPluginException {
      debugPrint('Windows file drop binding unavailable');
    }
  }

  /// 当前页面明确允许添加，传输和未知发送阶段都不能修改附件。
  bool get _enabled =>
      widget.enabled &&
      _nativeReady &&
      widget.attachments.enabled &&
      widget.attachments.editable &&
      !widget.attachments.transferring &&
      (ModalRoute.isCurrentOf(context) ?? true);

  /// 新弹窗或路由覆盖聊天时先撤销提示，底层目标随后取消接收。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _initializeNative();
    if (!_enabled) {
      _hovered = false;
      _draftToken = null;
    }
  }

  /// 接收状态变更时同步撤销遮罩，避免子插件更新期间反向 setState。
  @override
  void didUpdateWidget(AssistantFileDropArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    _initializeNative();
    if (!widget.enabled ||
        !widget.attachments.editable ||
        widget.attachments.transferring ||
        oldWidget.attachments != widget.attachments ||
        _draftToken != widget.attachments.draftToken) {
      _hovered = false;
      _draftToken = null;
    }
  }

  /// 从系统拖入时固定目标草稿，后续恢复和发送仍由附件控制器处理。
  void _enter(DropEventDetails details) {
    if (!_enabled) return;
    setState(() {
      _hovered = true;
      _draftToken = widget.attachments.draftToken;
    });
  }

  /// 离开工作区或取消拖动立即收起提示。
  void _exit(DropEventDetails details) {
    if (_hovered) setState(() => _hovered = false);
  }

  /// 松开后只读取普通本地文件，不递归读取文件夹。
  Future<void> _drop(DropDoneDetails details) async {
    // 异步检查期间继续使用进入时的身份，拒绝跨会话晚到结果。
    final int? token = _draftToken;
    _draftToken = null;
    if (_hovered) setState(() => _hovered = false);
    if (!_enabled || token != widget.attachments.draftToken) return;
    // 交给已有控制器执行类型、数量、体积及私有复制校验。
    final List<AssistantPickedFile> picked = <AssistantPickedFile>[];
    try {
      for (final DropItem item in details.files) {
        if (item is! DropItemFile ||
            !File(item.path).isAbsolute ||
            await FileSystemEntity.type(item.path) !=
                FileSystemEntityType.file) {
          if (mounted && _enabled && token == widget.attachments.draftToken) {
            showOmniMessage(context, message: '请拖入文件，暂不支持文件夹');
          }
          return;
        }
        picked.add(AssistantPickedFile(name: item.name, sourcePath: item.path));
      }
    } on FileSystemException {
      if (mounted && _enabled && token == widget.attachments.draftToken) {
        showOmniMessage(context, message: '无法读取拖入的文件，请重新添加');
      }
      return;
    }
    if (!mounted || !_enabled || token != widget.attachments.draftToken) return;
    await widget.attachments.add(picked);
  }

  /// 半透明遮罩覆盖完整聊天区域，仍由底层投放目标跟踪系统拖动。
  @override
  Widget build(BuildContext context) {
    // 遮罩表面和文字适配应用明暗主题。
    final AssistantWindowsPalette colors = AssistantWindowsPalette.of(context);
    return DropTarget(
      key: const ValueKey<String>('assistant-file-drop-target'),
      enable: _enabled,
      onDragEntered: _enter,
      onDragExited: _exit,
      onDragDone: (DropDoneDetails details) => unawaited(_drop(details)),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          widget.child,
          if (_hovered && _enabled)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  key: const ValueKey<String>('assistant-file-drop-overlay'),
                  color: colors.canvas.withValues(alpha: .82),
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.canvas,
                        border: Border.all(color: colors.line),
                        borderRadius: BorderRadius.circular(
                          AssistantWindowsMetrics.rowRadius,
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .08),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: Text(
                          '松开即可添加文件',
                          style: TextStyle(fontSize: 16, color: colors.ink),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
