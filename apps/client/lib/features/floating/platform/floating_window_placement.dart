import 'package:flutter/material.dart';

/// 将悬浮窗位置约束在显示器工作区范围内。
Offset clampFloatingPlacement({
  required Offset desiredPosition,
  required Size workAreaSize,
  required Size windowSize,
  double margin = 0,
}) {
  // 横向允许的最小位置。
  final double minimumX = margin.clamp(0, workAreaSize.width);
  // 纵向允许的最小位置。
  final double minimumY = margin.clamp(0, workAreaSize.height);
  // 横向允许的最大位置。
  final double maximumX = (workAreaSize.width - windowSize.width - margin)
      .clamp(minimumX, workAreaSize.width);
  // 纵向允许的最大位置。
  final double maximumY = (workAreaSize.height - windowSize.height - margin)
      .clamp(minimumY, workAreaSize.height);
  return Offset(
    desiredPosition.dx.clamp(minimumX, maximumX),
    desiredPosition.dy.clamp(minimumY, maximumY),
  );
}

/// 将靠近工作区边缘的悬浮窗吸附到对应边缘。
Offset snapFloatingPlacement({
  required Offset desiredPosition,
  required Size workAreaSize,
  required Size windowSize,
  double threshold = 24,
  double margin = 0,
}) {
  // 先约束到工作区内的安全位置。
  final Offset clampedPosition = clampFloatingPlacement(
    desiredPosition: desiredPosition,
    workAreaSize: workAreaSize,
    windowSize: windowSize,
    margin: margin,
  );
  // 横向允许的最小吸附位置。
  final double minimumX = margin.clamp(0, workAreaSize.width);
  // 纵向允许的最小吸附位置。
  final double minimumY = margin.clamp(0, workAreaSize.height);
  // 横向允许的最大吸附位置。
  final double maximumX = (workAreaSize.width - windowSize.width - margin)
      .clamp(minimumX, workAreaSize.width);
  // 纵向允许的最大吸附位置。
  final double maximumY = (workAreaSize.height - windowSize.height - margin)
      .clamp(minimumY, workAreaSize.height);
  // 非负吸附触发距离。
  final double safeThreshold = threshold.clamp(0, double.infinity);
  // 吸附后的横坐标。
  final double snappedX = switch ((
    (clampedPosition.dx - minimumX).abs() <= safeThreshold,
    (maximumX - clampedPosition.dx).abs() <= safeThreshold,
  )) {
    (true, _) => minimumX,
    (_, true) => maximumX,
    _ => clampedPosition.dx,
  };
  // 吸附后的纵坐标。
  final double snappedY = switch ((
    (clampedPosition.dy - minimumY).abs() <= safeThreshold,
    (maximumY - clampedPosition.dy).abs() <= safeThreshold,
  )) {
    (true, _) => minimumY,
    (_, true) => maximumY,
    _ => clampedPosition.dy,
  };
  return Offset(snappedX, snappedY);
}
