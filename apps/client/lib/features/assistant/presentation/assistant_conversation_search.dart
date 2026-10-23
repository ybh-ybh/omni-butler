import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_chat_controller.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 搜索弹窗独立管理查询与分页，绝不改写左侧历史列表。
class AssistantConversationSearch extends StatefulWidget {
  /// 当前认证作用域的聊天控制器。
  final AssistantChatController chat;

  /// 选择新聊天时由工作区创建真实会话。
  final VoidCallback onNew;

  /// 创建全文搜索面板。
  const AssistantConversationSearch({
    required this.chat,
    required this.onNew,
    super.key,
  });

  /// 创建独立搜索状态。
  @override
  State<AssistantConversationSearch> createState() =>
      _AssistantConversationSearchState();
}

/// 查询代次同时保护去抖、翻页与关闭后的迟到响应。
class _AssistantConversationSearchState
    extends State<AssistantConversationSearch> {
  /// 用户查询文本。
  final TextEditingController _query = TextEditingController();

  /// 搜索列表滚动位置。
  final ScrollController _scroll = ScrollController();

  /// 直接接收输入框按键，先于文本光标处理上下选择。
  late final FocusNode _focus = FocusNode(onKeyEvent: _handleKey);

  /// 当前查询的结果。
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];

  /// 下一页游标。
  String? _nextCursor;

  /// 已完成的分页游标，防止异常接口无限重复翻页。
  final Set<String> _usedCursors = <String>{};

  /// 只读缓存搜索标识。
  bool _cachedOnly = false;

  /// 当前查询正在加载。
  bool _loading = true;

  /// 当前查询错误。
  String? _error;

  /// 当前键盘选择项。
  int _selected = 0;

  /// 当前查询代次。
  int _generation = 0;

  /// 去抖计时器。
  Timer? _debounce;

  /// 用于键盘选择后滚入视口的稳定条目键。
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};

  /// 打开后加载最近会话，并按需翻页。
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_loadNearEnd);
    unawaited(_load());
  }

  /// 释放输入与所有未执行查询。
  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 新查询立即废弃旧结果，250毫秒后读取当前全文条件。
  void _changed(String value) {
    _debounce?.cancel();
    _generation++;
    _usedCursors.clear();
    setState(() {
      _loading = true;
      _items = <Map<String, dynamic>>[];
      _nextCursor = null;
      _error = null;
      _selected = 0;
    });
    _debounce = Timer(
      AssistantWindowsMetrics.searchDebounce,
      () => unawaited(_load()),
    );
  }

  /// 仅对当前查询提交结果；下一页先去重再拼接。
  Future<void> _load({bool next = false}) async {
    // 当前请求固定的查询代次。
    final int generation = _generation;
    // 下一页必须有真实服务端游标。
    final String? cursor = next ? _nextCursor : null;
    if (next && (_loading || cursor == null)) return;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // 固定当前查询及分页身份。
      final Map<String, dynamic> response = await widget.chat
          .searchConversations(_query.text.trim(), cursor: cursor);
      if (!mounted || generation != _generation) return;
      // 服务端或当前作用域缓存返回的真实会话。
      final List<Map<String, dynamic>> items = assistantItems(
        response['items'],
      );
      // 已经展示的会话身份，防止分页重复。
      final Set<String> seen = next
          ? _items.map((item) => '${item['id']}').toSet()
          : <String>{};
      // 异常回包不得复用当前或之前已经完成的分页游标。
      final String? nextCursor = response['nextCursor'] as String?;
      // 停止自动翻页并保留已有结果，用户仍可重新输入查询。
      final bool repeated =
          nextCursor != null &&
          (nextCursor == cursor || _usedCursors.contains(nextCursor));
      if (cursor != null) _usedCursors.add(cursor);
      setState(() {
        _items = <Map<String, dynamic>>[
          if (next) ..._items,
          ...items.where((item) => seen.add('${item['id']}')),
        ];
        _nextCursor = repeated ? null : nextCursor;
        _error = repeated ? '搜索分页异常，请重新搜索。' : null;
        _cachedOnly = response['cachedOnly'] == true;
        _loading = false;
        _selected = _items.isEmpty ? 0 : _selected.clamp(0, _items.length - 1);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNearEnd());
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error is ApiFailure ? error.message : '搜索失败，请重试';
      });
    }
  }

  /// 接近结果末尾时继续加载，不另外改变聊天会话。
  void _loadNearEnd() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 120 &&
        !_loading &&
        _error == null &&
        _nextCursor != null) {
      unawaited(_load(next: true));
    }
  }

  /// 正常分页失败继续原游标，异常游标则重置记录并从首页恢复。
  void _retrySearch() {
    if (_loading) return;
    if (_items.isNotEmpty && _nextCursor != null) {
      unawaited(_load(next: true));
      return;
    }
    _usedCursors.clear();
    unawaited(_load());
  }

  /// 选择真实会话后关闭弹窗，由调用方执行切换。
  void _choose(int index) {
    if (index < 0 || index >= _items.length || widget.chat.busy) return;
    Navigator.of(context).pop(_items[index]['id'] as String);
  }

  /// 模态路由独立处理新聊天快捷键，未知提交期间不可创建。
  void _create() {
    if (!widget.chat.connected ||
        widget.chat.busy ||
        widget.chat.pending != null) {
      return;
    }
    Navigator.of(context).pop();
    widget.onNew();
  }

  /// 搜索组合文字期间，Enter必须留给中文输入法。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_query.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyN) {
      _create();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _choose(_selected);
      return KeyEventResult.handled;
    }
    // Alt数字仅映射当前可见结果中的前九项。
    final List<LogicalKeyboardKey> numbers = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    if (HardwareKeyboard.instance.isAltPressed &&
        numbers.contains(event.logicalKey)) {
      _choose(numbers.indexOf(event.logicalKey));
      return KeyEventResult.handled;
    }
    if (_items.isNotEmpty &&
        (event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowUp)) {
      setState(
        () => _selected =
            (_selected +
                    (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1))
                .clamp(0, _items.length - 1),
      );
      // 已构建的选中条目滚动到视口内。
      final BuildContext? row =
          _rowKeys['${_items[_selected]['id']}']?.currentContext;
      if (row != null) {
        unawaited(
          Scrollable.ensureVisible(
            row,
            duration: OmniMotion.duration(context, OmniMotion.fast),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ),
        );
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 单行快捷键采用参考图的浅灰胶囊。
  Widget _shortcut(String label, AssistantWindowsPalette colors) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
    decoration: BoxDecoration(
      color: colors.soft,
      borderRadius: BorderRadius.circular(OmniRadius.pill),
    ),
    child: Text(label, style: TextStyle(color: colors.muted, fontSize: 13)),
  );

  /// 构建不会因为长正文而改变固定行高的搜索结果。
  Widget _result(int index, AssistantWindowsPalette colors) {
    // 当前会话元信息。
    final Map<String, dynamic> item = _items[index];
    // 稳定的会话身份。
    final String id = '${item['id']}';
    return Material(
      key: _rowKeys.putIfAbsent(id, GlobalKey.new),
      color: _selected == index ? colors.soft : colors.canvas,
      borderRadius: BorderRadius.circular(AssistantWindowsMetrics.rowRadius),
      child: OmniInkWell(
        key: ValueKey<String>('assistant-search-result-$id'),
        borderRadius: BorderRadius.circular(AssistantWindowsMetrics.rowRadius),
        onTap: () => _choose(index),
        onHover: (bool value) {
          if (value) setState(() => _selected = index);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 28,
                child: item['isPinned'] == true
                    ? Icon(
                        Icons.push_pin_outlined,
                        size: 15,
                        color: colors.muted,
                      )
                    : null,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${item['title'] ?? '新聊天'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: colors.ink),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (index < 9) _shortcut('Alt+${index + 1}', colors),
            ],
          ),
        ),
      ),
    );
  }

  /// 快捷操作沿用面板行布局，避免加入截图外的工具能力。
  Widget _action({
    required String title,
    required String shortcut,
    required IconData icon,
    required VoidCallback? action,
    required AssistantWindowsPalette colors,
  }) => OmniInkWell(
    onTap: action,
    borderRadius: BorderRadius.circular(AssistantWindowsMetrics.rowRadius),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: colors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 16, color: colors.ink),
            ),
          ),
          if (shortcut.isNotEmpty) _shortcut(shortcut, colors),
        ],
      ),
    ),
  );

  /// 居中的应用内圆角弹窗，列表内部滚动且适应大字号。
  @override
  Widget build(BuildContext context) {
    // 当前中性色与深色适配。
    final AssistantWindowsPalette colors = AssistantWindowsPalette.of(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _create,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AssistantWindowsMetrics.searchWidth,
              maxHeight: AssistantWindowsMetrics.searchHeight,
            ),
            child: Material(
              key: const ValueKey<String>('assistant-search-dialog'),
              color: colors.canvas,
              borderRadius: BorderRadius.circular(
                AssistantWindowsMetrics.panelRadius,
              ),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      child: OmniTextField(
                        key: const ValueKey<String>('assistant-search-input'),
                        controller: _query,
                        focusNode: _focus,
                        autofocus: true,
                        onChanged: _changed,
                        style: TextStyle(color: colors.ink, fontSize: 17),
                        decoration: InputDecoration(
                          hintText: '搜索聊天',
                          hintStyle: TextStyle(color: colors.muted),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                      child: Text(
                        _cachedOnly ? '聊天 · 仅本机缓存' : '聊天',
                        style: TextStyle(color: colors.muted, fontSize: 14),
                      ),
                    ),
                    Flexible(
                      child: ListView(
                        controller: _scroll,
                        shrinkWrap: true,
                        children: <Widget>[
                          for (int index = 0; index < _items.length; index++)
                            _result(index, colors),
                          if (_loading)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(
                                child: SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            ),
                          if (!_loading && _error == null && _items.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                _query.text.isEmpty ? '暂无聊天' : '没有找到相关聊天',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: colors.muted),
                              ),
                            ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                children: <Widget>[
                                  Text(
                                    _error!,
                                    style: TextStyle(color: colors.muted),
                                  ),
                                  OmniButton(
                                    label: '重试搜索',
                                    variant: OmniButtonVariant.text,
                                    onPressed: _retrySearch,
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
                      child: Text(
                        '快捷操作',
                        style: TextStyle(color: colors.muted, fontSize: 14),
                      ),
                    ),
                    _action(
                      title: '新聊天',
                      shortcut: 'Ctrl+N',
                      icon: Icons.edit_square,
                      action:
                          widget.chat.connected &&
                              !widget.chat.busy &&
                              widget.chat.pending == null
                          ? _create
                          : null,
                      colors: colors,
                    ),
                    _action(
                      title: 'AI 设置',
                      shortcut: '',
                      icon: Icons.settings_outlined,
                      action: () {
                        Navigator.of(context).pop();
                        context.go('/settings?section=ai');
                      },
                      colors: colors,
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
