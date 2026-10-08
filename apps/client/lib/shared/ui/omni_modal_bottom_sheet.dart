import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';

/// 打开遵循主题、安全区及减少动画偏好的底部面板。
Future<T?> showOmniModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: OmniColors.of(context).paper,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(
      top: Radius.circular(OmniRadius.dialog),
    ),
  ),
  clipBehavior: Clip.antiAlias,
  sheetAnimationStyle: OmniMotion.reduce(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(duration: OmniMotion.panel),
  builder: builder,
);
