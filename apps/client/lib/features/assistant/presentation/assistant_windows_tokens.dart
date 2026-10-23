import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';

/// Windows 助手参考布局的局部尺寸，不改变其他业务页面。
abstract final class AssistantWindowsMetrics {
  /// 历史侧栏宽度。
  static const double sidebarWidth = 280;

  /// 可读聊天列的最大宽度。
  static const double contentWidth = 880;

  /// 宽窗口内容距右边缘的留白。
  static const double contentInset = 72;

  /// 窄窗口边缘留白。
  static const double compactInset = 20;

  /// 自动折叠历史侧栏的窗口宽度。
  static const double collapseWidth = 900;

  /// 顶部会话标题高度。
  static const double headerHeight = 56;

  /// 常规历史行的最小高度。
  static const double historyHeight = 38;

  /// 历史行与菜单选项圆角。
  static const double rowRadius = 12;

  /// 用户消息气泡圆角。
  static const double bubbleRadius = 22;

  /// 输入与搜索面板圆角。
  static const double panelRadius = 28;

  /// 模型面板圆角。
  static const double modelRadius = 22;

  /// 输入区的最小视觉高度。
  static const double composerHeight = 118;

  /// 常规发送按钮尺寸。
  static const double sendSize = 36;

  /// 搜索面板宽度。
  static const double searchWidth = 650;

  /// 搜索面板最大高度。
  static const double searchHeight = 610;

  /// 模型列表宽度。
  static const double modelWidth = 310;

  /// 搜索输入去抖间隔。
  static const Duration searchDebounce = Duration(milliseconds: 250);
}

/// 助手使用中性表面，深色继续继承当前应用主题。
class AssistantWindowsPalette {
  /// 聊天主背景。
  final Color canvas;

  /// 历史侧栏背景。
  final Color sidebar;

  /// 消息与选中行底色。
  final Color soft;

  /// 主要文字。
  final Color ink;

  /// 次级说明。
  final Color muted;

  /// 轻边界。
  final Color line;

  /// 创建一组助手颜色。
  const AssistantWindowsPalette({
    required this.canvas,
    required this.sidebar,
    required this.soft,
    required this.ink,
    required this.muted,
    required this.line,
  });

  /// 根据明暗模式解析中性工作区颜色。
  factory AssistantWindowsPalette.of(BuildContext context) {
    // 深色模式沿用主题语义色，避免白色硬块。
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // 当前应用主题颜色。
    final OmniColors colors = OmniColors.of(context);
    // 浅色参考图以接近白色的中性面为基底。
    final Color canvas = dark ? colors.canvas : Colors.grey.shade50;
    return AssistantWindowsPalette(
      canvas: canvas,
      sidebar: dark ? colors.paper : Colors.grey.shade100,
      soft: Color.alphaBlend(
        (dark ? Colors.white : Colors.black).withValues(
          alpha: dark ? .06 : .04,
        ),
        canvas,
      ),
      ink: dark ? colors.ink : Colors.grey.shade800,
      muted: dark ? colors.muted : Colors.grey.shade500,
      line: (dark ? Colors.white : Colors.black).withValues(alpha: .07),
    );
  }
}
