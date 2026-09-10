import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/theme_controller.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 多端同步总开关持久化测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('首次安装默认关闭，用户开启后写入本机偏好', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试专用偏好存储。
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    // 覆盖真实偏好存储的 Provider 容器。
    final ProviderContainer container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);

    expect(container.read(syncPreferenceProvider), isFalse);
    await container.read(syncPreferenceProvider.notifier).setEnabled(true);
    expect(container.read(syncPreferenceProvider), isTrue);
    expect(preferences.getBool('sync.enabled'), isTrue);
  });
}
