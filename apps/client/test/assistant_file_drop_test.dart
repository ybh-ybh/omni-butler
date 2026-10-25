import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_attachments.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_attachment_widgets.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_file_drop_area.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 固定认证代次，测试不连接真实服务器。
class _Auth implements AuthRepository {
  /// 当前会话代次。
  @override
  int get sessionGeneration => 1;

  /// 流取消仍使用正式令牌类型。
  @override
  CancelToken createSessionStreamToken(int generation) => CancelToken();

  /// 未使用的认证操作不能隐式访问系统。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 新聊天拖放必须停留在本机，任何网络上传都算失败。
class _Repository extends AssistantRepository {
  /// 创建只读内存仓储。
  _Repository() : super(_Auth());

  /// 新草稿不应请求网络接口。
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async => throw StateError('草稿不得发起 $method $path');
}

/// 从真实插件通道投递 Windows 原生事件，覆盖插件坐标与事件顺序。
Future<void> _nativeDrag(String method, Object? arguments) async {
  ServicesBinding.instance.channelBuffers.push(
    'desktop_drop',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (ByteData? bytes) {},
  );
}

/// 查找稳定控件身份。
Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// 文件 IO 在真实异步区执行，模拟插件退出后同步交付的文件清单。
void _deliverFiles(WidgetTester tester, List<String> paths) {
  tester.widget<DropTarget>(_key('assistant-file-drop-target')).onDragDone!(
    DropDoneDetails(
      files: paths.map((String path) => DropItemFile(path)).toList(),
      localPosition: const Offset(200, 150),
      globalPosition: const Offset(200, 150),
    ),
  );
}

/// 本地草稿卡片，不包含服务器地址。
Map<String, dynamic> _draft(
  String id, {
  String kind = 'document',
  String status = 'local',
  String? localPath,
}) => <String, dynamic>{
  'id': id,
  'name': kind == 'image' ? '截图.png' : '很长的项目说明和后续安排文档.pdf',
  'kind': kind,
  'status': status,
  'size': 100,
  'localPath': ?localPath,
};

/// 测试使用隔离目录与真实附件控制器，通过重建验证异步门禁。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 插件通道在所有测试之外注册，避免绑定首个测试的虚拟异步区。
  DesktopDrop.instance.init();
  // 当前测试独享的临时目录。
  late Directory directory;
  // 当前真实附件控制器。
  late AssistantAttachments manager;
  // 模拟未知提交或执行阶段冻结。
  late bool frozen;
  // 手动同步界面与控制器变化。
  late ChangeNotifier changes;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('desktop_drop'),
          (MethodCall call) async =>
              call.method == 'initializeView' ? true : null,
        );
    directory = await Directory.systemTemp.createTemp('assistant-drop-');
    frozen = false;
    changes = ChangeNotifier();
    manager =
        AssistantAttachments(
            repository: _Repository(),
            scope: 'drop-test',
            ensureConversation: () async => null,
            changed: changes.notifyListeners,
            persist: () async {},
            frozen: () => frozen,
            directoryProvider: () async =>
                Directory('${directory.path}/private'),
          )
          ..capabilities = <String, dynamic>{
            'enabled': true,
            'extensions': <String>['txt', 'png', 'pdf'],
            'maxFiles': 5,
          };
  });
  tearDown(() async {
    manager.dispose();
    changes.dispose();
    await directory.delete(recursive: true);
  });

  /// 固定投放区域，其他区域保留空白用于验证离开边界。
  Future<void> pumpArea(WidgetTester tester, {bool enabled = true}) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: changes,
            builder: (BuildContext context, Widget? child) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                height: 400,
                child: AssistantFileDropArea(
                  attachments: manager,
                  enabled: enabled,
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('系统拖入、移出和取消只在对话区域显示提示', (WidgetTester tester) async {
    await pumpArea(tester);
    await _nativeDrag('entered', <double>[200, 150]);
    await tester.pump();
    expect(find.text('松开即可添加文件'), findsOneWidget);
    await _nativeDrag('updated', <double>[650, 150]);
    await tester.pump();
    expect(_key('assistant-file-drop-overlay'), findsNothing);
    await _nativeDrag('updated', <double>[200, 150]);
    await tester.pump();
    expect(_key('assistant-file-drop-overlay'), findsOneWidget);
    await _nativeDrag('exited', null);
    await tester.pump();
    expect(_key('assistant-file-drop-overlay'), findsNothing);
    expect(manager.drafts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实视图绑定成功前禁用拖放，晚到回执不更新已关闭页面', (WidgetTester tester) async {
    // 原生尚未返回注册事实，不能先显示可投放提示。
    final Completer<bool> bound = Completer<bool>();
    // 保留绑定时收到的真实视图身份。
    int? boundView;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('desktop_drop'), (
          MethodCall call,
        ) async {
          boundView = call.arguments as int;
          return bound.future;
        });
    await pumpArea(tester);
    expect(
      boundView,
      View.of(tester.element(find.byType(AssistantFileDropArea))).viewId,
    );
    expect(
      tester.widget<DropTarget>(_key('assistant-file-drop-target')).enable,
      isFalse,
    );
    await _nativeDrag('entered', <double>[200, 150]);
    await tester.pump();
    expect(_key('assistant-file-drop-overlay'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    bound.complete(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('原生松开批量复制文件到私有草稿，不创建聊天、不上传', (WidgetTester tester) async {
    // 源文件仅来自测试目录，原文件不能被移动或改写。
    final File first = File('${directory.path}/会议.txt')
      ..writeAsStringSync('会议内容');
    // 第二份文件用于核对有序附件清单。
    final File second = File('${directory.path}/计划.txt')
      ..writeAsStringSync('计划内容');
    await pumpArea(tester);
    await _nativeDrag('entered', <double>[200, 150]);
    await tester.pump();
    await _nativeDrag('exited', null);
    await tester.runAsync(() async {
      _deliverFiles(tester, <String>[first.path, second.path]);
      // 等待真实本机复制与持久步骤完成，失败不会无限等待。
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((manager.drafts.length != 2 || manager.adding) &&
          manager.error == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(manager.error, isNull);
    expect(
      manager.drafts.map((Map<String, dynamic> item) => item['name']),
      <String>['会议.txt', '计划.txt'],
    );
    expect(
      manager.drafts.every(
        (Map<String, dynamic> item) =>
            item['status'] == 'local' && item['conversationId'] == null,
      ),
      isTrue,
    );
    expect(_key('assistant-file-drop-overlay'), findsNothing);
    await tester.runAsync(() async {
      expect(await first.readAsString(), '会议内容');
      expect(
        await File(manager.drafts.first['localPath'] as String).readAsString(),
        '会议内容',
      );
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('禁用、未知提交冻结、草稿切换和弹窗均拒绝拖放', (WidgetTester tester) async {
    await pumpArea(tester, enabled: false);
    await _nativeDrag('entered', <double>[200, 150]);
    await tester.pump();
    expect(_key('assistant-file-drop-overlay'), findsNothing);
    await pumpArea(tester);
    await _nativeDrag('entered', <double>[200, 150]);
    await tester.pump();
    frozen = true;
    changes.notifyListeners();
    await tester.pump();
    expect(_key('assistant-file-drop-overlay'), findsNothing);
    await _nativeDrag('performOperation', <String>[
      '${directory.path}/unread.txt',
    ]);
    frozen = false;
    changes.notifyListeners();
    await tester.pump();
    await _nativeDrag('entered', <double>[200, 150]);
    await tester.pump();
    manager.restore(const <Object>[]);
    changes.notifyListeners();
    await tester.pump();
    await _nativeDrag('performOperation', <String>[
      '${directory.path}/unread.txt',
    ]);
    await tester.pump();
    expect(manager.drafts, isEmpty);
    // 原生拖放目标在模态窗口后必须停止接收。
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(AssistantFileDropArea)),
        builder: (BuildContext context) =>
            const AlertDialog(content: Text('对话框')),
      ),
    );
    await tester.pumpAndSettle();
    await _nativeDrag('entered', <double>[200, 150]);
    await tester.pump();
    expect(_key('assistant-file-drop-overlay'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件夹及不支持的扩展名不进入草稿', (WidgetTester tester) async {
    await pumpArea(tester);
    await _nativeDrag('entered', <double>[200, 150]);
    await _nativeDrag('exited', null);
    await tester.runAsync(() async {
      _deliverFiles(tester, <String>[directory.path]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('请拖入文件，暂不支持文件夹'), findsOneWidget);
    // 文件类型限制继续由正式控制器给出用户可读错误。
    final File? unsupported = await tester.runAsync(
      () => File('${directory.path}/程序.exe').writeAsString('unsupported'),
    );
    await _nativeDrag('entered', <double>[200, 150]);
    await _nativeDrag('exited', null);
    await tester.runAsync(() async {
      _deliverFiles(tester, <String>[unsupported!.path]);
      // 等待控制器错误进入稳定状态。
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (manager.error == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(manager.error, contains('请选择支持的'));
    expect(manager.drafts, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('图片缩略图与文档底栏，鼠标和键盘显现关闭并可移除', (WidgetTester tester) async {
    // 用真实可解码的图片验证私有本机缩略图，不请求 URL。
    final File image = File('${directory.path}/preview.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
        ),
      );
    manager.restore(<Object>[
      _draft('image', kind: 'image', localPath: image.path),
      _draft('document'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: changes,
            builder: (BuildContext context, Widget? child) => Padding(
              padding: const EdgeInsets.all(24),
              child: AssistantAttachmentDrafts(
                attachments: manager,
                settings: null,
                desktopPreview: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(_key('assistant-draft-image-image'), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('很长的项目说明和后续安排文档.pdf')).overflow,
      TextOverflow.ellipsis,
    );
    expect(
      tester
          .widget<AnimatedOpacity>(_key('assistant-draft-mask-image'))
          .opacity,
      0,
    );
    // 真实鼠标悬停覆盖卡片而非只覆盖图标。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(750, 500));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_key('assistant-draft-hover-image')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('截图.png · 100 B · 待发送', findRichText: true), findsNothing);
    expect(find.text('这些附件需要视觉模型，请手动选择并测试支持图片的模型'), findsNothing);
    expect(
      tester
          .widget<AnimatedOpacity>(_key('assistant-draft-mask-image'))
          .opacity,
      1,
    );
    expect(
      tester.getTopRight(_key('assistant-draft-remove-image')).dx,
      closeTo(
        tester.getTopRight(_key('assistant-draft-hover-image')).dx - 4,
        1,
      ),
    );
    await mouse.moveTo(const Offset(750, 500));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedOpacity>(_key('assistant-draft-mask-image'))
          .opacity,
      0,
    );
    // 不依赖鼠标也能通过 Tab 找到并移除附件。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedOpacity>(_key('assistant-draft-mask-image'))
          .opacity,
      1,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(manager.ids, <String>['document']);
    await mouse.moveTo(
      tester.getCenter(_key('assistant-draft-hover-document')),
    );
    await tester.pumpAndSettle();
    await tester.tap(_key('assistant-draft-remove-document'));
    await tester.pumpAndSettle();
    expect(manager.drafts, isEmpty);
    expect(tester.takeException(), isNull);
    // Windows 文件系统回调需要真实时钟与虚拟微任务交替推进，等删除彻底结束。
    for (int attempt = 0; attempt < 30 && manager.transferring; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(manager.transferring, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });

  testWidgets('深色320宽双倍字号保留失败重试，冻结时禁止移除', (WidgetTester tester) async {
    manager.restore(<Object>[
      _draft('failed', status: 'failed'),
      _draft(
        'image',
        kind: 'image',
        localPath: '${directory.path}/missing.png',
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.dark)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SizedBox(
              width: 280,
              child: AssistantAttachmentDrafts(
                attachments: manager,
                settings: null,
                desktopPreview: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_key('assistant-draft-retry-failed'), findsOneWidget);
    frozen = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness: Brightness.dark)
            .copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: AssistantAttachmentDrafts(
            attachments: manager,
            settings: null,
            desktopPreview: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OmniIconButton>(_key('assistant-draft-remove-failed'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OmniIconButton>(_key('assistant-draft-retry-failed'))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
