import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 直接展示原图，背景压暗由现有模态路由统一提供。
class AssistantImagePreview extends StatelessWidget {
  /// 已通过当前来源鉴权取得的图片，仅在预览期间持有。
  final Uint8List bytes;

  /// 创建无卡片、无标题栏的图片预览。
  const AssistantImagePreview({required this.bytes, super.key});

  /// 图片之外均可关闭；图片自身保留缩放拖动，关闭按钮固定在窗口右上角。
  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey<String>('assistant-image-preview-backdrop'),
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
          child: Center(
            child: GestureDetector(
              // 图片点击不透传给背景，只有真正的空白区域关闭。
              onTap: () {},
              child: InteractiveViewer(
                maxScale: 5,
                child: Image.memory(
                  bytes,
                  key: const ValueKey<String>('assistant-image-preview-image'),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Text('图片预览不可用'),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 16,
          right: 16,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 1,
            shape: CircleBorder(
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Semantics(
              label: '关闭图片',
              child: OmniTextButton(
                key: const ValueKey<String>('assistant-image-preview-close'),
                style: ButtonStyle(
                  minimumSize: const WidgetStatePropertyAll<Size>(
                    Size.square(36),
                  ),
                  maximumSize: const WidgetStatePropertyAll<Size>(
                    Size.square(36),
                  ),
                  fixedSize: const WidgetStatePropertyAll<Size>(
                    Size.square(36),
                  ),
                  padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                    EdgeInsets.zero,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.standard,
                  shape: const WidgetStatePropertyAll<OutlinedBorder>(
                    CircleBorder(),
                  ),
                  foregroundColor: WidgetStatePropertyAll<Color>(
                    Theme.of(context).colorScheme.onSurface,
                  ),
                  overlayColor: WidgetStateProperty.resolveWith<Color?>(
                    (states) =>
                        states.contains(WidgetState.hovered) ||
                            states.contains(WidgetState.focused) ||
                            states.contains(WidgetState.pressed)
                        ? Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: .10)
                        : Colors.transparent,
                  ),
                ),
                child: const Icon(Icons.close, size: 18),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
