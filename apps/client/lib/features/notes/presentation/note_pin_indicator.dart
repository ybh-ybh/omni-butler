import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';

/// 两端笔记时间左侧共用的主题色置顶标记。
class NotePinIndicator extends StatelessWidget {
  /// 正式笔记身份，标记随笔记移动而不随列表位置变化。
  final String noteId;

  /// 与两端原有时间字号协调的图标尺寸。
  final double size;

  /// 创建仅用于已置顶笔记的静态标记。
  const NotePinIndicator({required this.noteId, this.size = 14, super.key});

  /// 沿用当前主题品牌色，不改变时间文字的灰色样式。
  @override
  Widget build(BuildContext context) => Icon(
    Icons.push_pin,
    key: ValueKey<String>('note-pin-$noteId'),
    size: size,
    color: OmniColors.of(context).brand,
    semanticLabel: '已置顶',
  );
}
