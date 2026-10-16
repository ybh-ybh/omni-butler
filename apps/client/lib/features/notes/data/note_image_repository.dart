import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:omni_butler/core/attachments/image_sync_store.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 正式图片和草稿图片共用的展示快照。
class NoteImageView {
  /// 稳定图片身份。
  final String id;

  /// 可用原件路径，尚未下载时为空。
  final String? localPath;

  /// 真实图片格式。
  final String? mimeType;

  /// 本机缓存或传输状态。
  final String uploadState;

  /// 同篇显示顺序。
  final int sortOrder;

  /// 创建只读图片快照。
  const NoteImageView({
    required this.id,
    this.localPath,
    this.mimeType,
    required this.uploadState,
    required this.sortOrder,
  });
}

/// 独立线程校验图片，避免大图解码阻塞编辑输入。
String _inspectNoteImage(Uint8List bytes) {
  // 格式解码器只接受产品已有的栅格图片类型。
  final img.Decoder? decoder = img.findDecoderForData(bytes);
  if (decoder is! img.PngDecoder &&
      decoder is! img.JpegDecoder &&
      decoder is! img.WebPDecoder &&
      decoder is! img.GifDecoder) {
    throw const FormatException('请选择 PNG、JPEG、WebP 或 GIF 图片');
  }
  // 先检查头部尺寸，再分配解码像素。
  final img.DecodeInfo? info = decoder!.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 40000000 ||
      decoder.decodeFrame(0) == null) {
    throw const FormatException('图片不完整或超过 4000 万像素');
  }
  return decoder is img.PngDecoder
      ? 'image/png'
      : decoder is img.JpegDecoder
      ? 'image/jpeg'
      : decoder is img.WebPDecoder
      ? 'image/webp'
      : 'image/gif';
}

/// 笔记多图的本机暂存、原子发布及共享原件清理。
class NoteImageRepository {
  /// 与笔记仓储共用的数据库。
  final AppDatabase database;

  /// 可注入的私有目录，测试不访问用户文件。
  final Future<Directory> Function() directoryProvider;

  /// 单张图片上限，与服务器图片协议保持一致。
  static const int maxBytes = 20 * 1024 * 1024;

  /// 创建图片生命周期入口。
  NoteImageRepository(
    this.database, {
    Future<Directory> Function()? directoryProvider,
  }) : directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  /// 正式图片按稳定顺序查询；回收站也可显示原件。
  Future<List<NoteImageRecord>> published(String noteId) =>
      (database.select(database.noteImages)
            ..where((table) => table.noteId.equals(noteId))
            ..orderBy([
              (table) => OrderingTerm.asc(table.sortOrder),
              (table) => OrderingTerm.asc(table.createdAt),
              (table) => OrderingTerm.asc(table.id),
            ]))
          .get();

  /// 当前代次新增图片只存本机。
  Future<List<NoteDraftImageRecord>> staged(String draftId) =>
      (database.select(database.noteDraftImages)
            ..where((table) => table.draftId.equals(draftId))
            ..orderBy([
              (table) => OrderingTerm.asc(table.sortOrder),
              (table) => OrderingTerm.asc(table.id),
            ]))
          .get();

  /// 图片与附件缓存任一变化都会刷新；删除过滤由编辑器当前差量决定。
  Stream<List<NoteImageView>> watch(String noteId, {String? draftId}) =>
      database
          .customSelect(
            '''
SELECT n.id, a.local_path, a.mime_type, COALESCE(a.upload_state, 'pending') AS upload_state,
 n.sort_order, n.created_at FROM note_images n
 LEFT JOIN attachments a ON a.business_type = 'noteImage' AND a.business_id = n.id AND a.deleted_at IS NULL
 WHERE n.note_id = ? AND n.deleted_at IS NULL
 UNION ALL SELECT id, local_path, mime_type, 'localOnly', 2147483647 + sort_order, created_at
 FROM note_draft_images WHERE draft_id = ? ORDER BY sort_order, created_at, id
''',
            variables: [Variable(noteId), Variable(draftId ?? '')],
            readsFrom: {
              database.noteImages,
              database.attachments,
              database.noteDraftImages,
            },
          )
          .watch()
          .map(
            (rows) => rows
                .map(
                  (row) => NoteImageView(
                    id: row.read<String>('id'),
                    localPath: row.readNullable<String>('local_path'),
                    mimeType: row.readNullable<String>('mime_type'),
                    uploadState: row.read<String>('upload_state'),
                    sortOrder: row.read<int>('sort_order'),
                  ),
                )
                .toList(),
          );

  /// 文件选择后立即复制私有原件，取消代次不得登记或上传。
  Future<bool> stage(
    String draftId,
    String noteId,
    String sourcePath, {
    String? imageId,
  }) async {
    // 外部选择请求使用固定身份，恢复时先复用已登记的原件。
    final NoteDraftImageRecord? existing = imageId == null
        ? null
        : await (database.select(
            database.noteDraftImages,
          )..where((row) => row.id.equals(imageId))).getSingleOrNull();
    if (existing != null) {
      // 幂等命中仍尊重取消墓碑，不能把已丢弃请求当作导入成功。
      final NoteLocalDraftRecord? owner = await (database.select(
        database.noteLocalDrafts,
      )..where((row) => row.id.equals(draftId))).getSingleOrNull();
      return owner != null &&
          !owner.discarded &&
          existing.draftId == draftId &&
          existing.noteId == noteId;
    }
    // 选择器交付的外部文件。
    final File source = File(sourcePath);
    if (!await source.exists()) throw const FileSystemException('所选图片不存在');
    // 读取前先限制长度，避免将过大文件载入内存。
    final int length = await source.length();
    if (length < 1 || length > maxBytes) {
      throw const FormatException('单张图片不能超过 20 MB');
    }
    // 完整字节和可信格式在数据库事务外校验。
    final Uint8List bytes = await source.readAsBytes();
    if (bytes.length > maxBytes) throw const FormatException('单张图片不能超过 20 MB');
    // 完整解码返回的可信MIME用于后续上传。
    final String mime = await compute(_inspectNoteImage, bytes);
    // 原件摘要贯穿发布、传输和迁移。
    final String digest = sha256.convert(bytes).toString();
    // 私有文件身份不依赖外部文件名。
    final String id = imageId ?? const Uuid().v4();
    // 应用持久数据根目录。
    final Directory root = await directoryProvider();
    // 原件不再依赖系统文件选择器的临时位置。
    final Directory directory = Directory(
      p.join(root.path, 'omni_butler', 'note_images'),
    );
    await directory.create(recursive: true);
    // 随机私有目标不会覆盖用户源文件。
    final File target = File(p.join(directory.path, '$id.image'));
    await target.writeAsBytes(bytes, flush: true);
    // 只有已登记文件才由引用清理器接管。
    bool retained = false;
    try {
      retained = await database.transaction(() async {
        // 草稿持久墓碑是取消与异步选图之间的最终边界。
        final NoteLocalDraftRecord? draft = await (database.select(
          database.noteLocalDrafts,
        )..where((table) => table.id.equals(draftId))).getSingleOrNull();
        if (draft == null || draft.discarded || draft.noteId != noteId) {
          return false;
        }
        // 同次多选按实际入库顺序追加，不覆盖已有图片。
        final List<NoteDraftImageRecord> current = await staged(draftId);
        await database
            .into(database.noteDraftImages)
            .insert(
              NoteDraftImagesCompanion.insert(
                id: id,
                draftId: draftId,
                noteId: noteId,
                localPath: Value(target.path),
                mimeType: mime,
                sha256: digest,
                sizeBytes: bytes.length,
                sortOrder:
                    current.fold<int>(
                      -1,
                      (value, item) =>
                          item.sortOrder > value ? item.sortOrder : value,
                    ) +
                    1,
                createdAt: DateTime.now(),
              ),
            );
        return true;
      });
      return retained;
    } finally {
      if (!retained && await target.exists()) await target.delete();
    }
  }

  /// 提交前检查原件；失败保留草稿与正式记录。
  Future<void> verify(String? localPath, int? size, String? digest) async {
    // 当前原件不能只靠文件名或存在性判断完整。
    final File? file = localPath == null ? null : File(localPath);
    if (file == null ||
        !await file.exists() ||
        await file.length() != size ||
        (await sha256.bind(file.openRead()).first).toString() != digest) {
      throw StateError('图片原件不完整，请先恢复或下载图片；草稿仍已保留');
    }
  }

  /// 查询当前图片有效缓存；每个图片子记录只对应一个附件槽。
  Future<Attachment?> attachment(String id) =>
      (database.select(database.attachments)..where(
            (table) =>
                table.businessType.equals('noteImage') &
                table.businessId.equals(id) &
                table.deletedAt.isNull(),
          ))
          .getSingleOrNull();

  /// 在调用方事务内发布新增图，追加到最新顺序而非覆盖远端集合。
  Future<void> publish(String noteId, List<NoteDraftImageRecord> images) async {
    // 远端刚添加的图片也参与末尾排序。
    final List<NoteImageRecord> current = await published(noteId);
    // 最新正式末尾顺序，包含并发追加的图片。
    int order = current.fold<int>(
      -1,
      (value, item) => item.sortOrder > value ? item.sortOrder : value,
    );
    for (final NoteDraftImageRecord image in images) {
      await _insert(
        id: image.id,
        noteId: noteId,
        localPath: image.localPath!,
        mimeType: image.mimeType,
        digest: image.sha256,
        size: image.sizeBytes,
        order: ++order,
        createdAt: image.createdAt,
      );
    }
  }

  /// 独立业务身份共享已验证原件，删除原篇不能删掉副本。
  Future<void> copy(
    String sourceId,
    String targetId, {
    Set<String> excluded = const {},
  }) async {
    // 包含回收站图片，用户另存时恢复完整资产。
    final List<NoteImageRecord> images = await published(sourceId);
    for (final NoteImageRecord image in images) {
      if (excluded.contains(image.id)) continue;
      // 不把尚未下载的图片静默丢弃。
      final Attachment? file = await attachment(image.id);
      await verify(file?.localPath, file?.sizeBytes, file?.sha256);
      await _insert(
        id: const Uuid().v4(),
        noteId: targetId,
        localPath: file!.localPath!,
        mimeType: file.mimeType!,
        digest: file.sha256!,
        size: file.sizeBytes!,
        order: image.sortOrder,
        createdAt: DateTime.now(),
      );
    }
  }

  /// 业务关联、缓存与待传操作必须同事务创建。
  Future<void> _insert({
    required String id,
    required String noteId,
    required String localPath,
    required String mimeType,
    required String digest,
    required int size,
    required int order,
    required DateTime createdAt,
  }) async {
    // 新缓存身份和业务图片身份分离，以兼容现有图片协议。
    final String attachmentId = const Uuid().v4();
    // 图片正式发布时刻。
    final DateTime now = DateTime.now();
    await database
        .into(database.noteImages)
        .insert(
          NoteImagesCompanion.insert(
            id: id,
            noteId: noteId,
            sortOrder: order,
            createdAt: createdAt,
            updatedAt: now,
          ),
        );
    await database
        .into(database.attachments)
        .insert(
          AttachmentsCompanion.insert(
            id: attachmentId,
            businessType: 'noteImage',
            businessId: id,
            localPath: Value(localPath),
            mimeType: Value(mimeType),
            sizeBytes: Value(size),
            uploadState: const Value('pending'),
            sha256: Value(digest),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await ImageSyncStore(database).recordIntent('noteImage', id, attachmentId);
  }

  /// 删除只作用于当前篇选中的身份，不触及并发新增图片。
  Future<void> remove(String noteId, Set<String> ids) =>
      (database.delete(
            database.noteImages,
          )..where((table) => table.noteId.equals(noteId) & table.id.isIn(ids)))
          .go()
          .then((_) {});

  /// 正式关联、回收站和有效草稿共同保护文件；失败留行以便重试。
  Future<void> purgeOrphans() => database.transaction(() async {
    // 所有正式图片及草稿代次的当前引用。
    final Set<String> ids = (await database.select(database.noteImages).get())
        .map((item) => item.id)
        .toSet();
    // 活跃草稿保留待发布原件，丢弃墓碑不再保护文件。
    final Set<String> drafts =
        (await (database.select(
              database.noteLocalDrafts,
            )..where((table) => table.discarded.equals(false))).get())
            .map((item) => item.id)
            .toSet();
    // 所有模块缓存共同参与共享文件保护。
    final List<Attachment> files = await database
        .select(database.attachments)
        .get();
    // 包括取消后待清理的草稿图片。
    final List<NoteDraftImageRecord> stagedFiles = await database
        .select(database.noteDraftImages)
        .get();
    // 其他模块路径也受保护，不能误删共享缓存。
    final Set<String> protected = {
      for (final Attachment file in files)
        if ((file.businessType != 'noteImage' ||
                ids.contains(file.businessId)) &&
            file.localPath != null)
          file.localPath!,
      for (final NoteDraftImageRecord file in stagedFiles)
        if (drafts.contains(file.draftId) && file.localPath != null)
          file.localPath!,
    };
    for (final Attachment file in files) {
      if (file.businessType != 'noteImage' || ids.contains(file.businessId)) {
        continue;
      }
      await _deleteUnprotected(file.localPath, protected);
      await (database.delete(
        database.attachments,
      )..where((table) => table.id.equals(file.id))).go();
      await ImageSyncStore(database)
          .remove('intent:noteImage:${file.businessId}');
      await ImageSyncStore(database)
          .remove('remote:noteImage:${file.businessId}');
    }
    for (final NoteDraftImageRecord file in stagedFiles) {
      if (drafts.contains(file.draftId)) continue;
      await _deleteUnprotected(file.localPath, protected);
      await (database.delete(
        database.noteDraftImages,
      )..where((table) => table.id.equals(file.id))).go();
    }
  });

  /// 仅清理由本仓储登记且不再被引用的私有文件。
  Future<void> _deleteUnprotected(
    String? localPath,
    Set<String> protected,
  ) async {
    if (localPath == null || protected.contains(localPath)) return;
    // 元数据路径仅来自已验证的私有复制或缓存下载。
    final File file = File(localPath);
    if (await file.exists()) await file.delete();
  }
}
