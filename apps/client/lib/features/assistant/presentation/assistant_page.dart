import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/core/audio/microphone_coordinator.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/assistant/data/assistant_voice_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_voice_preferences.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_voice_button.dart';
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
import 'package:omni_butler/features/assistant/presentation/assistant_markdown.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_attachment_widgets.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_view.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_android_view.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_execution_progress.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_answer_actions.dart';
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
class _AssistantChatBodyState extends ConsumerState<_AssistantChatBody>
    with WidgetsBindingObserver {
  /// 两端共用的语音会话控制器。
  late final AssistantVoiceController _voice;

  /// 窗口隐藏和退出时等待语音停止与草稿落盘。
  late final VoiceInputLifecycle _voiceLifecycle;

  /// 子路由覆盖时也结束采集。
  GoRouter? _router;

  /// 页面销毁标记，异步回调不得再操作输入控件。
  bool _leaving = false;

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

  /// 发送展示切换时同步输入控件，失败后恢复底层草稿。
  bool _composerWasHidden = false;

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
    _voice = AssistantVoiceController(
      microphone: ref.read(microphoneCoordinatorProvider),
      beforeAcquire: () =>
          ref.read(noteRecorderProvider).ensureMicrophoneState(),
      createRecorder: ref.read(assistantVoiceRecorderFactoryProvider),
      connect: () async {
        // 连接前固定完整API地址；认证仓储再次检查来源代次。
        final SyncSession? session = ref.read(authControllerProvider).value;
        if (session == null || widget.repository?.isCurrent != true) {
          throw const ApiFailure('请先连接原服务器');
        }
        return ref.read(assistantSpeechConnectorProvider)(
          widget.repository!,
          session.apiBaseUrl,
        );
      },
      onText: (TextEditingValue value) {
        if (_leaving || !mounted) return;
        _input.value = value;
        _chat.setDraft(value.text);
      },
    );
    _voice.addListener(_voiceChanged);
    _chat.beforeConversationChange = _cancelVoiceAndFlush;
    _voiceLifecycle = ref.read(voiceInputLifecycleProvider);
    _voiceLifecycle.register(this, _cancelVoiceAndFlush);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_chat.initialize());
  }

  /// Observe the top route, including imperative pushes that do not update URLs.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Standalone widget tests may omit a router.
    final GoRouter? router = GoRouter.maybeOf(context);
    if (identical(router, _router)) return;
    _router?.routerDelegate.removeListener(_routeChanged);
    _router = router;
    _router?.routerDelegate.addListener(_routeChanged);
  }

  /// Require the actual top route and a visible app without relying on the URL.
  bool get _voiceContextCurrent =>
      mounted &&
      !_leaving &&
      widget.repository?.isCurrent == true &&
      (_router == null ||
          (_router!.routerDelegate.currentConfiguration.isNotEmpty &&
              _router!.state.uri.path == '/assistant')) &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive);

  /// Invalidate speech on route exit and refresh the entry gate on return.
  void _routeChanged() {
    if (_voice.busy && !_voiceContextCurrent) {
      unawaited(_cancelVoiceInBackground());
    }
    if (mounted && !_leaving) setState(() {});
  }

  /// Stop hidden capture and refresh eligibility when the app becomes visible.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (<AppLifecycleState>{
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    }.contains(state)) {
      unawaited(_cancelVoiceInBackground());
    }
    if (mounted && !_leaving) setState(() {});
  }

  /// 共享控制器同时冻结附件及键盘发送。
  void _voiceChanged() {
    _chat.composerLocked = _voice.busy;
    if (mounted && !_leaving) setState(() {});
  }

  /// 窗口退出及切换会话前保留已显示的最后一份草稿。
  Future<void> _cancelVoiceAndFlush() async {
    await _voice.cancel();
    await _chat.flushDraft();
  }

  /// 系统后台事件无法等待返回值，缓存失败仍在当前页面明确提示。
  Future<void> _cancelVoiceInBackground() async {
    try {
      await _cancelVoiceAndFlush();
    } catch (_) {
      if (!mounted || _leaving) return;
      _chat.error = '语音已停止，但草稿未能保存到本机，请检查后复制文字';
      setState(() {});
    }
  }

  /// 录音入口与最终自动发送共同使用当前消息门禁。
  bool get _canVoiceInput {
    // 读取当前服务端设置，刷新期间不开始新会话。
    final AsyncValue<Map<String, dynamic>?> settings = ref.read(
      assistantSettingsProvider,
    );
    return _voiceContextCurrent &&
        _chat.connected &&
        !_chat.offline &&
        !_chat.loading &&
        !_chat.busy &&
        _chat.pending == null &&
        !_chat.processing &&
        !settings.isLoading &&
        !settings.hasError &&
        settings.value?['enabled'] == true &&
        !_chat.attachments.transferring &&
        !_chat.attachments.adding &&
        (!_chat.active || _chat.run?['requiresTakeover'] != true) &&
        (!_chat.active ||
            <String>{
              'waitingInput',
              'waitingConfirmation',
            }.contains(_chat.run?['status']));
  }

  /// Preserve desktop click-to-toggle recording and ignore duplicate starts.
  Future<void> _toggleVoice() async {
    if (_voice.phase == AssistantVoicePhase.recording) {
      await _voice.finish();
      return;
    }
    if (_voice.busy || !_canVoiceInput) return;
    await _startVoice(autoSend: ref.read(assistantVoicePreferenceProvider));
  }

  /// Hold-to-talk explicitly sends the completed Android utterance.
  Future<void> _startAndroidVoice() =>
      _startVoice(autoSend: true, reportBlocked: true);

  /// Bind either interaction to the original conversation and selection.
  Future<void> _startVoice({
    required bool autoSend,
    bool reportBlocked = false,
  }) async {
    if (_voice.busy || !_canVoiceInput) return;
    // Keep the session bound until its final response is consumed.
    final String? conversation = _chat.conversationId;
    // 先结束输入法组合，语音不能覆盖正在组词的范围。
    _input.value = _input.value.copyWith(composing: TextRange.empty);
    _focus.unfocus();
    await _voice.start(
      initial: _input.value,
      autoSend: autoSend,
      isCurrent: () =>
          _voiceContextCurrent && _chat.conversationId == conversation,
      send: () async {
        // Recheck current configuration after the final transcript arrives.
        final Map<String, dynamic>? settings = ref
            .read(assistantSettingsProvider)
            .value;
        // Attachment failures already provide a specific user-facing reason.
        final String? attachmentBlock = _chat.attachments.blockReason(
          settings,
          includeVision: false,
        );
        if (!_canVoiceInput ||
            _voice.busy ||
            _chat.conversationId != conversation ||
            _input.text.length > 20000 ||
            attachmentBlock != null) {
          if (reportBlocked) {
            // Keep the combined draft visible with the reason it was not sent.
            final String reason = !_chat.connected || _chat.offline
                ? '当前离线，草稿已保留，请联网后发送'
                : _input.text.length > 20000
                ? '内容超过 20000 字，草稿已保留，请精简后发送'
                : attachmentBlock ??
                      (settings?['enabled'] != true
                          ? 'AI 助手未启用或配置尚未就绪，草稿已保留'
                          : '当前对话暂时无法发送，草稿已保留，请稍后发送');
            throw ApiFailure(reason);
          }
          return;
        }
        await _send();
        if (reportBlocked && mounted && _chat.error != null) {
          throw ApiFailure(_chat.error!);
        }
      },
    );
  }

  /// 两端一致的麦克风语义，桌面额外传入模型提交门禁。
  Widget _voiceButton(bool enabled) => AssistantVoiceButton(
    phase: _voice.phase,
    enabled: enabled && _canVoiceInput,
    onPressed: () => unawaited(_toggleVoice()),
  );

  /// 只在接近末尾时跟随流式文字，不打断历史阅读。
  void _changed() {
    if (!mounted) return;
    if (!_chat.loading &&
        (!_draftLoaded ||
            _draftConversation != _chat.conversationId ||
            _composerWasHidden != _chat.hideComposerDraft)) {
      _input.text = _chat.hideComposerDraft ? '' : _chat.draft;
      _composerWasHidden = _chat.hideComposerDraft;
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

  /// Release page listeners without cancelling existing background chat tasks.
  @override
  void dispose() {
    _leaving = true;
    WidgetsBinding.instance.removeObserver(this);
    _router?.routerDelegate.removeListener(_routeChanged);
    _voice.removeListener(_voiceChanged);
    // 页面已经离开时，宿主退出仍须等待原会话的停麦和草稿快照。
    final Future<void> cleanup = Future.wait<void>(<Future<void>>[
      _voice.cancel(),
      _chat.flushDraft(),
    ]);
    _voiceLifecycle.register(this, () => cleanup);
    unawaited(
      cleanup
          .whenComplete(() => _voiceLifecycle.unregister(this))
          .catchError((Object _) {}),
    );
    _voice.dispose();
    _chat.removeListener(_changed);
    _chat.dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 发送后仅在服务器接收成功时清空输入。
  Future<void> _send() async {
    if (_voice.busy) return;
    _chat.setDraft(_input.text);
    await _chat.send();
    if (!mounted) return;
    // 发送前能力校验读取服务器最新配置，失败后同步设置入口的操作提示。
    if (_chat.error != null && _chat.attachments.hasDrafts) {
      ref.invalidate(assistantSettingsProvider);
    }
    if (_chat.pending == null && _chat.draft.isEmpty) _input.clear();
  }

  /// 开始沿用同一聊天发送可见的继续消息，结果未知时保留正文与身份。
  Future<void> _continueConversation() async {
    if (!_chat.canContinue || _input.text.trim().isNotEmpty) return;
    // 切换聊天后不让迟到响应修改新输入框。
    final String? target = _chat.conversationId;
    _input.text = '继续';
    await _chat.continueConversation();
    if (!mounted || _chat.conversationId != target) return;
    _input.text = _chat.draft;
    _focus.requestFocus();
  }

  /// 输入控制器由弹窗状态管理，退出动画完成后再释放。
  Future<String?> _askText(String title, String initial) =>
      showOmniDialog<String>(
        context: context,
        builder: (BuildContext context) =>
            _AssistantRenameDialog(title: title, initial: initial),
      );

  /// Rename the selected history item even when another chat is open.
  Future<void> _renameConversation(String id) async {
    // Resolve the title from the selected immutable conversation identity.
    final String title =
        _chat.conversations
                .where((Map<String, dynamic> item) => item['id'] == id)
                .firstOrNull?['title']
            as String? ??
        '新对话';
    // Keep the existing dialog and validation lifecycle.
    final String? value = await _askText('重命名对话', title);
    if (value != null && mounted) await _chat.rename(value, id: id);
  }

  /// 会话删除需要明确说明仅删除聊天。
  Future<void> _deleteConversation({String? id}) async {
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
    if (confirmed) await _chat.delete(id: id);
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
        if (_voice.status != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
            child: Text(
              _voice.status!,
              key: const ValueKey<String>('assistant-voice-status'),
            ),
          ),
        if (!_chat.hideComposerDraft)
          AssistantAttachmentDrafts(
            attachments: _chat.attachments,
            settings: ref.watch(assistantSettingsProvider).value,
          ),
        if (_chat.recoveryReason != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
            child: Text(
              _chat.recoveryReason!,
              style: TextStyle(
                color: OmniColors.of(context).muted,
                fontSize: 13,
              ),
            ),
          ),
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
                  onPressed: _voice.busy ? null : _chat.clearDraftReference,
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
        if (_chat.run != null && _chat.run?['status'] != 'succeeded')
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
                readOnly: _chat.busy || _chat.pending != null || _voice.busy,
                onChanged: _chat.setDraft,
                decoration: const InputDecoration(
                  hintText: '记录想法、查询数据，或整理这一周…',
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: OmniSpacing.sm),
            _voiceButton(enabled),
            Flexible(
              child: OmniButton(
                key: ValueKey<String>(
                  _chat.processing
                      ? 'assistant-stop-button'
                      : _chat.canContinue && _input.text.trim().isEmpty
                      ? 'assistant-continue-button'
                      : 'assistant-send-button',
                ),
                label: _chat.processing
                    ? '停止'
                    : _chat.canContinue && _input.text.trim().isEmpty
                    ? '开始'
                    : _chat.pending == null
                    ? '发送'
                    : '恢复发送',
                icon: _chat.processing
                    ? Icons.stop_rounded
                    : _chat.canContinue && _input.text.trim().isEmpty
                    ? Icons.play_arrow_rounded
                    : Icons.arrow_upward,
                loading: _chat.busy && !_chat.processing,
                onPressed: _voice.busy
                    ? null
                    : _chat.processing
                    ? (_chat.canStop ? _chat.stop : null)
                    : _chat.canContinue && _input.text.trim().isEmpty
                    ? (enabled ? _continueConversation : null)
                    : enabled &&
                          !_chat.busy &&
                          (_chat.pending != null ||
                              _chat.attachments.blockReason(
                                    ref.watch(assistantSettingsProvider).value,
                                    includeVision: false,
                                  ) ==
                                  null) &&
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
            ),
          ],
        ),
        if (_chat.attachments.enabled)
          Align(
            alignment: Alignment.centerLeft,
            child: AssistantAttachmentButton(
              attachments: _chat.attachments,
              enabled: enabled && !_voice.busy,
            ),
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

  /// Render assistant Markdown and platform-specific user bubble surfaces.
  Widget _message(Map<String, dynamic> message, bool enabled) {
    enabled = enabled && !_voice.busy;
    // Android uses the reference's unboxed assistant answer layout.
    final bool android = Theme.of(context).platform == TargetPlatform.android;
    // 用户消息与助手消息使用位置和留白区别。
    final bool user = message['role'] == 'user';
    // 业务保存与撤销始终使用本条持久回答身份。
    final String id = message['id'] as String;
    // 只将撤销能力交给当前回答的首张结果卡。
    final String? undoRunId =
        _chat.run?['answerMessageId'] == id && _chat.run?['canUndo'] == true
        ? _chat.run!['id'] as String
        : null;
    // 排除附件卡后保持一致的结果索引。
    final List<Map<String, dynamic>> cards = assistantItems(message['cards'])
        .where((item) => item['type'] != 'attachment')
        .toList();
    if (user) {
      return Padding(
        padding: const EdgeInsets.only(bottom: OmniSpacing.lg),
        child: FractionallySizedBox(
          widthFactor: .85,
          alignment: Alignment.centerRight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              AssistantHistoryAttachments(
                items: assistantMessageAttachments(message),
                repository: _chat.repository,
                enabled: _chat.connected && !_chat.offline,
                localPreview: message['_localOutgoing'] == true,
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: android
                      ? OmniColors.of(context).brand.withValues(alpha: .08)
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: android
                      ? const BorderRadius.only(
                          topLeft: Radius.circular(OmniRadius.dialog),
                          topRight: Radius.circular(OmniRadius.dialog),
                          bottomLeft: Radius.circular(OmniRadius.dialog),
                          bottomRight: Radius.circular(OmniRadius.tiny),
                        )
                      : BorderRadius.circular(OmniRadius.control),
                ),
                child: SelectableText.rich(
                  NoteMarkdownText.span(
                    message['content'] as String? ?? '',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  textWidthBasis: TextWidthBasis.longestLine,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpacing.lg),
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 760),
          padding: android
              ? EdgeInsets.zero
              : const EdgeInsets.all(OmniSpacing.md),
          decoration: user
              ? BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                )
              : null,
          child: AssistantAnswerActions(
            key: ValueKey<String>('assistant-answer-actions-row-$id'),
            messageId: id,
            createdAt: message['createdAt'] as String?,
            colors: AssistantWindowsPalette.of(context),
            alwaysVisible: true,
            saved: _chat.savedNote(id) != null,
            saving: _chat.savingNote(id),
            error: _chat.noteSaveError(id),
            showSave:
                message['_streaming'] != true &&
                (message['content'] as String? ?? '').trim().isNotEmpty,
            onSave: _chat.connected && !_chat.offline
                ? () => unawaited(_chat.saveNote(id))
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (!android) ...<Widget>[
                  Text(
                    user ? '你' : '知序',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: OmniSpacing.xs),
                ],
                if (!user)
                  AssistantExecutionProgress(
                    key: ValueKey<String>(
                      'assistant-progress-${message['id']}',
                    ),
                    elapsedMs:
                        _chat.run?['answerMessageId'] == message['id'] &&
                            _chat.processing
                        ? _chat.liveElapsedMs
                        : message['_timingPending'] == true
                        ? null
                        : message['elapsedMs'] as num?,
                    running:
                        _chat.run?['answerMessageId'] == message['id'] &&
                        _chat.processing,
                    steps: assistantItems(message['executionSteps']),
                    colors: AssistantWindowsPalette.of(context),
                  ),
                if (!user)
                  AssistantMarkdown(
                    source: message['content'] as String? ?? '',
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(height: 1.35),
                  )
                else
                  SelectableText.rich(
                    NoteMarkdownText.span(
                      message['content'] as String? ?? '',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                AssistantHistoryAttachments(
                  items: assistantMessageAttachments(message),
                  repository: _chat.repository,
                  enabled: _chat.connected && !_chat.offline,
                ),
                for (final (int cardIndex, Map<String, dynamic> card)
                    in cards.indexed)
                  AssistantMessageCard(
                    key: ValueKey<String>(
                      'assistant-card-${message['id']}-$cardIndex',
                    ),
                    card: card,
                    enabled:
                        enabled &&
                        !_chat.busy &&
                        _chat.pending == null &&
                        (card['type'] != 'result' || !_chat.active),
                    repository: _chat.repository,
                    beforeEdit: _chat.catchUp,
                    undoExpiresAt: _chat.run?['undoExpiresAt'] as String?,
                    onUndo:
                        undoRunId != null &&
                            enabled &&
                            !_chat.busy &&
                            !_chat.active &&
                            cardIndex ==
                                cards.indexWhere(
                                  (item) => item['type'] == 'result',
                                )
                        ? () => unawaited(_chat.undo(runId: undoRunId))
                        : null,
                    onClarification:
                        _chat.run?['status'] == 'waitingInput' &&
                            _chat.run?['answerMessageId'] == message['id']
                        ? (String value) {
                            _input.text = value;
                            _chat.setDraft(value);
                            unawaited(_chat.send());
                          }
                        : null,
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
      ),
    );
  }

  /// Select the platform view while retaining the original controller owners.
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
    if (Theme.of(context).platform == TargetPlatform.windows) {
      return AssistantWindowsView(
        chat: _chat,
        input: _input,
        inputFocus: _focus,
        scroll: _scroll,
        onSend: _send,
        voiceBusy: _voice.busy,
        voiceStatus: _voice.status,
        voiceButton: _voiceButton,
        onDelete: (String id) => _deleteConversation(id: id),
        onRename: (String id) async {
          // 重命名固定用户选中的会话，而不是此刻打开的会话。
          final String title =
              _chat.conversations
                      .where((Map<String, dynamic> item) => item['id'] == id)
                      .firstOrNull?['title']
                  as String? ??
              '新聊天';
          // 弹窗与旧页面共用受控输入生命周期。
          final String? value = await _askText('重命名对话', title);
          if (value != null && mounted) await _chat.rename(value, id: id);
        },
      );
    }
    if (Theme.of(context).platform == TargetPlatform.android) {
      return AssistantAndroidView(
        chat: _chat,
        input: _input,
        inputFocus: _focus,
        scroll: _scroll,
        voice: _voice,
        canVoiceInput: _canVoiceInput,
        enabled: enabled,
        onSend: _send,
        onContinue: _continueConversation,
        onStartVoice: _startAndroidVoice,
        onDelete: (String id) => _deleteConversation(id: id),
        onRename: _renameConversation,
        messageBuilder: _message,
      );
    }
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
                              if (_chat.attachments.imageInputBlockReason(
                                    settings.value,
                                  ) !=
                                  null)
                                OmniButton(
                                  label: 'AI 设置',
                                  variant: OmniButtonVariant.text,
                                  onPressed: _chat.busy
                                      ? null
                                      : () =>
                                            context.go('/settings?section=ai'),
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
                        : _chat.displayMessages.isEmpty && _chat.plan == null
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
                                            onPressed: enabled && !_voice.busy
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
                                  in _chat.displayMessages)
                                _message(message, enabled),
                              if (_chat.run != null &&
                                  !_chat.messages.any(
                                    (message) =>
                                        message['role'] == 'assistant' &&
                                        message['id'] ==
                                            _chat.run?['answerMessageId'],
                                  ))
                                AssistantExecutionProgress(
                                  key: ValueKey<String>(
                                    'assistant-progress-${_chat.run?['answerMessageId'] ?? _chat.run?['id']}',
                                  ),
                                  elapsedMs: _chat.liveElapsedMs,
                                  running: _chat.processing,
                                  steps: assistantItems(
                                    _chat.run?['executionSteps'],
                                  ),
                                  colors: AssistantWindowsPalette.of(context),
                                ),
                              if (_chat.plan != null &&
                                  _chat.run?['status'] == 'waitingConfirmation')
                                AssistantPlanCard(
                                  plan: _chat.plan!,
                                  enabled:
                                      enabled &&
                                      !_voice.busy &&
                                      !_chat.busy &&
                                      !_chat.offline &&
                                      _chat.pending == null &&
                                      _chat.draft.trim().isEmpty &&
                                      _chat.run?['timingPending'] != true &&
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
