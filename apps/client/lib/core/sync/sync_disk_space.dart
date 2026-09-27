import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:win32/win32.dart';

/// 读取候选库所在卷可用空间，错误时不开始远端替换。
Future<int> migrationFreeBytes(String directory) async {
  if (Platform.isWindows) {
    return using((Arena arena) {
      // 当前进程实际可用的磁盘字节数。
      final Pointer<Uint64> available = arena<Uint64>();
      // 调用 Windows 原生卷空间查询。
      final result = GetDiskFreeSpaceEx(
        PCWSTR(directory.toNativeUtf16(allocator: arena)),
        available,
        nullptr,
        nullptr,
      );
      if (!result.value) throw const ApiFailure('无法检查本机剩余空间，请稍后重试');
      return available.value;
    });
  }
  if (Platform.isAndroid) {
    // Android 使用与应用私有目录相同的文件系统。
    final int? available = await const MethodChannel('omni_butler/storage')
        .invokeMethod<int>('availableBytes', {'path': directory});
    if (available != null) return available;
  }
  throw const ApiFailure('当前平台尚不支持安全迁移的磁盘空间检查');
}
