import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 统一的状态标签。
class OmniTag extends StatelessWidget {
  /// 标签文字。
  final String label;

  /// 标签语义色。
  final Color? color;

  /// 可选前置图标。
  final IconData? icon;

  /// 是否使用适合移动端记录卡的小尺寸标签。
  final bool compact;

  /// 创建状态标签。
  const OmniTag({
    required this.label,
    this.color,
    this.icon,
    this.compact = false,
    super.key,
  });

  /// 构建浅色填充标签。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前标签强调色。
    final Color effectiveColor = color ?? colors.brand;

    return Container(
      constraints: BoxConstraints(minHeight: compact ? 18 : 24),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? OmniSpacing.xxs : OmniSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(
          compact ? OmniRadius.tiny : OmniRadius.control,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: compact ? 11 : 13, color: effectiveColor),
            const SizedBox(width: OmniSpacing.xxs),
          ],
          Text(
            label,
            style: TextStyle(
              color: effectiveColor,
              fontSize: compact ? 11 : 12,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
