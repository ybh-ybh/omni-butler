import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_entity_details.dart';
import 'package:omni_butler/app/theme/app_tokens.dart';
import 'package:omni_butler/features/assistant/data/assistant_models.dart';
import 'package:omni_butler/shared/ui/omni_ui.dart';

/// 助手卡片采用业务语义标签，不直接显示协议字段。
const Map<String, String> _labels = <String, String>{
  'name': '名称',
  'title': '标题',
  'activity': '活动',
  'body': '正文',
  'content': '内容',
  'text': '内容',
  'description': '说明',
  'notes': '备注',
  'category': '分类',
  'categoryNames': '分类',
  'category_names': '分类',
  'tags': '标签',
  'tagNames': '标签',
  'tag_names': '标签',
  'started_at': '开始',
  'startedAt': '开始',
  'ended_at': '结束',
  'endedAt': '结束',
  'scheduled_date': '日期',
  'scheduledDate': '日期',
  'dueAt': '截止',
  'status': '状态',
  'location': '位置',
  'locationNames': '位置',
  'location_names': '位置',
  'quantity': '数量',
  'amount_cents': '金额（分）',
  'price_cents': '金额（分）',
  'expiration_date': '到期日期',
  'billing_cycle': '周期',
  'is_completed': '完成',
  'is_archived': '归档',
  'is_pinned': '置顶',
  'auto_renew': '自动续费',
  'recordedAt': '记录时间',
  'source': '来源',
  'day_key': '日期',
  'purchase_price_cents': '购买金额（分）',
  'purchase_date': '购买日期',
  'purchase_url': '购买地址',
  'purchase_platform': '购买平台',
  'warranty_expiration': '保修到期',
  'provider': '服务商',
  'website_url': '服务地址',
  'base_status': '基础状态',
  'is_permanent': '永久会员',
  'renewal_date': '续费日期',
  'needs_renewal': '需要续费',
  'expiration_reminder_enabled': '到期提醒',
  'expiration_reminder_days': '到期提前天数',
  'renewal_reminder_enabled': '续费提醒',
  'renewal_reminder_days': '续费提前天数',
  'reminder_time_minutes': '提醒时刻（当天分钟）',
  'cancel_guide': '取消指引',
  'interval_value': '间隔数',
  'interval_unit': '间隔单位',
  'reminder_enabled': '提醒',
  'reminder_days_before': '提前提醒天数',
  'initial_completed_at': '首次完成时间',
  'last_completed_at': '最近完成',
  'is_revoked': '撤销记录',
  'completed_at': '完成时间',
  'due_at': '截止',
  'reminder_at': '提醒时间',
  'priority_quadrant': '四象限',
  'task_type': '任务类型',
  'progress_unit': '进度单位',
  'sort_order': '顺序',
  'repeat_rule': '重复规则',
  'deleted_at': '回收站时间',
  'valid_from': '账期开始',
  'valid_until': '账期结束',
  'created_at': '创建时间',
  'updated_at': '更新时间',
};

/// 输入和数据库事实共用中英文语义映射。
String? _labelFor(String field) =>
    _labels[field] ??
    _labels[field.replaceAllMapped(
      RegExp('[A-Z]'),
      (Match match) => '_${match.group(0)!.toLowerCase()}',
    )];

/// 只格式化受控资料，不执行模型 HTML、代码或链接。
String assistantDisplayValue(Object? value) {
  if (value == null) return '未设置';
  if (value is bool) return value ? '是' : '否';
  if (value is List) return value.map(assistantDisplayValue).join('、');
  if (value is Map) {
    return '${value['name'] ?? value['title'] ?? value['label'] ?? '详情'}';
  }
  // UUID 为内部身份，不当作分类名称呈现。
  final String text = value.toString();
  if (RegExp(
    r'^[0-9a-f]{8}-[0-9a-f-]{27,}$',
    caseSensitive: false,
  ).hasMatch(text)) {
    return '已关联记录';
  }
  // ISO 日期保持偏移，避免用设备时区重新解释自然日。
  return text.replaceFirstMapped(
    RegExp(r'^(\d{4}-\d{2}-\d{2})T'),
    (Match match) => '${match.group(1)} ',
  );
}

/// 分类关联优先显示后端解析名称，避免同一项再展示原始UUID数组。
bool _visibleField(String field, Map<String, dynamic> fields) {
  if (_labelFor(field) == null) return false;
  if (field == 'category' && fields.containsKey('categoryNames')) return false;
  if (field == 'tags' && fields.containsKey('tagNames')) return false;
  if (field == 'location' && fields.containsKey('locationNames')) return false;
  return true;
}

/// 标签旧存储的JSON数组仅作为标签数据解析，不把正文当协议。
String _fieldValue(String field, Object? value) {
  if (field == 'tags' && value is String && value.startsWith('[')) {
    try {
      return assistantDisplayValue(jsonDecode(value));
    } catch (_) {
      return '标签暂不可读';
    }
  }
  return assistantDisplayValue(value);
}

/// 展示冻结的业务变化及关联影响。
class AssistantChangeCard extends StatelessWidget {
  /// 服务端真实预演或回执。
  final Map<String, dynamic> value;

  /// 创建受控变化列表。
  const AssistantChangeCard({required this.value, super.key});

  /// 逐字段展示已知业务语义，隐藏内部凭据。
  Widget _fields(
    Map<String, dynamic> fields, {
    Map<String, dynamic>? before,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      for (final MapEntry<String, dynamic> field in fields.entries)
        if (_visibleField(field.key, fields))
          Padding(
            padding: const EdgeInsets.only(top: OmniSpacing.xs),
            child: SelectableText(
              '${_labelFor(field.key)}：${before == null ? '' : '${_fieldValue(field.key, before[field.key])} → '}${_fieldValue(field.key, field.value)}',
            ),
          ),
    ],
  );

  /// 原生差异列表不把材料内容解释为授权。
  @override
  Widget build(BuildContext context) {
    // 原工具可能返回批次预演或单条变化。
    final List<Map<String, dynamic>> changes = assistantItems(value['changes']);
    // 批次结果按顺序展开。
    final List<Map<String, dynamic>> steps = assistantItems(
      value['steps'] ?? value['results'] ?? value['values'],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (value['summary'] is String)
          SelectableText(value['summary'] as String),
        for (final Map<String, dynamic> change in changes)
          Padding(
            padding: const EdgeInsets.only(top: OmniSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${change['newRecord'] == true ? '新增' : '变更'} · ${change['label'] ?? '记录'}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                _fields(
                  assistantMap(change['after']),
                  before: change['before'] is Map
                      ? assistantMap(change['before'])
                      : null,
                ),
              ],
            ),
          ),
        for (final Map<String, dynamic> step in steps)
          Padding(
            padding: const EdgeInsets.only(top: OmniSpacing.sm),
            child: AssistantChangeCard(
              value: assistantMap(step['preview'] ?? step['result'] ?? step),
            ),
          ),
        if (changes.isEmpty && steps.isEmpty)
          _fields(
            assistantMap(
              value['record'] ?? value['note'] ?? value['after'] ?? value,
            ),
          ),
        if (value['relatedImpact'] != null)
          Text('关联影响：${assistantDisplayValue(value['relatedImpact'])}'),
        if (value['warnings'] is List)
          Text(
            (value['warnings'] as List).map(assistantDisplayValue).join('\n'),
          ),
      ],
    );
  }
}

/// 一次批量操作的固定确认卡片。
class AssistantPlanCard extends StatelessWidget {
  /// 绑定版本与摘要的计划。
  final Map<String, dynamic> plan;

  /// 当前卡片是否可以操作。
  final bool enabled;

  /// 卡片决策，只有按钮触发执行授权。
  final ValueChanged<String> onDecision;

  /// 修订方案时进入文字输入。
  final VoidCallback onEdit;

  /// 创建原生确认卡。
  const AssistantPlanCard({
    required this.plan,
    required this.enabled,
    required this.onDecision,
    required this.onEdit,
    super.key,
  });

  /// 显示完整目标数和真实预演。
  @override
  Widget build(BuildContext context) => OmniPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '确认修改 ${plan['targetCount'] ?? ''} 个对象',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: OmniSpacing.xs),
        const Text('确认后按此清单执行；修改方案需要重新确认。'),
        AssistantChangeCard(value: assistantMap(plan['preview'])),
        const SizedBox(height: OmniSpacing.md),
        Wrap(
          spacing: OmniSpacing.sm,
          runSpacing: OmniSpacing.xs,
          children: <Widget>[
            OmniButton(
              label: '确认执行',
              onPressed: enabled ? () => onDecision('confirm') : null,
            ),
            OmniButton(
              label: '修改方案',
              variant: OmniButtonVariant.secondary,
              onPressed: enabled ? onEdit : null,
            ),
            OmniButton(
              label: '取消',
              variant: OmniButtonVariant.text,
              onPressed: enabled ? () => onDecision('cancel') : null,
            ),
          ],
        ),
      ],
    ),
  );
}

/// 结果、重名选择和冲突都由原生结构化组件展示。
class AssistantMessageCard extends StatelessWidget {
  /// 已持久保存的服务器卡片。
  final Map<String, dynamic> card;

  /// 旧服务器缓存不允许进行任何卡片操作。
  final bool enabled;

  /// 选择对象通过明确的新消息继续任务。
  final void Function(String content, Map<String, dynamic> selection) onChoice;

  /// 编辑只把受控引用交给输入框，不直接执行修改。
  final ValueChanged<Map<String, dynamic>>? onEditReference;

  /// 创建只执行受控行为的卡片。
  const AssistantMessageCard({
    required this.card,
    required this.enabled,
    required this.onChoice,
    this.onEditReference,
    super.key,
  });

  /// 由真实引用打开精确服务器快照，不向不支持定位的页面传无效参数。
  void _open(BuildContext context, Map<String, dynamic> reference) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            AssistantEntityDetails(reference: reference),
      ),
    );
  }

  /// 构建当前卡片的可读事实。
  @override
  Widget build(BuildContext context) {
    // 卡片受控种类。
    final String type = card['type'] as String? ?? '';
    if (!<String>{
      'result',
      'conflict',
      'choice',
      'error',
      'memory',
      'references',
    }.contains(type)) {
      return const SizedBox.shrink();
    }
    // 重名候选的真实对象。
    final List<Map<String, dynamic>> choices = assistantItems(
      card['choices'] ?? card['options'],
    );
    // 受控结果引用包含可直接定位的真实对象。
    final List<Map<String, dynamic>> references = assistantItems(
      card['entityRefs'] ?? assistantMap(card['result'])['entityRefs'],
    );
    return Padding(
      padding: const EdgeInsets.only(top: OmniSpacing.sm),
      child: OmniPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              card['title'] as String? ??
                  switch (type) {
                    'conflict' => '数据发生变化，请重新核对',
                    'choice' => '请选择对象',
                    'error' => '操作未完成',
                    'memory' => '记忆已更新',
                    'references' => '参考记录',
                    _ => '执行结果',
                  },
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (card['message'] is String)
              Padding(
                padding: const EdgeInsets.only(top: OmniSpacing.xs),
                child: SelectableText(card['message'] as String),
              ),
            if (type == 'references')
              const Text('部分来源 · 最多展示20条参考记录，统计覆盖范围见正文'),
            if (type == 'result') const Text('服务器已保存；其他设备将在同步后显示。'),
            AssistantChangeCard(
              value: assistantMap(card['result'] ?? card['preview'] ?? card),
            ),
            if (choices.isNotEmpty)
              Wrap(
                spacing: OmniSpacing.sm,
                children: <Widget>[
                  for (final Map<String, dynamic> choice in choices)
                    OmniButton(
                      label:
                          '${choice['name'] ?? choice['title'] ?? choice['label'] ?? '选择此项'}',
                      variant: OmniButtonVariant.secondary,
                      onPressed: enabled
                          ? () => onChoice(
                              '选择${choice['name'] ?? choice['title'] ?? choice['label'] ?? '此对象'}',
                              <String, dynamic>{
                                'id': choice['id'],
                                'module': choice['module'],
                              },
                            )
                          : null,
                    ),
                ],
              ),
            for (final Map<String, dynamic> reference in references.take(
              type == 'references' ? 20 : references.length,
            ))
              Wrap(
                spacing: OmniSpacing.sm,
                children: <Widget>[
                  OmniButton(
                    label: '查看${reference['label'] ?? '记录'}',
                    variant: OmniButtonVariant.text,
                    onPressed: enabled ? () => _open(context, reference) : null,
                  ),
                  if (onEditReference != null && type == 'result')
                    OmniButton(
                      label: '编辑',
                      variant: OmniButtonVariant.text,
                      onPressed: enabled
                          ? () => onEditReference!(reference)
                          : null,
                    ),
                ],
              ),
            if (card['reference'] is Map)
              Align(
                alignment: Alignment.centerLeft,
                child: OmniButton(
                  label: '查看记录',
                  variant: OmniButtonVariant.text,
                  onPressed: enabled
                      ? () => _open(context, assistantMap(card['reference']))
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
