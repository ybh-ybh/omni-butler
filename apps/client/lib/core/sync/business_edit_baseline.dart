import 'dart:convert';

/// 表单基线与SDK队列前值解决不同时间窗口：防止远端已下行后旧表单复制回旧字段。
void assertBusinessEditBaseline(
  Map<String, dynamic>? baseline,
  Map<String, dynamic>? current,
) {
  if (baseline == null) return;
  // 本机同步提示状态不是业务事实，不能让状态刷新制造虚假冲突。
  final Map<String, dynamic> original = Map<String, dynamic>.from(baseline)
    ..remove('syncState');
  // 仍然比较真实字段及更新时间，不依据设备时钟先后猜测谁更新。
  final Map<String, dynamic>? latest = current == null
      ? null
      : (Map<String, dynamic>.from(current)..remove('syncState'));
  if (latest == null || jsonEncode(original) != jsonEncode(latest)) {
    throw const FormatException('记录已在其他设备或 MCP 中修改。当前草稿未提交，请保留草稿并重新核对最新记录后保存。');
  }
}
