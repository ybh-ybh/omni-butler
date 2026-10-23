import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/features/notes/presentation/note_markdown_text.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/sync/sync_providers.dart';
import 'package:omni_butler/features/assistant/data/assistant_cache.dart';
import 'package:omni_butler/features/assistant/data/assistant_chat_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_cards.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 两端共用助手入口，认证变化时销毁旧服务器页面。
class AssistantPage extends ConsumerWidget {
  /// 创建独立聊天页面。
  const AssistantPage({super.key});

  /// 固定认证数据源，旧服务器响应不能进入新会话。
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 已恢复的当前设备身份。
    final AsyncValue<SyncSession?> session = ref.watch(authControllerProvider);
    if (session.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    // 服务器地址包含路径前缀，不能仅使用域名隔离。
    final String? scope = session.value == null
        ? null
        : AssistantCache.scopeFor(
            session.value!.apiBaseUrl,
            session.value!.identity.id,
          );
    // 原仓储代次同时隔离同服务器重新登录。
    final AssistantRepository repository = ref.watch(
      assistantRepositoryProvider,
    );
    return _AssistantChatBody(
      key: ValueKey<String>('$scope:${repository.generation}'),
      scope: scope,
      repository: session.value == null ? null : repository,
    );
  }
}

/// 页面状态只管理对话显示和输入，不执行模型返回的代码。
class _AssistantChatBody extends ConsumerStatefulWidget {
  /// 当前服务器作用域。
  final String? scope;

  /// 固定代次的接口。
  final AssistantRepository? repository;

  /// 创建认证隔离的页面。
  const _AssistantChatBody({
    required this.scope,
    required this.repository,
    super.key,
  });

  /// 创建页面生命周期。
  @override
  ConsumerState<_AssistantChatBody> createState() => _AssistantChatBodyState();
}

/// 文字输入和服务器任务可分别恢复。
class _AssistantChatBodyState extends ConsumerState<_AssistantChatBody> {
  /// 输入控制器。
  final TextEditingController _input = TextEditingController();

  /// 列表滚动控制器。
  final ScrollController _scroll = ScrollController();

  /// 输入焦点。
  final FocusNode _focus = FocusNode();

  /// 固定服务器的聊天控制器。
  late final AssistantChatController _chat;

  /// 加载后只同步一次草稿，避免流事件打断输入法。
  bool _draftLoaded = false;

  /// 当前输入框所属的会话，切换时恢复各自草稿。
  String? _draftConversation;

  /// 初始化缓存与同一服务器的活动任务。
  @override
  void initState() {
    super.initState();
    _chat = AssistantChatController(
      repository: widget.repository,
      scope: widget.scope,
      cache: ref.read(assistantCacheProvider),
      catchUp: () async {
        // 写前检查当前本机业务数据上传，离线时不能绕过。
        final runtime = ref.read(syncRuntimeProvider);
        if (runtime == null) throw const ApiFailure('同步运行时尚未就绪，请先连接同步服务器');
        if (widget.repository?.isCurrent != true) {
          throw const ApiFailure('服务器已切换，请重新打开助手');
        }
        await runtime.catchUp(timeout: const Duration(seconds: 30));
        if (widget.repository?.isCurrent != true) {
          throw const ApiFailure('服务器已切换，请重新打开助手');
        }
      },
    );
    _chat.addListener(_changed);
    unawaited(_chat.initialize());
  }

  /// 只在接近末尾时跟随流式文字，不打断历史阅读。
  void _changed() {
    if (!mounted) return;
    if (!_chat.loading &&
        (!_draftLoaded || _draftConversation != _chat.conversationId)) {
      _input.text = _chat.draft;
      _draftLoaded = true;
      _draftConversation = _chat.conversationId;
    }
    setState(() {});
    if (!_scroll.hasClients || _scroll.position.extentAfter < 160) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  /// 页面离开不停止后台任务，只结束事件订阅。
  @override
  void dispose() {
    _chat.removeListener(_changed);
    _chat.dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 发送后仅在服务器接收成功时清空输入。
  Future<void> _send() async {
    _chat.setDraft(_input.text);
    await _chat.send();
    if (!mounted) return;
    if (_chat.pending == null && _chat.draft.isEmpty) _input.clear();
  }

  /// 输入控制器由弹窗状态管理，退出动画完成后再释放。
  Future<String?> _askText(String title, String initial) =>
      showOmniDialog<String>(
        context: context,
        builder: (BuildContext context) =>
            _AssistantRenameDialog(title: title, initial: initial),
      );

  /// 会话删除需要明确说明仅删除聊天。
  Future<void> _deleteConversation() async {
    // 明确删除聊天不会撤销业务数据。
    final bool confirmed =
        await showOmniDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => OmniDialogScaffold(
            title: '删除对话',
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
            child: const Text('删除本次聊天记录，停止尚未执行的计划。已保存的业务记录会保留。'),
          ),
        ) ??
        false;
    if (confirmed) await _chat.delete();
  }

  /// 窄屏通过统一对话框切换历史。
  Future<void> _showHistory() async {
    await showOmniDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => OmniDialogScaffold(
        title: '历史对话',
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: _history(
            onSelected: (String id) {
              Navigator.of(dialogContext).pop();
              unawaited(_chat.select(id));
            },
          ),
        ),
      ),
    );
  }

  /// 历史列表保留完整名称，可按列表自然滚动。
  Widget _history({ValueChanged<String>? onSelected}) => Column(
    children: <Widget>[
      Padding(
        padding: const EdgeInsets.all(OmniSpacing.md),
        child: OmniButton(
          label: '新对话',
          icon: Icons.add,
          onPressed: _chat.connected && !_chat.busy ? _chat.create : null,
        ),
      ),
      Expanded(
        child: ListView(
          children: <Widget>[
            for (final Map<String, dynamic> conversation in _chat.conversations)
              ListTile(
                selected: conversation['id'] == _chat.conversationId,
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(conversation['title'] as String? ?? '对话'),
                onTap: _chat.busy
                    ? null
                    : () =>
                          (onSelected ??
                          (String id) => unawaited(_chat.select(id)))(
                            conversation['id'] as String,
                          ),
              ),
          ],
        ),
      ),
    ],
  );

  /// 标题栏在窄屏可换行，不压缩主要操作热区。
  Widget _header(bool wide) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: OmniSpacing.md,
      vertical: OmniSpacing.xs,
    ),
    child: Row(
      children: <Widget>[
        if (!wide)
          OmniIconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回首页',
            onPressed: () => context.go('/home'),
          ),
        if (!wide)
          OmniIconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史对话',
            onPressed: _showHistory,
          ),
        Expanded(
          child: Text(
            '知序助手',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (_chat.conversationId != null && _chat.connected) ...<Widget>[
          OmniIconButton(
            icon: const Icon(Icons.drive_file_rename_outline),
            tooltip: '重命名对话',
            onPressed: _chat.busy
                ? null
                : () async {
                    // 当前会话标题来自服务器列表。
                    final String title =
                        _chat.conversations
                                .where(
                                  (Map<String, dynamic> item) =>
                                      item['id'] == _chat.conversationId,
                                )
                                .firstOrNull?['title']
                            as String? ??
                        '对话';
                    // 明确的新名称。
                    final String? value = await _askText('重命名对话', title);
                    if (value != null) await _chat.rename(value);
                  },
          ),
          OmniIconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除对话',
            onPressed: _chat.busy ? null : _deleteConversation,
          ),
        ],
        OmniIconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: '助手设置',
          onPressed: () => context.go('/settings?section=ai'),
        ),
      ],
    ),
  );

  /// 输入区维持底部稳定，不随消息滚动。
  Widget _composer(bool enabled) => Padding(
    padding: const EdgeInsets.all(OmniSpacing.md),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_chat.draftReference != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
            child: Wrap(
              spacing: OmniSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text('编辑目标：${_chat.draftReference!['label'] ?? '所选记录'}'),
                OmniButton(
                  label: '取消定位',
                  variant: OmniButtonVariant.text,
                  onPressed: _chat.clearDraftReference,
                ),
              ],
            ),
          ),
        if (_chat.run?['errorMessage'] is String)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
            child: Text(
              _chat.run!['errorMessage'] as String,
              style: TextStyle(color: OmniColors.of(context).danger),
            ),
          ),
        if (_chat.run != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
            child: Wrap(
              spacing: OmniSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(
                  _chat.run?['requiresTakeover'] == true && _chat.active
                      ? '任务由其他设备处理，请先接管'
                      : assistantStatusLabel(_chat.run!['status'] as String?),
                ),
                if (_chat.run?['canUndo'] == true)
                  OmniButton(
                    label: '撤销新增',
                    variant: OmniButtonVariant.text,
                    onPressed: !_chat.busy && enabled ? _chat.undo : null,
                  ),
                if (_chat.active)
                  OmniButton(
                    label: '停止',
                    variant: OmniButtonVariant.text,
                    onPressed: !_chat.busy && _chat.connected && !_chat.offline
                        ? _chat.stop
                        : null,
                  ),
                if (_chat.run?['requiresTakeover'] == true &&
                    _chat.run?['status'] != 'succeeded' &&
                    _chat.run?['status'] != 'cancelled')
                  OmniButton(
                    label: '在此设备接管',
                    variant: OmniButtonVariant.text,
                    onPressed: !_chat.busy && _chat.connected && !_chat.offline
                        ? _chat.takeover
                        : null,
                  ),
                if (<String>{
                  'failed',
                  'submissionUnknown',
                }.contains(_chat.run!['status']))
                  OmniButton(
                    label: '重试任务',
                    variant: OmniButtonVariant.text,
                    onPressed: !_chat.busy && enabled ? _chat.retry : null,
                  ),
              ],
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: OmniTextField(
                key: const ValueKey<String>('assistant-input'),
                controller: _input,
                focusNode: _focus,
                minLines: 1,
                maxLines: 5,
                maxLength: 20000,
                enabled: enabled && !_chat.loading,
                onChanged: _chat.setDraft,
                decoration: const InputDecoration(
                  hintText: '记录想法、查询数据，或整理这一周…',
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: OmniSpacing.sm),
            OmniButton(
              label: _chat.pending == null ? '发送' : '恢复发送',
              icon: Icons.arrow_upward,
              loading: _chat.busy,
              onPressed:
                  enabled &&
                      !_chat.busy &&
                      (!_chat.active ||
                          _chat.run?['requiresTakeover'] != true) &&
                      (_chat.pending != null ||
                          !_chat.active ||
                          <String>{
                            'waitingInput',
                            'waitingConfirmation',
                          }.contains(_chat.run?['status']))
                  ? _send
                  : null,
            ),
          ],
        ),
        const SizedBox(height: OmniSpacing.xs),
        Text(
          _chat.offline
              ? '当前仅显示本机缓存；恢复连接后核实服务器状态。'
              : '仅查询服务器已接收的数据。未发布笔记草稿不会自动发送。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  /// 消息正文采用可选择纯文字，操作只由受控卡片提供。
  Widget _message(Map<String, dynamic> message, bool enabled) {
    // 用户消息与助手消息使用位置和留白区别。
    final bool user = message['role'] == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpacing.lg),
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 760),
          padding: const EdgeInsets.all(OmniSpacing.md),
          decoration: user
              ? BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                user ? '你' : '知序',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: OmniSpacing.xs),
              SelectableText.rich(
                NoteMarkdownText.span(
                  message['content'] as String? ?? '',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (!user &&
                  message['_streaming'] != true &&
                  (message['content'] as String? ?? '').trim().isNotEmpty)
                OmniButton(
                  label: '保存为笔记',
                  variant: OmniButtonVariant.text,
                  onPressed:
                      enabled &&
                          !_chat.busy &&
                          !_chat.active &&
                          _chat.pending == null &&
                          (message['content'] as String).length <= 19000
                      ? () {
                          _input.text =
                              '请把以下内容完整保存为一篇笔记：\n\n${message['content']}';
                          _chat.setDraft(_input.text, clearReference: true);
                          unawaited(_send());
                        }
                      : null,
                ),
              for (final Map<String, dynamic> card in assistantItems(
                message['cards'],
              ))
                AssistantMessageCard(
                  card: card,
                  enabled: enabled && !_chat.busy && _chat.pending == null,
                  onEditReference: (_chat.active || _chat.pending != null)
                      ? null
                      : (Map<String, dynamic> reference) {
                          _input.text = '请修改「${reference['label'] ?? '这条记录'}」：';
                          _chat.setDraft(_input.text, reference: reference);
                          _focus.requestFocus();
                        },
                  onChoice: (String value, Map<String, dynamic> selection) {
                    _input.text = value;
                    _chat.setDraft(value);
                    unawaited(
                      _chat.send(selection: selection).then((_) {
                        if (mounted && _chat.pending == null) _input.clear();
                      }),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 宽屏双栏、窄屏独立对话，并保留加载和设置错误状态。
  @override
  Widget build(BuildContext context) {
    // 后端助手开关与独立模型配置。
    final AsyncValue<Map<String, dynamic>?> settings = ref.watch(
      assistantSettingsProvider,
    );
    // 只有服务器确认开启且当前数据源有效才可提交消息。
    final bool enabled =
        _chat.connected &&
        !_chat.offline &&
        !_chat.loading &&
        settings.value?['enabled'] == true;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 大字号时更早折叠会话列表。
        final bool wide =
            constraints.maxWidth >=
            900 * MediaQuery.textScalerOf(context).scale(14) / 14;
        return Row(
          children: <Widget>[
            if (wide) SizedBox(width: 240, child: _history()),
            if (wide) const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: <Widget>[
                  _header(wide),
                  const Divider(height: 1),
                  if (_chat.connected && settings.isLoading)
                    const LinearProgressIndicator(),
                  if (_chat.connected &&
                      !settings.isLoading &&
                      (settings.hasError || settings.value?['enabled'] != true))
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * .22,
                      ),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(OmniSpacing.md),
                          child: Wrap(
                            spacing: OmniSpacing.sm,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: <Widget>[
                              Text(
                                settings.hasError
                                    ? '无法读取助手设置，请重试'
                                    : '请在 AI 设置中选择助手模型并开启助手。',
                              ),
                              OmniButton(
                                label: 'AI 设置',
                                variant: OmniButtonVariant.secondary,
                                onPressed: () =>
                                    context.go('/settings?section=ai'),
                              ),
                              if (settings.hasError)
                                OmniButton(
                                  label: '重试',
                                  variant: OmniButtonVariant.text,
                                  onPressed: () =>
                                      ref.invalidate(assistantSettingsProvider),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_chat.error != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * .22,
                      ),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(OmniSpacing.sm),
                          child: Wrap(
                            spacing: OmniSpacing.sm,
                            children: <Widget>[
                              Text(
                                _chat.error!,
                                style: TextStyle(
                                  color: OmniColors.of(context).danger,
                                ),
                              ),
                              OmniButton(
                                label: '刷新状态',
                                variant: OmniButtonVariant.text,
                                onPressed: _chat.connected
                                    ? _chat.refresh
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: _chat.loading
                        ? const Center(child: CircularProgressIndicator())
                        : _chat.messages.isEmpty && _chat.plan == null
                        ? SingleChildScrollView(
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(OmniSpacing.lg),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Icon(
                                      Icons.auto_awesome_outlined,
                                      size: 40,
                                      color: OmniColors.of(context).muted,
                                    ),
                                    const SizedBox(height: OmniSpacing.lg),
                                    Text(
                                      '把事情交代给知序',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall,
                                    ),
                                    const SizedBox(height: OmniSpacing.sm),
                                    const Text(
                                      '添加一条记录，整理最近的想法，或回顾这一周。',
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: OmniSpacing.md),
                                    Wrap(
                                      spacing: OmniSpacing.sm,
                                      children: <Widget>[
                                        for (final String example in <String>[
                                          '我今天的时间花在哪里？',
                                          '帮我做本周总结',
                                        ])
                                          OmniButton(
                                            label: example,
                                            variant:
                                                OmniButtonVariant.secondary,
                                            onPressed: enabled
                                                ? () {
                                                    _input.text = example;
                                                    _chat.setDraft(example);
                                                    _focus.requestFocus();
                                                  }
                                                : null,
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        : ListView(
                            controller: _scroll,
                            padding: EdgeInsets.symmetric(
                              horizontal: constraints.maxWidth > 1100
                                  ? 40
                                  : OmniSpacing.md,
                              vertical: OmniSpacing.lg,
                            ),
                            children: <Widget>[
                              for (final Map<String, dynamic> message
                                  in _chat.messages)
                                _message(message, enabled),
                              if (_chat.plan != null &&
                                  _chat.run?['status'] == 'waitingConfirmation')
                                AssistantPlanCard(
                                  plan: _chat.plan!,
                                  enabled:
                                      enabled &&
                                      !_chat.busy &&
                                      !_chat.offline &&
                                      _chat.pending == null &&
                                      _chat.draft.trim().isEmpty &&
                                      _chat.run?['requiresTakeover'] != true,
                                  onDecision: (String value) =>
                                      unawaited(_chat.decide(value)),
                                  onEdit: () {
                                    _input.text = '修改方案：';
                                    _chat.setDraft(
                                      _input.text,
                                      clearReference: true,
                                    );
                                    _focus.requestFocus();
                                  },
                                ),
                            ],
                          ),
                  ),
                  if (_chat.busy) const LinearProgressIndicator(),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .5,
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: _composer(enabled),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 简短会话名称编辑器，不持有接口或业务写权限。
class _AssistantRenameDialog extends StatefulWidget {
  /// 弹窗标题。
  final String title;

  /// 当前会话名称。
  final String initial;

  /// 创建受控重命名弹窗。
  const _AssistantRenameDialog({required this.title, required this.initial});

  /// 创建控制器生命周期。
  @override
  State<_AssistantRenameDialog> createState() => _AssistantRenameDialogState();
}

/// 控制器与弹窗卸载保持一致。
class _AssistantRenameDialogState extends State<_AssistantRenameDialog> {
  /// 当前输入草稿。
  late final TextEditingController _editor;

  /// 创建独立输入控制器。
  @override
  void initState() {
    super.initState();
    _editor = TextEditingController(text: widget.initial);
  }

  /// 跟随真实弹窗卸载销毁。
  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  /// 只返回非空名称，不在弹窗内调用服务器。
  void _save() {
    if (_editor.text.trim().isNotEmpty) {
      Navigator.of(context).pop(_editor.text.trim());
    }
  }

  /// 构建统一名称输入。
  @override
  Widget build(BuildContext context) => OmniDialogScaffold(
    title: widget.title,
    actions: <Widget>[
      OmniButton(
        label: '取消',
        variant: OmniButtonVariant.text,
        onPressed: () => Navigator.of(context).pop(),
      ),
      OmniButton(label: '保存', onPressed: _save),
    ],
    child: OmniTextField(
      controller: _editor,
      autofocus: true,
      maxLength: 120,
      decoration: const InputDecoration(labelText: '会话名称'),
    ),
  );
}
