import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_icon_button.dart';

/// 根据触控密度与当前视口约束日历宽度。
double _calendarWidth(BuildContext context) {
  // 触控端以七列点击热区为目标，窄屏时让浮层留在视口中。
  final double preferredWidth = OmniDensity.isTouch(context)
      ? OmniSize.touch * 7 + OmniSpacing.sm * 2
      : OmniDateTimePickerMetrics.calendarWidth;
  return math.min(
    preferredWidth,
    math.max(0, MediaQuery.sizeOf(context).width - OmniSpacing.md * 2),
  );
}

/// 日期与时间浮层的统一尺寸。
abstract final class OmniDateTimePickerMetrics {
  /// 日期浮层宽度。
  static const double calendarWidth = 280;

  /// 日期单元格高度。
  static const double dayCellHeight = 36;

  /// 时间浮层宽度。
  static const double timeMenuWidth = 104;

  /// 时间菜单项高度。
  static const double timeItemHeight = 36;

  /// 时间浮层最大高度。
  static const double timeMenuMaxHeight = 252;
}

/// 从触发按钮下方展开的统一日期选择器。
class OmniDatePickerButton extends StatefulWidget {
  /// 当前已选择的日期；为空时使用初始日期定位月份。
  final DateTime? value;

  /// 未选择日期时用于定位的初始日期。
  final DateTime initialDate;

  /// 最早可选日期。
  final DateTime firstDate;

  /// 最晚可选日期。
  final DateTime lastDate;

  /// 触发按钮文案。
  final String label;

  /// 触发按钮图标；为空时只展示文案。
  final IconData? icon;

  /// 触发按钮样式；为空时使用默认 OutlinedButton 样式。
  final ButtonStyle? style;

  /// 日期变化回调；为空时禁用控件。
  final ValueChanged<DateTime>? onChanged;

  /// 用于标记今天的日期，主要供可重复测试覆盖。
  final DateTime? currentDate;

  /// 创建锚定式日期选择按钮。
  OmniDatePickerButton({
    required this.value,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.label,
    required this.onChanged,
    this.icon = Icons.calendar_today_outlined,
    this.style,
    this.currentDate,
    super.key,
  }) : assert(!lastDate.isBefore(firstDate));

  /// 创建日期选择器状态。
  @override
  State<OmniDatePickerButton> createState() => _OmniDatePickerButtonState();
}

/// 锚定式日期选择器状态。
class _OmniDatePickerButtonState extends State<OmniDatePickerButton> {
  /// 浮层菜单控制器。
  final MenuController _menuController = MenuController();

  /// 日期浮层关闭后恢复的触发器焦点。
  final FocusNode _triggerFocus = FocusNode();

  /// 键盘进入日历时聚焦的日期格。
  final FocusNode _dateFocus = FocusNode();

  /// 当前展示的月份。
  late DateTime _visibleMonth;

  /// 是否正在展示月份快速选择网格。
  bool _showMonthGrid = false;

  /// 浮层是否已打开。
  bool _menuOpen = false;

  /// 初始化当前展示月份。
  @override
  void initState() {
    super.initState();
    _visibleMonth = _monthFor(_effectiveDate);
  }

  /// 释放日期触发器焦点。
  @override
  void dispose() {
    _dateFocus.dispose();
    _triggerFocus.dispose();
    super.dispose();
  }

  /// 在外部日期变化且浮层关闭时同步展示月份。
  @override
  void didUpdateWidget(covariant OmniDatePickerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_menuOpen && oldWidget.value != widget.value) {
      _visibleMonth = _monthFor(_effectiveDate);
    }
  }

  /// 当前用于定位浮层的有效日期。
  DateTime get _effectiveDate =>
      _clampDate(DateUtils.dateOnly(widget.value ?? widget.initialDate));

  /// 当前用于标记今天的日期。
  DateTime get _today =>
      DateUtils.dateOnly(widget.currentDate ?? DateTime.now());

  /// 将日期限制在可选择范围内。
  DateTime _clampDate(DateTime date) {
    // 归一化后的最早日期。
    final DateTime firstDate = DateUtils.dateOnly(widget.firstDate);
    // 归一化后的最晚日期。
    final DateTime lastDate = DateUtils.dateOnly(widget.lastDate);
    if (date.isBefore(firstDate)) {
      return firstDate;
    }
    if (date.isAfter(lastDate)) {
      return lastDate;
    }
    return date;
  }

  /// 返回日期所在月份的第一天。
  DateTime _monthFor(DateTime date) => DateTime(date.year, date.month);

  /// 将年月转换为连续月份序号。
  int _monthIndex(DateTime date) => date.year * 12 + date.month - 1;

  /// 判断指定日期是否在可选范围内。
  bool _isSelectable(DateTime date) {
    // 归一化后的候选日期。
    final DateTime normalized = DateUtils.dateOnly(date);
    return !normalized.isBefore(DateUtils.dateOnly(widget.firstDate)) &&
        !normalized.isAfter(DateUtils.dateOnly(widget.lastDate));
  }

  /// 切换日期浮层。
  void _toggleMenu() {
    if (_menuController.isOpen) {
      _menuController.close();
      return;
    }
    _visibleMonth = _monthFor(_effectiveDate);
    _showMonthGrid = false;
    _menuController.open();
  }

  /// 记录浮层已打开。
  void _handleOpen() {
    if (mounted) {
      setState(() => _menuOpen = true);
      if (FocusManager.instance.highlightMode ==
          FocusHighlightMode.traditional) {
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          if (mounted && _menuController.isOpen && _dateFocus.context != null) {
            _dateFocus.requestFocus();
          }
        });
      }
    }
  }

  /// 记录浮层已关闭。
  void _handleClose() {
    if (mounted) {
      _triggerFocus.requestFocus();
      setState(() {
        _menuOpen = false;
        _showMonthGrid = false;
      });
    }
  }

  /// 切换日期网格与月份快速选择网格。
  void _toggleMonthGrid() {
    setState(() => _showMonthGrid = !_showMonthGrid);
  }

  /// 切换到相邻月份。
  void _moveMonth(int delta) {
    // 目标月份。
    final DateTime target = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + delta,
    );
    if (_monthIndex(target) < _monthIndex(widget.firstDate) ||
        _monthIndex(target) > _monthIndex(widget.lastDate)) {
      return;
    }
    setState(() => _visibleMonth = target);
  }

  /// 切换月份快速选择网格中的年份。
  void _moveYear(int delta) {
    // 目标年份。
    final int targetYear = _visibleMonth.year + delta;
    if (targetYear < widget.firstDate.year ||
        targetYear > widget.lastDate.year) {
      return;
    }
    setState(() {
      _visibleMonth = DateTime(targetYear, _visibleMonth.month);
    });
  }

  /// 选中月份并返回日期网格。
  void _selectMonth(int month) {
    // 候选月份。
    final DateTime target = DateTime(_visibleMonth.year, month);
    if (_monthIndex(target) < _monthIndex(widget.firstDate) ||
        _monthIndex(target) > _monthIndex(widget.lastDate)) {
      return;
    }
    setState(() {
      _visibleMonth = target;
      _showMonthGrid = false;
    });
  }

  /// 提交已选择日期并关闭浮层。
  void _selectDate(DateTime date) {
    if (!_isSelectable(date)) {
      return;
    }
    widget.onChanged?.call(DateUtils.dateOnly(date));
    _menuController.close();
  }

  /// 构建日期浮层样式。
  MenuStyle _menuStyle(OmniColors colors) {
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll<Color>(colors.paper),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      shadowColor: WidgetStatePropertyAll<Color>(
        Colors.black.withValues(alpha: 0.12),
      ),
      elevation: const WidgetStatePropertyAll<double>(6),
      side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: colors.line)),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.panel),
        ),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.zero,
      ),
      minimumSize: WidgetStatePropertyAll<Size>(
        Size(_calendarWidth(context), 0),
      ),
      maximumSize: WidgetStatePropertyAll<Size>(
        Size(
          _calendarWidth(context),
          math.min(
            OmniDensity.isTouch(context) ? 456 : 380,
            math.max(0, MediaQuery.sizeOf(context).height - OmniSpacing.md * 2),
          ),
        ),
      ),
    );
  }

  /// 构建日期选择触发按钮。
  Widget _buildTrigger() {
    // 打开时用于强调锚点的按钮样式；与调用方自定义样式合并。
    final ButtonStyle? emphasisStyle = _menuOpen
        ? (widget.style ?? const ButtonStyle()).copyWith(
            side: WidgetStatePropertyAll<BorderSide>(
              BorderSide(color: OmniColors.of(context).brand, width: 1.5),
            ),
          )
        : widget.style;
    if (widget.icon == null) {
      return OutlinedButton(
        focusNode: _triggerFocus,
        onPressed: widget.onChanged == null ? null : _toggleMenu,
        style: emphasisStyle,
        child: Text(widget.label, overflow: TextOverflow.ellipsis),
      );
    }
    return OutlinedButton.icon(
      focusNode: _triggerFocus,
      onPressed: widget.onChanged == null ? null : _toggleMenu,
      style: emphasisStyle,
      icon: Icon(widget.icon, size: 18),
      label: Text(widget.label, overflow: TextOverflow.ellipsis),
    );
  }

  /// 构建锚定日期浮层。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return MenuAnchor(
      controller: _menuController,
      childFocusNode: _triggerFocus,
      style: _menuStyle(colors),
      alignmentOffset: const Offset(0, OmniSpacing.xxs),
      crossAxisUnconstrained: true,
      useRootOverlay: true,
      animated: false,
      onOpen: _handleOpen,
      onClose: _handleClose,
      menuChildren: <Widget>[
        _OmniCalendarPanel(
          visibleMonth: _visibleMonth,
          selectedDate: widget.value,
          focusDate: DateUtils.isSameMonth(_visibleMonth, _effectiveDate)
              ? _effectiveDate
              : _clampDate(_visibleMonth),
          dateFocus: _dateFocus,
          today: _today,
          firstDate: DateUtils.dateOnly(widget.firstDate),
          lastDate: DateUtils.dateOnly(widget.lastDate),
          showMonthGrid: _showMonthGrid,
          onToggleMonthGrid: _toggleMonthGrid,
          onMoveMonth: _moveMonth,
          onMoveYear: _moveYear,
          onSelectMonth: _selectMonth,
          onSelectDate: _selectDate,
        ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) {
            return Semantics(
              button: true,
              expanded: _menuOpen,
              enabled: widget.onChanged != null,
              child: _buildTrigger(),
            );
          },
    );
  }
}

/// 日期浮层中的日历面板。
class _OmniCalendarPanel extends StatelessWidget {
  /// 当前展示月份。
  final DateTime visibleMonth;

  /// 当前已选择日期。
  final DateTime? selectedDate;

  /// 键盘进入当前月份时使用的有效日期。
  final DateTime focusDate;

  /// 初始可操作日期的焦点节点。
  final FocusNode dateFocus;

  /// 用于标记今天的日期。
  final DateTime today;

  /// 最早可选日期。
  final DateTime firstDate;

  /// 最晚可选日期。
  final DateTime lastDate;

  /// 是否展示月份快速选择网格。
  final bool showMonthGrid;

  /// 月份网格切换回调。
  final VoidCallback onToggleMonthGrid;

  /// 相邻月份切换回调。
  final ValueChanged<int> onMoveMonth;

  /// 相邻年份切换回调。
  final ValueChanged<int> onMoveYear;

  /// 月份选择回调。
  final ValueChanged<int> onSelectMonth;

  /// 日期选择回调。
  final ValueChanged<DateTime> onSelectDate;

  /// 创建日历浮层面板。
  const _OmniCalendarPanel({
    required this.visibleMonth,
    required this.selectedDate,
    required this.focusDate,
    required this.dateFocus,
    required this.today,
    required this.firstDate,
    required this.lastDate,
    required this.showMonthGrid,
    required this.onToggleMonthGrid,
    required this.onMoveMonth,
    required this.onMoveYear,
    required this.onSelectMonth,
    required this.onSelectDate,
  });

  /// 将年月转换为连续月份序号。
  int _monthIndex(DateTime date) => date.year * 12 + date.month - 1;

  /// 判断日期是否在可选范围内。
  bool _isSelectable(DateTime date) =>
      !date.isBefore(firstDate) && !date.isAfter(lastDate);

  /// 构建浮层顶部月份导航。
  Widget _buildHeader(BuildContext context, OmniColors colors) {
    // 当前是否允许向前切换。
    final bool canMoveBack = showMonthGrid
        ? visibleMonth.year > firstDate.year
        : _monthIndex(visibleMonth) > _monthIndex(firstDate);
    // 当前是否允许向后切换。
    final bool canMoveForward = showMonthGrid
        ? visibleMonth.year < lastDate.year
        : _monthIndex(visibleMonth) < _monthIndex(lastDate);
    return SizedBox(
      height: 48,
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextButton(
              onPressed: onToggleMonthGrid,
              style: TextButton.styleFrom(
                foregroundColor: colors.ink,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      showMonthGrid
                          ? '${visibleMonth.year}年'
                          : '${visibleMonth.year}年${visibleMonth.month}月',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge!
                          .copyWith(fontSize: 14, fontWeight: FontWeight.w400),
                    ),
                  ),
                  const SizedBox(width: OmniSpacing.xxs),
                  AnimatedRotation(
                    turns: showMonthGrid ? 0.5 : 0,
                    duration: OmniMotion.duration(context, OmniMotion.fast),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: colors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          OmniIconButton(
            tooltip: showMonthGrid ? '上一年' : '上个月',
            onPressed: canMoveBack
                ? () => showMonthGrid ? onMoveYear(-1) : onMoveMonth(-1)
                : null,
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
          ),
          OmniIconButton(
            tooltip: showMonthGrid ? '下一年' : '下个月',
            onPressed: canMoveForward
                ? () => showMonthGrid ? onMoveYear(1) : onMoveMonth(1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  /// 构建星期标题。
  Widget _buildWeekdays(BuildContext context, OmniColors colors) {
    // 从周一开始展示的中文星期标签。
    const List<String> weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];
    return Row(
      children: weekdays
          .map(
            (String weekday) => Expanded(
              child: SizedBox(
                height: 32,
                child: Center(
                  child: Text(
                    weekday,
                    style: Theme.of(context).textTheme.bodySmall!
                        .copyWith(color: colors.muted, fontSize: 12),
                  ),
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  /// 构建一个日期单元格。
  Widget _buildDayCell(BuildContext context, DateTime date, OmniColors colors) {
    // 日期是否属于当前展示月份。
    final bool inVisibleMonth = date.month == visibleMonth.month;
    // 日期是否是当前选中项。
    final bool selected =
        selectedDate != null && DateUtils.isSameDay(date, selectedDate);
    // 日期是否是今天。
    final bool isToday = DateUtils.isSameDay(date, today);
    // 日期是否可选。
    final bool enabled = _isSelectable(date);
    // 日期默认前景色。
    final Color foreground = selected
        ? colors.accentInk
        : enabled
        ? (inVisibleMonth ? colors.ink : colors.muted.withValues(alpha: 0.68))
        : colors.muted.withValues(alpha: 0.34);
    return Semantics(
      label: MaterialLocalizations.of(context).formatFullDate(date),
      selected: selected,
      child: Center(
        child: SizedBox.square(
          dimension: OmniDensity.isTouch(context) ? OmniSize.touch : 32,
          child: TextButton(
            focusNode: DateUtils.isSameDay(date, focusDate) ? dateFocus : null,
            onPressed: enabled ? () => onSelectDate(date) : null,
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                EdgeInsets.zero,
              ),
              minimumSize: WidgetStatePropertyAll<Size>(
                Size.square(OmniDensity.isTouch(context) ? OmniSize.touch : 32),
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.standard,
              foregroundColor: WidgetStatePropertyAll<Color>(foreground),
              backgroundColor: WidgetStateProperty.resolveWith<Color?>((
                Set<WidgetState> states,
              ) {
                if (selected) {
                  return colors.brand;
                }
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)) {
                  return colors.brandSoft;
                }
                return Colors.transparent;
              }),
              shape: const WidgetStatePropertyAll<OutlinedBorder>(
                CircleBorder(),
              ),
              side: WidgetStatePropertyAll<BorderSide?>(
                isToday && !selected
                    ? BorderSide(color: colors.brand)
                    : BorderSide.none,
              ),
              textStyle: WidgetStatePropertyAll<TextStyle>(
                Theme.of(context).textTheme.bodyMedium!
                    .copyWith(fontSize: 13, fontWeight: FontWeight.w400),
              ),
            ),
            child: ExcludeSemantics(child: Text('${date.day}')),
          ),
        ),
      ),
    );
  }

  /// 构建六行日期网格。
  Widget _buildDayGrid(BuildContext context, OmniColors colors) {
    // 当月第一天。
    final DateTime firstOfMonth = DateTime(
      visibleMonth.year,
      visibleMonth.month,
    );
    // 网格第一格对应的周一日期。
    final DateTime gridStart = firstOfMonth.subtract(
      Duration(days: firstOfMonth.weekday - DateTime.monday),
    );
    // 固定六周的日期集合。
    final List<DateTime> days = List<DateTime>.generate(
      42,
      (int index) => gridStart.add(Duration(days: index)),
      growable: false,
    );
    // 日期行高度保留触控点击区域，桌面沿用紧凑密度。
    final double rowHeight = OmniDensity.isTouch(context)
        ? OmniSize.touch
        : OmniDateTimePickerMetrics.dayCellHeight;
    return SizedBox(
      height: rowHeight * 6,
      child: GridView(
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          mainAxisExtent: rowHeight,
        ),
        children: days
            .map((DateTime day) => _buildDayCell(context, day, colors))
            .toList(growable: false),
      ),
    );
  }

  /// 构建一年十二个月的快速选择网格。
  Widget _buildMonthGrid(OmniColors colors) {
    // 十二个月份。
    final List<int> months = List<int>.generate(12, (int index) => index + 1);
    return SizedBox(
      height: 248,
      child: GridView(
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisExtent: 56,
        ),
        children: months
            .map((int month) {
              // 当前月份候选值。
              final DateTime candidate = DateTime(visibleMonth.year, month);
              // 当前月份是否在范围内。
              final bool enabled =
                  _monthIndex(candidate) >= _monthIndex(firstDate) &&
                  _monthIndex(candidate) <= _monthIndex(lastDate);
              // 当前月份是否被展示。
              final bool selected = month == visibleMonth.month;
              return Padding(
                padding: const EdgeInsets.all(4),
                child: TextButton(
                  onPressed: enabled ? () => onSelectMonth(month) : null,
                  style: TextButton.styleFrom(
                    foregroundColor: selected ? colors.brandStrong : colors.ink,
                    backgroundColor: selected ? colors.brandSoft : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(OmniRadius.control),
                    ),
                  ),
                  child: Text('$month 月'),
                ),
              );
            })
            .toList(growable: false),
      ),
    );
  }

  /// 构建完整日历面板。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return SizedBox(
      width: _calendarWidth(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _buildHeader(context, colors),
            if (showMonthGrid)
              _buildMonthGrid(colors)
            else ...<Widget>[
              _buildWeekdays(context, colors),
              _buildDayGrid(context, colors),
              const SizedBox(height: OmniSpacing.sm),
            ],
          ],
        ),
      ),
    );
  }
}

/// 从触发按钮下方展开的统一时间选择器。
class OmniTimePickerButton extends StatefulWidget {
  /// 当前已选择的时间。
  final TimeOfDay value;

  /// 触发按钮文案。
  final String label;

  /// 触发按钮图标；为空时只展示文案。
  final IconData? icon;

  /// 时间变化回调；为空时禁用控件。
  final ValueChanged<TimeOfDay>? onChanged;

  /// 时间列表分钟步长。
  final int minuteStep;

  /// 创建锚定式时间选择按钮。
  const OmniTimePickerButton({
    required this.value,
    required this.label,
    required this.onChanged,
    this.icon = Icons.schedule_outlined,
    this.minuteStep = 30,
    super.key,
  }) : assert(minuteStep > 0 && minuteStep <= 60);

  /// 创建时间选择器状态。
  @override
  State<OmniTimePickerButton> createState() => _OmniTimePickerButtonState();
}

/// 锚定式时间选择器状态。
class _OmniTimePickerButtonState extends State<OmniTimePickerButton> {
  /// 浮层菜单控制器。
  final MenuController _menuController = MenuController();

  /// 时间浮层关闭后恢复的触发器焦点。
  final FocusNode _triggerFocus = FocusNode();

  /// 键盘打开菜单后使用的当前时间项焦点。
  final FocusNode _timeFocus = FocusNode();

  /// 时间列表滚动控制器。
  final ScrollController _scrollController = ScrollController();

  /// 浮层是否已打开。
  bool _menuOpen = false;

  /// 释放滚动控制器。
  @override
  void dispose() {
    _timeFocus.dispose();
    _triggerFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 当前时间对应的一天内分钟数。
  int get _selectedMinutes => widget.value.hour * 60 + widget.value.minute;

  /// 构建全部可选分钟并保留既有非步长时间。
  List<int> _minuteValues() {
    // 按步长生成的分钟列表。
    final List<int> values = <int>[
      for (int minute = 0; minute < 24 * 60; minute += widget.minuteStep)
        minute,
    ];
    if (!values.contains(_selectedMinutes)) {
      values.add(_selectedMinutes);
      values.sort();
    }
    return values;
  }

  /// 将一天内分钟数格式化为二十四小时制文字。
  String _formatMinutes(int minutes) {
    // 小时文本。
    final String hour = (minutes ~/ 60).toString().padLeft(2, '0');
    // 分钟文本。
    final String minute = (minutes % 60).toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// 切换时间浮层。
  void _toggleMenu() {
    if (_menuController.isOpen) {
      _menuController.close();
      return;
    }
    _menuController.open();
  }

  /// 记录浮层已打开并滚动到当前时间附近。
  void _handleOpen() {
    setState(() => _menuOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!_scrollController.hasClients) {
        return;
      }
      // 当前时间在菜单中的位置。
      final int selectedIndex = _minuteValues().indexOf(_selectedMinutes);
      // 让选中项前方保留两项上下文的目标偏移。
      final double targetOffset = math.max(
        0,
        (selectedIndex - 2) * _itemHeight,
      );
      _scrollController.jumpTo(
        math.min(targetOffset, _scrollController.position.maxScrollExtent),
      );
      if (FocusManager.instance.highlightMode ==
          FocusHighlightMode.traditional) {
        // 等滚动后的目标菜单项挂载，再将焦点交给当前时间。
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          if (mounted && _menuController.isOpen && _timeFocus.context != null) {
            _timeFocus.requestFocus();
          }
        });
      }
    });
  }

  /// 记录浮层已关闭。
  void _handleClose() {
    if (mounted) {
      _triggerFocus.requestFocus();
      setState(() => _menuOpen = false);
    }
  }

  /// 时间项高度兼顾触控目标与放大后的文本。
  double get _itemHeight => math.max(
    OmniDensity.isTouch(context)
        ? OmniSize.touch
        : OmniDateTimePickerMetrics.timeItemHeight,
    MediaQuery.textScalerOf(context).scale(13) + OmniSpacing.md,
  );

  /// 提交时间选择并关闭浮层。
  void _selectTime(int minutes) {
    widget.onChanged?.call(
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
    );
    _menuController.close();
  }

  /// 构建时间浮层样式。
  MenuStyle _menuStyle(OmniColors colors) {
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll<Color>(colors.paper),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      shadowColor: WidgetStatePropertyAll<Color>(
        Colors.black.withValues(alpha: 0.12),
      ),
      elevation: const WidgetStatePropertyAll<double>(6),
      side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: colors.line)),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadius.panel),
        ),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.all(OmniSpacing.xxs),
      ),
      minimumSize: const WidgetStatePropertyAll<Size>(
        Size(OmniDateTimePickerMetrics.timeMenuWidth, 0),
      ),
      maximumSize: const WidgetStatePropertyAll<Size>(
        Size(
          OmniDateTimePickerMetrics.timeMenuWidth,
          OmniDateTimePickerMetrics.timeMenuMaxHeight,
        ),
      ),
    );
  }

  /// 构建时间菜单项。
  Widget _buildTimeItem(int minutes, OmniColors colors) {
    // 当前项是否被选中。
    final bool selected = minutes == _selectedMinutes;
    return MenuItemButton(
      focusNode: selected ? _timeFocus : null,
      onPressed: widget.onChanged == null ? null : () => _selectTime(minutes),
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll<Size>(Size(0, _itemHeight)),
        fixedSize: WidgetStatePropertyAll<Size>(Size.fromHeight(_itemHeight)),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(horizontal: OmniSpacing.sm),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: OmniDensity.isTouch(context)
            ? VisualDensity.standard
            : VisualDensity.compact,
        alignment: Alignment.center,
        foregroundColor: WidgetStatePropertyAll<Color>(
          selected ? colors.accentInk : colors.ink,
        ),
        backgroundColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (selected) {
            return colors.brand;
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return colors.paperSubtle;
          }
          return Colors.transparent;
        }),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(OmniRadius.control),
          ),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle>(
          Theme.of(context).textTheme.bodyMedium!
              .copyWith(fontSize: 13, fontWeight: FontWeight.w400),
        ),
      ),
      child: Text(_formatMinutes(minutes)),
    );
  }

  /// 构建时间选择触发按钮。
  Widget _buildTrigger() {
    // 打开时用于强调锚点的按钮样式。
    final ButtonStyle? style = _menuOpen
        ? OutlinedButton.styleFrom(
            side: BorderSide(color: OmniColors.of(context).brand, width: 1.5),
          )
        : null;
    if (widget.icon == null) {
      return OutlinedButton(
        focusNode: _triggerFocus,
        onPressed: widget.onChanged == null ? null : _toggleMenu,
        style: style,
        child: Text(widget.label, overflow: TextOverflow.ellipsis),
      );
    }
    return OutlinedButton.icon(
      focusNode: _triggerFocus,
      onPressed: widget.onChanged == null ? null : _toggleMenu,
      style: style,
      icon: Icon(widget.icon, size: 18),
      label: Text(widget.label, overflow: TextOverflow.ellipsis),
    );
  }

  /// 构建锚定时间浮层。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 全部可选分钟。
    final List<int> values = _minuteValues();
    return MenuAnchor(
      controller: _menuController,
      childFocusNode: _triggerFocus,
      style: _menuStyle(colors),
      alignmentOffset: const Offset(0, OmniSpacing.xxs),
      crossAxisUnconstrained: true,
      useRootOverlay: true,
      animated: false,
      onOpen: _handleOpen,
      onClose: _handleClose,
      menuChildren: <Widget>[
        SizedBox(
          width: OmniDateTimePickerMetrics.timeMenuWidth,
          height: OmniDateTimePickerMetrics.timeMenuMaxHeight - 8,
          child: ListView(
            controller: _scrollController,
            padding: EdgeInsets.zero,
            children: values
                .map((int minutes) => _buildTimeItem(minutes, colors))
                .toList(growable: false),
          ),
        ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) {
            return Semantics(
              button: true,
              expanded: _menuOpen,
              enabled: widget.onChanged != null,
              child: _buildTrigger(),
            );
          },
    );
  }
}
