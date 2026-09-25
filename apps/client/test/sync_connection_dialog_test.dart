import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/settings/presentation/sync_connection_dialog.dart';

/// 跳过应用偏好恢复，连接流程仍使用真实控制器和仓储。
class _DialogAuthController extends AuthController {
  /// 从未连接状态开始测试。
  @override
  Future<SyncSession?> build() async => null;
}

/// 展示真实设置表单，将 HTTP 传输替换为内存响应。
Future<void> _showDialog(
  WidgetTester tester,
  List<RequestOptions> requests,
) async {
  // 执行真实地址拼接和会话保存的认证仓储。
  final AuthRepository repository = AuthRepository(
    const FlutterSecureStorage(),
    clientFactory: (String baseUrl) {
      // 当前请求使用的 HTTP 客户端。
      final Dio client = Dio(BaseOptions(baseUrl: baseUrl));
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions request, RequestInterceptorHandler handler) {
                requests.add(request);
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: request,
                    statusCode: 200,
                    data: request.path == '/auth/connect'
                        ? <String, dynamic>{
                            'accessToken': 'access',
                            'refreshToken': 'device-secret',
                            'expiresIn': 900,
                          }
                        : <String, dynamic>{'sub': 'owner-id'},
                  ),
                );
              },
        ),
      );
      return client;
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(_DialogAuthController.new),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showSyncConnectionDialog(context),
              child: const Text('打开连接设置'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开连接设置'));
  await tester.pumpAndSettle();
}

/// 验证基础输入及固定路径的实际请求地址，覆盖桌面和紧凑布局。
void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  // 桌面和手机的测试视口。
  for (final Size size in <Size>[const Size(1100, 800), const Size(390, 844)]) {
    testWidgets('地址、端口和密钥即可连接：${size.width}', (WidgetTester tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 捕获最终发送的 HTTP 请求。
      final List<RequestOptions> requests = <RequestOptions>[];
      await _showDialog(tester, requests);

      expect(find.byType(TextFormField), findsNWidgets(3));
      expect(find.text('服务器地址'), findsOneWidget);
      expect(find.text('端口'), findsOneWidget);
      expect(find.text('同步密钥'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(0), '192.168.1.10');
      await tester.enterText(find.byType(TextFormField).at(1), '9000');
      await tester.ensureVisible(find.byType(TextFormField).at(2));
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'valid-deployment-secret',
      );
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();

      expect(find.text('连接自托管同步服务'), findsNothing);
      expect(requests.map((RequestOptions request) => request.uri.toString()), [
        'http://192.168.1.10:9000/omni-butler/api/v1/auth/connect',
        'http://192.168.1.10:9000/omni-butler/api/v1/auth/session',
      ]);
      expect(requests.first.data, <String, String>{
        'syncKey': 'valid-deployment-secret',
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('非法端口或携带路径的地址在提交前提示错误', (WidgetTester tester) async {
    // 不合法的输入不得发送网络请求。
    final List<RequestOptions> requests = <RequestOptions>[];
    await _showDialog(tester, requests);
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'valid-deployment-secret',
    );
    // 覆盖空值、范围边界和非整数输入。
    for (final String port in <String>['', '0', '65536', 'abc', '3.5']) {
      await tester.enterText(find.byType(TextFormField).at(1), port);
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();
      expect(find.text('端口必须是 1 到 65535 之间的整数'), findsOneWidget);
      expect(requests, isEmpty);
    }
    await tester.enterText(find.byType(TextFormField).at(1), '3000');
    await tester.enterText(
      find.byType(TextFormField).at(0),
      '192.168.1.10/omni-butler/api/v1',
    );
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(find.text('请只填写 IP 地址或域名，端口在下方填写'), findsOneWidget);
    expect(requests, isEmpty);
  });
}
