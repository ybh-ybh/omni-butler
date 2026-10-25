import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 应用内助手开关与记忆权限设置，模型选择留在助手输入区。
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
          // 已保存模型只用于判断助手总开关当前是否具备启用条件。
          final List<Map<String, dynamic>> profiles = assistantItems(
            settings['profiles'],
          );
          // 已删除配置不能作为助手当前可用模型。
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
          // 卡片分段统一使用当前主题的弱文字与分隔线颜色。
          final OmniColors colors = OmniColors.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              MergeSemantics(
                child: OmniListRow(
                  key: const ValueKey<String>('assistant-settings-header'),
                  padding: EdgeInsets.zero,
                  title: Text(
                    '应用内助手',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  trailing: OmniSwitch(
                    key: const ValueKey<String>('assistant-enabled-switch'),
                    value: settings['enabled'] == true,
                    onChanged:
                        _busy || (!complete && settings['enabled'] != true)
                        ? null
                        : (bool value) => _update(settings, <String, dynamic>{
                            'enabled': value,
                          }),
                  ),
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: OmniSpacing.sm),
                  child: Text(_message!),
                ),
              const SizedBox(height: OmniSpacing.md),
              Divider(height: 1, color: colors.line),
              const SizedBox(height: OmniSpacing.md),
              Column(
                key: const ValueKey<String>('assistant-memory-section'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  OmniListRow(
                    padding: EdgeInsets.zero,
                    title: Text(
                      '记忆',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    trailing: OmniButton(
                      label: '管理记忆',
                      variant: OmniButtonVariant.secondary,
                      compact: true,
                      onPressed: () => context.push('/assistant/memories'),
                    ),
                  ),
                  MergeSemantics(
                    child: OmniListRow(
                      padding: const EdgeInsets.symmetric(
                        vertical: OmniSpacing.sm,
                      ),
                      title: const Text('使用已保存记忆'),
                      subtitle: const Text('只读取启用中的相关记忆'),
                      trailing: OmniSwitch(
                        key: const ValueKey<String>(
                          'assistant-memory-read-switch',
                        ),
                        value: settings['memoryReadEnabled'] == true,
                        onChanged: _busy
                            ? null
                            : (bool value) => _update(
                                settings,
                                <String, dynamic>{'memoryReadEnabled': value},
                              ),
                      ),
                    ),
                  ),
                  Divider(height: 1, color: colors.line),
                  MergeSemantics(
                    child: OmniListRow(
                      padding: const EdgeInsets.symmetric(
                        vertical: OmniSpacing.sm,
                      ),
                      title: const Text('允许保存显式记忆'),
                      subtitle: const Text('仅当你明确要求“记住”时保存'),
                      trailing: OmniSwitch(
                        key: const ValueKey<String>(
                          'assistant-memory-write-switch',
                        ),
                        value: settings['memoryWriteEnabled'] == true,
                        onChanged: _busy
                            ? null
                            : (bool value) => _update(
                                settings,
                                <String, dynamic>{'memoryWriteEnabled': value},
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: OmniSpacing.xs),
                  Text(
                    '聊天与记忆保存于服务端数据库备份；本机迁移备份不包含助手历史。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.muted),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
