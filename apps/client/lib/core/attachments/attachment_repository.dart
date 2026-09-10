import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 第一期附件业务类型。
enum AttachmentBusinessType {
  /// 首页名言横幅背景。
  quoteBanner,

  /// 物品主图。
  inventoryImage,

  /// 会员主图。
  membershipImage,
}

/// 附件保存状态；云端状态保留给下一期附件同步。
enum AttachmentUploadState {
  /// 只保存在当前设备。
  localOnly,

  /// 等待上传。
  pending,

  /// 正在上传。
  uploading,

  /// 已完成云端登记。
  synced,

  /// 上传失败。
  failed,
}

/// 本地附件仓储。
class AttachmentRepository {
  /// 本地数据库。
  final AppDatabase _database;

  /// UUID 生成器。
  final Uuid _uuid;

  /// 应用数据目录解析器。
  final Future<Directory> Function() _directoryProvider;

  /// 创建附件仓储。
  AttachmentRepository(
    this._database, {
    this._uuid = const Uuid(),
    Future<Directory> Function()? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  /// 监听指定业务记录当前有效附件。
  Stream<Attachment?> watchCurrent({
    required AttachmentBusinessType businessType,
    required String businessId,
  }) {
    // 业务附件查询。
    final query = _database.select(_database.attachments)
      ..where(
        (Attachments table) =>
            table.businessType.equals(businessType.name) &
            table.businessId.equals(businessId) &
            table.deletedAt.isNull(),
      )
      ..orderBy(<OrderingTerm Function(Attachments)>[
        (Attachments table) => OrderingTerm.desc(table.updatedAt),
      ])
      ..limit(1);
    return query.watchSingleOrNull();
  }

  /// 读取下一期可处理的附件上传任务。
  Stream<List<Attachment>> watchUploadQueue() {
    // 待处理附件查询。
    final query = _database.select(_database.attachments)
      ..where(
        (Attachments table) =>
            table.deletedAt.isNull() &
            table.uploadState.isIn(<String>[
              AttachmentUploadState.pending.name,
              AttachmentUploadState.failed.name,
            ]),
      )
      ..orderBy(<OrderingTerm Function(Attachments)>[
        (Attachments table) => OrderingTerm.asc(table.createdAt),
      ]);
    return query.watch();
  }

  /// 将用户选择的文件复制到应用私有目录并建立本机关联。
  Future<Attachment> attachLocalFile({
    required AttachmentBusinessType businessType,
    required String businessId,
    required String sourcePath,
    String? mimeType,
  }) async {
    // 用户选择的源文件。
    final File source = File(sourcePath);
    if (!await source.exists()) {
      throw const FileSystemException('所选文件不存在');
    }
    // 源文件字节。
    final List<int> bytes = await source.readAsBytes();
    // 文件摘要。
    final String fileHash = sha256.convert(bytes).toString();
    // 同一业务下已存在的相同附件。
    final Attachment? duplicated =
        await (_database.select(_database.attachments)..where(
              (Attachments table) =>
                  table.businessType.equals(businessType.name) &
                  table.businessId.equals(businessId) &
                  table.sha256.equals(fileHash) &
                  table.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    if (duplicated != null) {
      return duplicated;
    }
    // 新附件稳定标识。
    final String id = _uuid.v7();
    // 应用数据目录。
    final Directory supportDirectory = await _directoryProvider();
    // 附件私有目录。
    final Directory attachmentDirectory = Directory(
      path.join(supportDirectory.path, 'omni_butler', 'attachments'),
    );
    await attachmentDirectory.create(recursive: true);
    // 保留后的文件扩展名。
    final String extension = path.extension(source.path).toLowerCase();
    // 私有文件目标路径。
    final String targetPath = path.join(
      attachmentDirectory.path,
      '$id$extension',
    );
    // 私有附件文件。
    final File target = await source.copy(targetPath);
    // 当前创建时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      await _softDeleteCurrent(businessType, businessId, now);
      await _database
          .into(_database.attachments)
          .insert(
            AttachmentsCompanion.insert(
              id: id,
              businessType: businessType.name,
              businessId: businessId,
              localPath: Value<String>(target.path),
              mimeType: Value<String?>(mimeType),
              sizeBytes: Value<int>(bytes.length),
              sha256: Value<String>(fileHash),
              uploadState: Value<String>(AttachmentUploadState.localOnly.name),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _updateBusinessReference(
        businessType: businessType,
        businessId: businessId,
        attachmentId: id,
        localPath: target.path,
        now: now,
      );
    });
    return (_database.select(
      _database.attachments,
    )..where((Attachments table) => table.id.equals(id))).getSingle();
  }

  /// 恢复默认背景或移除业务主图。
  Future<void> removeCurrent({
    required AttachmentBusinessType businessType,
    required String businessId,
  }) async {
    // 当前删除时间。
    final DateTime now = DateTime.now();
    await _database.transaction(() async {
      await _softDeleteCurrent(businessType, businessId, now);
      await _updateBusinessReference(
        businessType: businessType,
        businessId: businessId,
        attachmentId: null,
        localPath: null,
        now: now,
      );
    });
  }

  /// 将失败附件重新放回等待队列。
  Future<void> retry(String id) async {
    await (_database.update(
      _database.attachments,
    )..where((Attachments table) => table.id.equals(id))).write(
      AttachmentsCompanion(
        uploadState: Value<String>(AttachmentUploadState.pending.name),
        lastError: const Value<String?>(null),
        updatedAt: Value<DateTime>(DateTime.now()),
      ),
    );
  }

  /// 更新附件上传状态。
  Future<void> updateUploadState({
    required String id,
    required AttachmentUploadState state,
    String? objectKey,
    String? error,
  }) async {
    await (_database.update(
      _database.attachments,
    )..where((Attachments table) => table.id.equals(id))).write(
      AttachmentsCompanion(
        objectKey: objectKey == null
            ? const Value.absent()
            : Value<String>(objectKey),
        uploadState: Value<String>(state.name),
        lastError: Value<String?>(error),
        updatedAt: Value<DateTime>(DateTime.now()),
      ),
    );
  }

  /// 软删除当前业务附件。
  Future<void> _softDeleteCurrent(
    AttachmentBusinessType businessType,
    String businessId,
    DateTime now,
  ) async {
    await (_database.update(_database.attachments)..where(
          (Attachments table) =>
              table.businessType.equals(businessType.name) &
              table.businessId.equals(businessId) &
              table.deletedAt.isNull(),
        ))
        .write(
          AttachmentsCompanion(
            deletedAt: Value<DateTime>(now),
            updatedAt: Value<DateTime>(now),
          ),
        );
  }

  /// 更新业务记录保存的稳定附件标识。
  Future<void> _updateBusinessReference({
    required AttachmentBusinessType businessType,
    required String businessId,
    required String? attachmentId,
    required String? localPath,
    required DateTime now,
  }) async {
    switch (businessType) {
      case AttachmentBusinessType.quoteBanner:
        // 已存在的首页横幅配置。
        final BannerSetting? current =
            await (_database.select(_database.bannerSettings)
                  ..where((BannerSettings table) => table.key.equals('home')))
                .getSingleOrNull();
        if (current == null) {
          await _database
              .into(_database.bannerSettings)
              .insert(
                BannerSettingsCompanion.insert(
                  id: const Uuid().v7(),
                  key: 'home',
                  attachmentId: Value<String?>(attachmentId),
                  updatedAt: now,
                ),
              );
        } else {
          await (_database.update(_database.bannerSettings)
                ..where((BannerSettings table) => table.id.equals(current.id)))
              .write(
                BannerSettingsCompanion(
                  attachmentId: Value<String?>(attachmentId),
                  updatedAt: Value<DateTime>(now),
                ),
              );
        }
      case AttachmentBusinessType.inventoryImage:
        await (_database.update(
          _database.inventoryItems,
        )..where((InventoryItems table) => table.id.equals(businessId))).write(
          InventoryItemsCompanion(
            imageAttachmentId: Value<String?>(attachmentId),
            imageLocalPath: Value<String?>(localPath),
            updatedAt: Value<DateTime>(now),
          ),
        );
      case AttachmentBusinessType.membershipImage:
        await (_database.update(
          _database.memberships,
        )..where((Memberships table) => table.id.equals(businessId))).write(
          MembershipsCompanion(
            imageAttachmentId: Value<String?>(attachmentId),
            imageLocalPath: Value<String?>(localPath),
            updatedAt: Value<DateTime>(now),
          ),
        );
    }
  }
}
