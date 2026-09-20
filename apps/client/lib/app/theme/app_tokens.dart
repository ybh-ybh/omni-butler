import 'package:flutter/material.dart';

/// Omni Butler 的统一间距 Token。
abstract final class OmniSpacing {
  /// 最小间距。
  static const double xxs = 4;

  /// 紧凑间距。
  static const double xs = 8;

  /// 控件内部间距。
  static const double sm = 12;

  /// 标准内容间距。
  static const double md = 16;

  /// 区块间距。
  static const double lg = 20;

  /// 页面间距。
  static const double xl = 24;

  /// 大区块间距。
  static const double xxl = 32;
}

/// Omni Butler 的统一圆角 Token。
abstract final class OmniRadius {
  /// 复选框等微型控件圆角。
  static const double tiny = 3;

  /// 按钮、输入框与标签圆角。
  static const double control = 6;

  /// 卡片与菜单圆角。
  static const double panel = 8;

  /// 模态框与侧边面板圆角。
  static const double dialog = 12;

  /// 胶囊标签圆角。
  static const double pill = 999;
}

/// Omni Butler 的统一尺寸 Token。
abstract final class OmniSize {
  /// 桌面紧凑控件高度。
  static const double control = 32;

  /// 桌面页面主操作高度。
  static const double pageAction = 36;

  /// 桌面大控件高度。
  static const double controlLarge = 40;

  /// 移动端最小触控高度。
  static const double touch = 44;

  /// 开关视觉相对原生控件的缩放比例。
  static const double switchVisualScale = 0.76;

  /// 立体开关的完整点击宽度。
  static const double switchTapWidth = 60;

  /// 立体开关轨道宽度。
  static const double switchTrackWidth = 56;

  /// 立体开关轨道高度。
  static const double switchTrackHeight = 28;

  /// 立体开关滑块直径。
  static const double switchThumb = 20;

  /// 立体开关状态环直径。
  static const double switchIndicator = 12;

  /// 立体开关状态环与左右边缘的额外间距。
  static const double switchIndicatorInset = 4;

  /// 桌面顶栏高度。
  static const double topBar = 48;

  /// 展开侧栏宽度。
  static const double sidebar = 192;

  /// 中等布局导航宽度。
  static const double navigationRail = 58;

  /// 桌面编辑面板宽度。
  static const double sideSheet = 520;

  /// 标准图标尺寸。
  static const double icon = 18;

  /// 导航图标尺寸。
  static const double navigationIcon = 20;
}

/// Omni Butler 的统一动效 Token。
abstract final class OmniMotion {
  /// 即时状态反馈时长。
  static const Duration fast = Duration(milliseconds: 120);

  /// 常规状态切换时长。
  static const Duration normal = Duration(milliseconds: 180);

  /// 面板进入与退出时长。
  static const Duration panel = Duration(milliseconds: 220);

  /// 立体开关滑块移动时长，在参考 CSS 基础上加快 30%。
  static const Duration switchThumb = Duration(milliseconds: 210);

  /// 立体开关状态环动画时长，在参考 CSS 基础上加快 30%。
  static const Duration switchIndicator = Duration(milliseconds: 700);

  /// 常规缓动曲线。
  static const Curve standardCurve = Curves.easeOutCubic;
}

/// Omni Butler 的统一响应式断点。
abstract final class OmniBreakpoint {
  /// 紧凑布局上限。
  static const double compact = 720;

  /// 展开布局起点。
  static const double expanded = 1200;

  /// 判断当前宽度是否为紧凑布局。
  static bool isCompact(double width) => width < compact;

  /// 判断当前宽度是否为展开布局。
  static bool isExpanded(double width) => width >= expanded;

  /// 判断当前是否运行在桌面端平台。
  static bool isDesktopPlatform(TargetPlatform platform) {
    return switch (platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };
  }
}
