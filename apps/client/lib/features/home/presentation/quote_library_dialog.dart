import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/features/home/data/quote_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 名言库管理弹窗。
class QuoteLibraryDialog extends ConsumerWidget {
  /// 创建名言库管理弹窗。
  const QuoteLibraryDialog({super.key});

  /// 显示名言库管理弹窗。
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => const QuoteLibraryDialog(),
    );
  }

  /// 打开名言编辑器。
  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    QuoteRecord? quote,
  ]) async {
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
      _invalidateToday(ref);
    } on FormatException catch (error) {
      if (context.mounted) {
        showOmniMessage(
          context,
          message: error.message,
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 确认并删除名言。
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    QuoteRecord quote,
  ) async {
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
      _invalidateToday(ref);
      if (context.mounted) {
        showOmniMessage(
          context,
          message: '“${quote.content}”已移入回收站',
          tone: OmniMessageTone.success,
        );
      }
    }
  }

  /// 刷新今日名言选择。
  void _invalidateToday(WidgetRef ref) {
    ref.invalidate(quoteForDayProvider(DateUtils.dateOnly(DateTime.now())));
  }

  /// 构建名言库管理弹窗。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前名言库流。
    final AsyncValue<List<QuoteRecord>> quotes = ref.watch(quotesProvider);
    return OmniDialogScaffold(
      title: '名言库',
      width: 680,
      height: 580,
      actions: <Widget>[
        OmniButton(
          label: '新增名言',
          icon: Icons.add_rounded,
          variant: OmniButtonVariant.secondary,
          onPressed: () => _edit(context, ref),
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
                    onTap: () => _edit(context, ref, quote),
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
                            _invalidateToday(ref);
                          },
                        ),
                        if (!compact) ...<Widget>[
                          IconButton(
                            tooltip: '编辑',
                            onPressed: () => _edit(context, ref, quote),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: '移入回收站',
                            onPressed: () => _delete(context, ref, quote),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ] else
                          OmniPopupMenuButton<String>(
                            tooltip: '更多操作',
                            onSelected: (String value) {
                              if (value == 'edit') {
                                _edit(context, ref, quote);
                              } else if (value == 'delete') {
                                _delete(context, ref, quote);
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
