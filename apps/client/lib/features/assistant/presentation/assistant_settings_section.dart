import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 助手模型与笔记整理分别选择，共用后端保存的供应商配置。
class AssistantSettingsSection extends ConsumerStatefulWidget {
  /// 创建独立助手设置区域。
  const AssistantSettingsSection({super.key});

  /// 创建设置状态。
  @override
  ConsumerState<AssistantSettingsSection> createState() =>
      _AssistantSettingsSectionState();
}

/// 只有后端保存成功后才更新开关。
class _AssistantSettingsSectionState
    extends ConsumerState<AssistantSettingsSection> {
  /// 正在提交设置或测试。
  bool _busy = false;

  /// 持续可见的操作结果。
  String? _message;

  /// 固定仓储执行请求，防止换服后迟到结果污染页面。
  Future<void> _run(
    Future<String?> Function(AssistantRepository) operation,
  ) async {
    if (_busy) return;
    // 当前固定数据源接口。
    final AssistantRepository repository = ref.read(
      assistantRepositoryProvider,
    );
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // 返回用户说明，密钥从不进入页面。
      final String? message = await operation(repository);
      if (mounted && repository.isCurrent) {
        setState(() => _message = message);
        ref.invalidate(assistantSettingsProvider);
      }
    } catch (error) {
      if (mounted && repository.isCurrent) {
        setState(
          () => _message = error is ApiFailure ? error.message : '助手设置操作失败',
        );
      }
      if (mounted && repository.isCurrent) {
        ref.invalidate(assistantSettingsProvider);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 设置变更使用当前修订号，冲突刷新但不静默重试写入。
  Future<void> _update(
    Map<String, dynamic> settings,
    Map<String, dynamic> patch,
  ) async {
    // 固定当前服务器身份，开关直接提交且仍等待后端保存成功。
    final AssistantRepository repository = ref.read(
      assistantRepositoryProvider,
    );
    if (!mounted || !repository.isCurrent) return;
    await _run((AssistantRepository fixed) async {
      if (!identical(fixed, repository)) throw const ApiFailure('服务器已切换，请重新操作');
      await fixed.request(
        'PUT',
        '/settings',
        data: <String, dynamic>{
          'revision': settings['revision'],
          'enabled': settings['enabled'],
          'profileId': settings['profileId'],
          'memoryReadEnabled': settings['memoryReadEnabled'],
          'memoryWriteEnabled': settings['memoryWriteEnabled'],
          'timeZone': settings['timeZone'] ?? 'Asia/Shanghai',
          ...patch,
        },
      );
      return null;
    });
  }

  /// 读取失败时不提供空白可写设置。
  @override
  Widget build(BuildContext context) {
    // 助手设置与笔记当前配置独立。
    final AsyncValue<Map<String, dynamic>?> state = ref.watch(
      assistantSettingsProvider,
    );
    return OmniPanel(
      child: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(error is ApiFailure ? error.message : '无法读取助手设置'),
            OmniButton(
              label: '重试读取助手设置',
              onPressed: () => ref.invalidate(assistantSettingsProvider),
            ),
          ],
        ),
        data: (Map<String, dynamic>? settings) {
          if (settings == null) return const Text('连接服务器后可配置应用内助手。');
          // 只允许选择完整的既有配置。
          final List<Map<String, dynamic>> profiles = assistantItems(
            settings['profiles'],
          );
          // 已删除配置不作为下拉框的旧选中值。
          final String? profileId =
              profiles.any(
                (Map<String, dynamic> profile) =>
                    profile['id'] == settings['profileId'],
              )
              ? settings['profileId'] as String?
              : null;
          // 缺少密钥时不能启用助手。
          final bool complete = profiles.any(
            (Map<String, dynamic> profile) =>
                profile['id'] == profileId && profile['hasApiKey'] == true,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('应用内助手', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: OmniSpacing.sm),
              OmniListRow(
                padding: EdgeInsets.zero,
                title: const Text('开启知序助手'),
                subtitle: const Text('文字对话、查询与整理，以及确认后执行批量变更'),
                trailing: OmniSwitch(
                  key: const ValueKey<String>('assistant-enabled-switch'),
                  value: settings['enabled'] == true,
                  onChanged: _busy || (!complete && settings['enabled'] != true)
                      ? null
                      : (bool value) => _update(settings, <String, dynamic>{
                          'enabled': value,
                        }),
                ),
              ),
              const SizedBox(height: OmniSpacing.sm),
              const Text('助手使用的模型'),
              const SizedBox(height: OmniSpacing.xs),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) =>
                    OmniDropdownButton<String>(
                      value: profileId,
                      width: constraints.maxWidth,
                      hint: const Text('选择已有模型配置'),
                      items: <DropdownMenuItem<String>>[
                        for (final Map<String, dynamic> profile in profiles)
                          DropdownMenuItem<String>(
                            value: profile['id'] as String,
                            enabled: profile['hasApiKey'] == true,
                            child: Text(
                              '${profile['name']} · ${profile['model']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (String? value) => _update(
                              settings,
                              <String, dynamic>{'profileId': value},
                            ),
                    ),
              ),
              const SizedBox(height: OmniSpacing.xs),
              const Text('与笔记 AI 整理分别选择。修改或删除模型配置会影响使用该配置的助手任务。'),
              const SizedBox(height: OmniSpacing.sm),
              Wrap(
                spacing: OmniSpacing.sm,
                runSpacing: OmniSpacing.xs,
                children: <Widget>[
                  OmniButton(
                    label: '测试助手能力',
                    variant: OmniButtonVariant.secondary,
                    loading: _busy,
                    onPressed: !complete || _busy
                        ? null
                        : () => _run((AssistantRepository repository) async {
                            // 固定文本和无副作用函数用于验证流式与工具能力。
                            final Map<String, dynamic> result = await repository
                                .request(
                                  'POST',
                                  '/test',
                                  data: <String, dynamic>{
                                    'profileId': profileId,
                                  },
                                );
                            return result['message'] as String? ??
                                '助手流式与工具调用测试通过';
                          }),
                  ),
                  OmniButton(
                    label: '管理记忆',
                    variant: OmniButtonVariant.secondary,
                    onPressed: () => context.push('/assistant/memories'),
                  ),
                  OmniButton(
                    label: '打开助手',
                    onPressed: settings['enabled'] == true
                        ? () => context.go('/assistant')
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: OmniSpacing.md),
              OmniListRow(
                padding: EdgeInsets.zero,
                title: const Text('使用已保存记忆'),
                subtitle: const Text('只读取启用中的相关记忆'),
                trailing: OmniSwitch(
                  value: settings['memoryReadEnabled'] == true,
                  onChanged: _busy
                      ? null
                      : (bool value) => _update(settings, <String, dynamic>{
                          'memoryReadEnabled': value,
                        }),
                ),
              ),
              OmniListRow(
                padding: EdgeInsets.zero,
                title: const Text('允许保存显式记忆'),
                subtitle: const Text('仅当你明确要求“记住”时保存'),
                trailing: OmniSwitch(
                  value: settings['memoryWriteEnabled'] == true,
                  onChanged: _busy
                      ? null
                      : (bool value) => _update(settings, <String, dynamic>{
                          'memoryWriteEnabled': value,
                        }),
                ),
              ),
              const SizedBox(height: OmniSpacing.xs),
              const Text('聊天与记忆保存于服务端数据库备份；本机迁移备份不包含助手历史。'),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: OmniSpacing.sm),
                  child: Text(_message!),
                ),
            ],
          );
        },
      ),
    );
  }
}
