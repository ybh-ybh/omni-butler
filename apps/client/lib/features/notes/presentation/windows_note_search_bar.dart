import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/features/notes/data/note_search_history.dart';
import 'package:omni_butler/features/notes/presentation/windows_note_search_filter.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';
import 'package:omni_butler/shared/ui/omni_windows_semantics_boundary.dart';

/// 桌面笔记搜索：灰底待机、向左展开和本机历史共用同一输入框。
class WindowsNoteSearchBar extends ConsumerStatefulWidget {
  /// 页面持有的关键词，保留既有实时检索能力。
  final TextEditingController controller;

  /// 壳层 Ctrl+F 与页面共用的焦点。
  final FocusNode focusNode;

  /// 当前可用标签，不读取另一套数据库。
  final List<TaxonomyEntry> tags;

  /// 已应用的筛选条件。
  final WindowsNoteSearchFilter filter;

  /// 实时更新页面查询。
  final ValueChanged<String> onChanged;

  /// 只有明确点击搜索才应用面板条件。
  final ValueChanged<WindowsNoteSearchFilter> onFilterChanged;

  /// 创建搜索入口；宽度由父级可用空间约束。
  const WindowsNoteSearchBar({
    required this.controller,
    required this.focusNode,
    required this.tags,
    required this.filter,
    required this.onChanged,
    required this.onFilterChanged,
    super.key,
  });

  /// 创建焦点、历史浮层和悬停状态。
  @override
  ConsumerState<WindowsNoteSearchBar> createState() =>
      _WindowsNoteSearchBarState();
}

/// 局部交互不改变正文编辑器或全局搜索行为。
class _WindowsNoteSearchBarState extends ConsumerState<WindowsNoteSearchBar> {
  /// 历史跟随搜索框右下角，展开动画中保持对齐。
  final LayerLink _historyLink = LayerLink();

  /// 历史浮层由当前页面生命周期负责清理。
  final OverlayPortalController _historyPortal = OverlayPortalController();

  /// 过滤面板使用整个搜索框作定位锚点。
  final GlobalKey _anchor = GlobalKey();

  /// 鼠标悬停只控制边框，不触发搜索。
  bool _hovered = false;

  /// 面板打开期间保持触发器反馈并阻止重复打开。
  bool _filterOpen = false;

  /// 上下方向键选择的历史行，负数表示使用当前输入。
  int _historyIndex = -1;

  /// 用户提交后先收起历史，再次点击时重新打开。
  bool _historyDismissed = false;

  /// 监听共享焦点，不接管其释放责任。
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
  }

  /// 响应父级更换焦点节点。
  @override
  void didUpdateWidget(WindowsNoteSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
  }

  /// 页面卸载只解除自己添加的监听。
  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    super.dispose();
  }

  /// 键盘进入立即展开；离开输入区关闭历史。
  void _focusChanged() {
    if (!mounted) return;
    setState(() {
      _historyIndex = -1;
      _historyDismissed = false;
    });
    _syncHistory();
  }

  /// 历史不抢占输入焦点，也不会与过滤菜单同时展示。
  void _syncHistory() {
    if (widget.focusNode.hasFocus && !_filterOpen && !_historyDismissed) {
      _historyPortal.show();
    } else {
      _historyPortal.hide();
    }
  }

  /// 明确提交或选择历史时记忆完整词条，输入法组合期不记录。
  void _submit([String? query]) {
    if (query == null &&
        widget.controller.value.composing.isValid &&
        !widget.controller.value.composing.isCollapsed) {
      return;
    }
    // 历史点击直接替换输入，并将光标放在末尾。
    final String text = (query ?? widget.controller.text).trim();
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.onChanged(text);
    unawaited(ref.read(noteSearchHistoryProvider.notifier).record(text));
    setState(() => _historyDismissed = true);
    _syncHistory();
    widget.focusNode.unfocus();
  }

  /// 方向键选历史，Escape收起；中文候选框保留自己的键盘处理。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        widget.controller.value.composing.isValid &&
            !widget.controller.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.focusNode.unfocus();
      return KeyEventResult.handled;
    }
    // 最多五项，循环选择不移动输入光标。
    final List<String> history = ref.read(noteSearchHistoryProvider);
    if (_historyPortal.isShowing && history.isNotEmpty) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _historyIndex = event.logicalKey == LogicalKeyboardKey.arrowDown
              ? (_historyIndex + 1) % history.length
              : (_historyIndex < 0
                    ? history.length - 1
                    : (_historyIndex - 1) % history.length);
        });
        return KeyEventResult.handled;
      }
      if ((event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
          _historyIndex >= 0) {
        _submit(history[_historyIndex]);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// 过滤草稿仅在搜索按钮确认后回传页面。
  Future<void> _openFilters() async {
    if (_filterOpen) return;
    setState(() => _filterOpen = true);
    _historyPortal.hide();
    widget.focusNode.unfocus();
    try {
      // 独立弹层负责窗口边界、取消和焦点恢复。
      final WindowsNoteSearchFilter? result = await showWindowsNoteSearchFilter(
        context: context,
        anchorKey: _anchor,
        value: widget.filter,
        tags: widget.tags,
      );
      if (mounted && result != null) {
        widget.onFilterChanged(result);
        unawaited(
          ref
              .read(noteSearchHistoryProvider.notifier)
              .record(widget.controller.text),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _filterOpen = false);
        _syncHistory();
      }
    }
  }

  /// 历史使用跟随浮层，覆盖正文而不推动笔记布局。
  Widget _history(BuildContext context, double width) {
    // 真实本机词条，不提供示例或占位历史。
    final List<String> history = ref.watch(noteSearchHistoryProvider);
    // 浮层沿用共享菜单的表面、圆角和阴影。
    final OmniColors colors = OmniColors.of(context);
    // 可用高度随窗口变化，短窗中历史自身滚动。
    final RenderBox? box =
        _anchor.currentContext?.findRenderObject() as RenderBox?;
    // 锚点以下空间始终留出窗口边距。
    final double available = box == null
        ? 260
        : (MediaQuery.sizeOf(context).height -
                  box.localToGlobal(Offset(0, box.size.height)).dy -
                  16)
              .clamp(0, 320);
    return Positioned(
      width: width,
      child: CompositedTransformFollower(
        link: _historyLink,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(0, OmniSpacing.xs),
        showWhenUnlinked: false,
        child: TextFieldTapRegion(
          child: OmniWindowsSemanticsBoundary(
            child: Material(
              key: const ValueKey('notes-search-history'),
              color: colors.paper,
              elevation: OmniMenuMetrics.elevation,
              shadowColor: Colors.black.withValues(
                alpha: OmniMenuMetrics.shadowOpacity,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(OmniRadius.panel),
                side: BorderSide(color: colors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: available),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(OmniSpacing.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(OmniSpacing.xs),
                        child: Text(
                          '最近搜索',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.muted),
                        ),
                      ),
                      if (history.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(OmniSpacing.xs),
                          child: Text(
                            '暂无搜索历史',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colors.muted),
                          ),
                        ),
                      // 搜索历史保持最近使用的顺序，最多五行。
                      for (int index = 0; index < history.length; index++)
                        Semantics(
                          selected: _historyIndex == index,
                          child: Material(
                            color: _historyIndex == index
                                ? colors.mist
                                : colors.mist.withValues(alpha: 0),
                            borderRadius: BorderRadius.circular(
                              OmniRadius.control,
                            ),
                            child: OmniInkWell(
                              key: ValueKey('notes-search-history-$index'),
                              canRequestFocus: false,
                              borderRadius: BorderRadius.circular(
                                OmniRadius.control,
                              ),
                              onTap: () => _submit(history[index]),
                              child: Padding(
                                padding: const EdgeInsets.all(OmniSpacing.xs),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.history,
                                      size: OmniSize.icon,
                                      color: colors.muted,
                                    ),
                                    const SizedBox(width: OmniSpacing.xs),
                                    Expanded(
                                      child: Text(
                                        history[index],
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Icon(
                                      Icons.north_west,
                                      size: OmniMenuMetrics.iconSize,
                                      color: colors.muted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 保留原输入组件与测试身份，只在外围实现局部视觉状态。
  @override
  Widget build(BuildContext context) {
    // 深色沿用主题表面，浅色聚焦使用白色。
    final OmniColors colors = OmniColors.of(context);
    // 旧搜索框实际48dp，按要求缩小10%；大字号只增加必要高度。
    final double height =
        43.2 + (MediaQuery.textScalerOf(context).scale(14) - 14).clamp(0, 40);
    // 输入聚焦时展开，打开筛选本身不扩大搜索框。
    final bool focused = widget.focusNode.hasFocus;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 可用空间不足时不越过页面边缘。
        final double width = (focused ? 400.0 : 260.0).clamp(
          0,
          constraints.maxWidth,
        );
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: width, end: width),
          duration: OmniMotion.duration(context, OmniMotion.panel),
          curve: OmniMotion.standardCurve,
          builder: (context, currentWidth, child) => Align(
            alignment: Alignment.centerRight,
            heightFactor: 1,
            child: SizedBox(
              width: currentWidth,
              child: OverlayPortal(
                controller: _historyPortal,
                overlayChildBuilder: (context) =>
                    _history(context, currentWidth),
                child: CompositedTransformTarget(
                  key: _anchor,
                  link: _historyLink,
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _hovered = true),
                    onExit: (_) => setState(() => _hovered = false),
                    child: AnimatedContainer(
                      key: const ValueKey('notes-search-surface'),
                      duration: OmniMotion.duration(context, OmniMotion.fast),
                      height: height,
                      decoration: BoxDecoration(
                        color: focused
                            ? (Theme.of(context).brightness == Brightness.light
                                  ? Colors.white
                                  : colors.paper)
                            : colors.mist,
                        borderRadius: BorderRadius.circular(OmniRadius.panel),
                        border: Border.all(
                          color: focused || _hovered || _filterOpen
                              ? colors.line
                              : colors.line.withValues(alpha: 0),
                        ),
                      ),
                      child: TextFieldTapRegion(
                        child: Row(
                          children: [
                            const SizedBox(width: OmniSpacing.sm),
                            Icon(
                              Icons.search,
                              size: OmniSize.icon,
                              color: colors.muted,
                            ),
                            const SizedBox(width: OmniSpacing.xs),
                            Expanded(
                              child: Focus(
                                onKeyEvent: _handleKey,
                                child: OmniTextField(
                                  key: const ValueKey('notes-search'),
                                  controller: widget.controller,
                                  focusNode: widget.focusNode,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                  textInputAction: TextInputAction.search,
                                  textAlignVertical: TextAlignVertical.center,
                                  decoration: InputDecoration(
                                    hintText: '搜索笔记 · Ctrl+F',
                                    filled: false,
                                    isDense: true,
                                    isCollapsed: true,
                                    contentPadding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    hoverColor: Colors.transparent,
                                  ),
                                  onTap: () {
                                    _historyDismissed = false;
                                    _syncHistory();
                                  },
                                  onTapOutside: (_) =>
                                      widget.focusNode.unfocus(),
                                  onChanged: (value) {
                                    setState(() => _historyIndex = -1);
                                    widget.onChanged(value);
                                  },
                                  onSubmitted: (_) => _submit(),
                                  // 由提交函数确认组合输入结束后再修改焦点和历史。
                                  onEditingComplete: () {},
                                ),
                              ),
                            ),
                            OmniIconButton(
                              key: const ValueKey('notes-search-filter'),
                              tooltip: '过滤笔记',
                              icon: const Icon(Icons.filter_list),
                              color: widget.filter.isActive ? colors.ink : null,
                              isSelected: _filterOpen || widget.filter.isActive,
                              onPressed: _openFilters,
                            ),
                            const SizedBox(width: OmniSpacing.xxs),
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
