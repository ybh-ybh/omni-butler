import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';

/// 验证附件本地保存、摘要去重和业务关联。
void main() {
  /// 每个测试使用的内存数据库。
  late AppDatabase database;

  /// 每个测试使用的临时目录。
  late Directory temporaryDirectory;

  /// 每个测试使用的附件仓储。
  late AttachmentRepository repository;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'omni_butler_attachment_test_',
    );
    repository = AttachmentRepository(
      database,
      directoryProvider: () async => temporaryDirectory,
    );
  });

  tearDown(() async {
    await database.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('选择图片后复制到私有目录并保持仅本机状态', () async {
    // 测试源图片。
    final File source = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}source.png',
    );
    await source.writeAsBytes(<int>[137, 80, 78, 71, 1, 2, 3]);
    // 新建的附件。
    final Attachment attachment = await repository.attachLocalFile(
      businessType: AttachmentBusinessType.quoteBanner,
      businessId: 'home-banner',
      sourcePath: source.path,
      mimeType: 'image/png',
    );
    expect(attachment.uploadState, AttachmentUploadState.localOnly.name);
    expect(attachment.sha256, isNotEmpty);
    expect(await File(attachment.localPath!).exists(), isTrue);
    expect(await repository.watchUploadQueue().first, isEmpty);
  });

  test('同一业务重复选择相同内容不会产生第二条附件', () async {
    // 测试源图片。
    final File source = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}same.jpg',
    );
    await source.writeAsBytes(<int>[1, 2, 3, 4]);
    // 第一次选择结果。
    final Attachment first = await repository.attachLocalFile(
      businessType: AttachmentBusinessType.quoteBanner,
      businessId: 'home-banner',
      sourcePath: source.path,
    );
    // 第二次选择结果。
    final Attachment repeated = await repository.attachLocalFile(
      businessType: AttachmentBusinessType.quoteBanner,
      businessId: 'home-banner',
      sourcePath: source.path,
    );
    expect(repeated.id, first.id);
    expect(await repository.watchUploadQueue().first, isEmpty);
  });

  test('移除当前附件后业务引用清空且队列不再包含该任务', () async {
    // 测试源图片。
    final File source = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}remove.webp',
    );
    await source.writeAsBytes(<int>[8, 9, 10]);
    await repository.attachLocalFile(
      businessType: AttachmentBusinessType.quoteBanner,
      businessId: 'home-banner',
      sourcePath: source.path,
    );
    await repository.removeCurrent(
      businessType: AttachmentBusinessType.quoteBanner,
      businessId: 'home-banner',
    );
    expect(
      await repository
          .watchCurrent(
            businessType: AttachmentBusinessType.quoteBanner,
            businessId: 'home-banner',
          )
          .first,
      isNull,
    );
    expect(await repository.watchUploadQueue().first, isEmpty);
  });
}
