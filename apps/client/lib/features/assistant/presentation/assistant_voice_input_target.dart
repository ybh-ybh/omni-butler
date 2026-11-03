import 'package:flutter/material.dart';

/// Capture long presses only where native text selection is not being used.
class AssistantVoiceInputTarget extends StatefulWidget {
  /// Eligibility is evaluated before the original pointer goes down.
  final bool enabled;

  /// Explicit session cancellation also releases stale native pointer metadata.
  final bool active;

  /// The original text field or explicit hold-to-talk surface.
  final Widget child;

  /// A short tap retains the original inline keyboard workflow.
  final VoidCallback onTap;

  /// The accepted long press shares the existing microphone lifecycle.
  final void Function(int pointer, Offset origin) onStart;

  /// Only the owning finger can change the cancellation preview.
  final PointerMoveEventListener onMove;

  /// The owning finger releases the existing speech session.
  final PointerUpEventListener onEnd;

  /// Interrupted gestures never finish or send a recording.
  final VoidCallback onCancel;

  /// Keep the capture layer independent from the changing field contents.
  const AssistantVoiceInputTarget({
    required this.enabled,
    required this.active,
    required this.child,
    required this.onTap,
    required this.onStart,
    required this.onMove,
    required this.onEnd,
    required this.onCancel,
    super.key,
  });

  /// Retain the recognized gesture until the original finger is released.
  @override
  State<AssistantVoiceInputTarget> createState() =>
      _AssistantVoiceInputTargetState();
}

/// A transparent capture layer avoids competing with EditableText recognizers.
class _AssistantVoiceInputTargetState extends State<AssistantVoiceInputTarget> {
  /// The first pointer owns the complete gesture, including its initial position.
  PointerDownEvent? _down;

  /// Transcription and permission updates must not remove an accepted gesture.
  bool _accepted = false;

  /// Native dialogs can omit pointer-up, so cancelled recognizers need a new owner.
  int _recognizerGeneration = 0;

  /// Permission dialogs and navigation can end a session before pointer-up arrives.
  @override
  void didUpdateWidget(covariant AssistantVoiceInputTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_down != null &&
        ((oldWidget.active && !widget.active) ||
            (!widget.enabled && !widget.active))) {
      _down = null;
      _accepted = false;
      _recognizerGeneration++;
    }
  }

  /// Snapshot only metadata; microphone acquisition waits for long-press acceptance.
  void _pointerDown(PointerDownEvent event) {
    if (!widget.enabled || _down != null) return;
    setState(() => _down = event);
  }

  /// Let Flutter enforce its standard long-press delay and movement tolerance.
  void _start(LongPressStartDetails details) {
    // Keep the original down position even if the keyboard later changes geometry.
    final PointerDownEvent? down = _down;
    if (down == null || !widget.enabled) return;
    _accepted = true;
    widget.onStart(down.pointer, down.position);
  }

  /// Release the original pointer exactly once, including during preparation.
  void _pointerUp(PointerUpEvent event) {
    if (event.pointer != _down?.pointer) return;
    if (_accepted) widget.onEnd(event);
    if (mounted) {
      setState(() {
        _down = null;
        _accepted = false;
      });
    }
  }

  /// Losing the native pointer cancels only an already accepted recording.
  void _pointerCancel(PointerCancelEvent event) {
    if (event.pointer != _down?.pointer) return;
    if (_accepted) widget.onCancel();
    if (mounted) {
      setState(() {
        _down = null;
        _accepted = false;
      });
    }
  }

  /// The text field stays mounted beneath a stable, eligible capture surface.
  @override
  Widget build(BuildContext context) => Stack(
    children: <Widget>[
      widget.child,
      if (widget.enabled || _down != null)
        Positioned.fill(
          child: Listener(
            key: const ValueKey<String>('assistant-input-voice-target'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: _pointerDown,
            onPointerMove: (event) {
              if (_accepted && event.pointer == _down?.pointer) {
                widget.onMove(event);
              }
            },
            onPointerUp: _pointerUp,
            onPointerCancel: _pointerCancel,
            child: GestureDetector(
              key: ValueKey<int>(_recognizerGeneration),
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: widget.onTap,
              onLongPressStart: _start,
            ),
          ),
        ),
    ],
  );
}
