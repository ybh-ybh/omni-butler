import { BadRequestException } from '@nestjs/common';

/// 记录时间的持久字段；旧记录允许整组为空，由创建事实确定默认值。
export interface NoteRecordTimeSource {
  /// 创建时的原始时刻。
  createdAt: Date;
  /// 创建时的时区名称及固定偏移。
  creationTimezone: string;
  /// 记录自然日内的秒数。
  recordTimeSeconds?: number | null;
  /// 设定记录时间时的固定 UTC 偏移。
  recordUtcOffsetMinutes?: number | null;
}

/// 只检查字段结构，不限制历史 PUT 与换服快照的归档日期范围。
export function validateNoteRecordTime(data: Record<string, unknown>, patch: boolean): void {
  // PowerSync 差量可能省略赋值未变的列，PATCH 在事务内补全当前时间组。
  const hasSeconds = Object.hasOwn(data, 'record_time_seconds');
  // 显式 undefined 同样属于非法字段，不能作为缺省绕过校验。
  const hasOffset = Object.hasOwn(data, 'record_utc_offset_minutes');
  if (!patch && hasSeconds !== hasOffset) throw new BadRequestException('笔记记录时间必须同时包含秒数与时区偏移');
  if (hasSeconds || hasOffset) {
    // 仅旧完整行允许整组空值，主动 PATCH 不能清空记录时间。
    const legacy = data.record_time_seconds === null && data.record_utc_offset_minutes === null;
    if (legacy && !patch) return;
    if (hasSeconds && (!Number.isSafeInteger(data.record_time_seconds) || (data.record_time_seconds as number) < 0 || (data.record_time_seconds as number) > 86399)) throw new BadRequestException('笔记记录时间秒数必须为零至八万六千三百九十九的整数');
    if (hasOffset && (!Number.isSafeInteger(data.record_utc_offset_minutes) || (data.record_utc_offset_minutes as number) < -840 || (data.record_utc_offset_minutes as number) > 840)) throw new BadRequestException('笔记记录时间偏移必须为负八百四十至八百四十分钟的整数');
    if (!patch && data.day_key === undefined) throw new BadRequestException('笔记记录时间变更必须同时包含日期');
  }
}

/// 从稳定创建事实推导旧记录的时分秒，不依赖服务端或设备的当前时区。
export function effectiveNoteRecordTime(source: NoteRecordTimeSource): { seconds: number; offsetMinutes: number } {
  if (source.recordTimeSeconds != null && source.recordUtcOffsetMinutes != null) return { seconds: source.recordTimeSeconds, offsetMinutes: source.recordUtcOffsetMinutes };
  // 创建时区只读取末尾偏移；未知历史使用 UTC，不推断地区。
  const match = /\|([+-])(\d{2}):(\d{2})$/.exec(source.creationTimezone);
  // 超出实际时区范围的旧字符串统一按未知处理。
  const minutes = match ? Number(match[2]) * 60 + Number(match[3]) : 0;
  // 半小时和四十五分钟时区也保留精确偏移。
  const offsetMinutes = match && Number(match[3]) < 60 && minutes <= 840 ? (match[1] === '-' ? -minutes : minutes) : 0;
  // 加偏移后始终读取 UTC 各字段，避免运行环境时区影响。
  const wallTime = new Date(source.createdAt.getTime() + offsetMinutes * 60000);
  return { seconds: wallTime.getUTCHours() * 3600 + wallTime.getUTCMinutes() * 60 + wallTime.getUTCSeconds(), offsetMinutes };
}

/// 仅主动设定的增量请求限制在 1970 年至当前实际时刻，完整历史导入不调用此校验。
export function validateSelectedNoteRecordTime(data: Record<string, unknown>, now: number = Date.now()): void {
  // 自然日格式已由 SQL 构建器统一验证。
  const day = data.day_key as string;
  // 固定偏移用于还原实际时刻，不改变保存的自然日和时分秒。
  const instant = Date.parse(`${day}T00:00:00Z`) + (data.record_time_seconds as number) * 1000 - (data.record_utc_offset_minutes as number) * 60000;
  if (day < '1970-01-01' || !Number.isFinite(instant) || instant > now) throw new BadRequestException('笔记记录时间必须为 1970 年至当前时刻');
}
