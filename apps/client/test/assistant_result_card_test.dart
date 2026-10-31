import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_result_card.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 认证代次可变，验证换服后旧面板不能保存。
class _Auth implements AuthRepository {
  /// 当前来源代次。
  int generation = 1;

  /// 固定仓储读取此代次。
  @override
  int get sessionGeneration => generation;

  /// 其他认证行为不属于本测试。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 真实卡片和表单只替换网络边界，不依赖已同步的本机业务数据库。
class _Repository extends AssistantRepository {
  /// 记录全部查询和精确保存负载。
  final List<({String method, Object? data})> calls = [];

  /// 可主动制造一次结果未知。
  bool loseResponse = false;

  /// 可主动制造明确并发冲突。
  bool conflict = false;

  /// 模拟当前运行的旧服务器不返回编辑版本，也没有保存接口。
  bool legacyServer = false;

  /// 模拟错误身份，旧版本兼容不能绕过归属对象校验。
  bool wrongIdentity = false;

  /// 模拟延迟查询，验证换服竞态。
  Completer<Map<String, dynamic>>? read;

  /// Hold each PATCH so its real in-flight presentation can be inspected.
  Completer<void>? saveGate;

  /// 最新服务器记录。
  Map<String, dynamic> record = <String, dynamic>{
    'id': 'todo-id',
    'title': '完成个人网站开发',
    'taskType': 'normal',
    'scheduledDate': '2026-10-25T00:00:00.000Z',
    'priorityQuadrant': 2,
    'description': '原有说明',
    'updatedAt': '2026-10-25T01:00:00.000Z',
    'sortOrder': 7168,
    'deletedAt': null,
  };

  /// 保存成功的回执，重复请求直接重放。
  Map<String, dynamic>? receipt;

  /// 当前版本摘要由服务端产生。
  String version = 'old-version';

  /// 创建合成仓储。
  _Repository(super.auth);

  /// 当前快照具有精确身份和编辑版本。
  Map<String, dynamic> get snapshot => <String, dynamic>{
    'module': 'todos',
    'id': wrongIdentity ? 'other-id' : 'todo-id',
    'record': Map<String, dynamic>.of(record),
    'label': record['title'],
    if (!legacyServer) 'editVersion': version,
    'serverSaved': true,
  };

  /// 合成查询与保存，不会调用真实服务器。
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    calls.add((method: method, data: data));
    if (method == 'GET') return read == null ? snapshot : await read!.future;
    await saveGate?.future;
    if (conflict) throw const AssistantApiFailure('记录已在其他位置修改，请刷新后再编辑', 409);
    if (receipt != null) return receipt!;
    // 模拟真正保存后响应丢失，客户端不能创建第二个操作身份。
    final Map<String, dynamic> payload = data! as Map<String, dynamic>;
    record = <String, dynamic>{
      ...record,
      ...payload['changes'] as Map<String, dynamic>,
      'updatedAt': '2026-10-25T01:01:00.000Z',
    };
    version = 'saved-version';
    receipt = snapshot;
    if (loseResponse) throw const AssistantApiFailure('连接中断', null);
    return receipt!;
  }
}

/// 单个真实对象回执，不包含模型生成的任意路由。
Map<String, dynamic> _card(
  _Repository repository, {
  String? operation = 'create',
}) => <String, dynamic>{
  'type': 'result',
  'result': <String, dynamic>{
    'entityRefs': <Object>[
      <String, dynamic>{
        'module': 'todos',
        'id': 'todo-id',
        'label': '完成个人网站开发',
        'operation': ?operation,
        'record': Map<String, dynamic>.of(repository.record),
      },
    ],
  },
};

/// 使用共享主题和可滚动空间承载实际卡片。
Future<void> _mount(
  WidgetTester tester,
  _Repository repository, {
  bool enabled = true,
  double width = 1000,
  double scale = 1,
  Future<void> Function()? beforeEdit,
  String? operation = 'create',
  VoidCallback? onUndo,
  String? undoExpiresAt,
  TargetPlatform platform = TargetPlatform.windows,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(brightness: Brightness.light)
          .copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey<String>('result-preview'),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AssistantResultCard(
              card: _card(repository, operation: operation),
              enabled: enabled,
              repository: repository,
              beforeEdit: beforeEdit,
              onUndo: onUndo,
              undoExpiresAt: undoExpiresAt,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 只点击真正可见的卡片按钮，覆盖长表单滚动。
Future<void> _tap(WidgetTester tester, String text) async {
  // 按统一按钮定位，避免与业务标签重复。
  final Finder button = find.widgetWithText(OmniButton, text);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// 进入表单编辑前先完成只读展开和服务器版本获取。
Future<void> _edit(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('assistant-result-toggle-todo-id')),
  );
  await tester.pumpAndSettle();
  await _tap(tester, '编辑');
}

/// 编辑字段使用实际输入控件，不通过外部直接修改差量。
Future<void> _title(WidgetTester tester, String value) async {
  // 表单统一字段身份。
  final Finder input = find.byKey(const ValueKey<String>('result-input-title'));
  await tester.ensureVisible(input);
  await tester.enterText(input, value);
  await tester.pumpAndSettle();
}

void main() {
  // Cover the Android change alongside the existing Windows loading contract.
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name}卡片保存与原请求重试保持各自加载呈现及防重', (tester) async {
      // Simulate a committed write whose first response is lost.
      final _Repository repository = _Repository(_Auth())..loseResponse = true;
      await _mount(
        tester,
        repository,
        platform: platform,
        width: 390,
        scale: 2,
      );
      await _edit(tester);
      await _title(tester, '异步保存标题');
      // Exercise both the first submission and its identity-preserving retry.
      for (final String label in <String>['保存', '重试保存']) {
        repository.saveGate = Completer<void>();
        addTearDown(() {
          if (!repository.saveGate!.isCompleted) {
            repository.saveGate!.complete();
          }
        });
        // Only settle before the request starts; Windows retains its spinner.
        final Finder action = find.widgetWithText(OmniButton, label);
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        // Android must retain this exact pre-submit button rectangle.
        final Rect before = tester.getRect(action);
        await tester.tap(action);
        await tester.pump();
        if (platform == TargetPlatform.android) {
          expect(tester.getRect(action), before);
          expect(find.byType(CircularProgressIndicator), findsNothing);
        } else {
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
        }
        // The pending request cannot be duplicated by a second native tap.
        final Finder busy = find.byWidgetPredicate(
          (Widget widget) => widget is OmniButton && widget.loading,
        );
        expect(tester.widget<OmniButton>(busy).onPressed, isNull);
        await tester.tap(busy);
        await tester.pump();
        expect(
          repository.calls.where((call) => call.method == 'PATCH'),
          hasLength(label == '保存' ? 1 : 2),
        );
        repository.saveGate!.complete();
        await tester.pumpAndSettle();
        if (label == '保存') {
          expect(find.text('保存结果尚未确认，请重试原请求核实结果'), findsOneWidget);
          repository.loseResponse = false;
        }
      }
      // Presentation changes must not change retry request identity or payload.
      final List<Object?> sent = repository.calls
          .where((call) => call.method == 'PATCH')
          .map((call) => call.data)
          .toList();
      expect(sent[0], sent[1]);
      expect(find.text('已保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('撤销到期无需重新请求即隐藏，窄屏双倍字号保持可用', (tester) async {
    // 有效期限只用于界面显隐，不替代服务端资格校验。
    final _Repository repository = _Repository(_Auth());
    await _mount(
      tester,
      repository,
      width: 320,
      scale: 2,
      onUndo: () {},
      undoExpiresAt: DateTime.now()
          .add(const Duration(seconds: 30))
          .toUtc()
          .toIso8601String(),
    );
    expect(find.text('撤销新增'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 31));
    expect(find.text('撤销新增'), findsNothing);
    expect(repository.calls, isEmpty);
  });

  testWidgets('撤销位于折叠结果标题右侧，点击不展开也不读取记录', (tester) async {
    // 当前任务提供唯一真实撤销回调。
    int undos = 0;
    // 结果卡仍然使用真实组件和共享主题。
    final _Repository repository = _Repository(_Auth());
    await _mount(tester, repository, onUndo: () => undos++);
    // 按钮与展开热区是两个独立兄弟节点。
    final Finder undo = find.byKey(
      const ValueKey<String>('assistant-result-undo-todo-id'),
    );
    expect(
      tester.getRect(undo).left,
      greaterThan(
        tester
                .getRect(
                  find.byKey(
                    const ValueKey<String>('assistant-result-toggle-todo-id'),
                  ),
                )
                .right -
            1,
      ),
    );
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(undos, 1);
    expect(find.text('任务名称'), findsNothing);
    expect(repository.calls, isEmpty);
  });

  if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
    setUpAll(() async {
      // 合成预览加载系统中文字体，不读取真实用户业务资料。
      final ByteData font = ByteData.sublistView(
        await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
      );
      for (final String family in <String>[
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'Roboto',
        'Ahem',
      ]) {
        // 覆盖测试默认字体，检查真实中文布局。
        final FontLoader loader = FontLoader(family)
          ..addFont(Future<ByteData>.value(font));
        await loader.load();
      }
      // 图标单独使用 SDK 字体，避免预览中的展开箭头变成方框。
      final ByteData icons = ByteData.sublistView(
        await File(
          'D:/program/code/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes(),
      );
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future<ByteData>.value(icons))).load();
    });
  }
  testWidgets('旧服务器无编辑版本仍显示最新记录，更新服务后重新读取可编辑保存', (tester) async {
    // 真实旧接口有同归属记录和更新时间，仅缺少新版编辑协议。
    final _Repository repository = _Repository(_Auth())..legacyServer = true;
    await _mount(tester, repository);
    repository.record['title'] = '服务器当前标题';
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-result-toggle-todo-id')),
    );
    await tester.pumpAndSettle();
    expect(find.text('服务器当前标题'), findsOneWidget);
    expect(find.text('无法核实记录版本，请重新读取'), findsNothing);
    expect(find.text('当前服务器尚不支持原地编辑，请更新 API 后重新读取'), findsOneWidget);
    expect(find.widgetWithText(OmniButton, '编辑'), findsNothing);
    expect(repository.calls.where((call) => call.method == 'PATCH'), isEmpty);
    // 用户明确更新服务器后，在同一面板重新读取即可获得编辑权限。
    repository.legacyServer = false;
    await _tap(tester, '重新读取');
    expect(find.text('当前服务器尚不支持原地编辑，请更新 API 后重新读取'), findsNothing);
    await _tap(tester, '编辑');
    await _title(tester, '更新后的标题');
    await _tap(tester, '保存');
    expect(find.text('执行结果 • 新增待办 • 更新后的标题'), findsOneWidget);
    expect(
      repository.calls.where((call) => call.method == 'PATCH'),
      hasLength(1),
    );
  });

  testWidgets('无版本的错误对象仍拒绝进入编辑，不将兼容当作跳过身份校验', (tester) async {
    // 其他对象不能覆盖当前面板，无论服务器是否支持新版本字段。
    final _Repository repository = _Repository(_Auth())
      ..legacyServer = true
      ..wrongIdentity = true;
    await _mount(tester, repository);
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-result-toggle-todo-id')),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法核实记录版本，请重新读取'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('result-input-title')),
      findsNothing,
    );
    expect(repository.calls.where((call) => call.method == 'PATCH'), isEmpty);
  });

  testWidgets('保存响应缺少版本不能误报成功，保留原请求等待核实', (tester) async {
    // 读接口正确返回版本，写响应发生协议缺失。
    final _Repository repository = _Repository(_Auth());
    await _mount(tester, repository);
    await _edit(tester);
    await _title(tester, '等待核实的标题');
    repository.legacyServer = true;
    await _tap(tester, '保存');
    expect(find.text('已保存'), findsNothing);
    expect(find.text('保存结果尚未确认，请重试原请求核实结果'), findsOneWidget);
    expect(find.widgetWithText(OmniButton, '重试保存'), findsOneWidget);
    expect(
      repository.calls.where((call) => call.method == 'PATCH'),
      hasLength(1),
    );
  });

  testWidgets('默认单行折叠，编辑保存只提交变化字段并更新摘要', (tester) async {
    // 模拟服务器独立于本机业务数据库。
    final _Repository repository = _Repository(_Auth());
    // 检查编辑及保存都等待同步边界。
    int checkpoints = 0;
    await _mount(
      tester,
      repository,
      beforeEdit: () async {
        checkpoints++;
      },
    );
    expect(find.text('执行结果 • 新增待办 • 完成个人网站开发'), findsOneWidget);
    expect(find.text('计划日期'), findsNothing);
    expect(repository.calls, isEmpty);
    await _edit(tester);
    expect(checkpoints, 1);
    expect(find.text('normal'), findsNothing);
    expect(find.textContaining('7168'), findsNothing);
    expect(find.text('普通任务'), findsOneWidget);
    expect(
      tester
          .widget<OmniButton>(find.widgetWithText(OmniButton, '保存'))
          .onPressed,
      isNull,
    );
    await _title(tester, '完成网站首页');
    await _tap(tester, '保存');
    // 人工保存不是新聊天消息，也没有附带未修改默认字段。
    final List<Object?> saved = repository.calls
        .where((call) => call.method == 'PATCH')
        .map((call) => call.data)
        .toList();
    expect(saved, hasLength(1));
    expect(
      saved.single,
      containsPair('changes', <String, dynamic>{'title': '完成网站首页'}),
    );
    expect(saved.single, containsPair('expectedVersion', 'old-version'));
    expect(checkpoints, 2);
    expect(find.text('执行结果 • 新增待办 • 完成网站首页'), findsOneWidget);
    expect(find.text('已保存'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('result-input-title')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消编辑只还原表单，旧回执不猜新增', (tester) async {
    // 旧回执缺少operation，使用中性摘要。
    final _Repository repository = _Repository(_Auth());
    await _mount(tester, repository, operation: null);
    expect(find.textContaining('已保存待办'), findsOneWidget);
    await _edit(tester);
    await _title(tester, '不应保存');
    await _tap(tester, '取消');
    expect(repository.calls.where((call) => call.method == 'PATCH'), isEmpty);
    expect(find.text('不应保存'), findsNothing);
    expect(find.textContaining('完成个人网站开发'), findsWidgets);
  });

  testWidgets('保存断流冻结草稿，显式重试原身份核实已保存结果', (tester) async {
    // 服务器已经保存但客户端没有拿到回执。
    final _Repository repository = _Repository(_Auth())..loseResponse = true;
    await _mount(tester, repository);
    await _edit(tester);
    await _title(tester, '已保存但响应丢失');
    await _tap(tester, '保存');
    expect(find.text('保存结果尚未确认，请重试原请求核实结果'), findsOneWidget);
    expect(
      tester
          .widget<OmniButton>(find.widgetWithText(OmniButton, '取消'))
          .onPressed,
      isNull,
    );
    await _tap(tester, '重试保存');
    // 两次请求身份、版本、字段完全相同。
    final List<Object?> sent = repository.calls
        .where((call) => call.method == 'PATCH')
        .map((call) => call.data)
        .toList();
    expect(sent, hasLength(2));
    expect(sent[0], sent[1]);
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('并发冲突保留草稿，显式重新载入才能继续编辑', (tester) async {
    // 后台先于本次保存发生了变化。
    final _Repository repository = _Repository(_Auth())..conflict = true;
    await _mount(tester, repository);
    await _edit(tester);
    await _title(tester, '我的草稿');
    repository.record['title'] = '另一设备的新标题';
    repository.version = 'another-version';
    await _tap(tester, '保存');
    expect(find.text('我的草稿'), findsOneWidget);
    expect(
      tester
          .widget<OmniButton>(find.widgetWithText(OmniButton, '保存'))
          .onPressed,
      isNull,
    );
    await _tap(tester, '重新载入');
    expect(find.text('我的草稿'), findsNothing);
    expect(find.text('另一设备的新标题'), findsOneWidget);
    expect(
      repository.calls.where((call) => call.method == 'PATCH'),
      hasLength(1),
    );
  });

  testWidgets('来源切换后迟到的读取不进入编辑', (tester) async {
    // 页面仍在，但认证仓储已经属于新来源。
    final _Auth auth = _Auth();
    // 请求延迟到换服之后才完成。
    final _Repository repository = _Repository(auth)
      ..read = Completer<Map<String, dynamic>>();
    await _mount(tester, repository);
    await tester.tap(
      find.byKey(const ValueKey<String>('assistant-result-toggle-todo-id')),
    );
    await tester.pump();
    auth.generation++;
    repository.read!.complete(repository.snapshot);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OmniButton>(find.widgetWithText(OmniButton, '编辑'))
          .onPressed,
      isNull,
    );
    expect(repository.calls.where((call) => call.method == 'PATCH'), isEmpty);
  });

  for (final double width in <double>[1000, 320]) {
    testWidgets('结果面板 ${width.toInt()} 宽度只读可展开，窄屏大字号无溢出', (tester) async {
      // 离线快照不能发出查询或写入。
      final _Repository repository = _Repository(_Auth());
      await _mount(
        tester,
        repository,
        enabled: false,
        width: width,
        scale: width == 320 ? 2 : 1,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('assistant-result-toggle-todo-id')),
      );
      await tester.pumpAndSettle();
      expect(find.text('重要不紧急'), findsOneWidget);
      expect(repository.calls, isEmpty);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('ASSISTANT_PREVIEW')) {
        await tester.runAsync(() async {
          // 保存真实Flutter像素用于中文布局核对。
          final RenderRepaintBoundary boundary = tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey<String>('result-preview')),
              );
          // 当前视口截图，不假装为真实用户数据。
          final ui.Image image = await boundary.toImage();
          // 无损预览输出。
          final ByteData? bytes = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory('build/assistant_previews').create(recursive: true);
          await File(
            'build/assistant_previews/result_form_${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
