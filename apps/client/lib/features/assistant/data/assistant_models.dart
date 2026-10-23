import 'dart:convert';

/// 将受控接口对象转换为可读取的映射。
Map<String, dynamic> assistantMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

/// 提取分页接口或嵌套数组中的对象。
List<Map<String, dynamic>> assistantItems(Object? value) => value is List
    ? value.map(assistantMap).toList(growable: true)
    : <Map<String, dynamic>>[];

/// 不会继续自动执行的任务状态。
const Set<String> assistantTerminalStates = <String>{
  'succeeded',
  'failed',
  'cancelled',
};

/// 任务状态的界面说明，不暴露内部思考。
String assistantStatusLabel(String? status) => switch (status) {
  'queued' => '等待处理',
  'running' => '正在处理',
  'waitingConfirmation' => '等待确认',
  'waitingInput' => '需要补充信息',
  'succeeded' => '已完成',
  'failed' => '处理失败',
  'cancelled' => '已停止',
  'submissionUnknown' => '正在核实执行结果',
  _ => '',
};

/// 一个可按序号恢复的服务端事件。
class AssistantEvent {
  /// 单任务递增事件身份。
  final int seq;

  /// 事件种类。
  final String type;

  /// 绑定的运行身份。
  final String runId;

  /// 受控事件负载。
  final Map<String, dynamic> data;

  /// 创建已解析事件。
  const AssistantEvent({
    required this.seq,
    required this.type,
    required this.runId,
    required this.data,
  });

  /// 解析事件负载，兼容 SSE 标准 id 字段。
  factory AssistantEvent.fromJson(
    Map<String, dynamic> json, {
    String? eventId,
  }) => AssistantEvent(
    seq: (json['seq'] as num?)?.toInt() ?? int.tryParse(eventId ?? '') ?? 0,
    type: json['type'] as String? ?? '',
    runId: json['runId'] as String? ?? '',
    data: assistantMap(json['data']),
  );
}

/// 按完整 SSE 帧解析，不执行不完整 JSON 或 Function Call。
Stream<AssistantEvent> decodeAssistantEvents(Stream<List<int>> bytes) async* {
  // 多行 data 组成一条完整帧。
  final List<String> data = <String>[];
  // SSE 断点身份。
  String? eventId;
  await for (final String line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        // 只有完整帧才进入持久事件处理。
        final Object? decoded = jsonDecode(data.join('\n'));
        if (decoded is Map) {
          yield AssistantEvent.fromJson(
            assistantMap(decoded),
            eventId: eventId,
          );
        }
      }
      data.clear();
      eventId = null;
    } else if (line.startsWith('data:')) {
      data.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
    } else if (line.startsWith('id:')) {
      eventId = line.substring(3).trim();
    }
  }
}
