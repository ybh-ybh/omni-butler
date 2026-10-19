import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/note_composer_style.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/audio/note_audio_export_service.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/features/notes/data/note_audio_transfer_service.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/shared/ui/omni_note_audio_controls.dart';
import 'package:omni_butler/shared/ui/omni_note_composer_button.dart';

part 'note_audio_compact.dart';

/// 每段原音独立展示回听、识别状态和待插入文本，不直接编辑笔记正文。
class NoteAudioCard extends StatefulWidget {
  /// 创建无供应商、数据库容器依赖的音频卡片。
  const NoteAudioCard({
    required this.segment,
    required this.local,
    required this.player,
    required this.onRecognize,
    required this.onCancel,
    required this.onInsert,
    required this.recordingActive,
    this.compact = false,
    this.editing = false,
    this.editEnabled = true,
    this.recognitionEnabled = true,
    this.onDelete,
    this.onRetryPolish,
    this.onAdoptPolish,
    this.exporter = const NoteAudioExportService(),
    super.key,
  });

  /// 原音和原始转写元数据。
  final NoteAudioSegmentRecord segment;

  /// 当前设备真实缓存和任务状态。
  final NoteAudioLocalFileRecord? local;

  /// 应用共享回听服务。
  final NoteAudioPlayerService player;

  /// 父页面负责授权提示及启动或重试原任务。
  final VoidCallback onRecognize;

  /// 父页面负责撤回授权和取消未提交任务。
  final VoidCallback onCancel;

  /// 用户明确插入候选文本，父页面决定光标与正文版本。
  final ValueChanged<String> onInsert;

  /// 正在录音时禁用回听，文字和转写管理继续可用。
  final bool recordingActive;

  /// 两端阅读与编辑可共用紧凑音频条，旧页面保留完整卡片选项。
  final bool compact;

  /// 历史编辑在原有音频工具后增加正文插入和草稿删除。
  final bool editing;

  /// 冻结或正在提交的草稿禁止更改正文与音频。
  final bool editEnabled;

  /// 尚未发布的本机草稿原音不能启动正式识别任务。
  final bool recognitionEnabled;

  /// 删除由父编辑器暂存，只有显式保存才修改正式记录。
  final VoidCallback? onDelete;

  /// 父页面负责重试已保存的 ASR 文本整理。
  final VoidCallback? onRetryPolish;

  /// 父页面负责整理候选的版本检查和明确采用。
  final VoidCallback? onAdoptPolish;

  /// 下载只导出已核验原音副本，测试可替换系统保存边界。
  final NoteAudioExportService exporter;

  /// 创建当前卡片局部状态。
  @override
  State<NoteAudioCard> createState() => _NoteAudioCardState();
}

/// 只跟踪本段回听与文件检查，不拥有播放器生命周期。
class _NoteAudioCardState extends State<NoteAudioCard> {
  /// 共享播放器的状态订阅。
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// 本段已播放位置。
  Duration _position = Duration.zero;

  /// 原生播放器核验的文件时长。
  Duration? _playbackDuration;

  /// 真实文件可用性，空值表示检查中。
  bool? _fileAvailable;

  /// 区分文件缺失与被修改，不能把损坏原音当作可回听。
  String? _fileIssue;

  /// 播放命令等待期间阻止重复启动。
  bool _busy = false;

  /// 当前回听错误，不与网络识别错误混用。
  String? _playbackError;

  /// 拖动滑块时保留手指位置，不被播放回调覆盖。
  double? _dragPosition;

  /// 异步文件检查代次，旧路径结果不能覆盖新缓存。
  int _fileCheck = 0;

  /// 紧凑音频条的原文展开状态与播放状态互不影响。
  bool _detailsExpanded = false;

  /// 保存文件期间阻止重复打开系统保存窗口。
  bool _exporting = false;

  /// 下载错误不混入播放或厂商识别状态。
  String? _exportError;

  /// 同库紧凑视图通过此入口更新状态，避免访问受保护的框架方法。
  void _updateCompact(VoidCallback change) {
    if (mounted) setState(change);
  }

  /// 当前播放器是否绑定本段本机原音。
  bool get _isCurrent =>
      widget.local?.localPath != null &&
      widget.player.currentPath == widget.local!.localPath;

  /// 实际播放器时长优先，回听前显示不可变录音时长。
  Duration get _duration =>
      _playbackDuration ?? Duration(milliseconds: widget.segment.durationMs);

  /// 建立音源身份、状态、播放位置和时长监听。
  @override
  void initState() {
    super.initState();
    _subscribe();
    unawaited(_checkFile());
  }

  /// 音源或缓存变化时清理旧状态并重新核查真实文件。
  @override
  void didUpdateWidget(NoteAudioCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _unsubscribe();
      _subscribe();
    }
    if (oldWidget.local != widget.local ||
        oldWidget.segment.id != widget.segment.id) {
      _playbackError = null;
      unawaited(_checkFile());
    }
  }

  /// 共享播放器只把位置与时长显示在活动卡片上。
  void _subscribe() {
    _subscriptions.add(
      widget.player.currentPaths.listen((_) {
        if (!mounted) return;
        setState(() {
          _position = Duration.zero;
          _playbackDuration = null;
          _dragPosition = null;
        });
      }),
    );
    _subscriptions.add(
      widget.player.states.listen(
        (_) {
          if (mounted) setState(() {});
        },
        onError: (Object error) {
          if (mounted && _isCurrent) {
            setState(() => _playbackError = '回听失败：$error');
          }
        },
      ),
    );
    _subscriptions.add(
      widget.player.positions.listen((position) {
        if (mounted && _isCurrent) setState(() => _position = position);
      }),
    );
    _subscriptions.add(
      widget.player.durations.listen((duration) {
        if (mounted && _isCurrent) setState(() => _playbackDuration = duration);
      }),
    );
  }

  /// 页面离开只取消卡片监听，不停止共享回听。
  void _unsubscribe() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  /// 文件存在且含音频数据才允许回听；元信息存在不等于原音已下载。
  Future<void> _checkFile() async {
    // 当前检查代次。
    final check = ++_fileCheck;
    // 当前缓存路径。
    final path = widget.local?.localPath;
    if (mounted) setState(() => _fileAvailable = null);
    // 默认缺失，下载成功或恢复缓存后可重新检查。
    var available = false;
    // 明确的原音缺失或校验失败说明。
    String? issue;
    if (path != null) {
      try {
        // 录音文件必须含标准头之外的实际原音。
        final file = File(path);
        if (await file.exists()) {
          // 必须核验原件实际长度及 SHA256，禁止播放同路径的替换文件。
          final length = await file.length();
          if (length > 44 && length == widget.segment.byteSize) {
            // 增量校验长录音，避免把整个文件装入内存。
            final digest = await sha256.bind(file.openRead()).first;
            available = digest.toString() == widget.segment.sha256;
          }
          if (!available) issue = '原音校验失败，请从同步服务重新下载或恢复备份';
        }
      } on FileSystemException {
        available = false;
      }
    }
    if (mounted && check == _fileCheck) {
      setState(() {
        _fileAvailable = available;
        _fileIssue = issue;
      });
    }
  }

  /// 执行一次回听操作并向用户明确报告设备或文件失败。
  Future<void> _control(Future<void> Function() action) async {
    if (_busy || widget.recordingActive) return;
    setState(() {
      _busy = true;
      _playbackError = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _playbackError = '回听失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 开始/暂停/继续时使用当前音源身份，不能误操作别的卡片。
  Future<void> _togglePlayback() => _control(() async {
    if (_isCurrent && widget.player.state == PlayerState.playing) {
      await widget.player.pause();
    } else {
      await _checkFile();
      if (_fileAvailable != true) return;
      if (_isCurrent && widget.player.state == PlayerState.paused) {
        await widget.player.resume();
      } else {
        await widget.player.play(widget.local!.localPath!);
      }
    }
  });

  /// 手指或键盘明确调整播放位置。
  Future<void> _seek(double milliseconds) => _control(() async {
    if (!_isCurrent) return;
    await widget.player.seek(
      Duration(milliseconds: milliseconds.round()),
      expectedPath: widget.local?.localPath,
    );
    if (mounted) {
      setState(() {
        _position = Duration(milliseconds: milliseconds.round());
        _dragPosition = null;
      });
    }
  });

  /// 显示不可改写的原始转写，查看或复制不覆盖正文。
  Future<void> _showTranscript({bool candidate = false}) async {
    // 原始识别文本，包括未插入的候选。
    final text =
        (candidate
            ? widget.local?.candidateTranscript
            : widget.segment.transcript) ??
        '';
    // 本次重试候选与首次原始转写分别查看，不能混用含义。
    final label = candidate ? '本次转写' : '原始转写';
    await showOmniDialog<void>(
      context: context,
      builder: (dialogContext) => OmniDialogScaffold(
        title: '第 ${widget.segment.sortOrder + 1} 段 · $label',
        width: 560,
        actions: [
          OmniButton(
            label: candidate ? '复制本次文本' : '复制原文',
            variant: OmniButtonVariant.secondary,
            visualHeight: OmniSize.control,
            icon: Icons.copy_outlined,
            onPressed: () => unawaited(_copy(text, label: label)),
          ),
          OmniButton(
            label: '关闭',
            variant: OmniButtonVariant.text,
            visualHeight: OmniSize.control,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
        child: SizedBox(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(dialogContext).height * .55,
            ),
            child: SingleChildScrollView(child: SelectableText(text)),
          ),
        ),
      ),
    );
  }

  /// 复制原始转写，不会自动插入笔记。
  Future<void> _copy(String text, {String label = '原始转写'}) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        showOmniMessage(
          context,
          message: '$label已复制',
          tone: OmniMessageTone.success,
        );
      }
    } catch (_) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '复制失败，请选择文本后复制',
          tone: OmniMessageTone.error,
        );
      }
    }
  }

  /// 构建窄屏可换行、键盘可操作的原音卡片。
  @override
  Widget build(BuildContext context) {
    // 公共语义色，不能仅用颜色区别失败状态。
    final colors = OmniColors.of(context);
    // 同一播放器仅活动片段显示暂停/继续。
    final playing = _isCurrent && widget.player.state == PlayerState.playing;
    // 暂停后继续回听。
    final paused = _isCurrent && widget.player.state == PlayerState.paused;
    // 播放进度不能越过原音时长。
    final total = max(1, _duration.inMilliseconds).toDouble();
    // 用户正在拖动时保留预览位置。
    final progress =
        (_dragPosition ??
                (_isCurrent ? _position.inMilliseconds.toDouble() : 0.0))
            .clamp(0.0, total);
    // 原始转写只以用户明确操作插入正文。
    final transcript =
        widget.local?.candidateTranscript ?? widget.segment.transcript;
    // waiting: 仅记录首次转写预留位置，尚未实际插入正文。
    final inserted =
        widget.local?.insertedRevision != null &&
        !widget.local!.insertedRevision!.startsWith('waiting:');
    // 非空候选文本待插入状态。
    final candidate =
        transcript != null &&
        transcript.trim().isNotEmpty &&
        (widget.local?.candidateTranscript != null || !inserted);
    // 服务任务是否仍在排队或处理中。
    final pending = const {
      'queued',
      'processing',
      'running',
      'submitting',
    }.contains(widget.local?.recognitionState);
    // 撤回提交之后已送达厂商的任务可能无法取消。
    final cancelling = widget.local?.recognitionState == 'cancelPending';
    // 不明确的提交回执必须先查原任务，不能直接重新付费。
    final unknown = widget.local?.recognitionState == 'submissionUnknown';
    if (widget.compact) {
      return _compactAudioCard(
        playing: playing,
        paused: paused,
        progress: progress,
        total: total,
        recognizing: pending || cancelling || unknown,
      );
    }
    return FocusTraversalGroup(
      child: OmniPanel(
        padding: const EdgeInsets.all(OmniSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: OmniSpacing.md,
              runSpacing: OmniSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '第 ${widget.segment.sortOrder + 1} 段录音',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  _format(Duration(milliseconds: widget.segment.durationMs)),
                  style: TextStyle(color: colors.muted),
                ),
              ],
            ),
            const SizedBox(height: OmniSpacing.sm),
            Semantics(
              liveRegion: true,
              child: Text(
                _fileAvailable == null
                    ? '正在检查原音'
                    : _fileAvailable!
                    ? '原音已保存在本机'
                    : _fileIssue ?? '本机原音缺失，连接同步服务后下载或恢复备份',
                style: TextStyle(
                  color: _fileAvailable == false
                      ? Theme.of(context).colorScheme.error
                      : colors.muted,
                ),
              ),
            ),
            const SizedBox(height: OmniSpacing.xs),
            Wrap(
              spacing: OmniSpacing.sm,
              runSpacing: OmniSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OmniButton(
                  label: playing
                      ? '暂停回听'
                      : paused
                      ? '继续回听'
                      : '回听原音',
                  icon: playing ? Icons.pause : Icons.play_arrow,
                  variant: OmniButtonVariant.secondary,
                  visualHeight: OmniSize.control,
                  loading: _busy,
                  onPressed: _fileAvailable == true && !widget.recordingActive
                      ? () => unawaited(_togglePlayback())
                      : null,
                ),
                if (_isCurrent)
                  OmniButton(
                    label: '停止回听',
                    icon: Icons.stop,
                    visualHeight: OmniSize.control,
                    variant: OmniButtonVariant.text,
                    onPressed: _busy
                        ? null
                        : () => unawaited(_control(widget.player.stop)),
                  ),
                if (_fileAvailable == false)
                  OmniButton(
                    label: '检查原音',
                    icon: Icons.refresh,
                    visualHeight: OmniSize.control,
                    variant: OmniButtonVariant.text,
                    onPressed: () => unawaited(_checkFile()),
                  ),
                Text(
                  '${_format(Duration(milliseconds: progress.round()))} / ${_format(_duration)}',
                  style: TextStyle(color: colors.muted),
                ),
              ],
            ),
            if (widget.recordingActive) const Text('正在录音，请结束后回听原音'),
            Semantics(
              label: '第 ${widget.segment.sortOrder + 1} 段回听进度',
              child: Slider(
                value: progress,
                max: total,
                semanticFormatterCallback: (value) =>
                    _format(Duration(milliseconds: value.round())),
                onChanged: _isCurrent && !widget.recordingActive && !_busy
                    ? (value) => setState(() => _dragPosition = value)
                    : null,
                onChangeEnd: _isCurrent && !widget.recordingActive && !_busy
                    ? (value) => unawaited(_seek(value))
                    : null,
              ),
            ),
            if (_playbackError != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _playbackError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Text(
              _uploadLabel(widget.local?.uploadState),
              style: TextStyle(color: colors.muted),
            ),
            const SizedBox(height: OmniSpacing.sm),
            Semantics(
              liveRegion: true,
              child: Text(_recognitionLabel(widget.local?.recognitionState)),
            ),
            _polishControls(),
            if (widget.local?.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: OmniSpacing.xs),
                child: Text(
                  '${unknown
                      ? '提交回执待核实'
                      : widget.local?.recognitionState == 'failed'
                      ? '转写失败'
                      : widget.local?.uploadState == 'failed'
                      ? '原音同步失败'
                      : '处理异常'}：${noteAudioTransferErrorMessage(widget.local!.lastError!)}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (candidate)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: OmniSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('转写已完成，待插入正文', style: TextStyle(color: colors.brand)),
                    const SizedBox(height: OmniSpacing.xs),
                    Text(
                      transcript,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: OmniSpacing.sm),
            Wrap(
              spacing: OmniSpacing.sm,
              runSpacing: OmniSpacing.sm,
              children: [
                if (!pending && !cancelling && !unknown)
                  OmniButton(
                    label: widget.local?.recognitionState == 'failed'
                        ? '重试转写'
                        : transcript != null
                        ? '重新转写'
                        : '开启本段转写',
                    icon: Icons.transcribe_outlined,
                    visualHeight: OmniSize.control,
                    variant: OmniButtonVariant.secondary,
                    onPressed: widget.onRecognize,
                  ),
                if (widget.local?.consent == true ||
                    pending ||
                    cancelling ||
                    unknown)
                  OmniButton(
                    label: cancelling ? '正在撤回授权' : '撤回本段转写授权',
                    icon: Icons.cancel_outlined,
                    visualHeight: OmniSize.control,
                    variant: OmniButtonVariant.text,
                    onPressed: cancelling ? null : widget.onCancel,
                  ),
                if (widget.segment.transcript != null)
                  OmniButton(
                    label: '查看原始转写',
                    icon: Icons.article_outlined,
                    visualHeight: OmniSize.control,
                    variant: OmniButtonVariant.text,
                    onPressed: () => unawaited(_showTranscript()),
                  ),
                if (widget.local?.candidateTranscript != null)
                  OmniButton(
                    label: '查看本次转写',
                    icon: Icons.article_outlined,
                    visualHeight: OmniSize.control,
                    variant: OmniButtonVariant.text,
                    onPressed: () =>
                        unawaited(_showTranscript(candidate: true)),
                  ),
                if (candidate)
                  OmniButton(
                    label: '插入正文',
                    icon: Icons.text_snippet_outlined,
                    visualHeight: OmniSize.control,
                    onPressed: () => widget.onInsert(transcript),
                  ),
              ],
            ),
            if (inserted && !candidate && widget.segment.transcript != null)
              const Padding(
                padding: EdgeInsets.only(top: OmniSpacing.xs),
                child: Text('转写已插入正文，原始转写仍可查看和复制'),
              ),
            if (cancelling || unknown)
              const Padding(
                padding: EdgeInsets.only(top: OmniSpacing.xs),
                child: Text('已送达服务方的任务可能继续处理；原音和已保存文字仍保留'),
              ),
          ],
        ),
      ),
    );
  }

  /// 格式化实际播放或录音时长。
  String _format(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  /// 整理状态独立于 ASR，紧凑音频条可将结果入口放入底部操作行。
  Widget _polishControls({bool showResultAction = true}) {
    // 本机持久状态反映后台任务，不使用模型文字判断是否成功。
    final NoteAudioLocalFileRecord? local = widget.local;
    if (local == null || local.polishState == 'disabled') {
      return const SizedBox.shrink();
    }
    // 输入和输出的指纹区分旧原文采用与本次整理采用，避免隐藏新候选。
    final bool adopted =
        local.polishAdoptedHash != null &&
        local.polishAdoptedHash == notePolishFingerprint(local);
    // 失败和付费回执未知只允许显式重试。
    final bool retryable = const {
      'failed',
      'submissionUnknown',
    }.contains(local.polishState);
    // 给出用户能理解的状态，错误码保留在详细说明。
    final String? label = switch (local.polishState) {
      'waiting' || 'queued' || 'processing' => 'AI 整理中',
      'succeeded' => adopted ? null : 'AI 整理完成，待采用',
      'cancelled' => 'AI 整理已停止，原始转写已保留',
      'submissionUnknown' => 'AI 整理结果待核实，原始转写已保留',
      _ => 'AI 整理失败，原始转写已保留',
    };
    if (label == null && local.polishError == null && !showResultAction) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: OmniSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Semantics(
              liveRegion: true,
              child: Text(
                label,
                key: ValueKey('note-polish-status-${widget.segment.id}'),
              ),
            ),
          if (local.polishError != null)
            Text(
              _polishErrorLabel(local.polishError!),
              style: TextStyle(color: OmniColors.of(context).danger),
            ),
          Wrap(
            spacing: OmniSpacing.sm,
            children: [
              if (retryable && widget.onRetryPolish != null)
                OmniButton(
                  label: '重试整理',
                  variant: OmniButtonVariant.text,
                  onPressed: widget.recognitionEnabled && local.consent
                      ? widget.onRetryPolish
                      : null,
                ),
              if (showResultAction &&
                  local.polishedText?.trim().isNotEmpty == true)
                OmniButton(
                  label: '查看AI转录',
                  variant: OmniButtonVariant.text,
                  onPressed: () =>
                      unawaited(_showPolishedText(local.polishedText!)),
                ),
              if (local.polishState == 'succeeded' &&
                  !adopted &&
                  widget.onAdoptPolish != null)
                OmniButton(
                  label: '采用整理结果',
                  variant: OmniButtonVariant.text,
                  onPressed: widget.editEnabled ? widget.onAdoptPolish : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 全文预览与复制不会触发正文写入。
  Future<void> _showPolishedText(String text) => showOmniDialog<void>(
    context: context,
    builder: (dialogContext) => OmniDialogScaffold(
      title: 'AI 整理结果',
      width: 560,
      actions: [
        OmniButton(
          label: '复制',
          variant: OmniButtonVariant.secondary,
          onPressed: () => unawaited(_copy(text, label: 'AI 整理结果')),
        ),
        OmniButton(
          label: '关闭',
          variant: OmniButtonVariant.text,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(dialogContext).height * .55,
        ),
        child: SingleChildScrollView(child: SelectableText(text)),
      ),
    ),
  );

  /// 固定后端错误码转换为可操作说明，本机中文校验错误直接保留。
  String _polishErrorLabel(String code) => switch (code) {
    'AI_REASONING_UNSUPPORTED' => '该模型始终开启思考，不支持关闭思考（reasoning.effort=none）。',
    'AI_AUTH_FAILED' => '模型 API Key 无效或没有访问权限，请检查 AI 设置。',
    'AI_MODEL_OR_URL_INVALID' => '模型名称或 API 地址无效，请检查 AI 设置。',
    'AI_TIMEOUT' || 'AI_SUBMISSION_UNKNOWN' => '模型请求结果暂无法确认，可能已计费，可手动重试整理。',
    'AI_RATE_LIMITED' => '模型请求受限，请检查服务商额度或稍后重试。',
    'AI_KEY_DECRYPTION_FAILED' ||
    'AI_KEY_STORAGE_FAILED' => '服务器无法读取模型密钥，请恢复密钥备份或重新配置 API Key。',
    'AI_OUTPUT_TRUNCATED' || 'AI_OUTPUT_TOO_LONG' => '整理结果超出长度限制，原始转写已保留。',
    'AI_EMPTY_OUTPUT' || 'AI_INVALID_RESPONSE' => '模型没有返回完整正文，原始转写已保留。',
    'AI_CANCELLED' => '整理已停止，已保存的原文和正文仍可使用。',
    _ => code.startsWith('AI_') ? '模型服务暂不可用，请检查设置后重试。' : code,
  };

  /// 原音同步与厂商识别是两种独立状态。
  String _uploadLabel(String? state) => switch (state) {
    'synced' => '原音已同步',
    'uploading' => '原音正在上传',
    'downloading' => '原音正在下载',
    'failed' => '原音同步失败，本机内容仍保留',
    _ => '原音尚未同步，等待网络或同步服务',
  };

  /// 不虚构百分比，失败和未知提交回执明确区分。
  String _recognitionLabel(String? state) => switch (state) {
    'queued' => '等待转写服务',
    'processing' || 'running' || 'submitting' => '正在转写，原音仍可回听',
    'succeeded' =>
      ((widget.local?.candidateTranscript ?? widget.segment.transcript)
                  ?.trim()
                  .isEmpty ??
              true)
          ? '未识别到有效文字，原音仍保留'
          : '转写成功',
    'failed' => '转写失败，可修复问题后重试，无需重新录音',
    'cancelPending' => '等待联网撤回转写授权',
    'cancelled' || 'canceled' => '本段转写已取消',
    'submissionUnknown' => '提交结果待核实，请查询原任务，避免重复提交',
    _ =>
      widget.segment.transcript != null
          ? '原始转写已保存'
          : widget.local?.consent == true
          ? '已授权本段转写，等待网络或服务'
          : '本段未启用语音转文字',
  };

  /// 页面销毁不停止其他页面或卡片的原音播放。
  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }
}
