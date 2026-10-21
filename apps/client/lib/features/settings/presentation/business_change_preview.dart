import 'package:flutter/material.dart';

/// 审批界面优先展示用户可理解字段，保留精确值。
const Map<String, String> _fieldLabels = <String, String>{
  'id': '记录身份',
  'time_zone': '时区',
  'category_ids': '分类身份',
  'tag_ids': '标签身份',
  'base_revision': '正文基线修订',
  'name': '名称',
  'title': '标题',
  'content': '内容',
  'source': '来源',
  'body': '正文',
  'text': '追加内容',
  'activity': '活动',
  'category': '分类',
  'location': '位置',
  'quantity': '数量',
  'status': '状态',
  'base_status': '基础状态',
  'notes': '备注',
  'description': '说明',
  'purchase_price_cents': '购买金额（分）',
  'price_cents': '金额（分）',
  'amount_cents': '支付金额（分）',
  'purchase_date': '购买日期',
  'expiration_date': '到期日期',
  'started_at': '开始时刻',
  'ended_at': '结束时刻',
  'scheduled_date': '计划日期',
  'completed_at': '完成时刻',
  'is_completed': '是否完成',
  'is_archived': '是否归档',
  'is_pinned': '是否置顶',
  'deleted_at': '回收站时间',
  'auto_renew': '自动续费记录',
  'billing_cycle': '计费周期',
  'interval_value': '周期数值',
  'interval_unit': '周期单位',
  'day_key': '记录日期',
  'record_time_seconds': '日内秒数',
  'record_utc_offset_minutes': '时区偏移（分钟）',
  'parent_id': '父任务',
  'parent_item_id': '父物品',
  'repeat_rule': '重复规则',
  'priority_quadrant': '四象限',
  'tags': '标签',
  'is_revoked': '是否撤销',
  'valid_from': '账期开始',
  'valid_until': '账期结束',
};

/// 输入使用camelCase、事实使用snake_case，显示时共用同一业务标签。
String _fieldLabel(String field) =>
    _fieldLabels[field.replaceAllMapped(
      RegExp('[A-Z]'),
      (Match match) => '_${match.group(0)!.toLowerCase()}',
    )] ??
    field;

/// 将精确字段值展示为纯文字，绝不执行模型生成的HTML或按钮。
String _displayValue(Object? value) => value == null
    ? '未设置'
    : value is bool
    ? (value ? '是' : '否')
    : value is List
    ? value.map(_displayValue).join('、')
    : value.toString();

/// 操作的固定输入与实际影响分开展示，让同名目标和无变化请求也能被核对。
class BusinessParametersPreview extends StatelessWidget {
  /// 已冻结且不允许在审批页修改的参数。
  final Map<String, dynamic> input;

  /// 创建纯文字参数清单。
  const BusinessParametersPreview({super.key, required this.input});

  /// 展示每项精确值，不执行或重新解释任何资料内容。
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      for (final MapEntry<String, dynamic> field in input.entries)
        SelectableText(
          '${_fieldLabel(field.key)}：${_displayValue(field.value)}',
        ),
    ],
  );
}

/// 纯文字前后差异，不把资料内容渲染成可执行组件。
class BusinessChangePreview extends StatelessWidget {
  /// 服务端冻结变化。
  final Map<String, dynamic> change;

  /// 创建一个真实影响记录。
  const BusinessChangePreview({super.key, required this.change});

  /// 每个已变化字段同时展示之前与之后。
  @override
  Widget build(BuildContext context) {
    // 明确新建记录的正式身份尚未分配。
    final Map<String, dynamic> after = Map<String, dynamic>.from(
      change['after'] as Map,
    );
    // 新记录不存在之前事实。
    final Map<String, dynamic> before = change['before'] == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(change['before'] as Map);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${change['newRecord'] == true ? '新增' : '修改'} · ${change['label']}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (change['id'] != null) SelectableText('记录身份：${change['id']}'),
          for (final String field in after.keys)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(
                '${_fieldLabel(field)}\n${_displayValue(before[field])} → ${_displayValue(after[field])}',
              ),
            ),
        ],
      ),
    );
  }
}
