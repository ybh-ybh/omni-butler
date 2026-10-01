import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/home/data/quote_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 用户选择的名言 JSON 文件内容。
class QuoteJsonInputFile {
  /// 原始文件名。
  final String name;

  /// 文件字节。
  final Uint8List bytes;

  /// 创建名言 JSON 输入文件。
  const QuoteJsonInputFile({required this.name, required this.bytes});
}

/// 名言 JSON 文件选择与保存网关。
abstract interface class QuoteJsonFileGateway {
  /// 选择并读取一个 JSON 文件。
  Future<QuoteJsonInputFile?> pickImportFile();

  /// 将 JSON 字节保存到用户选择的位置。
  Future<Uri?> saveExportFile({
    required String fileName,
    required Uint8List bytes,
  });
}

/// 使用系统文件选择器的名言 JSON 文件网关。
class SystemQuoteJsonFileGateway implements QuoteJsonFileGateway {
  /// 创建系统名言文件网关。
  const SystemQuoteJsonFileGateway();

  /// 选择并读取一个 JSON 文件。
  @override
  Future<QuoteJsonInputFile?> pickImportFile() async {
    // 用户选择的 JSON 文件。
    final PlatformFile? file = await FilePicker.pickFile(
      dialogTitle: '选择名言 JSON 文件',
      type: FileType.custom,
      allowedExtensions: const <String>['json'],
    );
    if (file == null) {
      return null;
    }
    // 兼容桌面路径与 Android 内容 URI 的文件字节。
    final Uint8List bytes = await file.readAsBytes();
    return QuoteJsonInputFile(name: file.name, bytes: bytes);
  }

  /// 将 JSON 字节保存到用户选择的位置。
  @override
  Future<Uri?> saveExportFile({
    required String fileName,
    required Uint8List bytes,
  }) {
    return FilePicker.saveFile(
      dialogTitle: '导出名言 JSON',
      fileName: fileName,
      bytes: bytes,
      mimeType: 'application/json',
    );
  }
}

/// 名言 JSON 文件操作。
enum _QuoteTransferAction {
  /// 导入 JSON。
  importJson,

  /// 导出 JSON。
  exportJson,
}

/// 名言库管理弹窗。
class QuoteLibraryDialog extends ConsumerStatefulWidget {
  /// 文件选择与保存网关。
  final QuoteJsonFileGateway fileGateway;

  /// 创建名言库管理弹窗。
  const QuoteLibraryDialog({
    this.fileGateway = const SystemQuoteJsonFileGateway(),
    super.key,
  });

  /// 显示名言库管理弹窗。
  static Future<void> show(BuildContext context) {
    return showOmniDialog<void>(
      context: context,
      builder: (BuildContext context) => const QuoteLibraryDialog(),
    );
  }

  /// 创建名言库管理状态。
  @override
  ConsumerState<QuoteLibraryDialog> createState() => _QuoteLibraryDialogState();
}

/// 名言库管理弹窗状态。
class _QuoteLibraryDialogState extends ConsumerState<QuoteLibraryDialog> {
  /// 当前是否正在读写 JSON 文件或数据库。
  bool _transferring = false;

  /// 打开名言编辑器。
  Future<void> _edit([QuoteRecord? quote]) async {
    // 用户提交的名言草稿。
    final QuoteDraft? draft = await showOmniSideSheet<QuoteDraft>(
      context,
      builder: (BuildContext context) => _QuoteEditorDialog(quote: quote),
    );
    if (draft == null) {
      return;
    }
    try {
      await ref.read(quoteRepositoryProvider).save(draft);
      _invalidateToday();
    } on FormatException catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: error.message,
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 确认并删除名言。
  Future<void> _delete(QuoteRecord quote) async {
    // 用户是否确认删除。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '删除这条名言？',
      message: '如果它正被今日使用，首页会重新选择一条可用名言。删除后可在回收站恢复。',
      confirmLabel: '移入回收站',
      danger: true,
    );
    if (confirmed) {
      await ref.read(quoteRepositoryProvider).delete(quote.id);
      ref.invalidate(recycleBinItemsProvider);
      _invalidateToday();
      if (mounted) {
        showOmniMessage(
          context,
          message: '“${quote.content}”已移入回收站',
          tone: OmniMessageTone.success,
        );
      }
    }
  }

  /// 根据用户选择执行导入或导出。
  void _handleTransferAction(_QuoteTransferAction action) {
    switch (action) {
      case _QuoteTransferAction.importJson:
        unawaited(_runTransfer(_importJson));
      case _QuoteTransferAction.exportJson:
        unawaited(_runTransfer(_exportJson));
    }
  }

  /// 在统一加载与错误反馈中执行文件操作。
  Future<void> _runTransfer(Future<void> Function() operation) async {
    if (_transferring) {
      return;
    }
    setState(() => _transferring = true);
    try {
      await operation();
    } on FormatException catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: error.message,
          tone: OmniMessageTone.error,
        );
      }
    } on Object catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '名言文件操作失败：$error',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _transferring = false);
      }
    }
  }

  /// 选择、预览并导入名言 JSON。
  Future<void> _importJson() async {
    // 用户选择并读取的 JSON 文件。
    final QuoteJsonInputFile? file = await widget.fileGateway.pickImportFile();
    if (file == null) {
      if (mounted) {
        showOmniMessage(context, message: '已取消导入');
      }
      return;
    }
    // 名言库仓储。
    final QuoteRepository repository = ref.read(quoteRepositoryProvider);
    // 严格校验并去重后的导入文档。
    final QuoteImportDocument document = repository.decodeImportJson(
      file.bytes,
    );
    // 两种导入方式的数量预览。
    final QuoteImportPreview preview = await repository.previewImport(document);
    if (!mounted) {
      return;
    }
    // 用户最终选择的导入方式。
    final QuoteImportMode? mode = await QuoteImportPreviewDialog.show(
      context,
      fileName: file.name,
      preview: preview,
    );
    if (mode == null) {
      if (mounted) {
        showOmniMessage(context, message: '已取消导入');
      }
      return;
    }
    // 实际导入结果。
    final QuoteImportResult result = await repository.importJson(
      document,
      mode,
    );
    ref.invalidate(recycleBinItemsProvider);
    _invalidateToday();
    if (mounted) {
      showOmniMessage(
        context,
        message: _importSuccessMessage(mode, result),
        tone: OmniMessageTone.success,
      );
    }
  }

  /// 导出当前未删除名言到用户选择的位置。
  Future<void> _exportJson() async {
    // 当前名言库 JSON 字节。
    final Uint8List bytes = await ref
        .read(quoteRepositoryProvider)
        .exportJson();
    // 带自然日的默认导出文件名。
    final String fileName =
        'omni-butler-quotes-${DateFormat('yyyyMMdd').format(DateTime.now())}.json';
    // 文件保存结果。
    final Uri? savedUri = await widget.fileGateway.saveExportFile(
      fileName: fileName,
      bytes: bytes,
    );
    if (!mounted) {
      return;
    }
    if (savedUri == null) {
      showOmniMessage(context, message: '已取消导出');
      return;
    }
    showOmniMessage(
      context,
      message: '名言已导出为 $fileName',
      tone: OmniMessageTone.success,
    );
  }

  /// 返回合并或替换后的成功摘要。
  String _importSuccessMessage(QuoteImportMode mode, QuoteImportResult result) {
    return switch (mode) {
      QuoteImportMode.merge =>
        '已新增 ${result.insertedCount} 条名言，跳过 ${result.skippedCount} 条重复项',
      QuoteImportMode.replace =>
        '已导入 ${result.insertedCount} 条名言，原有 ${result.replacedCount} 条已移入回收站，跳过 ${result.skippedCount} 条重复项',
    };
  }

  /// 刷新今日名言选择。
  void _invalidateToday() {
    ref.invalidate(quoteForDayProvider(DateUtils.dateOnly(DateTime.now())));
  }

  /// 构建名言库管理弹窗。
  @override
  Widget build(BuildContext context) {
    // 当前名言库流。
    final AsyncValue<List<QuoteRecord>> quotes = ref.watch(quotesProvider);
    return OmniDialogScaffold(
      title: '名言库',
      width: 680,
      height: 580,
      actions: <Widget>[
        OmniPopupMenuButton<_QuoteTransferAction>(
          key: const ValueKey<String>('quote-transfer-menu'),
          tooltip: '导入或导出',
          enabled: !_transferring,
          icon: _transferring
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.swap_vert_rounded),
          onSelected: _handleTransferAction,
          itemBuilder: (BuildContext context) =>
              <PopupMenuEntry<_QuoteTransferAction>>[
                OmniPopupMenuItem<_QuoteTransferAction>(
                  key: const ValueKey<String>('quote-import-json-action'),
                  value: _QuoteTransferAction.importJson,
                  label: '导入 JSON',
                  icon: Icons.file_upload_outlined,
                ),
                OmniPopupMenuItem<_QuoteTransferAction>(
                  key: const ValueKey<String>('quote-export-json-action'),
                  value: _QuoteTransferAction.exportJson,
                  label: '导出 JSON',
                  icon: Icons.file_download_outlined,
                ),
              ],
        ),
        OmniButton(
          label: '新增名言',
          icon: Icons.add_rounded,
          variant: OmniButtonVariant.secondary,
          onPressed: _transferring ? null : _edit,
        ),
        OmniButton(label: '完成', onPressed: () => Navigator.of(context).pop()),
      ],
      child: SizedBox(
        height: 460,
        child: quotes.when(
          data: (List<QuoteRecord> records) {
            if (records.isEmpty) {
              return const Center(child: Text('名言库为空，首页会展示内置占位内容。'));
            }
            return OmniPanel(
              padding: EdgeInsets.zero,
              child: ListView.separated(
                itemCount: records.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) {
                  // 当前名言。
                  final QuoteRecord quote = records[index];
                  // 当前是否为紧凑布局。
                  final bool compact = OmniBreakpoint.isCompact(
                    MediaQuery.sizeOf(context).width,
                  );
                  return OmniListRow(
                    leading: const Icon(Icons.format_quote_rounded),
                    title: Text(
                      quote.content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(quote.source ?? '未署名'),
                    onTap: () => _edit(quote),
                    trailing: Wrap(
                      spacing: OmniSpacing.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        OmniSwitch(
                          value: quote.isEnabled,
                          onChanged: (bool value) async {
                            await ref
                                .read(quoteRepositoryProvider)
                                .setEnabled(quote.id, value);
                            _invalidateToday();
                          },
                        ),
                        if (!compact) ...<Widget>[
                          IconButton(
                            tooltip: '编辑',
                            onPressed: () => _edit(quote),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: '移入回收站',
                            onPressed: () => _delete(quote),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ] else
                          OmniPopupMenuButton<String>(
                            tooltip: '更多操作',
                            onSelected: (String value) {
                              if (value == 'edit') {
                                _edit(quote);
                              } else if (value == 'delete') {
                                _delete(quote);
                              }
                            },
                            itemBuilder: (BuildContext context) =>
                                <PopupMenuEntry<String>>[
                                  OmniPopupMenuItem<String>(
                                    value: 'edit',
                                    label: '编辑',
                                    icon: Icons.edit_outlined,
                                  ),
                                  OmniPopupMenuItem<String>(
                                    value: 'delete',
                                    label: '移入回收站',
                                    icon: Icons.delete_outline_rounded,
                                    danger: true,
                                  ),
                                ],
                          ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, StackTrace stackTrace) =>
              Center(child: Text('名言库读取失败：$error')),
        ),
      ),
    );
  }
}

/// 名言 JSON 导入方式预览弹窗。
class QuoteImportPreviewDialog extends StatefulWidget {
  /// 用户选择的文件名。
  final String fileName;

  /// 导入数量预览。
  final QuoteImportPreview preview;

  /// 创建名言导入预览弹窗。
  const QuoteImportPreviewDialog({
    required this.fileName,
    required this.preview,
    super.key,
  });

  /// 显示导入预览并返回用户选择的方式。
  static Future<QuoteImportMode?> show(
    BuildContext context, {
    required String fileName,
    required QuoteImportPreview preview,
  }) {
    return showOmniDialog<QuoteImportMode>(
      context: context,
      builder: (BuildContext context) =>
          QuoteImportPreviewDialog(fileName: fileName, preview: preview),
    );
  }

  /// 创建名言导入预览状态。
  @override
  State<QuoteImportPreviewDialog> createState() =>
      _QuoteImportPreviewDialogState();
}

/// 名言 JSON 导入方式预览弹窗状态。
class _QuoteImportPreviewDialogState extends State<QuoteImportPreviewDialog> {
  /// 默认采用更安全的合并方式。
  QuoteImportMode _mode = QuoteImportMode.merge;

  /// 确认当前导入方式。
  void _submit() {
    Navigator.of(context).pop(_mode);
  }

  /// 构建导入数量、方式和风险提示。
  @override
  Widget build(BuildContext context) {
    // 当前导入预览。
    final QuoteImportPreview preview = widget.preview;
    // 当前方式对应的主要操作标签。
    final String confirmLabel = _mode == QuoteImportMode.merge
        ? '合并导入'
        : '替换并导入';
    return OmniDialogScaffold(
      title: '导入预览',
      width: 480,
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        OmniButton(
          key: const ValueKey<String>('quote-import-confirm-button'),
          label: confirmLabel,
          variant: _mode == QuoteImportMode.replace
              ? OmniButtonVariant.danger
              : OmniButtonVariant.primary,
          onPressed: _submit,
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: OmniSpacing.xs),
            Text(
              '文件共 ${preview.document.totalCount} 条，去重后 ${preview.document.entries.length} 条'
              '${preview.document.duplicateCount == 0 ? '' : ' · 文件内重复 ${preview.document.duplicateCount} 条'}',
            ),
            const SizedBox(height: OmniSpacing.lg),
            RadioGroup<QuoteImportMode>(
              groupValue: _mode,
              onChanged: (QuoteImportMode? value) {
                if (value != null) {
                  setState(() => _mode = value);
                }
              },
              child: Column(
                children: <Widget>[
                  RadioListTile<QuoteImportMode>(
                    key: const ValueKey<String>('quote-import-mode-merge'),
                    value: QuoteImportMode.merge,
                    title: const Text('合并导入'),
                    subtitle: Text(
                      '新增 ${preview.mergeInsertedCount} 条，跳过 ${preview.mergeSkippedCount} 条重复项；现有 ${preview.currentCount} 条保持不变。',
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<QuoteImportMode>(
                    key: const ValueKey<String>('quote-import-mode-replace'),
                    value: QuoteImportMode.replace,
                    title: const Text('替换导入'),
                    subtitle: Text(
                      '现有 ${preview.currentCount} 条全部移入回收站，再导入 ${preview.document.entries.length} 条。',
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            if (_mode == QuoteImportMode.replace) ...<Widget>[
              const SizedBox(height: OmniSpacing.sm),
              Text(
                '替换不会永久删除旧名言，可稍后从回收站恢复。',
                key: const ValueKey<String>('quote-import-replace-warning'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 名言编辑弹窗。
class _QuoteEditorDialog extends StatefulWidget {
  /// 可选待编辑名言。
  final QuoteRecord? quote;

  /// 创建名言编辑弹窗。
  const _QuoteEditorDialog({this.quote});

  /// 创建弹窗状态。
  @override
  State<_QuoteEditorDialog> createState() => _QuoteEditorDialogState();
}

/// 名言编辑弹窗状态。
class _QuoteEditorDialogState extends State<_QuoteEditorDialog> {
  /// 正文控制器。
  late final TextEditingController _contentController;

  /// 出处控制器。
  late final TextEditingController _sourceController;

  /// 是否启用。
  late bool _isEnabled;

  /// 初始化名言表单。
  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(
      text: widget.quote?.content ?? '',
    );
    _sourceController = TextEditingController(text: widget.quote?.source ?? '');
    _isEnabled = widget.quote?.isEnabled ?? true;
  }

  /// 释放文本控制器。
  @override
  void dispose() {
    _contentController.dispose();
    _sourceController.dispose();
    super.dispose();
  }

  /// 提交名言草稿。
  void _submit() {
    Navigator.of(context).pop(
      QuoteDraft(
        id: widget.quote?.id,
        content: _contentController.text,
        source: _sourceController.text,
        isEnabled: _isEnabled,
      ),
    );
  }

  /// 构建名言编辑表单。
  @override
  Widget build(BuildContext context) {
    return OmniSideSheetScaffold(
      title: widget.quote == null ? '新增名言' : '编辑名言',
      actions: <Widget>[
        OmniButton(
          label: '取消',
          variant: OmniButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        OmniButton(label: '保存', onPressed: _submit),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OmniSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _contentController,
              autofocus: true,
              maxLines: 4,
              decoration: const InputDecoration(labelText: '正文 *'),
            ),
            const SizedBox(height: OmniSpacing.md),
            TextField(
              controller: _sourceController,
              decoration: const InputDecoration(labelText: '出处'),
            ),
            OmniSwitchListTile(
              value: _isEnabled,
              title: const Text('参与每日选择'),
              onChanged: (bool value) => setState(() => _isEnabled = value),
            ),
          ],
        ),
      ),
    );
  }
}
