import 'note_record_time_picker.dart';
import 'note_polish_actions.dart';
import '../data/note_repository.dart';

import 'dart:async';
import 'dart:io';

import 'android_notes_view.dart';
import 'note_pin_indicator.dart';
import 'windows_note_tags.dart';
import '../data/note_search_filter.dart';

import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/note_composer_style.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/audio/note_audio_player_service.dart';
import 'package:omni_butler/features/notes/data/note_editor_controller.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/notes/data/note_image_repository.dart';
import 'package:omni_butler/features/notes/markdown/note_markdown.dart';
import 'package:omni_butler/features/notes/presentation/note_rich_editor.dart';
import 'package:omni_butler/features/notes/presentation/note_markdown_text.dart';
import 'package:omni_butler/features/notes/presentation/note_audio_card.dart';
import 'package:omni_butler/features/notes/presentation/note_search_focus.dart';
import 'package:omni_butler/features/notes/presentation/note_statistic_button.dart';
import 'package:omni_butler/features/notes/presentation/windows_note_statistics_dialog.dart';
import 'package:omni_butler/features/notes/presentation/windows_note_search_bar.dart';
import 'package:omni_butler/features/notes/presentation/windows_note_search_filter.dart';
import 'package:omni_butler/features/settings/data/recycle_bin_repository.dart';
import 'package:omni_butler/features/settings/presentation/recycle_bin_section.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/shared/ui/omni_note_composer_button.dart';
import 'package:omni_butler/shared/ui/omni_note_audio_controls.dart';
import 'package:omni_butler/shared/ui/omni_taxonomy_chip.dart';
import 'package:omni_butler/shared/ui/omni_windows_semantics_boundary.dart';
import 'package:uuid/uuid.dart';

part 'windows_notes_view.dart';

part 'windows_note_tag_picker.dart';
part 'windows_note_body.dart';
part 'windows_note_tools.dart';

/// 含已删除名称的笔记分类流，历史名称不能丢失。
final _noteTaxonomiesProvider = noteTaxonomiesProvider;

/// 全部原始转写用于历史组合检索。
final _allNoteAudioProvider = allNoteAudioProvider;

/// 平台入口保持既有路由和外部笔记定位参数。
class NotesPage extends StatelessWidget {
  /// 搜索或通知指定已有笔记。
  final String? initialNoteId;

  /// 创建平台对应的笔记工作区。
  const NotesPage({this.initialNoteId, super.key});

  /// Android 使用独立布局，其他平台沿用原有工作区。
  @override
  Widget build(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.android
      ? AndroidNotesView(initialNoteId: initialNoteId)
      : _NotesWorkspace(initialNoteId: initialNoteId);
}

/// 原工作区保留 Windows 呈现和其他平台兼容路径。
class _NotesWorkspace extends ConsumerStatefulWidget {
  /// 外部笔记定位请求。
  final String? initialNoteId;

  /// 创建既有工作区。
  const _NotesWorkspace({this.initialNoteId});

  /// 创建原工作区状态。
  @override
  ConsumerState<_NotesWorkspace> createState() => _NotesPageState();
}

/// 历史与编辑区域共用的呈现状态。
class _NotesPageState extends ConsumerState<_NotesWorkspace>
    with WidgetsBindingObserver {
  /// 正文输入与中文输入法状态。
  final TextEditingController _body = TextEditingController();

  /// Windows 可视文档的选区与撤销记录独立于持久 Markdown。
  final NoteRichEditorController _richBody = NoteRichEditorController();

  /// 字体弹层始终锚定当前格式按钮。
  final GlobalKey _formatAnchor = GlobalKey();

  /// 弹层打开期间保持 Aa 的选中反馈。
  bool _formatMenuOpen = false;

  /// 阻止同时打开多个系统图片选择窗口。
  bool _pickingImages = false;

  /// 历史搜索输入。
  final TextEditingController _search = TextEditingController();

  /// 正文焦点，用于失焦落盘。
  final FocusNode _focus = FocusNode();

  /// 正文和底部工具共同决定输入卡片的聚焦外观。
  bool _composerFocused = false;

  /// 可选的已挂载路由器。
  GoRouter? _router;

  /// 路由预载与实际进入分离。
  bool _visible = false;

  /// 已经消费的外部记录定位请求，普通返回入口不复用旧搜索参数。
  String? _openedRequestId;

  /// 插入候选的在途身份，防止重复点击。
  final Set<String> _inserting = {};

  /// 手机历史页面状态。
  bool _history = false;

  /// 时间筛选键。
  String _range = 'all';

  /// 用户自定义起止自然日。
  DateTimeRange? _customRange;

  /// 桌面搜索的独立键盘焦点。
  FocusNode get _searchFocus => ref.read(noteSearchFocusProvider);

  /// 桌面正文与卡片共用滚动位置。
  final ScrollController _notesScroll = ScrollController();

  /// 桌面抽屉宿主用于选择过滤项后关闭导航。
  final GlobalKey<ScaffoldState> _notesScaffold = GlobalKey<ScaffoldState>();

  /// 笔记侧栏的会话内宽度，拖动时限制在 220–340dp。
  double _noteSidebarWidth = 264;

  /// 宽窗笔记侧栏是否完全收起。
  bool _noteSidebarHidden = false;

  /// 鼠标位于整个笔记侧栏时显示收起入口。
  bool _noteSidebarHovered = false;

  /// 鼠标按住分隔条时立即绘制主题色指示线。
  bool _noteSidebarResizing = false;

  /// 分隔条悬停时显示灰色提示。
  bool _noteSidebarDividerHovered = false;

  /// 桌面标签选择器按需展开。
  bool _showTagEditor = false;

  /// 展开的唯一历史笔记。
  String? _expandedNoteId;

  /// 阅读正文只展开一篇，独立于真实编辑器与录音原文展开。
  String? _expandedBodyNoteId;

  /// 当前热力图选择的自然日。
  String? _selectedDay;

  /// 阻止连续点击统计入口叠加弹窗。
  bool _statisticsOpen = false;

  /// 笔记内独立回收站视图。
  bool _recycle = false;

  /// 卡片定位锚点，外部搜索定位使用。
  final Map<String, GlobalKey> _noteKeys = {};

  /// 保存或取消正在执行，阻止重复点击。
  bool _committing = false;

  /// 当前是否使用 Windows 的显式提交布局。
  bool get _windows => Theme.of(context).platform == TargetPlatform.windows;

  /// 供桌面呈现扩展更新页面交互状态。
  void _updateWindows(VoidCallback change) {
    if (mounted) setState(change);
  }

  /// 多标签交集筛选。
  final Set<String> _tagFilter = {};

  /// 无有效标签集合。
  bool _untagged = false;

  /// 桌面标签筛选可切换为排除所选标签。
  bool _excludeSearchTags = false;

  /// 桌面内容类型按交集筛选，不改变正文或附件数据。
  final Set<String> _searchContents = {};

  /// 防止数据流在build中同步通知。
  bool _acceptingRemote = false;

  /// 上次已观察的持久记录，防止重复帧通知。
  NoteEntryRecord? _lastObserved;

  /// 当前事实对应的笔记身份。
  String? _observedId;

  /// 编辑器通知器。
  NoteEditorController? _editor;

  /// 通知返回原笔记订阅。
  StreamSubscription<String>? _returns;

  /// 当前切换错误提示。
  String? _actionError;

  /// 页面监听不启动麦克风、不持久化空白记录。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _richBody.addListener(_richSelectionChanged);
    _focus.addListener(() {
      if (!_focus.hasFocus) unawaited(_editor?.flush());
    });
  }

  /// 选区变化只刷新工具状态，不把光标移动当正文编辑。
  void _richSelectionChanged() {
    if (mounted) setState(() {});
  }

  /// 等实际路由可读取后监听进入事件。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 状态长期保留在应用容器中。
    final NoteEditorController editor = ref.read(noteEditorProvider);
    if (!identical(editor, _editor)) {
      _editor?.removeListener(_syncText);
      _editor = editor;
      editor.addListener(_syncText);
      _syncText();
      _returns?.cancel();
      _returns = editor.recorder.returnRequests.listen(
        (id) => _router?.go('/notes?id=$id'),
      );
    }
    // 预载页面没有实际进入，因此只监听路由变化。
    final GoRouter? router = GoRouter.maybeOf(context);
    if (!identical(_router, router)) {
      _router?.routeInformationProvider.removeListener(_routeChanged);
      _router = router;
      router?.routeInformationProvider.addListener(_routeChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _routeChanged();
    });
  }

  /// 搜索改变指定记录时直接打开原记录。
  @override
  void didUpdateWidget(_NotesWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialNoteId != oldWidget.initialNoteId &&
        widget.initialNoteId != null) {
      _openedRequestId = widget.initialNoteId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_open(widget.initialNoteId!, reveal: true));
      });
    }
  }

  /// 主动切进分支才提供新的空白记录，恢复前台不触发。
  void _routeChanged() {
    // 未在真实路由中挂载的测试可直接使用编辑器。
    final bool active =
        _router?.routeInformationProvider.value.uri.path == '/notes';
    if (active && !_visible) {
      _visible = true;
      if (widget.initialNoteId != null &&
          _openedRequestId != widget.initialNoteId) {
        _openedRequestId = widget.initialNoteId;
        unawaited(_open(widget.initialNoteId!, reveal: true));
      } else {
        unawaited(
          _perform(() async {
            if (_windows) {
              await _editor?.openComposer();
              _expandedNoteId = null;
            } else {
              await _editor?.enter();
            }
            if (mounted) setState(() => _history = false);
          }),
        );
      }
    } else if (!active && _visible) {
      _visible = false;
      unawaited(_editor?.flush());
    }
  }

  /// 外部转写或版本选择同步到输入框，不移动正在组词的光标。
  void _syncText() {
    // 当前人工或明确选择的正文。
    final String text = _editor?.draft.body ?? '';
    _richBody.syncMarkdown(text, identity: _editor?.draft.id);
    if (_body.text != text) {
      _body.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    if (mounted) setState(() {});
  }

  /// 切应用与锁屏刷新文字，但保留正在采集的录音。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_editor?.flush());
    }
  }

  /// 清理页面订阅；应用级录音器继续存在。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router?.routeInformationProvider.removeListener(_routeChanged);
    _editor?.removeListener(_syncText);
    unawaited(_editor?.flush());
    _returns?.cancel();
    _body.dispose();
    _richBody.removeListener(_richSelectionChanged);
    _richBody.dispose();
    _search.dispose();
    _focus.dispose();
    _notesScroll.dispose();
    super.dispose();
  }

  /// 统一操作错误保留，不影响自动保存的正文。
  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _actionError = null);
    } catch (failure) {
      if (mounted) setState(() => _actionError = '$failure');
    }
  }

  /// 打开历史先排空当前编辑。
  Future<void> _open(String id, {bool reveal = false}) => _perform(() async {
    if (_committing ||
        _editor?.committing == true ||
        _editor?.recordingStarting == true) {
      return;
    }
    await _editor?.open(id);
    if (mounted && _editor?.draft.id == id) {
      setState(() {
        _history = false;
        _recycle = false;
        if (_windows) {
          _expandedNoteId = id;
          _expandedBodyNoteId = null;
          if (reveal) {
            _search.clear();
            _tagFilter.clear();
            _selectedDay = null;
            _range = 'all';
            _customRange = null;
            _untagged = false;
            _excludeSearchTags = false;
            _searchContents.clear();
          }
        }
      });
      if (_windows && reveal) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // 主列表采用完整锚点，旧记录也能直接定位。
          final BuildContext? target = _noteKeys[id]?.currentContext;
          if (target != null) {
            unawaited(
              Scrollable.ensureVisible(
                target,
                duration: OmniMotion.duration(context, OmniMotion.panel),
                alignment: 0.1,
              ),
            );
          }
        });
      }
    }
  });

  /// 可组合的日期、标签、内容与关键词筛选。
  bool _matches(
    NoteEntryRecord note,
    List<TaxonomyEntry> taxonomies,
    List<NoteAudioSegmentRecord> audio, {
    Set<String> imageNoteIds = const {},
  }) {
    return matchesNoteSearch(
      note,
      filter: NoteSearchFilter(
        range: _range,
        customRange: _customRange,
        tagMode: _untagged
            ? 'none'
            : _excludeSearchTags
            ? 'exclude'
            : 'include',
        tagIds: _tagFilter,
        contents: _searchContents,
      ),
      taxonomies: taxonomies,
      audio: audio,
      imageNoteIds: imageNoteIds,
      query: _search.text,
      selectedDay: _selectedDay,
    );
  }

  /// 构建与现有导航共存的两端布局。
  @override
  Widget build(BuildContext context) {
    // 当前数据源编辑器，替换数据源时重新订阅。
    final NoteEditorController editor = ref.watch(noteEditorProvider);
    if (!identical(_editor, editor)) {
      _editor?.removeListener(_syncText);
      _editor = editor;
      editor.addListener(_syncText);
    }
    // 分类含历史墓碑名称，加载完成前不清除用户筛选。
    final AsyncValue<List<TaxonomyEntry>> taxonomyState = ref.watch(
      _noteTaxonomiesProvider,
    );
    // 有效标签和墓碑共用同一数据源，远端删除也能移除失效筛选。
    final List<TaxonomyEntry> taxonomy = taxonomyState.value ?? [];
    if (_windows && taxonomyState.hasValue) {
      _tagFilter.retainAll(
        taxonomy
            .where((tag) => tag.kind == 'tag' && tag.deletedAt == null)
            .map((tag) => tag.id),
      );
    }
    // 历史有效笔记。
    final AsyncValue<List<NoteEntryRecord>> notes = ref.watch(notesProvider);
    // 本机传输与转写状态。
    final List<NoteAudioLocalFileRecord> local =
        ref.watch(noteLocalAudioProvider).value ?? [];
    // 本篇原音按稳定顺序展示。
    final List<NoteAudioSegmentRecord> segments =
        ref.watch(noteAudioProvider(editor.draft.id)).value ?? [];
    // 录音快照与限额提示。
    final NoteRecordingState recording =
        ref.watch(noteRecordingProvider).value ?? editor.recorder.state;
    // 清洁编辑器接收已落盘远端变化。
    final AsyncValue<NoteEntryRecord?> record = ref.watch(
      noteByIdProvider(editor.draft.id),
    );
    final NoteEntryRecord? current = record.value;
    if (!_acceptingRemote &&
        record.hasValue &&
        (_observedId != editor.draft.id || _lastObserved != current) &&
        (_windows || !editor.dirty)) {
      _observedId = editor.draft.id;
      _lastObserved = current;
      _acceptingRemote = true;
      // 延迟回填必须仍对应同一编辑器和笔记，空值也不能跨篇冻结。
      final String observingId = editor.draft.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _acceptingRemote = false;
        if (mounted &&
            identical(_editor, editor) &&
            editor.draft.id == observingId) {
          editor.acceptRemote(current);
        }
      });
    }
    if (_windows) {
      return _windowsView(editor, taxonomy, notes, segments, local, recording);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 历史与正文在大窗口并排，小窗口切页。
        final bool wide = constraints.maxWidth >= 900;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text('笔记', style: Theme.of(context).textTheme.headlineSmall),
                  const Spacer(),
                  if (!wide)
                    OmniIconButton(
                      tooltip: _history ? '返回记录' : '查看历史',
                      icon: Icon(_history ? Icons.edit_note : Icons.history),
                      onPressed: () => _perform(() async {
                        await editor.flush();
                        if (!editor.dirty && mounted) {
                          setState(() {
                            _history = !_history;
                            _recycle = false;
                          });
                        }
                      }),
                    ),
                  OmniButton(
                    label: '新建',
                    visualHeight: OmniSize.control,
                    icon: Icons.add,
                    onPressed: () => _perform(() async {
                      await editor.newNote();
                      if (mounted && !editor.dirty) {
                        setState(() => _history = false);
                      }
                    }),
                  ),
                ],
              ),
            ),
            if (_actionError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _actionError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 320,
                          child: _recycle
                              ? _noteRecycleView()
                              : _historyPanel(notes, taxonomy),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: _editorPanel(
                            editor,
                            taxonomy,
                            segments,
                            local,
                            recording,
                          ),
                        ),
                      ],
                    )
                  : _history
                  ? _recycle
                        ? _noteRecycleView()
                        : _historyPanel(notes, taxonomy)
                  : _editorPanel(editor, taxonomy, segments, local, recording),
            ),
          ],
        );
      },
    );
  }

  /// 可搜索、按日分组的历史列表。
  Widget _historyPanel(
    AsyncValue<List<NoteEntryRecord>> notes,
    List<TaxonomyEntry> taxonomy,
  ) {
    // 原始转写可检索但不替换人工正文。
    final List<NoteAudioSegmentRecord> audio =
        ref.watch(_allNoteAudioProvider).value ?? [];
    // 本次组合查询结果。
    final List<NoteEntryRecord> filtered = (notes.value ?? [])
        .where((note) => _matches(note, taxonomy, audio))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OmniTextField(
            controller: _search,
            decoration: const InputDecoration(
              hintText: '搜索笔记、标签或转写',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OmniDropdownButton<String>(
                value: _range,
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('全部时间')),
                  DropdownMenuItem(value: 'today', child: Text('今天')),
                  DropdownMenuItem(value: 'week', child: Text('本周')),
                  DropdownMenuItem(value: 'month', child: Text('本月')),
                  DropdownMenuItem(value: 'custom', child: Text('自定义日期')),
                ],
                onChanged: (value) async {
                  if (value == 'custom') {
                    // 起止日期由用户明确选择。
                    final DateTimeRange? range = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                      initialDateRange: _customRange,
                    );
                    if (range == null || !mounted) return;
                    _customRange = range;
                  }
                  if (mounted) setState(() => _range = value ?? 'all');
                },
              ),
              OmniFilterChip(
                label: const Text('未打标签'),
                selected: _untagged,
                onSelected: (value) => setState(() {
                  _untagged = value;
                  if (value) _tagFilter.clear();
                }),
              ),
              ...taxonomy
                  .where((item) => item.kind == 'tag' && item.deletedAt == null)
                  .map(
                    (item) => OmniFilterChip(
                      label: Text(item.name),
                      selected: _tagFilter.contains(item.id),
                      onSelected: (selected) => setState(() {
                        _untagged = false;
                        if (selected) {
                          _tagFilter.add(item.id);
                        } else {
                          _tagFilter.remove(item.id);
                        }
                      }),
                    ),
                  ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: OmniButton(
            label: '笔记回收站',
            icon: Icons.delete_outline,
            variant: OmniButtonVariant.text,
            onPressed: () => setState(() => _recycle = true),
          ),
        ),
        if (notes.isLoading) const LinearProgressIndicator(),
        if (notes.hasError) Text('加载失败：${notes.error}'),
        if (!notes.isLoading && filtered.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('没有符合条件的笔记'),
                  OmniButton(
                    label: '清除筛选',
                    variant: OmniButtonVariant.text,
                    visualHeight: OmniSize.control,
                    onPressed: () => setState(() {
                      _search.clear();
                      _range = 'all';
                      _tagFilter.clear();
                      _untagged = false;
                    }),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                // 当前按日排序的笔记。
                final NoteEntryRecord note = filtered[index];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (index == 0 || filtered[index - 1].dayKey != note.dayKey)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(
                          note.dayKey,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                    Material(
                      type: MaterialType.transparency,
                      child: OmniListTile(
                        selected: note.id == _editor?.draft.id,
                        title: Text(
                          note.body.trim().isEmpty
                              ? audio.any((item) => item.noteId == note.id)
                                    ? '语音笔记'
                                    : '内容已清空'
                              : note.body.trim().split('\n').first,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${note.createdAt.toLocal().hour.toString().padLeft(2, '0')}:${note.createdAt.toLocal().minute.toString().padLeft(2, '0')}',
                        ),
                        onTap: () => unawaited(_open(note.id)),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  /// 无强制标题、保存按钮或分类前置的记录表面。
  Widget _editorPanel(
    NoteEditorController editor,
    List<TaxonomyEntry> taxonomy,
    List<NoteAudioSegmentRecord> segments,
    List<NoteAudioLocalFileRecord> local,
    NoteRecordingState recording, {
    bool inline = false,
  }) {
    // 历史编辑按实际内容撑高，顶部新建输入保留既有留白。
    final bool historyEditing = inline && _expandedNoteId == editor.draft.id;
    // Windows 只操作当前草稿的录音，避免浏览其他笔记时结束或取消错篇。
    final bool ownsRecording =
        recording.noteId == editor.draft.id &&
        recording.draftId == editor.draftId;
    // 启停和提交期间禁止重复点击，暂停/继续保持同一采集身份。
    final bool recordingBlocked =
        _committing ||
        editor.committing ||
        editor.recordingStarting ||
        (recording.isActive &&
            recording.phase != NoteRecordingPhase.recording &&
            recording.phase != NoteRecordingPhase.paused) ||
        (_windows && recording.isActive && !ownsRecording);
    // 桌面内嵌编辑器由外层列表负责滚动。
    final Widget content = Padding(
      padding: inline
          ? const EdgeInsets.fromLTRB(
              OmniSpacing.xl,
              OmniSpacing.xl,
              OmniSpacing.md,
              OmniSpacing.sm,
            )
          : const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!inline)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OmniDatePickerButton(
                  value: DateTime.parse(editor.draft.dayKey),
                  initialDate: DateTime.parse(editor.draft.dayKey),
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(),
                  label: editor.draft.dayKey,
                  icon: Icons.calendar_today,
                  onChanged: (day) => editor.edit(dayKey: businessDayKey(day)),
                ),
                Text(
                  editor.saveStatus,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (editor.dirty || editor.error != null)
                  OmniButton(
                    label: '重试保存',
                    variant: OmniButtonVariant.text,
                    visualHeight: OmniSize.control,
                    onPressed: () => _perform(editor.flush),
                  ),
                if (editor.error != null || editor.conflicted)
                  OmniButton(
                    label: '另存为新笔记',
                    variant: OmniButtonVariant.text,
                    visualHeight: OmniSize.control,
                    onPressed: () => _perform(editor.saveAsNew),
                  ),
                OmniIconButton(
                  tooltip: '复制正文',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _body.text)),
                  icon: const Icon(Icons.copy_outlined),
                ),
                OmniIconButton(
                  tooltip: '版本记录',
                  onPressed: () => _showVersions(editor),
                  icon: const Icon(Icons.restore),
                ),
                OmniIconButton(
                  tooltip: '删除笔记',
                  onPressed: () => _deleteNote(editor),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          if (editor.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                editor.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (editor.pendingRecoveryCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '检测到 ${editor.pendingRecoveryCount} 段未确认保存的原音，请点击“恢复上次录音”检查。',
              ),
            ),
          if (inline)
            NoteRichEditor(
              key: const ValueKey('note-rich-editor'),
              controller: _richBody,
              focusNode: _focus,
              enabled: !_committing && !editor.committing,
              readOnly: editor.frozen || editor.conflicted,
              minHeight: historyEditing ? 0 : NoteComposerStyle.bodyHeight,
              placeholder: '现在的想法是...',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                height: 1.5,
                color: Theme.of(context).brightness == Brightness.light
                    ? NoteComposerStyle.ink
                    : OmniColors.of(context).ink,
              ),
              onChanged: (value) => editor.edit(body: value),
            )
          else
            OmniTextField(
              controller: _body,
              enabled: !_committing && !editor.committing,
              readOnly: editor.frozen || editor.conflicted,
              focusNode: _focus,
              minLines: inline ? (historyEditing ? 1 : 5) : 9,
              maxLines: null,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                height: inline ? 1.5 : 1.7,
                color:
                    inline && Theme.of(context).brightness == Brightness.light
                    ? NoteComposerStyle.ink
                    : null,
              ),
              decoration: InputDecoration(
                hintText: inline ? '现在的想法是...' : '记下此刻的想法…',
                hintStyle: inline
                    ? TextStyle(
                        color: Theme.of(context).brightness == Brightness.light
                            ? NoteComposerStyle.muted
                            : OmniColors.of(context).muted,
                      )
                    : null,
                filled: inline ? false : null,
                fillColor: inline ? Colors.transparent : null,
                hoverColor: inline ? Colors.transparent : null,
                contentPadding: inline ? EdgeInsets.zero : null,
                constraints: inline && !historyEditing
                    ? const BoxConstraints(
                        minHeight: NoteComposerStyle.bodyHeight,
                      )
                    : null,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: inline ? InputBorder.none : null,
              ),
              onChanged: (value) => editor.edit(body: value),
            ),
          if (!inline) const Divider(),
          if (!inline || recording.isActive)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!recording.isActive)
                  OmniButton(
                    label: '开始录音',
                    visualHeight: OmniSize.control,
                    icon: Icons.mic_none,
                    onPressed: editor.frozen || editor.committing
                        ? null
                        : () => _perform(editor.startRecording),
                  )
                else ...[
                  Text(
                    '${recording.phase == NoteRecordingPhase.paused ? '已暂停' : '正在录音'}  ${_duration(recording.duration)}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  OmniButton(
                    label: recording.phase == NoteRecordingPhase.paused
                        ? '继续'
                        : '暂停',
                    visualHeight: OmniSize.control,
                    variant: OmniButtonVariant.secondary,
                    onPressed: recordingBlocked
                        ? null
                        : () => _perform(
                            recording.phase == NoteRecordingPhase.paused
                                ? editor.recorder.resume
                                : editor.recorder.pause,
                          ),
                  ),
                  OmniButton(
                    label: '结束录音',
                    visualHeight: OmniSize.control,
                    onPressed: recordingBlocked
                        ? null
                        : _windows
                        ? () => _finishEdit(editor)
                        : () => _perform(() async {
                            await editor.recorder.stop();
                          }),
                  ),
                  if (_windows &&
                      ownsRecording &&
                      recording.phase == NoteRecordingPhase.paused)
                    OmniButton(
                      label: '取消录音',
                      visualHeight: OmniSize.control,
                      variant: OmniButtonVariant.secondary,
                      onPressed: recordingBlocked
                          ? null
                          : () => _cancelPausedRecording(editor),
                    ),
                  if (recording.noteId != editor.draft.id)
                    OmniButton(
                      label: '返回正在录音的笔记',
                      variant: OmniButtonVariant.text,
                      visualHeight: OmniSize.control,
                      onPressed: () => _open(recording.noteId!, reveal: true),
                    ),
                ],
                if (!inline)
                  OmniButton(
                    label: '恢复上次录音',
                    variant: OmniButtonVariant.text,
                    visualHeight: OmniSize.control,
                    onPressed: () => _perform(editor.recover),
                  ),
                if (_windows && (!inline || recording.isActive))
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('自动转文字'),
                      const SizedBox(width: OmniSpacing.xs),
                      Semantics(
                        label: '自动转文字',
                        child: OmniSwitch(
                          key: const ValueKey('note-auto-transcribe-switch'),
                          value: editor.voiceConsent,
                          onChanged: recordingBlocked
                              ? null
                              : (_) => _enableVoice(editor),
                        ),
                      ),
                    ],
                  )
                else if (!inline || recording.isActive)
                  OmniButton(
                    label: editor.voiceConsent ? '关闭自动转文字' : '开启自动转文字',
                    variant: OmniButtonVariant.text,
                    visualHeight: OmniSize.control,
                    onPressed: () => _enableVoice(editor),
                  ),
              ],
            ),
          if (recording.approachingLimit)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('剩余不到 30 秒，将自动结束并保存原音'),
            ),
          if (recording.error != null)
            OmniButton(
              label: '${recording.error} · 打开系统权限设置',
              variant: OmniButtonVariant.text,
              visualHeight: OmniSize.control,
              onPressed: () => _perform(editor.recorder.openSettings),
            ),
          if (!inline || segments.isNotEmpty) const SizedBox(height: 16),
          ...segments
              .where((segment) => !inline || !editor.isAudioRemoved(segment.id))
              .map(
                (segment) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: NoteAudioCard(
                    key: ValueKey('note-editor-audio-${segment.id}'),
                    compact: inline,
                    editing: historyEditing,
                    editEnabled:
                        !editor.frozen &&
                        !editor.conflicted &&
                        !editor.committing &&
                        !_committing,
                    onDelete: historyEditing
                        ? () => _removeEditedAudio(editor, segment.id)
                        : null,
                    segment: segment,
                    local: local
                        .where((item) => item.id == segment.id)
                        .firstOrNull,
                    player: ref.read(noteAudioPlayerProvider),
                    recordingActive: recording.isActive,
                    onRecognize: () => _recognize(segment),
                    onCancel: () => _cancelRecognition(segment),
                    onRetryPolish: () =>
                        unawaited(retryNotePolish(context, ref, segment)),
                    onAdoptPolish: () =>
                        unawaited(adoptNotePolish(context, ref, segment)),
                    onInsert: (text) => _insertTranscript(segment, text),
                  ),
                ),
              ),
          if (!inline) const Divider(),
          if (inline)
            _NoteComposerTagPicker(
              editor: editor,
              tags: taxonomy
                  .where((item) => item.kind == 'tag' && item.deletedAt == null)
                  .toList(),
              expanded: _showTagEditor,
              blocked: _committing,
            )
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OmniButton(
                  label: '管理标签',
                  variant: OmniButtonVariant.text,
                  visualHeight: OmniSize.control,
                  onPressed: () => TaxonomyManagerDialog.show(
                    context,
                    module: TaxonomyModule.notes,
                    kind: TaxonomyKind.tag,
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: taxonomy
                  .where((item) => item.kind == 'tag' && item.deletedAt == null)
                  .map(
                    (item) => OmniFilterChip(
                      label: Text(item.name),
                      selected: editor.draft.tags.contains(item.id),
                      onSelected: editor.frozen || editor.committing
                          ? null
                          : (selected) {
                              // 标签选择保留身份，重命名不需改正文。
                              final Set<String> tags = {...editor.draft.tags};
                              if (selected) {
                                tags.add(item.id);
                              } else {
                                tags.remove(item.id);
                              }
                              editor.edit(tags: tags);
                            },
                    ),
                  )
                  .toList(),
            ),
          ],
          if (inline) ...[
            const SizedBox(height: OmniSpacing.sm),
            _draftAudio(editor),
            _editorImages(editor),
            _commitActions(editor, segments, recording),
          ],
        ],
      ),
    );
    return inline ? content : SingleChildScrollView(child: content);
  }

  /// 格式化有效采样时长。
  Future<void> _insertTranscript(NoteAudioSegmentRecord segment, String text) =>
      _perform(() async {
        if (_inserting.contains(segment.id)) return;
        // 候选归属不能越过用户切换的笔记。
        final NoteEditorController editor = ref.read(noteEditorProvider);
        if (editor.draft.id != segment.noteId ||
            editor.isAudioRemoved(segment.id) ||
            editor.frozen ||
            editor.conflicted ||
            editor.committing ||
            _committing) {
          return;
        }
        // 异步候选查询只能标记本次编辑代次。
        final String? draftId = editor.draftId;
        _inserting.add(segment.id);
        try {
          // 使用用户光标位置，正文替换只发生在明确选中的范围。
          if (_windows) {
            _richBody.insertText(text);
            editor.edit(body: _richBody.markdown);
          } else {
            // Android 保留原有纯文本编辑偏移。
            final TextSelection selection = _body.selection;
            final int start = selection.isValid
                ? selection.start.clamp(0, _body.text.length)
                : _body.text.length;
            // 有效选区只替换用户明确选择的范围。
            final int end = selection.isValid
                ? selection.end.clamp(start, _body.text.length)
                : start;
            editor.edit(body: _body.text.replaceRange(start, end, text));
          }
          if (_windows) {
            // 原始转写与再识别候选分别记录，发布前不消费正式候选。
            final NoteAudioLocalFileRecord? current =
                await (editor.repository.database.select(
                      editor.repository.database.noteAudioLocalFiles,
                    )..where((table) => table.id.equals(segment.id)))
                    .getSingleOrNull();
            if (editor.draftId != draftId ||
                editor.draft.id != segment.noteId ||
                editor.isAudioRemoved(segment.id)) {
              return;
            }
            editor.markTranscriptInsertion(
              segment.id,
              candidate: current?.candidateTranscript == text,
            );
            await editor.flush();
            return;
          }
          await editor.flush();
          if (editor.dirty || editor.draft.id != segment.noteId) return;
          await (editor.repository.database.update(
            editor.repository.database.noteAudioLocalFiles,
          )..where((table) => table.id.equals(segment.id))).write(
            NoteAudioLocalFilesCompanion(
              insertedRevision: Value(editor.draft.baseRevision),
              candidateTranscript: const Value(null),
            ),
          );
        } finally {
          _inserting.remove(segment.id);
        }
      });

  /// 格式化有效采样时长。
  String _duration(Duration duration) =>
      '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  /// 明确授权默认只覆盖新录音，Windows 开关同时覆盖当前所属片段。
  Future<void> _enableVoice(NoteEditorController editor) async {
    if (editor.voiceConsent) {
      editor.setVoiceConsent(false, includeCurrentRecording: _windows);
      return;
    }
    // 未连接时说明如何启用服务，录音仍可本地使用。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '开启语音转文字',
      message: _windows
          ? '当前及之后的新录音将通过你连接的服务器提交给其配置的语音识别服务，原音和转写仍分别保留。需在设置中连接并开启同步；历史录音需要逐段授权。'
          : '之后的新录音将通过你连接的服务器提交给其配置的语音识别服务，原音和转写仍分别保留。需在设置中连接并开启同步；历史录音需要逐段授权。',
      confirmLabel: '开启',
    );
    if (confirmed && mounted) {
      editor.setVoiceConsent(true, includeCurrentRecording: _windows);
    }
  }

  /// 单段明确授权或重新识别；复用未知提交身份，禁止重复付费。
  Future<void> _recognize(NoteAudioSegmentRecord segment) => _perform(() async {
    if (!ref.read(syncPreferenceProvider)) throw StateError('请先在设置中连接服务器并开启同步');
    // 用户决定将此原音送交供应商。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '将这段原音转为文字？',
      message: '原音会通过你的服务器提交给语音识别服务，结果作为可选文本，不覆盖人工正文。',
      confirmLabel: '转文字',
    );
    if (!confirmed || !mounted) return;
    // 本机任务记录可能尚未从第二设备下载建立。
    final AppDatabase database = ref.read(appDatabaseProvider);
    final NoteAudioLocalFileRecord? current = await (database.select(
      database.noteAudioLocalFiles,
    )..where((table) => table.id.equals(segment.id))).getSingleOrNull();
    // 未知提交必须继续查询旧身份，确定终态才允许新的尝试。
    final bool retry =
        current != null &&
        ['failed', 'cancelled', 'succeeded'].contains(current.recognitionState);
    await database
        .into(database.noteAudioLocalFiles)
        .insertOnConflictUpdate(
          NoteAudioLocalFilesCompanion(
            id: Value(segment.id),
            consent: const Value(true),
            recognitionId: retry || current?.recognitionId == null
                ? Value(const Uuid().v4())
                : const Value.absent(),
            recognitionState: const Value('queued'),
            lastError: const Value(null),
          ),
        );
    await ref.read(noteAudioTransferProvider)?.tick();
  });

  /// 撤回立即停止本机提交，离线时明确待服务端送达。
  Future<void> _cancelRecognition(NoteAudioSegmentRecord segment) =>
      _perform(() async {
        // 持久状态保证重启仍继续发送撤回请求。
        final AppDatabase database = ref.read(appDatabaseProvider);
        await (database.update(
          database.noteAudioLocalFiles,
        )..where((table) => table.id.equals(segment.id))).write(
          const NoteAudioLocalFilesCompanion(
            consent: Value(false),
            recognitionState: Value('cancelPending'),
          ),
        );
        await ref.read(noteAudioTransferProvider)?.tick();
      });

  /// 正文和原音绑定删除；正在录音先结束落盘。
  Future<void> _deleteNote(NoteEditorController editor) => _perform(() async {
    // 明确说明统一回收站与恢复范围。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '删除这篇笔记？',
      message: '正文、原音和转写一起进入笔记回收站，30 天内可恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed) return;
    // 只结束本篇正在采集的录音，浏览其他笔记不停止原采集。
    if (editor.recorder.state.noteId == editor.draft.id) {
      await editor.recorder.stop();
    }
    await editor.flush();
    await editor.repository.softDelete(editor.draft.id);
    if (_windows) {
      await editor.openComposer();
      if (mounted) setState(() => _expandedNoteId = null);
    } else {
      await editor.newNote();
    }
  });

  /// 原始版本与离线冲突保留用户选择。
  Future<void> _showVersions(NoteEditorController editor) async {
    // 先读取持久候选，不能用当前输入伪造历史。
    final List<NoteVersionRecord> versions =
        await (editor.repository.database.select(
                editor.repository.database.noteVersions,
              )
              ..where(
                (table) =>
                    table.noteId.equals(editor.draft.id) &
                    table.deletedAt.isNull(),
              )
              ..orderBy([(table) => OrderingTerm.desc(table.createdAt)]))
            .get();
    if (!mounted) return;
    await showOmniDialog<void>(
      context: context,
      builder: (context) => OmniDialogScaffold(
        title: '版本记录',
        width: 560,
        actions: [
          OmniButton(
            label: '关闭',
            variant: OmniButtonVariant.text,
            visualHeight: OmniSize.control,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        child: SizedBox(
          height: 400,
          child: versions.isEmpty
              ? const Center(child: Text('暂无已保存版本'))
              : ListView(
                  children: versions
                      .map(
                        (version) => OmniListTile(
                          title: _windows
                              ? NoteMarkdownText(
                                  source: version.body.isEmpty
                                      ? '内容已清空'
                                      : version.body,
                                  maxLines: 5,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : Text(
                                  version.body.isEmpty ? '内容已清空' : version.body,
                                  maxLines: 5,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          subtitle: Text('${version.createdAt.toLocal()}'),
                          trailing: OmniIconButton(
                            tooltip: '复制此版本',
                            icon: const Icon(Icons.copy),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: version.body),
                            ),
                          ),
                          onTap: () async {
                            Navigator.pop(context);
                            await _perform(
                              () => editor.useVersion(version.body),
                            );
                          },
                        ),
                      )
                      .toList(),
                ),
        ),
      ),
    );
  }
}
