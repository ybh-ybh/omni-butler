import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 解析手动输入的二十四小时制时刻，允许小时省略前导零。
TimeOfDay? _parseClock(String text) {
  // 完整且有效的小时和分钟捕获结果。
  final RegExpMatch? match = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$')
      .firstMatch(text.trim());
  if (match == null) return null;
  return TimeOfDay(
    hour: int.parse(match.group(1)!),
    minute: int.parse(match.group(2)!),
  );
}

/// 补记起止时间摘要，触控端切换滚轮，桌面端直接输入。
class TimeEntryEndpointCard extends StatefulWidget {
  /// 稳定的开始或结束端点标识。
  final String endpoint;

  /// 当前完整时间。
  final DateTime value;

  /// 是否为滚轮交互。
  final bool usesWheel;

  /// 是否正在编辑此端点。
  final bool selected;

  /// 结束日期是否为开始日期的下一自然日。
  final bool nextDay;

  /// 是否允许修改。
  final bool enabled;

  /// 切换当前滚轮端点。
  final VoidCallback onSelect;

  /// 修改日期，时分保持不变。
  final ValueChanged<DateTime> onDateChanged;

  /// 修改时分，空值表示桌面输入暂时不完整或无效。
  final ValueChanged<TimeOfDay?> onTimeChanged;

  /// 创建同一布局下的日期与时间摘要。
  const TimeEntryEndpointCard({
    required this.endpoint,
    required this.value,
    required this.usesWheel,
    required this.selected,
    required this.nextDay,
    required this.enabled,
    required this.onSelect,
    required this.onDateChanged,
    required this.onTimeChanged,
    super.key,
  });

  /// 创建桌面精确输入状态。
  @override
  State<TimeEntryEndpointCard> createState() => _TimeEntryEndpointCardState();
}

/// 保留部分输入，并同步来自滑轨或日期控件的外部时刻。
class _TimeEntryEndpointCardState extends State<TimeEntryEndpointCard> {
  /// 桌面时刻输入控制器。
  late final TextEditingController _clockController;

  /// 初始化时刻文本，保留原始分钟。
  @override
  void initState() {
    super.initState();
    _clockController = TextEditingController(
      text: DateFormat('HH:mm').format(widget.value),
    );
  }

  /// 外部时刻变化才更新文本，避免输入途中移动光标。
  @override
  void didUpdateWidget(covariant TimeEntryEndpointCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value.hour != widget.value.hour ||
        oldWidget.value.minute != widget.value.minute) {
      // 控制器会通知祖先 Form，须在布局完成后再同步外部变更。
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted) return;
        if (_parseClock(_clockController.text) !=
            TimeOfDay.fromDateTime(widget.value)) {
          _clockController.text = DateFormat('HH:mm').format(widget.value);
        }
      });
    }
  }

  /// 释放桌面输入控制器。
  @override
  void dispose() {
    _clockController.dispose();
    super.dispose();
  }

  /// 构建可点击摘要或精确时间输入，以及常驻日期选择器。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 开始或结束的可读标签。
    final String label = widget.endpoint == 'start' ? '开始' : '结束';
    // 保留主题字体和用户字号缩放的时间文字样式。
    final TextStyle clockStyle = Theme.of(context).textTheme.headlineSmall!
        .copyWith(
          color: widget.selected && widget.usesWheel
              ? colors.brandStrong
              : colors.ink,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
    // 卡片中的标签与可操作时间。
    final Widget timeContent = Padding(
      padding: const EdgeInsets.fromLTRB(
        OmniSpacing.sm,
        OmniSpacing.sm,
        OmniSpacing.sm,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.nextDay ? '$label · 次日' : label,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.muted),
          ),
          const SizedBox(height: OmniSpacing.xxs),
          if (widget.usesWheel)
            Text(DateFormat('HH:mm').format(widget.value), style: clockStyle)
          else
            OmniTextFormField(
              key: ValueKey<String>('time-${widget.endpoint}-input'),
              controller: _clockController,
              enabled: widget.enabled,
              keyboardType: TextInputType.datetime,
              autocorrect: false,
              enableSuggestions: false,
              style: clockStyle,
              decoration: const InputDecoration(
                hintText: 'HH:mm',
                filled: false,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
              ),
              validator: (String? value) =>
                  _parseClock(value ?? '') == null ? '请输入 HH:mm' : null,
              onChanged: (String value) =>
                  widget.onTimeChanged(_parseClock(value)),
            ),
        ],
      ),
    );
    return Material(
      color: widget.selected && widget.usesWheel
          ? colors.brandSoft
          : colors.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadius.panel),
        side: BorderSide(
          color: widget.selected && widget.usesWheel
              ? colors.brand
              : colors.line,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.usesWheel)
            Semantics(
              selected: widget.selected,
              button: true,
              label: '调整$label时间',
              child: InkWell(
                key: ValueKey<String>('time-${widget.endpoint}-select'),
                onTap: widget.enabled ? widget.onSelect : null,
                child: timeContent,
              ),
            )
          else
            timeContent,
          Padding(
            padding: const EdgeInsets.all(OmniSpacing.xs),
            child: Semantics(
              label: '$label日期',
              child: OmniDatePickerButton(
                key: ValueKey<String>('time-${widget.endpoint}-date'),
                value: widget.value,
                initialDate: widget.value,
                firstDate: DateTime(1970),
                lastDate: DateTime(2100),
                label: DateFormat('yyyy/MM/dd').format(widget.value),
                icon: null,
                onChanged: widget.enabled ? widget.onDateChanged : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 闹钟式小时和分钟滚轮，只调整时刻，不改变所选日期。
class TimeEntryWheelPicker extends StatefulWidget {
  /// 当前端点的时刻。
  final TimeOfDay value;

  /// 当前正在编辑的端点标签。
  final String label;

  /// 是否允许滚动。
  final bool enabled;

  /// 分钟滚轮的刻度间隔，其他编辑入口仍默认逐分钟。
  final int minuteInterval;

  /// 任一滚轮吸附到新值时的回调。
  final ValueChanged<TimeOfDay> onChanged;

  /// 创建指定分钟间隔的双列滚轮。
  const TimeEntryWheelPicker({
    required this.value,
    required this.label,
    required this.enabled,
    required this.onChanged,
    this.minuteInterval = 1,
    super.key,
  }) : assert(minuteInterval > 0 && 60 % minuteInterval == 0);

  /// 创建独立时分滚动控制器。
  @override
  State<TimeEntryWheelPicker> createState() => _TimeEntryWheelPickerState();
}

/// 维护滚轮位置及与外部时刻的一致性。
class _TimeEntryWheelPickerState extends State<TimeEntryWheelPicker> {
  /// 小时滚轮控制器。
  late final FixedExtentScrollController _hourController;

  /// 分钟滚轮控制器。
  late final FixedExtentScrollController _minuteController;

  /// 同步外部数据时阻止回调覆盖另一列。
  bool _syncing = false;

  /// 分钟列的循环刻度数量。
  int get _minuteCount => 60 ~/ widget.minuteInterval;

  /// 当前分钟对应的刻度位置，非整刻度边界保留精确值。
  int get _minuteIndex => widget.value.minute ~/ widget.minuteInterval;

  /// 当前刻度保留外部精确分钟，其余可选刻度均按固定间隔显示。
  int _minuteAt(int index) => index == _minuteIndex
      ? widget.value.minute
      : index * widget.minuteInterval;

  /// 按当前精确时刻定位滚轮。
  @override
  void initState() {
    super.initState();
    _hourController = FixedExtentScrollController(
      initialItem: widget.value.hour,
    );
    _minuteController = FixedExtentScrollController(initialItem: _minuteIndex);
  }

  /// 保留用户滚动，只有外部值不一致时才同步对应列。
  @override
  void didUpdateWidget(covariant TimeEntryWheelPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 普通滚动回写不跳转也不屏蔽下一次用户选择。
    final bool syncHour =
        _hourController.hasClients &&
        _hourController.selectedItem % 24 != widget.value.hour;
    // 判断分钟列是否确有来自外部的变化。
    final bool syncMinute =
        _minuteController.hasClients &&
        _minuteController.selectedItem % _minuteCount != _minuteIndex;
    if (!syncHour && !syncMinute) return;
    _syncing = true;
    if (syncHour) {
      _hourController.jumpToItem(widget.value.hour);
    }
    if (syncMinute) {
      _minuteController.jumpToItem(_minuteIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _syncing = false;
    });
  }

  /// 释放两列滚动控制器。
  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  /// 用吸附后的两列当前位置产生时刻，保留日期由表单管理。
  void _notifyChanged() {
    if (!mounted || _syncing || !widget.enabled) return;
    // 当前小时与分钟，循环滚动不携带日期进位。
    final TimeOfDay next = TimeOfDay(
      hour: _hourController.selectedItem % 24,
      minute: _minuteAt(_minuteController.selectedItem % _minuteCount),
    );
    if (next != widget.value) widget.onChanged(next);
  }

  /// 为读屏用户提供与上下滑动等价的逐项调整。
  void _step(FixedExtentScrollController controller, int direction) {
    if (!widget.enabled || !controller.hasClients) return;
    controller.animateToItem(
      controller.selectedItem + direction,
      duration: OmniMotion.duration(context, OmniMotion.normal),
      curve: OmniMotion.standardCurve,
    );
  }

  /// 构建一列带吸附、循环与读屏增减动作的滚轮。
  Widget _buildWheel({
    required FixedExtentScrollController controller,
    required int count,
    required int selected,
    required double itemExtent,
    required String unit,
    required String keyName,
    required int Function(int) valueAt,
  }) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    return Expanded(
      child: Semantics(
        label: '${widget.label}$unit',
        value: valueAt(selected).toString().padLeft(2, '0'),
        increasedValue: valueAt((selected + 1) % count)
            .toString()
            .padLeft(2, '0'),
        decreasedValue: valueAt((selected - 1) % count)
            .toString()
            .padLeft(2, '0'),
        onIncrease: widget.enabled ? () => _step(controller, 1) : null,
        onDecrease: widget.enabled ? () => _step(controller, -1) : null,
        child: ExcludeSemantics(
          child: ListWheelScrollView.useDelegate(
            key: ValueKey<String>(keyName),
            controller: controller,
            itemExtent: itemExtent,
            physics: widget.enabled
                ? const FixedExtentScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            diameterRatio: 2.2,
            overAndUnderCenterOpacity: 0.35,
            onSelectedItemChanged: (int _) => _notifyChanged(),
            childDelegate: ListWheelChildLoopingListDelegate(
              children: List<Widget>.generate(count, (int index) {
                return Center(
                  child: Text(
                    valueAt(index).toString().padLeft(2, '0'),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: index == selected ? colors.ink : colors.muted,
                      fontWeight: index == selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  /// 构建居中选中带与小时、分钟两列，跟随用户文字缩放。
  @override
  Widget build(BuildContext context) {
    // 当前主题语义色。
    final OmniColors colors = OmniColors.of(context);
    // 放大字体时增高刻度，避免选中行被截断。
    final double itemExtent =
        (MediaQuery.textScalerOf(context).scale(
                  Theme.of(context).textTheme.headlineSmall?.fontSize ?? 24,
                ) +
                OmniSpacing.lg)
            .clamp(OmniSize.touch, double.infinity);
    return Center(
      child: SizedBox(
        width: 240,
        height: itemExtent * 3,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Positioned(
              left: 0,
              right: 0,
              height: itemExtent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.paperSubtle,
                  borderRadius: BorderRadius.circular(OmniRadius.control),
                ),
              ),
            ),
            Row(
              children: <Widget>[
                _buildWheel(
                  controller: _hourController,
                  count: 24,
                  selected: widget.value.hour,
                  itemExtent: itemExtent,
                  unit: '小时',
                  keyName: 'time-wheel-hour',
                  valueAt: (int index) => index,
                ),
                Text(':', style: Theme.of(context).textTheme.titleLarge),
                _buildWheel(
                  controller: _minuteController,
                  count: _minuteCount,
                  selected: _minuteIndex,
                  itemExtent: itemExtent,
                  unit: '分钟',
                  keyName: 'time-wheel-minute',
                  valueAt: _minuteAt,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
