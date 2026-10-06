import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/check_ui_style.dart';

/// 在隔离业务页面中扫描候选代码，并及时清理临时源码树。
Map<String, int> _scanSnippet(String snippet) {
  // 独立于实际仓库的最小目录树。
  final Directory root = Directory.systemTemp.createTempSync('omni-ui-guard-');
  try {
    // 模拟新增的业务页面。
    final File source = File(
      '${root.path}/lib/features/demo/presentation/demo.dart',
    );
    source.parent.createSync(recursive: true);
    Directory('${root.path}/lib/shared/ui').createSync(recursive: true);
    source.writeAsStringSync(snippet);
    return scanUiStyle(root);
  } finally {
    root.deleteSync(recursive: true);
  }
}

/// 验证样式约束能发现真实绕过入口，并忽略注释、文案和基础实现。
void main() {
  test('发现具名原生构造、颜色和圆角，忽略文案与样式工厂', () {
    // 与业务文件隔离的临时源码树。
    final Directory root = Directory.systemTemp.createTempSync(
      'omni-ui-guard-',
    );
    try {
      // 模拟新增业务页面。
      final File source = File(
        '${root.path}/lib/features/demo/presentation/demo.dart',
      );
      source.parent.createSync(recursive: true);
      Directory('${root.path}/lib/shared/ui').createSync(recursive: true);
      source.writeAsStringSync('''
// TextField() 只是注释。
/* Card() 也是注释。 */
final label = 'TextField()';
final description = "Switch()";
final button = IconButton.filled(onPressed: null, icon: icon);
final field = TextFormField();
final style = IconButton.styleFrom();
final color = Color(0xFF123456);
final shape = BorderRadius.circular(8);
''');
      // 基础组件可合法使用 Flutter 原语。
      File('${root.path}/lib/shared/ui/base.dart')
          .writeAsStringSync('final field = TextField();');
      // 实际扫描结果。
      final Map<String, int> result = scanUiStyle(root);
      expect(result, <String, int>{
        'lib/features/demo/presentation/demo.dart :: IconButton': 1,
        'lib/features/demo/presentation/demo.dart :: TextFormField': 1,
        'lib/features/demo/presentation/demo.dart :: Color(0xFF123456)': 1,
        'lib/features/demo/presentation/demo.dart :: BorderRadius.circular(8)':
            1,
      });
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('覆盖带导入前缀的按钮选择开关下拉和弹窗族', () {
    // 各控件族真实使用的调用形态，包含泛型、具名构造与前缀。
    const Map<String, String> cases = <String, String>{
      'ElevatedButton': 'final a = material.ElevatedButton.icon(onPressed: run, label: label, icon: icon);',
      'RawMaterialButton': 'final b = RawMaterialButton(onPressed: run);',
      'FloatingActionButton': 'final c = material.FloatingActionButton.extended(onPressed: run, label: label);',
      'CheckboxListTile': 'final d = material.CheckboxListTile.adaptive(value: checked, onChanged: select);',
      'Radio': 'final e = material.Radio<int>(value: 1);',
      'SwitchListTile': 'final f = material.SwitchListTile.adaptive(value: checked, onChanged: select);',
      'ToggleButtons':
          'final g = ToggleButtons(isSelected: selected, children: children);',
      'FilterChip': 'final h = material.FilterChip.elevated(label: label, selected: checked, onSelected: select);',
      'ActionChip': 'final i = ActionChip(label: label, onPressed: run);',
      'InputChip': 'final j = InputChip(label: label, onDeleted: run);',
      'DropdownMenu': 'final k = material.DropdownMenu<String>(dropdownMenuEntries: entries);',
      'DropdownButtonFormField': 'final l = DropdownButtonFormField<Map<String, int>>(items: items, onChanged: select);',
      'MenuItemButton':
          'final m = MenuItemButton(onPressed: run, child: label);',
      'SubmenuButton':
          'final n = SubmenuButton(menuChildren: children, child: label);',
      'Slider': 'final o = material.Slider.adaptive(value: fraction, onChanged: select);',
      'CupertinoButton': 'final p = cupertino.CupertinoButton.filled(onPressed: run, child: label);',
      'CupertinoCheckbox': 'final q = cupertino.CupertinoCheckbox(value: checked, onChanged: select);',
      'CupertinoRadio': 'final r = cupertino.CupertinoRadio<int>(value: 1);',
      'CupertinoSwitch': 'final s = cupertino.CupertinoSwitch(value: checked, onChanged: select);',
      'CupertinoTextField': 'final t = cupertino.CupertinoTextField.borderless(controller: controller);',
      'CupertinoSlidingSegmentedControl': 'final u = cupertino.CupertinoSlidingSegmentedControl<int>(children: children, onValueChanged: select);',
      'CupertinoDatePicker':
          'final v = cupertino.CupertinoDatePicker(onDateTimeChanged: select);',
      'CupertinoAlertDialog':
          'final w = cupertino.CupertinoAlertDialog(title: label);',
      'CupertinoActionSheetAction': 'final x = cupertino.CupertinoActionSheetAction(onPressed: run, child: label);',
      'showCupertinoModalPopup': 'final y = cupertino.showCupertinoModalPopup<int>(context: context, builder: builder);',
      'showDateRangePicker': 'final z = material.showDateRangePicker(context: context, firstDate: first, lastDate: last);',
      'showBottomSheet': 'final aa = material.showBottomSheet(context: context, builder: builder);',
      'DatePickerDialog':
          'final ab = DatePickerDialog(firstDate: first, lastDate: last);',
    };
    // 每种原生入口应独立登记一次，避免前缀或泛型造成漏检。
    final Map<String, int> expected = <String, int>{
      for (final String name in cases.keys)
        'lib/features/demo/presentation/demo.dart :: $name': 1,
    };
    expect(_scanSnippet(cases.values.join('\n')), expected);
  });

  test('保留布局焦点表单和分组原语，不误报统一控件或样式工厂', () {
    expect(
      _scanSnippet('''
final form = material.Form(child: FormField<int>(builder: builder));
final group = material.RadioGroup<int>(groupValue: value, onChanged: select, child: child);
final layout = Row(children: [Expanded(child: Padding(padding: inset, child: child))]);
final interaction = Focus(child: InkWell(onTap: run, child: GestureDetector(child: child)));
final tile = ListTile(title: label, trailing: OmniCheckbox(value: checked, onChanged: select));
final unified = OmniTextField(decoration: decoration);
final style = material.ElevatedButton . styleFrom(minimumSize: size);
final iconStyle = material.IconButton.styleFrom(foregroundColor: color);
final segment = ButtonSegment<String>(value: value, label: label);
final entry = DropdownMenuEntry<String>(value: value, label: label);
'''),
      isEmpty,
    );
  });
}
