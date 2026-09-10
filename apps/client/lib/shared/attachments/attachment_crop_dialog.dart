import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 通用图片裁剪弹窗。
///
/// 允许用户在原图上框选一个矩形区域，返回裁剪后的本地文件路径。
/// 当 [aspectRatio] 为 null 时，裁剪框可自由调整比例；
/// 否则裁剪框会锁定为指定宽高比。
class AttachmentCropDialog extends StatefulWidget {
  /// 原图文件路径。
  final String sourcePath;

  /// 裁剪框锁定宽高比（宽 / 高）。
  final double? aspectRatio;

  /// 弹窗标题。
  final String title;

  /// 创建图片裁剪弹窗。
  const AttachmentCropDialog({
    required this.sourcePath,
    required this.title,
    this.aspectRatio,
    super.key,
  });

  /// 显示图片裁剪弹窗，返回裁剪后的文件路径。
  static Future<String?> show(
    BuildContext context, {
    required String sourcePath,
    required String title,
    double? aspectRatio,
  }) {
    return showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AttachmentCropDialog(
        sourcePath: sourcePath,
        title: title,
        aspectRatio: aspectRatio,
      ),
    );
  }

  @override
  State<AttachmentCropDialog> createState() => _AttachmentCropDialogState();
}

class _AttachmentCropDialogState extends State<AttachmentCropDialog> {
  /// 原图尺寸。
  img.Image? _sourceImage;

  /// 加载错误信息。
  String? _error;

  /// 当前图片在弹窗中的显示区域。
  Rect _imageRect = Rect.zero;

  /// 当前裁剪框（基于弹窗坐标）。
  Rect _cropRect = Rect.zero;

  /// 当前交互模式。
  _CropMode _mode = _CropMode.idle;

  /// 交互开始时的裁剪框。
  Rect _startCropRect = Rect.zero;

  /// 交互开始时的指针位置。
  Offset _startPosition = Offset.zero;

  /// 最小裁剪尺寸。
  static const double _minCropSize = 48;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  /// 读取并解码原图。
  Future<void> _loadImage() async {
    try {
      final File file = File(widget.sourcePath);
      final Uint8List bytes = await file.readAsBytes();
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) {
        setState(() => _error = '图片解码失败');
        return;
      }
      setState(() => _sourceImage = decoded);
    } on Exception catch (e) {
      setState(() => _error = '读取图片失败：$e');
    }
  }

  /// 根据图片显示区域初始化裁剪框。
  void _initCropRect() {
    if (_sourceImage == null) return;
    final Size imageSize = Size(
      _sourceImage!.width.toDouble(),
      _sourceImage!.height.toDouble(),
    );
    final Rect imageRect = _calculateImageRect(imageSize, _imageRect.size);
    _imageRect = imageRect;

    // 默认裁剪框占图片区域的 80%，并按比例约束。
    double cropWidth = imageRect.width * 0.8;
    double cropHeight = imageRect.height * 0.8;
    final double? ratio = widget.aspectRatio;
    if (ratio != null) {
      final double targetHeight = cropWidth / ratio;
      if (targetHeight > imageRect.height * 0.8) {
        cropHeight = imageRect.height * 0.8;
        cropWidth = cropHeight * ratio;
      } else {
        cropHeight = targetHeight;
      }
    }
    _cropRect = Rect.fromCenter(
      center: imageRect.center,
      width: cropWidth,
      height: cropHeight,
    );
    _constrainCropRect();
  }

  /// 计算图片按 contain 规则在容器中的显示区域。
  Rect _calculateImageRect(Size imageSize, Size containerSize) {
    final double scale = math.min(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height,
    );
    final double displayWidth = imageSize.width * scale;
    final double displayHeight = imageSize.height * scale;
    final double left = (containerSize.width - displayWidth) / 2;
    final double top = (containerSize.height - displayHeight) / 2;
    return Rect.fromLTWH(left, top, displayWidth, displayHeight);
  }

  /// 确保裁剪框不超出图片显示区域。
  void _constrainCropRect() {
    if (_cropRect.isEmpty) return;

    double width = _cropRect.width;
    double height = _cropRect.height;
    final double? ratio = widget.aspectRatio;

    // 先约束最小尺寸。
    if (width < _minCropSize) {
      width = _minCropSize;
      if (ratio != null) {
        height = width / ratio;
      }
    }
    if (height < _minCropSize) {
      height = _minCropSize;
      if (ratio != null) {
        width = height * ratio;
      }
    }

    // 再约束不超出图片区域。
    if (width > _imageRect.width) {
      width = _imageRect.width;
      if (ratio != null) {
        height = width / ratio;
      }
    }
    if (height > _imageRect.height) {
      height = _imageRect.height;
      if (ratio != null) {
        width = height * ratio;
      }
    }

    double left = _cropRect.left;
    double top = _cropRect.top;

    if (left < _imageRect.left) {
      left = _imageRect.left;
    }
    if (top < _imageRect.top) {
      top = _imageRect.top;
    }
    if (left + width > _imageRect.right) {
      left = _imageRect.right - width;
    }
    if (top + height > _imageRect.bottom) {
      top = _imageRect.bottom - height;
    }

    _cropRect = Rect.fromLTWH(left, top, width, height);
  }

  /// 执行裁剪并返回新文件路径。
  Future<String?> _crop() async {
    final img.Image? source = _sourceImage;
    if (source == null || _imageRect.isEmpty || _cropRect.isEmpty) {
      return null;
    }

    try {
      final double scale = source.width / _imageRect.width;
      final int x = (_cropRect.left - _imageRect.left).round();
      final int y = (_cropRect.top - _imageRect.top).round();
      final int width = _cropRect.width.round();
      final int height = _cropRect.height.round();

      final int srcX = math.max(0, (x * scale).round());
      final int srcY = math.max(0, (y * scale).round());
      final int srcWidth = math.min(source.width - srcX, (width * scale).round());
      final int srcHeight = math.min(
        source.height - srcY,
        (height * scale).round(),
      );

      final img.Image cropped = img.copyCrop(
        source,
        x: srcX,
        y: srcY,
        width: srcWidth,
        height: srcHeight,
      );

      final Directory tempDir = Directory.systemTemp;
      final String extension = _extensionFor(widget.sourcePath);
      final String targetPath =
          '${tempDir.path}${Platform.pathSeparator}omni_butler_crop_${DateTime.now().millisecondsSinceEpoch}$extension';
      final File target = File(targetPath);
      final Uint8List encoded = _encode(cropped, extension);
      await target.writeAsBytes(encoded);
      return target.path;
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('裁剪失败：$e')));
      }
      return null;
    }
  }

  /// 根据扩展名编码图片。
  Uint8List _encode(img.Image image, String extension) {
    switch (extension.toLowerCase()) {
      case '.png':
        return Uint8List.fromList(img.encodePng(image));
      case '.webp':
        return Uint8List.fromList(img.encodeWebP(image));
      case '.jpg':
      case '.jpeg':
      default:
        return Uint8List.fromList(img.encodeJpg(image, quality: 92));
    }
  }

  /// 返回文件扩展名。
  String _extensionFor(String filePath) {
    final int lastDot = filePath.lastIndexOf('.');
    if (lastDot == -1) return '.jpg';
    return filePath.substring(lastDot);
  }

  /// 根据指针位置判断拖拽区域。
  _CropRegion _regionAt(Offset position) {
    final Rect rect = _cropRect;
    final double handleSize = 16;
    final Rect left = Rect.fromLTWH(
      rect.left - handleSize / 2,
      rect.top + handleSize,
      handleSize,
      rect.height - handleSize * 2,
    );
    final Rect right = Rect.fromLTWH(
      rect.right - handleSize / 2,
      rect.top + handleSize,
      handleSize,
      rect.height - handleSize * 2,
    );
    final Rect top = Rect.fromLTWH(
      rect.left + handleSize,
      rect.top - handleSize / 2,
      rect.width - handleSize * 2,
      handleSize,
    );
    final Rect bottom = Rect.fromLTWH(
      rect.left + handleSize,
      rect.bottom - handleSize / 2,
      rect.width - handleSize * 2,
      handleSize,
    );

    if (left.contains(position)) return _CropRegion.left;
    if (right.contains(position)) return _CropRegion.right;
    if (top.contains(position)) return _CropRegion.top;
    if (bottom.contains(position)) return _CropRegion.bottom;
    if (rect.contains(position)) return _CropRegion.move;
    return _CropRegion.none;
  }

  /// 将交互区域转换为交互模式。
  _CropMode _modeFromRegion(_CropRegion region) => switch (region) {
    _CropRegion.none => _CropMode.idle,
    _CropRegion.move => _CropMode.move,
    _CropRegion.left => _CropMode.left,
    _CropRegion.right => _CropMode.right,
    _CropRegion.top => _CropMode.top,
    _CropRegion.bottom => _CropMode.bottom,
  };

  /// 处理指针按下。
  void _onPointerDown(PointerDownEvent event) {
    final _CropRegion region = _regionAt(event.localPosition);
    if (region == _CropRegion.none) return;
    setState(() {
      _mode = _modeFromRegion(region);
      _startCropRect = _cropRect;
      _startPosition = event.localPosition;
    });
  }

  /// 处理指针移动。
  void _onPointerMove(PointerMoveEvent event) {
    if (_mode == _CropMode.idle) return;

    final Offset delta = event.localPosition - _startPosition;
    final Rect start = _startCropRect;
    final double? ratio = widget.aspectRatio;

    setState(() {
      switch (_mode) {
        case _CropMode.idle:
          break;
        case _CropMode.move:
          _cropRect = start.translate(delta.dx, delta.dy);
        case _CropMode.left:
          _cropRect = _resizeLeft(start, delta, ratio);
        case _CropMode.right:
          _cropRect = _resizeRight(start, delta, ratio);
        case _CropMode.top:
          _cropRect = _resizeTop(start, delta, ratio);
        case _CropMode.bottom:
          _cropRect = _resizeBottom(start, delta, ratio);
      }
      _constrainCropRect();
    });
  }

  /// 处理指针抬起。
  void _onPointerUp(PointerUpEvent event) {
    setState(() => _mode = _CropMode.idle);
  }

  /// 左侧缩放。
  Rect _resizeLeft(Rect start, Offset delta, double? ratio) {
    double newLeft = start.left + delta.dx;
    double newWidth = start.right - newLeft;
    double newHeight = start.height;
    double newTop = start.top;

    if (ratio != null) {
      newHeight = newWidth / ratio;
      newTop = start.top + (start.height - newHeight) / 2;
    }

    return Rect.fromLTWH(newLeft, newTop, newWidth, newHeight);
  }

  /// 右侧缩放。
  Rect _resizeRight(Rect start, Offset delta, double? ratio) {
    double newWidth = start.width + delta.dx;
    double newHeight = start.height;
    double newTop = start.top;

    if (ratio != null) {
      newHeight = newWidth / ratio;
      newTop = start.top + (start.height - newHeight) / 2;
    }

    return Rect.fromLTWH(start.left, newTop, newWidth, newHeight);
  }

  /// 顶部缩放。
  Rect _resizeTop(Rect start, Offset delta, double? ratio) {
    double newTop = start.top + delta.dy;
    double newHeight = start.bottom - newTop;
    double newWidth = start.width;
    double newLeft = start.left;

    if (ratio != null) {
      newWidth = newHeight * ratio;
      newLeft = start.left + (start.width - newWidth) / 2;
    }

    return Rect.fromLTWH(newLeft, newTop, newWidth, newHeight);
  }

  /// 底部缩放。
  Rect _resizeBottom(Rect start, Offset delta, double? ratio) {
    double newHeight = start.height + delta.dy;
    double newWidth = start.width;
    double newLeft = start.left;

    if (ratio != null) {
      newWidth = newHeight * ratio;
      newLeft = start.left + (start.width - newWidth) / 2;
    }

    return Rect.fromLTWH(newLeft, start.top, newWidth, newHeight);
  }

  @override
  Widget build(BuildContext context) {
    return OmniDialogScaffold(
      title: widget.title,
      width: 760,
      height: 620,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!))
                : _sourceImage == null
                    ? const Center(child: CircularProgressIndicator())
                    : LayoutBuilder(
                        builder: (
                          BuildContext context,
                          BoxConstraints constraints,
                        ) {
                          // 仅在尺寸变化时重新初始化裁剪框。
                          final Rect newRect = _calculateImageRect(
                            Size(
                              _sourceImage!.width.toDouble(),
                              _sourceImage!.height.toDouble(),
                            ),
                            Size(constraints.maxWidth, constraints.maxHeight),
                          );
                          if (_imageRect != newRect) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                setState(() {
                                  _imageRect = newRect;
                                  if (_cropRect.isEmpty) {
                                    _initCropRect();
                                  }
                                });
                              }
                            });
                          }

                          return Listener(
                            onPointerDown: _onPointerDown,
                            onPointerMove: _onPointerMove,
                            onPointerUp: _onPointerUp,
                            child: MouseRegion(
                              cursor: _mode == _CropMode.move
                                  ? SystemMouseCursors.grabbing
                                  : SystemMouseCursors.basic,
                              child: Stack(
                                children: <Widget>[
                                  // 原图显示。
                                  Positioned.fromRect(
                                    rect: _imageRect,
                                    child: Image.file(
                                      File(widget.sourcePath),
                                      fit: BoxFit.fill,
                                    ),
                                  ),
                                  // 遮罩层。
                                  CustomPaint(
                                    size: Size(
                                      constraints.maxWidth,
                                      constraints.maxHeight,
                                    ),
                                    painter: _CropMaskPainter(
                                      imageRect: _imageRect,
                                      cropRect: _cropRect,
                                    ),
                                  ),
                                  // 裁剪框边框与手柄。
                                  if (!_cropRect.isEmpty)
                                    Positioned.fromRect(
                                      rect: _cropRect,
                                      child: const _CropFrame(),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
          const SizedBox(height: OmniSpacing.md),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: OmniSpacing.xs,
            runSpacing: OmniSpacing.xs,
            children: <Widget>[
              OmniButton(
                label: '取消',
                variant: OmniButtonVariant.secondary,
                onPressed: () => Navigator.of(context).pop(),
              ),
              OmniButton(
                label: '确认裁剪',
                icon: Icons.crop_rounded,
                onPressed: () async {
                  final String? croppedPath = await _crop();
                  if (!mounted) return;
                  Navigator.of(this.context).pop(croppedPath);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 裁剪交互区域。
enum _CropRegion {
  none,
  move,
  left,
  right,
  top,
  bottom,
}

/// 裁剪交互模式。
enum _CropMode {
  idle,
  move,
  left,
  right,
  top,
  bottom,
}

/// 裁剪框视觉。
class _CropFrame extends StatelessWidget {
  const _CropFrame();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Stack(
        children: <Widget>[
          // 三分线。
          CustomPaint(
            size: Size.infinite,
            painter: _RuleOfThirdsPainter(),
          ),
          // 手柄。
          Positioned(
            left: -6,
            top: -6,
            child: _Handle(cursor: SystemMouseCursors.resizeUpLeftDownRight),
          ),
          Positioned(
            right: -6,
            top: -6,
            child: _Handle(cursor: SystemMouseCursors.resizeUpRightDownLeft),
          ),
          Positioned(
            left: -6,
            bottom: -6,
            child: _Handle(cursor: SystemMouseCursors.resizeUpRightDownLeft),
          ),
          Positioned(
            right: -6,
            bottom: -6,
            child: _Handle(cursor: SystemMouseCursors.resizeUpLeftDownRight),
          ),
        ],
      ),
    );
  }
}

/// 裁剪手柄。
class _Handle extends StatelessWidget {
  final MouseCursor cursor;

  const _Handle({required this.cursor});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: cursor,
      child: Container(
        width: 12,
        height: 12,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// 三分线绘制。
class _RuleOfThirdsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    final double x1 = size.width / 3;
    final double x2 = size.width * 2 / 3;
    final double y1 = size.height / 3;
    final double y2 = size.height * 2 / 3;

    canvas
      ..drawLine(Offset(x1, 0), Offset(x1, size.height), paint)
      ..drawLine(Offset(x2, 0), Offset(x2, size.height), paint)
      ..drawLine(Offset(0, y1), Offset(size.width, y1), paint)
      ..drawLine(Offset(0, y2), Offset(size.width, y2), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 遮罩层绘制。
class _CropMaskPainter extends CustomPainter {
  final Rect imageRect;
  final Rect cropRect;

  const _CropMaskPainter({
    required this.imageRect,
    required this.cropRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6);

    final Path screenPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final Path cropPath = Path()..addRect(cropRect);

    canvas.drawPath(
      Path.combine(PathOperation.difference, screenPath, cropPath),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CropMaskPainter oldDelegate) =>
      oldDelegate.imageRect != imageRect ||
      oldDelegate.cropRect != cropRect;
}
