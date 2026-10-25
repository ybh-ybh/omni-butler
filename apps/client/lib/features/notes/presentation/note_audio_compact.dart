part of 'note_audio_card.dart';

/// 紧凑展示复用原音完整性、互斥播放与识别授权，不复制业务协议。
extension _CompactNoteAudioCard on _NoteAudioCardState {
  /// 保存按钮只复制当前片段原件，不触发识别或插入正文。
  Future<void> _downloadAudio() async {
    if (_exporting) return;
    _updateCompact(() {
      _exporting = true;
      _exportError = null;
    });
    try {
      // 用户明确选择保存位置后才写副本，取消静默保留原音。
      final Uri? saved = await widget.exporter.export(
        widget.segment,
        widget.local,
      );
      if (saved != null && mounted) {
        showOmniMessage(
          context,
          message: '音频文件已保存',
          tone: OmniMessageTone.success,
        );
      }
    } catch (error) {
      if (mounted) _updateCompact(() => _exportError = '下载失败：$error');
    } finally {
      if (mounted) _updateCompact(() => _exporting = false);
    }
  }

  /// 播放按钮、细进度线、时长和展开入口始终位于同一浅灰表面。
  Widget _compactAudioCard({
    required bool playing,
    required bool paused,
    required double progress,
    required double total,
    required bool recognizing,
  }) {
    // 表面跟随主题，浅色的小字保持参考图的灰度。
    final OmniColors colors = OmniColors.of(context);
    // 灰色原文与时长不使用主文字色。
    final Color muted = Theme.of(context).brightness == Brightness.light
        ? NoteComposerStyle.muted
        : colors.muted;
    // 当前原音未下载时通过播放提示说明，常态不增加工具或状态行。
    final String playLabel = _fileAvailable == null
        ? '正在检查原音'
        : _fileAvailable == false
        ? _fileIssue ?? '本机原音尚未下载'
        : playing
        ? '暂停回听'
        : paused
        ? '继续回听'
        : '播放录音';
    // 更多始终可点击，展开状态通过语义传递给键盘和读屏。
    final Widget more = OmniDisclosureToggle(
      expanded: _detailsExpanded,
      child: OmniNoteAudioLink(
        key: ValueKey('note-audio-expand-${widget.segment.id}'),
        label: _detailsExpanded ? '收起' : '更多',
        trailingIcon: _detailsExpanded
            ? Icons.keyboard_arrow_up
            : Icons.keyboard_arrow_down,
        color: muted,
        onPressed: () =>
            _updateCompact(() => _detailsExpanded = !_detailsExpanded),
      ),
    );
    // 原文、候选或任务状态任一存在时才表示有过识别，授权本身不算开始。
    final bool hasRecognition =
        widget.segment.transcript?.trim().isNotEmpty == true ||
        widget.local?.candidateTranscript?.trim().isNotEmpty == true ||
        widget.local?.recognitionId != null ||
        (widget.local != null && widget.local!.recognitionState != 'idle');
    // 首次原始转写与重新识别候选分开保存，展开不会改写正文。
    final Widget details = Padding(
      padding: const EdgeInsets.fromLTRB(
        OmniSpacing.xs,
        OmniSpacing.sm,
        OmniSpacing.xs,
        OmniSpacing.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            widget.segment.transcript ?? '暂无识别原文',
            key: ValueKey('note-audio-transcript-${widget.segment.id}'),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontSize: 12, color: muted, height: 1.6),
          ),
          if (recognizing)
            Text(
              _recognitionLabel(widget.local?.recognitionState),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: muted),
            ),
          if (widget.local?.lastError != null)
            Text(
              noteAudioTransferErrorMessage(widget.local!.lastError!),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.danger),
            ),
          if (_fileAvailable == false)
            Text(
              _fileIssue ?? '本机原音尚未下载，请连接同步服务后重试',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: muted),
            ),
          _polishControls(showResultAction: false),
          const SizedBox(height: OmniSpacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              // 文字操作共用同一组，在可用宽度内自然换行。
              final Widget actions = Wrap(
                spacing: OmniSpacing.xxs,
                runSpacing: OmniSpacing.xxs,
                children: [
                  OmniNoteAudioLink(
                    key: ValueKey('note-audio-recognize-${widget.segment.id}'),
                    label: hasRecognition ? '重新识别' : '开始识别',
                    onPressed: recognizing || !widget.recognitionEnabled
                        ? null
                        : widget.onRecognize,
                  ),
                  OmniNoteAudioLink(
                    key: ValueKey('note-audio-download-${widget.segment.id}'),
                    label: _exporting ? '下载中…' : '下载',
                    onPressed: _fileAvailable == true && !_exporting
                        ? () => unawaited(_downloadAudio())
                        : null,
                  ),
                  if (widget.local?.polishState != 'disabled' &&
                      widget.local?.polishedText?.trim().isNotEmpty == true)
                    OmniNoteAudioLink(
                      key: ValueKey(
                        'note-audio-polish-result-${widget.segment.id}',
                      ),
                      label: '查看AI转录',
                      onPressed: () => unawaited(
                        _showPolishedText(widget.local!.polishedText!),
                      ),
                    ),
                  if (widget.editing)
                    OmniNoteAudioLink(
                      key: ValueKey('note-audio-insert-${widget.segment.id}'),
                      label: '插入正文',
                      onPressed:
                          widget.editEnabled &&
                              (widget.local?.candidateTranscript ??
                                      widget.segment.transcript ??
                                      '')
                                  .trim()
                                  .isNotEmpty
                          ? () => widget.onInsert(
                              widget.local?.candidateTranscript ??
                                  widget.segment.transcript!,
                            )
                          : null,
                    ),
                ],
              );
              if (!widget.editing) return actions;
              // 删除单独靠右，大字号与窄窗时放到下一行，避免挤压查看结果。
              final Widget deletion = OmniNoteAudioLink(
                key: ValueKey('note-audio-delete-${widget.segment.id}'),
                label: '删除录音',
                leadingIcon: Icons.delete_outline,
                color: colors.danger,
                onPressed: widget.editEnabled ? widget.onDelete : null,
              );
              if (constraints.maxWidth < 360 ||
                  MediaQuery.textScalerOf(context).scale(12) > 18) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    actions,
                    Align(alignment: Alignment.centerRight, child: deletion),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: actions),
                  deletion,
                ],
              );
            },
          ),
        ],
      ),
    );
    return DecoratedBox(
      key: ValueKey('note-audio-bar-${widget.segment.id}'),
      decoration: BoxDecoration(
        color: colors.paperSubtle,
        borderRadius: BorderRadius.circular(OmniRadius.control),
      ),
      child: Padding(
        padding: const EdgeInsets.all(OmniSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // 窄窗或大字号时只将更多入口换行，进度条继续占用剩余宽度。
                final bool stacked =
                    constraints.maxWidth < 300 ||
                    MediaQuery.textScalerOf(context).scale(12) > 18;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      children: [
                        OmniNoteComposerButton(
                          key: ValueKey('note-audio-play-${widget.segment.id}'),
                          tooltip: playLabel,
                          size: const Size.square(OmniSpacing.xl),
                          foreground: _fileAvailable == true
                              ? colors.ink
                              : muted,
                          icon: Icon(
                            playing ? Icons.pause : Icons.play_arrow,
                            size: OmniSize.icon,
                          ),
                          overlay: colors.mist,
                          onPressed:
                              _fileAvailable == true &&
                                  !widget.recordingActive &&
                                  !_busy
                              ? () => unawaited(_togglePlayback())
                              : null,
                        ),
                        const SizedBox(width: OmniSpacing.xxs),
                        Expanded(
                          child: OmniNoteAudioSeekBar(
                            key: ValueKey(
                              'note-audio-progress-${widget.segment.id}',
                            ),
                            value: progress,
                            total: total,
                            label: '第 ${widget.segment.sortOrder + 1} 段录音播放进度',
                            onChanged:
                                _isCurrent && !widget.recordingActive && !_busy
                                ? (value) => _updateCompact(
                                    () => _dragPosition = value,
                                  )
                                : null,
                            onChangeEnd:
                                _isCurrent && !widget.recordingActive && !_busy
                                ? (value) => unawaited(_seek(value))
                                : null,
                          ),
                        ),
                        const SizedBox(width: OmniSpacing.xs),
                        Text(
                          _compactDuration(_duration),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontSize: 12, color: muted),
                        ),
                        if (!stacked) ...[
                          const SizedBox(width: OmniSpacing.xxs),
                          more,
                        ],
                      ],
                    ),
                    if (stacked) more,
                  ],
                );
              },
            ),
            ClipRect(
              child: TweenAnimationBuilder<double>(
                key: ValueKey('note-audio-expansion-${widget.segment.id}'),
                tween: Tween<double>(begin: 0, end: _detailsExpanded ? 1 : 0),
                duration: OmniMotion.duration(context, OmniMotion.panel),
                curve: OmniMotion.standardCurve,
                builder: (_, factor, child) => Align(
                  alignment: Alignment.topCenter,
                  heightFactor: factor,
                  child: child,
                ),
                child: IgnorePointer(
                  ignoring: !_detailsExpanded,
                  child: ExcludeFocus(
                    excluding: !_detailsExpanded,
                    child: ExcludeSemantics(
                      excluding: !_detailsExpanded,
                      child: details,
                    ),
                  ),
                ),
              ),
            ),
            if (_playbackError != null || _exportError != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _exportError ?? _playbackError!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.danger),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 时长与截图一致，两位分钟和秒，不显示常驻播放状态文案。
  String _compactDuration(Duration duration) =>
      '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
}
