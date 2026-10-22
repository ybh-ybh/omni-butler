import { BadRequestException } from '@nestjs/common';

/// 业务入口仅接收明确列出的 JSON 参数，不依赖 HTTP 管道。
export function objectInput(
  value: unknown,
  fields: readonly string[],
): Record<string, unknown> {
  if (
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Object.prototype
  )
    throw new BadRequestException('参数必须为普通 JSON 对象');
  // 命令身份由调用执行层生成，不能夹带归属或数据库列。
  const input = value as Record<string, unknown>;
  if (Object.keys(input).some((key) => !fields.includes(key)))
    throw new BadRequestException('包含不支持的业务参数');
  return input;
}

/// 校验稳定记录或操作身份并统一大小写。
export function uuidInput(value: unknown, field = 'id'): string {
  if (
    typeof value !== 'string' ||
    !/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(
      value,
    )
  )
    throw new BadRequestException(`${field} 必须为 UUID`);
  return value.toLowerCase();
}

/// 清理文本；可空字段用 null 明确清空。
export function textInput(
  value: unknown,
  field: string,
  max = 200,
  nullable = false,
): string | null {
  if (nullable && (value === null || value === undefined)) return null;
  if (typeof value !== 'string')
    throw new BadRequestException(`${field} 必须为文本`);
  // 非正文文字去除两端空格，正文另行保留原始内容。
  const text = value.trim();
  if ([...text].length > max || (!nullable && !text))
    throw new BadRequestException(`${field} 长度不合法`);
  return text || null;
}

/// 分类、位置及兼容标签文字不能携带误放的规范UUID。
export function taxonomyTextInput(
  value: unknown,
  field: string,
  nullable = true,
): string | null {
  // 兼容逗号分隔名称，同时拦截其中任一被误当作文字的UUID。
  const name = textInput(value, field, 200, nullable);
  if (
    name
      ?.split(',')
      .some((part) =>
        /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(part.trim()),
      )
  )
    throw new BadRequestException(
      `${field} 只能填写名称文字；分类UUID请使用categoryId/categoryIds，位置UUID请使用locationIds`,
    );
  return name;
}

/// 校验整数，拒绝浮点、字符串与安全范围外金额。
export function integerInput(
  value: unknown,
  field: string,
  min = 0,
  max = 2147483647,
): number {
  if (
    !Number.isSafeInteger(value) ||
    (value as number) < min ||
    (value as number) > max
  )
    throw new BadRequestException(`${field} 必须为 ${min} 至 ${max} 的整数`);
  return value as number;
}

/// 布尔值不得以真值转换代替验证。
export function booleanInput(value: unknown, field: string): boolean {
  if (typeof value !== 'boolean')
    throw new BadRequestException(`${field} 必须为布尔值`);
  return value;
}

/// 枚举仅允许当前业务支持的值。
export function enumInput<T extends string>(
  value: unknown,
  field: string,
  allowed: readonly T[],
): T {
  if (typeof value !== 'string' || !allowed.includes(value as T))
    throw new BadRequestException(`${field} 不合法`);
  return value as T;
}

/// 真实自然日不随服务器时区改变。
export function dayInput(value: unknown, field = 'day'): string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    throw new BadRequestException(`${field} 必须为 YYYY-MM-DD`);
  // Date 会将越界日期进位，需回比原值。
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (
    !Number.isFinite(parsed.getTime()) ||
    value.startsWith('0000-') ||
    parsed.toISOString().slice(0, 10) !== value
  )
    throw new BadRequestException(`${field} 不是有效日期`);
  return value;
}

/// 时间点必须显式携带时区，禁止依赖宿主本地设置。
export function instantInput(value: unknown, field: string): Date {
  if (
    typeof value !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(
      value,
    )
  )
    throw new BadRequestException(`${field} 必须为带时区的 ISO 时间`);
  // 同时拒绝被 Date 隐式修正的日期和越界钟点。
  dayInput(value.slice(0, 10), field);
  if (
    Number(value.slice(11, 13)) > 23 ||
    Number(value.slice(14, 16)) > 59 ||
    Number(value.slice(17, 19)) > 59
  )
    throw new BadRequestException(`${field} 时间不合法`);
  // 规范化后只向数据库写绝对时间。
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime()))
    throw new BadRequestException(`${field} 时间不合法`);
  return parsed;
}

/// 业务时区由调用方明确指定，支持 IANA 地区与 UTC。
export function timeZoneInput(value: unknown): string {
  if (typeof value !== 'string' || value.length > 128)
    throw new BadRequestException('需要有效业务时区');
  try {
    new Intl.DateTimeFormat('en', { timeZone: value }).format();
  } catch {
    throw new BadRequestException('业务时区不合法');
  }
  return value;
}

/// 提取指定时区的日历日期与时钟。
export function localParts(
  at: Date,
  timeZone: string,
): { day: string; seconds: number; offsetMinutes: number } {
  // 使用固定数字历法，避免地区格式及午夜 24 点差异。
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(at);
  // 格式化字段按名称索引。
  const values = Object.fromEntries(
    parts.map((part) => [part.type, part.value]),
  );
  // 自然日保留调用方地区语义。
  const day = `${values.year!.padStart(4, '0')}-${values.month}-${values.day}`;
  // 日内秒数不使用跨 DST 的 elapsed time 替代。
  const seconds =
    Number(values.hour) * 3600 +
    Number(values.minute) * 60 +
    Number(values.second);
  // 偏移以该真实时间点为准。
  const offsetMinutes = Math.round(
    (Date.parse(`${day}T${values.hour}:${values.minute}:${values.second}Z`) -
      Math.floor(at.getTime() / 1000) * 1000) /
      60000,
  );
  return { day, seconds, offsetMinutes };
}

/// 日历时刻按客户端 DateTime 语义转换，DST 跳跃时向后规范化。
export function localInstant(
  day: string,
  seconds: number,
  timeZone: string,
): Date {
  // 先以 UTC 表示目标本地时钟，再逐次纠正该地区偏移。
  const wall = Date.parse(`${day}T00:00:00Z`) + seconds * 1000;
  // 迭代起点只作数学计算，不作为业务时区事实。
  let result = new Date(wall);
  // 保存偏移两侧的候选，跳跃时选择目标时钟之后的最近结果。
  const candidates: Date[] = [];
  for (let attempt = 0; attempt < 4; attempt += 1) {
    result = new Date(
      wall - localParts(result, timeZone).offsetMinutes * 60000,
    );
    candidates.push(result);
  }
  // DST 跳跃可能使时钟没有对应真实时间；派生日历与客户端一样规范化。
  const actual = localParts(result, timeZone);
  if (actual.day !== day || actual.seconds !== seconds) {
    // 比较当地墙上时钟，而不是 UTC 大小。
    const shifted = candidates
      .map((candidate) => {
        // 候选实际对应的当地日历时钟。
        const local = localParts(candidate, timeZone);
        return {
          candidate,
          wall: Date.parse(`${local.day}T00:00:00Z`) + local.seconds * 1000,
        };
      })
      .filter((candidate) => candidate.wall >= wall)
      .sort((left, right) => left.wall - right.wall);
    if (!shifted.length) throw new BadRequestException('无法确定该日历时刻');
    return shifted[0]!.candidate;
  }
  return result;
}

/// 按日历加月，月底截断而不进位到下个月。
export function addMonths(day: string, months: number): string {
  // 原日期只用于取得年月日。
  const source = new Date(`${day}T00:00:00Z`);
  // 先定位目标月一日，防止源日期触发隐式进位。
  const target = new Date(source);
  target.setUTCDate(1);
  target.setUTCFullYear(
    source.getUTCFullYear(),
    source.getUTCMonth() + months,
    1,
  );
  if (
    !Number.isFinite(target.getTime()) ||
    target.getUTCFullYear() < 1 ||
    target.getUTCFullYear() > 9999
  )
    throw new BadRequestException('日历周期超出支持日期范围');
  // 目标月最后一天限制源日。
  const lastDay = new Date(target);
  lastDay.setUTCMonth(lastDay.getUTCMonth() + 1, 0);
  // 不用 Date.UTC 的 0—99 年兼容转换，保留真实公历年份。
  const last = lastDay.getUTCDate();
  target.setUTCDate(Math.min(source.getUTCDate(), last));
  return target.toISOString().slice(0, 10);
}

/// 对自然日进行天数运算，不使用设备时区的毫秒差。
export function addDays(day: string, days: number): string {
  return new Date(Date.parse(`${day}T00:00:00Z`) + days * 86400000)
    .toISOString()
    .slice(0, 10);
}

/// URL 仅作数据保存，不执行网络请求。
export function urlInput(value: unknown, field: string): string | null {
  // 未填写或显式清空表示没有链接。
  const text = textInput(value, field, 4000, true);
  if (text === null) return null;
  try {
    // 仅解析链接结构，不发起网络请求。
    const url = new URL(text);
    if (!['http:', 'https:'].includes(url.protocol) || !url.hostname)
      throw new Error();
  } catch {
    throw new BadRequestException(`${field} 必须为 HTTP(S) 链接`);
  }
  return text;
}

/// UUID 集合同时限制大小和重复身份。
export function idsInput(value: unknown, field: string, max = 200): string[] {
  if (!Array.isArray(value) || value.length > max)
    throw new BadRequestException(`${field} 必须为不超过 ${max} 项的身份数组`);
  // 同一 UUID 的大小写不能绕过重复校验。
  const ids = value.map((item: unknown) => uuidInput(item, field));
  if (new Set(ids).size !== ids.length)
    throw new BadRequestException(`${field} 不能重复`);
  return ids;
}

/// 通用列表只复用实际相同的分页字段，不生成领域 DTO。
export function pageInput(input: Record<string, unknown>): {
  skip: number;
  take: number;
} {
  return {
    skip: integerInput(input.offset ?? 0, 'offset', 0, 1000000),
    take: integerInput(input.limit ?? 50, 'limit', 1, 200),
  };
}

/// 有界列表明确是否截断，统计不从这一页反推全量。
export function pageResult<T>(
  rows: T[],
  page: { skip: number; take: number },
): { items: T[]; hasMore: boolean; nextOffset: number | null } {
  return {
    items: rows.slice(0, page.take),
    hasMore: rows.length > page.take,
    nextOffset: rows.length > page.take ? page.skip + page.take : null,
  };
}

/// 绝对时间窗口只校验首尾，不引入未参与查询的时区或截止点。
export function absoluteRangeInput(input: Record<string, unknown>): {
  from: Date;
  to: Date;
} {
  // 查询窗口使用左闭右开语义。
  const from = instantInput(input.from, 'from');
  // 结束点不计入当前周期。
  const to = instantInput(input.to, 'to');
  if (to <= from || to.getTime() - from.getTime() > 3660 * 86400000)
    throw new BadRequestException('范围必须为正且不超过十年');
  return { from, to };
}

/// 自然日统计在绝对窗口之外明确地区日界，但不宣称历史状态快照。
export function calendarRangeInput(input: Record<string, unknown>): {
  from: Date;
  to: Date;
  timeZone: string;
} {
  return {
    ...absoluteRangeInput(input),
    timeZone: timeZoneInput(input.timeZone),
  };
}

/// 需要截止点的统计复用范围与地区，并固定进行中状态的计算时刻。
export function rangeInput(input: Record<string, unknown>): {
  from: Date;
  to: Date;
  asOf: Date;
  timeZone: string;
} {
  return {
    ...calendarRangeInput(input),
    asOf:
      input.asOf === undefined ? new Date() : instantInput(input.asOf, 'asOf'),
  };
}
