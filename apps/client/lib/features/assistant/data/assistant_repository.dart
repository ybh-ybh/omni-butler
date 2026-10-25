import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';

/// 保留受控 HTTP 状态便于区分附件失效和暂时离线，不保存请求或响应正文。
class AssistantApiFailure extends ApiFailure {
  /// 服务端 HTTP 状态，网络断开时为空。
  final int? statusCode;

  /// 后端固定机器码用于区分确定拒绝与代理错误。
  final String? code;

  /// 创建可显示且不含凭据的请求错误。
  const AssistantApiFailure(super.message, this.statusCode, {this.code});
}

/// 设备认证下的助手接口，与外部 MCP 连接授权独立。
class AssistantRepository {
  /// 当前认证边界。
  final AuthRepository auth;

  /// 仓储固定服务器代次。
  final int generation;

  /// 创建绑定当前服务器的仓储。
  AssistantRepository(this.auth) : generation = auth.sessionGeneration;

  /// 是否仍属于当前服务器。
  bool get isCurrent => generation == auth.sessionGeneration;

  /// 使用稳定上传身份传送私有文件，不自动建立新的上传请求。
  Future<Map<String, dynamic>> uploadAttachment(
    String conversationId,
    String uploadId,
    String localPath,
    String name,
  ) async => request(
    'PUT',
    '/conversations/${Uri.encodeComponent(conversationId)}/attachments/${Uri.encodeComponent(uploadId)}',
    data: FormData.fromMap(<String, dynamic>{
      'file': await MultipartFile.fromFile(localPath, filename: name),
    }),
  );

  /// 图片和文档始终经过当前设备认证下载，不将令牌拼到 URL。
  Future<Uint8List> attachmentBytes(String id) async {
    try {
      // 认证层在返回前核对服务器代次。
      final Response<List<int>> response = await auth
          .authorizedRequestForGeneration<List<int>>(
            generation,
            'GET',
            '/assistant/attachments/${Uri.encodeComponent(id)}/file',
            responseType: ResponseType.bytes,
            preserveTransportErrors: true,
          );
      if (response.data == null) throw const ApiFailure('附件内容暂不可用');
      return Uint8List.fromList(response.data!);
    } on DioException {
      throw const ApiFailure('附件下载失败，请恢复原服务器连接后重试');
    }
  }

  /// 普通接口不自动重放写入，错误只展示用户消息。
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    try {
      // 所有响应返回前由认证仓储复验代次。
      final Response<Map<String, dynamic>> response = await auth
          .authorizedRequestForGeneration<Map<String, dynamic>>(
            generation,
            method,
            '/assistant$path',
            data: data,
            preserveTransportErrors: true,
            receiveTimeout: const Duration(seconds: 90),
          );
      return response.data ?? <String, dynamic>{};
    } on DioException catch (error) {
      // 不输出可能包含令牌或模型输入的 Dio 诊断。
      final Map<String, dynamic> body = assistantMap(error.response?.data);
      // 仅保留公开用户消息，不能传递原始请求头或响应诊断。
      final Object? message = body['message'];
      throw AssistantApiFailure(
        message is String ? message : '助手请求未完成，请检查网络；执行结果可在恢复连接后查询',
        error.response?.statusCode,
        code: body['code'] is String ? body['code'] as String : null,
      );
    }
  }

  /// 监听服务端持久事件；连接中断不会停止服务器任务。
  Stream<AssistantEvent> events(
    String runId,
    int after,
    CancelToken token,
  ) async* {
    try {
      // SSE 响应头完成后仍需逐帧校验代次。
      final Response<ResponseBody> response = await auth
          .authorizedRequestForGeneration<ResponseBody>(
            generation,
            'GET',
            '/assistant/runs/${Uri.encodeComponent(runId)}/events',
            queryParameters: <String, dynamic>{'after': after},
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 90),
            preserveTransportErrors: true,
            cancelToken: token,
          );
      if (response.data == null) throw const ApiFailure('服务器没有返回助手事件流');
      await for (final AssistantEvent event in decodeAssistantEvents(
        response.data!.stream,
      )) {
        if (!isCurrent || token.isCancelled) break;
        yield event;
      }
    } finally {
      auth.releaseSessionStreamToken(token);
    }
  }
}

/// 随认证边界重建的接口仓储。
final Provider<AssistantRepository> assistantRepositoryProvider =
    Provider<AssistantRepository>((Ref ref) {
      ref.watch(authControllerProvider);
      return AssistantRepository(ref.watch(authRepositoryProvider));
    });

/// 助手设置独立读取，删除模型后重新获取真实状态。
final FutureProvider<Map<String, dynamic>?> assistantSettingsProvider =
    FutureProvider<Map<String, dynamic>?>((Ref ref) async {
      // 没有设备连接不读取服务端设置。
      final SyncSession? session = await ref.watch(
        authControllerProvider.future,
      );
      if (session == null) return null;
      return ref.watch(assistantRepositoryProvider).request('GET', '/settings');
    });
