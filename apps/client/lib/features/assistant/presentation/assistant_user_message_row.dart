import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 整行悬停时显示用户消息时间与复制操作，气泡宽度继续由正文决定。
class AssistantUserMessageRow extends StatefulWidget {
  /// 稳定消息身份用于独立定位操作，不按正文合并重复消息。
  final String messageId;

  /// 复制原始正文，保留换行和Markdown内容。
  final String content;

  /// 仅使用服务器真实创建时间，旧缓存缺失时不补造。
  final String? createdAt;

  /// 与当前消息列共用中性颜色。
  final AssistantWindowsPalette colors;

  /// 已完成最大宽度与右对齐的消息气泡。
  final Widget child;

  /// 创建有稳定操作身份的消息行。
  const AssistantUserMessageRow({
    required this.messageId,
    required this.content,
    required this.createdAt,
    required this.colors,
    required this.child,
    super.key,
  });

  /// 悬停和复制反馈仅属于本条消息。
  @override
  State<AssistantUserMessageRow> createState() =>
      _AssistantUserMessageRowState();
}

/// 固定预留操作区域，悬停不会改变气泡与后续回答的位置。
class _AssistantUserMessageRowState extends State<AssistantUserMessageRow> {
  /// 包括气泡左侧空白及下方工具栏的整行悬停状态。
  bool _hovered = false;

  /// 键盘进入消息行也能查看并访问复制操作。
  bool _focused = false;

  /// 复制成功时用对勾提供轻量反馈。
  bool _copied = false;

  /// 离开页面时释放复制反馈的恢复计时器。
  Timer? _copyReset;

  /// 每次点击复制固定当前正文，失败时不伪造成功状态。
  Future<void> _copy() async {
    // 等待剪贴板期间正文可能因刷新更新。
    final String content = widget.content;
    try {
      await Clipboard.setData(ClipboardData(text: content));
      if (!mounted || widget.content != content) return;
      _copyReset?.cancel();
      setState(() => _copied = true);
      _copyReset = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (_) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '复制未完成，请重试',
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 正文变化后清除旧内容的成功反馈。
  @override
  void didUpdateWidget(covariant AssistantUserMessageRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _copyReset?.cancel();
      _copied = false;
    }
  }

  /// 不让复制反馈计时器超出消息生命周期。
  @override
  void dispose() {
    _copyReset?.cancel();
    super.dispose();
  }

  /// 时间使用本机时区，完整日期通过悬停提示提供。
  @override
  Widget build(BuildContext context) {
    // 不使用当前时间或会话更新时间代替消息时间。
    final DateTime? createdAt = widget.createdAt == null
        ? null
        : DateTime.tryParse(widget.createdAt!)?.toLocal();
    // 鼠标离开时仍允许键盘操作，避免焦点所在按钮突然消失。
    final bool visible = _hovered || _focused;
    return MouseRegion(
      opaque: true,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        onFocusChange: (bool value) => setState(() => _focused = value),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            widget.child,
            const SizedBox(height: 8),
            ExcludeFocus(
              excluding: !visible,
              child: ExcludeSemantics(
                excluding: !visible,
                child: IgnorePointer(
                  ignoring: !visible,
                  child: AnimatedOpacity(
                    key: ValueKey<String>(
                      'assistant-message-actions-${widget.messageId}',
                    ),
                    opacity: visible ? 1 : 0,
                    duration: OmniMotion.duration(context, OmniMotion.fast),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: <Widget>[
                        if (createdAt != null)
                          Tooltip(
                            message: DateFormat('yyyy-MM-dd HH:mm:ss')
                                .format(createdAt),
                            child: Text(
                              DateFormat('HH:mm').format(createdAt),
                              key: ValueKey<String>(
                                'assistant-message-date-${widget.messageId}',
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: widget.colors.muted,
                              ),
                            ),
                          ),
                        OmniIconButton(
                          key: ValueKey<String>(
                            'assistant-copy-message-${widget.messageId}',
                          ),
                          tooltip: _copied ? '已复制' : '复制消息',
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            _copied ? Icons.check : Icons.content_copy_outlined,
                            size: 16,
                          ),
                          color: widget.colors.muted,
                          onPressed: widget.content.isEmpty ? null : _copy,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
