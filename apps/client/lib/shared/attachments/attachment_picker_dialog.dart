import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/attachments/attachment_repository.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/shared/attachments/attachment_crop_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 通用主图或横幅附件选择弹窗。
class AttachmentPickerDialog extends ConsumerWidget {
  /// 附件业务类型。
  final AttachmentBusinessType businessType;

  /// 所属业务记录标识。
  final String businessId;

  /// 弹窗标题。
  final String title;

  /// 选择图片后是否进入裁剪流程，非 null 时裁剪框锁定为该宽高比。
  final double? cropAspectRatio;

  /// 创建附件选择弹窗。
  const AttachmentPickerDialog({
    required this.businessType,
    required this.businessId,
    required this.title,
    this.cropAspectRatio,
    super.key,
  });

  /// 显示附件选择弹窗。
  static Future<void> show(
    BuildContext context, {
    required AttachmentBusinessType businessType,
    required String businessId,
    required String title,
    double? cropAspectRatio,
  }) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AttachmentPickerDialog(
        businessType: businessType,
        businessId: businessId,
        title: title,
        cropAspectRatio: cropAspectRatio,
      ),
    );
  }

  /// 选择本地图片并写入应用私有目录。
  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    // 用户选择结果。
    final PlatformFile? result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['jpg', 'jpeg', 'png', 'webp'],
    );
    // 用户选择的文件路径。
    String? selectedPath = result?.path;
    if (selectedPath == null) {
      return;
    }

    // 如配置了裁剪比例，先进入裁剪流程。
    if (cropAspectRatio != null && context.mounted) {
      final String? croppedPath = await AttachmentCropDialog.show(
        context,
        sourcePath: selectedPath,
        title: title,
        aspectRatio: cropAspectRatio,
      );
      if (croppedPath == null) {
        return;
      }
      selectedPath = croppedPath;
    }

    try {
      await ref
          .read(attachmentRepositoryProvider)
          .attachLocalFile(
            businessType: businessType,
            businessId: businessId,
            sourcePath: selectedPath,
            mimeType: _mimeFor(selectedPath),
          );
    } on FileSystemException catch (error) {
      if (context.mounted) {
        showOmniMessage(
          context,
          message: error.message,
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 恢复默认图或移除当前主图。
  Future<void> _remove(WidgetRef ref) {
    return ref
        .read(attachmentRepositoryProvider)
        .removeCurrent(businessType: businessType, businessId: businessId);
  }

  /// 构建附件选择弹窗。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前业务附件。
    final AsyncValue<Attachment?> attachment = ref.watch(
      currentAttachmentProvider((businessType, businessId)),
    );
    return OmniDialogScaffold(
      title: title,
      width: 600,
      height: 520,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: attachment.when(
              data: (Attachment? record) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: _AttachmentPreview(attachment: record)),
                  if (record != null) ...<Widget>[
                    const SizedBox(height: OmniSpacing.sm),
                    _AttachmentStateLine(attachment: record),
                  ],
                ],
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object error, StackTrace stackTrace) =>
                  Center(child: Text('附件读取失败：$error')),
            ),
          ),
          const SizedBox(height: OmniSpacing.md),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: OmniSpacing.xs,
            runSpacing: OmniSpacing.xs,
            children: <Widget>[
              if (attachment.asData?.value != null)
                OmniButton(
                  label: businessType == AttachmentBusinessType.quoteBanner
                      ? '恢复默认背景'
                      : '移除图片',
                  variant: OmniButtonVariant.text,
                  onPressed: () => _remove(ref),
                ),
              OmniButton(
                label: attachment.asData?.value == null ? '选择图片' : '更换图片',
                icon: Icons.folder_open_outlined,
                variant: OmniButtonVariant.secondary,
                onPressed: () => _pick(context, ref),
              ),
              OmniButton(
                label: '完成',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 根据文件后缀返回常用图片 MIME 类型。
  String _mimeFor(String filePath) {
    // 小写文件路径。
    final String normalized = filePath.toLowerCase();
    if (normalized.endsWith('.png')) {
      return 'image/png';
    }
    if (normalized.endsWith('.webp')) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }
}

/// 附件图片预览。
class _AttachmentPreview extends StatelessWidget {
  /// 当前附件。
  final Attachment? attachment;

  /// 创建附件图片预览。
  const _AttachmentPreview({required this.attachment});

  /// 构建本地图片或空状态。
  @override
  Widget build(BuildContext context) {
    // 当前本地文件路径。
    final String? localPath = attachment?.localPath;
    if (localPath == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: OmniColors.of(context).mist,
          borderRadius: BorderRadius.circular(OmniRadius.panel),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.add_photo_alternate_outlined, size: 48),
              SizedBox(height: 10),
              Text('尚未选择图片'),
            ],
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(OmniRadius.panel),
      child: Image.file(
        File(localPath),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const Center(child: Text('本地图片无法读取')),
      ),
    );
  }
}

/// 附件保存状态行。
class _AttachmentStateLine extends ConsumerWidget {
  /// 当前附件。
  final Attachment attachment;

  /// 创建附件保存状态行。
  const _AttachmentStateLine({required this.attachment});

  /// 构建状态与重试入口。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前附件保存状态。
    final AttachmentUploadState state = AttachmentUploadState.values.firstWhere(
      (AttachmentUploadState value) => value.name == attachment.uploadState,
      orElse: () => AttachmentUploadState.localOnly,
    );
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 状态展示信息。
    final (String, Color, IconData) view = switch (state) {
      AttachmentUploadState.localOnly => (
        '图片只保存在当前设备',
        colors.muted,
        Icons.computer_rounded,
      ),
      AttachmentUploadState.pending => (
        '下一期云端上传任务等待处理',
        colors.warning,
        Icons.schedule_rounded,
      ),
      AttachmentUploadState.uploading => (
        '下一期云端附件正在上传',
        colors.info,
        Icons.cloud_upload_outlined,
      ),
      AttachmentUploadState.synced => (
        '下一期云端附件已同步',
        colors.success,
        Icons.cloud_done_outlined,
      ),
      AttachmentUploadState.failed => (
        '上传失败：${attachment.lastError ?? '未知错误'}',
        colors.danger,
        Icons.cloud_off_outlined,
      ),
    };
    return Wrap(
      spacing: OmniSpacing.xs,
      runSpacing: OmniSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        OmniTag(label: view.$1, color: view.$2, icon: view.$3),
        if (state == AttachmentUploadState.failed)
          OmniButton(
            label: '重试',
            variant: OmniButtonVariant.text,
            onPressed: () =>
                ref.read(attachmentRepositoryProvider).retry(attachment.id),
          ),
      ],
    );
  }
}
