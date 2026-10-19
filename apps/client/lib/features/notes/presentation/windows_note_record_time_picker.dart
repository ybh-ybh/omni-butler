import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/note_record_time_picker_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 桌面独立时间草稿，按视频构建月历和向上展开的时分秒浮层。
class WindowsNoteRecordTimePanel extends StatefulWidget {
  /// 打开时的记录时间。
  final DateTime initialValue;

  /// 可注入的当前墙钟，用于边界测试。
  final DateTime? now;

  /// 仅保存正式记录时间的回调。
  final Future<void> Function(DateTime value) onConfirm;

  /// 创建桌面选择器，不接管任何正文草稿。
  const WindowsNoteRecordTimePanel({
    required this.initialValue,
    required this.now,
    required this.onConfirm,
    super.key,
  });

  /// 创建独立选择状态。
  @override
  State<WindowsNoteRecordTimePanel> createState() =>
      _WindowsNoteRecordTimePanelState();
}

/// 月历、可编辑时钟、子浮层和异步保存状态。
class _WindowsNoteRecordTimePanelState
    extends State<WindowsNoteRecordTimePanel> {
  /// 当前日期与时间，UTC容器只保留墙钟字段。
  late DateTime _value;

  /// 当前展示月份，不因选择时间而重置。
  late DateTime _month;

  /// 完整时分秒文本。
  late final TextEditingController _clock;

  /// 时间输入焦点。
  final FocusNode _clockFocus = FocusNode();

  /// 子面板打开前的文本，取消时完整恢复。
  String? _clockBefore;

  /// 子面板打开前的时分秒，恢复时不覆盖期间修改的日期。
  DateTime? _valueBefore;

  /// 输入是否完整有效。
  bool _validClock = true;

  /// 保存期间阻止重复提交和关闭。
  bool _saving = false;

  /// 保存失败或输入错误的反馈。
  String? _error;

  /// 鼠标悬停时才显示时间框清除入口。
  bool _clockHovered = false;

  /// 当前允许的最晚墙钟时间。
  DateTime get _now => _wall(widget.now ?? DateTime.now());

  /// 当前选择是否可正式提交。
  bool get _valid =>
      _validClock &&
      !_value.isBefore(DateTime.utc(1970)) &&
      !_value.isAfter(_now);

  /// 是否展示时间子面板。
  bool get _clockOpen => _clockBefore != null;

  /// 深色主题只替换中性色，视频中的绿色和结构保持。
  bool get _dark => Theme.of(context).brightness == Brightness.dark;

  /// 当前正文色。
  Color get _ink =>
      _dark ? OmniColors.of(context).ink : NoteRecordTimePickerTokens.ink;

  /// 当前辅助文字色。
  Color get _muted =>
      _dark ? OmniColors.of(context).muted : NoteRecordTimePickerTokens.muted;

  /// 当前分割线颜色。
  Color get _line =>
      _dark ? OmniColors.of(context).line : NoteRecordTimePickerTokens.line;

  /// 当前表面颜色。
  Color get _surface =>
      _dark ? OmniColors.of(context).paper : NoteRecordTimePickerTokens.surface;

  /// 不做时区转换，仅按所选年月日时分秒建立容器。
  DateTime _wall(DateTime value) => DateTime.utc(
    value.year,
    value.month,
    value.day,
    value.hour,
    value.minute,
    value.second,
  );

  /// 初始化当前记录时间和可见月份。
  @override
  void initState() {
    super.initState();
    _value = _wall(widget.initialValue);
    _month = DateTime.utc(_value.year, _value.month);
    _clock = TextEditingController(text: DateFormat('HH:mm:ss').format(_value));
  }

  /// 释放字段资源。
  @override
  void dispose() {
    _clock.dispose();
    _clockFocus.dispose();
    super.dispose();
  }

  /// 校验严格的二十四小时时分秒，非法输入原样保留供修正。
  void _clockChanged(String text) {
    // 三段完整输入，不接受日期库的溢出进位。
    final RegExpMatch? match = RegExp(r'^([01]\d|2[0-3]):([0-5]\d):([0-5]\d)$')
        .firstMatch(text.trim());
    setState(() {
      _validClock = match != null;
      _error = match == null ? '请输入 HH:mm:ss' : null;
      if (match != null) {
        _value = DateTime.utc(
          _value.year,
          _value.month,
          _value.day,
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
          int.parse(match.group(3)!),
        );
      }
    });
  }

  /// 替换日期，保留当前精确时钟。
  void _selectDate(DateTime date) => setState(() {
    _value = DateTime.utc(
      date.year,
      date.month,
      date.day,
      _value.hour,
      _value.minute,
      _value.second,
    );
    _error = null;
  });

  /// 按月份移动，允许浏览未来月份但不可选择未来日期。
  void _move(int months) => setState(() {
    _month = DateTime.utc(_month.year, _month.month + months);
  });

  /// 打开时间浮层并记住取消所需的原值。
  void _openClock() {
    if (_saving || _clockOpen) return;
    setState(() {
      _clockBefore = _clock.text;
      _valueBefore = _value;
    });
  }

  /// 时钟滚动立即预览到输入框，仍不提交正式笔记。
  void _previewClock(int hour, int minute, int second) {
    _clock.text =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:${second.toString().padLeft(2, '0')}';
    _clockChanged(_clock.text);
  }

  /// 仅关闭时间子面板；取消恢复原始时钟，不改变日期。
  void _closeClock({required bool apply}) {
    if (!_clockOpen) return;
    if (!apply) {
      _clock.text = _clockBefore!;
      _value = DateTime.utc(
        _value.year,
        _value.month,
        _value.day,
        _valueBefore!.hour,
        _valueBefore!.minute,
        _valueBefore!.second,
      );
      _clockChanged(_clock.text);
    }
    setState(() {
      _clockBefore = null;
      _valueBefore = null;
    });
  }

  /// Escape先撤销时间选择，再关闭整个日期面板。
  void _escape() {
    if (_saving) return;
    if (_clockOpen) {
      _closeClock(apply: false);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// 立即保存目标笔记；失败保持输入和面板供重试。
  Future<void> _confirm() async {
    if (_saving || !_valid) return;
    _closeClock(apply: true);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onConfirm(_value);
      if (!mounted) return;
      setState(() => _saving = false);
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '修改日期失败，请重试';
      });
    }
  }

  /// 小型文字按钮使用统一按压与焦点反馈，覆盖视频要求的几何。
  ButtonStyle _buttonStyle({
    Color? foreground,
    Color? background,
    double fontSize = 12,
  }) => TextButton.styleFrom(
    foregroundColor: foreground ?? _ink,
    backgroundColor: background,
    disabledForegroundColor: _muted.withValues(alpha: 0.45),
    disabledBackgroundColor: background == Colors.transparent
        ? Colors.transparent
        : background?.withValues(alpha: 0.4),
    minimumSize: Size.zero,
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: Theme.of(context).textTheme.bodySmall
        ?.copyWith(fontSize: fontSize),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(OmniRadius.control),
    ),
  );

  /// 年、月四个独立导航入口。
  Widget _navigation(String label, int delta) => SizedBox(
    width: 28,
    height: 28,
    child: Tooltip(
      message: label,
      child: OmniTextButton(
        key: ValueKey<String>('note-record-time-nav-$delta'),
        style: _buttonStyle(foreground: _muted),
        onPressed:
            DateTime.utc(_month.year, _month.month + delta).year < 1970 ||
                DateTime.utc(_month.year, _month.month + delta).year > 9999
            ? null
            : () => _move(delta),
        child: SizedBox.square(
          dimension: 16,
          child: CustomPaint(
            painter: _DateNavigationChevron(
              color: _muted,
              forward: delta > 0,
              doubleArrow: delta.abs() == 12,
            ),
          ),
        ),
      ),
    ),
  );

  /// 周日开头、固定六周的日期网格，包括不可选的邻月日期。
  Widget _calendar(double scale) {
    // 以周日作为该月第一行的起点。
    final DateTime first = _month.subtract(Duration(days: _month.weekday % 7));
    // 当天之后的自然日不可选择。
    final DateTime today = DateTime.utc(_now.year, _now.month, _now.day);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: NoteRecordTimePickerTokens.weekdayHeight * scale,
            child: Row(
              children: <Widget>[
                for (final String day in <String>[
                  '日',
                  '一',
                  '二',
                  '三',
                  '四',
                  '五',
                  '六',
                ])
                  Expanded(
                    child: Center(
                      child: Text(
                        day,
                        style: TextStyle(fontSize: 14, color: _muted),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 0, thickness: 1, color: _line),
          for (int week = 0; week < 6; week++)
            SizedBox(
              height: NoteRecordTimePickerTokens.weekHeight * scale,
              child: Row(
                children: <Widget>[
                  for (int column = 0; column < 7; column++)
                    _day(
                      first.add(Duration(days: week * 7 + column)),
                      today,
                      scale,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 日期只有选中态为绿色实心圆，今天仅显示绿色数字。
  Widget _day(DateTime date, DateTime today, double scale) {
    // 邻月与范围外日期按视频显示灰色且不可点击。
    final bool enabled =
        date.month == _month.month &&
        !date.isBefore(DateTime.utc(1970)) &&
        !date.isAfter(today);
    // 当前选择即使是历史越界值也保持定位。
    final bool selected = DateUtils.isSameDay(date, _value);
    // 今天仅使用文字强调，不增加描边。
    final bool isToday = DateUtils.isSameDay(date, today);
    return Expanded(
      child: Center(
        child: SizedBox.square(
          dimension: NoteRecordTimePickerTokens.dayDiameter * scale,
          child: Semantics(
            label: DateFormat('yyyy年M月d日').format(date),
            selected: selected,
            child: OmniTextButton(
              key: ValueKey<String>(
                'note-record-time-day-${DateFormat('yyyy-MM-dd').format(date)}',
              ),
              style:
                  _buttonStyle(
                    foreground: selected
                        ? Colors.white
                        : !enabled
                        ? (_dark
                              ? _muted.withValues(alpha: 0.4)
                              : NoteRecordTimePickerTokens.disabled)
                        : isToday
                        ? NoteRecordTimePickerTokens.green
                        : _ink,
                    background: selected
                        ? NoteRecordTimePickerTokens.green
                        : Colors.transparent,
                  ).copyWith(
                    shape: const WidgetStatePropertyAll<OutlinedBorder>(
                      CircleBorder(),
                    ),
                    overlayColor: WidgetStatePropertyAll<Color>(
                      _ink.withValues(alpha: 0.05),
                    ),
                  ),
              onPressed: enabled ? () => _selectDate(date) : null,
              child: Text('${date.day}'),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部灰色时钟输入与绿色确认保持同一行。
  Widget _footer(double scale) => Container(
    height: NoteRecordTimePickerTokens.footerHeight * scale,
    padding: EdgeInsets.fromLTRB(14, 11 * scale, 13, 12 * scale),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: _line)),
    ),
    child: Row(
      children: <Widget>[
        Expanded(
          child: MouseRegion(
            onEnter: (_) => setState(() => _clockHovered = true),
            onExit: (_) => setState(() => _clockHovered = false),
            child: OmniTextFormField(
              key: const ValueKey<String>('note-record-time-input'),
              controller: _clock,
              focusNode: _clockFocus,
              enabled: !_saving,
              style: TextStyle(fontSize: 14, color: _ink, height: 1),
              textAlignVertical: TextAlignVertical.center,
              keyboardType: TextInputType.datetime,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                isDense: true,
                constraints: BoxConstraints.tightFor(height: 34 * scale),
                filled: true,
                fillColor: _dark
                    ? OmniColors.of(context).paperSubtle
                    : NoteRecordTimePickerTokens.field,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                prefixIcon: Icon(Icons.access_time, size: 13, color: _muted),
                prefixIconConstraints: BoxConstraints.tightFor(
                  width: 32,
                  height: 34 * scale,
                ),
                suffixIcon: _clockHovered && _clock.text.isNotEmpty
                    ? SizedBox(
                        width: 24,
                        child: OmniTextButton(
                          style: _buttonStyle(foreground: _muted),
                          onPressed: () {
                            _clock.clear();
                            _clockChanged('');
                          },
                          child: const Icon(Icons.cancel, size: 13),
                        ),
                      )
                    : null,
                suffixIconConstraints: const BoxConstraints(maxWidth: 24),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                  borderSide: BorderSide(
                    color: _dark ? _line : NoteRecordTimePickerTokens.focusLine,
                  ),
                ),
              ),
              onTap: _openClock,
              onChanged: _clockChanged,
              onFieldSubmitted: (_) => _confirm(),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 64 * scale,
          height: 34 * scale,
          child: OmniTextButton(
            key: const ValueKey<String>('note-record-time-confirm'),
            style: _buttonStyle(
              foreground: Colors.white,
              background: NoteRecordTimePickerTokens.green,
              fontSize: 14,
            ),
            onPressed: _valid && !_saving ? _confirm : null,
            child: _saving
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    '确定',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
          ),
        ),
      ],
    ),
  );

  /// 构建无额外标题的月历，时间浮层覆盖日期而不改变主面板高度。
  @override
  Widget build(BuildContext context) {
    // 大字号增加行高，不固定系统文本缩放。
    final double scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return PopScope(
      canPop: !_saving,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _escape,
        },
        child: Material(
          color: _surface,
          child: IgnorePointer(
            ignoring: _saving,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  key: const ValueKey<String>('windows-note-record-time-panel'),
                  height: NoteRecordTimePickerTokens.height * scale,
                  child: Stack(
                    children: <Widget>[
                      Column(
                        children: <Widget>[
                          SizedBox(
                            height:
                                NoteRecordTimePickerTokens.headerHeight * scale,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              child: Row(
                                children: <Widget>[
                                  _navigation('上一年', -12),
                                  _navigation('上个月', -1),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        '${_month.year} 年 ${_month.month} 月',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: _ink,
                                        ),
                                      ),
                                    ),
                                  ),
                                  _navigation('下个月', 1),
                                  _navigation('下一年', 12),
                                ],
                              ),
                            ),
                          ),
                          _calendar(scale),
                          const Spacer(),
                          _footer(scale),
                        ],
                      ),
                      if (_clockOpen)
                        Positioned(
                          left: 14,
                          right: 13,
                          bottom:
                              NoteRecordTimePickerTokens.footerHeight * scale,
                          child: Align(
                            alignment: Alignment.bottomLeft,
                            child: TapRegion(
                              onTapOutside: (PointerDownEvent event) {
                                // 时间输入本身属于浮层入口，点击字段继续编辑而非取消。
                                final RenderBox? field =
                                    _clockFocus.context?.findRenderObject()
                                        as RenderBox?;
                                if (field != null &&
                                    (field.localToGlobal(Offset.zero) &
                                            field.size)
                                        .contains(event.position)) {
                                  return;
                                }
                                _closeClock(apply: true);
                              },
                              child: _WindowsClockPanel(
                                value: _value,
                                scale: scale,
                                onChanged: _previewClock,
                                onCancel: () => _closeClock(apply: false),
                                onConfirm: () => _closeClock(apply: true),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_error != null || (!_valid && _validClock))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Text(
                      _error ?? '请选择 1970 年至当前时刻之间的时间',
                      key: const ValueKey<String>('note-record-time-error'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 时分秒子浮层，三列独立滚动，中间一行用连续浅灰底表示当前值。
class _WindowsClockPanel extends StatefulWidget {
  /// 当前输入预览值。
  final DateTime value;

  /// 系统字号的布局比例。
  final double scale;

  /// 滚动后仅更新输入预览。
  final void Function(int hour, int minute, int second) onChanged;

  /// 取消恢复打开时输入。
  final VoidCallback onCancel;

  /// 确定仅关闭子面板。
  final VoidCallback onConfirm;

  /// 创建时间子浮层。
  const _WindowsClockPanel({
    required this.value,
    required this.scale,
    required this.onChanged,
    required this.onCancel,
    required this.onConfirm,
  });

  /// 创建三列滚动状态。
  @override
  State<_WindowsClockPanel> createState() => _WindowsClockPanelState();
}

/// 三列吸附控制器与键盘操作。
class _WindowsClockPanelState extends State<_WindowsClockPanel> {
  /// 独立控制各列，重建不丢失滚动位置。
  late final List<FixedExtentScrollController> _controllers;

  /// 外部输入同步期间忽略滚动回调，避免在构建中再次更新父状态。
  bool _syncing = false;

  /// 当前悬停列，滚动条只在该列可见。
  int? _hoveredColumn;

  /// 当前时分秒数值。
  List<int> get _values => <int>[
    widget.value.hour,
    widget.value.minute,
    widget.value.second,
  ];

  /// 定位到当前时分秒。
  @override
  void initState() {
    super.initState();
    _controllers = List<FixedExtentScrollController>.generate(
      3,
      (int column) => FixedExtentScrollController(initialItem: _values[column]),
    );
  }

  /// 输入文本变化后同步列位置。
  @override
  void didUpdateWidget(covariant _WindowsClockPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _syncing = true;
      for (int column = 0; column < 3; column++) {
        if (_controllers[column].hasClients &&
            _controllers[column].selectedItem != _values[column]) {
          _controllers[column].jumpToItem(_values[column]);
        }
      }
      _syncing = false;
    });
  }

  /// 释放三列资源。
  @override
  void dispose() {
    for (final FixedExtentScrollController controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 合并一列选择并更新输入预览。
  void _changed(int column, int index) {
    if (_syncing) return;
    // 其他列值保持当前选择。
    final List<int> values = _values;
    values[column] = index;
    widget.onChanged(values[0], values[1], values[2]);
  }

  /// 单列可通过滚轮、点击或键盘上下键操作。
  Widget _column(int column, Color ink) => Expanded(
    child: CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        for (final int delta in <int>[-1, 1])
          SingleActivator(
            delta < 0
                ? LogicalKeyboardKey.arrowUp
                : LogicalKeyboardKey.arrowDown,
          ): () => _controllers[column].jumpToItem(
            (_values[column] + delta).clamp(0, column == 0 ? 23 : 59),
          ),
      },
      child: Focus(
        child: Semantics(
          label: '记录时间${<String>['时', '分', '秒'][column]}',
          value: '${_values[column]}',
          child: MouseRegion(
            onEnter: (_) => setState(() => _hoveredColumn = column),
            onExit: (_) => setState(() => _hoveredColumn = null),
            child: RawScrollbar(
              controller: _controllers[column],
              thumbVisibility: _hoveredColumn == column,
              thickness: 3,
              radius: const Radius.circular(OmniRadius.pill),
              thumbColor: ink.withValues(alpha: 0.16),
              child: ListWheelScrollView.useDelegate(
                key: ValueKey<String>('note-record-time-clock-$column'),
                controller: _controllers[column],
                itemExtent:
                    NoteRecordTimePickerTokens.clockRowHeight * widget.scale,
                physics: const FixedExtentScrollPhysics(),
                diameterRatio: 100,
                perspective: 0.0001,
                onSelectedItemChanged: (int index) => _changed(column, index),
                childDelegate: ListWheelChildBuilderDelegate(
                  childCount: column == 0 ? 24 : 60,
                  builder: (BuildContext context, int index) => Center(
                    child: OmniTextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: ink,
                        minimumSize: Size.zero,
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(
                              fontSize: 12,
                              fontWeight: index == _values[column]
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                      ),
                      onPressed: () => _controllers[column].jumpToItem(index),
                      child: Text(index.toString().padLeft(2, '0')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// 六行高的平面滚动列表与底部取消、确定。
  @override
  Widget build(BuildContext context) {
    // 深色主题的中性色。
    final OmniColors colors = OmniColors.of(context);
    // 当前是否采用深色表面。
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // 子浮层文字色。
    final Color ink = dark ? colors.ink : NoteRecordTimePickerTokens.ink;
    // 子浮层边界。
    final Color line = dark ? colors.line : NoteRecordTimePickerTokens.line;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(OmniRadius.control),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.3 : 0.14),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        key: const ValueKey<String>('note-record-time-clock-panel'),
        color: dark ? colors.paper : NoteRecordTimePickerTokens.surface,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(OmniRadius.control),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: NoteRecordTimePickerTokens.clockWidth * widget.scale,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                height:
                    NoteRecordTimePickerTokens.clockListHeight * widget.scale,
                child: Stack(
                  children: <Widget>[
                    Center(
                      child: Container(
                        height:
                            NoteRecordTimePickerTokens.clockRowHeight *
                            widget.scale,
                        color: dark
                            ? colors.paperSubtle
                            : NoteRecordTimePickerTokens.field,
                        child: Row(
                          children: <Widget>[
                            for (int column = 0; column < 3; column++)
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: column == 2
                                        ? null
                                        : Border(
                                            right: BorderSide(
                                              color: dark
                                                  ? colors.paper
                                                  : Colors.white,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Row(
                      children: <Widget>[
                        for (int column = 0; column < 3; column++)
                          _column(column, ink),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                height: 36 * widget.scale,
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: line)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    for (final bool confirm in <bool>[false, true])
                      SizedBox(
                        width: 44 * widget.scale,
                        child: OmniTextButton(
                          key: ValueKey<String>(
                            confirm
                                ? 'note-record-time-clock-confirm'
                                : 'note-record-time-clock-cancel',
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: confirm
                                ? NoteRecordTimePickerTokens.clockBlue
                                : ink,
                            minimumSize: Size.zero,
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontSize: 12,
                                  fontWeight: confirm
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                          ),
                          onPressed: confirm
                              ? widget.onConfirm
                              : widget.onCancel,
                          child: Text(confirm ? '确定' : '取消'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 年月导航使用视频中的单像素细线箭头，不依赖系统图标字重。
class _DateNavigationChevron extends CustomPainter {
  /// 箭头颜色。
  final Color color;

  /// 是否朝右。
  final bool forward;

  /// 是否绘制双箭头。
  final bool doubleArrow;

  /// 创建细线导航图形。
  const _DateNavigationChevron({
    required this.color,
    required this.forward,
    required this.doubleArrow,
  });

  /// 绘制居中的单或双折线。
  @override
  void paint(Canvas canvas, Size size) {
    // 与视频一致的细线和圆角端点。
    final Paint pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    if (forward) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    for (final double shift in doubleArrow ? <double>[-2, 2] : <double>[0]) {
      // 四像素宽、八像素高的左折线。
      final Path path = Path()
        ..moveTo(10 + shift, 4)
        ..lineTo(6 + shift, 8)
        ..lineTo(10 + shift, 12);
      canvas.drawPath(path, pen);
    }
    canvas.restore();
  }

  /// 仅方向、单双或颜色变化时重画。
  @override
  bool shouldRepaint(covariant _DateNavigationChevron oldDelegate) =>
      color != oldDelegate.color ||
      forward != oldDelegate.forward ||
      doubleArrow != oldDelegate.doubleArrow;
}
