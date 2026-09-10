import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';

/// 自托管服务器地址边界测试。
void main() {
  // 无需实际访问系统安全存储的仓储。
  const AuthRepository repository = AuthRepository(FlutterSecureStorage());

  test('允许 HTTPS、本机和私有局域网 HTTP 地址', () {
    expect(
      repository.normalizeBaseUrl('https://sync.example.com/api/v1/'),
      'https://sync.example.com/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('http://127.0.0.1:3000/api/v1'),
      'http://127.0.0.1:3000/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('http://192.168.1.10:3000/api/v1'),
      'http://192.168.1.10:3000/api/v1',
    );
    expect(
      repository.normalizeBaseUrl('http://172.16.0.5:3000/api/v1'),
      'http://172.16.0.5:3000/api/v1',
    );
  });

  test('拒绝公网明文 HTTP 地址', () {
    expect(
      () => repository.normalizeBaseUrl('http://sync.example.com/api/v1'),
      throwsA(
        isA<ApiFailure>().having(
          (ApiFailure error) => error.message,
          'message',
          contains('公网服务必须使用 HTTPS'),
        ),
      ),
    );
  });
}
