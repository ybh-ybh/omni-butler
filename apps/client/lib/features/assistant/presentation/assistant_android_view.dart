import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/assistant/data/assistant_chat_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_voice_controller.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_android_sidebar.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_attachment_widgets.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_cards.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_execution_progress.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_loading_indicator.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_recording_overlay.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_voice_input_target.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Android presentation keeps the existing chat and voice ownership intact.
class AssistantAndroidView extends ConsumerStatefulWidget {
  /// Current authenticated conversation state.
  final AssistantChatController chat;

  /// Shared draft and selection controller.
  final TextEditingController input;

  /// Shared native text input focus.
  final FocusNode inputFocus;

  /// Shared conversation scroll position.
  final ScrollController scroll;

  /// Existing bounded speech session controller.
  final AssistantVoiceController voice;

  /// Route, lifecycle and source ownership remain separate from send eligibility.
  final bool voiceContextCurrent;

  /// Current permission and task gates for starting speech.
  final bool canVoiceInput;

  /// Current server setting and connection gate.
  final bool enabled;

  /// Original idempotent message submission.
  final Future<void> Function() onSend;

  /// Original explicit continuation action.
  final Future<void> Function() onContinue;

  /// Starts one manual-release speech session.
  final Future<void> Function() onStartVoice;

  /// Deletes the explicitly selected conversation.
  final Future<void> Function(String id) onDelete;

  /// Renames the explicitly selected conversation.
  final Future<void> Function(String id) onRename;

  /// Retains existing message cards and business interactions.
  final Widget Function(
    Map<String, dynamic> message,
    bool enabled, {
    Widget? leading,
    Widget? footer,
  })
  messageBuilder;

  /// Creates the Android workspace without replacing its data controllers.
  const AssistantAndroidView({
    required this.chat,
    required this.input,
    required this.inputFocus,
    required this.scroll,
    required this.voice,
    required this.canVoiceInput,
    required this.voiceContextCurrent,
    required this.enabled,
    required this.onSend,
    required this.onContinue,
    required this.onStartVoice,
    required this.onDelete,
    required this.onRename,
    required this.messageBuilder,
    super.key,
  });

  /// Owns presentation animation and one active press gesture.
  @override
  ConsumerState<AssistantAndroidView> createState() =>
      _AssistantAndroidViewState();
}

/// Local state never becomes the source of truth for messages or audio.
class _AssistantAndroidViewState extends ConsumerState<AssistantAndroidView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// Drawer progress also supports direct drag takeover.
  late final AnimationController _drawer = AnimationController(vsync: this);

  /// Requested drawer destination keeps the main page inaccessible in transit.
  bool _drawerOpen = false;

  /// Manual connection refresh owns only its local presentation state.
  bool _refreshing = false;

  /// Text and hold-to-talk are local input presentation modes.
  bool _voiceMode = false;

  /// Anchor the root overlay to the actual keyboard-safe composer geometry.
  final GlobalKey _composerAnchor = GlobalKey(
    debugLabel: 'assistant-composer-anchor',
  );

  /// The overlay is presentation-only and never creates a second speech session.
  OverlayEntry? _recordingEntry;

  /// Cancelled sessions must not recreate an overlay while cleanup is in flight.
  bool _overlaySuppressed = false;

  /// Only the original finger can finish this recording.
  int? _pointer;

  /// Initial screen position defines the cancellation threshold.
  double _pointerStartY = 0;

  /// A generation rejects callbacks from a cancelled press.
  int _gestureGeneration = 0;

  /// Moving back below the threshold restores normal release behavior.
  bool _cancelOnRelease = false;

  /// A final transcript may arrive after the finger was released.
  bool _awaitingVoiceResult = false;

  /// Previous phase identifies completion without changing the pressed subtree.
  AssistantVoicePhase _previousVoicePhase = AssistantVoicePhase.idle;

  /// Attaches listeners without taking over controller disposal.
  @override
  void initState() {
    super.initState();
    widget.input.addListener(_inputChanged);
    widget.inputFocus.addListener(_focusChanged);
    widget.voice.addListener(_voiceChanged);
    widget.chat.addListener(_chatChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  /// Rebinds external objects if a parent supplies a new instance.
  @override
  void didUpdateWidget(covariant AssistantAndroidView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.input != widget.input) {
      oldWidget.input.removeListener(_inputChanged);
      widget.input.addListener(_inputChanged);
    }
    if (oldWidget.inputFocus != widget.inputFocus) {
      oldWidget.inputFocus.removeListener(_focusChanged);
      widget.inputFocus.addListener(_focusChanged);
    }
    if (oldWidget.voice != widget.voice) {
      _removeRecordingOverlay();
      oldWidget.voice.removeListener(_voiceChanged);
      widget.voice.addListener(_voiceChanged);
      _pointer = null;
      _gestureGeneration++;
      _awaitingVoiceResult = false;
    }
    if (!widget.voiceContextCurrent && widget.voice.busy) {
      _overlaySuppressed = true;
      _removeRecordingOverlay();
      // Guard delayed cleanup against a later gesture or controller replacement.
      final int generation = ++_gestureGeneration;
      // Fix the controller whose source or route became unavailable.
      final AssistantVoiceController voice = widget.voice;
      _pointer = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            generation == _gestureGeneration &&
            identical(widget.voice, voice) &&
            !widget.voiceContextCurrent) {
          unawaited(voice.cancel());
        }
      });
    }
    if (oldWidget.chat != widget.chat) {
      oldWidget.chat.removeListener(_chatChanged);
      widget.chat.addListener(_chatChanged);
    }
  }

  /// Releases only view-owned listeners and animation resources.
  @override
  void dispose() {
    _gestureGeneration++;
    _removeRecordingOverlay();
    _pointer = null;
    _awaitingVoiceResult = false;
    _cancelOnRelease = false;
    widget.input.removeListener(_inputChanged);
    widget.inputFocus.removeListener(_focusChanged);
    widget.voice.removeListener(_voiceChanged);
    widget.chat.removeListener(_chatChanged);
    WidgetsBinding.instance.removeObserver(this);
    _drawer.dispose();
    super.dispose();
  }

  /// Native permission dialogs invalidate a held press before they can resume it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || state == AppLifecycleState.resumed) return;
    if (_pointer != null) {
      unawaited(_cancelPress());
    } else if (_awaitingVoiceResult && widget.voice.busy) {
      _awaitingVoiceResult = false;
      _overlaySuppressed = true;
      _removeRecordingOverlay();
      unawaited(widget.voice.cancel());
    }
  }

  /// Draft changes may reveal a send action without replacing the voice target.
  void _inputChanged() {
    _recordingEntry?.markNeedsBuild();
    if (mounted) setState(() {});
  }

  /// Reopen a hidden IME even when an empty field still owns native focus.
  void _focusInput() {
    // A focused field may keep its connection after the keyboard was dismissed.
    final bool alreadyFocused = widget.inputFocus.hasFocus;
    widget.inputFocus.requestFocus();
    if (alreadyFocused) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    }
  }

  /// Native selection remains available while a nonempty field has focus.
  void _focusChanged() {
    if (mounted) setState(() {});
  }

  /// Root overlays cover bottom navigation without pushing or cancelling a route.
  void _syncRecordingOverlay() {
    if (!mounted) return;
    if (!widget.voice.busy || _overlaySuppressed) {
      _removeRecordingOverlay();
      return;
    }
    if (_recordingEntry != null) {
      _recordingEntry!.markNeedsBuild();
      return;
    }
    _recordingEntry = OverlayEntry(
      builder: (_) => InheritedTheme.captureAll(
        context,
        AssistantRecordingOverlay(
          input: widget.input,
          voice: widget.voice,
          anchorKey: _composerAnchor,
          cancelOnRelease: _cancelOnRelease,
          onFinish: _semanticVoice,
          onCancel: () => unawaited(_cancelPress()),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_recordingEntry!);
  }

  /// Explicit cleanup also handles a route leaving before final transcription.
  void _removeRecordingOverlay() {
    _recordingEntry?.remove();
    _recordingEntry?.dispose();
    _recordingEntry = null;
  }

  /// Chat failures return hidden speech text to the editable surface.
  void _chatChanged() {
    if (!mounted) return;
    if (!widget.voice.busy && widget.chat.error != null) _voiceMode = false;
    setState(() {});
  }

  /// Finishing or failing speech does not rely on the pointer still being down.
  void _voiceChanged() {
    if (!mounted) return;
    // A terminal voice state leaves any retained draft visible on failure.
    final bool completed =
        _previousVoicePhase != AssistantVoicePhase.idle &&
        widget.voice.phase == AssistantVoicePhase.idle;
    if (completed) {
      _pointer = null;
      _cancelOnRelease = false;
      _awaitingVoiceResult = false;
      _overlaySuppressed = false;
    }
    // Submission may fail after the controller has already entered idle.
    if (widget.voice.phase == AssistantVoicePhase.idle &&
        widget.voice.message != null) {
      _voiceMode = false;
    }
    _previousVoicePhase = widget.voice.phase;
    _syncRecordingOverlay();
    setState(() {});
  }

  /// The explicit microphone mode retains its original immediate hold behavior.
  void _pointerDown(PointerDownEvent event) {
    if (_voiceMode) {
      _beginHold(event.pointer, event.position);
    }
  }

  /// Both hold surfaces share one original pointer and one speech generation.
  void _beginHold(int pointer, Offset origin) {
    if (!mounted ||
        _pointer != null ||
        widget.voice.busy ||
        !widget.canVoiceInput) {
      return;
    }
    _pointer = pointer;
    _pointerStartY = origin.dy;
    _cancelOnRelease = false;
    _awaitingVoiceResult = true;
    _overlaySuppressed = false;
    // Completion from an older press must not reset a newer pointer.
    final int generation = ++_gestureGeneration;
    setState(() {});
    unawaited(_startPress(generation));
  }

  /// A rejected start releases its own pointer without touching a later press.
  Future<void> _startPress(int generation) async {
    await widget.onStartVoice();
    if (!mounted || generation != _gestureGeneration) return;
    if (!widget.voice.busy && _pointer != null) {
      setState(() {
        _pointer = null;
        _awaitingVoiceResult = false;
        _cancelOnRelease = false;
        _voiceMode = false;
      });
    }
  }

  /// The cancel preview is reversible while the original finger remains down.
  void _pointerMove(PointerMoveEvent event) {
    if (!mounted || event.pointer != _pointer) return;
    // Distances use logical pixels, independent of display density.
    final bool cancel = _pointerStartY - event.position.dy >= 64;
    if (cancel != _cancelOnRelease) {
      setState(() => _cancelOnRelease = cancel);
      _recordingEntry?.markNeedsBuild();
    }
  }

  /// Only a live recording can turn a normal release into a final request.
  void _pointerUp(PointerUpEvent event) {
    if (!mounted || event.pointer != _pointer) return;
    // Snapshot the decision before removing the active pointer.
    final bool cancel = _cancelOnRelease;
    _pointer = null;
    _cancelOnRelease = false;
    setState(() {});
    if (cancel || widget.voice.phase == AssistantVoicePhase.preparing) {
      unawaited(_cancelPress());
      return;
    }
    if (widget.voice.phase == AssistantVoicePhase.recording) {
      unawaited(widget.voice.finish());
    }
  }

  /// Gesture cancellation restores exactly the snapshot captured by the session.
  Future<void> _cancelPress() async {
    if (!mounted) return;
    _overlaySuppressed = true;
    _removeRecordingOverlay();
    _gestureGeneration++;
    _pointer = null;
    _cancelOnRelease = false;
    _awaitingVoiceResult = false;
    setState(() {});
    await widget.voice.cancel(restoreInitial: true);
  }

  /// Switching input mode preserves text, attachments and insertion selection.
  void _toggleInputMode() {
    if (widget.voice.busy) return;
    setState(() => _voiceMode = !_voiceMode);
    if (_voiceMode) {
      widget.inputFocus.unfocus();
    } else {
      widget.inputFocus.requestFocus();
    }
  }

  /// Opens history after synchronously invalidating speech and hiding the IME.
  void _openSidebar() {
    widget.inputFocus.unfocus();
    if (_pointer != null) {
      unawaited(_cancelPress());
    } else if (widget.voice.busy) {
      _awaitingVoiceResult = false;
      unawaited(widget.voice.cancel());
    }
    _animateDrawer(true);
  }

  /// Transitions continue from their current visible position.
  void _animateDrawer(bool open) {
    setState(() => _drawerOpen = open);
    if (OmniMotion.reduce(context)) {
      _drawer.value = open ? 1 : 0;
      return;
    }
    unawaited(
      _drawer.animateTo(
        open ? 1 : 0,
        duration: open
            ? OmniMotion.androidModalEnter
            : OmniMotion.androidModalExit,
        curve: OmniMotion.standardCurve,
      ),
    );
  }

  /// A dragged drawer snaps closed or restores its full width.
  void _finishDrawerDrag(DragEndDetails details) {
    _animateDrawer(
      !(_drawer.value < .72 || details.velocity.pixelsPerSecond.dx < -500),
    );
  }

  /// Conversation selection keeps existing cache and submission boundaries.
  void _selectConversation(String id) {
    _animateDrawer(false);
    _voiceMode = false;
    unawaited(widget.chat.select(id));
  }

  /// A new conversation remains a local draft until its first submission.
  void _newConversation() {
    if (!widget.chat.connected ||
        widget.chat.busy ||
        widget.chat.pending != null ||
        widget.voice.busy) {
      return;
    }
    widget.inputFocus.unfocus();
    setState(() => _voiceMode = false);
    unawaited(widget.chat.create());
  }

  /// Android back closes local surfaces before returning to the existing home.
  Future<void> _back() async {
    if (_recordingEntry != null || _pointer != null || widget.voice.busy) {
      await _cancelPress();
      return;
    }
    if (MediaQuery.viewInsetsOf(context).bottom > 0 ||
        widget.inputFocus.hasFocus) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    if (_drawerOpen || _drawer.value > 0) {
      _animateDrawer(false);
      return;
    }
    if (_pointer != null) {
      await _cancelPress();
    } else if (widget.voice.busy) {
      await widget.voice.cancel();
    }
    if (mounted) GoRouter.maybeOf(context)?.go('/home');
  }

  /// A narrow centered title has equal-sized leading and trailing touch targets.
  Widget _header() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
    child: Row(
      children: <Widget>[
        OmniIconButton(
          key: const ValueKey<String>('assistant-history-button'),
          icon: const Icon(Icons.menu_open_rounded),
          tooltip: '历史对话',
          onPressed: _openSidebar,
        ),
        Expanded(
          child: Text(
            widget.chat.conversations
                        .where(
                          (item) => item['id'] == widget.chat.conversationId,
                        )
                        .firstOrNull?['title']
                    as String? ??
                '新对话',
            key: const ValueKey<String>('assistant-android-title'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        OmniIconButton(
          key: const ValueKey<String>('assistant-new-conversation-button'),
          icon: const Icon(Icons.add_comment_outlined),
          tooltip: '新对话',
          onPressed:
              widget.chat.connected &&
                  !widget.chat.busy &&
                  widget.chat.pending == null &&
                  !widget.voice.busy
              ? _newConversation
              : null,
        ),
      ],
    ),
  );

  /// Empty content is centered in the currently available keyboard-safe space.
  Widget _welcome() => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(OmniSpacing.lg),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Image.asset(
                  'assets/icon/app_icon.png',
                  width: 44,
                  height: 44,
                  excludeFromSemantics: true,
                ),
                const SizedBox(height: OmniSpacing.sm),
                Text(
                  '今天有什么可以帮到你？',
                  key: const ValueKey<String>('assistant-android-welcome'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// Raw errors remain intact; only task failures receive a short projection.
  String? get _failureMessage {
    if (widget.chat.run == null) return null;
    if (widget.chat.streamFailure?['runId'] == widget.chat.run?['id']) {
      return widget.chat.streamFailure?['message'] as String?;
    }
    if (<String>{
      'failed',
      'submissionUnknown',
    }.contains(widget.chat.run?['status'])) {
      return widget.chat.run?['errorMessage'] as String? ?? '';
    }
    return null;
  }

  /// Only the identical task error is suppressed above the conversation.
  bool get _showOperationError =>
      widget.chat.error != null &&
      (_failureMessage == null || widget.chat.error != _failureMessage);

  /// Attach failed-turn feedback to its user bubble before any partial answer.
  String? get _failureTargetId {
    if (_failureMessage == null) return null;
    // All candidates belong to the currently displayed conversation.
    final List<Map<String, dynamic>> messages = widget.chat.displayMessages;
    // Missing legacy identities fall back to the run placeholder.
    final String? taskId = widget.chat.run?['taskId'] as String?;
    for (final Map<String, dynamic> message in messages.reversed) {
      if (taskId != null &&
          message['role'] == 'user' &&
          message['taskId'] == taskId &&
          (message['conversationId'] ?? widget.chat.conversationId) ==
              (widget.chat.run?['conversationId'] ??
                  widget.chat.conversationId)) {
        return message['id'] as String?;
      }
    }
    // A partially delivered answer keeps its own failure feedback.
    final String? answerId = widget.chat.run?['answerMessageId'] as String?;
    if (answerId != null &&
        messages.any((message) => message['id'] == answerId)) {
      return answerId;
    }
    return null;
  }

  /// One explicit retry preserves the existing run and submission boundaries.
  Widget _retryButton() {
    // Capture identity so an old row cannot retry a newer run.
    final String? runId = widget.chat.run?['id'] as String?;
    // A stream error alone never grants permission to retry a running task.
    final bool canRetry =
        <String>{
          'failed',
          'submissionUnknown',
        }.contains(widget.chat.run?['status']) &&
        runId != null &&
        !widget.chat.busy &&
        widget.enabled &&
        widget.chat.connected &&
        !widget.chat.offline &&
        !widget.voice.busy &&
        widget.chat.pending == null;
    return OmniIconButton(
      key: ValueKey<String>('assistant-android-retry-$runId'),
      tooltip: '重试任务',
      // A small yellow disc sits inside the standard Android touch target.
      icon: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.amber.shade700,
          shape: BoxShape.circle,
        ),
        child: const SizedBox.square(
          dimension: 24,
          child: Icon(Icons.refresh_rounded, size: 17, color: Colors.white),
        ),
      ),
      onPressed: canRetry
          ? () {
              if (widget.chat.run?['id'] == runId &&
                  widget.chat.pending == null) {
                unawaited(widget.chat.retry());
              }
            }
          : null,
    );
  }

  /// Neutral failure text occupies one compact line beneath the user bubble.
  Widget _failureCaption() {
    // Unknown outcomes retain a distinct, neutral message.
    final bool unknown =
        widget.chat.run?['status'] == 'submissionUnknown' ||
        widget.chat.streamFailure?['code'] == 'AI_SUBMISSION_UNKNOWN';
    return Text(
      unknown ? '结果待确认' : '处理失败，请重试',
      key: ValueKey<String>(
        'assistant-android-failure-${widget.chat.run?['id']}',
      ),
      textAlign: TextAlign.right,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: AssistantWindowsPalette.of(context).muted),
    );
  }

  /// Legacy records without a user bubble still retain one recovery action.
  Widget _failureNotice() => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        _retryButton(),
        Flexible(child: _failureCaption()),
      ],
    ),
  );

  /// Existing plan and progress components preserve business authorization.
  Widget _messages() {
    // Resolve the matching message once rather than scanning for every row.
    final String? failureTargetId = _failureTargetId;
    return widget.chat.loading && widget.chat.displayMessages.isEmpty
        ? const Center(child: AssistantLoadingIndicator(animating: true))
        : widget.chat.displayMessages.isEmpty &&
              widget.chat.plan == null &&
              _failureMessage == null
        ? _welcome()
        : ListView(
            key: const ValueKey<String>('assistant-android-messages'),
            controller: widget.scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.symmetric(
              horizontal: OmniSpacing.lg,
              vertical: OmniSpacing.lg,
            ),
            children: <Widget>[
              for (final Map<String, dynamic> message
                  in widget.chat.displayMessages)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    widget.messageBuilder(
                      message,
                      widget.enabled,
                      leading:
                          failureTargetId == message['id'] &&
                              message['role'] == 'user'
                          ? _retryButton()
                          : null,
                      footer:
                          failureTargetId == message['id'] &&
                              message['role'] == 'user'
                          ? _failureCaption()
                          : null,
                    ),
                    if (_failureMessage != null &&
                        failureTargetId == message['id'] &&
                        message['role'] != 'user')
                      _failureNotice(),
                  ],
                ),
              if (widget.chat.run != null &&
                  !widget.chat.messages.any(
                    (message) =>
                        message['role'] == 'assistant' &&
                        message['id'] == widget.chat.run?['answerMessageId'],
                  ))
                AssistantExecutionProgress(
                  compact: true,
                  key: ValueKey<String>(
                    'assistant-progress-${widget.chat.run?['answerMessageId'] ?? widget.chat.run?['id']}',
                  ),
                  elapsedMs: widget.chat.liveElapsedMs,
                  running: widget.chat.processing,
                  steps: assistantItems(widget.chat.run?['executionSteps']),
                  colors: AssistantWindowsPalette.of(context),
                ),
              if (_failureMessage != null && failureTargetId == null)
                _failureNotice(),
              if (widget.chat.plan != null &&
                  widget.chat.run?['status'] == 'waitingConfirmation')
                AssistantPlanCard(
                  plan: widget.chat.plan!,
                  enabled:
                      widget.enabled &&
                      !widget.voice.busy &&
                      !widget.chat.busy &&
                      !widget.chat.offline &&
                      widget.chat.pending == null &&
                      widget.chat.draft.trim().isEmpty &&
                      widget.chat.run?['timingPending'] != true &&
                      widget.chat.run?['requiresTakeover'] != true,
                  onDecision: (value) => unawaited(widget.chat.decide(value)),
                  onEdit: () {
                    setState(() => _voiceMode = false);
                    widget.input.text = '修改方案：';
                    widget.chat.setDraft(
                      widget.input.text,
                      clearReference: true,
                    );
                    widget.inputFocus.requestFocus();
                  },
                ),
            ],
          );
  }

  /// Settings and network failures stay outside the reverse-scrolled composer.
  Widget _notices(
    AsyncValue<Map<String, dynamic>?> settings, {
    bool centered = true,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.stretch,
    children: <Widget>[
      if (widget.chat.connected &&
          !settings.isLoading &&
          (settings.hasError || settings.value?['enabled'] != true))
        Wrap(
          alignment: centered ? WrapAlignment.center : WrapAlignment.start,
          spacing: OmniSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(settings.hasError ? '无法读取助手设置，请重试' : '请在 AI 设置中选择助手模型并开启助手。'),
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
      if (_showOperationError)
        Wrap(
          alignment: centered ? WrapAlignment.center : WrapAlignment.start,
          spacing: OmniSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              widget.chat.error!,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                color: centered
                    ? AssistantWindowsPalette.of(context).muted
                    : OmniColors.of(context).danger,
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
              onPressed: widget.chat.connected && !_refreshing
                  ? _refreshConnection
                  : null,
            ),
          ],
        ),
      if (widget.chat.offline)
        Text(
          '当前仅显示本机缓存；恢复连接后核实服务器状态。',
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ],
  );

  /// Speech instructions describe the gesture, not the desktop toggle button.
  String? get _voiceStatus => switch (widget.voice.phase) {
    AssistantVoicePhase.preparing => '正在连接语音服务…',
    AssistantVoicePhase.recording => _cancelOnRelease ? '松开取消' : '松开发送，上滑取消',
    AssistantVoicePhase.finishing => '正在完成转写…',
    AssistantVoicePhase.idle => widget.voice.message,
  };

  /// Screen-reader actions expose the same controlled recording lifecycle.
  void _semanticVoice() {
    if (!mounted) return;
    if (widget.voice.phase == AssistantVoicePhase.recording) {
      unawaited(widget.voice.finish());
    } else if (!widget.voice.busy && widget.canVoiceInput) {
      _awaitingVoiceResult = true;
      _overlaySuppressed = false;
      unawaited(widget.onStartVoice());
    }
  }

  /// A stable raw-pointer surface survives partial transcript and draft updates.
  Widget _holdSurface() => Semantics(
    label: widget.voice.phase == AssistantVoicePhase.recording
        ? '结束录音并发送'
        : '按住说话',
    button: true,
    enabled: widget.canVoiceInput || widget.voice.busy,
    onTap: _semanticVoice,
    customSemanticsActions: widget.voice.busy
        ? <CustomSemanticsAction, VoidCallback>{
            const CustomSemanticsAction(label: '取消录音'): () =>
                unawaited(_cancelPress()),
          }
        : null,
    child: Listener(
      key: const ValueKey<String>('assistant-voice-hold'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: (event) {
        if (mounted && event.pointer == _pointer) unawaited(_cancelPress());
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OmniSize.touch),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: OmniSpacing.xs),
          child: Center(
            child: Text(
              widget.voice.phase == AssistantVoicePhase.preparing
                  ? '正在连接…'
                  : widget.voice.phase == AssistantVoicePhase.finishing
                  ? '正在转写…'
                  : _cancelOnRelease
                  ? '松开取消'
                  : widget.voice.phase == AssistantVoicePhase.recording
                  ? '松开发送'
                  : '按住说话',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: _cancelOnRelease
                    ? OmniColors.of(context).danger
                    : widget.canVoiceInput || widget.voice.busy
                    ? OmniColors.of(context).ink
                    : OmniColors.of(context).muted,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// The primary action keeps original stop, continue and replay gates.
  Widget _sendAction(Map<String, dynamic>? settings) {
    // Continuation is explicit when no new text replaces it.
    final bool continuing =
        widget.chat.canContinue && widget.input.text.trim().isEmpty;
    // Labels remain available to assistive technologies and automated tests.
    final String label = widget.chat.processing
        ? '停止'
        : continuing
        ? '开始'
        : widget.chat.pending == null
        ? '发送'
        : '恢复发送';
    // A single existing action owns the current button state.
    final VoidCallback? action = widget.voice.busy
        ? null
        : widget.chat.processing
        ? (widget.chat.canStop ? widget.chat.stop : null)
        : continuing
        ? (widget.enabled ? widget.onContinue : null)
        : widget.enabled &&
              !widget.chat.busy &&
              (widget.chat.pending != null ||
                  widget.chat.attachments.blockReason(
                        settings,
                        includeVision: false,
                      ) ==
                      null) &&
              (!widget.chat.active ||
                  widget.chat.run?['requiresTakeover'] != true) &&
              (widget.chat.pending != null ||
                  !widget.chat.active ||
                  <String>{
                    'waitingInput',
                    'waitingConfirmation',
                  }.contains(widget.chat.run?['status']))
        ? widget.onSend
        : null;
    return OmniIconButton(
      key: ValueKey<String>(
        widget.chat.processing
            ? 'assistant-stop-button'
            : continuing
            ? 'assistant-continue-button'
            : 'assistant-send-button',
      ),
      tooltip: label,
      onPressed: action,
      icon: Container(
        width: OmniSize.control,
        height: OmniSize.control,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: action == null
              ? OmniColors.of(context).line
              : Theme.of(context).colorScheme.primary,
        ),
        child: Icon(
          widget.chat.processing
              ? Icons.stop_rounded
              : continuing
              ? Icons.play_arrow_rounded
              : Icons.arrow_upward_rounded,
          color: action == null
              ? OmniColors.of(context).muted
              : Theme.of(context).colorScheme.onPrimary,
        ),
      ),
    );
  }

  /// Recovery actions stay available without adding permanent helper labels.
  Widget _composerNotices() => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (_voiceStatus != null && !widget.voice.busy)
        Padding(
          padding: const EdgeInsets.only(bottom: OmniSpacing.xs),
          child: Text(
            _voiceStatus!,
            key: const ValueKey<String>('assistant-voice-status'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: _cancelOnRelease
                  ? OmniColors.of(context).danger
                  : OmniColors.of(context).muted,
            ),
          ),
        ),
      if (widget.chat.recoveryReason != null) Text(widget.chat.recoveryReason!),
      if (widget.chat.draftReference != null)
        Wrap(
          spacing: OmniSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text('编辑目标：${widget.chat.draftReference!['label'] ?? '所选记录'}'),
            OmniButton(
              label: '取消定位',
              variant: OmniButtonVariant.text,
              onPressed: widget.voice.busy
                  ? null
                  : widget.chat.clearDraftReference,
            ),
          ],
        ),
      if (widget.chat.run != null &&
          (_failureMessage == null ||
              widget.chat.run?['requiresTakeover'] == true) &&
          widget.chat.run?['status'] != 'succeeded' &&
          (!widget.chat.processing ||
              widget.chat.run?['requiresTakeover'] == true))
        Wrap(
          spacing: OmniSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (_failureMessage == null)
              Text(
                widget.chat.run?['requiresTakeover'] == true &&
                        widget.chat.active
                    ? '任务由其他设备处理，请先接管'
                    : assistantStatusLabel(
                        widget.chat.run!['status'] as String?,
                      ),
              ),
            if (widget.chat.run?['requiresTakeover'] == true &&
                widget.chat.run?['status'] != 'cancelled')
              OmniButton(
                label: '在此设备接管',
                variant: OmniButtonVariant.text,
                onPressed:
                    !widget.chat.busy &&
                        widget.chat.connected &&
                        !widget.chat.offline &&
                        !widget.voice.busy
                    ? widget.chat.takeover
                    : null,
              ),
          ],
        ),
    ],
  );

  /// Inline editing borrows note geometry without opening a note editor route.
  Widget _composer(Map<String, dynamic>? settings) {
    // The paper surface follows the user's palette and brightness.
    final OmniColors colors = OmniColors.of(context);
    // Voice state takes precedence over transcript-driven draft changes.
    final bool speaking = _voiceMode || widget.voice.busy;
    // Additional actions appear only when there is meaningful work to perform.
    final bool showSend =
        widget.chat.processing ||
        widget.chat.canContinue ||
        widget.chat.pending != null ||
        (!speaking &&
            (widget.input.text.trim().isNotEmpty ||
                widget.chat.attachments.hasDrafts));
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OmniSpacing.lg,
        OmniSpacing.xs,
        OmniSpacing.lg,
        OmniSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _composerNotices(),
          if (!widget.chat.hideComposerDraft)
            AssistantAttachmentDrafts(
              attachments: widget.chat.attachments,
              settings: settings,
            ),
          KeyedSubtree(
            key: _composerAnchor,
            child: Material(
              key: const ValueKey<String>('assistant-android-composer'),
              color: colors.paper,
              elevation: 2,
              borderRadius: BorderRadius.circular(OmniRadius.pill),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  AssistantAttachmentButton(
                    alwaysVisible: true,
                    attachments: widget.chat.attachments,
                    enabled: widget.enabled && !widget.voice.busy,
                    icon: Icons.add,
                  ),
                  Expanded(
                    child: AssistantVoiceInputTarget(
                      active: _pointer != null,
                      enabled:
                          !_voiceMode &&
                          !widget.voice.busy &&
                          widget.canVoiceInput &&
                          (!widget.inputFocus.hasFocus ||
                              widget.input.text.isEmpty),
                      onTap: _focusInput,
                      onStart: _beginHold,
                      onMove: _pointerMove,
                      onEnd: _pointerUp,
                      onCancel: () => unawaited(_cancelPress()),
                      child: speaking
                          ? _holdSurface()
                          : OmniTextField(
                              key: const ValueKey<String>('assistant-input'),
                              controller: widget.input,
                              focusNode: widget.inputFocus,
                              minLines: 1,
                              maxLines: 5,
                              maxLength: 20000,
                              style: Theme.of(context).textTheme.bodyLarge,
                              textAlignVertical: TextAlignVertical.center,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              enabled: widget.enabled && !widget.chat.loading,
                              readOnly:
                                  widget.chat.busy ||
                                  widget.chat.pending != null,
                              onChanged: widget.chat.setDraft,
                              decoration: InputDecoration(
                                hintText: '发消息',
                                hintStyle: TextStyle(color: colors.muted),
                                counterText: '',
                                isDense: true,
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                                visualDensity: VisualDensity.standard,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: OmniSpacing.sm,
                                ),
                                constraints: const BoxConstraints(
                                  minHeight: OmniSize.touch,
                                ),
                              ),
                            ),
                    ),
                  ),
                  OmniIconButton(
                    key: const ValueKey<String>('assistant-voice-button'),
                    tooltip: speaking ? '键盘输入' : '语音输入',
                    icon: Icon(
                      speaking ? Icons.keyboard_outlined : Icons.mic_none,
                    ),
                    onPressed: widget.voice.busy
                        ? null
                        : (speaking || widget.canVoiceInput)
                        ? _toggleInputMode
                        : null,
                  ),
                  if (showSend) _sendAction(settings),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Retry reads server facts without resubmitting a chat message.
  Future<void> _refreshConnection() async {
    if (_refreshing || !mounted) return;
    setState(() => _refreshing = true);
    try {
      await widget.chat.refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Center the loading mark while keeping errors directly below its position.
  Widget _connectionStatus(AsyncValue<Map<String, dynamic>?> settings) =>
      LayoutBuilder(
        builder: (context, constraints) {
          // Requests stop animating once a failure is known; retry starts them again.
          final bool animating =
              widget.chat.loading ||
              _refreshing ||
              (widget.chat.connected && settings.isLoading);
          // Short keyboard windows use a scrollable group instead of clipping notices.
          final bool short = constraints.maxHeight < 420;
          // Read the same notices and recovery actions without repeating a top banner.
          final Widget notices = Padding(
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.lg),
            child: _notices(settings),
          );
          return short
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: math.min(56, constraints.maxHeight * .2),
                      bottom: math.min(112, constraints.maxHeight * .25),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          AssistantLoadingIndicator(
                            key: const ValueKey<String>(
                              'assistant-connection-spinner',
                            ),
                            animating: animating,
                          ),
                          const SizedBox(height: 16),
                          notices,
                        ],
                      ),
                    ),
                  ),
                )
              : Stack(
                  children: <Widget>[
                    Center(
                      child: AssistantLoadingIndicator(
                        key: const ValueKey<String>(
                          'assistant-connection-spinner',
                        ),
                        animating: animating,
                      ),
                    ),
                    Positioned(
                      top: constraints.maxHeight / 2 + 48,
                      left: 0,
                      right: 0,
                      bottom: 112,
                      child: SingleChildScrollView(child: notices),
                    ),
                  ],
                );
        },
      );

  /// The outer route performs keyboard avoidance once for the whole workspace.
  Widget _workspace(AsyncValue<Map<String, dynamic>?> settings) =>
      LayoutBuilder(
        builder: (context, constraints) {
          // Existing messages and business results remain visible during reconnects.
          final bool empty =
              widget.chat.displayMessages.isEmpty &&
              widget.chat.run == null &&
              widget.chat.plan == null;
          // Initialization and empty-page connection failures share one status surface.
          final bool connectionStatus =
              empty &&
              (widget.chat.loading ||
                  _refreshing ||
                  (widget.chat.connected && settings.isLoading) ||
                  _showOperationError ||
                  widget.chat.offline);
          // Only exceptional state takes space above the conversation content.
          final bool notices =
              _showOperationError ||
              widget.chat.offline ||
              (widget.chat.connected &&
                  !settings.isLoading &&
                  (settings.hasError || settings.value?['enabled'] != true));
          return Stack(
            children: <Widget>[
              Column(
                children: <Widget>[
                  _header(),
                  if (!connectionStatus &&
                      widget.chat.connected &&
                      settings.isLoading)
                    const LinearProgressIndicator(),
                  if (notices && !connectionStatus)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * .24,
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: OmniSpacing.lg,
                        ),
                        child: _notices(settings, centered: false),
                      ),
                    ),
                  Expanded(
                    child: connectionStatus
                        ? const SizedBox.expand()
                        : _messages(),
                  ),
                  if (widget.chat.busy && !connectionStatus)
                    const LinearProgressIndicator(),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .5,
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: _composer(settings.value),
                    ),
                  ),
                ],
              ),
              if (connectionStatus)
                Positioned.fill(child: _connectionStatus(settings)),
            ],
          );
        },
      );

  /// Main content is pushed aside instead of being covered by a modal sheet.
  @override
  Widget build(BuildContext context) {
    // The existing settings provider is shared with desktop and the parent page.
    final AsyncValue<Map<String, dynamic>?> settings = ref.watch(
      assistantSettingsProvider,
    );
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_back());
      },
      child: ColoredBox(
        color: OmniColors.of(context).paper,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The exposed page edge remains a usable dismissal target.
            final double drawerWidth = math.min(constraints.maxWidth * .8, 360);
            return AnimatedBuilder(
              animation: _drawer,
              builder: (context, child) {
                // Keep the page blocked during both entering and leaving.
                final bool blocked = _drawerOpen || _drawer.value > 0;
                return Stack(
                  children: <Widget>[
                    if (blocked)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: drawerWidth,
                        child: GestureDetector(
                          onHorizontalDragStart: (_) => _drawer.stop(),
                          onHorizontalDragUpdate: (details) {
                            _drawer.value =
                                (_drawer.value + details.delta.dx / drawerWidth)
                                    .clamp(0, 1);
                          },
                          onHorizontalDragEnd: _finishDrawerDrag,
                          onHorizontalDragCancel: () => _animateDrawer(true),
                          child: AssistantAndroidSidebar(
                            chat: widget.chat,
                            voiceBusy: widget.voice.busy,
                            onSelected: _selectConversation,
                            onRename: widget.onRename,
                            onDelete: widget.onDelete,
                            onClose: () => _animateDrawer(false),
                          ),
                        ),
                      ),
                    Transform.translate(
                      offset: Offset(drawerWidth * _drawer.value, 0),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: OmniSpacing.sm * _drawer.value,
                        ),
                        child: Material(
                          color: OmniColors.of(context).paper,
                          elevation: 4 * _drawer.value,
                          borderRadius: BorderRadius.circular(
                            OmniRadius.dialog * _drawer.value,
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            fit: StackFit.expand,
                            children: <Widget>[
                              ExcludeSemantics(
                                excluding: blocked,
                                child: ExcludeFocus(
                                  excluding: blocked,
                                  child: IgnorePointer(
                                    ignoring: blocked,
                                    child: child,
                                  ),
                                ),
                              ),
                              if (blocked)
                                Semantics(
                                  label: '关闭历史对话',
                                  button: true,
                                  child: GestureDetector(
                                    key: const ValueKey<String>(
                                      'assistant-sidebar-close',
                                    ),
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => _animateDrawer(false),
                                    onHorizontalDragStart: (_) =>
                                        _drawer.stop(),
                                    onHorizontalDragUpdate: (details) {
                                      _drawer.value =
                                          (_drawer.value +
                                                  details.delta.dx /
                                                      drawerWidth)
                                              .clamp(0, 1);
                                    },
                                    onHorizontalDragEnd: _finishDrawerDrag,
                                    onHorizontalDragCancel: () =>
                                        _animateDrawer(true),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
              child: _workspace(settings),
            );
          },
        ),
      ),
    );
  }
}
