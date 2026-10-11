import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:omni_butler/core/taxonomy/taxonomy_repository.dart';
import 'package:omni_butler/features/notes/audio/note_recorder_service.dart';
import 'package:omni_butler/features/notes/data/note_editor_controller.dart';
import 'package:omni_butler/features/notes/data/note_providers.dart';
import 'package:omni_butler/features/notes/data/note_repository.dart';
import 'package:omni_butler/features/notes/presentation/note_audio_card.dart';
import 'package:omni_butler/shared/taxonomy/taxonomy_manager_dialog.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:uuid/uuid.dart';

/// 含已删除名称的笔记分类流，历史名称不能丢失。
final _noteTaxonomiesProvider = StreamProvider<List<TaxonomyEntry>>((ref) {
  // 当前数据库与模块管理项。
  final AppDatabase database = ref.watch(appDatabaseProvider);
  return (database.select(database.taxonomyEntries)
        ..where((table) => table.module.equals('notes'))
        ..orderBy([(table) => OrderingTerm.asc(table.sortOrder)]))
      .watch();
});

/// 全部原始转写用于历史组合检索。
final _allNoteAudioProvider = StreamProvider<List<NoteAudioSegmentRecord>>((
  ref,
) {
  // 当前模块原音，无效记录不会进入有效笔记集合。
  final AppDatabase database = ref.watch(appDatabaseProvider);
  return database.select(database.noteAudioSegments).watch();
});

/// 低成本捕捉入口；路由预载只构造空编辑器，不产生业务记录。
class NotesPage extends ConsumerStatefulWidget {
  /// 搜索或通知指定已有笔记。
  final String? initialNoteId;

  /// 创建笔记页。
  const NotesPage({this.initialNoteId, super.key});

  /// 创建页面状态。
  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

/// 历史与编辑区域共用的呈现状态。
class _NotesPageState extends ConsumerState<NotesPage>
    with WidgetsBindingObserver {
  /// 正文输入与中文输入法状态。
  final TextEditingController _body = TextEditingController();

  /// 历史搜索输入。
  final TextEditingController _search = TextEditingController();

  /// 正文焦点，用于失焦落盘。
  final FocusNode _focus = FocusNode();

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

  /// 可选类别，none表示没有有效分类。
  String? _categoryFilter;

  /// 多标签交集筛选。
  final Set<String> _tagFilter = {};

  /// 无有效标签集合。
  bool _untagged = false;

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
    _focus.addListener(() {
      if (!_focus.hasFocus) unawaited(_editor?.flush());
    });
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
  void didUpdateWidget(NotesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialNoteId != oldWidget.initialNoteId &&
        widget.initialNoteId != null) {
      _openedRequestId = widget.initialNoteId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_open(widget.initialNoteId!));
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
        unawaited(_open(widget.initialNoteId!));
      } else {
        unawaited(
          _perform(() async {
            await _editor?.enter();
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
    _search.dispose();
    _focus.dispose();
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
  Future<void> _open(String id) => _perform(() async {
    await _editor?.open(id);
    if (mounted && _editor?.draft.id == id) setState(() => _history = false);
  });

  /// 可组合的日期、类别、标签与关键词筛选。
  bool _matches(
    NoteEntryRecord note,
    List<TaxonomyEntry> taxonomies,
    List<NoteAudioSegmentRecord> audio,
  ) {
    // 有效分类集合。
    final Set<String> categories = taxonomies
        .where((item) => item.kind == 'category' && item.deletedAt == null)
        .map((item) => item.id)
        .toSet();
    if (_categoryFilter == 'none' && categories.contains(note.categoryId)) {
      return false;
    }
    if (_categoryFilter != null &&
        _categoryFilter != 'none' &&
        note.categoryId != _categoryFilter) {
      return false;
    }
    // 有效多标签，不把被删除标签算入未打标签判断。
    final Set<String> tags = noteTagIds(note.tags).intersection(
      taxonomies
          .where((item) => item.kind == 'tag' && item.deletedAt == null)
          .map((item) => item.id)
          .toSet(),
    );
    if (_untagged && tags.isNotEmpty || !tags.containsAll(_tagFilter)) {
      return false;
    }
    // 当前本地自然日。
    final DateTime now = DateTime.now();
    // 自然日边界保持日期语义。
    final DateTime today = DateTime(now.year, now.month, now.day);
    // 筛选下限与上限。
    final DateTime? start = switch (_range) {
      'today' => today,
      'week' => today.subtract(Duration(days: today.weekday - 1)),
      'month' => DateTime(today.year, today.month),
      'custom' => _customRange?.start,
      _ => null,
    };
    final DateTime? end = _range == 'custom'
        ? _customRange?.end
        : start == null
        ? null
        : today;
    if (start != null && note.dayKey.compareTo(businessDayKey(start)) < 0 ||
        end != null && note.dayKey.compareTo(businessDayKey(end)) > 0) {
      return false;
    }
    // 类别与标签名字也可作为关键词。
    final String keyword = _search.text.trim().toLowerCase();
    if (keyword.isEmpty) return true;
    return [
      note.body,
      note.categoryName ?? '',
      ...taxonomies
          .where((item) => tags.contains(item.id))
          .map((item) => item.name),
      ...audio
          .where((item) => item.noteId == note.id)
          .map((item) => item.transcript ?? ''),
    ].any((value) => value.toLowerCase().contains(keyword));
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
    // 分类含历史墓碑名称。
    final List<TaxonomyEntry> taxonomy =
        ref.watch(_noteTaxonomiesProvider).value ?? [];
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
        !editor.dirty) {
      _observedId = editor.draft.id;
      _lastObserved = current;
      _acceptingRemote = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _acceptingRemote = false;
        if (mounted) editor.acceptRemote(current);
      });
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
                          setState(() => _history = !_history);
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
                          child: _historyPanel(notes, taxonomy),
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
                  ? _historyPanel(notes, taxonomy)
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
              hintText: '搜索笔记、类别或标签',
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
              OmniDropdownButton<String>(
                value:
                    _categoryFilter != null &&
                        _categoryFilter != 'none' &&
                        !taxonomy.any(
                          (item) =>
                              item.id == _categoryFilter &&
                              item.deletedAt == null,
                        )
                    ? null
                    : _categoryFilter,
                hint: const Text('全部类别'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('全部类别')),
                  const DropdownMenuItem(value: 'none', child: Text('未分类')),
                  ...taxonomy
                      .where(
                        (item) =>
                            item.kind == 'category' && item.deletedAt == null,
                      )
                      .map(
                        (item) => DropdownMenuItem(
                          value: item.id,
                          child: Text(item.name),
                        ),
                      ),
                ],
                onChanged: (value) => setState(() => _categoryFilter = value),
              ),
              FilterChip(
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
                    (item) => FilterChip(
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
                      _categoryFilter = null;
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
                      child: ListTile(
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
                          '${note.createdAt.toLocal().hour.toString().padLeft(2, '0')}:${note.createdAt.toLocal().minute.toString().padLeft(2, '0')}  ${note.categoryName ?? '未分类'}',
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
    NoteRecordingState recording,
  ) {
    // 当前仍有效的分类与历史显示名称。
    final TaxonomyEntry? category = taxonomy
        .where((item) => item.id == editor.draft.categoryId)
        .firstOrNull;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          OmniTextField(
            controller: _body,
            focusNode: _focus,
            minLines: 9,
            maxLines: null,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.7),
            decoration: const InputDecoration(
              hintText: '记下此刻的想法…\n也可以点麦克风，慢慢说。',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
            onChanged: (value) => editor.edit(body: value),
          ),
          const Divider(),
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
                  onPressed: () => _perform(editor.startRecording),
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
                  onPressed: () => _perform(
                    recording.phase == NoteRecordingPhase.paused
                        ? editor.recorder.resume
                        : editor.recorder.pause,
                  ),
                ),
                OmniButton(
                  label: '结束录音',
                  visualHeight: OmniSize.control,
                  onPressed: () => _perform(() async {
                    await editor.recorder.stop();
                  }),
                ),
                if (recording.noteId != editor.draft.id)
                  OmniButton(
                    label: '返回正在录音的笔记',
                    variant: OmniButtonVariant.text,
                    visualHeight: OmniSize.control,
                    onPressed: () => _open(recording.noteId!),
                  ),
              ],
              OmniButton(
                label: '恢复上次录音',
                variant: OmniButtonVariant.text,
                visualHeight: OmniSize.control,
                onPressed: () => _perform(editor.recover),
              ),
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
          const SizedBox(height: 16),
          ...segments.map(
            (segment) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: NoteAudioCard(
                segment: segment,
                local: local.where((item) => item.id == segment.id).firstOrNull,
                player: ref.read(noteAudioPlayerProvider),
                recordingActive: recording.isActive,
                onRecognize: () => _recognize(segment),
                onCancel: () => _cancelRecognition(segment),
                onInsert: (text) => _insertTranscript(segment, text),
              ),
            ),
          ),
          const Divider(),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OmniDropdownButton<String>(
                value: category?.deletedAt == null ? category?.id : null,
                hint: Text(
                  category?.deletedAt != null
                      ? '${category!.name}（已删除）'
                      : editor.draft.categoryName ?? '未分类',
                ),
                items: taxonomy
                    .where(
                      (item) =>
                          item.kind == 'category' && item.deletedAt == null,
                    )
                    .map(
                      (item) => DropdownMenuItem(
                        value: item.id,
                        child: Text(item.name),
                      ),
                    )
                    .toList(),
                onChanged: (id) {
                  final TaxonomyEntry? selected = taxonomy
                      .where((item) => item.id == id)
                      .firstOrNull;
                  editor.edit(categoryId: id, categoryName: selected?.name);
                },
              ),
              if (editor.draft.categoryId != null)
                OmniIconButton(
                  tooltip: '清除类别',
                  onPressed: () => editor.edit(clearCategory: true),
                  icon: const Icon(Icons.close),
                ),
              OmniButton(
                label: '管理类别',
                variant: OmniButtonVariant.text,
                visualHeight: OmniSize.control,
                onPressed: () => TaxonomyManagerDialog.show(
                  context,
                  module: TaxonomyModule.notes,
                  kind: TaxonomyKind.category,
                ),
              ),
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
                  (item) => FilterChip(
                    label: Text(item.name),
                    selected: editor.draft.tags.contains(item.id),
                    onSelected: (selected) {
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
      ),
    );
  }

  /// 格式化有效采样时长。
  Future<void> _insertTranscript(NoteAudioSegmentRecord segment, String text) =>
      _perform(() async {
        if (_inserting.contains(segment.id)) return;
        // 候选归属不能越过用户切换的笔记。
        final NoteEditorController editor = ref.read(noteEditorProvider);
        if (editor.draft.id != segment.noteId) return;
        _inserting.add(segment.id);
        try {
          // 使用用户光标位置，正文替换只发生在明确选中的范围。
          final TextSelection selection = _body.selection;
          final int start = selection.isValid
              ? selection.start.clamp(0, _body.text.length)
              : _body.text.length;
          final int end = selection.isValid
              ? selection.end.clamp(start, _body.text.length)
              : start;
          editor.edit(body: _body.text.replaceRange(start, end, text));
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

  /// 首次明确授权，只覆盖之后新录音。
  Future<void> _enableVoice(NoteEditorController editor) async {
    if (editor.voiceConsent) {
      setState(() => editor.voiceConsent = false);
      return;
    }
    // 未连接时说明如何启用服务，录音仍可本地使用。
    final bool confirmed = await showOmniConfirmDialog(
      context,
      title: '开启语音转文字',
      message:
          '之后的新录音将通过你连接的服务器提交给其配置的语音识别服务，原音和转写仍分别保留。需在设置中连接并开启同步；历史录音需要逐段授权。',
      confirmLabel: '开启',
    );
    if (confirmed && mounted) setState(() => editor.voiceConsent = true);
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
      message: '正文、原音和转写一起进入 30 天回收站，可在设置中恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed) return;
    await editor.shutdown();
    await editor.repository.softDelete(editor.draft.id);
    await editor.newNote();
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
                        (version) => ListTile(
                          title: Text(
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
