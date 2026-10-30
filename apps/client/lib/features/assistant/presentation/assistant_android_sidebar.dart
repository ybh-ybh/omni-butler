import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_chat_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// Displays Android history without owning the workspace slide transition.
class AssistantAndroidSidebar extends ConsumerStatefulWidget {
  /// Owns conversations and the authenticated cache scope.
  final AssistantChatController chat;

  /// Freezes navigation and settings while voice input owns the draft.
  final bool voiceBusy;

  /// Selects a fixed conversation through the workspace.
  final ValueChanged<String> onSelected;

  /// Opens the existing rename flow for a fixed conversation.
  final Future<void> Function(String id) onRename;

  /// Opens the existing delete confirmation for a fixed conversation.
  final Future<void> Function(String id) onDelete;

  /// Closes the sidebar before navigating elsewhere.
  final VoidCallback onClose;

  /// Creates the independently scrollable history sidebar.
  const AssistantAndroidSidebar({
    required this.chat,
    required this.voiceBusy,
    required this.onSelected,
    required this.onRename,
    required this.onDelete,
    required this.onClose,
    super.key,
  });

  /// Creates scoped search and model selection state.
  @override
  ConsumerState<AssistantAndroidSidebar> createState() =>
      _AssistantAndroidSidebarState();
}

/// Keeps search responses separate from the controller's history list.
class _AssistantAndroidSidebarState
    extends ConsumerState<AssistantAndroidSidebar> {
  /// Stores the current search text across keyboard changes.
  final TextEditingController _query = TextEditingController();

  /// Loads another page when the history viewport reaches its end.
  final ScrollController _scroll = ScrollController();

  /// Preserves the editor subtree when a short viewport scrolls all controls.
  final GlobalKey _searchKey = GlobalKey();

  /// Anchors the model menu above the bottom controls.
  final GlobalKey _modelKey = GlobalKey();

  /// Anchors the remaining navigation menu.
  final GlobalKey _moreKey = GlobalKey();

  /// Debounces edits without delaying stale-response invalidation.
  Timer? _debounce;

  /// Identifies the current query and controller scope.
  int _generation = 0;

  /// Contains only results returned for the current query.
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];

  /// Holds the next unconsumed server or cache cursor.
  String? _nextCursor;

  /// Prevents repeated cursor responses from creating an endless loop.
  final Set<String> _usedCursors = <String>{};

  /// Marks an in-flight search request or pending debounce.
  bool _loading = false;

  /// Explains when results only cover the local cache.
  bool _cachedOnly = false;

  /// Holds a recoverable search error without clearing existing results.
  String? _searchError;

  /// Prevents concurrent menus and model writes.
  bool _modelOpen = false;

  /// Keeps model changes mutually exclusive with other sidebar actions.
  bool _savingModel = false;

  /// Watches history updates even when the parent does not rebuild.
  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_chatChanged);
    _scroll.addListener(_loadNearEnd);
  }

  /// Discards old results whenever the authentication scope is replaced.
  @override
  void didUpdateWidget(AssistantAndroidSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.chat, widget.chat)) return;
    oldWidget.chat.removeListener(_chatChanged);
    widget.chat.addListener(_chatChanged);
    _debounce?.cancel();
    _generation++;
    _query.clear();
    _items = <Map<String, dynamic>>[];
    _nextCursor = null;
    _usedCursors.clear();
    _loading = false;
    _cachedOnly = false;
    _searchError = null;
  }

  /// Releases listeners and invalidates requests before removing the sidebar.
  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    widget.chat.removeListener(_chatChanged);
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Repaints saved titles, pin state and operation gates.
  void _chatChanged() {
    if (mounted) setState(() {});
  }

  /// Empty search displays the complete controller history immediately.
  bool get _searching => _query.text.trim().isNotEmpty;

  /// Preserves pending submissions and attachment ownership during navigation.
  bool get _canNavigate =>
      !widget.voiceBusy &&
      !widget.chat.busy &&
      widget.chat.pending == null &&
      !widget.chat.attachments.transferring &&
      !widget.chat.attachments.adding &&
      !_savingModel;

  /// Only the original online repository may mutate conversation metadata.
  bool get _canMutate =>
      _canNavigate && widget.chat.connected && !widget.chat.offline;

  /// Invalidates prior requests before scheduling the next query.
  void _queryChanged(String value) {
    _debounce?.cancel();
    _generation++;
    _usedCursors.clear();
    setState(() {
      _items = <Map<String, dynamic>>[];
      _nextCursor = null;
      _loading = value.trim().isNotEmpty;
      _cachedOnly = false;
      _searchError = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (value.trim().isEmpty) return;
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_load()),
    );
  }

  /// Applies a page only while its query and controller are still current.
  Future<void> _load({bool next = false}) async {
    if (!_searching) return;
    // Capture the request identity before awaiting the repository.
    final int generation = _generation;
    // Keep requests tied to the original controller instance.
    final AssistantChatController chat = widget.chat;
    // Freeze the normalized query for this request.
    final String query = _query.text.trim();
    // Only a real unconsumed cursor may request another page.
    final String? cursor = next ? _nextCursor : null;
    if (next && (_loading || cursor == null)) return;
    setState(() {
      _loading = true;
      _searchError = null;
    });
    try {
      // Reuse server search and its scoped offline fallback.
      final Map<String, dynamic> response = await chat.searchConversations(
        query,
        cursor: cursor,
      );
      if (!mounted ||
          generation != _generation ||
          !identical(widget.chat, chat)) {
        return;
      }
      // Reject malformed identities instead of creating unusable rows.
      final List<Map<String, dynamic>> incoming = assistantItems(
        response['items'],
      ).where((item) => item['id'] is String && item['id'] != '').toList();
      // Dedupe within each page as well as across prior pages.
      final Set<String> seen = next
          ? _items.map((item) => item['id'] as String).toSet()
          : <String>{};
      // Empty cursors represent the end of the result set.
      final String? returnedCursor =
          response['nextCursor'] is String &&
              (response['nextCursor'] as String).isNotEmpty
          ? response['nextCursor'] as String
          : null;
      // Stop pagination when the server repeats an already requested cursor.
      final bool repeated =
          returnedCursor != null &&
          (returnedCursor == cursor || _usedCursors.contains(returnedCursor));
      if (cursor != null) _usedCursors.add(cursor);
      setState(() {
        _items = <Map<String, dynamic>>[
          if (next) ..._items,
          ...incoming.where((item) => seen.add(item['id'] as String)),
        ];
        _nextCursor = repeated ? null : returnedCursor;
        _cachedOnly = response['cachedOnly'] == true;
        _loading = false;
        _searchError = repeated ? '搜索分页异常，请重新搜索' : null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNearEnd());
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          !identical(widget.chat, chat)) {
        return;
      }
      setState(() {
        _loading = false;
        _searchError = error is ApiFailure ? error.message : '搜索失败，请重试';
      });
    }
  }

  /// Fetches another page when the visible list has little content remaining.
  void _loadNearEnd() {
    if (!mounted ||
        !_searching ||
        !_scroll.hasClients ||
        _scroll.position.extentAfter >= 120 ||
        _loading ||
        _searchError != null ||
        _nextCursor == null) {
      return;
    }
    unawaited(_load(next: true));
  }

  /// Retries a failed page or restarts an invalid cursor sequence.
  void _retrySearch() {
    if (_loading || !_searching) return;
    if (_items.isNotEmpty && _nextCursor != null) {
      unawaited(_load(next: true));
      return;
    }
    _generation++;
    _usedCursors.clear();
    unawaited(_load());
  }

  /// Lets the workspace select and close using the captured conversation id.
  void _choose(String id) {
    if (!_canNavigate) return;
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onSelected(id);
  }

  /// Positions menus within the same root overlay as their trigger.
  RelativeRect? _menuPosition(GlobalKey key) {
    // Resolve the rendered trigger without assuming a fixed sidebar width.
    final RenderBox? button =
        key.currentContext?.findRenderObject() as RenderBox?;
    // Root coordinates remain correct while the workspace is translated.
    final RenderBox? overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay?.context.findRenderObject()
            as RenderBox?;
    if (button == null || overlay == null) return null;
    return RelativeRect.fromRect(
      button.localToGlobal(Offset.zero, ancestor: overlay) & button.size,
      Offset.zero & overlay.size,
    );
  }

  /// Binds every long-press action to the selected row rather than current chat.
  Future<void> _conversationMenu(
    Map<String, dynamic> conversation,
    Offset position,
  ) async {
    if (!_canMutate) return;
    // Freeze the controller so a server switch invalidates the open menu.
    final AssistantChatController chat = widget.chat;
    // Freeze the actual selected row identity.
    final String id = conversation['id'] as String;
    // Search rows may have older metadata than the latest history refresh.
    final Map<String, dynamic> current =
        chat.conversations.where((item) => item['id'] == id).firstOrNull ??
        conversation;
    // Preserve the intended toggle even if the active chat changes.
    final bool pinned = current['isPinned'] == true;
    // Use root coordinates because menus render outside the translated panel.
    final RenderBox overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay!.context.findRenderObject()!
            as RenderBox;
    // Convert the global touch into the root overlay's coordinate system.
    final Offset local = overlay.globalToLocal(position);
    // Return only a fixed action from the shared menu surface.
    final String? action = await showOmniMenu<String>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromRect(
        local & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        OmniPopupMenuItem<String>(
          value: 'rename',
          label: '重命名',
          icon: Icons.drive_file_rename_outline,
        ),
        OmniPopupMenuItem<String>(
          value: 'pin',
          label: pinned ? '取消置顶' : '置顶',
          icon: Icons.push_pin_outlined,
        ),
        OmniPopupMenuItem<String>(
          value: 'delete',
          label: '删除聊天',
          icon: Icons.delete_outline,
          danger: true,
        ),
      ],
    );
    if (!mounted || !identical(widget.chat, chat) || !_canMutate) return;
    if (action == 'rename') await widget.onRename(id);
    if (action == 'pin') await chat.setPinned(id, !pinned);
    if (action == 'delete') await widget.onDelete(id);
    if (!mounted || !identical(widget.chat, chat) || action == null) return;
    if (_searching) {
      _queryChanged(_query.text);
    }
  }

  /// Saves a model choice with the exact settings revision shown in the menu.
  Future<void> _models(Map<String, dynamic>? settings) async {
    if (!_canMutate || _modelOpen || settings == null) return;
    // Keep the write attached to the chat's original authenticated repository.
    final AssistantRepository? repository = widget.chat.repository;
    // Keep response application attached to the same chat instance.
    final AssistantChatController chat = widget.chat;
    // Resolve the trigger before opening the root menu.
    final RelativeRect? position = _menuPosition(_modelKey);
    if (repository == null || !repository.isCurrent || position == null) return;
    // Freeze the compare-and-swap revision and unchanged settings fields.
    final Map<String, dynamic> fixed = Map<String, dynamic>.from(settings);
    // Ignore malformed profiles and preserve real server identities.
    final List<Map<String, dynamic>> profiles =
        assistantItems(fixed['profiles'])
            .where((profile) => profile['id'] is String && profile['id'] != '')
            .toList();
    if (profiles.isEmpty) {
      showOmniMessage(context, message: '请先在 AI 设置中添加模型配置');
      return;
    }
    // Count duplicate model labels before adding configuration names.
    final Map<String, int> counts = <String, int>{};
    // Each profile remains independently selectable by id.
    for (final Map<String, dynamic> profile in profiles) {
      // Use the same fallback label as the current-model button.
      final String label = '${profile['model'] ?? profile['name'] ?? '模型'}';
      counts[label] = (counts[label] ?? 0) + 1;
    }
    _modelOpen = true;
    try {
      // The menu only returns a profile; it never writes settings itself.
      final String? id = await showOmniMenu<String>(
        context: context,
        useRootNavigator: true,
        position: position,
        initialValue: fixed['profileId'] as String?,
        items: <PopupMenuEntry<String>>[
          for (final Map<String, dynamic> profile in profiles)
            OmniPopupMenuItem<String>(
              key: ValueKey<String>('assistant-android-model-${profile['id']}'),
              value: profile['id'] as String,
              label: _modelLabel(profile, counts),
              icon: profile['id'] == fixed['profileId'] ? Icons.check : null,
              enabled: profile['hasApiKey'] == true,
            ),
        ],
      );
      if (!mounted ||
          id == null ||
          id == fixed['profileId'] ||
          !identical(widget.chat, chat) ||
          !repository.isCurrent ||
          !_canMutate) {
        return;
      }
      // Settings outlive this sidebar when the user closes it during the write.
      final ProviderContainer container = ProviderScope.containerOf(
        context,
        listen: false,
      );
      // A public subscription tracks scope disposal independently of this widget.
      final ProviderSubscription<AsyncValue<Map<String, dynamic>?>> lifetime =
          container.listen(assistantSettingsProvider, (previous, next) {});
      setState(() => _savingModel = true);
      try {
        await repository.request(
          'PUT',
          '/settings',
          data: <String, dynamic>{
            'revision': fixed['revision'],
            'enabled': fixed['enabled'],
            'profileId': id,
            'memoryReadEnabled': fixed['memoryReadEnabled'],
            'memoryWriteEnabled': fixed['memoryWriteEnabled'],
            'timeZone': fixed['timeZone'] ?? 'Asia/Shanghai',
          },
        );
        if (!repository.isCurrent || lifetime.closed) return;
        container.invalidate(assistantSettingsProvider);
      } catch (error) {
        if (!repository.isCurrent || lifetime.closed) return;
        container.invalidate(assistantSettingsProvider);
        if (!mounted || !identical(widget.chat, chat)) return;
        showOmniMessage(
          context,
          message: error is ApiFailure ? error.message : '模型切换失败，请重试',
          tone: OmniMessageTone.error,
        );
      } finally {
        lifetime.close();
        if (mounted) setState(() => _savingModel = false);
      }
    } finally {
      _modelOpen = false;
    }
  }

  /// Disambiguates profiles that use the same model on different providers.
  String _modelLabel(Map<String, dynamic> profile, Map<String, int> counts) {
    // Prefer the actual model name over the optional profile label.
    final String model = '${profile['model'] ?? profile['name'] ?? '模型'}';
    // Include the saved configuration name only when needed for disambiguation.
    final String name = '${profile['name'] ?? ''}'.trim();
    return (counts[model] ?? 0) > 1 && name.isNotEmpty && name != model
        ? '$model · $name'
        : model;
  }

  /// Closes the sidebar before visiting existing application destinations.
  Future<void> _more() async {
    if (!_canNavigate) return;
    // Anchor the menu to the bottom action without fixed screen coordinates.
    final RelativeRect? position = _menuPosition(_moreKey);
    if (position == null) return;
    // Preserve the route owner while the menu is open.
    final AssistantChatController chat = widget.chat;
    // The selected path remains an application-defined destination.
    final String? destination = await showOmniMenu<String>(
      context: context,
      useRootNavigator: true,
      position: position,
      items: <PopupMenuEntry<String>>[
        OmniPopupMenuItem<String>(
          value: '/settings?section=ai',
          label: 'AI 设置',
          icon: Icons.settings_outlined,
        ),
        OmniPopupMenuItem<String>(
          value: '/assistant/memories',
          label: '助手记忆',
          icon: Icons.psychology_outlined,
        ),
        OmniPopupMenuItem<String>(
          value: '/home',
          label: '返回首页',
          icon: Icons.home_outlined,
        ),
      ],
    );
    if (!mounted ||
        destination == null ||
        !identical(widget.chat, chat) ||
        !_canNavigate) {
      return;
    }
    // Capture the router before onClose can remove this sidebar subtree.
    final GoRouter router = GoRouter.of(context);
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onClose();
    router.go(destination);
  }

  /// Reads real activity dates in local time without inventing missing values.
  DateTime? _updatedAt(Map<String, dynamic> conversation) {
    // Public timestamps are ISO strings; missing values belong to older history.
    final Object? value = conversation['updatedAt'];
    return value is String ? DateTime.tryParse(value)?.toLocal() : null;
  }

  /// Builds an accessible history row with the standard long-press feedback.
  Widget _conversation(Map<String, dynamic> conversation, OmniColors colors) {
    // Keep keys and callbacks bound to the real conversation identity.
    final String id = conversation['id'] as String;
    // Selection follows controller state rather than the last touched row.
    final bool selected = widget.chat.conversationId == id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.xs),
      child: Semantics(
        selected: selected,
        button: true,
        enabled: _canNavigate,
        child: Material(
          color: selected ? colors.canvas : Colors.transparent,
          borderRadius: BorderRadius.circular(OmniRadius.panel),
          clipBehavior: Clip.antiAlias,
          child: OmniPressSurface(
            key: ValueKey<String>('assistant-history-row-$id'),
            enabled: _canNavigate,
            borderRadius: BorderRadius.circular(OmniRadius.panel),
            onTap: () => _choose(id),
            onLongPressStart: _canMutate
                ? (details) => unawaited(
                    _conversationMenu(conversation, details.globalPosition),
                  )
                : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: OmniSize.touch),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: OmniSpacing.sm,
                  vertical: OmniSpacing.sm,
                ),
                child: Text(
                  '${conversation['title'] ?? '新对话'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.ink,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Uses quiet labels to separate activity dates without extra count badges.
  Widget _groupLabel(String label, OmniColors colors) => Padding(
    padding: const EdgeInsets.fromLTRB(
      OmniSpacing.lg,
      OmniSpacing.md,
      OmniSpacing.lg,
      OmniSpacing.xxs,
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: colors.muted),
    ),
  );

  /// Groups each history row once and keeps the server's order within groups.
  List<Widget> _history(OmniColors colors) {
    // Use the injected clock so date boundaries remain testable.
    final DateTime now = widget.chat.now().toLocal();
    // Local calendar boundaries avoid daylight-saving duration errors.
    final DateTime today = DateTime(now.year, now.month, now.day);
    // Yesterday is a calendar day rather than exactly twenty-four hours ago.
    final DateTime yesterday = DateTime(now.year, now.month, now.day - 1);
    // Today plus the preceding six days forms the latest seven-day group.
    final DateTime recent = DateTime(now.year, now.month, now.day - 6);
    // Insertion order defines the visible group order.
    final Map<String, List<Map<String, dynamic>>> groups = {
      '置顶': <Map<String, dynamic>>[],
      '今天': <Map<String, dynamic>>[],
      '昨天': <Map<String, dynamic>>[],
      '7天内': <Map<String, dynamic>>[],
      '更早': <Map<String, dynamic>>[],
    };
    // Duplicate identities must not create duplicate list keys.
    final Set<String> seen = <String>{};
    // Classify each real conversation without changing controller state.
    for (final Map<String, dynamic> conversation in widget.chat.conversations) {
      // Ignore incomplete server rows that cannot be selected safely.
      final Object? id = conversation['id'];
      if (id is! String || id.isEmpty || !seen.add(id)) continue;
      // Missing dates stay in the final group.
      final DateTime? updated = _updatedAt(conversation);
      // Pinned rows belong only to the pinned group.
      final String group = conversation['isPinned'] == true
          ? '置顶'
          : updated == null
          ? '更早'
          : !updated.isBefore(today)
          ? '今天'
          : !updated.isBefore(yesterday)
          ? '昨天'
          : !updated.isBefore(recent)
          ? '7天内'
          : '更早';
      groups[group]!.add(conversation);
    }
    return <Widget>[
      if (widget.chat.offline || !widget.chat.connected)
        _notice('当前显示本机缓存', colors),
      if (seen.isEmpty) _notice(widget.chat.loading ? '正在加载…' : '暂无对话', colors),
      for (final MapEntry<String, List<Map<String, dynamic>>> group
          in groups.entries)
        if (group.value.isNotEmpty) ...<Widget>[
          _groupLabel(group.key, colors),
          for (final Map<String, dynamic> conversation in group.value)
            _conversation(conversation, colors),
        ],
    ];
  }

  /// Displays only useful availability, empty-state or error text.
  Widget _notice(String text, OmniColors colors) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: OmniSpacing.lg,
      vertical: OmniSpacing.sm,
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: colors.muted),
    ),
  );

  /// Keeps successful pages visible when later pages fail.
  List<Widget> _results(OmniColors colors) => <Widget>[
    if (_cachedOnly) _notice('仅搜索本机缓存', colors),
    for (final Map<String, dynamic> item in _items) _conversation(item, colors),
    if (_loading)
      const Padding(
        padding: EdgeInsets.all(OmniSpacing.md),
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    if (!_loading && _items.isEmpty && _searchError == null)
      _notice('没有找到相关对话', colors),
    if (_searchError != null) ...<Widget>[
      _notice(_searchError!, colors),
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
          child: OmniTextButton(
            key: const ValueKey<String>('assistant-android-search-retry'),
            onPressed: _loading ? null : _retrySearch,
            child: const Text('重试'),
          ),
        ),
      ),
    ],
  ];

  /// Keeps input and clear controls inside the quiet search surface.
  Widget _search(OmniColors colors) => Padding(
    key: _searchKey,
    padding: const EdgeInsets.all(OmniSpacing.md),
    child: OmniTextField(
      key: const ValueKey<String>('assistant-history-search'),
      controller: _query,
      onChanged: _queryChanged,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) {
        if (!_searching) return;
        _debounce?.cancel();
        _generation++;
        _usedCursors.clear();
        unawaited(_load());
      },
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: '搜索对话',
        hintStyle: TextStyle(color: colors.muted),
        prefixIcon: Icon(Icons.search, color: colors.muted, size: 20),
        suffixIcon: _query.text.isEmpty
            ? null
            : OmniIconButton(
                tooltip: '清空搜索',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _query.clear();
                  _queryChanged('');
                },
              ),
        filled: true,
        fillColor: colors.canvas,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: OmniSpacing.sm,
          vertical: OmniSpacing.sm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmniRadius.panel),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmniRadius.panel),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OmniRadius.panel),
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );

  /// Keeps model and navigation actions at the bottom of a normal viewport.
  Widget _footer(
    AsyncValue<Map<String, dynamic>?> settings,
    OmniColors colors,
  ) {
    // Resolve the currently saved model without inventing a default profile.
    final Map<String, dynamic>? profile = assistantItems(
      settings.value?['profiles'],
    ).where((item) => item['id'] == settings.value?['profileId']).firstOrNull;
    // Keep the empty setup state accessible through the existing more menu.
    final String label = '${profile?['model'] ?? profile?['name'] ?? '选择模型'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OmniSpacing.sm,
        OmniSpacing.xs,
        OmniSpacing.xs,
        OmniSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Container(
              key: _modelKey,
              child: OmniTextButton(
                key: const ValueKey<String>('assistant-model-button'),
                onPressed:
                    _canMutate && !settings.isLoading && !settings.hasError
                    ? () => unawaited(_models(settings.value))
                    : null,
                style: TextButton.styleFrom(
                  foregroundColor: colors.ink,
                  minimumSize: const Size(0, OmniSize.touch),
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSpacing.xs,
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: OmniSpacing.xxs),
                    if (_savingModel)
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.expand_more, size: 18),
                  ],
                ),
              ),
            ),
          ),
          Container(
            key: _moreKey,
            child: OmniIconButton(
              key: const ValueKey<String>('assistant-sidebar-more'),
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz),
              onPressed: _canNavigate ? () => unawaited(_more()) : null,
            ),
          ),
        ],
      ),
    );
  }

  /// Preserves fixed bottom actions until a short viewport needs full scrolling.
  @override
  Widget build(BuildContext context) {
    // Use semantic surfaces for all supported palettes and dark mode.
    final OmniColors colors = OmniColors.of(context);
    // A shared provider supplies the same settings used by the assistant.
    final AsyncValue<Map<String, dynamic>?> settings = ref.watch(
      assistantSettingsProvider,
    );
    // Current history and search rows use the same gesture and selection rules.
    final List<Widget> rows = _searching ? _results(colors) : _history(colors);
    return Material(
      key: const ValueKey<String>('assistant-android-sidebar'),
      color: colors.paper,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Estimate chrome from real text scaling and preserve a useful list area.
          final double minimumHeight =
              math.max(
                48.0,
                MediaQuery.textScalerOf(context).scale(16) * 1.5 + 24,
              ) +
              math.max(
                48.0,
                MediaQuery.textScalerOf(context).scale(14) * 1.5 + 16,
              ) +
              128;
          if (constraints.maxHeight < minimumHeight) {
            return ListView(
              controller: _scroll,
              padding: EdgeInsets.zero,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: <Widget>[
                _search(colors),
                ...rows,
                _footer(settings, colors),
              ],
            );
          }
          return Column(
            children: <Widget>[
              _search(colors),
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: OmniSpacing.sm),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: rows,
                ),
              ),
              _footer(settings, colors),
            ],
          );
        },
      ),
    );
  }
}
