import 'package:flutter/material.dart';

/// 当前设备可选的主题配色；标识用于持久化，不随显示名称变化。
enum AppThemePalette {
  /// 保留原有品牌外观。
  classicBlue(
    'classic_blue',
    '经典蓝',
    Color(0xFF3370FF),
    Color(0xFF4C88FF),
    Color(0xFF3370FF),
  ),

  /// 中性灰白配色。
  cloud('cloud', '云雾', Color(0xFFECEDEE), Color(0xFF050505), Color(0xFF62666D)),

  /// 清淡青色配色。
  seaSalt(
    'sea_salt',
    '海盐',
    Color(0xFFE6F1F4),
    Color(0xFF2A333C),
    Color(0xFF35747E),
  ),

  /// 柔和浅蓝配色。
  sky('sky', '苍穹', Color(0xFFDCE6F7), Color(0xFF2E3242), Color(0xFF536FA8)),

  /// 沉静中蓝配色。
  distantMountain(
    'distant_mountain',
    '远山',
    Color(0xFF4872AD),
    Color(0xFF30435F),
    Color(0xFF4872AD),
  ),

  /// 低饱和蓝灰配色。
  slate('slate', '黛蓝', Color(0xFF54647D), Color(0xFF373E4C), Color(0xFF54647D));

  /// 创建固定的主题元数据。
  const AppThemePalette(
    this.id,
    this.label,
    this.lightPreviewColor,
    this.darkPreviewColor,
    this.seedColor,
  );

  /// 本机存储使用的稳定标识。
  final String id;

  /// 设置页显示名称。
  final String label;

  /// 浅色预览色；非经典主题也用于 Windows 标题栏与导航背景。
  final Color lightPreviewColor;

  /// 深色预览色；非经典主题也用于 Windows 标题栏与导航背景。
  final Color darkPreviewColor;

  /// 生成完整明暗配色的基准色。
  final Color seedColor;

  /// 解析当前明暗模式的预览色，同时供 Windows 窗口与导航使用。
  Color previewColorFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkPreviewColor : lightPreviewColor;

  /// 恢复已保存配色，兼容缺失和未知标识。
  static AppThemePalette fromId(String? id) => values.firstWhere(
    (AppThemePalette palette) => palette.id == id,
    orElse: () => classicBlue,
  );

  /// 使用 Material 色调生成可读的明暗色对，保留灰白与蓝灰的低饱和特点。
  ColorScheme colorScheme(Brightness brightness) {
    // 根据主题色调生成文字、操作色和分层表面。
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
      dynamicSchemeVariant: switch (this) {
        cloud || slate => DynamicSchemeVariant.neutral,
        distantMountain => DynamicSchemeVariant.vibrant,
        _ => DynamicSchemeVariant.tonalSpot,
      },
    );
    return brightness == Brightness.dark && this != classicBlue
        ? scheme.copyWith(primaryContainer: darkPreviewColor)
        : scheme;
  }
}
