import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/settings/data/sync_conflict_repository.dart';
import 'package:omni_butler/features/settings/presentation/business_change_preview.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 原队列在处理前不确认，用户核对完整事务后选择如何保留两端事实。
class SyncConflictsSection extends ConsumerStatefulWidget {
  /// 创建同步冲突入口。
  const SyncConflictsSection({super.key});

  /// 创建只持有瞬时确认状态的界面。
  @override
  ConsumerState<SyncConflictsSection> createState() =>
      _SyncConflictsSectionState();
}

/// 候选来自服务器持久回执，本机原始事务继续由SDK保存。
class _SyncConflictsSectionState extends ConsumerState<SyncConflictsSection> {
  /// 防止重复决策。
  bool _busy = false;

  /// 不将未核实结果显示为成功。
  String? _message;

  /// 人工打开、核对并决定，服务器变动时须重新获取预览。
  Future<void> _review(String id) async {
    if (_busy) return;
    // 固定打开时的认证边界，切换服务器后不能继续批准。
    final SyncConflictRepository repository = ref.read(
      syncConflictRepositoryProvider,
    );
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // 预览包含整笔本机事务，不能只展示第一个冲突字段。
      final Map<String, dynamic> preview = await repository.preview(id);
      if (!mounted ||
          repository.generation != repository.auth.sessionGeneration) {
        return;
      }
      // 每一条记录对应当前服务器事实，后续同记录步骤仍按原顺序显示。
      final List<Map<String, dynamic>> records =
          (preview['currentRecords'] as List)
              .map((dynamic value) => Map<String, dynamic>.from(value as Map))
              .toList();
      // 准备用户可读差异，用户选择保留本机也仍遵守原领域约束。
      final List<Map<String, dynamic>> changes = <Map<String, dynamic>>[];
      for (final dynamic value in preview['operations'] as List) {
        // 操作由原SDK队列固化，不允许此窗口更改请求字段。
        final Map<String, dynamic> operation = Map<String, dynamic>.from(
          value as Map,
        );
        // 目标不存在与字段空值区分。
        final Map<String, dynamic> record = records.firstWhere(
          (Map<String, dynamic> row) =>
              row['table'] == operation['table'] &&
              row['id'] == operation['id'],
        );
        // 当前服务器事实作为“之前”，本机意图作为“之后”。
        final Map<String, dynamic> current = record['data'] == null
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(record['data'] as Map);
        // 永久删除明确展示动作，不伪造已不存在对象的恢复。
        final Map<String, dynamic> proposed = operation['op'] == 'DELETE'
            ? <String, dynamic>{
                for (final String field in current.keys) field: null,
                '处理方式': '永久删除原事务目标（仍受墓碑和领域规则约束）',
              }
            : Map<String, dynamic>.from(
                operation['data'] as Map? ?? <String, dynamic>{},
              );
        changes.add(<String, dynamic>{
          'id': operation['id'],
          'label':
              current['name'] ??
              current['title'] ??
              current['activity'] ??
              '${operation['table']} · ${operation['id']}',
          'newRecord': operation['op'] == 'PUT',
          'before': current,
          'after': proposed,
        });
      }
      // 后来新增的关联记录不在旧队列里，也必须让用户核对删除闭包。
      for (final Map<String, dynamic> record in records) {
        if ((preview['operations'] as List).any(
          (dynamic operation) =>
              operation['table'] == record['table'] &&
              operation['id'] == record['id'],
        )) {
          continue;
        }
        // 完整事实仅展示为资料，不把可能的级联影响伪装成已执行。
        final Map<String, dynamic> data = Map<String, dynamic>.from(
          record['data'] as Map,
        );
        changes.add(<String, dynamic>{
          'id': record['id'],
          'label':
              data['name'] ??
              data['title'] ??
              data['content'] ??
              '${record['table']} · ${record['id']}',
          'newRecord': false,
          'before': data,
          'after': <String, dynamic>{
            ...data,
            '关联影响': '父记录删除可能使此记录删除或失效。以上是当前关联事实，请核对后再选择。',
          },
        });
      }
      // 处理决定只绑定当前展示的服务器快照与固定操作身份。
      final String? decision = await showOmniDialog<String>(
        context: context,
        builder: (BuildContext dialogContext) => OmniDialogScaffold(
          title: '核对同步冲突',
          actions: <Widget>[
            OmniButton(
              label: '稍后处理',
              variant: OmniButtonVariant.secondary,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            OmniButton(
              label: '采用服务器',
              variant: OmniButtonVariant.secondary,
              onPressed: () => Navigator.of(dialogContext).pop('server'),
            ),
            OmniButton(
              label: '重新提交本机事务',
              onPressed: () => Navigator.of(dialogContext).pop('local'),
            ),
          ],
          child: SizedBox(
            width: 660,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '整笔本机事务尚未确认，未执行其中的部分修改。请核对以下完整清单，选择后才允许原设备继续上传。稍后处理会保留全部本机修改。',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '“之前”是当前服务器值，“之后”是本机原始意图。重新提交仍遵守领域规则：永久墓碑不能复活，新增不会变成更新，笔记冲突仍可能保存为候选。',
                  ),
                  for (final Map<String, dynamic> change in changes)
                    BusinessChangePreview(change: change),
                ],
              ),
            ),
          ),
        ),
      );
      if (decision == null ||
          !mounted ||
          repository.generation != repository.auth.sessionGeneration) {
        return;
      }
      // 请求ID在本次显式选择时生成，网络层不自动更换后重试。
      final String requestId = const Uuid().v4();
      // 服务端若已变化会拒绝，不以刚读取的新值自动覆盖。
      final Map<String, dynamic> result = await repository.resolve(
        id,
        preview['baselineHash'] as String,
        decision,
        requestId,
      );
      if (!mounted ||
          repository.generation != repository.auth.sessionGeneration) {
        return;
      }
      setState(
        () => _message =
            result['message'] as String? ?? '服务器已处理，请等待原设备重试同步并核实下行结果。',
      );
      ref.invalidate(syncConflictProvider);
    } catch (error) {
      if (mounted &&
          repository.generation == repository.auth.sessionGeneration) {
        setState(
          () => _message = error is ApiFailure
              ? error.message
              : '未能核实处理结果，请刷新后查看；原事务仍受保护。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 不在读取失败时显示“没有冲突”，窄屏按钮自然换行。
  @override
  Widget build(BuildContext context) {
    // 预览加载不会修改业务或确认任何SDK队列。
    final AsyncValue<Map<String, dynamic>?> snapshot = ref.watch(
      syncConflictProvider,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 20),
        const Divider(),
        const Text(
          '同步冲突',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const Text('旧离线编辑不会静默覆盖 MCP 修改。发生冲突时原事务保留，明确处理后才继续确认队列。'),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_message!),
          ),
        snapshot.when(
          loading: () => const LinearProgressIndicator(),
          error: (Object error, StackTrace stack) =>
              Text(error is ApiFailure ? error.message : '无法读取同步冲突，请重试'),
          data: (Map<String, dynamic>? data) => data == null
              ? const Text('连接服务器后可查看同步冲突。')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if ((data['items'] as List).isEmpty)
                      const Text('没有待处理的同步冲突。'),
                    for (final dynamic value in data['items'] as List)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            SelectableText(
                              '待核对 ${(value as Map)['operationCount']} 个操作 · ${value['createdAt']}',
                            ),
                            OmniButton(
                              label: '核对冲突',
                              variant: OmniButtonVariant.secondary,
                              onPressed: _busy
                                  ? null
                                  : () => _review(value['id'] as String),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OmniButton(
            label: '刷新冲突',
            variant: OmniButtonVariant.secondary,
            onPressed: _busy
                ? null
                : () => ref.invalidate(syncConflictProvider),
          ),
        ),
      ],
    );
  }
}
