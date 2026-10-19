import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 明确重试只发送已保存的转写文本，不重新提交语音识别。
Future<void> retryNotePolish(
  BuildContext context,
  WidgetRef ref,
  NoteAudioSegmentRecord segment,
) async {
  try {
    // 当前来源有效的后台传输器，不能跨服务器重试。
    final transfer = ref.read(noteAudioTransferProvider);
    if (transfer == null) throw StateError('请先连接同步服务器');
    await transfer.retryPolish(segment.id);
    if (context.mounted) {
      showOmniMessage(context, message: '已请求重试 AI 整理');
    }
  } on Object catch (error) {
    if (context.mounted) {
      showOmniMessage(
        context,
        message: '整理重试失败：$error',
        tone: OmniMessageTone.error,
      );
    }
  }
}

/// 安全采用使用精确版本；冲突候选只有明确确认后才追加。
Future<void> adoptNotePolish(
  BuildContext context,
  WidgetRef ref,
  NoteAudioSegmentRecord segment,
) async {
  // 固定当前数据源，弹窗期间切换服务器不能写入新数据库。
  final repository = ref.read(noteRepositoryProvider);
  try {
    // 编辑中的草稿必须先正式保存，不能绕过编辑器提交。
    if (ref.read(noteEditorProvider).hasUncommittedDraft(segment.noteId)) {
      throw StateError('请先保存当前笔记草稿，再采用整理结果');
    }
    if (await repository.adoptPolishedTranscript(segment.id)) return;
    // 当前候选仅用于预览，实际提交会再次验证来源与版本。
    final NoteAudioLocalFileRecord? local = await (repository.database.select(
      repository.database.noteAudioLocalFiles,
    )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
    if (local?.polishedText == null || !context.mounted) return;
    // 确认只授权眼前的候选，后台新结果不能替换用户已预览的文本。
    final String? fingerprint = notePolishFingerprint(local!);
    if (fingerprint == null) throw StateError('整理候选不完整，请重新整理后采用');
    // 人工正文发生变化时，追加需要用户明确选择。
    final bool? append = await showOmniDialog<bool>(
      context: context,
      builder: (dialogContext) => OmniDialogScaffold(
        title: '采用 AI 整理结果',
        width: 560,
        actions: [
          OmniButton(
            label: '取消',
            variant: OmniButtonVariant.text,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          OmniButton(
            label: '追加到正文',
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(dialogContext).height * .55,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('正文版本已变化，整理结果将追加到末尾，请核对是否与现有内容重复。'),
                const SizedBox(height: 12),
                SelectableText(local.polishedText!),
              ],
            ),
          ),
        ),
      ),
    );
    if (append != true ||
        !context.mounted ||
        !identical(repository, ref.read(noteRepositoryProvider))) {
      return;
    }
    if (!await repository.adoptPolishedTranscript(
      segment.id,
      allowAppend: true,
      expectedFingerprint: fingerprint,
    )) {
      throw StateError('当前有未保存草稿、内容已采用或原记录已变化，请保存后重试');
    }
  } on Object catch (error) {
    if (context.mounted) {
      showOmniMessage(
        context,
        message: '采用失败：$error',
        tone: OmniMessageTone.error,
      );
    }
  }
}
