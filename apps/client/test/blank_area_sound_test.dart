import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';
import 'package:omni_butler/app/router/app_router.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/database/app_database.dart';
import 'package:omni_butler/core/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 Windows 一级页面空白区域不会请求播放系统提示音。
void main() {
  testWidgets('首页、每日待办和时间管理的空白区域保持静默', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'light',
    });
    // 测试用主题偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 测试用内存数据库。
    final AppDatabase database = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    // 显式管理的测试依赖容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        appDatabaseProvider.overrideWithValue(database),
        nowProvider.overrideWithValue(DateTime(2026, 9, 9, 10, 30)),
      ],
    );
    // 页面点击期间收到的平台方法调用。
    final List<MethodCall> platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          platformCalls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OmniButlerApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 当前需要验证的路由与空白坐标。
    for (final MapEntry<String, Offset> route in <String, Offset>{
      '/home': const Offset(70, 50),
      '/todos': const Offset(541, 500),
      '/timeline': const Offset(120, 740),
    }.entries) {
      container.read(appRouterProvider).go(route.key);
      await tester.pumpAndSettle();
      platformCalls.clear();
      // 当前路由内可稳定命中的空白坐标。
      final Offset blankPoint = route.value;

      await tester.tapAt(blankPoint);
      await tester.pump();

      expect(
        platformCalls.where(
          (MethodCall call) => call.method == 'SystemSound.play',
        ),
        isEmpty,
        reason: '${route.key} 的空白区域不应触发 Windows 系统提示音',
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await database.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
