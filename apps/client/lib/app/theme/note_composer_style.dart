import 'package:flutter/material.dart';

/// 笔记输入卡片的中性灰色及局部尺寸，操作色由当前主题提供。
abstract final class NoteComposerStyle {
  /// 非聚焦时的浅灰边框。
  static const Color border = Color(0xFFEEEEEE);

  /// 浅色正文，避免继承输入框填充色。
  static const Color ink = Color(0xFF595959);

  /// 占位、字数和聚焦工具图标的灰色。
  static const Color muted = Color(0xFF999999);

  /// 非聚焦工具图标仍可操作，但视觉保持极浅灰。
  static const Color idleTool = Color(0xFFEFEFEF);

  /// 笔记高亮的固定浅黄色，与 Markdown codec 的颜色属性一致。
  static const Color highlight = Color(0xFFFFF59D);

  /// 高亮文字在明暗主题均使用深灰，确保浅黄背景上的可读性。
  static const Color highlightInk = Color(0xFF494949);

  /// Windows 新增卡片由 244dp 减半至 122dp，扣除 84dp 内边距与工具区。
  static const double bodyHeight = 38;

  /// 发布按钮比普通方形工具按钮更宽。
  static const Size actionSize = Size(48, 30);
}
