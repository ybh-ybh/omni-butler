import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/core/sync/sync_preferences.dart';

/// Windows 与 Android 系统安全存储提供者。
final Provider<FlutterSecureStorage> secureStorageProvider =
    Provider<FlutterSecureStorage>((Ref ref) {
      return const FlutterSecureStorage(aOptions: AndroidOptions());
    });

/// 自托管同步服务会话仓储提供者。
final Provider<AuthRepository> authRepositoryProvider =
    Provider<AuthRepository>((Ref ref) {
      // 系统安全存储。
      final FlutterSecureStorage storage = ref.watch(secureStorageProvider);
      return AuthRepository(storage);
    });

/// 当前设备同步服务会话控制器。
class AuthController extends AsyncNotifier<SyncSession?> {
  /// 应用启动时恢复设备会话，失败时保持本机模式。
  @override
  Future<SyncSession?> build() {
    // 当前设备同步总开关。
    final bool syncEnabled = ref.watch(syncPreferenceProvider);
    if (!syncEnabled) {
      return Future<SyncSession?>.value();
    }
    // 同步服务会话仓储。
    final AuthRepository repository = ref.watch(authRepositoryProvider);
    return repository.restoreSession();
  }

  /// 使用服务地址和同步密钥连接自托管服务器。
  Future<void> connect({
    required String apiBaseUrl,
    required String syncKey,
  }) async {
    state = const AsyncLoading<SyncSession?>();
    state = await AsyncValue.guard(
      () => ref
          .read(authRepositoryProvider)
          .connect(apiBaseUrl: apiBaseUrl, syncKey: syncKey),
    );
  }

  /// 断开同步服务器并保留本机数据。
  Future<void> disconnect() async {
    state = const AsyncLoading<SyncSession?>();
    state = await AsyncValue.guard(() async {
      await ref.read(authRepositoryProvider).disconnect();
      return null;
    });
  }

  /// 重新检查服务端会话状态。
  Future<void> refreshSession() async {
    state = const AsyncLoading<SyncSession?>();
    state = await AsyncValue.guard(
      ref.read(authRepositoryProvider).restoreSession,
    );
  }
}

/// 当前设备同步服务会话提供者。
final AsyncNotifierProvider<AuthController, SyncSession?>
authControllerProvider = AsyncNotifierProvider<AuthController, SyncSession?>(
  AuthController.new,
);
