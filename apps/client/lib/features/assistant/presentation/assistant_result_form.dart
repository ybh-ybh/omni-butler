import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 执行结果的业务表单，仅输出显式修改的安全字段。
class AssistantResultForm extends StatefulWidget {
  /// 服务端固定的业务模块名。
  final String module;

  /// 服务端返回的当前记录，不从模型推导字段。
  final Map<String, dynamic> record;

  /// 是否进入行内编辑。
  final bool editing;

  /// 保存期间禁用全部编辑操作。
  final bool enabled;

  /// 记录未携带时区时，由宿主提供明确的 IANA 业务时区。
  final String? timeZone;

  /// 有效时返回差量，无变更返回空映射，无效时返回空值。
  final ValueChanged<Map<String, dynamic>?> onChanged;

  /// 创建只读与编辑共用布局的业务表单。
  const AssistantResultForm({
    required this.module,
    required this.record,
    required this.editing,
    required this.enabled,
    required this.onChanged,
    this.timeZone,
    super.key,
  });

  /// 创建本地编辑草稿。
  @override
  State<AssistantResultForm> createState() => _AssistantResultFormState();
}

/// 字段交互种类，不接受运行时传入任意控件。
enum _Kind { text, multiline, integer, money, day, instant, choice, boolean }

/// 业务字段定义，白名单同时决定展示与可修改范围。
class _Field {
  /// 服务端字段名。
  final String name;

  /// 用户可见标签。
  final String label;

  /// 所在业务分组。
  final String group;

  /// 控件种类。
  final _Kind kind;

  /// 是否需要非空值。
  final bool required;

  /// 是否允许在当前面板修改。
  final bool editable;

  /// 数字最小值。
  final int minimum;

  /// 文字最大长度。
  final int maxLength;

  /// 固定枚举的显示名称。
  final Map<Object, String> options;

  /// 声明固定的业务字段。
  const _Field(
    this.name,
    this.label, {
    this.group = '基本信息',
    this.kind = _Kind.text,
    this.required = false,
    this.editable = true,
    this.minimum = 0,
    this.maxLength = 20000,
    this.options = const <Object, String>{},
  });
}

/// 待办优先级使用领域固定编号。
const Map<Object, String> _quadrants = <Object, String>{
  0: '不重要不紧急',
  1: '紧急不重要',
  2: '重要不紧急',
  3: '重要且紧急',
};

/// 固定业务表单不展示主键、同步字段或未审核的对象内容。
const Map<String, List<_Field>> _fields = <String, List<_Field>>{
  'todos': <_Field>[
    _Field('title', '任务名称', required: true, maxLength: 200),
    _Field(
      'taskType',
      '任务类型',
      kind: _Kind.choice,
      editable: false,
      options: <Object, String>{'normal': '普通任务', 'progress': '进度任务'},
    ),
    _Field('scheduledDate', '计划日期', kind: _Kind.day, required: true),
    _Field('priorityQuadrant', '优先级', kind: _Kind.choice, options: _quadrants),
    _Field('isCompleted', '是否完成', kind: _Kind.boolean, editable: false),
    _Field('dueAt', '截止时间', group: '时间安排', kind: _Kind.instant),
    _Field('reminderAt', '提醒时间', group: '时间安排', kind: _Kind.instant),
    _Field('progressUnit', '进度单位', group: '任务详情', maxLength: 10),
    _Field('description', '说明', group: '任务详情', kind: _Kind.multiline),
  ],
  'inventory': <_Field>[
    _Field('name', '物品名称', required: true, maxLength: 200),
    _Field('quantity', '数量', required: true, kind: _Kind.integer, minimum: 1),
    _Field(
      'status',
      '物品状态',
      kind: _Kind.choice,
      options: <Object, String>{
        'inUse': '在用',
        'idle': '闲置',
        'lent': '借出',
        'sold': '已售',
        'discarded': '已丢弃',
      },
    ),
    _Field('purchasePriceCents', '购买总金额（元）', group: '购买信息', kind: _Kind.money),
    _Field('purchaseDate', '购买日期', group: '购买信息', kind: _Kind.day),
    _Field('warrantyExpiration', '保修到期日', group: '购买信息', kind: _Kind.day),
    _Field('purchasePlatform', '购买平台', group: '购买信息'),
    _Field('purchaseUrl', '购买链接', group: '购买信息'),
    _Field('notes', '备注', group: '补充信息', kind: _Kind.multiline),
  ],
  'time': <_Field>[
    _Field('activity', '活动名称', required: true, maxLength: 200),
    _Field(
      'startedAt',
      '开始时间',
      group: '时间安排',
      kind: _Kind.instant,
      required: true,
    ),
    _Field(
      'endedAt',
      '结束时间',
      group: '时间安排',
      kind: _Kind.instant,
      required: true,
    ),
    _Field('timeZone', '记录时区', group: '时间安排', editable: false),
    _Field('notes', '备注', group: '补充信息', kind: _Kind.multiline),
  ],
  'notes': <_Field>[
    _Field('body', '笔记内容', kind: _Kind.multiline, required: true),
    _Field('dayKey', '所属日期', kind: _Kind.day, required: true),
    _Field('recordTimeSeconds', '记录时间', editable: false),
    _Field('isPinned', '置顶笔记', kind: _Kind.boolean),
  ],
  'quotes': <_Field>[
    _Field('content', '语录内容', kind: _Kind.multiline, required: true),
    _Field('source', '出处'),
    _Field('isEnabled', '启用语录', kind: _Kind.boolean),
  ],
  'memberships': <_Field>[
    _Field('name', '会员名称', required: true, maxLength: 200),
    _Field('provider', '服务商'),
    _Field(
      'baseStatus',
      '会员状态',
      kind: _Kind.choice,
      options: <Object, String>{
        'trial': '试用',
        'active': '有效',
        'cancelled': '已取消',
      },
    ),
    _Field('description', '权益说明', kind: _Kind.multiline),
    _Field(
      'priceCents',
      '账期金额（元）',
      group: '购买信息',
      kind: _Kind.money,
      required: true,
    ),
    _Field(
      'billingCycle',
      '账期',
      group: '购买信息',
      kind: _Kind.choice,
      editable: false,
      options: <Object, String>{
        'week': '每周',
        'month': '每月',
        'quarter': '每季度',
        'halfYear': '每半年',
        'year': '每年',
        'twoYears': '每两年',
        'threeYears': '每三年',
        'permanent': '永久',
        'custom': '自定义',
      },
    ),
    _Field(
      'purchaseDate',
      '购买日期',
      group: '购买信息',
      kind: _Kind.day,
      required: true,
    ),
    _Field(
      'expirationDate',
      '到期日期',
      group: '购买信息',
      kind: _Kind.day,
      editable: false,
    ),
    _Field('purchasePlatform', '购买平台', group: '购买信息'),
    _Field('websiteUrl', '官网链接', group: '购买信息'),
    _Field('autoRenew', '自动续费记录', group: '续费信息', kind: _Kind.boolean),
    _Field('renewalDate', '下次续费日期', group: '续费信息', kind: _Kind.day),
    _Field('needsRenewal', '需要续费', group: '续费信息', kind: _Kind.boolean),
    _Field('cancelGuide', '退订说明', group: '补充信息', kind: _Kind.multiline),
    _Field('notes', '备注', group: '补充信息', kind: _Kind.multiline),
  ],
  'events': <_Field>[
    _Field('name', '事务名称', required: true, maxLength: 200),
    _Field('category', '分类'),
    _Field(
      'intervalValue',
      '重复间隔',
      kind: _Kind.integer,
      minimum: 1,
      required: true,
    ),
    _Field(
      'intervalUnit',
      '间隔单位',
      kind: _Kind.choice,
      options: <Object, String>{
        'day': '天',
        'week': '周',
        'month': '月',
        'year': '年',
      },
    ),
    _Field('reminderEnabled', '启用提醒', group: '提醒设置', kind: _Kind.boolean),
    _Field(
      'reminderDaysBefore',
      '提前提醒天数',
      group: '提醒设置',
      kind: _Kind.integer,
      required: true,
    ),
    _Field('reminderTimeMinutes', '提醒时刻', group: '提醒设置', editable: false),
    _Field('isArchived', '归档事务', group: '补充信息', kind: _Kind.boolean),
    _Field('notes', '备注', group: '补充信息', kind: _Kind.multiline),
  ],
};

/// 业务表单的本地状态，失败保存时不丢失用户输入。
class _AssistantResultFormState extends State<AssistantResultForm> {
  /// 按字段复用控制器，避免输入过程中光标跳动。
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  /// 只包含用户真实操作的字段。
  final Map<String, dynamic> _changes = <String, dynamic>{};

  /// 字段级错误阻止父面板保存。
  final Map<String, String> _errors = <String, String>{};

  /// 重置后更换下拉控件身份，清除旧表单值。
  int _revision = 0;

  /// 当前模块的受控字段。
  List<_Field> get _specs => (_fields[widget.module] ?? const <_Field>[])
      .where(
        (_Field field) =>
            field.name != 'progressUnit' ||
            widget.record['taskType'] == 'progress',
      )
      .toList(growable: false);

  /// 初始有效草稿在首帧后通知，避免父级构建过程中更新状态。
  @override
  void initState() {
    super.initState();
    _notifyAfterFrame();
  }

  /// 重置后的空差量只在仍挂载且没有输入时交付。
  void _notifyAfterFrame() {
    // 捕获当前编辑代次，防止旧回调污染新草稿。
    final int revision = _revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          revision == _revision &&
          _changes.isEmpty &&
          _errors.isEmpty) {
        widget.onChanged(<String, dynamic>{});
      }
    });
  }

  /// 进入编辑状态前清除上次未保存的草稿。
  @override
  void didUpdateWidget(covariant AssistantResultForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editing != widget.editing ||
        oldWidget.module != widget.module) {
      _reset();
      _notifyAfterFrame();
    }
  }

  /// 清理草稿和控件，不将取消编辑理解为服务器写入。
  void _reset() {
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    _changes.clear();
    _errors.clear();
    _revision += 1;
  }

  /// 释放文本编辑资源。
  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  /// 读取草稿值，显式空值不能回退到原始记录。
  dynamic _value(_Field field) => _changes.containsKey(field.name)
      ? _changes[field.name]
      : field.name == 'timeZone'
      ? widget.record[field.name] ?? widget.timeZone
      : field.name == 'isCompleted'
      ? widget.record[field.name] ?? widget.record['completed']
      : widget.record[field.name];

  /// 日期字段统一使用业务日，不因本地时区改变日期。
  String _day(DateTime value) => DateFormat('yyyy-MM-dd').format(value);

  /// 日期值仅解析可信记录与日期选择器输出。
  DateTime? _date(_Field field, dynamic value) {
    // 当前日期的原始文本。
    final String raw = value?.toString() ?? '';
    // 纯日期截取日部分，时刻则转换为当前设备本地时间展示。
    final DateTime? parsed = DateTime.tryParse(
      field.kind == _Kind.day && raw.length >= 10 ? raw.substring(0, 10) : raw,
    );
    return field.kind == _Kind.instant ? parsed?.toLocal() : parsed;
  }

  /// 按业务含义格式化值，内部枚举不直接展示。
  String _display(_Field field, dynamic value) {
    if (value == null || value == '') return '';
    if (value is int &&
        (field.name == 'recordTimeSeconds' ||
            field.name == 'reminderTimeMinutes')) {
      // 记录时刻按保存的当地钟面展示，不当作 Unix 时间戳。
      final int seconds = field.name == 'recordTimeSeconds'
          ? value
          : value * 60;
      return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}';
    }
    if (field.kind == _Kind.choice) return field.options[value] ?? '未知状态';
    if (field.kind == _Kind.boolean) return value == true ? '是' : '否';
    if (field.kind == _Kind.money && value is num) {
      return (value / 100).toStringAsFixed(2);
    }
    if (field.kind == _Kind.day || field.kind == _Kind.instant) {
      // 当前业务日期或时刻。
      final DateTime? parsed = _date(field, value);
      if (parsed != null) {
        return DateFormat(
          field.kind == _Kind.day ? 'yyyy-MM-dd' : 'yyyy-MM-dd HH:mm',
        ).format(parsed);
      }
    }
    return value is String || value is num ? value.toString() : '';
  }

  /// 只回传差量；同一日期的不同序列化形式不产生无意义更新。
  void _set(_Field field, dynamic value, {String? error}) {
    // 服务端原始字段值。
    final dynamic previous = widget.record[field.name];
    // 日期字段用同一种表示判断是否改变。
    final bool same = field.kind == _Kind.day
        ? _display(field, previous) == _display(field, value)
        : field.kind == _Kind.instant && previous != null && value != null
        ? _date(field, previous)?.isAtSameMomentAs(_date(field, value)!) == true
        : previous == value;
    setState(() {
      if (same) {
        _changes.remove(field.name);
      } else {
        _changes[field.name] = value;
      }
      if (error == null) {
        _errors.remove(field.name);
      } else {
        _errors[field.name] = error;
      }
    });
    _notify();
  }

  /// 验证跨字段时间关系并交付差量。
  void _notify() {
    // 保存时交付副本，附加必需的记录上下文不污染本地字段差量。
    final Map<String, dynamic> patch = Map<String, dynamic>.of(_changes);
    if (widget.module == 'time') {
      // 时间记录必须结束晚于开始。
      final DateTime? start = DateTime.tryParse(
        (_changes['startedAt'] ?? widget.record['startedAt'])?.toString() ?? '',
      );
      // 结束时刻与当前草稿开始时刻一起验证。
      final DateTime? end = DateTime.tryParse(
        (_changes['endedAt'] ?? widget.record['endedAt'])?.toString() ?? '',
      );
      if (start != null && end != null && !end.isAfter(start)) {
        setState(() => _errors['endedAt'] = '结束时间应晚于开始时间');
      } else {
        _errors.remove('endedAt');
      }
      // 记录有明确时区时沿用；否则要求父级传入业务时区。
      final dynamic timeZone = widget.record['timeZone'] ?? widget.timeZone;
      if (patch.isNotEmpty &&
          (timeZone is! String ||
              !(timeZone == 'UTC' ||
                  RegExp(r'^[A-Za-z_]+(?:/[A-Za-z0-9_+\-]+)+$')
                      .hasMatch(timeZone)))) {
        setState(() => _errors['timeZone'] = '缺少记录时区，请刷新后重试');
      } else {
        _errors.remove('timeZone');
        if (patch.isNotEmpty) patch['timeZone'] = timeZone;
      }
    }
    widget.onChanged(_errors.isEmpty ? patch : null);
  }

  /// 文本、数量和金额在本地校验，金额按十进制精确换算为分。
  void _textChanged(_Field field, String text) {
    // 保留正文空白，单行字段去除无意义的首尾空白。
    final String value = field.kind == _Kind.multiline ? text : text.trim();
    if (value.trim().isEmpty) {
      _set(field, null, error: field.required ? '请填写${field.label}' : null);
      return;
    }
    if (field.kind == _Kind.integer) {
      // 整数不接受小数或指数形式。
      final int? number = int.tryParse(value);
      _set(
        field,
        number,
        error: number == null || number < field.minimum || number > 2147483647
            ? '请输入不小于${field.minimum}的有效整数'
            : null,
      );
    } else if (field.kind == _Kind.money) {
      if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value)) {
        _set(field, null, error: '请输入非负金额，最多两位小数');
        return;
      }
      // 拆分整数元和最多两位小数分，避免浮点舍入。
      final List<String> parts = value.split('.');
      // 整数分上限与数据库整数相同。
      final int? yuan = int.tryParse(parts[0]);
      // 不足两位的小数右侧补零。
      final int cents = yuan == null
          ? -1
          : yuan * 100 +
                int.parse(parts.length == 1 ? '0' : parts[1].padRight(2, '0'));
      _set(
        field,
        cents,
        error: cents < 0 || cents > 2147483647 ? '金额超出允许范围' : null,
      );
    } else {
      // 链接字段必须为 HTTP 或 HTTPS。
      final Uri? uri = field.name.endsWith('Url') ? Uri.tryParse(value) : null;
      _set(
        field,
        value,
        error: value.length > field.maxLength
            ? '最多${field.maxLength}字'
            : field.name.endsWith('Url') &&
                  (uri == null ||
                      !<String>['http', 'https'].contains(uri.scheme) ||
                      uri.host.isEmpty)
            ? '请输入 HTTP 或 HTTPS 链接'
            : null,
      );
    }
  }

  /// 每个字段使用统一上方标签，窄屏与大字号能自然换行。
  Widget _labelled(_Field field, Widget child) => Column(
    key: ValueKey<String>('assistant-result-field-${field.name}'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(field.label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: OmniSpacing.xs),
      child,
      if (_errors[field.name] != null)
        Padding(
          padding: const EdgeInsets.only(top: OmniSpacing.xs),
          child: Text(
            _errors[field.name]!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );

  /// 只读字段使用正常文字色，保持与编辑模式相同的字段位置。
  Widget _readOnly(_Field field, [String? text]) => InputDecorator(
    decoration: const InputDecoration(
      isDense: true,
      border: OutlineInputBorder(),
    ),
    child: SelectableText(
      (text ?? _display(field, _value(field))).isEmpty
          ? '未设置'
          : text ?? _display(field, _value(field)),
    ),
  );

  /// 组合日期和时间选择器，保留未修改的小时与分钟。
  Widget _dateField(_Field field) {
    // 当前业务日期。
    final DateTime? current = _date(field, _value(field));
    // 空日期只为打开选择器定位，不会自动提交为默认日期。
    final DateTime initial = current ?? DateTime.now();
    return Wrap(
      spacing: OmniSpacing.xs,
      runSpacing: OmniSpacing.xs,
      children: <Widget>[
        OmniDatePickerButton(
          key: ValueKey<String>('result-date-${field.name}'),
          value: current,
          initialDate: initial,
          firstDate: DateTime(1900),
          lastDate: DateTime(2200),
          label: current == null ? '选择日期' : _day(current),
          onChanged: widget.enabled
              ? (DateTime selected) {
                  // 日期与当前时刻组合后才转换为 UTC 保存。
                  final DateTime next = DateTime(
                    selected.year,
                    selected.month,
                    selected.day,
                    initial.hour,
                    initial.minute,
                    initial.second,
                    initial.millisecond,
                    initial.microsecond,
                  );
                  _set(
                    field,
                    field.kind == _Kind.day
                        ? _day(next)
                        : next.toUtc().toIso8601String(),
                  );
                }
              : null,
        ),
        if (field.kind == _Kind.instant && current != null)
          OmniTimePickerButton(
            value: TimeOfDay.fromDateTime(current),
            label: DateFormat('HH:mm').format(current),
            minuteStep: 1,
            onChanged: widget.enabled
                ? (TimeOfDay time) => _set(
                    field,
                    DateTime(
                      current.year,
                      current.month,
                      current.day,
                      time.hour,
                      time.minute,
                    ).toUtc().toIso8601String(),
                  )
                : null,
          ),
        if (!field.required && current != null)
          OmniIconButton(
            tooltip: '清除${field.label}',
            icon: const Icon(Icons.close, size: 18),
            onPressed: widget.enabled ? () => _set(field, null) : null,
          ),
      ],
    );
  }

  /// 根据固定定义创建可编辑控件。
  Widget _control(_Field field) {
    if (!widget.editing || !field.editable) return _readOnly(field);
    if (field.kind == _Kind.day || field.kind == _Kind.instant) {
      return _dateField(field);
    }
    if (field.kind == _Kind.choice || field.kind == _Kind.boolean) {
      // 布尔和枚举都使用明确选择，不把缺失值强制设置为 false。
      final Map<Object, String> options = field.kind == _Kind.boolean
          ? const <Object, String>{true: '是', false: '否'}
          : field.options;
      return OmniDropdownButtonFormField<Object>(
        key: ValueKey<String>('result-choice-${field.name}-$_revision'),
        initialValue: options.containsKey(_value(field))
            ? _value(field) as Object
            : null,
        hint: const Text('未设置'),
        items: options.entries
            .map(
              (MapEntry<Object, String> entry) => DropdownMenuItem<Object>(
                value: entry.key,
                child: Text(entry.value),
              ),
            )
            .toList(growable: false),
        onChanged: widget.enabled
            ? (Object? value) {
                if (value != null) _set(field, value);
              }
            : null,
      );
    }
    // 按字段缓存控制器，修改其他控件不重建输入草稿。
    final TextEditingController controller = _controllers.putIfAbsent(
      field.name,
      () => TextEditingController(
        text: _display(field, widget.record[field.name]),
      ),
    );
    return OmniTextFormField(
      key: ValueKey<String>('result-input-${field.name}'),
      controller: controller,
      readOnly: !widget.enabled,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
      ),
      minLines: field.kind == _Kind.multiline ? 3 : 1,
      maxLines: field.kind == _Kind.multiline ? null : 1,
      keyboardType: field.kind == _Kind.money
          ? const TextInputType.numberWithOptions(decimal: true)
          : field.kind == _Kind.integer
          ? TextInputType.number
          : field.kind == _Kind.multiline
          ? TextInputType.multiline
          : TextInputType.text,
      onChanged: (String value) => _textChanged(field, value),
    );
  }

  /// 仅展示服务端真实返回的分类或位置名称，不展示或编辑其身份。
  List<Widget> _relations() {
    // 领域关系字段与其中文标题。
    const Map<String, String> labels = <String, String>{
      'categories': '分类',
      'locations': '位置',
      'tags': '标签',
    };
    // 展示投影提供的是已解析名称列表，不能将相应 ID 列表作为回退。
    const Map<String, String> nameKeys = <String, String>{
      'categories': 'categoryNames',
      'locations': 'locationNames',
      'tags': 'tagNames',
    };
    // 真实名称存在时才增加关系字段。
    final List<Widget> result = <Widget>[];
    for (final MapEntry<String, String> entry in labels.entries) {
      // 关联对象可能包装在 category/location/tag 内。
      final dynamic values = widget.record[entry.key];
      // 只接受名称，不能将未知结构格式化成 JSON 或 UUID。
      final List<String> names = <String>[];
      // 单独的名称投影优先，兼容历史卡片没有完整关联对象的情况。
      final dynamic projected = widget.record[nameKeys[entry.key]];
      if (projected is List) {
        names.addAll(
          projected.whereType<String>().where(
            (String name) => name.trim().isNotEmpty,
          ),
        );
      }
      for (final dynamic item in values is List ? values : const <dynamic>[]) {
        if (item is! Map) continue;
        // MCP 与业务详情都可直接返回名称或关联对象。
        final dynamic nested =
            item['category'] ?? item['location'] ?? item['tag'];
        // 当前条目的安全显示名称。
        final dynamic name =
            item['name'] ?? (nested is Map ? nested['name'] : null);
        if (name is String && name.trim().isNotEmpty && !names.contains(name)) {
          names.add(name);
        }
      }
      if (names.isNotEmpty) {
        result.add(
          _labelled(
            _Field(entry.key, entry.value, editable: false),
            _readOnly(_Field(entry.key, entry.value), names.join('、')),
          ),
        );
      }
    }
    return result;
  }

  /// 分组内宽屏两列，长正文及窄屏大字号使用单列。
  Widget _group(List<_Field> fields, double width, bool twoColumns) => Wrap(
    spacing: OmniSpacing.md,
    runSpacing: OmniSpacing.md,
    children: fields
        .map(
          (_Field field) => SizedBox(
            width: twoColumns && field.kind != _Kind.multiline
                ? (width - OmniSpacing.md) / 2
                : width,
            child: _labelled(field, _control(field)),
          ),
        )
        .toList(growable: false),
  );

  /// 构建业务字段分组，隐藏所有内部同步元数据。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      // 按实际可用宽度与字体缩放选择列数。
      final bool twoColumns =
          constraints.maxWidth >= 560 &&
          MediaQuery.textScalerOf(context).scale(14) < 21;
      // 分组顺序与新增窗口一致，保留基本信息优先。
      final List<String> groups = _specs
          .map((_Field field) => field.group)
          .toSet()
          .toList(growable: false);
      // 真实关系名称使用只读字段。
      final List<Widget> relations = _relations();
      if (groups.isEmpty) return const Text('此记录暂不支持行内编辑');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String group in groups) ...<Widget>[
            if (group != groups.first)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: OmniSpacing.md),
                child: Divider(height: 1),
              ),
            Text(group, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: OmniSpacing.md),
            _group(
              _specs
                  .where((_Field field) => field.group == group)
                  .toList(growable: false),
              constraints.maxWidth,
              twoColumns,
            ),
          ],
          if (relations.isNotEmpty) ...<Widget>[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: OmniSpacing.md),
              child: Divider(height: 1),
            ),
            for (final Widget relation in relations)
              Padding(
                padding: const EdgeInsets.only(bottom: OmniSpacing.md),
                child: relation,
              ),
          ],
        ],
      );
    },
  );
}
