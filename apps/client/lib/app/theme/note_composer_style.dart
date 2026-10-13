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

  /// 正文留白保持参考图的输入卡片高度。
  static const double bodyHeight = 160;

  /// 发布按钮比普通方形工具按钮更宽。
  static const Size actionSize = Size(48, 30);
}
