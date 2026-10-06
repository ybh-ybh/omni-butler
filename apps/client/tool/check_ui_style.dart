import 'dart:convert';
import 'dart:io';

/// 检查业务界面是否增加绕过统一控件或硬编码视觉值的入口。
void main(List<String> arguments) {
  // 客户端根目录；支持从仓库根或客户端目录执行。
  final Directory root = Directory('lib').existsSync()
      ? Directory.current
      : Directory('apps/client').absolute;
  // 明确审查后的逐文件例外，不允许整目录放行。
  final File exceptionFile = File('${root.path}/tool/ui_style_exceptions.json');
  // 扫描所得的构造器与视觉值使用次数。
  final Map<String, int> actual = scanUiStyle(root);
  if (arguments.contains('--report')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(actual));
    return;
  }
  // 已记录的受控例外及解释。
  final Map<String, dynamic> exceptions =
      jsonDecode(exceptionFile.readAsStringSync()) as Map<String, dynamic>;
  // 本轮检查发现的问题。
  final List<String> errors = <String>[];
  for (final MapEntry<String, int> entry in actual.entries) {
    // 当前入口允许存在的次数。
    final Map<String, dynamic>? allowed =
        exceptions[entry.key] as Map<String, dynamic>?;
    if (allowed == null || entry.value > (allowed['count'] as int)) {
      errors.add(
        '${entry.key}: ${entry.value} 处，超出已审查例外 ${allowed?['count'] ?? 0}',
      );
    }
  }
  for (final MapEntry<String, dynamic> entry in exceptions.entries) {
    // 每条例外都必须有明确原因，并随实现清理。
    final Map<String, dynamic> allowed = entry.value as Map<String, dynamic>;
    if ((allowed['reason'] as String? ?? '').trim().isEmpty) {
      errors.add('${entry.key}: 缺少例外原因');
    }
    if ((actual[entry.key] ?? 0) < (allowed['count'] as int)) {
      errors.add('${entry.key}: 例外已减少，请同步收紧记录');
    }
  }
  if (errors.isNotEmpty) {
    stderr.writeln(errors.join('\n'));
    exitCode = 1;
    return;
  }
  stdout.writeln('UI style check passed: ${actual.length} 项受控例外，无新增绕过入口。');
}

/// 扫描业务、共享工具界面和布局；基础组件实现可使用 Flutter 底层控件。
Map<String, int> scanUiStyle(Directory root) {
  // 仅登记直接带原生外观的控件与浮层入口；Form、RadioGroup、InkWell 等行为和布局原语不在此列。
  const List<String> nativeControls = <String>[
    // 文本编辑与表单字段。
    'TextField',
    'TextFormField',
    'CupertinoTextField',
    'CupertinoTextFormFieldRow',
    // 常用按钮与平台具名变体。
    'TextButton', 'OutlinedButton', 'FilledButton', 'ElevatedButton',
    'RawMaterialButton', 'IconButton', 'FloatingActionButton',
    'BackButton', 'CloseButton', 'DrawerButton', 'EndDrawerButton',
    'CupertinoButton', 'CupertinoDialogAction', 'CupertinoActionSheetAction',
    // 单选、复选、开关与分段选择，保留 RadioGroup 自身的键盘协调能力。
    'Checkbox', 'CheckboxListTile', 'Radio', 'RadioListTile',
    'Switch', 'SwitchListTile', 'ToggleButtons', 'SegmentedButton',
    'CupertinoCheckbox', 'CupertinoRadio', 'CupertinoSwitch',
    'CupertinoSegmentedControl', 'CupertinoSlidingSegmentedControl',
    // 具有独立状态和外观的标签、菜单与下拉控件。
    'Chip', 'RawChip', 'ChoiceChip', 'FilterChip', 'ActionChip', 'InputChip',
    'DropdownButton', 'DropdownButtonFormField', 'DropdownMenu',
    'DropdownMenuFormField', 'PopupMenuButton', 'PopupMenuItem',
    'MenuItemButton', 'SubmenuButton',
    // 滑块及滚轮式选择器。
    'Slider', 'RangeSlider', 'CupertinoSlider', 'CupertinoPicker',
    'CupertinoDatePicker', 'CupertinoTimerPicker',
    // 卡片、弹窗表面及标准选择对话框。
    'Card', 'AlertDialog', 'Dialog', 'BottomSheet',
    'DatePickerDialog', 'DateRangePickerDialog', 'TimePickerDialog',
    'CupertinoAlertDialog', 'CupertinoActionSheet',
    // 显示浮层的函数也可通过导入前缀调用，按入口名称统一登记。
    'showMenu', 'showDialog', 'showGeneralDialog', 'showModalBottomSheet',
    'showBottomSheet',
    'showDatePicker',
    'showDateRangePicker',
    'showTimePicker',
    'showCupertinoDialog', 'showCupertinoModalPopup',
  ];
  // 前缀后的词边界仍能识别 material.Radio<int>.adaptive 等具名调用。
  final RegExp constructors = RegExp(
    '\\b(${nativeControls.join('|')})'
    r'\s*(?:<[^;()]+?>\s*)?(?:\.\s*(\w+)\s*)?\(',
  );
  // 新增硬编码颜色与圆角也必须经逐文件审查。
  final RegExp visualLiterals = RegExp(
    r'\bColor\(0x[0-9a-fA-F]+\)|\bBorderRadius\.circular\(\s*\d+(?:\.\d+)?\s*\)',
  );
  // 字符串和注释不代表真实构造调用。
  final RegExp commentsAndStrings = RegExp(
    r'''//[^\n]*|/\*[\s\S]*?\*/|r?"""[\s\S]*?"""|r?\x27\x27\x27[\s\S]*?\x27\x27\x27|r?"(?:\\.|[^"\\])*"|r?'(?:\\.|[^'\\])*' '''
        .trimRight(),
    multiLine: true,
  );
  // 已发现入口按路径排序，保证输出稳定。
  final Map<String, int> counts = <String, int>{};
  for (final String relative in <String>['lib/features', 'lib/shared']) {
    // 本轮扫描的目录。
    final Directory directory = Directory('${root.path}/$relative');
    for (final File file
        in directory.listSync(recursive: true).whereType<File>()) {
      // 使用仓库相对路径记录例外。
      final String path = file.path
          .substring(root.path.length + 1)
          .replaceAll('\\', '/');
      if (!path.endsWith('.dart') ||
          path.startsWith('lib/shared/ui/') ||
          (path.startsWith('lib/features/') &&
              !path.contains('/presentation/'))) {
        continue;
      }
      // 仅保留可执行源码，避免文案与注释造成误报。
      final String source = file.readAsStringSync().replaceAll(
        commentsAndStrings,
        ' ',
      );
      for (final RegExpMatch match in constructors.allMatches(source)) {
        // 样式工厂是既有语义变体配置，不是绕过封装的控件实例。
        if (match.group(2) == 'styleFrom') continue;
        // 路径与构造类型共同构成受控入口。
        final String key = '$path :: ${match.group(1)}';
        counts.update(key, (int value) => value + 1, ifAbsent: () => 1);
      }
      for (final RegExpMatch match in visualLiterals.allMatches(source)) {
        // 视觉字面量保留具体数值，避免替换后悄悄沿用许可。
        final String key =
            '$path :: ${match.group(0)!.replaceAll(RegExp(r'\s+'), '')}';
        counts.update(key, (int value) => value + 1, ifAbsent: () => 1);
      }
    }
  }
  return Map<String, int>.fromEntries(
    counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}
