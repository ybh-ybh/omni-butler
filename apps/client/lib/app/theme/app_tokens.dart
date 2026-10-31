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
  static const double tiny = 4;

  /// 按钮、输入框与标签圆角。
  static const double control = 8;

  /// 卡片与菜单圆角。
  static const double panel = 12;

  /// 模态框与侧边面板圆角。
  static const double dialog = 16;

  /// 胶囊标签圆角。
  static const double pill = 999;
}

/// Omni Butler 的统一尺寸 Token。
abstract final class OmniSize {
  /// 列表操作紧凑按钮的视觉高度，触控热区单独保留。
  static const double controlCompact = 28;

  /// 桌面紧凑控件高度。
  static const double control = 32;

  /// 桌面页面主操作高度。
  static const double pageAction = 36;

  /// Windows普通图标按钮统一为36dp方形，字形与背景分别居中。
  static const double iconButton = 36;

  /// 桌面大控件高度。
  static const double controlLarge = 40;

  /// 移动端最小触控高度。
  static const double touch = 48;

  /// 开关的完整点击宽度。
  static const double switchTapWidth = 52;

  /// 开关轨道宽度。
  static const double switchTrackWidth = 46;

  /// 开关轨道高度。
  static const double switchTrackHeight = 28;

  /// 开关滑块直径。
  static const double switchThumb = 22;

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

/// Omni Butler 的统一操作菜单尺寸和材质 Token。
abstract final class OmniMenuMetrics {
  /// 标准操作菜单的最小宽度。
  static const double minWidth = 160;

  /// 标准操作菜单的最大宽度。
  static const double maxWidth = 280;

  /// 标准操作行的最小高度。
  static const double itemHeight = 36;

  /// 操作菜单图标尺寸。
  static const double iconSize = 16;

  /// 操作菜单文字尺寸。
  static const double fontSize = 14;

  /// 操作菜单的轻阴影层级。
  static const double elevation = 6;

  /// 操作菜单阴影透明度。
  static const double shadowOpacity = 0.12;

  /// 危险菜单行的浅红悬停透明度。
  static const double dangerHoverOpacity = 0.10;
}

/// Omni Butler 的统一动效 Token。
abstract final class OmniMotion {
  /// Observe only reduced motion so keyboard metrics do not rebuild consumers.
  static bool reduce(BuildContext context) {
    return MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  /// 在减少动画模式下保留即时状态反馈，停止位移过渡。
  static Duration duration(BuildContext context, Duration duration) {
    return reduce(context) ? Duration.zero : duration;
  }

  /// 即时状态反馈时长。
  static const Duration fast = Duration(milliseconds: 120);

  /// 常规状态切换时长。
  static const Duration normal = Duration(milliseconds: 180);

  /// 安卓模态弹窗完整滑入屏幕的时长。
  static const Duration androidModalEnter = Duration(milliseconds: 300);

  /// 安卓模态弹窗沿底部滑出屏幕的时长。
  static const Duration androidModalExit = Duration(milliseconds: 220);

  /// 进退共用同一位置曲线，反向播放自然加速且中途关闭不跳帧。
  static const Curve androidModalCurve = Curves.easeOutCubic;

  /// 安卓弹窗共用的原生面板参数，显式覆盖及系统禁用动画优先。
  static AnimationStyle androidModalStyle(
    BuildContext context, {
    AnimationStyle? override,
  }) => reduce(context)
      ? AnimationStyle.noAnimation
      : AnimationStyle(
          duration: override?.duration ?? androidModalEnter,
          reverseDuration: override?.reverseDuration ?? androidModalExit,
          curve: override?.curve ?? androidModalCurve,
          reverseCurve: override?.reverseCurve ?? androidModalCurve,
        );

  /// 安卓条目按下时，从触点扩散至全部轮廓的时长。
  static const Duration pressSpread = Duration(milliseconds: 280);

  /// 安卓条目按下时的轻微缩放比例。
  static const double pressScale = 0.98;

  /// Windows按下时仅压缩内容的比例。
  static const double windowsPressScale = 0.97;

  /// Windows内容按下至压缩尺寸的时长。
  static const Duration windowsPressDown = Duration(milliseconds: 90);

  /// Windows松开或取消后内容恢复的时长。
  static const Duration windowsPressRelease = Duration(milliseconds: 160);

  /// Windows操作菜单整体淡入与缩放的时长。
  static const Duration windowsMenuEnter = Duration(milliseconds: 150);

  /// Windows操作菜单整体淡出与缩放的时长。
  static const Duration windowsMenuExit = Duration(milliseconds: 120);

  /// Windows操作菜单打开和关闭时的最小视觉比例。
  static const double windowsMenuScale = 0.96;

  /// Windows菜单行悬停与焦点底色切换时长。
  static const Duration windowsMenuHover = Duration(milliseconds: 100);

  /// 面板进入与退出时长。
  static const Duration panel = Duration(milliseconds: 220);

  /// 开关滑块移动时长。
  static const Duration switchThumb = Duration(milliseconds: 180);

  /// Windows 整窗主题从右上向左下渐变的时长。
  static const Duration themeChange = Duration(milliseconds: 480);

  /// 常规缓动曲线。
  static const Curve standardCurve = Curves.easeOutCubic;
}

/// 以输入平台决定控件密度，避免窄桌面窗口变成触控控件。
abstract final class OmniDensity {
  /// 当前平台是否默认使用触控热区。
  static bool isTouch(BuildContext context) {
    return !OmniBreakpoint.isDesktopPlatform(Theme.of(context).platform);
  }

  /// 按平台与强调层级返回控件最小高度。
  static double controlHeight(BuildContext context, {bool large = false}) {
    if (isTouch(context)) return OmniSize.touch;
    return large ? OmniSize.controlLarge : OmniSize.control;
  }
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
