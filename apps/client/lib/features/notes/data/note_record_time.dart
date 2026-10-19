/// 固定墙钟日期时间；设备时区变化不会改变记录归属及显示。
class NoteRecordTime {
  /// 用户选择的自然日。
  final String dayKey;

  /// 当日零点起的秒数。
  final int seconds;

  /// 选择时设备相对 UTC 的偏移分钟。
  final int utcOffsetMinutes;

  /// 创建固定记录时间。
  const NoteRecordTime(this.dayKey, this.seconds, this.utcOffsetMinutes);

  /// 从选择器的墙钟字段捕获时间，不对字段做时区换算。
  factory NoteRecordTime.selected(DateTime value) => NoteRecordTime(
    _day(value),
    value.hour * 3600 + value.minute * 60 + value.second,
    DateTime.now().timeZoneOffset.inMinutes,
  );

  /// 兼容旧记录：已知偏移还原创建时钟，未知时区统一使用 UTC。
  factory NoteRecordTime.resolve({
    required String dayKey,
    required DateTime createdAt,
    String? creationTimezone,
    int? seconds,
    int? utcOffsetMinutes,
  }) {
    // 仅解析原始偏移，不猜测时区地区。
    final RegExpMatch? match = RegExp(r'\|([+-])(\d{2}):(\d{2})$')
        .firstMatch(creationTimezone ?? '');
    // 无效历史偏移与未知时区一律按 UTC，与服务端保持一致。
    final int historicMinutes = match == null
        ? 0
        : int.parse(match[2]!) * 60 + int.parse(match[3]!);
    final int historicOffset =
        match != null && int.parse(match[3]!) < 60 && historicMinutes <= 840
        ? historicMinutes * (match[1] == '-' ? -1 : 1)
        : 0;
    final int offset = utcOffsetMinutes ?? historicOffset;
    // UTC 容器只承载墙钟字段，不随当前设备换算。
    final DateTime clock = createdAt.toUtc().add(Duration(minutes: offset));
    return NoteRecordTime(
      dayKey,
      seconds ?? clock.hour * 3600 + clock.minute * 60 + clock.second,
      offset,
    );
  }

  /// 将自然日及秒数还原为仅供显示和选择的墙钟字段。
  DateTime get wallTime {
    // 使用 UTC 容器避免夏令时归一化改变用户所选字段。
    final DateTime date = DateTime.parse('${dayKey}T00:00:00Z');
    return date.add(Duration(seconds: seconds));
  }

  /// 根据选择时偏移还原实际瞬间，用于范围校验。
  DateTime get instant =>
      wallTime.subtract(Duration(minutes: utcOffsetMinutes));

  /// 统一显示秒级记录时间。
  String get label => '$dayKey $clockLabel';

  /// 二十四小时制时钟。
  String get clockLabel =>
      '${(seconds ~/ 3600).toString().padLeft(2, '0')}:'
      '${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:'
      '${(seconds % 60).toString().padLeft(2, '0')}';

  /// 主动修改只能选择真实有效的历史自然日及当前瞬间以前。
  void validate({DateTime? now}) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dayKey) ||
        seconds < 0 ||
        seconds >= 86400 ||
        utcOffsetMinutes < -840 ||
        utcOffsetMinutes > 840) {
      throw const FormatException('记录时间无效');
    }
    // DateTime.parse 会归一化无效日期，必须往返比对。
    final DateTime date = DateTime.parse('${dayKey}T00:00:00Z');
    if (_day(date) != dayKey ||
        date.year < 1970 ||
        instant.isAfter((now ?? DateTime.now()).toUtc())) {
      throw const FormatException('请选择1970年至当前时刻的记录时间');
    }
  }

  /// 不依赖设备时区的自然日格式。
  static String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}
