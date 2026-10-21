import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';

/// 同步候选的读取与人工决策，固定服务器代次，不改变SDK原队列。
class SyncConflictRepository {
  /// 当前设备JWT认证边界。
  final AuthRepository auth;

  /// 发起预览时的服务器代次。
  final int generation;

  /// 创建当前服务器的候选仓储。
  SyncConflictRepository(this.auth) : generation = auth.sessionGeneration;

  /// 网络/业务错误只显示安全消息，不自动以新基线重试。
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    try {
      // 请求前后由认证层核对服务器归属及代次。
      final Response<Map<String, dynamic>> response = await auth
          .authorizedRequestForGeneration<Map<String, dynamic>>(
            generation,
            method,
            '/sync/write-conflicts$path',
            data: data,
            preserveTransportErrors: true,
          );
      return response.data ?? <String, dynamic>{};
    } on DioException catch (error) {
      // 不将Dio请求头、原始数据或堆栈串接到界面。
      final Object? body = error.response?.data;
      // 服务器提供受控冲突原因，重读后由人决定。
      final Object? message = body is Map ? body['message'] : null;
      throw ApiFailure(message is String ? message : '暂时无法核实同步冲突，请保留本机数据并稍后刷新');
    }
  }

  /// 仅加载摘要，正文由人打开后才查询。
  Future<Map<String, dynamic>> load() async {
    // 无效或旧版本响应不能伪装成“没有冲突”。
    final Map<String, dynamic> result = await request('GET', '');
    if (result['items'] is! List) {
      throw const ApiFailure('服务器未返回有效同步冲突列表，请核对版本后重试');
    }
    return result;
  }

  /// 重新取得服务器事实及与其绑定的确认摘要。
  Future<Map<String, dynamic>> preview(String id) =>
      request('GET', '/${Uri.encodeComponent(id)}');

  /// 一次用户明确决策保持固定身份，响应丢失后可按相同请求核实。
  Future<Map<String, dynamic>> resolve(
    String id,
    String hash,
    String decision,
    String requestId,
  ) => request(
    'POST',
    '/${Uri.encodeComponent(id)}/resolve',
    data: <String, dynamic>{
      'baselineHash': hash,
      'decision': decision,
      'requestId': requestId,
    },
  );
}

/// 认证变化后重建仓储，旧确认不发送到新服务器。
final Provider<SyncConflictRepository> syncConflictRepositoryProvider =
    Provider<SyncConflictRepository>((Ref ref) {
      ref.watch(authControllerProvider);
      return SyncConflictRepository(ref.watch(authRepositoryProvider));
    });

/// 已连接时读取候选；读取失败不能当成“没有冲突”。
final FutureProvider<Map<String, dynamic>?> syncConflictProvider =
    FutureProvider<Map<String, dynamic>?>((Ref ref) async {
      // 未认证时不调用服务器。
      final AsyncValue<SyncSession?> session = ref.watch(
        authControllerProvider,
      );
      if (session.isLoading || session.hasError || session.value == null) {
        return null;
      }
      return ref.watch(syncConflictRepositoryProvider).load();
    });
