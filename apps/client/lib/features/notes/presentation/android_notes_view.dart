import 'note_record_time_picker.dart';
import 'note_pin_indicator.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/settings/presentation/recycle_bin_section.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/shared/ui/omni_modal_bottom_sheet.dart';

import '../audio/note_recorder_service.dart';
import '../data/note_editor_controller.dart';
import '../data/note_image_repository.dart';
import '../data/note_providers.dart';
import '../data/note_repository.dart';
import '../data/note_search_filter.dart';
import '../data/note_search_history.dart';
import '../data/note_statistics.dart';
import '../data/note_tag_actions.dart';
import '../data/note_tag_emoji_catalog.dart';
import '../markdown/note_markdown.dart';
import 'note_audio_card.dart';
import 'note_markdown_text.dart';
import 'note_rich_editor.dart';
import 'windows_note_statistics_dialog.dart';
import 'windows_note_tag_editor.dart' show NoteTagIcon;

part 'android_note_editor.dart';
part 'android_note_actions.dart';
part 'android_note_history_surface.dart';
part 'android_note_composer_surface.dart';
part 'android_note_recording.dart';
part 'android_note_search.dart';
part 'android_note_search_filter.dart';
part 'android_note_search_history.dart';
part 'android_note_sidebar.dart';
part 'android_note_sidebar_tags.dart';
part 'android_note_tag_pages.dart';
part 'android_note_statistics.dart';
part 'android_note_widgets.dart';

/// Android 以正式笔记列表为入口，覆盖层与应用底部导航分离。
class AndroidNotesView extends ConsumerStatefulWidget {
  /// 外部搜索或录音通知指定的正式笔记身份。
  final String? initialNoteId;

  /// 创建安卓笔记工作区。
  const AndroidNotesView({this.initialNoteId, super.key});

  /// 创建独立于桌面呈现的页面状态。
  @override
  ConsumerState<AndroidNotesView> createState() => _AndroidNotesViewState();
}

/// 列表保活，编辑、搜索和侧栏由根导航覆盖。
class _AndroidNotesViewState extends ConsumerState<AndroidNotesView>
    with WidgetsBindingObserver {
  /// 主列表滚动位置不随搜索或编辑重置。
  final ScrollController _scroll = ScrollController();

  /// 抽屉关闭后继续保留用户浏览标签的位置。
  final ScrollController _sidebarScroll = _AndroidSidebarScrollController();

  /// 同一标签两处入口只高亮实际点选的那一行。
  String _sidebarOrigin = 'all';

  /// 当前列表的标签和日期条件。
  NoteSearchFilter _filter = const NoteSearchFilter.empty();

  /// 热图或统计选择的归档日。
  String? _day;

  /// 主列表内唯一展开的正文。
  String? _expanded;

  /// 独立笔记回收站视图。
  bool _recycle = false;

  /// 避免重复打开编辑覆盖层。
  bool _editorOpen = false;

  /// 编辑器异步加载阶段禁止重复请求。
  bool _opening = false;

  /// 外部请求只在参数变化时消费。
  String? _openedId;

  /// 路由与通知监听不触发预载录音。
  GoRouter? _router;

  /// 录音通知可定位本机尚未发布的草稿。
  StreamSubscription<String>? _returns;

  /// 记录通知订阅的采集器，数据源切换时重新绑定。
  NoteRecorderService? _recorder;

  /// 同库扩展通过此方法更新页面，遵循 State 的受保护成员边界。
  void _update(VoidCallback change) {
    if (mounted) setState(change);
  }

  /// 当前数据源拥有的唯一编辑会话。
  NoteEditorController get _editor => ref.read(noteEditorProvider);

  /// 安装生命周期观察但不创建业务记录。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 原生通知与路由只在页面真正进入时打开编辑器。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 当前应用路由器。
    final GoRouter? router = GoRouter.maybeOf(context);
    if (!identical(router, _router)) {
      _router?.routeInformationProvider.removeListener(_routeChanged);
      _router = router;
      router?.routeInformationProvider.addListener(_routeChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _routeChanged());
  }

  /// 参数更新后的定位在构建结束后执行。
  @override
  void didUpdateWidget(AndroidNotesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialNoteId != widget.initialNoteId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _routeChanged());
    }
  }

  /// 预载或重新选择底栏不会创建空白草稿，也不会打开键盘。
  void _routeChanged() {
    if (!mounted) return;
    // 没有真实路由的组件测试也可通过 initialNoteId 定位。
    final bool active =
        _router == null ||
        _router!.routeInformationProvider.value.uri.path == '/notes';
    if (!active) {
      _openedId = null;
      unawaited(_editor.flush());
      return;
    }
    // 外部请求不同于普通分支进入。
    final String? id = widget.initialNoteId;
    if (id == null) _openedId = null;
    if (id != null && id != _openedId) {
      _openedId = id;
      unawaited(_openEditor(noteId: id));
    }
  }

  /// 切后台只暂存文字，应用级采集器保持录音。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_editor.flush());
    }
  }

  /// 页面退出不销毁应用级编辑器及录音器。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router?.routeInformationProvider.removeListener(_routeChanged);
    unawaited(_returns?.cancel());
    _scroll.dispose();
    _sidebarScroll.dispose();
    super.dispose();
  }

  /// 优先返回正在录音的草稿，通知里的身份不假设已存在正式表。
  Future<void> _openEditor({
    String? noteId,
    String? draftId,
    // 从版本面板恢复的固定正文，只应用到对应正式篇的草稿。
    NoteVersionRecord? version,
    // 是否由入口明确请求开始录音。
    bool record = false,
    // 是否由入口明确请求选择图片。
    bool images = false,
    // 图片回填时不主动弹出键盘。
    bool autofocus = true,
  }) async {
    if (_editorOpen ||
        _opening ||
        _editor.committing ||
        _editor.recordingStarting) {
      return;
    }
    _opening = true;
    // 所有异步步骤固定同一数据源编辑器，完成前再核验身份。
    final NoteEditorController session = _editor;
    // 只有真正创建覆盖层的调用才能清除打开状态。
    bool ownsSheet = false;
    // 独立语音结束后恢复此前已经可靠暂存的文字草稿。
    String? previousDraft;
    // 历史编辑退出后再回原录音，避免同一全屏页中途换篇。
    NoteRecordingState? returnRecording;
    // 只有主页主动录音创建新草稿，通知返回仍沿用原身份。
    final bool quickVoice =
        record &&
        noteId == null &&
        draftId == null &&
        !session.recorder.state.isActive;
    try {
      if (quickVoice) {
        await session.flush();
        if (session.dirty) throw StateError(session.error ?? '原草稿尚未暂存');
        previousDraft = (await session.localDrafts.find(session.draftId!))?.id;
        if (!await session.startFreshComposer()) return;
      } else if (draftId != null) {
        await session.openLocalDraft(draftId);
      } else if (noteId != null) {
        // 原音仍绑定当前草稿时禁止切成另一代同名正式笔记。
        if (!(session.recorder.state.noteId == noteId &&
            session.recorder.state.isActive &&
            session.draft.id == noteId)) {
          // 重启恢复的原音通知也可能指向未发布草稿。
          final List<NoteLocalDraftRecord> drafts = await session
              .listLocalDrafts();
          // 该笔记或原音对应的本机持久事实。
          final NoteLocalDraftRecord? local = drafts
              .where((draft) => draft.noteId == noteId)
              .firstOrNull;
          if (local != null) {
            await session.openLocalDraft(local.id);
          } else {
            await session.open(noteId);
          }
        }
      } else if (!session.recorder.state.isActive) {
        await session.openComposer();
      } else if (session.recorder.state.draftId != session.draftId &&
          session.recorder.state.draftId != null) {
        await session.openLocalDraft(session.recorder.state.draftId!);
      }
      if (!mounted) return;
      if (!identical(_editor, session)) throw StateError('数据源已切换，请重新打开笔记');
      if ((noteId != null && session.draft.id != noteId) ||
          (draftId != null && session.draftId != draftId)) {
        showOmniMessage(context, message: session.error ?? '当前草稿尚未暂存，请先重试');
        return;
      }
      if (_editorOpen) return;
      ownsSheet = true;
      setState(() => _editorOpen = true);
      // 历史恢复只替换本篇草稿，点击顶栏或正常退出时正式保存。
      if (version != null) {
        if (version.noteId != session.draft.id || session.frozen) {
          throw StateError('版本所属笔记已不可编辑');
        }
        await session.useVersion(version.body);
        if (session.dirty) await session.flush();
        if (session.dirty) throw StateError(session.error ?? '恢复版本暂存失败');
      }
      if (!mounted) return;
      if (!identical(_editor, session)) throw StateError('数据源已切换，请重新打开笔记');
      // 正式历史及其修改草稿走全屏，未发布新稿保持紧凑呈现。
      final bool history = session.draft.baseRevision.isNotEmpty && !record;
      // 两种表面共用原有编辑会话与提交事务。
      Widget editorPage(BuildContext context) => _AndroidNoteEditor(
        onReturnRecording: (recording) => returnRecording = recording,
        mode: history
            ? _AndroidNoteEditorMode.fullscreen
            : _AndroidNoteEditorMode.compact,
        startRecording: record,
        pickImages: images,
        quickVoice: quickVoice,
        autofocus: autofocus,
      );
      // 根路由覆盖底栏但保留原列表状态。
      final Future<void> sheet = Navigator.of(context, rootNavigator: true)
          .push<void>(
            history
                ? _AndroidHistoryRoute(
                    builder: editorPage,
                    reducedMotion: OmniMotion.reduce(context),
                  )
                : _AndroidComposerRoute(
                    reducedMotion: OmniMotion.reduce(context),
                    builder: editorPage,
                  ),
          );
      _opening = false;
      await sheet;
      if (previousDraft != null) {
        // 不将此前未发布内容替换成刚刚结束的语音草稿。
        final NoteLocalDraftRecord? previous = await session.localDrafts.find(
          previousDraft,
        );
        if (identical(_editor, session) &&
            previous != null &&
            !previous.discarded) {
          await session.openLocalDraft(previous.id);
        }
      }
    } on Object catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '$error',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      _opening = false;
      if (mounted && ownsSheet) setState(() => _editorOpen = false);
    }
    if (mounted &&
        identical(_editor, session) &&
        returnRecording != null &&
        session.recorder.state.isActive &&
        session.recorder.state.recordingId == returnRecording!.recordingId) {
      await _openEditor(
        draftId: returnRecording!.draftId,
        noteId: returnRecording!.draftId == null
            ? returnRecording!.noteId
            : null,
        autofocus: false,
      );
    }
  }

  /// 根导航全屏搜索独立维护条件，不污染主列表。
  Future<void> _openSearch() =>
      Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _AndroidNoteSearch(
            onEdit: (id, {version}) =>
                _openEditor(noteId: id, version: version),
          ),
        ),
      );

  /// 加号在原按钮上方打开紧凑拍照与相册菜单，背景保持清晰。
  Future<void> _add(BuildContext anchorContext) async {
    // 使用按钮实际位置，菜单不覆盖输入栏。
    final RenderBox anchor = anchorContext.findRenderObject()! as RenderBox;
    // 菜单属于同一个根覆盖层。
    final RenderBox overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay!.context.findRenderObject()!
            as RenderBox;
    // 两行48dp菜单向上留出8dp间隔。
    final Offset point = anchor.localToGlobal(
      const Offset(0, -(OmniSize.touch * 2 + OmniSpacing.md)),
      ancestor: overlay,
    );
    // 取消菜单不创建草稿或调用系统相机。
    final String? action = await showOmniMenu<String>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromRect(
        point & Size.zero,
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 216, maxWidth: 260),
      items: [
        OmniPopupMenuItem<String>(
          value: 'camera',
          label: '拍照',
          icon: Icons.photo_camera_outlined,
        ),
        OmniPopupMenuItem<String>(
          value: 'gallery',
          label: '选择图片',
          icon: Icons.add_photo_alternate_outlined,
        ),
      ],
    );
    if (!mounted || action == null || _opening || _editorOpen) return;
    if (_editor.recorder.state.isActive) {
      await _openEditor(record: true);
      return;
    }
    _opening = true;
    // 外部界面之前固定原草稿，成功后再打开面板。
    String? owner;
    // 图片取消不遗留打开的空面板。
    bool imported = false;
    try {
      await _editor.openComposer();
      owner = _editor.draftId;
      imported = await ref
          .read(noteImageAcquisitionProvider)
          .acquire(camera: action == 'camera');
    } on Object catch (error) {
      if (mounted) {
        showOmniMessage(
          context,
          message: '$error',
          tone: OmniMessageTone.error,
        );
      }
    } finally {
      _opening = false;
    }
    if (mounted && imported && owner != null) {
      await _openEditor(draftId: owner, autofocus: false);
    }
  }

  /// 构建正式列表、独立回收站和常驻输入入口。
  @override
  Widget build(BuildContext context) {
    // 监听替换后的采集器，不把旧数据源通知发给新资料库。
    final NoteEditorController editor = ref.watch(noteEditorProvider);
    if (!identical(_recorder, editor.recorder)) {
      _recorder = editor.recorder;
      unawaited(_returns?.cancel());
      _returns = editor.recorder.returnRequests.listen((id) {
        if (_router != null &&
            (_router!.routeInformationProvider.value.uri.path != '/notes' ||
                widget.initialNoteId != id)) {
          _router!.go('/notes?id=$id');
        } else {
          unawaited(_openEditor(noteId: id));
        }
      });
    }
    // 数据加载与错误分别展示，统计不使用筛选后的集合。
    final AsyncValue<List<NoteEntryRecord>> notes = ref.watch(notesProvider);
    // 只有成功加载的标签事实才能清除失效筛选。
    final AsyncValue<List<TaxonomyEntry>> taxonomy = ref.watch(
      noteTaxonomiesProvider,
    );
    // 当前可用的有效标签集合。
    final List<TaxonomyEntry> tags = (taxonomy.value ?? [])
        .where((tag) => tag.kind == 'tag' && tag.deletedAt == null)
        .toList();
    if (taxonomy.hasValue &&
        !taxonomy.hasError &&
        !taxonomy.isLoading &&
        _filter.tagIds.any((id) => !tags.any((tag) => tag.id == id))) {
      // 固定筛选身份，帧尾不能覆盖用户刚选择的另一行。
      final NoteSearchFilter previous = _filter;
      // 固定本轮资料库，旧订阅不能清除新资料库条件。
      final AppDatabase source = ref.read(appDatabaseProvider);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !identical(_filter, previous) ||
            !identical(ref.read(appDatabaseProvider), source)) {
          return;
        }
        _update(() {
          _filter = previous.copyWith(
            tagIds: previous.tagIds.intersection(
              tags.map((tag) => tag.id).toSet(),
            ),
          );
          _sidebarOrigin = 'all';
        });
      });
    }
    // 当前采集器的实际状态快照。
    final NoteRecordingState recording =
        ref.watch(noteRecordingProvider).value ?? editor.recorder.state;
    // 当前视图或卡片使用的可见标题。
    final String title = _recycle
        ? '笔记回收站'
        : _day ??
              tags
                  .where((tag) => _filter.tagIds.contains(tag.id))
                  .map((tag) => tag.name)
                  .firstOrNull ??
              '全部笔记';
    // 当前主题的语义颜色。
    final OmniColors colors = OmniColors.of(context);
    return ColoredBox(
      color: colors.canvas,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OmniSpacing.sm,
              vertical: OmniSpacing.xs,
            ),
            child: Row(
              children: [
                OmniIconButton(
                  key: const ValueKey('android-notes-menu'),
                  tooltip: '打开笔记侧栏',
                  icon: const Icon(Icons.menu),
                  onPressed: _showSidebar,
                ),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                OmniIconButton(
                  key: const ValueKey('android-notes-search'),
                  tooltip: '搜索笔记',
                  icon: const Icon(Icons.search),
                  onPressed: _openSearch,
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _recycle
                      ? const SingleChildScrollView(
                          padding: EdgeInsets.all(OmniSpacing.md),
                          child: RecycleBinSection(
                            scope: RecycleBinScope.notes,
                          ),
                        )
                      : _AndroidNoteList(
                          notes: notes,
                          filter: _filter,
                          selectedDay: _day,
                          controller: _scroll,
                          expandedId: _expanded,
                          bottomPadding: 100,
                          onExpand: (id) => setState(
                            () => _expanded = _expanded == id ? null : id,
                          ),
                          onEdit: (id, {version}) =>
                              _openEditor(noteId: id, version: version),
                        ),
                ),
                if (!_recycle)
                  Positioned(
                    left: OmniSpacing.lg,
                    right: OmniSpacing.lg,
                    bottom: OmniSpacing.md,
                    child: SizedBox(
                      height: math.max(
                        48,
                        MediaQuery.textScalerOf(context).scale(24) + 23.6,
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            top: .2,
                            bottom: .2,
                            child: Material(
                              key: const ValueKey('android-note-input-surface'),
                              color: colors.paper,
                              elevation: 2,
                              borderRadius: BorderRadius.circular(
                                OmniRadius.pill,
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Builder(
                                builder: (anchorContext) => OmniIconButton(
                                  tooltip: '添加图片或录音',
                                  icon: const Icon(Icons.add),
                                  onPressed: () => _add(anchorContext),
                                ),
                              ),
                              Expanded(
                                child: OmniInkWell(
                                  key: const ValueKey(
                                    'android-note-input-touch',
                                  ),
                                  onTap: () =>
                                      _openEditor(record: recording.isActive),
                                  onLongPress: () => _openEditor(record: true),
                                  child: SizedBox(
                                    height: math.max(
                                      48,
                                      MediaQuery.textScalerOf(context)
                                              .scale(24) +
                                          23.6,
                                    ),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        recording.isActive
                                            ? '录音中 ${_audioDuration(recording.duration)} · 点击返回'
                                            : '点击输入或长按语音',
                                        key: const ValueKey(
                                          'android-note-input',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyLarge
                                            ?.copyWith(color: colors.muted),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              OmniIconButton(
                                key: const ValueKey('android-note-microphone'),
                                tooltip: recording.isActive ? '返回录音' : '开始录音',
                                icon: const Icon(Icons.mic_none),
                                onPressed:
                                    editor.recordingStarting ||
                                        editor.committing
                                    ? null
                                    : () => _openEditor(record: true),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 原音时长统一使用分秒，不把墙钟等待算入采样时长。
String _audioDuration(Duration duration) =>
    '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
