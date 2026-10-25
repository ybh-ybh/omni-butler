import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/features/assistant/data/assistant_repository.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_result_form.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 固定业务名避免将模型字段或数据库表名直接显示给用户。
const Map<String, String> _moduleNames = <String, String>{
  'todos': '待办',
  'inventory': '物品',
  'time': '时间记录',
  'notes': '笔记',
  'quotes': '语录',
  'memberships': '会员',
  'events': '周期事务',
};

/// 只有服务端实际执行步骤提供的操作种类才能称为新增或删除。
const Map<String, String> _operationNames = <String, String>{
  'create': '新增',
  'update': '修改',
  'delete': '删除',
  'restore': '恢复',
  'complete': '完成',
  'revoke': '撤销',
  'finish': '结束',
  'start': '开始',
};

/// 结果的主字段来自受控记录，不使用UUID作为展示名称。
String _recordLabel(Map<String, dynamic> record, Object? fallback) {
  for (final String field in <String>[
    'title',
    'name',
    'activity',
    'content',
    'body',
  ]) {
    // 多行正文仅抽取第一行作为折叠摘要，完整内容保留在表单内。
    final Object? value = record[field];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim().split('\n').first;
    }
  }
  return fallback is String && fallback.trim().isNotEmpty ? fallback : '记录';
}

/// 一次结果包含多个独立对象时，每个对象独立折叠和编辑。
class AssistantResultCard extends StatelessWidget {
  /// 原始结果卡片只作为历史资料。
  final Map<String, dynamic> card;

  /// 当前认证及页面可操作状态。
  final bool enabled;

  /// 固定来源的认证仓储，离线历史可不提供。
  final AssistantRepository? repository;

  /// 编辑和提交前复用页面已有的本机同步检查点。
  final Future<void> Function()? beforeEdit;

  /// 当前真实任务提供的撤销操作，仅挂在唯一结果面板上。
  final VoidCallback? onUndo;

  /// 撤销有效期来自服务端实际业务回执，不使用回答或任务时间推测。
  final String? undoExpiresAt;

  /// 创建结果展示，不会自动发起任何写入。
  const AssistantResultCard({
    required this.card,
    required this.enabled,
    this.repository,
    this.beforeEdit,
    this.onUndo,
    this.undoExpiresAt,
    super.key,
  });

  /// 历史卡片缺少引用时只展示主要内容，不能猜测可编辑身份。
  Map<String, dynamic> _legacy() {
    // 旧回执通过固定包装字段查找主项。
    Map<String, dynamic> record = assistantMap(card['result'] ?? card);
    // 旧包装只提供展示种类，没有entityRefs仍不开放写入。
    String? module;
    for (int depth = 0; depth < 4; depth++) {
      // 多条旧记录没有精确身份时不制造编辑入口。
      final List<Map<String, dynamic>> values = assistantItems(
        record['values'],
      );
      if (values.length == 1) {
        record = values.first;
        continue;
      }
      // 仅识别旧协议已知的业务包装。
      final String? wrapper = <String>[
        'record',
        'note',
        'todo',
        'item',
        'event',
        'membership',
        'timeEntry',
        'quote',
      ].where((field) => record[field] is Map).firstOrNull;
      if (wrapper == null) break;
      module =
          const <String, String>{
            'note': 'notes',
            'todo': 'todos',
            'item': 'inventory',
            'event': 'events',
            'membership': 'memberships',
            'timeEntry': 'time',
            'quote': 'quotes',
          }[wrapper] ??
          module;
      record = assistantMap(record[wrapper]);
    }
    return <String, dynamic>{
      'module': module,
      'record': record,
      'label': _recordLabel(record, card['title']),
    };
  }

  /// 默认只构建折叠摘要，不展开内部字段列表。
  @override
  Widget build(BuildContext context) {
    // 新回执的真实引用优先，旧回执不猜模块和主键。
    final List<Map<String, dynamic>> references = assistantItems(
      card['entityRefs'] ?? assistantMap(card['result'])['entityRefs'],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final Map<String, dynamic> reference
            in references.isEmpty
                ? <Map<String, dynamic>>[_legacy()]
                : references)
          _ResultEntityPanel(
            key: ValueKey<String>(
              'result-${reference['module']}-${reference['id']}',
            ),
            reference: reference,
            enabled: enabled,
            repository: repository,
            beforeEdit: beforeEdit,
            onUndo: references.length <= 1 ? onUndo : null,
            undoExpiresAt: undoExpiresAt,
          ),
      ],
    );
  }
}

/// 面板草稿与展示快照分开；模型不会参与用户手动保存。
class _ResultEntityPanel extends StatefulWidget {
  /// 服务器生成的精确引用及执行时快照。
  final Map<String, dynamic> reference;

  /// 当前消息操作权限。
  final bool enabled;

  /// 当前页面仓储，用于检测换服。
  final AssistantRepository? repository;

  /// 复用页面同步检查点。
  final Future<void> Function()? beforeEdit;

  /// 撤销回调绑定明确任务，不能读取后来变化的任务身份。
  final VoidCallback? onUndo;

  /// 可选期限兼容尚未返回该展示事实的旧服务。
  final String? undoExpiresAt;

  /// 创建单个对象面板。
  const _ResultEntityPanel({
    required this.reference,
    required this.enabled,
    required this.repository,
    required this.beforeEdit,
    required this.onUndo,
    required this.undoExpiresAt,
    super.key,
  });

  /// 每个对象保留独立折叠与草稿状态。
  @override
  State<_ResultEntityPanel> createState() => _ResultEntityPanelState();
}

/// 读取最新版本后才能编辑，保存失败不刷新基线覆盖并发修改。
class _ResultEntityPanelState extends State<_ResultEntityPanel> {
  /// 没有新网络事件时也按真实截止时间隐藏撤销入口。
  Timer? _undoExpiryTimer;

  /// 计时器到期后保持隐藏，不能因无关重建恢复旧按钮。
  bool _undoExpired = false;

  /// 当前实际业务期限和已到期状态共同控制撤销入口。
  bool get _showUndo =>
      widget.onUndo != null &&
      !_undoExpired &&
      (widget.undoExpiresAt == null ||
          (DateTime.tryParse(widget.undoExpiresAt!)?.isAfter(DateTime.now()) ??
              false));

  /// 建立独立于聊天秒表的单次到期通知。
  @override
  void initState() {
    super.initState();
    _watchUndoExpiry();
  }

  /// 新的资格事实到达时重新计算，不延长原有有效期。
  @override
  void didUpdateWidget(covariant _ResultEntityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.undoExpiresAt != widget.undoExpiresAt) {
      _watchUndoExpiry();
    }
  }

  /// 已过期立即隐藏，未到期只安排一次本地显示刷新。
  void _watchUndoExpiry() {
    _undoExpiryTimer?.cancel();
    _undoExpired = false;
    // 缺失旧字段不伪造到期时间，最终操作仍由服务器校验。
    final DateTime? deadline = DateTime.tryParse(widget.undoExpiresAt ?? '');
    if (deadline == null) return;
    // 延迟时间取真实回执截止时刻与当前设备时刻的差值。
    final Duration remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _undoExpired = true;
      return;
    }
    _undoExpiryTimer = Timer(remaining, () {
      if (mounted) setState(() => _undoExpired = true);
    });
  }

  /// 面板离开时不保留无用的到期回调。
  @override
  void dispose() {
    _undoExpiryTimer?.cancel();
    super.dispose();
  }

  /// 创建时绑定来源，认证变化后旧面板不可写。
  late final AssistantRepository? _repository = widget.repository;

  /// 当前读到的服务器快照，历史回执作为初始回退。
  late Map<String, dynamic> _record = assistantMap(widget.reference['record']);

  /// 默认收起，用户操作后重建仍保留偏好。
  bool _expanded = false;

  /// 正在读取快照。
  bool _loading = false;

  /// 正在保存固定请求。
  bool _saving = false;

  /// 表单是否处于编辑状态。
  bool _editing = false;

  /// 并发冲突后必须显式重新载入。
  bool _conflict = false;

  /// 服务端或网络公开错误，不展示原始异常正文。
  String? _error;

  /// 最近一次保存结果的简短反馈。
  String? _notice;

  /// 表单当前合法差异，无效时为null。
  Map<String, dynamic>? _changes = <String, dynamic>{};

  /// 结果未知时冻结原operationId、版本与字段，重试原样复用。
  Map<String, dynamic>? _pending;

  /// 新基线强制重建表单，取消编辑丢弃未提交的表单差异。
  int _formVersion = 0;

  /// 异步读取代次防止过时快照覆盖保存结果。
  int _requestVersion = 0;

  /// 行内容摘要覆盖同一毫秒内的并发更新。
  String? _editVersion;

  /// 旧版服务器可读取记录，但没有受版本保护的原地编辑接口。
  bool _legacyServer = false;

  /// 时间记录编辑沿用助手配置的业务时区。
  String? _timeZone;

  /// 已知七模块和非空身份才允许访问业务接口。
  bool get _hasIdentity =>
      _moduleNames.containsKey(widget.reference['module']) &&
      widget.reference['id'] is String &&
      (widget.reference['id'] as String).isNotEmpty;

  /// 页面状态、认证来源和服务器代次共同控制写入。
  bool get _available =>
      widget.enabled &&
      _repository != null &&
      identical(widget.repository, _repository) &&
      _repository.isCurrent;

  /// 只接受服务器已返回版本且尚未删除的记录作为编辑基线。
  bool get _canEdit =>
      _hasIdentity &&
      _available &&
      !_legacyServer &&
      _record['deletedAt'] == null;

  /// 模块和身份只能进入固定实体路由，不接受任意地址。
  String get _path =>
      '/entities/${Uri.encodeComponent('${widget.reference['module']}')}/${Uri.encodeComponent('${widget.reference['id']}')}';

  /// 失败或换服不能用返回值污染当前快照。
  Map<String, dynamic> _snapshot(
    Map<String, dynamic> response, {
    bool requireEditVersion = false,
  }) {
    // 要求精确身份匹配，避免空响应伪装成保存成功。
    final Map<String, dynamic> record = assistantMap(response['record']);
    if (response['id'] != widget.reference['id'] ||
        response['module'] != widget.reference['module'] ||
        record['updatedAt'] is! String) {
      throw const ApiFailure('无法核实记录版本，请重新读取');
    }
    if (requireEditVersion &&
        (response['editVersion'] is! String ||
            (response['editVersion'] as String).isEmpty)) {
      throw const ApiFailure('服务器未返回保存版本，请重新读取记录后核实结果');
    }
    return record;
  }

  /// 展开时读取当前状态；编辑前先等待本机上传检查点。
  Future<void> _load({bool edit = false}) async {
    if (!_hasIdentity ||
        !_available ||
        _loading ||
        _saving ||
        _pending != null) {
      return;
    }
    // 固定读取代次，不接受旧响应。
    final int request = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    try {
      if (edit) await widget.beforeEdit?.call();
      if (!_available) throw const ApiFailure('来源服务器已切换，此面板仅供查看');
      // 编辑一律基于最新服务器版本，未同步到本机也可操作。
      final Map<String, dynamic> response = await _repository!.request(
        'GET',
        _path,
      );
      // 只有时间记录领域更新需要额外的业务时区。
      final Map<String, dynamic> settings =
          edit && widget.reference['module'] == 'time'
          ? await _repository.request('GET', '/settings')
          : <String, dynamic>{};
      // 快照和版本必须来自同一份响应。
      final Map<String, dynamic> record = _snapshot(response);
      if (!mounted || request != _requestVersion || !_available) return;
      setState(() {
        _record = record;
        _editVersion = response['editVersion'] is String
            ? response['editVersion'] as String
            : null;
        _legacyServer = _editVersion == null || _editVersion!.isEmpty;
        _editing = edit && !_legacyServer && record['deletedAt'] == null;
        if (settings['timeZone'] is String) {
          _timeZone = settings['timeZone'] as String;
        }
        _conflict = false;
        _changes = <String, dynamic>{};
        _formVersion++;
        if (record['deletedAt'] != null) {
          _notice = '该记录已删除，仅可查看';
        } else if (_legacyServer) {
          _notice = '当前服务器尚不支持原地编辑，请更新 API 后重新读取';
        }
      });
    } catch (error) {
      if (mounted && request == _requestVersion) {
        setState(
          () => _error = error is ApiFailure ? error.message : '读取失败，请重试',
        );
      }
    } finally {
      if (mounted && request == _requestVersion) {
        setState(() => _loading = false);
      }
    }
  }

  /// 点击摘要仅切换面板，收起保留正在编辑的内容。
  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded && !_editing) _load();
  }

  /// 明确取消本地草稿，不撤销任何已提交到服务器的请求。
  void _cancel() => setState(() {
    _editing = false;
    _changes = <String, dynamic>{};
    _conflict = false;
    _error = null;
    _formVersion++;
  });

  /// 手动保存通过领域接口执行，不生成新的AI任务或聊天消息。
  Future<void> _save() async {
    if (!_canEdit ||
        _saving ||
        _loading ||
        _conflict ||
        (_pending == null && (_changes == null || _changes!.isEmpty))) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      if (_pending == null) {
        await widget.beforeEdit?.call();
        if (!_available) throw const ApiFailure('来源服务器已切换，请返回原服务器');
        _pending = <String, dynamic>{
          'operationId': const Uuid().v4(),
          'expectedUpdatedAt': _record['updatedAt'],
          'expectedVersion': _editVersion,
          'changes': Map<String, dynamic>.from(_changes!),
        };
      }
      // 原请求身份直到确定成功或拒绝才释放，断网不自动发起新写入。
      final Map<String, dynamic> response = await _repository!.request(
        'PATCH',
        _path,
        data: _pending,
      );
      if (!mounted || !_available) return;
      // HTTP成功也必须带回可核实的完整对象。
      final Map<String, dynamic> saved = _snapshot(
        response,
        requireEditVersion: true,
      );
      setState(() {
        _record = <String, dynamic>{..._record, ...saved};
        _pending = null;
        _editing = false;
        _editVersion = response['editVersion'] as String;
        _changes = <String, dynamic>{};
        _notice = '已保存';
        _formVersion++;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (error is AssistantApiFailure &&
            <int>{400, 401, 403, 404, 409, 422}.contains(error.statusCode)) {
          _pending = null;
          _conflict = error.statusCode == 409;
        }
        _error = _pending != null
            ? '保存结果尚未确认，请重试原请求核实结果'
            : error is ApiFailure
            ? error.message
            : '保存失败，请重试';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 业务字段按表单布局显示，卡片摘要始终保持单行。
  @override
  Widget build(BuildContext context) {
    // 服务端可选操作事实兼容历史没有操作种类的回执。
    final String operation =
        _operationNames[widget.reference['operation']] ?? '已保存';
    // 用户可理解的业务模块名称。
    final String module = _moduleNames[widget.reference['module']] ?? '记录';
    // 摘要只展示一个最重要字段，超长不挤占展开按钮。
    final String label = _recordLabel(_record, widget.reference['label']);
    return Padding(
      padding: const EdgeInsets.only(top: OmniSpacing.sm),
      child: OmniPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    expanded: _expanded,
                    child: OmniTextButton(
                      key: ValueKey<String>(
                        'assistant-result-toggle-${widget.reference['id']}',
                      ),
                      style: const ButtonStyle(
                        padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
                          EdgeInsets.zero,
                        ),
                        alignment: Alignment.centerLeft,
                      ),
                      onPressed: _toggle,
                      child: Row(
                        children: <Widget>[
                          Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                          ),
                          const SizedBox(width: OmniSpacing.xs),
                          Expanded(
                            child: Text(
                              '执行结果 • $operation$module • $label',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_showUndo)
                  OmniButton(
                    key: ValueKey<String>(
                      'assistant-result-undo-${widget.reference['id']}',
                    ),
                    label: '撤销新增',
                    variant: OmniButtonVariant.text,
                    onPressed: widget.enabled ? widget.onUndo : null,
                  ),
              ],
            ),
            if (_expanded) ...<Widget>[
              const SizedBox(height: OmniSpacing.md),
              if (_loading) const LinearProgressIndicator(),
              if (_moduleNames.containsKey(widget.reference['module']))
                AssistantResultForm(
                  key: ValueKey<String>('result-form-$_formVersion'),
                  module: widget.reference['module'] as String,
                  record: _record,
                  timeZone: _timeZone,
                  editing: _editing,
                  enabled:
                      _canEdit &&
                      !_saving &&
                      !_loading &&
                      _pending == null &&
                      !_conflict,
                  onChanged: (changes) {
                    if (mounted) setState(() => _changes = changes);
                  },
                )
              else
                SelectableText(
                  '${_record['body'] ?? _record['content'] ?? _record['title'] ?? _record['name'] ?? label}',
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: OmniSpacing.sm),
                  child: Text(_notice!),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: OmniSpacing.sm),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_hasIdentity)
                Padding(
                  padding: const EdgeInsets.only(top: OmniSpacing.md),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: OmniSpacing.sm,
                    runSpacing: OmniSpacing.sm,
                    children: <Widget>[
                      if (_conflict)
                        OmniButton(
                          label: '重新载入',
                          variant: OmniButtonVariant.secondary,
                          onPressed: _available && !_loading
                              ? () => _load(edit: true)
                              : null,
                        ),
                      if (_editing) ...<Widget>[
                        OmniButton(
                          label: '取消',
                          variant: OmniButtonVariant.secondary,
                          onPressed: !_saving && _pending == null
                              ? _cancel
                              : null,
                        ),
                        OmniButton(
                          label: _pending == null ? '保存' : '重试保存',
                          loading: _saving,
                          onPressed:
                              _canEdit &&
                                  !_saving &&
                                  !_loading &&
                                  !_conflict &&
                                  (_pending != null ||
                                      (_changes?.isNotEmpty ?? false))
                              ? _save
                              : null,
                        ),
                      ] else if (_legacyServer)
                        OmniButton(
                          label: '重新读取',
                          variant: OmniButtonVariant.secondary,
                          onPressed: _available && !_loading ? _load : null,
                        )
                      else
                        OmniButton(
                          label: '编辑',
                          variant: OmniButtonVariant.secondary,
                          onPressed: _canEdit && !_loading
                              ? () => _load(edit: true)
                              : null,
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
