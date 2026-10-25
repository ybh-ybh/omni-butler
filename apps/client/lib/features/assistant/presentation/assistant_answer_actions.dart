import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 回答整行悬停时显示时间和业务保存，手机使用同一操作区常驻显示。
class AssistantAnswerActions extends StatefulWidget {
  /// 稳定回答身份，不以相同正文合并操作状态。
  final String messageId;

  /// 服务器的消息创建时间，缺失时不补造当前时间。
  final String? createdAt;

  /// 主题的正文及次要文字颜色。
  final AssistantWindowsPalette colors;

  /// 手机没有鼠标，入口常驻可点击。
  final bool alwaysVisible;

  /// 是否已保存到业务笔记。
  final bool saved;

  /// 业务请求正在进行。
  final bool saving;

  /// 本条回答的保存错误。
  final String? error;

  /// 空正文及流式生成时不展示保存入口。
  final bool showSave;

  /// 不可用时仍保留时间和只读状态。
  final VoidCallback? onSave;

  /// 本条回答包含正文、执行链和卡片的完整区域。
  final Widget child;

  /// 创建回答独立的悬停及焦点区域。
  const AssistantAnswerActions({
    required this.messageId,
    required this.createdAt,
    required this.colors,
    required this.saved,
    required this.saving,
    required this.showSave,
    required this.child,
    this.alwaysVisible = false,
    this.error,
    this.onSave,
    super.key,
  });

  /// 每条回答单独维护显隐，不持久保存鼠标状态。
  @override
  State<AssistantAnswerActions> createState() => _AssistantAnswerActionsState();
}

/// 固定保留工具栏高度，移动鼠标不会推动后续消息。
class _AssistantAnswerActionsState extends State<AssistantAnswerActions> {
  /// 包含回答左侧空白及工具栏的整行悬停状态。
  bool _hovered = false;

  /// 键盘聚焦回答中的按钮时也保持入口可见。
  bool _focused = false;

  /// 时间和按钮共用轻量的操作行。
  @override
  Widget build(BuildContext context) {
    // 只解析真实消息时间，使用本机时区显示。
    final DateTime? createdAt = DateTime.tryParse(widget.createdAt ?? '')
        ?.toLocal();
    // 保存和错误反馈应保持可见，避免移出时用户无法核实状态。
    final bool visible =
        widget.alwaysVisible ||
        _hovered ||
        _focused ||
        widget.saving ||
        widget.error != null;
    return MouseRegion(
      key: ValueKey<String>('assistant-answer-row-${widget.messageId}'),
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
            ExcludeSemantics(
              excluding: !visible,
              child: IgnorePointer(
                ignoring: !visible,
                child: AnimatedOpacity(
                  key: ValueKey<String>(
                    'assistant-answer-actions-${widget.messageId}',
                  ),
                  opacity: visible ? 1 : 0,
                  duration: OmniMotion.duration(context, OmniMotion.fast),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: <Widget>[
                          if (widget.showSave)
                            OmniTextButton(
                              key: ValueKey<String>(
                                'assistant-save-note-${widget.messageId}',
                              ),
                              style: ButtonStyle(
                                padding:
                                    const WidgetStatePropertyAll<
                                      EdgeInsetsGeometry
                                    >(EdgeInsets.zero),
                                minimumSize: const WidgetStatePropertyAll<Size>(
                                  Size(0, 28),
                                ),
                                overlayColor:
                                    const WidgetStatePropertyAll<Color>(
                                      Colors.transparent,
                                    ),
                                backgroundColor:
                                    const WidgetStatePropertyAll<Color>(
                                      Colors.transparent,
                                    ),
                                foregroundColor:
                                    WidgetStateProperty.resolveWith<Color>(
                                      (states) =>
                                          states.contains(
                                                WidgetState.hovered,
                                              ) ||
                                              states.contains(
                                                WidgetState.focused,
                                              )
                                          ? widget.colors.ink
                                          : widget.colors.muted,
                                    ),
                                textStyle: WidgetStatePropertyAll<TextStyle?>(
                                  Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(fontSize: 12, height: 1.4),
                                ),
                              ),
                              onPressed: widget.saved || widget.saving
                                  ? null
                                  : widget.onSave,
                              child: Text(
                                widget.saved
                                    ? '已保存'
                                    : widget.saving
                                    ? '保存中…'
                                    : widget.error != null
                                    ? '重试保存'
                                    : '保存笔记',
                              ),
                            ),
                          if (createdAt != null)
                            Tooltip(
                              message: DateFormat('yyyy-MM-dd HH:mm:ss')
                                  .format(createdAt),
                              child: Text(
                                DateFormat('HH:mm').format(createdAt),
                                key: ValueKey<String>(
                                  'assistant-answer-date-${widget.messageId}',
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: widget.colors.muted,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (widget.error != null)
                        Text(
                          widget.error!,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
