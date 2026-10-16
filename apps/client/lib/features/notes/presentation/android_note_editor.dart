part of 'android_notes_view.dart';

/// 呈现选择不改变草稿和提交协议，旧入口默认保持紧凑面板。
enum _AndroidNoteEditorMode { compact, fullscreen }

/// 根导航编辑面板只拥有输入状态，草稿及录音仍由应用会话管理。
class _AndroidNoteEditor extends ConsumerStatefulWidget {
  /// 历史页先暂存退出，再由原入口返回另一篇正在录音的草稿。
  final ValueChanged<NoteRecordingState>? onReturnRecording;

  /// 当前入口需要的表面，历史正式篇使用全屏。
  final _AndroidNoteEditorMode mode;

  /// 打开面板后开始采集，不在页面预载时申请权限。
  final bool startRecording;

  /// 加号图片动作在面板挂载后打开系统选择器。
  final bool pickImages;

  /// 主页录音确认后直接发布独立语音草稿。
  final bool quickVoice;

  /// 图片入口返回时不自动弹出键盘。
  final bool autofocus;

  /// 创建可恢复的底部编辑器。
  const _AndroidNoteEditor({
    this.onReturnRecording,
    this.mode = _AndroidNoteEditorMode.compact,
    this.startRecording = false,
    this.pickImages = false,
    this.quickVoice = false,
    this.autofocus = true,
  });

  /// 创建正文与关闭状态。
  @override
  ConsumerState<_AndroidNoteEditor> createState() => _AndroidNoteEditorState();
}

/// 明确发布与可靠暂存分离，任一关闭路径都先暂存。
class _AndroidNoteEditorState extends ConsumerState<_AndroidNoteEditor>
    with WidgetsBindingObserver {
  /// 当前实际编辑器，数据源切换时重新绑定。
  late NoteEditorController _editor;

  /// 可视文档保留输入法组词、撤销及选区。
  final NoteRichEditorController _rich = NoteRichEditorController();

  /// 正文焦点独立于主列表和搜索。
  final FocusNode _focus = FocusNode();

  /// 日历是锚点浮层，返回须先关闭它而不是提前退出整页。
  final MenuController _historyDateMenu = MenuController();

  /// 防止异步选择、保存和取消重复进入。
  bool _busy = false;

  /// 面板关闭前暂存的独立门禁。
  bool _closing = false;

  /// 面板内显示可重试错误，不把失败变成静默关闭。
  String? _error;

  /// 当前是否呈现独立录音卡片。
  late bool _voice;

  /// 录音退出交给同一个卡片状态处理。
  final GlobalKey<_AndroidRecordingCardState> _recordingKey = GlobalKey();

  /// 数据源变更后整页退出，不能绑定到新源的同名篇。
  bool _sourceChanged = false;

  /// 横向工具胶囊的当前类型。
  String? _tool;

  /// 切换语音前保存文字焦点意图。
  bool _focusBeforeVoice = false;

  /// 提交或权限启动期间保持编辑归属。
  bool get _editable =>
      !_busy &&
      !_closing &&
      !_editor.committing &&
      !_editor.recordingStarting &&
      !_editor.frozen &&
      !_editor.conflicted;

  /// 初始化输入并在首帧后执行入口明确请求的动作。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _editor = ref.read(noteEditorProvider)..addListener(_sync);
    _rich.syncMarkdown(_editor.draft.body, identity: _editor.draftId);
    _voice =
        widget.startRecording ||
        (_editor.recorder.state.isActive &&
            _editor.recorder.state.draftId == _editor.draftId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_voice) return;
      if (widget.pickImages) {
        unawaited(_pickImages());
      } else if (widget.autofocus) {
        if (widget.mode == _AndroidNoteEditorMode.fullscreen) {
          _rich.selection = TextSelection.collapsed(
            offset: _rich.plainText.length,
          );
        }
        _focus.requestFocus();
      }
    });
  }

  /// 注册根遮罩的唯一关闭门禁。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 业务面板负责保存与录音确认，路由只提供视觉覆盖。
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route is _AndroidComposerRoute) route.requestClose = _requestClose;
  }

  /// 返回先收工具或键盘，录音则进入显式退出确认。
  Future<void> _requestClose({bool back = false}) async {
    if (_voice) {
      await _recordingKey.currentState?.requestExit();
    } else if (_historyDateMenu.isOpen) {
      _historyDateMenu.close();
    } else if (_tool != null) {
      setState(() => _tool = null);
    } else if (back && MediaQuery.viewInsetsOf(context).bottom > 0) {
      _focus.unfocus();
    } else {
      await _close();
    }
  }

  /// 外部草稿恢复或转写变化同步正文，但不把选区变化保存为内容。
  void _sync() {
    if (!mounted) return;
    _rich.syncMarkdown(_editor.draft.body, identity: _editor.draftId);
    setState(() {});
  }

  /// 系统暂停时草稿仍可靠落盘，录音不停止。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_editor.flush());
    }
  }

  /// 释放页面自己的控制器，不取消应用级采集。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _editor.removeListener(_sync);
    _rich.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 所有异步修改都保持当前面板身份，失败后恢复可重试入口。
  Future<void> _guard(Future<void> Function() action) async {
    if (_busy || _closing || _editor.committing) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 返回、遮罩和下滑统一暂存；只有可靠落盘后才移除覆盖层。
  Future<void> _close() async {
    if (_busy || _closing || _editor.committing || _editor.recordingStarting) {
      return;
    }
    setState(() {
      _closing = true;
      _error = null;
    });
    try {
      await _editor.flush();
      if (_editor.dirty) throw StateError(_editor.error ?? '草稿暂存失败，请重试');
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  /// 正式提交等待控制器排空音频与图片队列，失败保持面板。
  Future<void> _commit({bool saveAsNew = false}) => _guard(() async {
    if (saveAsNew) {
      await _editor.saveAsNew();
      if (_editor.error != null || _editor.conflicted || _editor.dirty) return;
    } else {
      // 空白和冲突都不作为提交成功处理。
      final NoteCommitResult result = await _editor.commit();
      if (result != NoteCommitResult.committed) {
        if (result == NoteCommitResult.empty &&
            widget.mode == _AndroidNoteEditorMode.fullscreen &&
            !_editor.dirty &&
            !_editor.frozen &&
            !_editor.conflicted &&
            _editor.error == null) {
          if (mounted) Navigator.pop(context);
          return;
        }
        if (result == NoteCommitResult.empty && mounted) {
          setState(() => _error = '请先输入内容或添加图片、录音');
        }
        return;
      }
    }
    if (mounted) Navigator.of(context).pop();
  });

  /// 明确放弃才取消这一代；取消不会删除正式笔记及其原件。
  Future<void> _discard() async {
    if (!_editable && !_editor.frozen && !_editor.conflicted) return;
    // 丢弃入口与普通收起明确分开。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '放弃更改？',
      message: '将丢弃这份本机草稿及尚未发布的附件，正式笔记保持原样。',
      confirmLabel: '放弃更改',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    await _guard(() async {
      await _editor.cancel();
      if (_editor.error != null) throw StateError(_editor.error!);
      if (mounted) Navigator.pop(context);
    });
  }

  /// 相机和相册共用持久归属与丢失结果恢复服务。
  Future<void> _pickImages({bool camera = false}) => _guard(() async {
    // 系统界面返回后恢复此前的文字输入意图。
    final bool focused = _focus.hasFocus;
    _focus.unfocus();
    await ref.read(noteImageAcquisitionProvider).acquire(camera: camera);
    if (mounted && focused) _focus.requestFocus();
  });

  /// 进入录音时保留原文档和选区，不创建新草稿。
  void _startVoice() {
    if (!_editable) return;
    if (_editor.recorder.state.isActive &&
        _editor.recorder.state.draftId != _editor.draftId) {
      showOmniMessage(context, message: '另有录音进行中，请先返回原录音');
      return;
    }
    _focusBeforeVoice = _focus.hasFocus;
    _focus.unfocus();
    setState(() {
      _tool = null;
      _voice = true;
    });
  }

  /// 主页确认发布；编辑器确认仅完成原音暂存并返回原文档。
  Future<void> _confirmVoice() async {
    await _editor.finishRecording();
    if (widget.quickVoice) {
      // 发布结果必须明确成功，失败时留在原卡片重试。
      final NoteCommitResult result = await _editor.commit();
      if (result != NoteCommitResult.committed) {
        throw StateError(_editor.error ?? '语音笔记发布失败，请重试');
      }
      if (mounted) Navigator.pop(context);
    } else if (mounted) {
      setState(() => _voice = false);
      if (_focusBeforeVoice) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focus.requestFocus();
        });
      }
    }
  }

  /// 卡片已清理本次片段，主页还需取消独立空草稿。
  Future<void> _cancelVoice() async {
    if (widget.quickVoice) {
      await _editor.cancel();
      if (_editor.error != null) throw StateError(_editor.error!);
      if (mounted) Navigator.pop(context);
    } else if (mounted) {
      setState(() => _voice = false);
      if (_focusBeforeVoice) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focus.requestFocus();
        });
      }
    }
  }

  /// 转写插入先修改可视选区，再保留候选消费标记供事务提交。
  Future<void> _insert(NoteAudioSegmentRecord segment, String text) =>
      _guard(() async {
        if (_editor.frozen ||
            _editor.conflicted ||
            _editor.isAudioRemoved(segment.id)) {
          return;
        }
        // 等待文件状态时不能把另一个草稿标成已插入。
        final String? draftId = _editor.draftId;
        // 该笔记或原音对应的本机持久事实。
        final NoteAudioLocalFileRecord? local =
            await (_editor.repository.database.select(
              _editor.repository.database.noteAudioLocalFiles,
            )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
        if (!mounted || _editor.draftId != draftId) return;
        _rich.insertText(text);
        _editor.edit(body: _rich.markdown);
        _editor.markTranscriptInsertion(
          segment.id,
          candidate: local?.candidateTranscript == text,
        );
        await _editor.flush();
      });

  /// 删除前停止本段回听，暂存删除不影响其他原件。
  Future<void> _removeAudio(String id) => _guard(() async {
    // 查询期间固定原草稿身份，避免外部定位后误删另一代。
    final String? draftId = _editor.draftId;
    // 正式和本机草稿原音都可能正在回听。
    final AppDatabase database = _editor.repository.database;
    // 本机正式原音的缓存路径。
    final NoteAudioLocalFileRecord? local = await (database.select(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
    // 尚未发布原音的缓存路径。
    final NoteDraftAudioSegmentRecord? staged = await (database.select(
      database.noteDraftAudioSegments,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
    if (!mounted || _editor.draftId != draftId) return;
    if (ref.read(noteAudioPlayerProvider).currentPath != null &&
        ref.read(noteAudioPlayerProvider).currentPath ==
            (local?.localPath ?? staged?.localPath)) {
      await ref.read(noteAudioPlayerProvider).stop();
    }
    if (mounted && _editor.draftId == draftId) await _editor.removeAudio(id);
  });

  /// 浏览另一篇笔记时可返回正在采集的原草稿，切换只暂存当前修改。
  Future<void> _returnToRecording(NoteRecordingState recording) =>
      _guard(() async {
        if (widget.mode == _AndroidNoteEditorMode.fullscreen) {
          await _editor.flush();
          if (_editor.dirty) throw StateError(_editor.error ?? '草稿暂存失败，请重试');
          if (!mounted || _sourceChanged) return;
          widget.onReturnRecording?.call(recording);
          Navigator.pop(context);
          return;
        }
        if (recording.draftId != null) {
          await _editor.openLocalDraft(recording.draftId!);
        } else if (recording.noteId != null) {
          await _editor.open(recording.noteId!);
        }
      });

  /// 新录音的自动转写授权只影响之后的采集。
  Future<void> _voiceConsent() async {
    if (!_editable) return;
    if (_editor.voiceConsent) {
      setState(() => _editor.voiceConsent = false);
      return;
    }
    // 明确说明服务提交边界，本机录音不要求开启转写。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '开启语音转文字',
      message: '之后的新录音将通过已连接的服务器提交给语音识别服务。需开启同步，原音与转写分别保留。',
      confirmLabel: '开启',
    );
    if (confirmed && mounted) setState(() => _editor.voiceConsent = true);
  }

  /// 版本恢复只更改当前草稿，仍需显式保存。
  Future<void> _versions() async {
    // 版本选择只允许回填打开列表时的原笔记。
    final String noteId = _editor.draft.id;
    if (widget.mode == _AndroidNoteEditorMode.fullscreen) {
      // 历史页沿用移动端完整版本正文，只把选择结果回填当前篇。
      final NoteVersionRecord? selected =
          await _androidReadOnlySheet<NoteVersionRecord>(
            context,
            (_) => _AndroidNoteVersions(source: _editor.repository, id: noteId),
          );
      if (selected != null &&
          mounted &&
          !_sourceChanged &&
          _editor.draft.id == noteId) {
        await _guard(() => _editor.useVersion(selected.body));
      }
      return;
    }
    // 版本列表使用正式仓储，不伪造当前尚未保存的正文。
    final List<NoteVersionRecord> versions = await _editor.repository
        .watchVersions(_editor.draft.id)
        .first;
    if (!mounted) return;
    await showOmniDialog<void>(
      context: context,
      builder: (context) => OmniDialogScaffold(
        title: '版本记录',
        width: 560,
        height: 480,
        child: ListView(
          children: [
            if (versions.isEmpty) const Text('暂无历史版本'),
            for (final NoteVersionRecord version in versions)
              OmniListTile(
                title: Text(
                  NoteMarkdown.plainText(version.body),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${version.createdAt.toLocal()}'),
                onTap: () {
                  Navigator.pop(context);
                  if (_editor.draft.id == noteId) {
                    unawaited(_guard(() => _editor.useVersion(version.body)));
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 顶部菜单复制当前未保存文字，删除仍保留冻结草稿。
  Future<void> _historyMenu(BuildContext anchor) async {
    if (_busy || _closing || _editor.committing) return;
    // 原篇身份在菜单关闭后仍须一致。
    final String id = _editor.draft.id;
    // 同一代次防止异步返回覆盖另一篇草稿。
    final String? owner = _editor.draftId;
    // 使用按钮真实坐标及统一菜单过渡。
    final RenderBox box = anchor.findRenderObject()! as RenderBox;
    // 根覆盖层包含全屏历史页。
    final RenderBox overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay!.context.findRenderObject()!
            as RenderBox;
    // 右下缘对齐并允许自动避让屏幕。
    final Offset point = box.localToGlobal(
      Offset(box.size.width, box.size.height),
      ancestor: overlay,
    );
    // 编辑页只保留视频中的复制全文与删除，不做分享。
    final String? action = await showOmniMenu<String>(
      wholePanelTransition: true,
      context: anchor,
      useRootNavigator: true,
      position: RelativeRect.fromRect(
        point & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final (String, String) item in [
          ('copy', '复制全文'),
          ('delete', '删除'),
        ])
          OmniPopupMenuItem.custom(
            value: item.$1,
            height: OmniSize.touch,
            padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
            danger: item.$1 == 'delete',
            child: Text(
              item.$2,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: item.$1 == 'delete'
                    ? OmniColors.of(context).danger
                    : OmniColors.of(context).ink,
              ),
            ),
          ),
      ],
    );
    if (!mounted ||
        _sourceChanged ||
        id != _editor.draft.id ||
        owner != _editor.draftId ||
        _editor.committing) {
      return;
    }
    if (action == 'copy') await _androidCopyNote(context, _rich.markdown);
    if (action == 'delete' && mounted) {
      setState(() => _busy = true);
      try {
        if (await _androidDeleteNote(context, ref, id) && mounted) {
          Navigator.pop(context);
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  /// 标签选择允许清空集合，确认后才修改正文之外的标签事实。
  Future<void> _tags(List<TaxonomyEntry> tags) async {
    if (!_editable) return;
    // 工具操作始终保留原正文的可视选区。
    final bool focused = _focus.hasFocus;
    _focus.unfocus();
    // 标签子面板沿用搜索界面的平铺与键盘适配。
    final Set<String>? ids = await Navigator.of(context, rootNavigator: true)
        .push<Set<String>>(
          ModalBottomSheetRoute<Set<String>>(
            isScrollControlled: true,
            useSafeArea: true,
            backgroundColor: Colors.transparent,
            builder: (context) => PopScope<Set<String>>(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                if (MediaQuery.viewInsetsOf(context).bottom > 0) {
                  FocusScope.of(context).unfocus();
                } else {
                  Navigator.pop(context);
                }
              },
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Material(
                  color: OmniColors.of(context).paper,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(OmniSpacing.xl),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _AndroidNoteTagPicker(
                    tags: tags,
                    selected: _editor.draft.tags,
                    allowEmpty: true,
                    onCancel: () => Navigator.pop(context),
                    onConfirm: (ids) => Navigator.pop(context, ids),
                  ),
                ),
              ),
            ),
          ),
        );
    if (!mounted) return;
    if (ids != null) _editor.edit(tags: ids);
    if (focused) _focus.requestFocus();
  }

  /// 低频选项移入单独面板，主编辑器只保留正文与一排工具。
  Future<void> _options(
    List<TaxonomyEntry> tags,
    List<NoteAudioSegmentRecord> audio,
  ) async {
    setState(() => _tool = null);
    _focus.unfocus();
    await showOmniExpandableBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => OmniExpandableBottomSheetScaffold(
          initialExtent: .65,
          maximumExtent: .95,
          semanticsLabel: '笔记选项',
          trailing: const SizedBox.shrink(),
          leading: OmniButton(
            label: '返回',
            variant: OmniButtonVariant.text,
            onPressed: () => Navigator.pop(context),
          ),
          bodyBuilder: (context, _) => ListenableBuilder(
            listenable: _editor,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('笔记选项', style: Theme.of(context).textTheme.titleLarge),
                Text(_editor.saveStatus),
                OmniDatePickerButton(
                  value: DateTime.parse(_editor.draft.dayKey),
                  initialDate: DateTime.parse(_editor.draft.dayKey),
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(),
                  label: _editor.draft.dayKey,
                  onChanged: _editable
                      ? (day) => _editor.edit(dayKey: businessDayKey(day))
                      : null,
                ),
                if (_editor.error != null) Text(_editor.error!),
                OmniButton(
                  label: '重试暂存',
                  variant: OmniButtonVariant.text,
                  onPressed: _busy ? null : () => _guard(_editor.flush),
                ),
                if (_editor.frozen || _editor.conflicted)
                  OmniButton(
                    label: '另存为新笔记',
                    onPressed: _busy
                        ? null
                        : () {
                            Navigator.pop(context);
                            unawaited(_commit(saveAsNew: true));
                          },
                  ),
                OmniButton(
                  label: _editor.voiceConsent ? '关闭自动转文字' : '开启自动转文字',
                  variant: OmniButtonVariant.text,
                  onPressed: _voiceConsent,
                ),
                OmniButton(
                  label: '恢复上次录音',
                  variant: OmniButtonVariant.text,
                  onPressed: () => _guard(_editor.recover),
                ),
                if (ref.read(noteImageAcquisitionProvider).error != null) ...[
                  Text(ref.read(noteImageAcquisitionProvider).error!),
                  OmniButton(
                    label: '重试图片导入',
                    variant: OmniButtonVariant.text,
                    onPressed: () => _guard(() async {
                      await ref.read(noteImageAcquisitionProvider).recover();
                    }),
                  ),
                ],
                OmniButton(
                  label: '开始录音',
                  icon: Icons.mic_none,
                  variant: OmniButtonVariant.secondary,
                  onPressed: _editable
                      ? () {
                          Navigator.pop(context);
                          _startVoice();
                        }
                      : null,
                ),
                if (_editor.recorder.state.isActive &&
                    _editor.recorder.state.draftId != _editor.draftId)
                  OmniButton(
                    label: '返回正在录音的笔记',
                    onPressed: () {
                      Navigator.pop(context);
                      unawaited(_returnToRecording(_editor.recorder.state));
                    },
                  ),
                for (final NoteAudioSegmentRecord segment in audio)
                  _AndroidNoteAudio(
                    segment: segment,
                    editing: true,
                    onInsert: (text) => _insert(segment, text),
                    onDelete: () => _removeAudio(segment.id),
                  ),
                if (_editor.draftId != null) _draftAudio(_editor),
                if (_editor.draft.baseRevision.isNotEmpty)
                  OmniButton(
                    label: '版本记录',
                    variant: OmniButtonVariant.text,
                    onPressed: () {
                      Navigator.pop(context);
                      unawaited(_versions());
                    },
                  ),
                OmniButton(
                  label: '放弃更改',
                  variant: OmniButtonVariant.text,
                  onPressed: () {
                    Navigator.pop(context);
                    unawaited(_discard());
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 紧凑图标沿用Omni热区，选中格式只显示轻底色。
  Widget _toolButton(
    String tooltip,
    IconData icon,
    VoidCallback? action, {
    bool selected = false,
  }) => OmniIconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: OmniSpacing.xl),
    onPressed: action,
    style: selected
        ? ButtonStyle(
            backgroundColor: WidgetStatePropertyAll(
              OmniColors.of(context).mist,
            ),
          )
        : null,
  );

  /// 横向工具胶囊浮于正文之上，不使编辑面板上下跳动。
  Widget? _popup(List<TaxonomyEntry> tags, List<NoteAudioSegmentRecord> audio) {
    if (_tool == null) return null;
    // 退场动画保留创建时的工具种类，不跟随新状态切换内容。
    final bool list = _tool == 'list';
    return Align(
      key: ValueKey(_tool),
      alignment: Alignment.bottomCenter,
      child: Material(
        elevation: 3,
        color: OmniColors.of(context).paper,
        borderRadius: BorderRadius.circular(OmniRadius.pill),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.all(OmniSpacing.xxs),
            child: ListenableBuilder(
              listenable: _rich,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: list
                    ? [
                        _toolButton(
                          '无序列表',
                          Icons.format_list_bulleted,
                          _editable
                              ? () {
                                  _rich.toggleList(false);
                                  setState(() {});
                                }
                              : null,
                          selected: _rich.isBulletList,
                        ),
                        _toolButton(
                          '有序列表',
                          Icons.format_list_numbered,
                          _editable
                              ? () {
                                  _rich.toggleList(true);
                                  setState(() {});
                                }
                              : null,
                          selected: _rich.isOrderedList,
                        ),
                      ]
                    : [
                        _toolButton(
                          '高亮',
                          Icons.highlight,
                          _editable ? _rich.toggleHighlight : null,
                          selected: _rich.isHighlight,
                        ),
                        _toolButton(
                          '下划线',
                          Icons.format_underlined,
                          _editable ? _rich.toggleUnderline : null,
                          selected: _rich.isUnderline,
                        ),
                        _toolButton(
                          '笔记选项',
                          Icons.tune,
                          () => _options(tags, audio),
                        ),
                        _toolButton(
                          '拍照',
                          Icons.photo_camera_outlined,
                          _editable ? () => _pickImages(camera: true) : null,
                        ),
                        _toolButton(
                          '撤销',
                          Icons.undo,
                          _editable && _rich.canUndo ? _rich.undo : null,
                        ),
                        _toolButton(
                          '重做',
                          Icons.redo,
                          _editable && _rich.canRedo ? _rich.redo : null,
                        ),
                      ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 默认200dp的正文面板，原草稿与富文本控制器不随语音切换销毁。
  @override
  Widget build(BuildContext context) {
    // 数据源替换时解绑原控制器，旧回调不得修改新资料库。
    final NoteEditorController editor = ref.watch(noteEditorProvider);
    if (!identical(editor, _editor) &&
        widget.mode == _AndroidNoteEditorMode.fullscreen) {
      if (!_sourceChanged) {
        _sourceChanged = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // 先关闭本页的菜单或选择器，随后退出原全屏路由。
          final ModalRoute<Object?>? route = ModalRoute.of(context);
          Navigator.of(context)
              .popUntil((candidate) => identical(candidate, route));
          Navigator.pop(context);
          showOmniMessage(context, message: '数据源已切换，请重新打开笔记');
        });
      }
      return ColoredBox(color: OmniColors.of(context).paper);
    }
    if (!identical(editor, _editor)) {
      _editor.removeListener(_sync);
      _editor = editor..addListener(_sync);
      _rich.syncMarkdown(editor.draft.body, identity: editor.draftId);
    }
    ref.listen(noteByIdProvider(editor.draft.id), (_, next) {
      // 延后读取当前正式记录，保留既有冲突保护。
      final String id = editor.draft.id;
      if (next.hasValue) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_editor, editor) && editor.draft.id == id) {
            editor.acceptRemote(next.value);
          }
        });
      }
    });
    // 标签沿用共享仓储的有效平铺顺序。
    final List<TaxonomyEntry> tags =
        (ref.watch(noteTaxonomiesProvider).value ?? [])
            .where((tag) => tag.kind == 'tag' && tag.deletedAt == null)
            .toList();
    // 原音条与提交按钮只依据真实原音事实。
    final List<NoteAudioSegmentRecord> audio =
        (ref.watch(noteAudioProvider(editor.draft.id)).value ?? [])
            .where((segment) => !editor.isAudioRemoved(segment.id))
            .toList();
    // 本机未发布原音同样可以使发送按钮可用。
    final AsyncValue<List<NoteDraftAudioSegmentRecord>> staged = ref.watch(
      androidDraftAudioProvider(editor.draftId),
    );
    // 空白格式和空标签不作为可提交的正文。
    final bool content =
        _rich.plainText.trim().isNotEmpty ||
        editor.hasImages ||
        audio.isNotEmpty ||
        (staged.value ?? []).any((item) => !editor.isAudioRemoved(item.id));
    // 紧凑面板为附件预留首屏位置，避免空正文把图片和原音全部挤到下方。
    final bool attachments =
        editor.hasImages ||
        editor.draft.tags.isNotEmpty ||
        audio.isNotEmpty ||
        (staged.value ?? []).any((item) => !editor.isAudioRemoved(item.id));
    // 语义颜色由当前主题决定。
    final OmniColors colors = OmniColors.of(context);
    // 正文与附件在两种表面中共用同一富文本控制器。
    final Widget body = LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        key: const ValueKey('android-composer-body'),
        padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null || editor.error != null)
              Text(
                _error ?? editor.error!,
                style: TextStyle(color: colors.danger),
              ),
            ConstrainedBox(
              constraints: widget.mode == _AndroidNoteEditorMode.fullscreen
                  ? const BoxConstraints()
                  : BoxConstraints.tightFor(
                      height: attachments
                          ? math.min(
                              constraints.maxHeight,
                              MediaQuery.textScalerOf(context).scale(32),
                            )
                          : math.max(72, constraints.maxHeight),
                    ),
              child: Listener(
                onPointerDown: (_) {
                  if (_tool != null) setState(() => _tool = null);
                },
                child: NoteRichEditor(
                  key: const ValueKey('android-note-rich-editor'),
                  controller: _rich,
                  focusNode: _focus,
                  minHeight: 0,
                  scrollable: widget.mode != _AndroidNoteEditorMode.fullscreen,
                  enabled: !_busy && !_closing && !editor.committing,
                  readOnly: editor.frozen || editor.conflicted,
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(height: 1.5),
                  onChanged: (value) => editor.edit(body: value),
                ),
              ),
            ),
            if (editor.draft.tags.isNotEmpty)
              Wrap(
                spacing: OmniSpacing.xs,
                children: [
                  for (final TaxonomyEntry tag in tags.where(
                    (tag) => editor.draft.tags.contains(tag.id),
                  ))
                    Text(
                      '${tag.iconEmoji ?? '#'} ${tag.name}',
                      style: TextStyle(color: colors.brand),
                    ),
                ],
              ),
            _AndroidNoteImages(
              noteId: editor.draft.id,
              draftId: editor.draftId,
              onRemove: (id) => _guard(() => editor.removeImage(id)),
            ),
            for (final NoteAudioSegmentRecord segment in audio)
              _AndroidNoteAudio(
                segment: segment,
                editing: true,
                onInsert: (text) => _insert(segment, text),
                onDelete: () => _removeAudio(segment.id),
              ),
            if (editor.draftId != null) _draftAudio(editor),
          ],
        ),
      ),
    );
    // 工具栏固定在实际键盘上沿，保存仍走同一事务。
    final Widget toolbar = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OmniSpacing.xs,
        vertical: OmniSpacing.xxs,
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ListenableBuilder(
                listenable: _rich,
                builder: (context, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _toolButton(
                      '选择标签',
                      Icons.tag,
                      _editable ? () => _tags(tags) : null,
                    ),
                    _toolButton(
                      '添加图片',
                      Icons.image_outlined,
                      _editable ? () => _pickImages() : null,
                    ),
                    SizedBox(
                      height: OmniSize.icon,
                      child: VerticalDivider(
                        color: colors.line,
                        width: OmniSpacing.sm,
                      ),
                    ),
                    _toolButton(
                      '加粗',
                      Icons.format_bold,
                      _editable ? _rich.toggleBold : null,
                      selected: _rich.isBold,
                    ),
                    _toolButton(
                      '列表格式',
                      Icons.format_list_bulleted,
                      () => setState(
                        () => _tool = _tool == 'list' ? null : 'list',
                      ),
                      selected: _tool == 'list',
                    ),
                    SizedBox(
                      height: OmniSize.icon,
                      child: VerticalDivider(
                        color: colors.line,
                        width: OmniSpacing.sm,
                      ),
                    ),
                    _toolButton(
                      '更多笔记工具',
                      Icons.more_horiz,
                      () => setState(
                        () => _tool = _tool == 'more' ? null : 'more',
                      ),
                      selected: _tool == 'more',
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_rich.plainText.trim().isEmpty)
            SizedBox(
              width: OmniSize.touch,
              height: OmniSize.touch,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: OmniSize.touch - OmniSpacing.sm,
                    height: OmniSize.touch - OmniSpacing.sm,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.line),
                    ),
                  ),
                  OmniIconButton(
                    tooltip: '开始录音',
                    icon: Icon(
                      Icons.mic_none,
                      color: colors.brand,
                      size: OmniSpacing.xl,
                    ),
                    onPressed: _editable ? _startVoice : null,
                  ),
                ],
              ),
            ),
          SizedBox(
            width: OmniSize.touch + OmniSpacing.sm,
            height: OmniSize.touch,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedContainer(
                  duration: OmniMotion.duration(
                    context,
                    const Duration(milliseconds: 120),
                  ),
                  width: OmniSize.touch + OmniSpacing.sm,
                  height: OmniSize.touch - OmniSpacing.sm,
                  decoration: BoxDecoration(
                    color: content ? colors.brand : colors.mist,
                    borderRadius: BorderRadius.circular(OmniRadius.pill),
                  ),
                ),
                OmniIconButton(
                  key: const ValueKey('android-note-publish'),
                  tooltip: editor.draft.baseRevision.isEmpty ? '发布' : '保存',
                  onPressed: _editable && content ? () => _commit() : null,
                  style: ButtonStyle(
                    backgroundColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    minimumSize: const WidgetStatePropertyAll(
                      Size(OmniSize.touch + OmniSpacing.sm, OmniSize.touch),
                    ),
                    shape: const WidgetStatePropertyAll(StadiumBorder()),
                  ),
                  icon: Icon(
                    widget.mode == _AndroidNoteEditorMode.fullscreen
                        ? Icons.check
                        : Icons.send_rounded,
                    color: content
                        ? Theme.of(context).colorScheme.onPrimary
                        : colors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    // 本页是否使用历史专用全屏表面。
    final bool fullscreen = widget.mode == _AndroidNoteEditorMode.fullscreen;
    // 历史正文始终挂载，录音覆盖不丢选区和撤销。
    final Widget surface = fullscreen
        ? _AndroidHistorySurface(
            dateMenu: _historyDateMenu,
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _editable ? _focus.requestFocus : null,
              child: body,
            ),
            toolbar: toolbar,
            popup: _popup(tags, audio),
            dateLabel:
                '${editor.draft.dayKey} ${_androidNoteTime(editor.draft.createdAt ?? DateTime.now(), seconds: true).split(' ').last}',
            onBack: _busy || _closing || editor.committing
                ? null
                : () => unawaited(_requestClose(back: true)),
            day: DateTime.tryParse(editor.draft.dayKey) ?? DateTime.now(),
            onDate: _editable
                ? (day) {
                    if (!_sourceChanged &&
                        identical(editor, _editor) &&
                        _editable) {
                      editor.edit(dayKey: businessDayKey(day));
                    }
                  }
                : null,
            onMenu: _busy || _closing || editor.committing
                ? null
                : (anchor) => unawaited(_historyMenu(anchor)),
          )
        : _AndroidComposerSurface(
            enabled: _editable,
            onClose: _close,
            popup: _popup(tags, audio),
            body: body,
            toolbar: toolbar,
          );
    // 卡片的数据归属与紧凑模式完全相同。
    Widget recording() => _AndroidRecordingCard(
      key: _recordingKey,
      editor: editor,
      onConfirm: _confirmVoice,
      onCancel: _cancelVoice,
    );
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestClose(back: true));
      },
      child: fullscreen
          ? Stack(
              fit: StackFit.expand,
              children: [
                surface,
                AnimatedSwitcher(
                  duration: OmniMotion.duration(
                    context,
                    const Duration(milliseconds: 280),
                  ),
                  reverseDuration: OmniMotion.duration(
                    context,
                    const Duration(milliseconds: 220),
                  ),
                  child: _voice
                      ? _AndroidHistoryVoiceCover(
                          child: recording(),
                          onClose: () => unawaited(_requestClose()),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            )
          : AnimatedSwitcher(
              duration: OmniMotion.duration(
                context,
                const Duration(milliseconds: 280),
              ),
              reverseDuration: OmniMotion.duration(
                context,
                const Duration(milliseconds: 220),
              ),
              child: _voice ? recording() : surface,
            ),
    );
  }

  /// 本机原音复用回听组件，未发布前不提供正式识别入口。
  Widget _draftAudio(NoteEditorController editor) =>
      StreamBuilder<List<NoteDraftAudioSegmentRecord>>(
        key: ValueKey('android-draft-audio-${editor.draftId}'),
        stream:
            (editor.repository.database.select(
                    editor.repository.database.noteDraftAudioSegments,
                  )
                  ..where((table) => table.draftId.equals(editor.draftId!))
                  ..orderBy([(table) => OrderingTerm.asc(table.sortOrder)]))
                .watch(),
        builder: (context, snapshot) => Column(
          children: [
            for (final NoteDraftAudioSegmentRecord audio in snapshot.data ?? [])
              if (!editor.isAudioRemoved(audio.id))
                _AndroidNoteAudio(
                  staged: true,
                  editing: true,
                  segment: NoteAudioSegmentRecord(
                    id: audio.id,
                    noteId: audio.noteId,
                    durationMs: audio.durationMs,
                    mime: audio.mime,
                    sha256: audio.sha256,
                    byteSize: audio.byteSize,
                    sortOrder: audio.sortOrder,
                    createdAt: audio.startedAt,
                    updatedAt: audio.startedAt,
                  ),
                  draftLocal: NoteAudioLocalFileRecord(
                    id: audio.id,
                    localPath: audio.localPath,
                    uploadState: 'local',
                    recognitionState: 'idle',
                    consent: false,
                  ),
                  onDelete: () => _removeAudio(audio.id),
                ),
          ],
        ),
      );
}
