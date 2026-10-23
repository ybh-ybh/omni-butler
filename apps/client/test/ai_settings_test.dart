import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/settings/data/ai_settings_repository.dart';
import 'package:omni_butler/features/settings/presentation/ai_settings_section.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 请求调用记录，不记录真实供应商密钥。
typedef _Request = ({
  String method,
  String path,
  Object? data,
  Duration? receiveTimeout,
});

/// 认证网络边界替身，避免访问安全存储和外部服务。
class _AiAuth implements AuthRepository {
  /// 可模拟服务器切换的代次。
  int generation = 1;

  /// 测试请求记录。
  final List<_Request> requests = <_Request>[];

  /// 每条请求的受控处理函数。
  Future<Map<String, dynamic>> Function(_Request request)? handler;

  /// 当前服务器代次。
  @override
  int get sessionGeneration => generation;

  /// 验证仓储绑定的代次并返回受控 JSON。
  @override
  Future<Response<T>> authorizedRequestForGeneration<T>(
    int generation,
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
    Duration? receiveTimeout,
    bool preserveTransportErrors = false,
    CancelToken? cancelToken,
  }) async {
    if (generation != this.generation) throw const ApiFailure('同步会话已变更');
    // 当前调用的最小请求信息。
    final _Request request = (
      method: method,
      path: path,
      data: data,
      receiveTimeout: receiveTimeout,
    );
    requests.add(request);
    // 按测试场景返回快照或错误。
    final Map<String, dynamic> result =
        await handler?.call(request) ?? _snapshot();
    if (generation != this.generation) throw const ApiFailure('同步会话已变更');
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      data: result as T,
    );
  }

  /// 与测试无关的认证能力不得隐式执行。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 固定同步会话，独立验证设置功能。
class _AiAuthController extends AuthController {
  /// 当前测试是否连接服务器。
  final bool connected;

  /// 创建固定认证状态。
  _AiAuthController({this.connected = true});

  /// 返回当前会话，不访问平台存储。
  @override
  Future<SyncSession?> build() async => connected
      ? const SyncSession(
          identity: SyncIdentity(id: 'owner-test'),
          apiBaseUrl: 'https://sync.example.com/api',
          isOffline: false,
        )
      : null;
}

/// 创建带密钥掩码的安全后端快照。
Map<String, dynamic> _snapshot({
  int revision = 1,
  bool enabled = false,
  bool profile = true,
  bool secondProfile = false,
}) => <String, dynamic>{
  'revision': revision,
  'activeProfileId': profile ? 'profile-1' : null,
  'notePolishEnabled': enabled,
  'profiles': <Map<String, dynamic>>[
    if (profile)
      <String, dynamic>{
        'id': 'profile-1',
        'name': '测试智谱',
        'provider': 'zhipu',
        'baseUrl': 'https://open.bigmodel.cn/api/v1',
        'model': 'glm-5.3',
        'hasApiKey': true,
        'maskedApiKey': '••••test',
      },
    if (secondProfile)
      <String, dynamic>{
        'id': 'profile-2',
        'name': '测试 DeepSeek',
        'provider': 'deepseek',
        'baseUrl': 'https://api.deepseek.com',
        'model': 'deepseek-flash',
        'hasApiKey': true,
        'maskedApiKey': '••••next',
      },
  ],
};

/// 只替换认证边界，仓储、控制器与页面使用正式实现。
Future<void> _pump(
  WidgetTester tester,
  _AiAuth auth, {
  bool connected = true,
  TargetPlatform platform = TargetPlatform.windows,
  double width = 960,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        authControllerProvider.overrideWith(
          () => _AiAuthController(connected: connected),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: platform),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(child: AiSettingsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 验证后端配置边界、错误恢复和两端表单行为。
void main() {
  testWidgets('模型配置逐行排列，新增在右上、操作靠右且当前状态无边框', (WidgetTester tester) async {
    // 两套配置验证行间隔和各操作所属对象，不读取真实配置。
    final _AiAuth auth = _AiAuth()
      ..handler = (_Request request) async => _snapshot(secondProfile: true);
    await _pump(tester, auth);
    // 新增按钮与分组标题同处顶部，右边缘与各配置操作对齐。
    final Rect add = tester.getRect(find.widgetWithText(OmniButton, '新增模型配置'));
    // 第一套配置的完整详情区域。
    final Rect first = tester.getRect(find.textContaining('glm-5.3\n'));
    // 第二套配置的完整详情区域。
    final Rect second = tester.getRect(find.textContaining('deepseek-flash\n'));
    // 每项右侧的编辑按钮位置。
    final Rect edit = tester.getRect(
      find.widgetWithText(OmniButton, '编辑').first,
    );
    expect(add.bottom, lessThan(tester.getTopLeft(find.text('测试智谱')).dy));
    expect(edit.left, greaterThan(first.right));
    expect(edit.center.dy, inInclusiveRange(first.top - 30, first.bottom));
    expect(second.top, greaterThan(first.bottom));
    expect(
      tester.getRect(find.widgetWithText(OmniButton, '删除').first).right,
      closeTo(add.right, 0.1),
    );
    expect(
      tester.getRect(find.widgetWithText(OmniButton, '删除').last).right,
      closeTo(add.right, 0.1),
    );
    expect(find.textContaining('保存多套服务配置'), findsNothing);
    // 当前配置保留禁用语义，实际按钮样式无可见边框。
    final OmniButton current = tester.widget<OmniButton>(
      find.widgetWithText(OmniButton, '当前使用'),
    );
    expect(current.onPressed, isNull);
    // 渲染后的文字按钮禁用状态不得残留描边。
    final TextButton currentButton = tester.widget<TextButton>(
      find.descendant(
        of: find.widgetWithText(OmniButton, '当前使用'),
        matching: find.byType(TextButton),
      ),
    );
    expect(
      currentButton.style!.side!
          .resolve(<WidgetState>{WidgetState.disabled})!
          .color
          .a,
      0,
    );
    await tester.tap(find.text('设为当前'));
    expect(
      auth.requests
          .singleWhere((_Request request) => request.method == 'PUT')
          .data,
      <String, dynamic>{
        'revision': 1,
        'activeProfileId': 'profile-2',
        'notePolishEnabled': false,
      },
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏双倍字号保留两套配置及完整操作，不溢出', (WidgetTester tester) async {
    // 窄屏测试仍使用两套完整的合成配置。
    final _AiAuth auth = _AiAuth()
      ..handler = (_Request request) async => _snapshot(secondProfile: true);
    await _pump(
      tester,
      auth,
      platform: TargetPlatform.android,
      width: 320,
      scale: 2,
    );
    expect(find.text('新增模型配置'), findsOneWidget);
    expect(find.textContaining('保存多套服务配置'), findsNothing);
    expect(find.text('编辑'), findsNWidgets(2));
    expect(find.text('删除'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('编辑').last);
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '测试 DeepSeek'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('更新空密钥保留原值，移除和测试均使用明确请求', () async {
    // 固定网络边界与正式仓储。
    final _AiAuth auth = _AiAuth();
    // 当前服务器的配置仓储。
    final AiSettingsRepository repository = AiSettingsRepository(auth);
    await repository.saveProfile(
      revision: 4,
      id: 'profile-1',
      name: ' 配置 ',
      provider: 'zhipu',
      baseUrl: ' https://model.example.com/v1 ',
      model: ' model ',
      apiKey: '',
    );
    expect(auth.requests.single.data, <String, dynamic>{
      'revision': 4,
      'name': '配置',
      'provider': 'zhipu',
      'baseUrl': 'https://model.example.com/v1',
      'model': 'model',
    });
    await repository.saveProfile(
      revision: 4,
      id: 'profile-1',
      name: '配置',
      provider: 'zhipu',
      baseUrl: 'https://model.example.com/v1',
      model: 'model',
      apiKey: '',
      removeApiKey: true,
    );
    expect((auth.requests.last.data! as Map)['removeApiKey'], isTrue);
    await repository.testConnection(
      profileId: 'profile-1',
      provider: 'zhipu',
      baseUrl: 'https://model.example.com/v1',
      model: 'model',
      apiKey: '',
    );
    expect(auth.requests.last.path, '/ai/test');
    expect(auth.requests.last.receiveTimeout, const Duration(seconds: 75));
    expect((auth.requests.last.data! as Map).containsKey('apiKey'), isFalse);
    expect((auth.requests.last.data! as Map).containsKey('text'), isFalse);
    auth.generation++;
    await expectLater(repository.load(), throwsA(isA<ApiFailure>()));
  });

  test('修订冲突刷新快照但不会自动重放写入', () async {
    // 固定认证边界。
    final _AiAuth auth = _AiAuth();
    // 仅使用本次测试的 Riverpod 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        authControllerProvider.overrideWith(_AiAuthController.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authControllerProvider.future);
    await container.read(aiSettingsControllerProvider.future);
    auth.handler = (_Request request) async {
      if (request.method == 'PUT') {
        throw DioException(
          requestOptions: RequestOptions(path: request.path),
          response: Response<void>(
            requestOptions: RequestOptions(path: request.path),
            statusCode: 409,
          ),
        );
      }
      return _snapshot(revision: 2, enabled: true);
    };
    await expectLater(
      container
          .read(aiSettingsControllerProvider.notifier)
          .mutate(
            (AiSettingsRepository repository) => repository.updateSettings(
              revision: 1,
              activeProfileId: 'profile-1',
              notePolishEnabled: true,
            ),
          ),
      throwsA(isA<AiSettingsConflict>()),
    );
    expect(container.read(aiSettingsControllerProvider).value?.revision, 2);
    expect(
      auth.requests.where((_Request request) => request.method == 'PUT'),
      hasLength(1),
    );
  });

  testWidgets('未连接服务器不请求配置且展示连接引导', (WidgetTester tester) async {
    // 完全离线测试边界。
    final _AiAuth auth = _AiAuth();
    await _pump(tester, auth, connected: false);
    expect(find.textContaining('请先在'), findsOneWidget);
    expect(find.text('新增模型配置'), findsNothing);
    expect(auth.requests, isEmpty);
  });

  testWidgets('读取失败不显示可覆盖配置的空白表单并可重试', (WidgetTester tester) async {
    // 第一次读取失败的网络边界。
    final _AiAuth auth = _AiAuth()
      ..handler = (_Request request) async => throw const ApiFailure('读取失败');
    await _pump(tester, auth);
    expect(find.text('读取失败'), findsOneWidget);
    expect(find.text('新增模型配置'), findsNothing);
    auth.handler = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('新增模型配置'), findsOneWidget);
  });

  for (final (TargetPlatform platform, double width, double scale)
      in <(TargetPlatform, double, double)>[
        (TargetPlatform.windows, 960, 1),
        (TargetPlatform.android, 320, 2),
      ]) {
    testWidgets('${platform.name} 配置表单大字号可用且掩码不回填密钥', (
      WidgetTester tester,
    ) async {
      // 正式页面使用的受控认证边界。
      final _AiAuth auth = _AiAuth();
      await _pump(tester, auth, platform: platform, width: width, scale: scale);
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      // 真实 API Key 编辑框，掩码只出现在说明中。
      final TextFormField field = tester.widget<TextFormField>(
        find.descendant(
          of: find.byType(OmniTextFormField).last,
          matching: find.byType(TextFormField),
        ),
      );
      expect(field.controller!.text, isEmpty);
      expect(find.textContaining('留空保留'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消').first);
      await tester.pumpAndSettle();
      expect(
        auth.requests.where((_Request request) => request.method != 'GET'),
        isEmpty,
      );
    });
  }

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 新增模型点击测试直接请求，结果内联且不保存草稿', (
      WidgetTester tester,
    ) async {
      // 固定请求完成时刻，以验证加载期间不会重复发起测试。
      final Completer<Map<String, dynamic>> gate =
          Completer<Map<String, dynamic>>();
      // 正式仓储只访问测试网络边界。
      final _AiAuth auth = _AiAuth()
        ..handler = (_Request request) => request.path == '/ai/test'
            ? gate.future
            : Future<Map<String, dynamic>>.value(_snapshot(profile: false));
      await _pump(
        tester,
        auth,
        platform: platform,
        width: platform == TargetPlatform.android ? 390 : 960,
      );
      await tester.tap(find.text('新增模型配置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(TextFormField).last);
      await tester.enterText(find.byType(TextFormField).last, 'test-only-key');
      await tester.ensureVisible(find.text('测试连接'));
      await tester.tap(find.text('测试连接'));
      await tester.pump();
      expect(find.text('开始测试'), findsNothing);
      expect(find.textContaining('将发送一条固定简短文本'), findsNothing);
      expect(
        auth.requests.where((_Request request) => request.path == '/ai/test'),
        hasLength(1),
      );
      expect(
        auth.requests
            .singleWhere((_Request request) => request.path == '/ai/test')
            .data,
        <String, dynamic>{
          'provider': 'zhipu',
          'baseUrl': 'https://open.bigmodel.cn/api/v1',
          'model': 'glm-5.3',
          'apiKey': 'test-only-key',
        },
      );
      // 原按钮进入加载及禁用状态，防止双击重复请求。
      final OmniButton testingButton = tester.widget<OmniButton>(
        find.widgetWithText(OmniButton, '测试连接'),
      );
      expect(testingButton.loading, isTrue);
      expect(testingButton.onPressed, isNull);
      gate.complete(<String, dynamic>{'message': '连接成功'});
      await tester.pumpAndSettle();
      expect(find.text('连接成功'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(4));
      // 失败重试也直接执行，草稿和错误反馈留在原表单内。
      auth.handler = (_Request request) async => throw DioException(
        requestOptions: RequestOptions(path: request.path),
        response: Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(path: request.path),
          statusCode: 503,
          data: <String, dynamic>{
            'code': 'AI_REASONING_UNSUPPORTED',
            'message': '该模型始终开启思考，不支持关闭思考（reasoning.effort=none）。',
          },
        ),
      );
      await tester.ensureVisible(find.text('测试连接'));
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(
        find.text('该模型始终开启思考，不支持关闭思考（reasoning.effort=none）。'),
        findsOneWidget,
      );
      expect(find.text('开始测试'), findsNothing);
      expect(
        auth.requests.where((_Request request) => request.path == '/ai/test'),
        hasLength(2),
      );
      expect(
        auth.requests.where(
          (_Request request) =>
              request.method != 'GET' && request.path != '/ai/test',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 开启整理直接提交，等待成功才切换且失败保留原状态', (
      WidgetTester tester,
    ) async {
      // 受控全局设置写入完成时刻。
      final Completer<Map<String, dynamic>> gate =
          Completer<Map<String, dynamic>>();
      // 读取正常、写入延迟的网络边界。
      final _AiAuth auth = _AiAuth()
        ..handler = (_Request request) => request.method == 'PUT'
            ? gate.future
            : Future<Map<String, dynamic>>.value(_snapshot());
      await _pump(
        tester,
        auth,
        platform: platform,
        width: platform == TargetPlatform.android ? 390 : 960,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('ai-note-polish-switch')),
      );
      await tester.pump();
      expect(find.text('开启整理'), findsNothing);
      expect(find.textContaining('ASR 文本将发送'), findsNothing);
      expect(
        auth.requests.where((_Request request) => request.method == 'PUT'),
        hasLength(1),
      );
      expect(
        tester
            .widget<OmniSwitch>(
              find.byKey(const ValueKey<String>('ai-note-polish-switch')),
            )
            .value,
        isFalse,
      );
      gate.complete(_snapshot(revision: 2, enabled: true));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OmniSwitch>(
              find.byKey(const ValueKey<String>('ai-note-polish-switch')),
            )
            .value,
        isTrue,
      );
      // 保存失败时错误直接显示，开关沿用服务器最后成功状态。
      auth.handler = (_Request request) async =>
          throw const ApiFailure('设置保存失败');
      await tester.tap(
        find.byKey(const ValueKey<String>('ai-note-polish-switch')),
      );
      await tester.pumpAndSettle();
      expect(find.text('设置保存失败'), findsOneWidget);
      expect(
        tester
            .widget<OmniSwitch>(
              find.byKey(const ValueKey<String>('ai-note-polish-switch')),
            )
            .value,
        isTrue,
      );
    });
  }
}
