part of 'android_notes_view.dart';

/// 录音卡片只管理本次片段的呈现，确认是否发布由入口会话决定。
class _AndroidRecordingCard extends ConsumerStatefulWidget {
  /// 应用级编辑器已经固定草稿身份。
  final NoteEditorController editor;

  /// 确认后主页发布，编辑器入口只保留当前附件。
  final Future<void> Function() onConfirm;

  /// 退出前仅清理本次片段。
  final Future<void> Function() onCancel;

  /// 创建与正文互斥的语音视图。
  const _AndroidRecordingCard({
    required this.editor,
    required this.onConfirm,
    required this.onCancel,
    super.key,
  });

  /// 音量与计时在卡片内部独立刷新。
  @override
  ConsumerState<_AndroidRecordingCard> createState() =>
      _AndroidRecordingCardState();
}

/// 暂停与停止是不同状态，停止后保留原音等待明确确认。
class _AndroidRecordingCardState extends ConsumerState<_AndroidRecordingCard>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// 本卡片所属的稳定录音身份。
  String? _id;

  /// 当前时间只刷新时长区域。
  final ValueNotifier<Duration> _duration = ValueNotifier(Duration.zero);

  /// 波形窗口只保留有限采样，不随长录音无限增长。
  final ValueNotifier<List<double>> _samples = ValueNotifier([]);

  /// 每次新采样在50ms内连续左移一格。
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 50),
  );

  /// 可视音量广播订阅。
  StreamSubscription<NoteRecordingLevel>? _levels;

  /// 已完成且属于本次片段的原音。
  NoteRecordingResult? _result;

  /// 完成流包含限额和系统中断，不能误认为用户已确认发布。
  StreamSubscription<NoteRecordingResult>? _completed;

  /// 是否已经停止并进入取消／确认状态。
  bool _reviewing = false;

  /// 命令期间防止重复启停或提交。
  bool _busy = false;

  /// 原音已可靠落入当前草稿才允许确认。
  bool _hasAudio = false;

  /// 失败后保留同一张卡片提供重试。
  String? _error;

  /// 当前实际录音限额。
  Duration _limit = NoteRecorderService.segmentLimit;

  /// 跟随手指的下移距离。
  double _drag = 0;

  /// 监听完成和音量，实际采集在首帧后开始。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _levels = widget.editor.recorder.levels.listen((level) {
      if (!mounted || level.recordingId != _id || _reviewing) return;
      _duration.value = level.duration;
      _samples.value = [
        ..._samples.value.skip(math.max(0, _samples.value.length - 119)),
        level.level,
      ];
      if (OmniMotion.reduce(context)) {
        _wave.value = 1;
      } else {
        unawaited(_wave.forward(from: 0));
      }
    });
    _completed = widget.editor.recorder.completed.listen((result) {
      if (!mounted || result.id != _id) return;
      _result = result;
      _duration.value = result.duration;
      if (!_busy) unawaited(_stop());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_begin()));
  }

  /// 后台只关闭可视化，不暂停应用级录音。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(
      widget.editor.recorder.setMeteringActive(
        state == AppLifecycleState.resumed && !_reviewing,
      ),
    );
  }

  /// 释放绘制与焦点资源，原件生命周期由控制器决定。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.editor.recorder.setMeteringActive(false));
    unawaited(_levels?.cancel());
    unawaited(_completed?.cancel());
    _wave.dispose();
    _samples.dispose();
    _duration.dispose();
    super.dispose();
  }

  /// 启动或返回同一采集会话，权限失败时不会丢弃正文。
  Future<void> _begin() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!widget.editor.recorder.state.isActive) {
        await widget.editor.startRecording();
      }
      if (!mounted) return;
      // 真实采集身份优先于页面自己的时间或显示状态。
      final NoteRecordingState state = widget.editor.recorder.state;
      if (!state.isActive) {
        throw StateError(widget.editor.error ?? '录音未启动，请检查麦克风权限');
      }
      if (state.draftId != widget.editor.draftId) {
        throw StateError('录音属于其他草稿，请返回原录音');
      }
      _id = state.recordingId;
      _limit = state.limit > Duration.zero
          ? state.limit
          : NoteRecorderService.segmentLimit;
      _duration.value = state.duration;
      await widget.editor.recorder.setMeteringActive(true);
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 停止后等待原件和草稿队列，不提前展示可提交成功。
  Future<void> _stop() async {
    if (_busy || _reviewing) return;
    // 已停止但暂存失败时恢复同一份原件，不重新启动采集。
    final bool retry = _result != null && _error != null;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.editor.recorder.setMeteringActive(false);
      // 返回值和事件流按录音ID去重，不依赖哪一个先到达。
      final NoteRecordingResult? result = await widget.editor.recorder.stop();
      _result ??= result;
      if (retry) await widget.editor.recover();
      await widget.editor.finishRecording(completed: _result);
      // 查持久事实而不是根据设备idle推断录音已保存。
      final List<NoteDraftAudioSegmentRecord> audio =
          widget.editor.draftId == null
          ? []
          : await widget.editor.localDrafts.audio(widget.editor.draftId!);
      if (!mounted) return;
      _hasAudio = audio.any(
        (item) => item.id == _id && !widget.editor.isAudioRemoved(item.id),
      );
      if (_result != null) _duration.value = _result!.duration;
      _wave.stop();
      _reviewing = true;
      if (!_hasAudio) _error = '未录到有效语音，可以退出后重试';
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 暂停仅改变采集状态，保持同一段原件与波形窗口。
  Future<void> _pauseOrResume() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (widget.editor.recorder.state.phase == NoteRecordingPhase.paused) {
        await widget.editor.recorder.resume();
      } else {
        await widget.editor.recorder.pause();
        _wave.stop();
      }
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 所有显式退出均先确认，继续录音时不改变原有采集阶段。
  Future<void> requestExit() async {
    if (_busy) return;
    await widget.editor.recorder.setMeteringActive(false);
    if (!mounted) return;
    // 确认表面从底部出现，与视频中的两列操作一致。
    final bool? exit = await Navigator.of(context, rootNavigator: true)
        .push<bool>(
          ModalBottomSheetRoute<bool>(
            isScrollControlled: true,
            useSafeArea: true,
            backgroundColor: Colors.transparent,
            builder: (context) => Material(
              color: OmniColors.of(context).paper,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(OmniSpacing.xl),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(OmniSpacing.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('提示', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: OmniSpacing.lg),
                      const Text('确定退出吗？录音将被清除', textAlign: TextAlign.center),
                      const SizedBox(height: OmniSpacing.xl),
                      Row(
                        children: [
                          Expanded(
                            child: OmniButton(
                              label: '继续',
                              variant: OmniButtonVariant.secondary,
                              onPressed: () => Navigator.pop(context, false),
                            ),
                          ),
                          const SizedBox(width: OmniSpacing.md),
                          Expanded(
                            child: OmniButton(
                              label: '退出',
                              variant: OmniButtonVariant.danger,
                              onPressed: () => Navigator.pop(context, true),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
    if (!mounted) return;
    if (exit != true) {
      setState(() => _drag = 0);
      await widget.editor.recorder.setMeteringActive(!_reviewing);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_id != null) await widget.editor.discardRecording(_id!);
      await widget.onCancel();
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _drag = 0;
        });
      }
    }
  }

  /// 确认失败保持当前片段，入口会话自行决定是否正式发布。
  Future<void> _confirm() async {
    if (_busy || !_hasAudio) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm();
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 圆形按钮保持触控热区和读屏名称。
  Widget _action(
    String label,
    IconData icon,
    Color background,
    Color foreground,
    VoidCallback? action,
  ) => ClipOval(
    child: OmniIconButton(
      tooltip: label,
      onPressed: action,
      constraints: const BoxConstraints.tightFor(width: 56, height: 56),
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(background),
        shape: const WidgetStatePropertyAll(CircleBorder()),
      ),
      icon: Icon(icon, color: foreground, size: OmniSpacing.xl),
    ),
  );

  /// 状态更新只影响卡片，真实音量单独驱动波形绘制。
  @override
  Widget build(BuildContext context) {
    // 状态以原生采集服务为准，暂停时不继续插入假波形。
    final NoteRecordingState recording =
        ref.watch(noteRecordingProvider).value ?? widget.editor.recorder.state;
    // 当前配色保留与编辑界面一致的品牌语义。
    final OmniColors colors = OmniColors.of(context);
    if (!_reviewing &&
        recording.recordingId == _id &&
        recording.duration > _duration.value) {
      _duration.value = recording.duration;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 短屏压缩波形区域，日期与操作始终可见。
        final double width = math.min(
          420,
          constraints.maxWidth - OmniSpacing.xl,
        );
        // 根覆盖层已经隔离全局底栏，只需避让设备安全区。
        final double bottom =
            MediaQuery.paddingOf(context).bottom + OmniSpacing.xs;
        // 视频卡片高度约为宽度的1.08倍，横屏限定在安全视口内。
        final double height = math.min(
          width * 1.08,
          constraints.maxHeight -
              MediaQuery.paddingOf(context).top -
              bottom -
              OmniSpacing.xs,
        );
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottom),
            child: _AndroidComposerEntrance(
              distance: height + bottom,
              child: Transform.translate(
                offset: Offset(0, _drag),
                child: GestureDetector(
                  onVerticalDragStart: _busy
                      ? null
                      : (_) => setState(() => _drag = 0),
                  onVerticalDragUpdate: _busy
                      ? null
                      : (details) => setState(
                          () => _drag = math.max(0, _drag + details.delta.dy),
                        ),
                  onVerticalDragEnd: _busy
                      ? null
                      : (_) {
                          if (_drag > 64) {
                            unawaited(requestExit());
                          } else {
                            setState(() => _drag = 0);
                          }
                        },
                  child: Material(
                    key: const ValueKey('android-recording-card'),
                    color: colors.paper,
                    borderRadius: BorderRadius.circular(OmniSpacing.xl),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: Padding(
                        padding: const EdgeInsets.all(OmniSpacing.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'REC',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                                const SizedBox(width: OmniSpacing.xxs),
                                Icon(
                                  Icons.circle,
                                  size: 6,
                                  color: colors.danger,
                                ),
                              ],
                            ),
                            Text(
                              widget.editor.draft.dayKey,
                              style: TextStyle(color: colors.muted),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: OmniSpacing.md,
                                ),
                                child: AnimatedBuilder(
                                  animation: Listenable.merge([
                                    _samples,
                                    _wave,
                                  ]),
                                  builder: (context, _) => CustomPaint(
                                    size: Size.infinite,
                                    painter: _AndroidWavePainter(
                                      samples: _samples.value,
                                      progress: _wave.value,
                                      line: colors.muted,
                                      brand: colors.brand,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (_error != null)
                              Text(
                                _error!,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: colors.danger),
                              ),
                            if (_error != null && !_reviewing)
                              Row(
                                children: [
                                  OmniButton(
                                    label: _result == null ? '重试录音' : '重试暂存',
                                    variant: OmniButtonVariant.text,
                                    onPressed: _busy
                                        ? null
                                        : (_result == null ? _begin : _stop),
                                  ),
                                  OmniIconButton(
                                    tooltip: '打开系统权限设置',
                                    icon: const Icon(Icons.settings_outlined),
                                    onPressed:
                                        widget.editor.recorder.openSettings,
                                  ),
                                ],
                              ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ValueListenableBuilder<Duration>(
                                        valueListenable: _duration,
                                        builder: (context, value, _) => FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            _audioDuration(value),
                                            style: Theme.of(context)
                                                .textTheme
                                                .displaySmall
                                                ?.copyWith(
                                                  fontSize: 44,
                                                  fontWeight: FontWeight.w700,
                                                  fontFeatures: const [
                                                    ui.FontFeature.tabularFigures(),
                                                  ],
                                                ),
                                          ),
                                        ),
                                      ),
                                      Text(
                                        _audioDuration(_limit),
                                        style: TextStyle(color: colors.muted),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: OmniSpacing.xs),
                                if (_reviewing) ...[
                                  _action(
                                    '取消录音',
                                    Icons.close,
                                    colors.danger.withValues(alpha: .12),
                                    colors.danger,
                                    _busy
                                        ? null
                                        : () => unawaited(requestExit()),
                                  ),
                                  const SizedBox(width: OmniSpacing.xs),
                                  _action(
                                    '确认录音',
                                    Icons.check,
                                    _hasAudio ? colors.brand : colors.mist,
                                    _hasAudio
                                        ? Theme.of(context)
                                              .colorScheme
                                              .onPrimary
                                        : colors.muted,
                                    _busy || !_hasAudio ? null : _confirm,
                                  ),
                                ] else ...[
                                  _action(
                                    recording.phase == NoteRecordingPhase.paused
                                        ? '继续录音'
                                        : '暂停录音',
                                    recording.phase == NoteRecordingPhase.paused
                                        ? Icons.play_arrow
                                        : Icons.pause,
                                    colors.ink,
                                    colors.paper,
                                    _busy || !recording.isActive
                                        ? null
                                        : _pauseOrResume,
                                  ),
                                  const SizedBox(width: OmniSpacing.xs),
                                  _action(
                                    '停止录音',
                                    Icons.stop,
                                    colors.brand,
                                    Theme.of(context).colorScheme.onPrimary,
                                    _busy || !recording.isActive ? null : _stop,
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// PCM音量历史从固定指示线向左移动，右侧仅显示未采样刻度。
class _AndroidWavePainter extends CustomPainter {
  /// 有界的真实音量历史。
  final List<double> samples;

  /// 当前采样格的连续位移。
  final double progress;

  /// 中性刻度颜色。
  final Color line;

  /// 固定指示线的主题色。
  final Color brand;

  /// 创建只负责绘制的波形快照。
  const _AndroidWavePainter({
    required this.samples,
    required this.progress,
    required this.line,
    required this.brand,
  });

  /// 仅绘制可见窗口，长录音不会增加每帧成本。
  @override
  void paint(Canvas canvas, Size size) {
    // 波形刻度使用细线而非整块填充。
    final Paint paint = Paint()
      ..color = line
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    // 居中指示线与历史窗口共享坐标。
    final double center = size.width / 2;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // 尚未采样区域保持短刻度。
    for (double x = 0; x < size.width; x += 4) {
      canvas.drawLine(
        Offset(x, size.height / 2 - 3),
        Offset(x, size.height / 2 + 3),
        paint,
      );
    }
    // 最新音量逐格左移，幅度严格来自采集事件。
    for (int index = samples.length - 1; index >= 0; index--) {
      // 当前历史条在可见窗口内的横坐标。
      final double x = center - (samples.length - 1 - index + progress) * 4;
      if (x < 0) break;
      // 给静音保留最小刻度，避免误画不存在的声音。
      final double half = math.max(3, samples[index] * size.height * .28);
      canvas.drawLine(
        Offset(x, size.height / 2 - half),
        Offset(x, size.height / 2 + half),
        paint,
      );
    }
    paint
      ..color = brand
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(center, 5), Offset(center, size.height - 5), paint);
    canvas.drawCircle(Offset(center, 5), 3, paint);
    canvas.restore();
  }

  /// 任意采样或主题变化才重画。
  @override
  bool shouldRepaint(_AndroidWavePainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.progress != progress ||
      oldDelegate.line != line ||
      oldDelegate.brand != brand;
}
