import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';

/// MCP管理只使用设备JWT，专用连接令牌不写入本机数据库或偏好。
class McpRepository {
  /// 固定当前认证实例。
  final AuthRepository auth;

  /// 仓储所属服务器代次，阻止换服后的迟到操作响应。
  final int generation;

  /// 创建当前认证边界下的管理仓储。
  McpRepository(this.auth) : generation = auth.sessionGeneration;

  /// 只返回可理解的错误，不展示Dio请求头或令牌。
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    try {
      // AuthRepository在发送前及完成后都校验固定服务器代次。
      final Response<Map<String, dynamic>> response = await auth
          .authorizedRequestForGeneration<Map<String, dynamic>>(
            generation,
            method,
            '/mcp-management$path',
            data: data,
            preserveTransportErrors: true,
          );
      return response.data ?? <String, dynamic>{};
    } on DioException catch (error) {
      // 仅信任服务器提供的安全用户消息。
      final Object? body = error.response?.data;
      // 业务冲突不自动重试，须重新核对预览。
      final Object? message = body is Map ? body['message'] : null;
      if (message is String) throw ApiFailure(message);
      throw const ApiFailure('MCP设置请求失败，请检查连接后重试');
    }
  }

  /// 列表只含安全连接信息与操作摘要。
  Future<Map<String, dynamic>> load() => request('GET', '');

  /// 明文专用令牌只在此响应显示一次，不放入任何provider状态。
  Future<Map<String, dynamic>> create(Map<String, dynamic> input) =>
      request('POST', '/connections', data: input);

  /// 撤销后所有未执行的操作一并失效。
  Future<void> revoke(String id) async {
    await request('POST', '/connections/${Uri.encodeComponent(id)}/revoke');
  }

  /// 只读查看冻结的完整影响及执行结果。
  Future<Map<String, dynamic>> review(String id) =>
      request('GET', '/actions/${Uri.encodeComponent(id)}');
}

/// 认证切换后重建，不能将旧服务器操作详情交给新服务器。
final Provider<McpRepository> mcpRepositoryProvider = Provider<McpRepository>((
  Ref ref,
) {
  ref.watch(authControllerProvider);
  return McpRepository(ref.watch(authRepositoryProvider));
});

/// 无后端连接时只显示连接说明，不构造空配置覆盖服务器。
final FutureProvider<Map<String, dynamic>?> mcpSettingsProvider =
    FutureProvider<Map<String, dynamic>?>((Ref ref) async {
      // 会话仍加载或失效时禁止后台请求。
      final AsyncValue<SyncSession?> session = ref.watch(
        authControllerProvider,
      );
      if (session.isLoading || session.hasError || session.value == null) {
        return null;
      }
      return ref.watch(mcpRepositoryProvider).load();
    });
