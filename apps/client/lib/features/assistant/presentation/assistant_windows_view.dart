import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/attachments/windows_clipboard_images.dart';
import 'package:omni_butler/features/assistant/data/assistant_attachments.dart';
import 'package:omni_butler/features/assistant/data/assistant_chat_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_cards.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_markdown.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_attachment_widgets.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_conversation_search.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_execution_progress.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_file_drop_area.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_user_message_row.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_answer_actions.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/features/notes/presentation/note_markdown_text.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Windows 独立工作区，继续使用原会话控制器和认证隔离生命周期。
class AssistantWindowsView extends ConsumerStatefulWidget {
  /// 当前服务器的真实聊天状态。
  final AssistantChatController chat;

  /// 与原页面共享的草稿输入控制器。
  final TextEditingController input;

  /// 原页面持有的输入焦点。
  final FocusNode inputFocus;

  /// 原页面管理的消息滚动位置。
  final ScrollController scroll;

  /// 保留原幂等发送入口。
  final Future<void> Function() onSend;

  /// 录音与最终转写期间冻结输入相关操作。
  final bool voiceBusy;

  /// 当前语音状态或可检查错误。
  final String? voiceStatus;

  /// 原页面持有语音状态，桌面只提供模型提交门禁。
  final Widget Function(bool enabled)? voiceButton;

  /// 按明确会话身份重命名。
  final Future<void> Function(String id) onRename;

  /// 按明确会话身份确认删除。
  final Future<void> Function(String id) onDelete;

  /// 创建仅供 Windows 使用的助手工作区。
  const AssistantWindowsView({
    required this.chat,
    required this.input,
    required this.inputFocus,
    required this.scroll,
    required this.onSend,
    required this.onRename,
    required this.onDelete,
    this.voiceBusy = false,
    this.voiceStatus,
    this.voiceButton,
    super.key,
  });

  /// 创建局部交互状态。
  @override
  ConsumerState<AssistantWindowsView> createState() =>
      _AssistantWindowsViewState();
}

/// 页面只维护搜索浮层与模型提交状态，任务事实仍以控制器为准。
class _AssistantWindowsViewState extends ConsumerState<AssistantWindowsView> {
  /// 模型按钮的真实屏幕锚点。
  final GlobalKey _modelKey = GlobalKey();

  /// 首次进入后接收工作区快捷键，避免焦点停留在外层导航壳。
  final FocusNode _workspaceFocus = FocusNode(debugLabel: 'AssistantWorkspace');

  /// 防止连续快捷键重复打开搜索。
  bool _searchOpen = false;

  /// 防止模型选择重复提交。
  bool _savingModel = false;

  /// 模型更新失败需要持续展示。
  String? _modelError;

  /// 图片编码期间忽略重复粘贴，不产生重复上传。
  bool _pasting = false;

  /// 接入输入焦点与草稿变化，不改写输入法的组合区。
  @override
  void initState() {
    super.initState();
    widget.input.addListener(_inputChanged);
    widget.inputFocus.onKeyEvent = _inputKey;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && !_workspaceFocus.hasFocus) {
        _workspaceFocus.requestFocus();
      }
    });
  }

  /// 移除局部监听，输入控制器仍由原页面释放。
  @override
  void dispose() {
    widget.input.removeListener(_inputChanged);
    widget.inputFocus.onKeyEvent = null;
    _workspaceFocus.dispose();
    super.dispose();
  }

  /// 输入内容变化时仅更新发送按钮状态。
  void _inputChanged() {
    if (mounted) setState(() {});
  }

  /// 默认要求设置读取完成；附件选择可在刷新时沿用已确认设置。
  bool _enabled(
    AsyncValue<Map<String, dynamic>?> settings, {
    bool allowSettingsRefresh = false,
  }) =>
      widget.chat.connected &&
      !widget.chat.offline &&
      !widget.chat.loading &&
      (!settings.isLoading || allowSettingsRefresh && settings.hasValue) &&
      !settings.hasError &&
      settings.value?['enabled'] == true;

  /// 按钮和键盘共用相同发送门禁，未知结果只能恢复原请求。
  bool _canSend(AsyncValue<Map<String, dynamic>?> settings) =>
      !widget.voiceBusy &&
      _enabled(settings) &&
      !widget.chat.busy &&
      !_savingModel &&
      (widget.chat.pending != null ||
          widget.chat.attachments.blockReason(
                settings.value,
                includeVision: false,
              ) ==
              null) &&
      (!widget.chat.active || widget.chat.run?['requiresTakeover'] != true) &&
      (widget.chat.pending != null ||
          ((widget.input.text.trim().isNotEmpty ||
                  widget.chat.attachments.hasDrafts) &&
              (!widget.chat.active ||
                  <String>{
                    'waitingInput',
                    'waitingConfirmation',
                  }.contains(widget.chat.run?['status']))));

  /// 只有输入框内无组合文字的普通 Enter 才发送。
  KeyEventResult _inputKey(FocusNode node, KeyEvent event) {
    if (widget.voiceBusy) return KeyEventResult.ignored;
    if (event is KeyDownEvent &&
        node.hasFocus &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        widget.input.value.composing.isCollapsed &&
        widget.chat.attachments.enabled &&
        !_pasting &&
        widget.chat.attachments.editable &&
        !widget.chat.attachments.transferring &&
        _enabled(ref.read(assistantSettingsProvider)) &&
        ref.read(windowsClipboardImagesProvider).hasImage) {
      unawaited(_pasteImage());
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent ||
        !widget.input.value.composing.isCollapsed ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter)) {
      return KeyEventResult.ignored;
    }
    if (_canSend(ref.read(assistantSettingsProvider))) {
      unawaited(widget.onSend());
    }
    return KeyEventResult.handled;
  }

  /// 只在输入区读取图片；无图片的 Ctrl+V 完全交给系统文字粘贴。
  Future<void> _pasteImage() async {
    if (_pasting || widget.voiceBusy) return;
    _pasting = true;
    // 编码结果不能进入用户后来切换到的聊天。
    final int draftToken = widget.chat.attachments.draftToken;
    try {
      // 剪贴板原生句柄在编码前释放，返回独立 PNG 内容。
      final bytes = await ref.read(windowsClipboardImagesProvider).readPng();
      if (!mounted ||
          !widget.inputFocus.hasFocus ||
          bytes == null ||
          draftToken != widget.chat.attachments.draftToken) {
        return;
      }
      await widget.chat.attachments.add(<AssistantPickedFile>[
        AssistantPickedFile(name: '粘贴图片.png', bytes: bytes),
      ]);
    } catch (failure) {
      if (mounted) {
        showOmniMessage(
          context,
          message: failure is ApiFailure
              ? failure.message
              : '图片粘贴失败，请重新复制或选择文件',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      _pasting = false;
    }
  }

  /// 全文搜索返回会话身份后才尝试切换，保留控制器的 pending 检查。
  Future<void> _search() async {
    if (_searchOpen) return;
    // 取消搜索时恢复原来的有效焦点，不强制跳入输入框。
    final FocusNode? previousFocus = FocusManager.instance.primaryFocus;
    // 只有真正选择了聊天，关闭后才把焦点交给输入框。
    bool selectedConversation = false;
    _searchOpen = true;
    try {
      // 弹窗只返回用户选中的真实会话。
      final String? selected = await showOmniDialog<String>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: .16),
        builder: (_) => AssistantConversationSearch(
          chat: widget.chat,
          onNew: _newConversation,
        ),
      );
      if (mounted && selected != null) {
        selectedConversation = true;
        await widget.chat.select(selected);
      }
    } finally {
      _searchOpen = false;
      if (mounted) {
        // 路由切换可能移除旧焦点节点，只有仍挂载的节点可以恢复。
        final FocusNode? target = selectedConversation
            ? widget.inputFocus
            : previousFocus;
        if (target?.context != null && target!.canRequestFocus) {
          target.requestFocus();
        }
      }
    }
  }

  /// 新聊天切换本地空白草稿并恢复输入焦点。
  void _newConversation() {
    if (!widget.chat.connected ||
        widget.chat.busy ||
        widget.chat.pending != null) {
      return;
    }
    unawaited(
      widget.chat.create().then((_) {
        if (mounted) widget.inputFocus.requestFocus();
      }),
    );
  }

  /// 右键菜单中的操作始终固定被点击条目，不能切换后误操作当前会话。
  Future<void> _contextMenu(
    Map<String, dynamic> conversation,
    Offset position,
  ) async {
    // 当前会话真实身份。
    final String id = conversation['id'] as String;
    // 由服务器提供的置顶状态。
    final bool pinned = conversation['isPinned'] == true;
    // 真实窗口覆盖层的边界。
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    // 本次右键明确选中的动作。
    final String? selected = await showOmniMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        OmniPopupMenuItem<String>(
          value: 'rename',
          label: '重命名',
          icon: Icons.drive_file_rename_outline,
          enabled: widget.chat.connected && !widget.chat.busy,
        ),
        OmniPopupMenuItem<String>(
          value: 'pin',
          label: pinned ? '取消置顶' : '置顶',
          icon: pinned ? Icons.push_pin_outlined : Icons.push_pin,
          enabled: widget.chat.connected && !widget.chat.busy,
        ),
        OmniPopupMenuItem<String>(
          value: 'delete',
          label: '删除聊天',
          icon: Icons.delete_outline,
          danger: true,
          enabled:
              widget.chat.connected &&
              !widget.chat.busy &&
              widget.chat.pending == null,
        ),
      ],
    );
    if (!mounted) return;
    if (selected == 'rename') await widget.onRename(id);
    if (selected == 'pin') await widget.chat.setPinned(id, !pinned);
    if (selected == 'delete') await widget.onDelete(id);
  }

  /// 模型面板紧贴按钮上方，并仅展示设置中真实存在的配置。
  Future<void> _models(Map<String, dynamic>? settings) async {
    if (widget.voiceBusy) return;
    if (_savingModel || settings == null || !widget.chat.connected) return;
    // 当前按钮与窗口的真实坐标，用于向上定位菜单。
    final RenderBox? button =
        _modelKey.currentContext?.findRenderObject() as RenderBox?;
    if (button == null) return;
    // 弹窗与按钮统一使用根导航覆盖层坐标，避免窗口安全区造成偏移。
    final RenderBox overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay!.context.findRenderObject()!
            as RenderBox;
    // 输入框内按钮相对于弹窗覆盖层的完整边界。
    final Rect anchor =
        button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
    // 选择前固定配置，禁止弹窗期间的设置刷新替换修订号。
    final Map<String, dynamic> fixed = Map<String, dynamic>.from(settings);
    // 真实已配置模型选项。
    final List<Map<String, dynamic>> profiles = assistantItems(
      fixed['profiles'],
    );
    // 面板只返回目标配置身份。
    final String? id = await showOmniDialog<String>(
      context: context,
      barrierColor: Colors.transparent,
      useSafeArea: false,
      builder: (_) => _AssistantModelPicker(
        anchor: anchor,
        profiles: profiles,
        selectedId: fixed['profileId'] as String?,
      ),
    );
    if (!mounted || id == null || id == fixed['profileId']) return;
    // 固定认证代次，避免切换服务器后提交旧配置。
    final AssistantRepository repository = ref.read(
      assistantRepositoryProvider,
    );
    if (!repository.isCurrent || !widget.chat.connected) return;
    setState(() {
      _savingModel = true;
      _modelError = null;
    });
    try {
      await repository.request(
        'PUT',
        '/settings',
        data: <String, dynamic>{
          'revision': fixed['revision'],
          'enabled': fixed['enabled'],
          'profileId': id,
          'memoryReadEnabled': fixed['memoryReadEnabled'],
          'memoryWriteEnabled': fixed['memoryWriteEnabled'],
          'timeZone': fixed['timeZone'] ?? 'Asia/Shanghai',
        },
      );
      if (!mounted || !repository.isCurrent) return;
      ref.invalidate(assistantSettingsProvider);
    } catch (error) {
      if (!mounted || !repository.isCurrent) return;
      setState(
        () => _modelError = error is ApiFailure ? error.message : '模型切换失败，请重试',
      );
      ref.invalidate(assistantSettingsProvider);
    } finally {
      if (mounted) setState(() => _savingModel = false);
    }
  }

  /// 左侧为品牌、新聊天以及按置顶状态分组的历史。
  Widget _sidebar(AssistantWindowsPalette colors) {
    // 置顶历史使用服务端稳定排序。
    final List<Map<String, dynamic>> pinned = widget.chat.conversations
        .where((item) => item['isPinned'] == true)
        .toList();
    // 普通历史保持服务端更新时间顺序。
    final List<Map<String, dynamic>> recent = widget.chat.conversations
        .where((item) => item['isPinned'] != true)
        .toList();
    return Container(
      key: const ValueKey<String>('assistant-windows-sidebar'),
      width: AssistantWindowsMetrics.sidebarWidth,
      decoration: BoxDecoration(
        color: colors.sidebar,
        border: Border(right: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '知序',
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                OmniIconButton(
                  key: const ValueKey<String>('assistant-search-button'),
                  icon: const Icon(Icons.search),
                  tooltip: '搜索聊天 (Ctrl+K)',
                  color: colors.muted,
                  onPressed: _search,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 20),
            child: Material(
              color: colors.sidebar,
              borderRadius: BorderRadius.circular(
                AssistantWindowsMetrics.rowRadius,
              ),
              child: OmniInkWell(
                key: const ValueKey<String>('assistant-new-chat'),
                hoverColor: colors.soft,
                focusColor: colors.soft,
                onTap:
                    widget.chat.connected &&
                        !widget.chat.busy &&
                        widget.chat.pending == null
                    ? _newConversation
                    : null,
                borderRadius: BorderRadius.circular(
                  AssistantWindowsMetrics.rowRadius,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AssistantWindowsMetrics.historyHeight,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.edit_square, size: 16, color: colors.ink),
                        const SizedBox(width: 12),
                        Text(
                          '新聊天',
                          style: TextStyle(
                            color: colors.ink,
                            fontSize: AssistantWindowsMetrics.historyFontSize,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: <Widget>[
                if (pinned.isNotEmpty) _groupLabel('置顶', colors),
                for (final Map<String, dynamic> item in pinned)
                  _conversation(item, colors),
                if (recent.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: pinned.isEmpty ? 0 : 18),
                    child: _groupLabel('聊天', colors),
                  ),
                for (final Map<String, dynamic> item in recent)
                  _conversation(item, colors),
                if (widget.chat.conversations.isEmpty && !widget.chat.loading)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '暂无聊天',
                      style: TextStyle(color: colors.muted, fontSize: 14),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 轻量分组标签。
  Widget _groupLabel(String label, AssistantWindowsPalette colors) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
    child: Text(label, style: TextStyle(color: colors.muted, fontSize: 14)),
  );

  /// 每行显示操作由行内悬停与键盘焦点决定。
  Widget _conversation(
    Map<String, dynamic> item,
    AssistantWindowsPalette colors,
  ) {
    // 会话操作必须绑定本行身份。
    final String id = item['id'] as String;
    return _AssistantConversationRow(
      key: ValueKey<String>('assistant-conversation-$id'),
      conversation: item,
      selected: widget.chat.conversationId == id,
      colors: colors,
      onSelect: widget.chat.busy
          ? null
          : () => unawaited(widget.chat.select(id)),
      onPin: widget.chat.connected && !widget.chat.busy
          ? () => unawaited(widget.chat.setPinned(id, item['isPinned'] != true))
          : null,
      onDelete:
          widget.chat.connected &&
              !widget.chat.busy &&
              widget.chat.pending == null
          ? () => unawaited(widget.onDelete(id))
          : null,
      onRename: widget.chat.connected && !widget.chat.busy
          ? () => unawaited(widget.onRename(id))
          : null,
      onContextMenu: (Offset position) =>
          unawaited(_contextMenu(item, position)),
    );
  }

  /// 标题本身是重命名入口，窄窗口提供搜索入口以恢复历史访问。
  Widget _header(bool wide, AssistantWindowsPalette colors) {
    // 当前聊天名称来自服务端历史列表。
    final String title =
        widget.chat.conversations
                .where((item) => item['id'] == widget.chat.conversationId)
                .firstOrNull?['title']
            as String? ??
        '新聊天';
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: AssistantWindowsMetrics.headerHeight,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Row(
          children: <Widget>[
            if (!wide) ...<Widget>[
              OmniIconButton(
                key: const ValueKey<String>('assistant-search-button'),
                icon: const Icon(Icons.search),
                tooltip: '搜索聊天 (Ctrl+K)',
                onPressed: _search,
              ),
              OmniIconButton(
                icon: const Icon(Icons.edit_square),
                tooltip: '新聊天 (Ctrl+N)',
                onPressed:
                    widget.chat.connected &&
                        !widget.chat.busy &&
                        widget.chat.pending == null
                    ? _newConversation
                    : null,
              ),
              const SizedBox(width: 8),
            ],
            Icon(Icons.chat_bubble_outline, color: colors.ink, size: 18),
            const SizedBox(width: 12),
            Flexible(
              child: Tooltip(
                message: '重命名对话',
                child: OmniInkWell(
                  onTap:
                      widget.chat.conversationId != null &&
                          widget.chat.connected &&
                          !widget.chat.busy
                      ? () => unawaited(
                          widget.onRename(widget.chat.conversationId!),
                        )
                      : null,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 消息和输入区在侧栏右侧的工作区共用同一条居中内容列。
  Widget _contentColumn({required Widget child, required double inset}) =>
      Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AssistantWindowsMetrics.contentWidth,
            ),
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      );

  /// 首个正文片段到达之前，进度也位于同一回答列中。
  Widget _pendingProgress(
    AssistantWindowsPalette colors,
  ) => AssistantExecutionProgress(
    key: ValueKey<String>(
      'assistant-progress-${widget.chat.submitting ? 'sending' : widget.chat.run?['answerMessageId'] ?? widget.chat.run?['id']}',
    ),
    elapsedMs: widget.chat.liveElapsedMs,
    running:
        widget.chat.submitting ||
        <String>{'queued', 'running'}.contains(widget.chat.run?['status']),
    steps: widget.chat.submitting
        ? const <Map<String, dynamic>>[]
        : assistantItems(widget.chat.run?['executionSteps']),
    colors: colors,
  );

  /// 正文终态可能先于运行终态到达，旧快照不能让已完成步骤回退。
  List<Map<String, dynamic>> _messageSteps(
    Map<String, dynamic> message,
    bool current,
  ) {
    // 以稳定步骤身份保留原顺序，重复回放仅更新同一行。
    final Map<String, Map<String, dynamic>> steps = {};
    for (final Map<String, dynamic> step in <Map<String, dynamic>>[
      ...assistantItems(message['executionSteps']),
      if (current) ...assistantItems(widget.chat.run?['executionSteps']),
    ]) {
      // 公开步骤缺少身份时不能参与合并。
      final Object? id = step['id'];
      if (id is! String) continue;
      if (steps[id]?['finishedAt'] != null && step['finishedAt'] == null) {
        continue;
      }
      steps[id] = step;
    }
    return steps.values.toList();
  }

  /// 轻量回答操作保留保存笔记与受控结构化卡片。
  Widget _message(
    Map<String, dynamic> message,
    bool enabled,
    AssistantWindowsPalette colors,
  ) {
    // 消息身份稳定绑定视觉测试和流式节点。
    final String id = '${message['id']}';
    // 用户与助手采用不同表面，移除重复的角色标题。
    final bool user = message['role'] == 'user';
    // 原始正文不经转换，分别交给助手 Markdown 和用户消息渲染。
    final String content = message['content'] as String? ?? '';
    // 服务端保存的本条回答耗时。
    final num? elapsed = message['elapsedMs'] as num?;
    // 发送新消息的本机秒表不能附着到上一条已完成回答。
    final bool current =
        !widget.chat.submitting && widget.chat.run?['answerMessageId'] == id;
    // 只有真实排队与执行阶段持续走表，等待用户操作时暂停。
    final bool running =
        current &&
        <String>{'queued', 'running'}.contains(widget.chat.run?['status']);
    // 当前回答仍在执行或等待结算时，不展示暂存的零耗时。
    final bool timingPending =
        current &&
        (widget.chat.run?['timingPending'] == true ||
            <String>{'running', 'queued'}.contains(widget.chat.run?['status']));
    // 当前发送与业务卡片可用状态。
    final bool actionsEnabled =
        enabled && !widget.chat.busy && widget.chat.pending == null;
    // 只给对应回答的唯一结果卡传递当前真实撤销身份。
    final String? undoRunId =
        widget.chat.run?['answerMessageId'] == id &&
            widget.chat.run?['canUndo'] == true
        ? widget.chat.run!['id'] as String
        : null;
    // 卡片索引与视觉顺序一致，撤销入口最多渲染一次。
    final List<Map<String, dynamic>> cards = assistantItems(message['cards'])
        .where((item) => item['type'] != 'attachment')
        .toList();
    // 用户行的底部空间由悬停工具栏固定预留。
    final Widget row = Padding(
      padding: EdgeInsets.zero,
      child: FractionallySizedBox(
        widthFactor: user ? .72 : 1,
        alignment: Alignment.centerRight,
        // 比例仅限制可用宽度，内层对齐让短消息气泡按文字收缩。
        child: Align(
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            key: ValueKey<String>(
              user ? 'assistant-user-message-$id' : 'assistant-answer-$id',
            ),
            padding: user
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                : EdgeInsets.zero,
            decoration: user
                ? BoxDecoration(
                    color: colors.soft,
                    borderRadius: BorderRadius.circular(
                      AssistantWindowsMetrics.bubbleRadius,
                    ),
                  )
                : null,
            child: Column(
              crossAxisAlignment: user
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.stretch,
              children: <Widget>[
                if (!user)
                  AssistantExecutionProgress(
                    key: ValueKey<String>('assistant-progress-$id'),
                    elapsedMs: running
                        ? widget.chat.liveElapsedMs
                        : !timingPending && elapsed != null && elapsed >= 0
                        ? elapsed
                        : null,
                    running: running,
                    steps: _messageSteps(message, current),
                    colors: colors,
                  ),
                if (!user && message['_streaming'] == true && content.isEmpty)
                  Text(
                    '正在思考…',
                    style: TextStyle(color: colors.muted, fontSize: 14),
                  ),
                if (!user)
                  AssistantMarkdown(
                    source: content,
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  )
                else
                  SelectableText.rich(
                    textWidthBasis: TextWidthBasis.longestLine,
                    NoteMarkdownText.span(
                      content,
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: user ? 14 : 16,
                        height: 1.7,
                      ),
                    ),
                  ),
                if (!user)
                  AssistantHistoryAttachments(
                    items: assistantMessageAttachments(message),
                    repository: widget.chat.repository,
                    enabled: widget.chat.connected && !widget.chat.offline,
                  ),
                for (final (int cardIndex, Map<String, dynamic> card)
                    in cards.indexed)
                  Padding(
                    key: ValueKey<String>('assistant-card-$id-$cardIndex'),
                    // 相关记录自身已有顶部间距，避免两层留白叠加。
                    padding: EdgeInsets.only(
                      top: card['type'] == 'references' ? 0 : 12,
                    ),
                    child: AssistantMessageCard(
                      card: card,
                      enabled:
                          actionsEnabled &&
                          (card['type'] != 'result' || !widget.chat.active),
                      repository: widget.chat.repository,
                      beforeEdit: widget.chat.catchUp,
                      undoExpiresAt:
                          widget.chat.run?['undoExpiresAt'] as String?,
                      onUndo:
                          undoRunId != null &&
                              actionsEnabled &&
                              !widget.chat.active &&
                              cardIndex ==
                                  cards.indexWhere(
                                    (item) => item['type'] == 'result',
                                  )
                          ? () => unawaited(widget.chat.undo(runId: undoRunId))
                          : null,
                      onClarification:
                          widget.chat.run?['status'] == 'waitingInput' &&
                              widget.chat.run?['answerMessageId'] == id
                          ? (String value) {
                              widget.input.text = value;
                              widget.chat.setDraft(value);
                              unawaited(widget.chat.send());
                            }
                          : null,
                      onChoice: (String value, Map<String, dynamic> selection) {
                        widget.input.text = value;
                        widget.chat.setDraft(value);
                        unawaited(
                          widget.chat.send(selection: selection).then((_) {
                            if (mounted && widget.chat.pending == null) {
                              widget.input.clear();
                            }
                          }),
                        );
                      },
                    ),
                  ),
                if (!user && widget.chat.run?['answerMessageId'] == id)
                  _runActions(enabled, colors),
              ],
            ),
          ),
        ),
      ),
    );
    return user
        ? AssistantUserMessageRow(
            key: ValueKey<String>('assistant-user-row-$id'),
            messageId: id,
            content: content,
            createdAt: message['createdAt'] is String
                ? message['createdAt'] as String
                : null,
            colors: colors,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                FractionallySizedBox(
                  widthFactor: .72,
                  alignment: Alignment.centerRight,
                  child: AssistantHistoryAttachments(
                    items: assistantMessageAttachments(message),
                    repository: widget.chat.repository,
                    enabled: widget.chat.connected && !widget.chat.offline,
                    localPreview: message['_localOutgoing'] == true,
                  ),
                ),
                row,
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(bottom: 36),
            child: AssistantAnswerActions(
              key: ValueKey<String>('assistant-answer-actions-row-$id'),
              messageId: id,
              createdAt: message['createdAt'] as String?,
              colors: colors,
              saved: widget.chat.savedNote(id) != null,
              saving: widget.chat.savingNote(id),
              error: widget.chat.noteSaveError(id),
              showSave:
                  message['_streaming'] != true && content.trim().isNotEmpty,
              onSave: widget.chat.connected && !widget.chat.offline
                  ? () => unawaited(widget.chat.saveNote(id))
                  : null,
              child: row,
            ),
          );
  }

  /// 当前任务操作跟随对应回答；没有回答时由消息列表末尾承载。
  Widget _runActions(bool enabled, AssistantWindowsPalette colors) {
    // 运行错误与受服务器控制的操作只渲染一份。
    final List<Widget> children = <Widget>[
      if (widget.chat.run?['errorMessage'] is String)
        Text(
          widget.chat.run!['errorMessage'] as String,
          style: TextStyle(color: OmniColors.of(context).danger, fontSize: 13),
        ),
      if (widget.chat.active ||
          <String>{
            'failed',
            'submissionUnknown',
          }.contains(widget.chat.run?['status']))
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: <Widget>[
            Text(
              widget.chat.run?['requiresTakeover'] == true && widget.chat.active
                  ? '任务由其他设备处理，请先接管'
                  : assistantStatusLabel(widget.chat.run?['status'] as String?),
              style: TextStyle(color: colors.muted, fontSize: 13),
            ),
            if (widget.chat.run?['requiresTakeover'] == true &&
                !<String>{
                  'succeeded',
                  'cancelled',
                }.contains(widget.chat.run?['status']))
              OmniButton(
                label: '在此设备接管',
                variant: OmniButtonVariant.text,
                onPressed:
                    !widget.chat.busy &&
                        widget.chat.connected &&
                        !widget.chat.offline
                    ? widget.chat.takeover
                    : null,
              ),
            if (<String>{
              'failed',
              'submissionUnknown',
            }.contains(widget.chat.run?['status']))
              OmniButton(
                label: '重试任务',
                variant: OmniButtonVariant.text,
                onPressed: !widget.chat.busy && enabled
                    ? widget.chat.retry
                    : null,
              ),
          ],
        ),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey<String>('assistant-run-actions'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// 连接、设置与草稿提示留在输入区，停止操作由主按钮承载。
  Widget _status(
    AsyncValue<Map<String, dynamic>?> settings,
    AssistantWindowsPalette colors,
    double availableHeight,
  ) {
    // 各状态共用可换行的小型操作区。
    final List<Widget> children = <Widget>[
      if (widget.chat.recoveryReason != null)
        Text(
          widget.chat.recoveryReason!,
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
      if (widget.chat.offline || !widget.chat.connected)
        Text(
          '当前仅显示本机缓存；恢复连接后核实服务器状态。',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
      if (widget.chat.connected &&
          !settings.isLoading &&
          (settings.hasError || settings.value?['enabled'] != true))
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: <Widget>[
            Text(
              settings.hasError ? '无法读取助手设置，请重试' : '请在 AI 设置中选择助手模型并开启助手。',
              style: TextStyle(color: colors.muted, fontSize: 13),
            ),
            OmniButton(
              label: 'AI 设置',
              variant: OmniButtonVariant.text,
              onPressed: () => context.go('/settings?section=ai'),
            ),
            if (settings.hasError)
              OmniButton(
                label: '重试',
                variant: OmniButtonVariant.text,
                onPressed: () => ref.invalidate(assistantSettingsProvider),
              ),
          ],
        ),
      if (_modelError != null)
        Text(
          _modelError!,
          style: TextStyle(color: OmniColors.of(context).danger, fontSize: 13),
        ),
      if (widget.chat.error != null)
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: <Widget>[
            Text(
              widget.chat.error!,
              style: TextStyle(
                color: OmniColors.of(context).danger,
                fontSize: 13,
              ),
            ),
            if (widget.chat.attachments.imageInputBlockReason(settings.value) !=
                null)
              OmniButton(
                label: 'AI 设置',
                variant: OmniButtonVariant.text,
                onPressed: widget.chat.busy
                    ? null
                    : () => context.go('/settings?section=ai'),
              ),
            OmniButton(
              label: '刷新状态',
              variant: OmniButtonVariant.text,
              onPressed: widget.chat.connected && !widget.chat.busy
                  ? widget.chat.refresh
                  : null,
            ),
          ],
        ),
      if (widget.chat.draftReference != null)
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: <Widget>[
            Text(
              '编辑目标：${widget.chat.draftReference!['label'] ?? '所选记录'}',
              style: TextStyle(color: colors.muted, fontSize: 13),
            ),
            OmniButton(
              label: '取消定位',
              variant: OmniButtonVariant.text,
              onPressed: widget.chat.busy || widget.chat.pending != null
                  ? null
                  : widget.chat.clearDraftReference,
            ),
          ],
        ),
      if (widget.chat.pending != null)
        Text(
          '上一条消息结果尚未核实，请恢复发送。',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: math.max(56, availableHeight * .23),
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }

  /// 在同一聊天明确继续，输入框始终保留实际发送的可见正文。
  Future<void> _continueConversation() async {
    if (!widget.chat.canContinue || widget.input.text.trim().isNotEmpty) return;
    // 可见正文与控制器草稿同步，失败时也保留实际发送内容。
    final String? target = widget.chat.conversationId;
    widget.input.text = '继续';
    await widget.chat.continueConversation();
    if (!mounted || widget.chat.conversationId != target) return;
    widget.input.text = widget.chat.draft;
    widget.inputFocus.requestFocus();
  }

  /// 输入区域固定两层：多行文本在上，模型与主操作在右下角。
  Widget _composer(
    AsyncValue<Map<String, dynamic>?> settings,
    AssistantWindowsPalette colors,
  ) {
    // 全局默认配置的可读名称。
    final Map<String, dynamic>? profile = assistantItems(
      settings.value?['profiles'],
    ).where((item) => item['id'] == settings.value?['profileId']).firstOrNull;
    // 没有配置时提供真实设置入口。
    final String model = profile == null
        ? '选择模型'
        : '${profile['model'] ?? profile['name'] ?? '选择模型'}';
    // 用户发送和未知结果恢复使用相同箭头但不同可访问名称。
    final bool canSend = _canSend(settings);
    // 生成中优先停止，确认停止且空输入时显示开始，其余使用原发送规则。
    final bool stopping = widget.chat.processing;
    final bool continuing =
        !stopping &&
        widget.chat.canContinue &&
        widget.input.text.trim().isEmpty;
    // 停止不依赖模型设置，开始与发送仍需当前设置明确可用。
    final bool canAct =
        !widget.voiceBusy &&
        (stopping
            ? widget.chat.canStop
            : continuing
            ? _enabled(settings) && !_savingModel
            : canSend);
    // 同一位置保留不同语义和稳定定位键。
    final String action = stopping
        ? '停止'
        : continuing
        ? '开始'
        : widget.chat.pending == null
        ? '发送 (Enter)'
        : '恢复发送';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.voiceStatus != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
            child: Text(
              widget.voiceStatus!,
              key: const ValueKey<String>('assistant-voice-status'),
              style: TextStyle(color: colors.muted, fontSize: 13),
            ),
          ),
        Container(
          key: const ValueKey<String>('assistant-windows-composer'),
          constraints: const BoxConstraints(
            minHeight: AssistantWindowsMetrics.composerHeight,
          ),
          decoration: BoxDecoration(
            color: colors.canvas,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(
              AssistantWindowsMetrics.panelRadius,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: .035),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (!widget.chat.hideComposerDraft)
                  AssistantAttachmentDrafts(
                    attachments: widget.chat.attachments,
                    settings: settings.value,
                    desktopPreview: true,
                  ),
                OmniTextField(
                  key: const ValueKey<String>('assistant-input'),
                  controller: widget.input,
                  focusNode: widget.inputFocus,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 20000,
                  textInputAction: TextInputAction.newline,
                  readOnly:
                      widget.voiceBusy ||
                      widget.chat.busy ||
                      widget.chat.pending != null ||
                      _savingModel,
                  enabled: _enabled(settings),
                  onChanged: widget.chat.setDraft,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.6,
                    color: colors.ink,
                  ),
                  decoration: InputDecoration(
                    hintText: '和知序一起工作',
                    hintStyle: TextStyle(
                      color: colors.muted.withValues(alpha: .65),
                    ),
                    counterText: '',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.only(top: 6, bottom: 6),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    if (widget.chat.attachments.enabled) ...<Widget>[
                      AssistantAttachmentButton(
                        attachments: widget.chat.attachments,
                        // 选择附件不依赖当前模型，设置刷新沿用已确认状态。
                        enabled:
                            !widget.voiceBusy &&
                            _enabled(settings, allowSettingsRefresh: true),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          key: _modelKey,
                          child: OmniTextButton(
                            key: const ValueKey<String>(
                              'assistant-model-button',
                            ),
                            onPressed:
                                !widget.voiceBusy &&
                                    widget.chat.connected &&
                                    !widget.chat.busy &&
                                    !_savingModel &&
                                    !settings.isLoading &&
                                    widget.chat.pending == null
                                ? () => _models(settings.value)
                                : null,
                            style:
                                TextButton.styleFrom(
                                  foregroundColor: colors.ink,
                                  overlayColor: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  minimumSize: const Size(0, 34),
                                  shape: const StadiumBorder(),
                                ).copyWith(
                                  // 模型入口仅在悬停时显示中性底色。
                                  backgroundColor:
                                      WidgetStateProperty.resolveWith<Color>(
                                        (Set<WidgetState> states) =>
                                            states.contains(WidgetState.hovered)
                                            ? colors.soft
                                            : Colors.transparent,
                                      ),
                                ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                if (_savingModel) ...<Widget>[
                                  const SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                ],
                                Flexible(
                                  child: Text(
                                    model,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Icon(
                                  Icons.keyboard_arrow_down,
                                  size: 16,
                                  color: colors.muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (widget.voiceButton != null) ...<Widget>[
                      widget.voiceButton!(!_savingModel && _enabled(settings)),
                      const SizedBox(width: OmniSpacing.xs),
                    ],
                    SizedBox.square(
                      dimension: AssistantWindowsMetrics.sendSize,
                      child: Material(
                        key: const ValueKey<String>('assistant-send-surface'),
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        color: canAct
                            ? colors.ink
                            : colors.muted.withValues(alpha: .7),
                        child: Tooltip(
                          message: action,
                          child: Semantics(
                            button: true,
                            enabled: canAct,
                            child: OmniInkWell(
                              key: ValueKey<String>(
                                stopping
                                    ? 'assistant-stop-button'
                                    : continuing
                                    ? 'assistant-continue-button'
                                    : 'assistant-send-button',
                              ),
                              customBorder: const CircleBorder(),
                              onTap: canAct
                                  ? () => unawaited(
                                      stopping
                                          ? widget.chat.stop()
                                          : continuing
                                          ? _continueConversation()
                                          : widget.onSend(),
                                    )
                                  : null,
                              child: Center(
                                child: widget.chat.busy && !stopping
                                    ? SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: colors.canvas,
                                        ),
                                      )
                                    : Icon(
                                        stopping
                                            ? Icons.stop_rounded
                                            : continuing
                                            ? Icons.play_arrow_rounded
                                            : Icons.arrow_upward,
                                        size: 21,
                                        color: colors.canvas,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 构建截图同款的平面聊天工作区，并在窄窗口保留完整入口。
  @override
  Widget build(BuildContext context) {
    // 当前真实助手设置。
    final AsyncValue<Map<String, dynamic>?> settings = ref.watch(
      assistantSettingsProvider,
    );
    // 本页面的中性表面。
    final AssistantWindowsPalette colors = AssistantWindowsPalette.of(context);
    // 当前业务卡片与输入门禁。
    final bool enabled = _enabled(settings) && !widget.voiceBusy;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            unawaited(_search()),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            _newConversation,
      },
      child: Focus(
        focusNode: _workspaceFocus,
        child: Material(
          color: colors.canvas,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 大字号优先保证聊天与输入宽度。
              final bool wide =
                  constraints.maxWidth >=
                  AssistantWindowsMetrics.collapseWidth *
                      MediaQuery.textScalerOf(context).scale(14) /
                      14;
              // 居中内容列的两侧留白随工作区宽度收紧。
              final double inset = constraints.maxWidth > 1350
                  ? AssistantWindowsMetrics.contentInset
                  : AssistantWindowsMetrics.compactInset;
              return Row(
                children: <Widget>[
                  if (wide) _sidebar(colors),
                  Expanded(
                    child: AssistantFileDropArea(
                      attachments: widget.chat.attachments,
                      enabled: enabled && !_savingModel,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _header(wide, colors),
                          Expanded(
                            child: widget.chat.loading
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : ListView(
                                    key: const ValueKey<String>(
                                      'assistant-windows-messages',
                                    ),
                                    controller: widget.scroll,
                                    padding: const EdgeInsets.only(
                                      top: 28,
                                      bottom: 24,
                                    ),
                                    children: <Widget>[
                                      _contentColumn(
                                        inset: inset,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: <Widget>[
                                            if (widget
                                                    .chat
                                                    .displayMessages
                                                    .isEmpty &&
                                                widget.chat.plan == null &&
                                                !widget.chat.submitting &&
                                                widget.chat.run == null)
                                              Padding(
                                                padding: EdgeInsets.only(
                                                  top: math.max(
                                                    20,
                                                    constraints.maxHeight * .20,
                                                  ),
                                                ),
                                                child: Text(
                                                  '把事情交代给知序',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: colors.ink,
                                                    fontSize: 28,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ),
                                            for (final Map<String, dynamic>
                                                message
                                                in widget.chat.displayMessages)
                                              _message(
                                                message,
                                                enabled,
                                                colors,
                                              ),
                                            if (widget.chat.plan != null &&
                                                widget.chat.run?['status'] ==
                                                    'waitingConfirmation')
                                              AssistantPlanCard(
                                                plan: widget.chat.plan!,
                                                enabled:
                                                    enabled &&
                                                    !widget.chat.busy &&
                                                    !widget.chat.offline &&
                                                    widget.chat.pending ==
                                                        null &&
                                                    widget.chat.draft
                                                        .trim()
                                                        .isEmpty &&
                                                    widget
                                                            .chat
                                                            .run?['timingPending'] !=
                                                        true &&
                                                    widget
                                                            .chat
                                                            .run?['requiresTakeover'] !=
                                                        true,
                                                onDecision: (String value) =>
                                                    unawaited(
                                                      widget.chat.decide(value),
                                                    ),
                                                onEdit: () {
                                                  widget.input.text = '修改方案：';
                                                  widget.chat.setDraft(
                                                    widget.input.text,
                                                    clearReference: true,
                                                  );
                                                  widget.inputFocus
                                                      .requestFocus();
                                                },
                                              ),
                                            if (widget.chat.submitting)
                                              _pendingProgress(colors)
                                            else if (widget.chat.run != null &&
                                                !widget.chat.messages.any(
                                                  (message) =>
                                                      message['role'] ==
                                                          'assistant' &&
                                                      message['id'] ==
                                                          widget
                                                              .chat
                                                              .run?['answerMessageId'],
                                                ))
                                              Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: <Widget>[
                                                  _pendingProgress(colors),
                                                  _runActions(enabled, colors),
                                                ],
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                          // 错误不能随底部反向滚动的附件输入区一起被裁掉。
                          _contentColumn(
                            inset: inset,
                            child: _status(
                              settings,
                              colors,
                              constraints.maxHeight,
                            ),
                          ),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: constraints.maxHeight * .52,
                            ),
                            child: SingleChildScrollView(
                              reverse: true,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  top: 8,
                                  bottom: 18,
                                ),
                                child: _contentColumn(
                                  inset: inset,
                                  child: _composer(settings, colors),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 历史条目把标题与悬停操作分开，出现按钮时不会推动整行。
class _AssistantConversationRow extends StatefulWidget {
  /// 条目真实会话。
  final Map<String, dynamic> conversation;

  /// 当前选中状态。
  final bool selected;

  /// 颜色与工作区保持一致。
  final AssistantWindowsPalette colors;

  /// 选择会话回调。
  final VoidCallback? onSelect;

  /// 置顶或取消置顶回调。
  final VoidCallback? onPin;

  /// 删除明确条目回调。
  final VoidCallback? onDelete;

  /// 重命名明确条目回调。
  final VoidCallback? onRename;

  /// 打开右键菜单回调。
  final ValueChanged<Offset> onContextMenu;

  /// 创建保留键盘访问的历史行。
  const _AssistantConversationRow({
    required this.conversation,
    required this.selected,
    required this.colors,
    required this.onSelect,
    required this.onPin,
    required this.onDelete,
    required this.onRename,
    required this.onContextMenu,
    super.key,
  });

  /// 创建悬停状态。
  @override
  State<_AssistantConversationRow> createState() =>
      _AssistantConversationRowState();
}

/// 只在鼠标或焦点位于本行时展示尾部操作。
class _AssistantConversationRowState extends State<_AssistantConversationRow> {
  /// 当前鼠标是否位于整行。
  bool _hovered = false;

  /// 当前键盘焦点是否属于整行。
  bool _focused = false;

  /// 构建固定高度的历史标题与两枚独立操作。
  @override
  Widget build(BuildContext context) {
    // 条目真实身份用于独立测试定位。
    final String id = widget.conversation['id'] as String;
    // 鼠标或键盘均可展开操作。
    final bool actions = _hovered || _focused;
    // 沿用原悬停的实际混合色，选中、悬停和焦点共用同一层背景。
    final Color highlighted = Color.alphaBlend(
      Theme.of(context).hoverColor,
      widget.colors.soft,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Focus(
          onFocusChange: (bool value) => setState(() => _focused = value),
          onKeyEvent: (FocusNode node, KeyEvent event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.f2 &&
                widget.onRename != null) {
              widget.onRename!();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Material(
            color: widget.selected || actions
                ? highlighted
                : widget.colors.sidebar,
            borderRadius: BorderRadius.circular(
              AssistantWindowsMetrics.rowRadius,
            ),
            child: OmniInkWell(
              // 表面已负责交互底色，墨水不再叠加悬停或焦点色。
              hoverColor: Colors.transparent,
              focusColor: Colors.transparent,
              onTap: widget.onSelect,
              onSecondaryTapDown: (TapDownDetails details) =>
                  widget.onContextMenu(details.globalPosition),
              borderRadius: BorderRadius.circular(
                AssistantWindowsMetrics.rowRadius,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AssistantWindowsMetrics.historyHeight,
                ),
                child: Stack(
                  alignment: Alignment.centerRight,
                  children: <Widget>[
                    Padding(
                      padding: EdgeInsets.fromLTRB(10, 6, actions ? 68 : 10, 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${widget.conversation['title'] ?? '新聊天'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.colors.ink,
                            fontSize: AssistantWindowsMetrics.historyFontSize,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                    ExcludeFocus(
                      excluding: !actions,
                      child: ExcludeSemantics(
                        excluding: !actions,
                        child: IgnorePointer(
                          ignoring: !actions,
                          child: AnimatedOpacity(
                            opacity: actions ? 1 : 0,
                            duration: OmniMotion.duration(
                              context,
                              OmniMotion.fast,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.only(right: 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  OmniIconButton(
                                    key: ValueKey<String>('assistant-pin-$id'),
                                    constraints: const BoxConstraints.tightFor(
                                      width: AssistantWindowsMetrics
                                          .historyActionSize,
                                      height: AssistantWindowsMetrics
                                          .historyActionSize,
                                    ),
                                    icon: Icon(
                                      widget.conversation['isPinned'] != true
                                          ? Icons.push_pin_outlined
                                          : Icons.push_pin,
                                    ),
                                    tooltip:
                                        widget.conversation['isPinned'] != true
                                        ? '置顶聊天'
                                        : '取消置顶',
                                    onPressed: widget.onPin,
                                    iconSize: 16,
                                  ),
                                  OmniIconButton(
                                    key: ValueKey<String>(
                                      'assistant-delete-$id',
                                    ),
                                    constraints: const BoxConstraints.tightFor(
                                      width: AssistantWindowsMetrics
                                          .historyActionSize,
                                      height: AssistantWindowsMetrics
                                          .historyActionSize,
                                    ),
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: '删除聊天',
                                    onPressed: widget.onDelete,
                                    iconSize: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 模型面板以真实按钮为锚点，完整保留当前配置名称与选择勾。
class _AssistantModelPicker extends StatelessWidget {
  /// 输入栏按钮的窗口坐标。
  final Rect anchor;

  /// 当前服务器全部模型配置。
  final List<Map<String, dynamic>> profiles;

  /// 已保存的全局默认配置。
  final String? selectedId;

  /// 创建向上弹出的模型列表。
  const _AssistantModelPicker({
    required this.anchor,
    required this.profiles,
    required this.selectedId,
  });

  /// 只有模型名称重复时附加配置名称，便于区分不同服务端的同款模型。
  String _profileLabel(
    Map<String, dynamic> profile,
    Map<String, int> modelCounts,
  ) {
    // 普通配置维持原来的紧凑模型标签。
    final String model = '${profile['model'] ?? profile['name'] ?? '模型'}';
    // 用户保存的配置名称只用于重名消歧。
    final String name = '${profile['name'] ?? ''}'.trim();
    return (modelCounts[model] ?? 0) > 1 && name.isNotEmpty && name != model
        ? '$model · $name'
        : model;
  }

  /// 构建跟随窗口大小钳制的选择面板。
  @override
  Widget build(BuildContext context) {
    // 本页面浮层使用同组中性色。
    final AssistantWindowsPalette colors = AssistantWindowsPalette.of(context);
    // 按实际显示模型名统计重复项，避免菜单逐行重复扫描配置。
    final Map<String, int> modelCounts = <String, int>{};
    // 每个服务端配置仍保留独立身份，名称只用于展示。
    for (final Map<String, dynamic> profile in profiles) {
      // 与菜单标签采用相同的兼容回退规则。
      final String model = '${profile['model'] ?? profile['name'] ?? '模型'}';
      modelCounts[model] = (modelCounts[model] ?? 0) + 1;
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 浮层已使用覆盖层坐标，边缘避让在同一坐标系内计算。
        final EdgeInsets safe = MediaQuery.paddingOf(context);
        // 窄窗口菜单保持完整留白。
        final double width = math.min(
          AssistantWindowsMetrics.modelWidth,
          math.max(0, constraints.maxWidth - safe.horizontal - 24),
        );
        // 菜单与模型按钮水平居中，靠近窗口边缘时仍保留安全留白。
        final double left = (anchor.center.dx - width / 2).clamp(
          safe.left + 12,
          math.max(
            safe.left + 12,
            constraints.maxWidth - safe.right - width - 12,
          ),
        );
        // 从按钮上边向上展开，短窗口限制可滚动高度。
        final double bottom = math.max(
          safe.bottom + 12,
          constraints.maxHeight - anchor.top + 8,
        );
        // 保证高字号时不会超出窗口上边缘。
        final double maxHeight = math.max(
          0,
          math.min(460, constraints.maxHeight - bottom - safe.top - 12),
        );
        return Stack(
          children: <Widget>[
            Positioned(
              left: left,
              bottom: bottom,
              width: width,
              child: Material(
                key: const ValueKey<String>('assistant-model-menu'),
                color: colors.canvas,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    AssistantWindowsMetrics.modelRadius,
                  ),
                  side: BorderSide(color: colors.line),
                ),
                clipBehavior: Clip.antiAlias,
                elevation: 6,
                shadowColor: Colors.black.withValues(alpha: .12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                            child: Text(
                              '选择模型',
                              style: TextStyle(
                                color: colors.muted,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          if (profiles.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                '请先在 AI 设置中添加模型配置。',
                                style: TextStyle(color: colors.muted),
                              ),
                            ),
                          for (final Map<String, dynamic> profile in profiles)
                            Material(
                              // 选中状态由勾号表达，底色只响应悬停。
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(
                                AssistantWindowsMetrics.rowRadius,
                              ),
                              child: OmniInkWell(
                                key: ValueKey<String>(
                                  'assistant-model-${profile['id']}',
                                ),
                                hoverColor: colors.soft,
                                onTap: profile['hasApiKey'] == true
                                    ? () =>
                                          Navigator.of(context)
                                              .pop(profile['id'] as String)
                                    : null,
                                borderRadius: BorderRadius.circular(
                                  AssistantWindowsMetrics.rowRadius,
                                ),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight:
                                        AssistantWindowsMetrics.modelRowHeight,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: <Widget>[
                                        Expanded(
                                          child: Text(
                                            _profileLabel(profile, modelCounts),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 14,
                                              height: 1.4,
                                              color:
                                                  profile['hasApiKey'] == true
                                                  ? colors.ink
                                                  : colors.muted,
                                            ),
                                          ),
                                        ),
                                        if (profile['id'] == selectedId)
                                          Icon(
                                            Icons.check,
                                            color: colors.ink,
                                            size: 16,
                                          ),
                                        if (profile['hasApiKey'] != true)
                                          Text(
                                            '未配置密钥',
                                            style: TextStyle(
                                              color: colors.muted,
                                              fontSize: 12,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
