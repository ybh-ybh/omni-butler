import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/sync/sync_image_report.dart';
import 'package:omni_butler/core/sync/sync_snapshot.dart';
import 'package:path/path.dart' as path;

/// 验证迁移只报告实际缺失的业务主图，且不要求旧服务器在线。
void main() {
  test('路径选择优先可用业务路径，不存在时使用附件缓存', () async {
    // 所有文件严格位于当前测试自己的临时目录。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni-image-path-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final File business = File(path.join(directory.path, 'business.png'));
    final File attachment = File(path.join(directory.path, 'attachment.png'));
    await business.writeAsBytes(<int>[1]);
    await attachment.writeAsBytes(<int>[2]);
    expect(
      await findAvailableMigrationImagePath(
        businessPath: business.path,
        attachmentPath: attachment.path,
      ),
      business.path,
    );
    expect(
      await findAvailableMigrationImagePath(
        businessPath: path.join(directory.path, 'missing.png'),
        attachmentPath: attachment.path,
      ),
      attachment.path,
    );
    expect(
      await findAvailableMigrationImagePath(
        businessPath: '',
        attachmentPath: path.join(directory.path, 'missing.png'),
      ),
      isNull,
    );
  });

  test('本机主图和附件缓存可迁移，云端独有和已丢文件按业务名称报告', () async {
    // 专属临时目录，不接触真实附件。
    final Directory directory = await Directory.systemTemp.createTemp(
      'omni-image-report-',
    );
    addTearDown(() => directory.delete(recursive: true));
    // 文件可位于业务路径或附件缓存路径。
    final File cached = File(path.join(directory.path, 'cached.png'));
    await cached.writeAsBytes(<int>[1, 2, 3]);
    // 包括云端尚未下载、历史只有路径和首页背景的完整本机状态。
    final SyncSnapshot snapshot = SyncSnapshot(
      tables: <String, List<Map<String, Object?>>>{
        'inventory_items': <Map<String, Object?>>[
          <String, Object?>{'id': 'no-image', 'name': '没有主图'},
          <String, Object?>{
            'id': 'cached',
            'name': '本机物品',
            'image_attachment_id': 'cache-id',
          },
          <String, Object?>{
            'id': 'cloud',
            'name': '云端相机',
            'image_attachment_id': 'cloud-id',
          },
        ],
        'memberships': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'local',
            'name': '本机会籍',
            'image_local_path': cached.path,
          },
          <String, Object?>{
            'id': 'lost',
            'name': '文件已丢',
            'image_local_path': path.join(directory.path, 'gone.png'),
          },
        ],
        'attachments': <Map<String, Object?>>[
          <String, Object?>{'id': 'cache-id', 'local_path': cached.path},
          <String, Object?>{'id': 'cloud-id', 'local_path': null},
          <String, Object?>{
            'id': 'banner-id',
            'business_type': 'quoteBanner',
            'local_path': path.join(directory.path, 'missing-background.png'),
          },
        ],
      },
      pendingOperations: 0,
    );
    expect(await findMissingMigrationImages(snapshot), <String>[
      '物品：云端相机',
      '会员：文件已丢',
    ]);
  });
}
