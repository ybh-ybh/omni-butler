import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 顶部浮动消息的语义类型。
enum OmniMessageTone {
  /// 普通信息。
  info,

  /// 成功反馈。
  success,

  /// 需要注意的反馈。
  warning,

  /// 错误反馈。
  error,
}

/// 可主动关闭的浮动消息句柄。
class OmniMessageHandle {
  /// 当前浮层条目。
  OverlayEntry? _entry;

  /// 自动关闭计时器。
  Timer? _timer;

  /// 关闭后的可选回调。
  VoidCallback? _onDismissed;

  /// 创建浮动消息句柄。
  OmniMessageHandle._();

  /// 当前消息是否仍在显示。
  bool get isVisible => _entry?.mounted ?? false;

  /// 关闭当前消息。
  void dismiss() {
    _timer?.cancel();
    _timer = null;
    // 当前待移除条目。
    final OverlayEntry? entry = _entry;
    _entry = null;
    if (entry?.mounted ?? false) {
      entry!.remove();
    }
    if (identical(_activeOmniMessage, this)) {
      _activeOmniMessage = null;
    }
    // 当前关闭回调只执行一次。
    final VoidCallback? callback = _onDismissed;
    _onDismissed = null;
    callback?.call();
  }
}

/// 当前窗口正在展示的唯一浮动消息。
OmniMessageHandle? _activeOmniMessage;

/// 在窗口根浮层顶部显示统一操作消息。
OmniMessageHandle showOmniMessage(
  BuildContext context, {
  required String message,
  OmniMessageTone tone = OmniMessageTone.info,
  Duration duration = const Duration(seconds: 4),
  String? actionLabel,
  VoidCallback? onAction,
  VoidCallback? onDismissed,
}) {
  _activeOmniMessage?.dismiss();
  // 当前消息句柄。
  final OmniMessageHandle handle = OmniMessageHandle._();
  // 当前窗口根浮层。
  final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) {
    return handle;
  }
  handle._onDismissed = onDismissed;
  // 当前浮层条目。
  final OverlayEntry entry = OverlayEntry(
    builder: (BuildContext overlayContext) => Positioned(
      key: const ValueKey<String>('omni-message-positioned'),
      top: OmniSpacing.md,
      left: OmniSpacing.md,
      right: OmniSpacing.md,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _OmniMessagePopup(
              message: message,
              tone: tone,
              actionLabel: actionLabel,
              onAction: onAction == null
                  ? null
                  : () {
                      handle.dismiss();
                      onAction();
                    },
              onDismiss: handle.dismiss,
            ),
          ),
        ),
      ),
    ),
  );
  handle._entry = entry;
  entry.addListener(() {
    if (!entry.mounted && identical(handle._entry, entry)) {
      handle.dismiss();
    }
  });
  _activeOmniMessage = handle;
  overlay.insert(entry);
  handle._timer = Timer(duration, handle.dismiss);
  return handle;
}

/// 顶部浮动消息内容。
class _OmniMessagePopup extends StatelessWidget {
  /// 消息正文。
  final String message;

  /// 消息语义类型。
  final OmniMessageTone tone;

  /// 可选操作文案。
  final String? actionLabel;

  /// 可选操作回调。
  final VoidCallback? onAction;

  /// 关闭回调。
  final VoidCallback onDismiss;

  /// 创建浮动消息内容。
  const _OmniMessagePopup({
    required this.message,
    required this.tone,
    required this.actionLabel,
    required this.onAction,
    required this.onDismiss,
  });

  /// 构建带语义色、阴影和进入动效的浮动消息。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前消息强调色。
    final Color accent = switch (tone) {
      OmniMessageTone.info => colors.info,
      OmniMessageTone.success => colors.success,
      OmniMessageTone.warning => colors.warning,
      OmniMessageTone.error => colors.danger,
    };
    // 当前消息图标。
    final IconData icon = switch (tone) {
      OmniMessageTone.info => Icons.info_rounded,
      OmniMessageTone.success => Icons.check_circle_rounded,
      OmniMessageTone.warning => Icons.warning_amber_rounded,
      OmniMessageTone.error => Icons.error_rounded,
    };
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: OmniMotion.fast,
      curve: OmniMotion.standardCurve,
      builder: (BuildContext context, double value, Widget? child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, -8 * (1 - value)),
          child: child,
        ),
      ),
      child: Semantics(
        liveRegion: true,
        child: Material(
          key: const ValueKey<String>('omni-message-popup'),
          color: colors.paper,
          elevation: 10,
          shadowColor: colors.ink.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(OmniRadius.control),
          clipBehavior: Clip.antiAlias,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.only(left: OmniSpacing.md),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.1),
              border: Border.all(color: accent.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(OmniRadius.control),
            ),
            child: Row(
              children: <Widget>[
                Icon(icon, color: accent, size: 18),
                const SizedBox(width: OmniSpacing.xs),
                Expanded(
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (actionLabel != null && onAction != null)
                  TextButton(onPressed: onAction, child: Text(actionLabel!)),
                IconButton(
                  tooltip: '关闭提示',
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
