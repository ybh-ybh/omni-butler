import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_result_form.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 真实业务记录夹具包含不得显示的同步元数据。
const Map<String, dynamic> _todo = <String, dynamic>{
  'id': 'private-record-id',
  'title': '完成个人网站开发',
  'taskType': 'normal',
  'scheduledDate': '2026-10-25T00:00:00.000Z',
  'priorityQuadrant': 2,
  'dueAt': null,
  'reminderAt': null,
  'description': '整理网站内容',
  'sortOrder': 7168,
  'createdAt': '2026-10-25T07:32:15.087Z',
};

/// 以实际主题挂载表单，支持窄屏与字体放大验证。
Future<void> _pump(
  WidgetTester tester, {
  String module = 'todos',
  Map<String, dynamic> record = _todo,
  bool editing = false,
  bool enabled = true,
  String? timeZone,
  double width = 800,
  double scale = 1,
  ValueChanged<Map<String, dynamic>?>? onChanged,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness: Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 1100),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: AssistantResultForm(
                module: module,
                record: record,
                editing: editing,
                enabled: enabled,
                timeZone: timeZone,
                onChanged: onChanged ?? (Map<String, dynamic>? _) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 业务表单回归覆盖语义展示、最小差量和窄屏交互。
void main() {
  for (final String field in <String>['isCompleted', 'completed']) {
    testWidgets('待办$field完成状态显示真实布尔值，兼容历史回执', (tester) async {
      await _pump(tester, record: <String, dynamic>{..._todo, field: false});
      expect(find.text('否'), findsOneWidget);
      await _pump(tester, record: <String, dynamic>{..._todo, field: true});
      expect(find.text('是'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('只读待办显示业务分组和枚举，隐藏内部身份与同步字段', (WidgetTester tester) async {
    await _pump(tester);
    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('任务详情'), findsOneWidget);
    expect(find.text('普通任务'), findsOneWidget);
    expect(find.text('重要不紧急'), findsOneWidget);
    expect(find.text('2026-10-25'), findsOneWidget);
    expect(find.text('private-record-id'), findsNothing);
    expect(find.text('7168'), findsNothing);
    expect(find.text('2026-10-25T07:32:15.087Z'), findsNothing);
    expect(find.byType(OmniTextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑只提交变更，空名称阻止保存，取消后恢复原始值', (WidgetTester tester) async {
    // 最近一次差量由外部保存按钮消费。
    Map<String, dynamic>? patch;
    await _pump(
      tester,
      editing: true,
      onChanged: (Map<String, dynamic>? value) => patch = value,
    );
    expect(patch, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('result-choice-taskType-0')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('result-input-title')),
      '完善个人网站',
    );
    await tester.pump();
    expect(patch, <String, dynamic>{'title': '完善个人网站'});
    await tester.enterText(
      find.byKey(const ValueKey<String>('result-input-title')),
      '',
    );
    await tester.pump();
    expect(patch, isNull);
    expect(find.text('请填写任务名称'), findsOneWidget);
    await _pump(
      tester,
      editing: false,
      onChanged: (Map<String, dynamic>? value) => patch = value,
    );
    expect(find.text('完成个人网站开发'), findsOneWidget);
    expect(patch, isEmpty);
    await _pump(
      tester,
      editing: true,
      onChanged: (Map<String, dynamic>? value) => patch = value,
    );
    expect(find.text('完成个人网站开发'), findsOneWidget);
    expect(patch, isEmpty);
  });

  testWidgets('物品金额精确换算为分并拒绝多余小数，关系保持只读', (WidgetTester tester) async {
    // 只变金额不应覆盖数量或分类。
    Map<String, dynamic>? patch;
    await _pump(
      tester,
      module: 'inventory',
      editing: true,
      record: <String, dynamic>{
        'name': '键盘',
        'quantity': 2,
        'status': 'inUse',
        'purchasePriceCents': 1234,
        'categories': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'hidden-category', 'name': '数码'},
        ],
        'locations': <Map<String, dynamic>>[
          <String, dynamic>{
            'location': <String, dynamic>{'name': '书房'},
          },
        ],
      },
      onChanged: (Map<String, dynamic>? value) => patch = value,
    );
    expect(find.text('12.34'), findsOneWidget);
    expect(find.text('数码'), findsOneWidget);
    expect(find.text('书房'), findsOneWidget);
    expect(find.text('hidden-category'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey<String>('result-input-purchasePriceCents')),
      '19.99',
    );
    await tester.pump();
    expect(patch, <String, dynamic>{'purchasePriceCents': 1999});
    await tester.enterText(
      find.byKey(const ValueKey<String>('result-input-purchasePriceCents')),
      '19.999',
    );
    await tester.pump();
    expect(patch, isNull);
    await tester.enterText(
      find.byKey(const ValueKey<String>('result-input-purchasePriceCents')),
      '',
    );
    await tester.pump();
    expect(patch, <String, dynamic>{'purchasePriceCents': null});
  });

  testWidgets('自然日相同不产生patch，修改自然日保持YYYY-MM-DD', (WidgetTester tester) async {
    // 日期对比不能把午夜UTC转为设备前一天。
    Map<String, dynamic>? patch;
    await _pump(
      tester,
      editing: true,
      onChanged: (Map<String, dynamic>? value) => patch = value,
    );
    // 复用实际选择器回调验证日期序列化。
    final OmniDatePickerButton picker = tester.widget<OmniDatePickerButton>(
      find.byKey(const ValueKey<String>('result-date-scheduledDate')),
    );
    picker.onChanged!(DateTime(2026, 10, 25));
    await tester.pump();
    expect(patch, isEmpty);
    picker.onChanged!(DateTime(2026, 10, 26));
    await tester.pump();
    expect(patch, <String, dynamic>{'scheduledDate': '2026-10-26'});
  });

  testWidgets('历史卡片名称投影正常显示而裸ID不出现在表单', (WidgetTester tester) async {
    await _pump(
      tester,
      module: 'notes',
      record: <String, dynamic>{
        'body': '学习记录',
        'dayKey': '2026-10-25',
        'isPinned': false,
        'tagNames': <String>['学习'],
        'tags': <String>['hidden-tag-uuid'],
        'categoryNames': <String>['日常'],
        'locationNames': <String>['书房'],
      },
    );
    expect(find.text('学习'), findsOneWidget);
    expect(find.text('日常'), findsOneWidget);
    expect(find.text('书房'), findsOneWidget);
    expect(find.text('hidden-tag-uuid'), findsNothing);
  });

  testWidgets('保存期间文本和日期编辑被禁用', (WidgetTester tester) async {
    await _pump(tester, editing: true, enabled: false);
    // 文本仍可读，但无法继续修改正在提交的草稿。
    final OmniTextFormField title = tester.widget<OmniTextFormField>(
      find.byKey(const ValueKey<String>('result-input-title')),
    );
    // 日期入口使用同一忙碌锁。
    final OmniDatePickerButton date = tester.widget<OmniDatePickerButton>(
      find.byKey(const ValueKey<String>('result-date-scheduledDate')),
    );
    expect(title.readOnly, isTrue);
    expect(date.onChanged, isNull);
  });

  testWidgets('时间编辑附带明确IANA时区，缺少时区时禁止保存', (WidgetTester tester) async {
    // 时间记录必须保留服务端业务时区。
    Map<String, dynamic>? patch;
    await _pump(
      tester,
      module: 'time',
      editing: true,
      record: <String, dynamic>{
        'activity': '开发',
        'startedAt': '2026-10-25T08:00:00Z',
        'endedAt': '2026-10-25T09:00:00Z',
      },
      onChanged: (Map<String, dynamic>? value) => patch = value,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('result-input-activity')),
      '完善网站',
    );
    await tester.pump();
    expect(patch, isNull);
    expect(find.text('缺少记录时区，请刷新后重试'), findsOneWidget);
    await _pump(
      tester,
      module: 'time',
      editing: true,
      timeZone: 'Asia/Shanghai',
      record: <String, dynamic>{
        'activity': '开发',
        'startedAt': '2026-10-25T08:00:00Z',
        'endedAt': '2026-10-25T09:00:00Z',
      },
      onChanged: (Map<String, dynamic>? value) => patch = value,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('result-input-activity')),
      '整理网站',
    );
    await tester.pump();
    expect(patch, <String, dynamic>{
      'activity': '整理网站',
      'timeZone': 'Asia/Shanghai',
    });
  });

  for (final String module in <String>[
    'todos',
    'inventory',
    'time',
    'notes',
    'quotes',
    'memberships',
    'events',
  ]) {
    testWidgets('$module在窄屏大字号下使用单列且无溢出', (WidgetTester tester) async {
      await _pump(
        tester,
        module: module,
        editing: true,
        width: 380,
        scale: 2,
        record: <String, dynamic>{
          ..._todo,
          'name': '中文长名称示例',
          'quantity': 2,
          'body': '笔记内容',
          'content': '语录内容',
          'activity': '整理网站',
          'status': 'inUse',
        },
      );
      expect(tester.takeException(), isNull);
      if (module == 'todos') {
        // 任务类型在名称下方，避免大字号时挤进两列。
        final Rect title = tester.getRect(
          find.byKey(const ValueKey<String>('assistant-result-field-title')),
        );
        // 只读类型保持同样的业务字段位置。
        final Rect taskType = tester.getRect(
          find.byKey(const ValueKey<String>('assistant-result-field-taskType')),
        );
        expect(taskType.top, greaterThan(title.bottom));
        expect(taskType.left, title.left);
      }
    });
  }
}
