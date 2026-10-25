import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:win32/win32.dart';

/// Windows 图片剪贴板只读适配，不清空或改写系统剪贴板。
class WindowsClipboardImages {
  /// 优先读取剪贴板注册的 PNG 格式。
  int get _png => using(
    (Arena arena) =>
        RegisterClipboardFormat(PCWSTR('PNG'.toNativeUtf16(allocator: arena)))
            .value,
  );

  /// 同步探测供键盘事件决定是否保留系统文本粘贴。
  bool get hasImage =>
      Platform.isWindows &&
      (IsClipboardFormatAvailable(_png).value ||
          IsClipboardFormatAvailable(CF_DIB).value);

  /// 原生锁仅用于有界复制，转换编码前立即释放剪贴板。
  Future<Uint8List?> readPng() async {
    if (!Platform.isWindows || !OpenClipboard(null).value) {
      throw const ApiFailure('剪贴板正被占用，请重新粘贴');
    }
    // PNG 内容无需颜色转换，否则读取 Windows 常见的 DIB。
    late final bool png;
    // 拷贝后的内容不依赖剪贴板句柄的生命周期。
    Uint8List? bytes;
    try {
      png = IsClipboardFormatAvailable(_png).value;
      if (!png && !IsClipboardFormatAvailable(CF_DIB).value) return null;
      // 数据句柄由 Windows 所有，不能 GlobalFree。
      final HANDLE handle = GetClipboardData(png ? _png : CF_DIB).value;
      if (handle.address == 0) throw const ApiFailure('无法读取剪贴板图片');
      // 在读取内存前限定大小，拒绝异常剪贴板块。
      final int length = GlobalSize(HGLOBAL(handle)).value;
      if (length <= 0 || length > 80 * 1024 * 1024) {
        throw const ApiFailure('剪贴板图片过大，请保存后选择文件');
      }
      // 锁定期间只复制，任何异常都释放锁。
      final Pointer pointer = GlobalLock(HGLOBAL(handle)).value;
      if (pointer.address == 0) throw const ApiFailure('无法读取剪贴板图片');
      try {
        bytes = Uint8List.fromList(pointer.cast<Uint8>().asTypedList(length));
      } finally {
        GlobalUnlock(HGLOBAL(handle));
      }
    } finally {
      CloseClipboard();
    }
    if (png) return bytes;
    // 纯解析器验证几何和边界后才创建图像。
    final ({Uint8List rgba, int width, int height}) decoded =
        decodeClipboardDib(bytes);
    // Dart 图像引擎执行 PNG 编码。
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      decoded.rgba,
      decoded.width,
      decoded.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    // 原生图片持有内存必须及时释放。
    final ui.Image image = await completer.future;
    try {
      // 输出统一 PNG，服务端再次进行内容验证。
      final ByteData? result = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (result == null) throw const ApiFailure('剪贴板图片转换失败');
      return result.buffer.asUint8List(
        result.offsetInBytes,
        result.lengthInBytes,
      );
    } finally {
      image.dispose();
    }
  }
}

/// 验证并解码常见 24/32 位 RGB DIB；拒绝压缩及未知位域。
({Uint8List rgba, int width, int height}) decodeClipboardDib(Uint8List bytes) {
  if (bytes.length < 40) throw const ApiFailure('剪贴板图片格式不支持，请保存后选择文件');
  // 所有 DIB 头字段使用小端。
  final ByteData header = ByteData.sublistView(bytes);
  // 头长度必须覆盖 BITMAPINFOHEADER 且位于数据范围内。
  final int headerSize = header.getUint32(0, Endian.little);
  // 原始像素宽度。
  final int width = header.getInt32(4, Endian.little);
  // 负高度代表从上到下排列。
  final int signedHeight = header.getInt32(8, Endian.little);
  // 真实行数。
  final int height = signedHeight.abs();
  // 像素位数决定行跨度。
  final int bits = header.getUint16(14, Endian.little);
  // 只接受未压缩 RGB 或标准 BGR 位域。
  final int compression = header.getUint32(16, Endian.little);
  if (!<int>{40, 52, 56, 108, 124}.contains(headerSize) ||
      headerSize > bytes.length ||
      width <= 0 ||
      height <= 0 ||
      width * height > 20000000 ||
      header.getUint16(12, Endian.little) != 1 ||
      !<int>{24, 32}.contains(bits) ||
      !<int>{0, 3}.contains(compression)) {
    throw const ApiFailure('剪贴板图片过大或格式不支持，请保存后选择文件');
  }
  // BITMAPINFOHEADER 的外部位域占额外 12 字节。
  final int masks = compression == 3 && headerSize == 40 ? 12 : 0;
  if (compression == 3) {
    if (bits != 32 ||
        bytes.length < 52 ||
        header.getUint32(40, Endian.little) != 0x00ff0000 ||
        header.getUint32(44, Endian.little) != 0x0000ff00 ||
        header.getUint32(48, Endian.little) != 0x000000ff) {
      throw const ApiFailure('剪贴板图片位域不支持，请保存后选择文件');
    }
  }
  // 24/32 位图片也可能携带显式颜色表。
  final int colors = header.getUint32(32, Endian.little);
  // 像素起始位置经过边界校验。
  final int offset = headerSize + masks + colors * 4;
  // Windows 每行按四字节对齐。
  final int stride = ((width * bits + 31) ~/ 32) * 4;
  if (offset + stride * height > bytes.length) {
    throw const ApiFailure('剪贴板图片内容不完整');
  }
  // 生成紧凑 RGBA，BI_RGB 未定义的 alpha 不能导致全透明。
  final Uint8List rgba = Uint8List(width * height * 4);
  // 明确提供标准透明位域时才读取 alpha，BI_RGB 保持不透明。
  final bool alpha =
      compression == 3 &&
      headerSize >= 56 &&
      header.getUint32(52, Endian.little) == 0xff000000;
  for (int y = 0; y < height; y++) {
    // 正高度的 DIB 自底向上存储。
    final int row = offset + (signedHeight > 0 ? height - 1 - y : y) * stride;
    for (int x = 0; x < width; x++) {
      // 输入字节偏移。
      final int source = row + x * (bits ~/ 8);
      // 输出字节偏移。
      final int target = (y * width + x) * 4;
      rgba[target] = bytes[source + 2];
      rgba[target + 1] = bytes[source + 1];
      rgba[target + 2] = bytes[source];
      rgba[target + 3] = alpha ? bytes[source + 3] : 255;
    }
  }
  return (rgba: rgba, width: width, height: height);
}

/// 可替换适配器供键盘测试验证不抢占普通文本粘贴。
final Provider<WindowsClipboardImages> windowsClipboardImagesProvider =
    Provider<WindowsClipboardImages>((Ref ref) => WindowsClipboardImages());
