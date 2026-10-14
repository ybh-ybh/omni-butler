import 'package:flutter/material.dart';

/// Windows提示浮层的锚点不能与相邻锚点合并，避免序列化孤立语义节点。
class OmniWindowsSemanticsBoundary extends StatelessWidget {
  /// 保留控件读屏与键盘操作，Android沿用原语义树。
  const OmniWindowsSemanticsBoundary({super.key, required this.child});

  /// 当前控件及其真实提示浮层。
  final Widget child;

  /// 每个Windows入口独立拥有语义孩子，不合并多个traversalParentIdentifier。
  @override
  Widget build(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.windows
      ? Semantics(container: true, explicitChildNodes: true, child: child)
      : child;
}
