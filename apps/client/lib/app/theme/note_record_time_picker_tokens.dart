import 'package:flutter/material.dart';

/// Windows记录时间浮层的用户视频规格，仅用于该入口，不改变全局配色。
abstract final class NoteRecordTimePickerTokens {
  /// 月历主面板宽度。
  static const double width = 324;

  /// 普通字号下的主面板高度。
  static const double height = 390;

  /// 年月导航区域高度。
  static const double headerHeight = 52;

  /// 星期区域高度。
  static const double weekdayHeight = 36;

  /// 每周日期行高度。
  static const double weekHeight = 38;

  /// 日期选中圆直径。
  static const double dayDiameter = 32;

  /// 底栏高度，时间浮层底部与此栏上沿对齐。
  static const double footerHeight = 60;

  /// 时分秒浮层宽度。
  static const double clockWidth = 180;

  /// 时间滚动区域高度。
  static const double clockListHeight = 192;

  /// 单个时间刻度高度。
  static const double clockRowHeight = 32;

  /// 参考视频中的主确认与日期选中色。
  static const Color green = Color(0xFF2DCE78);

  /// 时间子面板确认文字色。
  static const Color clockBlue = Color(0xFF409EFF);

  /// 浅色月历表面。
  static const Color surface = Color(0xFFFCFCFC);

  /// 浅色时间框与选中刻度背景。
  static const Color field = Color(0xFFEFEFEF);

  /// 浅色正文。
  static const Color ink = Color(0xFF303133);

  /// 浅色辅助文字。
  static const Color muted = Color(0xFF909399);

  /// 浅色不可选日期。
  static const Color disabled = Color(0xFFCCCCCC);

  /// 浅色边界。
  static const Color line = Color(0xFFE4E4E7);

  /// 时间输入聚焦边框。
  static const Color focusLine = Color(0xFFBFBFBF);
}
