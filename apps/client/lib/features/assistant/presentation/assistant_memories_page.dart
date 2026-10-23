import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 当前服务器的显式记忆管理页面。
class AssistantMemoriesPage extends ConsumerStatefulWidget {
  /// 创建可审阅和删除的记忆页。
  const AssistantMemoriesPage({super.key});

  /// 创建当前服务器的页面状态。
  @override
  ConsumerState<AssistantMemoriesPage> createState() =>
      _AssistantMemoriesPageState();
}

/// 页面操作绑定固定仓储，换服后旧弹窗不能写入。
class _AssistantMemoriesPageState extends ConsumerState<AssistantMemoriesPage> {
  /// 服务端记忆列表。
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];

  /// 当前是否加载或保存。
  bool _busy = false;

  /// 可见的接口错误。
  String? _error;

  /// 页面当前绑定的仓储，认证变化会重新加载。
  AssistantRepository? _repository;

  /// 按相同服务器读取最新事实。
  Future<void> _load() async {
    if (_busy) return;
    // 固定请求使用的服务器代次。
    final AssistantRepository repository = ref.read(
      assistantRepositoryProvider,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 返回完整分页的首批记忆。
      final Map<String, dynamic> result = await repository.request(
        'GET',
        '/memories',
      );
      // 记忆分页由同一数据源游标延续，管理页不能漏掉旧条目。
      final List<Map<String, dynamic>> items = assistantItems(result['items']);
      // 游标必须前进，异常时停止读取。
      final Set<String> seen = <String>{};
      // 当前下一页身份。
      String? next = result['nextCursor'] as String?;
      while (next != null && next.isNotEmpty) {
        if (!seen.add(next)) throw const ApiFailure('记忆分页异常，请刷新');
        // 只读拉取下一页，不触发模型或记忆变更。
        final Map<String, dynamic> page = await repository.request(
          'GET',
          '/memories?cursor=${Uri.encodeQueryComponent(next)}',
        );
        items.addAll(assistantItems(page['items']));
        next = page['nextCursor'] as String?;
      }
      if (mounted && repository.isCurrent) {
        setState(() => _items = items);
      }
    } catch (error) {
      if (mounted && repository.isCurrent) {
        setState(() => _error = error is ApiFailure ? error.message : '无法读取记忆');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用修订号提交变更，冲突后需重新核对。
  Future<void> _mutate(String method, String path, {Object? data}) async {
    if (_busy || _repository?.isCurrent != true) return;
    // 固定弹窗所属服务器。
    final AssistantRepository repository = _repository!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await repository.request(method, path, data: data);
    } catch (error) {
      if (mounted && repository.isCurrent) {
        setState(() => _error = error is ApiFailure ? error.message : '记忆操作失败');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && repository.isCurrent && _error == null) await _load();
  }

  /// 保存编辑器返回的固定草稿，弹窗生命周期拥有输入控制器。
  Future<void> _edit([Map<String, dynamic>? memory]) async {
    // 弹窗打开时固定服务器。
    final AssistantRepository? repository = _repository;
    // 只有明确保存才返回提交参数。
    final Map<String, dynamic>? draft =
        await showOmniDialog<Map<String, dynamic>>(
          context: context,
          builder: (BuildContext context) =>
              _AssistantMemoryEditor(memory: memory),
        );
    if (draft != null &&
        mounted &&
        identical(repository, _repository) &&
        repository?.isCurrent == true) {
      await _mutate(
        memory == null ? 'POST' : 'PATCH',
        memory == null ? '/memories' : '/memories/${memory['id']}',
        data: draft,
      );
    }
  }

  /// 单条删除或清空均明确展示影响。
  Future<void> _delete([Map<String, dynamic>? memory]) async {
    // 弹窗不能跨服务器继续授权。
    final AssistantRepository? repository = _repository;
    // 明确删除已保存记忆，不只是隐藏卡片。
    final bool confirmed =
        await showOmniDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => OmniDialogScaffold(
            title: memory == null ? '清空全部记忆' : '删除记忆',
            actions: <Widget>[
              OmniButton(
                label: '取消',
                variant: OmniButtonVariant.secondary,
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              OmniButton(
                label: '删除',
                variant: OmniButtonVariant.danger,
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
            child: Text(
              memory == null ? '删除当前服务器的全部助手记忆，后续对话不再使用。' : '删除这条记忆，后续对话不再使用。',
            ),
          ),
        ) ??
        false;
    if (confirmed &&
        mounted &&
        identical(repository, _repository) &&
        repository?.isCurrent == true) {
      await _mutate(
        'DELETE',
        memory == null ? '/memories' : '/memories/${memory['id']}',
        data: memory == null
            ? null
            : <String, dynamic>{'revision': memory['revision']},
      );
    }
  }

  /// 构建独立记忆页，列表不包含自动提炼的隐藏记忆。
  @override
  Widget build(BuildContext context) {
    // 认证变化时丢弃旧服务器的可写列表。
    final AssistantRepository repository = ref.watch(
      assistantRepositoryProvider,
    );
    if (!identical(_repository, repository)) {
      _repository = repository;
      _items = <Map<String, dynamic>>[];
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) _load();
      });
    }
    return Scaffold(
      appBar: AppBar(title: const Text('助手记忆')),
      body: ListView(
        padding: const EdgeInsets.all(OmniSpacing.md),
        children: <Widget>[
          const Text('只保存你明确要求记住的内容。停用或删除后，后续上下文将不再使用。'),
          const SizedBox(height: OmniSpacing.md),
          Wrap(
            spacing: OmniSpacing.sm,
            children: <Widget>[
              OmniButton(
                label: '新增记忆',
                onPressed: _busy ? null : () => _edit(),
              ),
              OmniButton(
                label: '刷新',
                variant: OmniButtonVariant.secondary,
                onPressed: _busy ? null : _load,
              ),
              OmniButton(
                label: '清空记忆',
                variant: OmniButtonVariant.danger,
                onPressed: _busy || _items.isEmpty ? null : () => _delete(),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: OmniSpacing.sm),
              child: Text(_error!),
            ),
          if (!_busy && _items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(OmniSpacing.lg),
              child: Text('还没有保存的记忆。'),
            ),
          for (final Map<String, dynamic> memory in _items)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpacing.md),
              child: OmniPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SelectableText(memory['content'] as String? ?? ''),
                    Text(
                      '${memory['category'] ?? ''}${memory['expiresAt'] == null ? '' : ' · 有效至 ${memory['expiresAt']}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Wrap(
                      spacing: OmniSpacing.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        OmniSwitch(
                          value: memory['enabled'] == true,
                          onChanged: _busy
                              ? null
                              : (bool enabled) => _mutate(
                                  'PATCH',
                                  '/memories/${memory['id']}',
                                  data: <String, dynamic>{
                                    'revision': memory['revision'],
                                    'content': memory['content'],
                                    'category': memory['category'],
                                    'expiresAt': memory['expiresAt'],
                                    'enabled': enabled,
                                  },
                                ),
                        ),
                        Text(memory['enabled'] == true ? '已启用' : '已停用'),
                        OmniButton(
                          label: '编辑',
                          variant: OmniButtonVariant.secondary,
                          onPressed: _busy ? null : () => _edit(memory),
                        ),
                        OmniButton(
                          label: '删除',
                          variant: OmniButtonVariant.text,
                          onPressed: _busy ? null : () => _delete(memory),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 弹窗动画结束时才销毁控制器，避免保存后重建已释放输入。
class _AssistantMemoryEditor extends StatefulWidget {
  /// 打开时固定的记忆事实与修订号。
  final Map<String, dynamic>? memory;

  /// 创建独立编辑器。
  const _AssistantMemoryEditor({this.memory});

  /// 创建原生表单状态。
  @override
  State<_AssistantMemoryEditor> createState() => _AssistantMemoryEditorState();
}

/// 只保留弹窗草稿，不直接提交业务或访问认证仓储。
class _AssistantMemoryEditorState extends State<_AssistantMemoryEditor> {
  /// 记忆正文草稿。
  late final TextEditingController _content;

  /// 保留已有类别的持久值。
  late final TextEditingController _category;

  /// 原有效期保持精确时刻，重新选日期按本机当天结束。
  DateTime? _expiry;

  /// 从打开时的固定快照初始化。
  @override
  void initState() {
    super.initState();
    _content = TextEditingController(
      text: widget.memory?['content'] as String? ?? '',
    );
    _category = TextEditingController(
      text: widget.memory?['category'] as String? ?? 'preference',
    );
    _expiry = DateTime.tryParse(widget.memory?['expiresAt'] as String? ?? '')
        ?.toLocal();
  }

  /// 控制器跟随真实弹窗卸载，不早于退出动画。
  @override
  void dispose() {
    _content.dispose();
    _category.dispose();
    super.dispose();
  }

  /// 返回精确UTC截止时刻或长期空值。
  void _save() {
    if (_content.text.trim().isEmpty) return;
    Navigator.of(context).pop(<String, dynamic>{
      'content': _content.text.trim(),
      'category': _category.text.trim().isEmpty
          ? 'preference'
          : _category.text.trim(),
      'expiresAt': _expiry?.toUtc().toIso8601String(),
      'enabled': widget.memory?['enabled'] != false,
      if (widget.memory != null) 'revision': widget.memory!['revision'],
    });
  }

  /// 复用统一日期选择器，不要求用户填写协议格式。
  @override
  Widget build(BuildContext context) => OmniDialogScaffold(
    title: widget.memory == null ? '新增记忆' : '编辑记忆',
    actions: <Widget>[
      OmniButton(
        label: '取消',
        variant: OmniButtonVariant.secondary,
        onPressed: () => Navigator.of(context).pop(),
      ),
      OmniButton(label: '保存', onPressed: _save),
    ],
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OmniTextField(
            controller: _content,
            minLines: 3,
            maxLines: 8,
            maxLength: 2000,
            decoration: const InputDecoration(labelText: '需要记住的内容'),
          ),
          const SizedBox(height: OmniSpacing.sm),
          const Text('有效期（可选）'),
          const SizedBox(height: OmniSpacing.xs),
          Wrap(
            spacing: OmniSpacing.sm,
            runSpacing: OmniSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              OmniDatePickerButton(
                value: _expiry,
                initialDate: _expiry ?? DateTime.now(),
                firstDate: DateTime(1900),
                lastDate: DateTime(2200),
                label: _expiry == null
                    ? '长期有效'
                    : '${_expiry!.year}-${_expiry!.month.toString().padLeft(2, '0')}-${_expiry!.day.toString().padLeft(2, '0')}',
                onChanged: (DateTime date) => setState(
                  () => _expiry = DateTime(
                    date.year,
                    date.month,
                    date.day,
                    23,
                    59,
                    59,
                    999,
                  ),
                ),
              ),
              if (_expiry != null)
                OmniButton(
                  label: '设为长期',
                  variant: OmniButtonVariant.text,
                  onPressed: () => setState(() => _expiry = null),
                ),
            ],
          ),
          const Text('选择日期后，有效至该日期在本机时区的当天结束。'),
          const SizedBox(height: OmniSpacing.sm),
          OmniTextField(
            controller: _category,
            decoration: const InputDecoration(
              labelText: '类别',
              helperText: '例如 preference、goal、profile',
            ),
          ),
        ],
      ),
    ),
  );
}
