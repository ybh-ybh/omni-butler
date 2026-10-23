import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';

/// 供应商预设，也用于用户可编辑的默认值。
class AiProviderPreset {
  /// 服务商标识。
  final String provider;

  /// 供应商展示名称。
  final String name;

  /// Responses API 服务根地址。
  final String baseUrl;

  /// 默认模型名称。
  final String model;

  /// 创建供应商预设。
  const AiProviderPreset({
    required this.provider,
    required this.name,
    required this.baseUrl,
    required this.model,
  });

  /// 解析后端供应商预设。
  factory AiProviderPreset.fromJson(Map<String, dynamic> json) =>
      AiProviderPreset(
        provider: json['provider'] as String,
        name: json['name'] as String,
        baseUrl: json['baseUrl'] as String,
        model: json['model'] as String,
      );
}

/// 后端未返回预设时仍能提供可编辑的基础选项。
const List<AiProviderPreset> aiProviderPresets = <AiProviderPreset>[
  AiProviderPreset(
    provider: 'zhipu',
    name: '智谱',
    baseUrl: 'https://open.bigmodel.cn/api/v1',
    model: 'glm-5.3',
  ),
  AiProviderPreset(
    provider: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
  ),
  AiProviderPreset(
    provider: 'custom',
    name: '自定义 Responses API 服务',
    baseUrl: '',
    model: '',
  ),
];

/// 不包含明文 API Key 的服务配置。
class AiModelProfile {
  /// 配置标识。
  final String id;

  /// 用户命名。
  final String name;

  /// 服务商标识。
  final String provider;

  /// 服务根地址。
  final String baseUrl;

  /// 模型名称。
  final String model;

  /// 后端是否保存了密钥。
  final bool hasApiKey;

  /// 后端提供的密钥掩码。
  final String maskedApiKey;

  /// 创建安全配置视图。
  const AiModelProfile({
    required this.id,
    required this.name,
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.hasApiKey,
    required this.maskedApiKey,
  });

  /// 判断当前配置是否可用于笔记整理。
  bool get isComplete => hasApiKey && baseUrl.isNotEmpty && model.isNotEmpty;

  /// 从服务器解析安全配置视图。
  factory AiModelProfile.fromJson(Map<String, dynamic> json) => AiModelProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    provider: json['provider'] as String,
    baseUrl: json['baseUrl'] as String,
    model: json['model'] as String,
    hasApiKey: json['hasApiKey'] == true,
    maskedApiKey: json['maskedApiKey'] as String? ?? '',
  );
}

/// 同一修订版本下的所有 AI 设置。
class AiSettingsSnapshot {
  /// 乐观并发控制修订号。
  final int revision;

  /// 当前配置标识。
  final String? activeProfileId;

  /// 笔记整理开关。
  final bool notePolishEnabled;

  /// 服务器保存的配置。
  final List<AiModelProfile> profiles;

  /// 可用供应商预设。
  final List<AiProviderPreset> presets;

  /// 创建完整设置快照。
  const AiSettingsSnapshot({
    required this.revision,
    required this.activeProfileId,
    required this.notePolishEnabled,
    required this.profiles,
    this.presets = aiProviderPresets,
  });

  /// 获取当前配置，配置被删除时返回空。
  AiModelProfile? get activeProfile {
    for (final AiModelProfile profile in profiles) {
      if (profile.id == activeProfileId) return profile;
    }
    return null;
  }

  /// 解析完整设置快照。
  factory AiSettingsSnapshot.fromJson(Map<String, dynamic> json) =>
      AiSettingsSnapshot(
        revision: json['revision'] as int,
        activeProfileId: json['activeProfileId'] as String?,
        notePolishEnabled: json['notePolishEnabled'] == true,
        profiles: (json['profiles'] as List)
            .map(
              (dynamic value) => AiModelProfile.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .toList(growable: false),
        presets:
            (json['presets'] as List?)
                ?.map(
                  (dynamic value) => AiProviderPreset.fromJson(
                    Map<String, dynamic>.from(value as Map),
                  ),
                )
                .toList(growable: false) ??
            aiProviderPresets,
      );
}

/// 他端先修改后刷新当前快照，禁止静默覆盖。
class AiSettingsConflict extends ApiFailure {
  /// 创建可理解的并发冲突。
  const AiSettingsConflict() : super('AI 设置已在其他设备修改，请核对最新设置后重试');
}

/// AI 设置只保存在后端，仓储不持久化任何供应商密钥。
class AiSettingsRepository {
  /// 当前认证边界。
  final AuthRepository auth;

  /// 仓储固定所属服务器代次。
  final int generation;

  /// 将仓储绑定到当前服务器。
  AiSettingsRepository(this.auth) : generation = auth.sessionGeneration;

  /// 使用固定代次请求并只解析受控错误，不展示包含请求头的异常。
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
  }) async {
    try {
      // 请求成功后 AuthRepository 还会校验服务器代次。
      final Response<Map<String, dynamic>> response = await auth
          .authorizedRequestForGeneration<Map<String, dynamic>>(
            generation,
            method,
            path,
            data: data,
            receiveTimeout: path == '/ai/test'
                ? const Duration(seconds: 75)
                : null,
            preserveTransportErrors: true,
          );
      return response.data ?? <String, dynamic>{};
    } on DioException catch (error) {
      if (error.response?.statusCode == 409) throw const AiSettingsConflict();
      // 仅使用服务端提供的用户错误，不串联 Dio 请求内容。
      final Object? body = error.response?.data;
      // Nest 错误响应的消息可能为单条文本或校验列表。
      final Object? message = body is Map ? body['message'] : null;
      if (message is String) throw ApiFailure(message);
      if (message is List && message.every((dynamic item) => item is String)) {
        throw ApiFailure(message.join('；'));
      }
      throw const ApiFailure('AI 服务请求失败，请检查网络和服务器后重试');
    }
  }

  /// 获取所有设置。
  Future<AiSettingsSnapshot> load() async =>
      AiSettingsSnapshot.fromJson(await request('GET', '/ai/settings'));

  /// 更新全局开关及当前配置。
  Future<AiSettingsSnapshot> updateSettings({
    required int revision,
    required String? activeProfileId,
    required bool notePolishEnabled,
  }) async => AiSettingsSnapshot.fromJson(
    await request(
      'PUT',
      '/ai/settings',
      data: <String, dynamic>{
        'revision': revision,
        'activeProfileId': activeProfileId,
        'notePolishEnabled': notePolishEnabled,
      },
    ),
  );

  /// 新增或更新配置，空密钥由后端保留原值。
  Future<AiSettingsSnapshot> saveProfile({
    required int revision,
    String? id,
    required String name,
    required String provider,
    required String baseUrl,
    required String model,
    required String apiKey,
    bool removeApiKey = false,
  }) async => AiSettingsSnapshot.fromJson(
    await request(
      id == null ? 'POST' : 'PUT',
      id == null ? '/ai/profiles' : '/ai/profiles/${Uri.encodeComponent(id)}',
      data: <String, dynamic>{
        'revision': revision,
        'name': name.trim(),
        'provider': provider,
        'baseUrl': baseUrl.trim(),
        'model': model.trim(),
        if (apiKey.trim().isNotEmpty) 'apiKey': apiKey.trim(),
        if (removeApiKey) 'removeApiKey': true,
      },
    ),
  );

  /// 删除配置，后端负责同时关闭当前配置的整理开关。
  Future<AiSettingsSnapshot> deleteProfile({
    required int revision,
    required String id,
  }) async => AiSettingsSnapshot.fromJson(
    await request(
      'DELETE',
      '/ai/profiles/${Uri.encodeComponent(id)}',
      data: <String, dynamic>{'revision': revision},
    ),
  );

  /// 测试草稿，固定测试文本由后端生成且不保存配置。
  Future<String> testConnection({
    String? profileId,
    required String provider,
    required String baseUrl,
    required String model,
    required String apiKey,
  }) async {
    // 成功响应不包含任何供应商凭证。
    final Map<String, dynamic> response = await request(
      'POST',
      '/ai/test',
      data: <String, dynamic>{
        'profileId': ?profileId,
        'provider': provider,
        'baseUrl': baseUrl.trim(),
        'model': model.trim(),
        if (apiKey.trim().isNotEmpty) 'apiKey': apiKey.trim(),
      },
    );
    return response['message'] as String? ?? '连接成功';
  }
}

/// 随认证会话重建并隔离服务器代次的仓储。
final Provider<AiSettingsRepository> aiSettingsRepositoryProvider =
    Provider<AiSettingsRepository>((Ref ref) {
      ref.watch(authControllerProvider);
      return AiSettingsRepository(ref.watch(authRepositoryProvider));
    });

/// 后端设置快照控制器，写请求成功后才更新页面。
class AiSettingsController extends AsyncNotifier<AiSettingsSnapshot?> {
  /// 无连接时不发请求，连接有效时从后端获取完整快照。
  @override
  Future<AiSettingsSnapshot?> build() async {
    // 认证未就绪时不跨会话读取设置。
    final AsyncValue<SyncSession?> session = ref.watch(authControllerProvider);
    if (session.isLoading || session.hasError || session.value == null) {
      return null;
    }
    return ref.watch(aiSettingsRepositoryProvider).load();
  }

  /// 显式重试读取失败的设置，读取时不创建空白表单。
  Future<void> reload() async {
    ref.invalidateSelf();
    await future;
  }

  /// 统一提交快照变更，冲突时只刷新、不自动重放写入。
  Future<void> mutate(
    Future<AiSettingsSnapshot> Function(AiSettingsRepository repository)
    operation,
  ) async {
    // 固定此次写入使用的仓储与服务器代次。
    final AiSettingsRepository repository = ref.read(
      aiSettingsRepositoryProvider,
    );
    try {
      // 不先覆盖旧快照，失败时保留可见配置。
      final AiSettingsSnapshot snapshot = await operation(repository);
      if (ref.mounted &&
          repository.generation == repository.auth.sessionGeneration) {
        state = AsyncData<AiSettingsSnapshot?>(snapshot);
        ref.invalidate(assistantSettingsProvider);
      }
    } on AiSettingsConflict {
      // 只刷新同一服务器，防止换服后迟到结果污染新设置。
      if (ref.mounted &&
          repository.generation == repository.auth.sessionGeneration) {
        try {
          // 服务器最新快照。
          final AiSettingsSnapshot latest = await repository.load();
          if (ref.mounted &&
              repository.generation == repository.auth.sessionGeneration) {
            state = AsyncData<AiSettingsSnapshot?>(latest);
          }
        } catch (_) {
          if (ref.mounted) ref.invalidateSelf();
        }
      }
      rethrow;
    }
  }
}

/// 页面与笔记功能共享当前服务器的 AI 设置快照。
final AsyncNotifierProvider<AiSettingsController, AiSettingsSnapshot?>
aiSettingsControllerProvider =
    AsyncNotifierProvider<AiSettingsController, AiSettingsSnapshot?>(
      AiSettingsController.new,
      retry: (int count, Object error) => null,
    );
