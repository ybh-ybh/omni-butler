import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/app/theme/note_record_time_picker_tokens.dart';

import 'package:omni_butler/shared/ui/omni_modal_bottom_sheet.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

import 'windows_note_record_time_picker.dart';

/// 按字段建立墙钟值，避免设备时区和夏令时改变所选年月日时分秒。
DateTime _wallClock(DateTime value) => DateTime.utc(
  value.year,
  value.month,
  value.day,
  value.hour,
  value.minute,
  value.second,
);

/// 打开安卓六列记录时间滚轮；确认仅返回值，由编辑页保存草稿。
Future<DateTime?> showAndroidNoteRecordTimePicker(
  BuildContext context, {
  required DateTime initialValue,
  DateTime? now,
}) => showOmniModalBottomSheet<DateTime>(
  context: context,
  builder: (BuildContext context) =>
      _NoteRecordTimePanel(initialValue: initialValue, now: now),
);

/// 打开桌面锚定日期浮层；保存失败保留选择，关闭或取消返回 false。
Future<bool> showWindowsNoteRecordTimePicker(
  BuildContext context, {
  required Rect anchor,
  required DateTime initialValue,
  required Future<void> Function(DateTime value) onConfirm,
  DateTime? now,
}) async {
  // 当前打开时的焦点，关闭浮层后交还调用入口。
  final FocusNode? previousFocus = FocusManager.instance.primaryFocus;
  // 与当前窗口菜单共用坐标系，不跨越到其他窗口的根导航。
  final RenderBox overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  // 窄窗口收窄面板，避免锚点靠边时内容溢出。
  final double width = math.min(
    NoteRecordTimePickerTokens.width,
    math.max(0, overlay.size.width - OmniSpacing.md * 2),
  );
  // 使用统一菜单路由负责精确测量、边缘避让、主题和焦点循环。
  final bool? saved = await showOmniMenu<bool>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(anchor.left, anchor.bottom + OmniSpacing.xxs, width, 0),
      Offset.zero & overlay.size,
    ),
    constraints: BoxConstraints.tightFor(width: width),
    menuPadding: EdgeInsets.zero,
    requestFocus: true,
    panelShadows: <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.1),
        blurRadius: 24,
        offset: const Offset(0, 8),
      ),
    ],
    items: <PopupMenuEntry<bool>>[
      _NoteRecordTimeMenuEntry(
        initialValue: initialValue,
        now: now,
        onConfirm: onConfirm,
      ),
    ],
  );
  if (previousFocus?.context != null && previousFocus!.canRequestFocus) {
    previousFocus.requestFocus();
  }
  return saved ?? false;
}

/// 将可编辑日期面板嵌入统一菜单路由，不触发普通菜单项点击提交。
class _NoteRecordTimeMenuEntry extends PopupMenuEntry<bool> {
  /// 打开时的完整记录时间。
  final DateTime initialValue;

  /// 测试指定的当前时刻。
  final DateTime? now;

  /// 确认后的独立保存操作。
  final Future<void> Function(DateTime value) onConfirm;

  /// 创建可包含表单和嵌套时间菜单的单个菜单条目。
  const _NoteRecordTimeMenuEntry({
    required this.initialValue,
    required this.now,
    required this.onConfirm,
  });

  /// 预估面板高度，统一菜单仍按最终内容尺寸布局。
  @override
  double get height => NoteRecordTimePickerTokens.height;

  /// 表单通过确定按钮提交，不对应自动选中的菜单值。
  @override
  bool represents(bool? value) => false;

  /// 创建面板承载状态。
  @override
  State<_NoteRecordTimeMenuEntry> createState() =>
      _NoteRecordTimeMenuEntryState();
}

/// 保留菜单路由语义及表单本身独立的取消和保存状态。
class _NoteRecordTimeMenuEntryState extends State<_NoteRecordTimeMenuEntry> {
  /// 构建桌面选择面板。
  @override
  Widget build(BuildContext context) => WindowsNoteRecordTimePanel(
    initialValue: widget.initialValue,
    now: widget.now,
    onConfirm: widget.onConfirm,
  );
}

/// 安卓六列选择草稿；正式写入仍由编辑页统一保存。
class _NoteRecordTimePanel extends StatefulWidget {
  /// 打开时记录时间。
  final DateTime initialValue;

  /// 测试指定当前时刻。
  final DateTime? now;

  /// 创建安卓选择面板。
  const _NoteRecordTimePanel({required this.initialValue, required this.now});

  /// 创建安卓选择状态。
  @override
  State<_NoteRecordTimePanel> createState() => _NoteRecordTimePanelState();
}

/// 原样展示已有时间并校验所选范围。
class _NoteRecordTimePanelState extends State<_NoteRecordTimePanel> {
  /// 当前墙钟选择，不随设备时区转换。
  late DateTime _value;

  /// 当前允许的最晚时刻。
  DateTime get _now => _wallClock(widget.now ?? DateTime.now());

  /// 选择值必须在1970年至当前时刻之间。
  bool get _valid =>
      !_value.isBefore(DateTime.utc(1970)) && !_value.isAfter(_now);

  /// 越界历史值也保留原始字段，等待用户主动修正。
  @override
  void initState() {
    super.initState();
    _value = _wallClock(widget.initialValue);
  }

  /// 只修改本次面板草稿。
  void _setValue(DateTime value) => setState(() => _value = _wallClock(value));

  /// 确认只把选择交回编辑器，不立即保存正式笔记。
  void _confirm() {
    if (_valid) Navigator.of(context).pop(_value);
  }

  /// 保持安卓原有标题、六列滚轮和底部操作。
  @override
  Widget build(BuildContext context) {
    // 安卓面板主题表面。
    final OmniColors colors = OmniColors.of(context);
    // 中文星期，无需依赖地区数据初始化。
    const List<String> weekdays = <String>[
      '星期一',
      '星期二',
      '星期三',
      '星期四',
      '星期五',
      '星期六',
      '星期日',
    ];
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: FocusScope(
        autofocus: true,
        child: Material(
          color: colors.paper,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(OmniRadius.panel),
            side: BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      OmniSpacing.md,
                      OmniSpacing.md,
                      OmniSpacing.md,
                      0,
                    ),
                    child: Align(
                      alignment: Alignment.center,
                      child: Text(
                        '设定日期',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(OmniSpacing.md),
                    child: Text(
                      '${DateFormat('yyyy年MM月dd日').format(_value)} ${weekdays[_value.weekday - 1]}',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  _RecordDateTimeWheels(
                    value: _value,
                    lastYear: _now.year,
                    onChanged: _setValue,
                  ),
                  if (!_valid)
                    Padding(
                      padding: const EdgeInsets.all(OmniSpacing.sm),
                      child: Text(
                        '请选择 1970 年至当前时刻之间的时间',
                        key: const ValueKey<String>('note-record-time-error'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(OmniSpacing.md),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: OmniButton(
                            label: '取消',
                            variant: OmniButtonVariant.text,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                        const SizedBox(width: OmniSpacing.sm),
                        Expanded(
                          child: OmniButton(
                            key: const ValueKey<String>(
                              'note-record-time-confirm',
                            ),
                            label: '确定',
                            onPressed: _valid ? _confirm : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 安卓年月日时分秒滚轮，各列范围有限且年月切换自动收敛月底。
class _RecordDateTimeWheels extends StatefulWidget {
  /// 当前墙钟选择。
  final DateTime value;

  /// 年份列允许的最后一年。
  final int lastYear;

  /// 任意列改变后的完整墙钟值。
  final ValueChanged<DateTime> onChanged;

  /// 创建六列滚轮。
  const _RecordDateTimeWheels({
    required this.value,
    required this.lastYear,
    required this.onChanged,
  });

  /// 创建六列独立滚动状态。
  @override
  State<_RecordDateTimeWheels> createState() => _RecordDateTimeWheelsState();
}

/// 同步列选择与月份天数，控制器不会在 rebuild 时丢失滚动位置。
class _RecordDateTimeWheelsState extends State<_RecordDateTimeWheels> {
  /// 六列滚轮的独立滚动控制器。
  late final List<FixedExtentScrollController> _controllers;

  /// 外部日期变化同步期间忽略滚轮回调。
  bool _syncing = false;

  /// 越界历史年份也可原样定位，修改回合法年份后恢复 1970 年起点。
  int get _firstYear => math.min(1970, widget.value.year);

  /// 当前值对应的六列零基索引。
  List<int> get _indices => <int>[
    widget.value.year - _firstYear,
    widget.value.month - 1,
    widget.value.day - 1,
    widget.value.hour,
    widget.value.minute,
    widget.value.second,
  ];

  /// 年月日时分秒各列允许的刻度数量。
  List<int> get _counts => <int>[
    math.max(widget.lastYear, widget.value.year) - _firstYear + 1,
    12,
    DateUtils.getDaysInMonth(widget.value.year, widget.value.month),
    24,
    60,
    60,
  ];

  /// 初始化所有滚轮到已有记录时间。
  @override
  void initState() {
    super.initState();
    _controllers = List<FixedExtentScrollController>.generate(
      6,
      (int column) =>
          FixedExtentScrollController(initialItem: _indices[column]),
    );
  }

  /// 年月切换造成月底收敛时，在布局后将日期列同步到合法刻度。
  @override
  void didUpdateWidget(covariant _RecordDateTimeWheels oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncing = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      for (int column = 0; column < 6; column++) {
        if (_controllers[column].hasClients &&
            _controllers[column].selectedItem != _indices[column]) {
          _controllers[column].jumpToItem(_indices[column]);
        }
      }
      _syncing = false;
    });
  }

  /// 释放所有滚轮控制器。
  @override
  void dispose() {
    for (final FixedExtentScrollController controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 将单列变更合并进墙钟，避免二月及小月日期溢出到下月。
  void _changed(int column, int index) {
    if (_syncing) return;
    // 当前选择的六列索引副本。
    final List<int> values = _indices;
    values[column] = index;
    // 目标月份的最后一天。
    final int lastDay = DateUtils.getDaysInMonth(
      values[0] + _firstYear,
      values[1] + 1,
    );
    widget.onChanged(
      DateTime.utc(
        values[0] + _firstYear,
        values[1] + 1,
        math.min(values[2] + 1, lastDay),
        values[3],
        values[4],
        values[5],
      ),
    );
  }

  /// 辅助功能逐项调整，遵从减少动画设置并限制在合法刻度内。
  void _step(int column, int direction) {
    // 本次辅助功能动作的目标刻度。
    final int target = (_indices[column] + direction).clamp(
      0,
      _counts[column] - 1,
    );
    if (OmniMotion.reduce(context)) {
      _controllers[column].jumpToItem(target);
      return;
    }
    _controllers[column].animateToItem(
      target,
      duration: OmniMotion.duration(context, OmniMotion.normal),
      curve: OmniMotion.standardCurve,
    );
  }

  /// 将零基刻度转换为年份、日期或时分秒的实际数值。
  int _columnValue(int column, int index) =>
      index +
      (column == 0
          ? _firstYear
          : column < 3
          ? 1
          : 0);

  /// 构建单列的名称、滚轮和读屏增减动作。
  Widget _buildColumn(int column, double itemExtent) {
    // 六列显示的中文单位。
    const List<String> units = <String>['年', '月', '日', '时', '分', '秒'];
    // 当前列允许的刻度数量。
    final int count = _counts[column];
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Expanded(
      flex: column == 0 ? 2 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(units[column], style: Theme.of(context).textTheme.bodySmall),
          SizedBox(
            height: itemExtent * 3,
            child: Semantics(
              label: '记录时间${units[column]}',
              value: '${_columnValue(column, _indices[column])}',
              increasedValue:
                  '${_columnValue(column, math.min(_indices[column] + 1, count - 1))}',
              decreasedValue:
                  '${_columnValue(column, math.max(_indices[column] - 1, 0))}',
              onIncrease: _indices[column] < count - 1
                  ? () => _step(column, 1)
                  : null,
              onDecrease: _indices[column] > 0 ? () => _step(column, -1) : null,
              child: ExcludeSemantics(
                child: ListWheelScrollView.useDelegate(
                  key: ValueKey<String>('note-record-time-wheel-$column'),
                  controller: _controllers[column],
                  itemExtent: itemExtent,
                  physics: const FixedExtentScrollPhysics(),
                  diameterRatio: 2.2,
                  overAndUnderCenterOpacity: 0.35,
                  onSelectedItemChanged: (int index) => _changed(column, index),
                  childDelegate: ListWheelChildBuilderDelegate(
                    childCount: count,
                    builder: (BuildContext context, int index) {
                      // 当前刻度的真实年份、日期或时分秒。
                      final int value = _columnValue(column, index);
                      return Center(
                        child: Text(
                          value.toString().padLeft(column == 0 ? 4 : 2, '0'),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: index == _indices[column]
                                    ? colors.ink
                                    : colors.muted,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建六列滚轮；窄屏允许横向滚动以维持每列 48dp 触控宽度。
  @override
  Widget build(BuildContext context) {
    // 字号缩放后仍可容纳完整时间刻度。
    final double itemExtent = math.max(
      OmniSize.touch,
      MediaQuery.textScalerOf(context).scale(22) + OmniSpacing.md,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: math.max(OmniSize.touch * 7, constraints.maxWidth),
              child: Row(
                children: List<Widget>.generate(
                  6,
                  (int column) => _buildColumn(column, itemExtent),
                ),
              ),
            ),
          ),
    );
  }
}
