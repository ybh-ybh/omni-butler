import 'package:flutter/material.dart';
import 'package:omni_butler/features/settings/presentation/business_change_preview.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/settings/data/mcp_repository.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 授权模块名与服务器固定目录一致。
const Map<String, String> mcpModuleLabels = <String, String>{
  'quotes': '名言',
  'time': '时间记录',
  'todos': '待办',
  'inventory': '物品',
  'memberships': '会员',
  'events': '事件',
  'notes': '笔记',
};

/// 服务器状态对应用户说明，不把准备等同于已经提交。
String _statusLabel(Object? value) => switch (value) {
  'pending' => '待执行',
  'approved' => '旧流程操作，请在 Codex 重新发起',
  'succeeded' => '服务器已保存',
  'cancelled' => '已取消',
  'expired' => '已过期',
  'conflict' => '数据变化，请重新准备',
  _ => '状态未知',
};

/// 正式结果只展示服务器分配的真实身份，预览的临时身份不能当成创建结果。
String _resultReference(Object? value) {
  if (value is! Map) return '请通过原操作状态核实结果';
  // 笔记保存有独立状态包装，其他模块直接返回对象或业务动作事实。
  final Map record = value['note'] is Map ? value['note'] as Map : value;
  // 结果卡片保持简短，完整正文通过已有业务页面查看。
  final String label =
      (record['name'] ??
              record['title'] ??
              record['activity'] ??
              record['content'] ??
              '业务结果')
          .toString();
  return '$label\n记录身份：${record['id'] ?? record['eventId'] ?? record['todoId'] ?? record['ids'] ?? '见原操作回执'}${value['candidateRevision'] != null ? '\n冲突候选：${value['candidateRevision']}' : ''}';
}

/// Windows双栏与Android二级设置共用的连接管理和操作记录。
class McpSettingsSection extends ConsumerStatefulWidget {
  /// 创建MCP设置内容。
  const McpSettingsSection({super.key});

  /// 创建可取消的页面状态。
  @override
  ConsumerState<McpSettingsSection> createState() => _McpSettingsSectionState();
}

/// 只保存瞬时忙碌状态，专用令牌不放入页面或provider持久状态。
class _McpSettingsSectionState extends ConsumerState<McpSettingsSection> {
  /// 防止重复提交人工决策。
  bool _busy = false;

  /// 持续可见的操作反馈。
  String? _message;

  /// 所有管理操作固定服务器代次；错误不自动重放写入。
  Future<void> _run(
    McpRepository repository,
    Future<void> Function() action,
  ) async {
    if (_busy || repository.generation != repository.auth.sessionGeneration) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted &&
          repository.generation == repository.auth.sessionGeneration) {
        setState(
          () => _message = error is ApiFailure ? error.message : '操作未完成，请刷新后核实',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 创建配置后一次性展示令牌，关闭窗口即释放局部值。
  Future<void> _create(McpRepository repository) async {
    // 草稿由独立表单持有，取消不会发往服务器。
    final Map<String, dynamic>? input =
        await showOmniDialog<Map<String, dynamic>>(
          context: context,
          builder: (BuildContext dialogContext) => const _McpConnectionEditor(),
        );
    if (input == null || !mounted) return;
    await _run(repository, () async {
      // 迟到响应由仓储代次校验拒绝，不把旧服令牌展示为新服令牌。
      final Map<String, dynamic> created = await repository.create(input);
      ref.invalidate(mcpSettingsProvider);
      if (!mounted ||
          repository.generation != repository.auth.sessionGeneration) {
        return;
      }
      await showOmniDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => OmniDialogScaffold(
          title: '连接令牌只显示这一次',
          actions: <Widget>[
            OmniButton(
              label: '复制令牌',
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: created['token'] as String),
                );
              },
            ),
            OmniButton(
              label: '已保存',
              variant: OmniButtonVariant.secondary,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '将令牌保存到运行 Codex 的环境变量 OMNI_MCP_TOKEN。关闭后无法再次查看，遗失请撤销并新建连接。不要将令牌写入仓库。',
                ),
                const SizedBox(height: 12),
                SelectableText(created['token'] as String),
                const SizedBox(height: 12),
                const Text(
                  'Codex 配置使用服务地址末尾的 /omni-butler/api/v1/mcp，并指定 bearer_token_env_var = "OMNI_MCP_TOKEN"。',
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  /// 撤销前说明未执行操作和令牌会一起失效。
  Future<void> _revoke(
    McpRepository repository,
    Map<String, dynamic> connection,
  ) async {
    // 确认窗口绑定打开时的服务器与连接身份。
    final bool confirmed =
        await showOmniDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => OmniDialogScaffold(
            title: '撤销 ${connection['name']}？',
            actions: <Widget>[
              OmniButton(
                label: '返回',
                variant: OmniButtonVariant.secondary,
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              OmniButton(
                label: '撤销连接',
                variant: OmniButtonVariant.danger,
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
            child: const Text('撤销后 Codex 不能继续访问数据，尚未执行的操作也会取消。已保存的业务记录保留。'),
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _run(repository, () async {
      await repository.revoke(connection['id'] as String);
      ref.invalidate(mcpSettingsProvider);
    });
  }

  /// 完整操作详情从服务器重新获取，不能只展示列表摘要。
  Future<void> _review(
    McpRepository repository,
    String id,
  ) => _run(repository, () async {
    // 列表摘要不能代替完整影响预览。
    final Map<String, dynamic> action = await repository.review(id);
    if (!mounted ||
        repository.generation != repository.auth.sessionGeneration) {
      return;
    }
    // 所有业务影响均来自服务器真实事务预演。
    final Map<String, dynamic> preview = Map<String, dynamic>.from(
      action['preview'] as Map,
    );
    // 候选成功不等于正文已经采用，终态反馈必须读取真实回执。
    final Map<String, dynamic>? result = action['result'] is Map
        ? Map<String, dynamic>.from(action['result'] as Map)
        : null;
    // 模态窗口仅查看真实预览及结果，不发起审批或提交。
    await showOmniDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => OmniDialogScaffold(
        title: 'MCP 操作详情',
        actions: <Widget>[
          OmniButton(
            label: '返回',
            variant: OmniButtonVariant.secondary,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
        child: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(_statusLabel(action['status'])),
                const SizedBox(height: 8),
                SelectableText(
                  '操作：$id\n有效至：${action['expiresAt']}\n影响 ${preview['affectedRecords']} 条记录；清单整体成功或整体失败。',
                ),
                if (preview['newRecordIds'] is String)
                  Text(preview['newRecordIds'] as String),
                if (preview['systemGeneratedValues'] is String)
                  Text(preview['systemGeneratedValues'] as String),
                for (final dynamic outcome
                    in preview['expectedOutcomes'] as List? ?? <Object>[])
                  Text(outcome.toString()),
                for (final dynamic step in preview['steps'] as List)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text((step as Map)['description'] as String),
                        BusinessParametersPreview(
                          input: Map<String, dynamic>.from(
                            step['input'] as Map? ?? <String, dynamic>{},
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final dynamic value in preview['changes'] as List)
                  BusinessChangePreview(
                    change: Map<String, dynamic>.from(value as Map),
                  ),
                const SizedBox(height: 12),
                if (result != null) ...<Widget>[
                  Text(result['syncStatus'] as String? ?? '请核实实际保存状态'),
                  SelectableText('服务器提交时间：${result['serverSavedAt']}'),
                  for (final dynamic value
                      in result['values'] as List? ?? <Object>[])
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SelectableText(_resultReference(value)),
                    ),
                ],
                const Text(
                  '此处仅查看操作详情。单条任务由 Codex 直接执行；批量任务在 Codex 对话中确认。请依据实际状态核实是否保存，业务数据变化时须重新准备。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  });

  /// 用流式布局容纳窄屏和大字号，不固定连接行高度。
  @override
  Widget build(BuildContext context) {
    // 仓储和快照都随认证边界重建。
    final McpRepository repository = ref.watch(mcpRepositoryProvider);
    // 无连接/加载/错误分别展示，不将读取失败当空配置。
    final AsyncValue<Map<String, dynamic>?> snapshot = ref.watch(
      mcpSettingsProvider,
    );
    return snapshot.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace stack) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(error is ApiFailure ? error.message : '无法读取 MCP 设置'),
          OmniButton(
            label: '重新加载',
            onPressed: () => ref.invalidate(mcpSettingsProvider),
          ),
        ],
      ),
      data: (Map<String, dynamic>? data) {
        if (data == null) return const Text('连接后端后可管理 Codex 的 MCP 连接并查看操作记录。');
        // 已撤销连接保留服务端历史，只在当前连接卡片中过滤。
        final List<Map<String, dynamic>> connections =
            (data['connections'] as List)
                .map((dynamic value) => Map<String, dynamic>.from(value as Map))
                .where(
                  (Map<String, dynamic> connection) =>
                      connection['revokedAt'] == null,
                )
                .toList();
        // 接口按状态分组返回，展示前统一按时间排序以取最近30条。
        final List<Map<String, dynamic>> actions =
            (data['actions'] as List)
                .map((dynamic value) => Map<String, dynamic>.from(value as Map))
                .toList()
              ..sort(
                (Map<String, dynamic> first, Map<String, dynamic> second) =>
                    DateTime.parse(
                      second['createdAt'] as String,
                    ).compareTo(DateTime.parse(first['createdAt'] as String)),
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            OmniPanel(
              key: const ValueKey<String>('mcp-connections-card'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                          // 窄屏或大字号将操作另起一行靠右，保留完整按钮文字。
                          final bool stacked =
                              constraints.maxWidth <
                              520 * MediaQuery.textScalerOf(context).scale(1);
                          // 连接列表的共同操作固定放在卡头右侧。
                          final Widget actions = Wrap(
                            alignment: WrapAlignment.end,
                            spacing: OmniSpacing.sm,
                            runSpacing: OmniSpacing.xs,
                            children: <Widget>[
                              OmniButton(
                                label: '新增连接',
                                onPressed: _busy
                                    ? null
                                    : () => _create(repository),
                              ),
                              OmniButton(
                                label: '刷新状态',
                                variant: OmniButtonVariant.secondary,
                                onPressed: _busy
                                    ? null
                                    : () => ref.invalidate(mcpSettingsProvider),
                              ),
                            ],
                          );
                          // 卡片标题沿用设置区域的标题层级。
                          final Widget title = Text(
                            'MCP 连接',
                            style: Theme.of(context).textTheme.titleLarge,
                          );
                          return stacked
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    title,
                                    const SizedBox(height: OmniSpacing.sm),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: actions,
                                    ),
                                  ],
                                )
                              : Row(
                                  children: <Widget>[
                                    Expanded(child: title),
                                    const SizedBox(width: OmniSpacing.sm),
                                    actions,
                                  ],
                                );
                        },
                  ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: OmniSpacing.sm),
                      child: Text(_message!),
                    ),
                  if (connections.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: OmniSpacing.md),
                      child: Text('暂无 MCP 连接'),
                    ),
                  for (final Map<String, dynamic> connection in connections)
                    Padding(
                      key: ValueKey<String>(
                        'mcp-connection-${connection['id']}',
                      ),
                      padding: const EdgeInsets.only(top: OmniSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  connection['name'] as String,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: OmniSpacing.sm),
                              OmniButton(
                                label: '撤销连接',
                                variant: OmniButtonVariant.secondary,
                                onPressed: _busy
                                    ? null
                                    : () => _revoke(repository, connection),
                              ),
                            ],
                          ),
                          Text(
                            '读取：${(connection['readModules'] as List).map((dynamic module) => mcpModuleLabels[module]).join('、')}',
                          ),
                          Text(
                            '写入：${(connection['writeModules'] as List).isEmpty ? '未授权' : (connection['writeModules'] as List).map((dynamic module) => mcpModuleLabels[module]).join('、')}',
                          ),
                          Text(
                            '到期：${connection['expiresAt'] ?? '永久'}\n时区：${connection['timeZone'] ?? '未配置，调用时需明确提供'}',
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: OmniSpacing.lg),
            OmniPanel(
              key: const ValueKey<String>('mcp-actions-card'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('操作记录', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: OmniSpacing.sm),
                  if (actions.isEmpty)
                    const Text('暂无 MCP 操作。使用 Codex 操作后，可刷新查看记录与结果。'),
                  // 相邻记录之间使用主题灰色细线，首尾不额外加线。
                  for (final (int index, Map<String, dynamic> action)
                      in actions.take(30).indexed) ...<Widget>[
                    if (index > 0) const Divider(),
                    Padding(
                      key: ValueKey<String>('mcp-action-row-${action['id']}'),
                      padding: const EdgeInsets.symmetric(
                        vertical: OmniSpacing.sm,
                      ),
                      child: LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints constraints) {
                          // 窄屏和大字号让信息占满一行，按钮另起一行靠右。
                          final bool stacked =
                              constraints.maxWidth <
                              480 * MediaQuery.textScalerOf(context).scale(1);
                          // 摘要只展示状态与身份，完整预览仍从服务器读取。
                          final Widget details = Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(_statusLabel(action['status'])),
                              SelectableText(action['id'] as String),
                              Text(
                                '影响 ${(action['preview'] as Map)['affectedRecords']} 条记录 · ${action['createdAt']}',
                              ),
                            ],
                          );
                          // 查看按钮绑定操作身份，不依赖排序后的列表索引。
                          final Widget review = OmniButton(
                            key: ValueKey<String>(
                              'mcp-action-review-${action['id']}',
                            ),
                            label: '查看操作',
                            variant: OmniButtonVariant.secondary,
                            onPressed: _busy
                                ? null
                                : () => _review(
                                    repository,
                                    action['id'] as String,
                                  ),
                          );
                          return stacked
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    details,
                                    const SizedBox(height: OmniSpacing.xs),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: review,
                                    ),
                                  ],
                                )
                              : Row(
                                  children: <Widget>[
                                    Expanded(child: details),
                                    const SizedBox(width: OmniSpacing.sm),
                                    review,
                                  ],
                                );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 新连接草稿只在窗口内存在，取消不提交。
class _McpConnectionEditor extends StatefulWidget {
  /// 创建空白连接表单。
  const _McpConnectionEditor();

  /// 创建表单草稿状态。
  @override
  State<_McpConnectionEditor> createState() => _McpConnectionEditorState();
}

/// 默认所有模块只读，写权限必须逐项显式勾选。
class _McpConnectionEditorState extends State<_McpConnectionEditor> {
  /// 用户连接名称，不接受密钥作为输入。
  final TextEditingController _name = TextEditingController(text: 'Codex');

  /// 用户确认的IANA时区，空值不猜测。
  final TextEditingController _timeZone = TextEditingController();

  /// 默认读取范围。
  final Set<String> _read = mcpModuleLabels.keys.toSet();

  /// 默认没有写权限。
  final Set<String> _write = <String>{};

  /// 固定有效期天数，0仅作为表单“永久”选项身份。
  int _ttlDays = 30;

  /// 释放窗口草稿控制器。
  @override
  void dispose() {
    _name.dispose();
    _timeZone.dispose();
    super.dispose();
  }

  /// 授权字段完整可见，新增不依赖模型建议的权限。
  @override
  Widget build(BuildContext context) => OmniDialogScaffold(
    title: '新增 MCP 连接',
    actions: <Widget>[
      OmniButton(
        label: '取消',
        variant: OmniButtonVariant.secondary,
        onPressed: () => Navigator.of(context).pop(),
      ),
      OmniButton(
        label: '创建连接',
        onPressed: () {
          if (_name.text.trim().isEmpty) return;
          Navigator.of(context).pop(<String, dynamic>{
            'name': _name.text.trim(),
            'timeZone': _timeZone.text.trim().isEmpty
                ? null
                : _timeZone.text.trim(),
            'ttlDays': _ttlDays == 0 ? null : _ttlDays,
            'readModules': _read.toList(),
            'writeModules': _write.toList(),
          });
        },
      ),
    ],
    child: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            OmniTextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '连接名称'),
            ),
            const SizedBox(height: 12),
            OmniTextField(
              controller: _timeZone,
              decoration: const InputDecoration(
                labelText: '默认时区（可选）',
                hintText: '例如 Asia/Shanghai',
              ),
            ),
            const SizedBox(height: 8),
            const Text('留空时，涉及日期的工具必须显式提供时区。'),
            OmniDropdownButtonFormField<int>(
              initialValue: _ttlDays,
              decoration: const InputDecoration(labelText: '有效期'),
              items: <int>[7, 30, 90, 365, 0]
                  .map(
                    (int days) => DropdownMenuItem<int>(
                      value: days,
                      child: Text(days == 0 ? '永久' : '$days 天'),
                    ),
                  )
                  .toList(),
              onChanged: (int? value) {
                if (value != null) setState(() => _ttlDays = value);
              },
            ),
            const SizedBox(height: 12),
            const Text('模块授权 · 写权限允许直接修改数据'),
            for (final MapEntry<String, String> module
                in mcpModuleLabels.entries)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  OmniSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('读取${module.value}'),
                    value: _read.contains(module.key),
                    onChanged: (bool value) => setState(() {
                      if (value) {
                        _read.add(module.key);
                      } else {
                        _read.remove(module.key);
                        _write.remove(module.key);
                      }
                    }),
                  ),
                  OmniSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('允许修改${module.value}数据'),
                    value: _write.contains(module.key),
                    onChanged: (bool value) => setState(() {
                      if (value) {
                        _write.add(module.key);
                        _read.add(module.key);
                      } else {
                        _write.remove(module.key);
                      }
                    }),
                  ),
                ],
              ),
          ],
        ),
      ),
    ),
  );
}
