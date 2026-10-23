import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_cards.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 精确业务对象的服务器快照，本机未同步也能审阅真实结果。
class AssistantEntityDetails extends ConsumerStatefulWidget {
  /// 后端派生的对象引用，而非模型任意 URL。
  final Map<String, dynamic> reference;

  /// 创建精确对象详情。
  const AssistantEntityDetails({required this.reference, super.key});

  /// 创建绑定服务器的详情状态。
  @override
  ConsumerState<AssistantEntityDetails> createState() =>
      _AssistantEntityDetailsState();
}

/// 页面保留来源服务器身份，换服后旧快照只读。
class _AssistantEntityDetailsState
    extends ConsumerState<AssistantEntityDetails> {
  /// 打开时的固定仓储。
  late final AssistantRepository _repository;

  /// 对象最新快照查询。
  late Future<Map<String, dynamic>> _future;

  /// 合法的七模块标识。
  static const Set<String> _modules = <String>{
    'time',
    'timeline',
    'timeEntries',
    'inventory',
    'memberships',
    'notes',
    'todos',
    'events',
    'quotes',
  };

  /// 初始快照来自业务执行器，并立即只读核实最新状态。
  @override
  void initState() {
    super.initState();
    _repository = ref.read(assistantRepositoryProvider);
    _future = _load();
  }

  /// 精确查询当前对象，找不到时保留执行时快照并明确标注。
  Future<Map<String, dynamic>> _load() {
    if (!_modules.contains(widget.reference['module']) ||
        widget.reference['id'] is! String) {
      return Future<Map<String, dynamic>>.error(const ApiFailure('对象引用无效'));
    }
    return _repository.request(
      'GET',
      '/entities/${Uri.encodeComponent(widget.reference['module'] as String)}/${Uri.encodeComponent(widget.reference['id'] as String)}',
    );
  }

  /// 展示精确对象快照，不把尚未同步的对象导航到普通列表。
  @override
  Widget build(BuildContext context) {
    // 监听认证变化，只允许来源服务器的快照继续刷新。
    ref.watch(assistantRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.reference['label'] as String? ?? '记录详情'),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder:
            (BuildContext context, AsyncSnapshot<Map<String, dynamic>> state) {
              // 网络失败时仅保留结果卡已带回的服务器快照。
              final Map<String, dynamic> source =
                  state.data ??
                  <String, dynamic>{'record': widget.reference['record']};
              // 不同模块的详情包装由字段映射统一处理。
              final Map<String, dynamic> record = assistantMap(
                source['record'] ?? source['value'] ?? source['note'] ?? source,
              );
              return ListView(
                padding: const EdgeInsets.all(OmniSpacing.md),
                children: <Widget>[
                  if (state.connectionState == ConnectionState.waiting)
                    const LinearProgressIndicator(),
                  Text(
                    _repository.isCurrent
                        ? '服务器快照 · 其他页面将在同步后显示'
                        : '来源服务器已切换，此快照仅供查看',
                  ),
                  if (state.hasError)
                    Text(
                      state.error is ApiFailure
                          ? (state.error as ApiFailure).message
                          : '无法核实最新状态，以下是操作完成时的快照。',
                    ),
                  const SizedBox(height: OmniSpacing.md),
                  OmniPanel(
                    child: AssistantChangeCard(
                      value: <String, dynamic>{'record': record},
                    ),
                  ),
                  const SizedBox(height: OmniSpacing.md),
                  Wrap(
                    spacing: OmniSpacing.sm,
                    children: <Widget>[
                      OmniButton(
                        label: '刷新快照',
                        variant: OmniButtonVariant.secondary,
                        onPressed: !_repository.isCurrent
                            ? null
                            : () => setState(() => _future = _load()),
                      ),
                      // 现有笔记页实际支持 id 定位，其余模块先保留精确快照。
                      if (widget.reference['module'] == 'notes')
                        OmniButton(
                          label: '在笔记中打开',
                          variant: OmniButtonVariant.secondary,
                          onPressed: !_repository.isCurrent
                              ? null
                              : () => context.go(
                                  Uri(
                                    path: '/notes',
                                    queryParameters: <String, String>{
                                      'id': widget.reference['id'] as String,
                                    },
                                  ).toString(),
                                ),
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
