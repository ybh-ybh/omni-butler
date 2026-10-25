import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 以笔记搜索相同的菜单样式展示历史日期及清空入口。
Future<void> showTodoCompletionSearchFilter({
  required BuildContext context,
  required GlobalKey anchorKey,
  required DateTime today,
  required DateTime firstDate,
  required DateTime? start,
  required DateTime? end,
  required void Function(DateTime?, DateTime?) onRangeChanged,
  required VoidCallback onClear,
  Widget? compactFilters,
}) async {
  // 菜单与整个搜索栏右边缘对齐，并由当前窗口菜单路由限制边界。
  final RenderObject? anchor = anchorKey.currentContext?.findRenderObject();
  // 当前窗口浮层坐标系，不能跨多窗口使用全局尺寸。
  final RenderObject? overlay = Navigator.of(context).overlay?.context
      .findRenderObject();
  if (anchor is! RenderBox || !anchor.attached || overlay is! RenderBox) return;
  // 搜索栏在当前窗口中的起点。
  final Offset origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
  // 窄窗保留安全边距，正常窗口沿用笔记面板的三百二十像素宽度。
  final double width = math.min(
    320,
    math.max(0, overlay.size.width - OmniSpacing.md * 2),
  );
  await showOmniMenu<void>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(
        origin.dx + anchor.size.width - width,
        origin.dy + anchor.size.height + OmniSpacing.xs,
        width,
        0,
      ),
      Offset.zero & overlay.size,
    ),
    constraints: BoxConstraints.tightFor(width: width),
    menuPadding: const EdgeInsets.all(OmniSpacing.xs),
    requestFocus: true,
    items: <PopupMenuEntry<void>>[
      _CompletionFilterEntry(
        today: today,
        firstDate: firstDate,
        start: start,
        end: end,
        onRangeChanged: onRangeChanged,
        onClear: onClear,
        compactFilters: compactFilters,
      ),
    ],
  );
}

/// 菜单独立刷新日期标签，选择后仍沿用原有的即时筛选规则。
class _CompletionFilterEntry extends PopupMenuEntry<void> {
  /// 当前本地自然日及日历定位范围。
  final DateTime today;

  /// 最早可选日期覆盖所有既有历史。
  final DateTime firstDate;

  /// 打开菜单时的日期范围起点。
  final DateTime? start;

  /// 打开菜单时的日期范围终点。
  final DateTime? end;

  /// 将每次日期选择立即传回当前历史页面。
  final void Function(DateTime?, DateTime?) onRangeChanged;

  /// 清空范围、类型和关键词的原有页面操作。
  final VoidCallback onClear;

  /// 窄窗额外保留任务类型和月份选择。
  final Widget? compactFilters;

  /// 创建仅属于当前搜索栏的过滤菜单。
  const _CompletionFilterEntry({
    required this.today,
    required this.firstDate,
    required this.start,
    required this.end,
    required this.onRangeChanged,
    required this.onClear,
    this.compactFilters,
  });

  /// 估算首帧菜单高度，实际高度和滚动范围仍由内容决定。
  @override
  double get height => OmniSize.control * 4 + OmniSpacing.md * 3;

  /// 表单控件自己处理操作，不对应整条菜单选中值。
  @override
  bool represents(void value) => false;

  /// 创建可即时更新日期标签的局部状态。
  @override
  State<_CompletionFilterEntry> createState() => _CompletionFilterEntryState();
}

/// 日期、日历及清空操作均位于同一筛选菜单。
class _CompletionFilterEntryState extends State<_CompletionFilterEntry> {
  /// 当前菜单显示的日期起点。
  late DateTime? _start = widget.start;

  /// 当前菜单显示的日期终点。
  late DateTime? _end = widget.end;

  /// 校正相反端点后立即更新页面，保留单侧日期检索能力。
  void _select(DateTime? start, DateTime? end) {
    setState(() {
      _start = start;
      _end = end;
    });
    widget.onRangeChanged(start, end);
  }

  /// 构建纵向日期控件，窄窗和大字号仍能完整访问。
  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey<String>('todo-completion-search-filter-panel'),
    padding: const EdgeInsets.all(OmniSpacing.xs),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('完成日期', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: OmniSpacing.xs),
        OmniDatePickerButton(
          key: const ValueKey<String>('todo-completion-start-date'),
          value: _start,
          initialDate: _start ?? widget.today,
          currentDate: widget.today,
          firstDate: widget.firstDate,
          lastDate: widget.today,
          wrapLabel: true,
          label: _start == null
              ? '开始日期'
              : DateFormat('yyyy-MM-dd').format(_start!),
          onChanged: (DateTime value) => _select(
            value,
            _end != null && _end!.isBefore(value) ? value : _end,
          ),
        ),
        const SizedBox(height: OmniSpacing.xs),
        OmniDatePickerButton(
          key: const ValueKey<String>('todo-completion-end-date'),
          value: _end,
          initialDate: _end ?? widget.today,
          currentDate: widget.today,
          firstDate: widget.firstDate,
          lastDate: widget.today,
          wrapLabel: true,
          label: _end == null ? '结束日期' : DateFormat('yyyy-MM-dd').format(_end!),
          onChanged: (DateTime value) => _select(
            _start != null && _start!.isAfter(value) ? value : _start,
            value,
          ),
        ),
        if (widget.compactFilters != null)
          Row(
            children: <Widget>[
              const Expanded(child: Text('任务类型与月份')),
              widget.compactFilters!,
            ],
          ),
        const SizedBox(height: OmniSpacing.xs),
        OmniButton(
          key: const ValueKey<String>('todo-completion-clear'),
          label: '清空筛选',
          variant: OmniButtonVariant.text,
          icon: Icons.filter_alt_off_outlined,
          onPressed: () {
            Navigator.of(context).pop();
            widget.onClear();
          },
        ),
      ],
    ),
  );
}
