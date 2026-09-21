import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 分类标签行菜单操作。
enum _TaxonomyRowAction {
  /// 重命名。
  rename,

  /// 删除。
  delete,
}

/// 模块分类与标签管理弹窗。
class TaxonomyManagerDialog extends ConsumerStatefulWidget {
  /// 所属模块。
  final TaxonomyModule module;

  /// 管理类型。
  final TaxonomyKind kind;

  /// 创建分类标签管理弹窗。
  const TaxonomyManagerDialog({
    required this.module,
    required this.kind,
    super.key,
  });

  /// 显示分类标签管理弹窗。
  static Future<void> show(
    BuildContext context, {
    required TaxonomyModule module,
    required TaxonomyKind kind,
  }) {
    // Windows 语义树无法稳定处理弹层过渡期间的节点切换。
    final bool desktop = OmniBreakpoint.isDesktopPlatform(
      Theme.of(context).platform,
    );
    return showDialog<void>(
      context: context,
      animationStyle: desktop ? AnimationStyle.noAnimation : null,
      builder: (BuildContext context) =>
          TaxonomyManagerDialog(module: module, kind: kind),
    );
  }

  /// 创建管理弹窗状态。
  @override
  ConsumerState<TaxonomyManagerDialog> createState() =>
      _TaxonomyManagerDialogState();
}

/// 分类标签管理弹窗状态。
class _TaxonomyManagerDialogState extends ConsumerState<TaxonomyManagerDialog> {
  /// 可选颜色名称和色值。
  static const List<(String, Color)> _colors = <(String, Color)>[
    ('蓝色', Color(0xFF3370FF)),
    ('青色', Color(0xFF1EA7A1)),
    ('绿色', Color(0xFF2EA121)),
    ('黄色', Color(0xFFD9A514)),
    ('橙色', Color(0xFFD97904)),
    ('红色', Color(0xFFE94444)),
    ('粉色', Color(0xFFD84A8B)),
    ('紫色', Color(0xFF8E5CD9)),
    ('靛青', Color(0xFF5B65C9)),
    ('灰色', Color(0xFF646A73)),
  ];

  /// 名称编辑控制器。
  final TextEditingController _nameController = TextEditingController();

  /// 当前正在重命名的分类标签标识。
  String? _editingId;

  /// 是否正在新增分类标签。
  bool _adding = false;

  /// 是否正在提交名称编辑。
  bool _savingName = false;

  /// 新增分类标签选择的颜色。
  Color _newColor = _colors.first.$2;

  /// 名称输入错误。
  String? _nameError;

  /// 用户本次打开弹窗后确认的本地显示顺序。
  List<String>? _localOrderIds;

  /// 当前操作反馈浮动消息。
  OmniMessageHandle? _feedbackMessage;

  /// 释放名称编辑控制器。
  @override
  void dispose() {
    _feedbackMessage?.dismiss();
    _nameController.dispose();
    super.dispose();
  }

  /// 当前业务中的分类标签名称。
  String get _typeName => switch (widget.kind) {
    TaxonomyKind.category => '分类',
    TaxonomyKind.tag => '标签',
    TaxonomyKind.location => '位置',
  };

  /// 当前管理器标题。
  String get _title {
    return switch (widget.module) {
      TaxonomyModule.timeline => '时间分类',
      TaxonomyModule.inventory => switch (widget.kind) {
        TaxonomyKind.category => '物品分类',
        TaxonomyKind.tag => '物品标签',
        TaxonomyKind.location => '物品位置',
      },
      TaxonomyModule.membership => '会员分类',
    };
  }

  /// 进入新增状态。
  void _startAdding() {
    setState(() {
      _adding = true;
      _editingId = null;
      _newColor = _colors.first.$2;
      _nameError = null;
      _nameController.clear();
    });
  }

  /// 进入重命名状态。
  void _startRenaming(TaxonomyEntry entry) {
    setState(() {
      _adding = false;
      _editingId = entry.id;
      _nameError = null;
      _nameController.text = entry.name;
      _nameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: entry.name.length,
      );
    });
  }

  /// 退出名称编辑状态。
  void _cancelEditing() {
    setState(() {
      _adding = false;
      _editingId = null;
      _nameError = null;
      _nameController.clear();
    });
  }

  /// 显示非表单操作失败信息。
  void _showError(Object error) {
    // 可直接展示的错误文本。
    final String message = error is FormatException
        ? error.message
        : '操作失败，请重试';
    _feedbackMessage = showOmniMessage(
      context,
      message: message,
      tone: OmniMessageTone.error,
      onDismissed: () => _feedbackMessage = null,
    );
  }

  /// 新增分类标签。
  Future<void> _add(List<TaxonomyEntry> entries) async {
    if (_savingName) {
      return;
    }
    setState(() {
      _savingName = true;
      _nameError = null;
    });
    try {
      await ref
          .read(taxonomyRepositoryProvider)
          .save(
            TaxonomyDraft(
              module: widget.module,
              kind: widget.kind,
              name: _nameController.text,
              colorValue: _newColor.toARGB32(),
              sortOrder: entries.length,
            ),
          );
      if (mounted) {
        _cancelEditing();
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _nameError = error.message);
      }
    } finally {
      if (mounted) {
        setState(() => _savingName = false);
      }
    }
  }

  /// 保存分类标签新名称。
  Future<void> _rename(TaxonomyEntry entry) async {
    if (_savingName) {
      return;
    }
    setState(() {
      _savingName = true;
      _nameError = null;
    });
    try {
      await ref
          .read(taxonomyRepositoryProvider)
          .save(
            TaxonomyDraft(
              id: entry.id,
              module: widget.module,
              kind: widget.kind,
              name: _nameController.text,
              colorValue: entry.colorValue,
              iconCodePoint: entry.iconCodePoint,
              sortOrder: entry.sortOrder,
            ),
          );
      if (mounted) {
        _cancelEditing();
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _nameError = error.message);
      }
    } finally {
      if (mounted) {
        setState(() => _savingName = false);
      }
    }
  }

  /// 保存分类标签新颜色。
  Future<void> _changeColor(TaxonomyEntry entry, Color color) async {
    try {
      await ref
          .read(taxonomyRepositoryProvider)
          .save(
            TaxonomyDraft(
              id: entry.id,
              module: widget.module,
              kind: widget.kind,
              name: entry.name,
              colorValue: color.toARGB32(),
              iconCodePoint: entry.iconCodePoint,
              sortOrder: entry.sortOrder,
            ),
          );
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  /// 删除分类标签并提供撤销入口。
  Future<void> _delete(TaxonomyEntry entry) async {
    // 用户是否确认删除。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '删除“${entry.name}”？',
      message: '删除后不能再为新记录选择它，已有记录中的$_typeName名称会继续保留。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      await ref.read(taxonomyRepositoryProvider).delete(entry.id);
      if (!mounted) {
        return;
      }
      if (_editingId == entry.id) {
        _cancelEditing();
      }
      _feedbackMessage?.dismiss();
      _feedbackMessage = showOmniMessage(
        context,
        message: '已删除“${entry.name}”',
        tone: OmniMessageTone.success,
        duration: const Duration(seconds: 10),
        actionLabel: '撤销',
        onAction: () => unawaited(_undoDelete(entry)),
        onDismissed: () => _feedbackMessage = null,
      );
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  /// 恢复最近删除的分类标签。
  Future<void> _undoDelete(TaxonomyEntry entry) async {
    try {
      await ref.read(taxonomyRepositoryProvider).restore(entry.id);
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  /// 保存拖拽后的分类标签顺序。
  Future<void> _reorder(
    List<TaxonomyEntry> entries,
    int oldIndex,
    int newIndex,
  ) async {
    // 调整后的分类标签。
    final List<TaxonomyEntry> reordered = List<TaxonomyEntry>.of(entries);
    // 被移动的分类标签。
    final TaxonomyEntry moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    // 本次拖拽后的标识顺序。
    final List<String> reorderedIds = reordered
        .map((TaxonomyEntry entry) => entry.id)
        .toList(growable: false);
    setState(() {
      _localOrderIds = reorderedIds;
    });
    try {
      await ref.read(taxonomyRepositoryProvider).reorder(reorderedIds);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _localOrderIds = null);
        _showError(error);
      }
    }
  }

  /// 用本地已确认顺序合并数据库最新内容，避免落库通知触发二次位移。
  List<TaxonomyEntry> _applyLocalOrder(List<TaxonomyEntry> entries) {
    // 当前本地显示顺序。
    final List<String>? localOrderIds = _localOrderIds;
    if (localOrderIds == null) {
      return entries;
    }
    // 数据库最新分类标签索引。
    final Map<String, TaxonomyEntry> entriesById = <String, TaxonomyEntry>{
      for (final TaxonomyEntry entry in entries) entry.id: entry,
    };
    // 按本地顺序生成的分类标签。
    final List<TaxonomyEntry> ordered = <TaxonomyEntry>[
      for (final String id in localOrderIds)
        if (entriesById.remove(id) case final TaxonomyEntry entry) entry,
    ];
    // 本次打开弹窗后新增、但尚未进入本地顺序的分类标签。
    final Iterable<TaxonomyEntry> appended = entries.where(
      (TaxonomyEntry entry) => entriesById.containsKey(entry.id),
    );
    return <TaxonomyEntry>[...ordered, ...appended];
  }

  /// 处理分类标签行菜单操作。
  void _handleRowAction(_TaxonomyRowAction action, TaxonomyEntry entry) {
    switch (action) {
      case _TaxonomyRowAction.rename:
        _startRenaming(entry);
      case _TaxonomyRowAction.delete:
        _delete(entry);
    }
  }

  /// 构建管理弹窗。
  @override
  Widget build(BuildContext context) {
    // 当前分类标签流。
    final AsyncValue<List<TaxonomyEntry>> entries = ref.watch(
      taxonomyEntriesProvider((widget.module, widget.kind)),
    );
    // 管理器主体。
    final Widget body = entries.when(
      data: (List<TaxonomyEntry> remoteEntries) =>
          _buildManager(_applyLocalOrder(remoteEntries)),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace stackTrace) =>
          Center(child: Text('读取失败：$error')),
    );
    // 当前是否使用移动端全屏布局。
    final bool mobileFullscreen =
        !OmniBreakpoint.isDesktopPlatform(Theme.of(context).platform) &&
        OmniBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
    if (mobileFullscreen) {
      return Dialog.fullscreen(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildMobileHeader(),
              Divider(color: OmniColors.of(context).line),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(OmniSpacing.md),
                  child: body,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return OmniDialogScaffold(
      title: _title,
      width: 500,
      height: 560,
      child: body,
    );
  }

  /// 构建移动端管理器标题栏。
  Widget _buildMobileHeader() {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: OmniSpacing.md),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建分类标签管理内容。
  Widget _buildManager(List<TaxonomyEntry> entries) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: Alignment.centerRight,
          child: OmniButton(
            label: '新增$_typeName',
            icon: Icons.add_rounded,
            variant: OmniButtonVariant.secondary,
            onPressed: _adding ? null : _startAdding,
          ),
        ),
        const SizedBox(height: OmniSpacing.sm),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(OmniRadius.panel),
            ),
            foregroundDecoration: BoxDecoration(
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(OmniRadius.panel),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_adding) _buildAddEditor(entries),
                Expanded(
                  child: entries.isEmpty
                      ? _buildEmptyState()
                      : _buildList(entries),
                ),
              ],
            ),
          ),
        ),
        if (entries.length > 1) ...<Widget>[
          const SizedBox(height: OmniSpacing.xs),
        ],
      ],
    );
  }

  /// 构建无分类标签时的提示。
  Widget _buildEmptyState() {
    return Center(
      child: Text(
        _adding ? '填写名称后添加第一项' : '还没有$_typeName',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  /// 构建可拖拽分类标签列表。
  Widget _buildList(List<TaxonomyEntry> entries) {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: entries.length,
      proxyDecorator: _buildDragProxy,
      onReorderItem: (int oldIndex, int newIndex) =>
          _reorder(entries, oldIndex, newIndex),
      itemBuilder: (BuildContext context, int index) {
        // 当前分类标签。
        final TaxonomyEntry entry = entries[index];
        return _buildEntry(entry, index, index == entries.length - 1);
      },
    );
  }

  /// 构建不参与辅助功能树的拖拽代理，避免 Windows 重复挂载整行语义节点。
  Widget _buildDragProxy(Widget child, int index, Animation<double> animation) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return ExcludeSemantics(
      child: Material(
        color: colors.paper,
        elevation: 2,
        shadowColor: colors.ink.withValues(alpha: 0.12),
        child: child,
      ),
    );
  }

  /// 构建新增分类标签编辑行。
  Widget _buildAddEditor(List<TaxonomyEntry> entries) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OmniSpacing.sm),
      decoration: BoxDecoration(
        color: colors.brandSoft.withValues(alpha: 0.65),
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildColorPicker(
            color: _newColor,
            onSelected: (Color color) => setState(() => _newColor = color),
          ),
          const SizedBox(width: OmniSpacing.xs),
          Expanded(
            child: TextField(
              controller: _nameController,
              autofocus: true,
              enabled: !_savingName,
              decoration: InputDecoration(
                labelText: '$_typeName名称',
                errorText: _nameError,
              ),
              onSubmitted: (_) => _add(entries),
            ),
          ),
          const SizedBox(width: OmniSpacing.xs),
          _buildNameActions(onSave: () => _add(entries), saveLabel: '添加'),
        ],
      ),
    );
  }

  /// 构建单个分类标签。
  Widget _buildEntry(TaxonomyEntry entry, int index, bool isLast) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 当前行是否正在重命名。
    final bool editing = _editingId == entry.id;
    return Container(
      key: ValueKey<String>(entry.id),
      decoration: BoxDecoration(
        color: editing
            ? colors.brandSoft.withValues(alpha: 0.65)
            : colors.paper,
        border: isLast ? null : Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Row(
              children: <Widget>[
                ReorderableDragStartListener(
                  index: index,
                  child: Semantics(
                    label: '拖动排序',
                    button: true,
                    child: ExcludeSemantics(
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(Icons.drag_indicator_rounded, size: 18),
                      ),
                    ),
                  ),
                ),
                _buildColorPicker(
                  color: Color(entry.colorValue),
                  onSelected: (Color color) => _changeColor(entry, color),
                ),
                const SizedBox(width: OmniSpacing.sm),
                Expanded(
                  child: InkWell(
                    onTap: () => _startRenaming(entry),
                    borderRadius: BorderRadius.circular(OmniRadius.control),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        entry.name,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w400),
                      ),
                    ),
                  ),
                ),
                PopupMenuButton<_TaxonomyRowAction>(
                  tooltip: '更多操作',
                  onSelected: (_TaxonomyRowAction action) =>
                      _handleRowAction(action, entry),
                  itemBuilder: (BuildContext popupContext) =>
                      <PopupMenuEntry<_TaxonomyRowAction>>[
                        const PopupMenuItem<_TaxonomyRowAction>(
                          value: _TaxonomyRowAction.rename,
                          child: Text('重命名'),
                        ),
                        PopupMenuItem<_TaxonomyRowAction>(
                          value: _TaxonomyRowAction.delete,
                          child: Text(
                            '删除$_typeName',
                            style: TextStyle(color: colors.danger),
                          ),
                        ),
                      ],
                ),
                const SizedBox(width: OmniSpacing.xxs),
              ],
            ),
          ),
          if (editing) _buildRenameEditor(entry),
        ],
      ),
    );
  }

  /// 构建重命名编辑区。
  Widget _buildRenameEditor(TaxonomyEntry entry) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        44,
        OmniSpacing.sm,
        OmniSpacing.sm,
        OmniSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _nameController,
              autofocus: true,
              enabled: !_savingName,
              decoration: InputDecoration(
                labelText: '$_typeName名称',
                errorText: _nameError,
              ),
              onSubmitted: (_) => _rename(entry),
            ),
          ),
          const SizedBox(width: OmniSpacing.xs),
          _buildNameActions(onSave: () => _rename(entry), saveLabel: '保存'),
        ],
      ),
    );
  }

  /// 构建名称编辑操作。
  Widget _buildNameActions({
    required VoidCallback onSave,
    required String saveLabel,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: OmniSpacing.xxs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          OmniButton(
            label: '取消',
            variant: OmniButtonVariant.text,
            onPressed: _savingName ? null : _cancelEditing,
          ),
          const SizedBox(width: OmniSpacing.xxs),
          OmniButton(
            label: saveLabel,
            onPressed: _savingName ? null : onSave,
            loading: _savingName,
          ),
        ],
      ),
    );
  }

  /// 构建锚定在色块上的颜色选择浮层。
  Widget _buildColorPicker({
    required Color color,
    required ValueChanged<Color> onSelected,
  }) {
    return PopupMenuButton<Color>(
      tooltip: '修改颜色',
      onSelected: onSelected,
      itemBuilder: (BuildContext popupContext) => <PopupMenuEntry<Color>>[
        PopupMenuItem<Color>(
          enabled: false,
          padding: const EdgeInsets.all(OmniSpacing.sm),
          child: _ColorPalette(colors: _colors, selectedColor: color),
        ),
      ],
      child: Semantics(
        button: true,
        label: '修改颜色',
        child: SizedBox(
          width: 36,
          height: 44,
          child: Center(
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 颜色选择浮层内容。
class _ColorPalette extends StatelessWidget {
  /// 可选颜色名称和色值。
  final List<(String, Color)> colors;

  /// 当前颜色。
  final Color selectedColor;

  /// 创建颜色选择浮层。
  const _ColorPalette({required this.colors, required this.selectedColor});

  /// 构建紧凑颜色网格。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      child: Wrap(
        spacing: OmniSpacing.xs,
        runSpacing: OmniSpacing.xs,
        children: colors
            .map(((String, Color) item) {
              // 当前颜色是否被选中。
              final bool selected =
                  item.$2.toARGB32() == selectedColor.toARGB32();
              return Tooltip(
                message: item.$1,
                child: InkWell(
                  borderRadius: BorderRadius.circular(OmniRadius.pill),
                  onTap: () => Navigator.of(context).pop(item.$2),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: item.$2,
                      ),
                      child: selected
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 16,
                            )
                          : null,
                    ),
                  ),
                ),
              );
            })
            .toList(growable: false),
      ),
    );
  }
}
