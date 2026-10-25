import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 回答内默认收起的执行记录，计时与执行事实均来自会话控制器。
class AssistantExecutionProgress extends StatefulWidget {
  /// 当前已知耗时；历史未知时不补造秒数。
  final num? elapsedMs;

  /// 当前回答是否仍在执行。
  final bool running;

  /// 归属当前回答的执行步骤及经过脱敏的工具输入。
  final List<Map<String, dynamic>> steps;

  /// 继承Windows助手局部颜色。
  final AssistantWindowsPalette colors;

  /// 创建单条回答的进度头。
  const AssistantExecutionProgress({
    required this.elapsedMs,
    required this.running,
    required this.steps,
    required this.colors,
    super.key,
  });

  /// 展开偏好归属于稳定回答身份。
  @override
  State<AssistantExecutionProgress> createState() =>
      _AssistantExecutionProgressState();
}

/// 仅维护显示偏好，不在视图中生成执行事实。
class _AssistantExecutionProgressState
    extends State<AssistantExecutionProgress> {
  /// 执行中和历史回答均默认收起。
  bool _expanded = false;

  /// 每次工具调用与模型思考均有独立展开状态。
  final Set<String> _expandedTools = <String>{};

  /// 跨占位和正式回答迁移时只恢复一次偏好。
  bool _restored = false;

  /// 没有步骤的旧历史也保留用时文字悬停反馈。
  bool _timeHovered = false;

  /// 兼容此前仅保存总开关的页面状态。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    // 稳定回答键在首个正文到达前后保持一致。
    final Object? saved = PageStorage.maybeOf(context)
        ?.readState(context, identifier: widget.key);
    if (saved is bool) _expanded = saved;
    if (saved is Map) {
      _expanded = saved['expanded'] == true;
      if (saved['tools'] is List) {
        _expandedTools.addAll((saved['tools'] as List).whereType<String>());
      }
    }
  }

  /// 页面存储仅保存当前回答的折叠偏好。
  void _savePreference() {
    if (widget.key == null) return;
    PageStorage.maybeOf(context)?.writeState(context, <String, Object>{
      'expanded': _expanded,
      'tools': _expandedTools.toList(),
    }, identifier: widget.key);
  }

  /// 手动展开选择不受后续流式正文影响。
  void _toggle() {
    setState(() => _expanded = !_expanded);
    _savePreference();
  }

  /// 工具与思考分别展开，重复事件更新不会产生新面板。
  void _toggleTool(String id) {
    setState(() {
      if (!_expandedTools.remove(id)) _expandedTools.add(id);
    });
    _savePreference();
  }

  /// 状态区分规划、实际完成和等待用户。
  String _status(String? value) => switch (value) {
    'running' => '执行中',
    'succeeded' => '已完成',
    'planned' => '已规划',
    'waiting' => '等待中',
    'failed' => '失败',
    'cancelled' => '已停止',
    _ => '状态待更新',
  };

  /// 仅模型明确返回可读文字或省略标记时提供思考入口。
  bool _hasReasoning(Map<String, dynamic> step) =>
      step['kind'] == 'model' &&
      step['reasoning'] is Map &&
      (((step['reasoning'] as Map)['text'] is String &&
              ((step['reasoning'] as Map)['text'] as String).isNotEmpty) ||
          (step['reasoning'] as Map)['truncated'] == true);

  /// 思考与工具共用执行链，不把思考正文拼进状态摘要。
  String _stepLabel(Map<String, dynamic> step) => _hasReasoning(step)
      ? '思考过程'
      : step['label'] is String
      ? step['label'] as String
      : '执行工具';

  /// 收起时只显示当前执行阶段；无运行项时取最后观察到的步骤。
  String get _summary {
    for (final Map<String, dynamic> step in widget.steps.reversed) {
      if (step['status'] == 'running') return '${_stepLabel(step)} · 执行中';
    }
    if (widget.steps.isEmpty) return widget.running ? '正在处理' : '已完成';
    // 末项状态必须依据服务器，不把计划描述为实际保存。
    final Map<String, dynamic> latest = widget.steps.last;
    return '${_stepLabel(latest)} · ${_status(latest['status'] as String?)}';
  }

  /// 工具行展开JSON参数，模型行展开可读思考，真实提交保留状态展示。
  Widget _step(Map<String, dynamic> step) {
    // 步骤身份来自服务器，不能用函数名合并不同调用。
    final String id = step['id'] as String? ?? '';
    // 详情字段仅接受服务端的新结构，旧历史显示明确的不可用提示。
    final Map? tool = step['tool'] is Map ? step['tool'] as Map : null;
    // 模型思考与工具参数使用各自的详情面板。
    final bool hasReasoning = _hasReasoning(step);
    // 仅接受服务端公开的文字副本，不读取原始模型协议。
    final Map? reasoning = hasReasoning ? step['reasoning'] as Map : null;
    // 工具和思考均可单独展开，提交步骤保持原有状态展示。
    final bool inspectable = step['kind'] == 'tool' || hasReasoning;
    // 每项独立折叠，不随总开关丢失。
    final bool expanded = _expandedTools.contains(id);
    // 工具名称与执行摘要分别保留完整文本，由实际可用宽度决定省略。
    final String label = _stepLabel(step);
    // 无摘要的旧记录不额外占据名称右侧空间。
    final String detail = step['detail'] is String
        ? step['detail'] as String
        : '';
    // 错误只依据服务端状态着色。
    final Color color = step['status'] == 'failed'
        ? OmniColors.of(context).danger
        : widget.colors.muted;
    // 图标区分模型、工具和真实保存。
    final IconData icon = switch (step['status']) {
      'failed' => Icons.error_outline,
      'cancelled' => Icons.stop_circle_outlined,
      _ => switch (step['kind']) {
        'model' => Icons.chat_bubble_outline,
        'commit' => Icons.save_outlined,
        _ => Icons.build_outlined,
      },
    };
    // 名称和摘要保持同一行，右侧箭头与状态始终保留完整操作入口。
    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: <Widget>[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth:
                          constraints.maxWidth * (detail.isEmpty ? 1 : .6),
                    ),
                    child: Text(
                      label,
                      key: ValueKey<String>('assistant-step-label-$id'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, height: 1.5, color: color),
                    ),
                  ),
                  if (detail.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Tooltip(
                        message: detail,
                        child: Text(
                          detail,
                          key: ValueKey<String>('assistant-step-detail-$id'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (inspectable) ...<Widget>[
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              key: ValueKey<String>('assistant-step-arrow-$id'),
              size: 16,
              color: color,
            ),
            const SizedBox(width: 4),
          ],
          Text(
            _status(step['status'] as String?),
            key: ValueKey<String>('assistant-step-status-$id'),
            style: TextStyle(fontSize: 12, height: 1.6, color: color),
          ),
        ],
      ),
    );
    return Column(
      key: ValueKey<String>('assistant-execution-step-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (inspectable)
          OmniDisclosureToggle(
            expanded: expanded,
            child: OmniTextButton(
              key: ValueKey<String>(
                hasReasoning
                    ? 'assistant-reasoning-toggle-$id'
                    : 'assistant-tool-toggle-$id',
              ),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
                alignment: Alignment.centerLeft,
              ),
              onPressed: () => _toggleTool(id),
              child: row,
            ),
          )
        else
          row,
        OmniDisclosure(
          expanded: hasReasoning && expanded,
          child: Padding(
            key: ValueKey<String>('assistant-reasoning-content-$id'),
            padding: const EdgeInsets.fromLTRB(23, 6, 0, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if ((reasoning?['text'] as String? ?? '').isNotEmpty)
                  SelectableText(
                    reasoning!['text'] as String,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: widget.colors.muted,
                    ),
                  ),
                if (reasoning?['truncated'] == true)
                  Text(
                    '思考内容较长，后续部分已省略',
                    style: TextStyle(fontSize: 12, color: widget.colors.muted),
                  ),
              ],
            ),
          ),
        ),
        OmniDisclosure(
          expanded: step['kind'] == 'tool' && expanded,
          child: Padding(
            key: ValueKey<String>('assistant-tool-arguments-$id'),
            padding: const EdgeInsets.fromLTRB(23, 6, 0, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (tool?['name'] is String)
                  Text(
                    tool!['name'] as String,
                    style: TextStyle(fontSize: 12, color: widget.colors.ink),
                  ),
                const SizedBox(height: 4),
                SelectableText(
                  tool?['arguments'] is Map
                      ? const JsonEncoder.withIndent('  ')
                            .convert(tool!['arguments'])
                      : '此历史记录未保存调用参数',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: widget.colors.ink,
                  ),
                ),
                if (tool?['truncated'] == true)
                  Text(
                    '参数过长，部分内容已省略',
                    style: TextStyle(fontSize: 12, color: widget.colors.muted),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 用时悬停只改变前景色，背景与点击水波均保持透明。
  @override
  Widget build(BuildContext context) {
    if (widget.elapsedMs == null && widget.steps.isEmpty) {
      return const SizedBox.shrink();
    }
    // 实时从零显示，完成后保留不足一秒的表达。
    final int seconds = widget.running
        ? (widget.elapsedMs ?? 0) ~/ 1000
        : ((widget.elapsedMs ?? 0) / 1000).ceil();
    // 未知历史不把缺失用时解释成零。
    final String label = widget.elapsedMs == null
        ? '执行过程'
        : seconds == 0 && !widget.running
        ? '用时不足1秒'
        : '用时 $seconds秒';
    // 明亮主题悬停使用黑字，深色继承可读的主要文字色。
    final Color hoverColor = Theme.of(context).brightness == Brightness.light
        ? Colors.black
        : widget.colors.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.steps.isEmpty)
            MouseRegion(
              onEnter: (_) => setState(() => _timeHovered = true),
              onExit: (_) => setState(() => _timeHovered = false),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: _timeHovered ? hoverColor : widget.colors.muted,
                ),
              ),
            )
          else
            OmniDisclosureToggle(
              expanded: _expanded,
              child: OmniTextButton(
                key: const ValueKey<String>('assistant-execution-toggle'),
                style: ButtonStyle(
                  padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                    EdgeInsets.symmetric(vertical: 3),
                  ),
                  minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 28)),
                  overlayColor: const WidgetStatePropertyAll<Color>(
                    Colors.transparent,
                  ),
                  backgroundColor: const WidgetStatePropertyAll<Color>(
                    Colors.transparent,
                  ),
                  foregroundColor: WidgetStateProperty.resolveWith<Color>(
                    (states) =>
                        states.contains(WidgetState.hovered) ||
                            states.contains(WidgetState.focused)
                        ? hoverColor
                        : widget.colors.muted,
                  ),
                ),
                onPressed: widget.steps.isEmpty ? null : _toggle,
                child: Row(
                  children: <Widget>[
                    Text(label, style: const TextStyle(fontSize: 14)),
                    const SizedBox(width: 4),
                    if (widget.steps.isNotEmpty)
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: widget.colors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          OmniDisclosure(
            expanded: _expanded && widget.steps.isNotEmpty,
            child: Padding(
              padding: const EdgeInsets.only(top: 9, bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final Map<String, dynamic> step in widget.steps)
                    _step(step),
                ],
              ),
            ),
          ),
          const SizedBox(height: 9),
          Divider(height: 1, color: widget.colors.line),
        ],
      ),
    );
  }
}
