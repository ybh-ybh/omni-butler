import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/sync/sync_disk_space.dart';

/// 验证生产 Windows FFI 查询在真实磁盘上返回可用字节数。
void main() {
  test('迁移空间预检读取应用可用磁盘空间', () async {
    // 系统临时目录与测试候选库位于相同卷。
    final int available = await migrationFreeBytes(Directory.systemTemp.path);
    expect(available, greaterThan(0));
  }, skip: !Platform.isWindows);
}
