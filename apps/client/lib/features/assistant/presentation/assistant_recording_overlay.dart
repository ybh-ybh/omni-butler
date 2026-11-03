import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/assistant/data/assistant_voice_controller.dart';

/// A root-overlay speech preview never owns audio or copies transcription state.
class AssistantRecordingOverlay extends StatefulWidget {
  /// The same text value that will be sent after the final transcript arrives.
  final TextEditingController input;

  /// Connection, recording and completion facts come from the existing controller.
  final AssistantVoiceController voice;

  /// The actual composer geometry anchors the bubble above the keyboard.
  final GlobalKey anchorKey;

  /// Sliding above the cancellation threshold changes only the preview.
  final bool cancelOnRelease;

  /// Assistive technologies can explicitly finish the current recording.
  final VoidCallback onFinish;

  /// Explicit cancellation restores the original draft and selection.
  final VoidCallback onCancel;

  /// Create a lightweight themed transcript surface above the existing page.
  const AssistantRecordingOverlay({
    required this.input,
    required this.voice,
    required this.anchorKey,
    required this.cancelOnRelease,
    required this.onFinish,
    required this.onCancel,
    super.key,
  });

  /// Only scroll position belongs to this presentation widget.
  @override
  State<AssistantRecordingOverlay> createState() =>
      _AssistantRecordingOverlayState();
}

/// Long utterances follow their latest text while keeping the card bounded.
class _AssistantRecordingOverlayState extends State<AssistantRecordingOverlay> {
  /// Scroll the live transcript without moving the underlying conversation.
  final ScrollController _scroll = ScrollController();

  /// Coalesce repeated partial results into one post-layout scroll update.
  bool _scrollQueued = false;

  /// Initial drafts may already be longer than the available preview height.
  @override
  void initState() {
    super.initState();
    _followText();
  }

  /// The owner rebuilds this widget from actual text and voice notifications.
  @override
  void didUpdateWidget(covariant AssistantRecordingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _followText();
  }

  /// Layout must finish before the final line's scroll extent is known.
  void _followText() {
    if (_scrollQueued) return;
    _scrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollQueued = false;
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// Release only the preview's own scroll resource.
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Derive concise instructions from the actual gesture and server phase.
  String get _status => widget.cancelOnRelease
      ? '松开取消'
      : switch (widget.voice.phase) {
          AssistantVoicePhase.preparing => '正在连接语音服务…',
          AssistantVoicePhase.recording => '松开发送，上滑取消',
          AssistantVoicePhase.finishing => '正在完成转写…',
          AssistantVoicePhase.idle => '',
        };

  /// Keep the preview inside safe screen bounds and above the actual composer.
  @override
  Widget build(BuildContext context) {
    // Root media metrics include the keyboard even when the body has resized.
    final MediaQueryData media = MediaQuery.of(context);
    // Colors and typography inherit the user's selected application theme.
    final OmniColors colors = OmniColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The anchor has already been laid out in the underlying overlay entry.
          final RenderBox? anchor =
              widget.anchorKey.currentContext?.findRenderObject() as RenderBox?;
          // Coordinate conversion must use the same root overlay as this entry.
          final RenderBox root =
              Overlay.of(context, rootOverlay: true).context.findRenderObject()!
                  as RenderBox;
          // A missing anchor during disposal never leaves an interactive orphan.
          if (anchor == null || !anchor.hasSize) return const SizedBox.shrink();
          // Keyboard motion changes geometry without changing gesture ownership.
          final Rect composer =
              anchor.localToGlobal(Offset.zero, ancestor: root) & anchor.size;
          // Safe areas take precedence over the normal sixteen-pixel separation.
          final double safeTop = media.padding.top + 12;
          // Short windows retain at least one readable transcript line.
          final double bottom = math.max(safeTop + 48, composer.top - 16);
          // Cap normal previews while allowing accessibility text to scroll.
          final double height = math.min(240, bottom - safeTop);
          // The bubble aligns with the composer's right edge on wide Android views.
          final double width = math.min(
            520,
            math.min(composer.width, constraints.maxWidth - 40),
          );
          // A fixed outer gutter keeps the bubble away from both screen edges.
          final double left = (composer.right - width).clamp(
            20,
            math.max(20, constraints.maxWidth - width - 20),
          );
          // Extremely short keyboard windows prioritize readable transcription.
          final bool compact = height < 120;
          // Show existing draft context as well as the latest recognized segment.
          final String text = widget.input.text;
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const ModalBarrier(
                key: ValueKey<String>('assistant-recording-barrier'),
                dismissible: false,
                barrierSemanticsDismissible: false,
                color: Colors.black54,
              ),
              Positioned(
                left: left,
                width: width,
                bottom: constraints.maxHeight - bottom,
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  label: '实时语音转录',
                  customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
                    if (widget.voice.phase == AssistantVoicePhase.recording)
                      const CustomSemanticsAction(label: '结束录音并发送'):
                          widget.onFinish,
                    const CustomSemanticsAction(label: '取消录音'): widget.onCancel,
                  },
                  child: Material(
                    key: const ValueKey<String>('assistant-recording-bubble'),
                    color: colors.brandSoft,
                    borderRadius: BorderRadius.circular(OmniRadius.dialog),
                    clipBehavior: Clip.antiAlias,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: height),
                      child: Padding(
                        padding: EdgeInsets.all(compact ? 8 : 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Flexible(
                              child: SingleChildScrollView(
                                key: const ValueKey<String>(
                                  'assistant-recording-transcript-scroll',
                                ),
                                controller: _scroll,
                                child: Text(
                                  text.isEmpty
                                      ? widget.voice.phase ==
                                                AssistantVoicePhase.recording
                                            ? '正在聆听…'
                                            : _status
                                      : text,
                                  key: const ValueKey<String>(
                                    'assistant-recording-transcript',
                                  ),
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        fontSize: 16,
                                        color: colors.ink,
                                      ),
                                ),
                              ),
                            ),
                            if (!compact &&
                                (text.isNotEmpty ||
                                    widget.voice.phase ==
                                        AssistantVoicePhase
                                            .recording)) ...<Widget>[
                              const SizedBox(height: 12),
                              Text(
                                _status,
                                key: const ValueKey<String>(
                                  'assistant-recording-status',
                                ),
                                textAlign: TextAlign.right,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: widget.cancelOnRelease
                                          ? colors.danger
                                          : colors.muted,
                                    ),
                              ),
                            ],
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
      ),
    );
  }
}
