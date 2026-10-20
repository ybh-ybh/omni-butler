import { BadRequestException } from '@nestjs/common';
import {
  addMonths,
  dayInput,
  instantInput,
  localInstant,
  localParts,
  objectInput,
  rangeInput,
} from '../src/business/business-input';
import { notePlainText } from '../src/business/notes-business.service';
import { membershipPeriodEnd } from '../src/business/memberships.service';
import { todoOccursOn } from '../src/business/todos.service';

describe('后端业务日期与文字口径', () => {
  it('拒绝归属注入、非普通对象和非法日期，而不依赖 HTTP 管道', () => {
    expect(() => objectInput({ userId: 'other' }, ['name'])).toThrow(
      BadRequestException,
    );
    expect(() => objectInput(new Date(), ['name'])).toThrow(
      BadRequestException,
    );
    expect(() => dayInput('2026-02-30')).toThrow(BadRequestException);
    expect(() => dayInput('0000-01-01')).toThrow(BadRequestException);
    expect(() => instantInput('2026-01-01T10:00:00', 'at')).toThrow(
      BadRequestException,
    );
    expect(() => instantInput('2026-02-30T10:00:00Z', 'at')).toThrow(
      BadRequestException,
    );
    expect(() =>
      rangeInput({
        from: '2026-02-01T00:00:00Z',
        to: '2026-01-01T00:00:00Z',
        timeZone: 'UTC',
      }),
    ).toThrow(BadRequestException);
  });

  it('明确地区的自然日不随宿主时区变化', () => {
    expect(
      localParts(new Date('2026-01-31T16:30:00Z'), 'Asia/Shanghai'),
    ).toEqual({ day: '2026-02-01', seconds: 1800, offsetMinutes: 480 });
    expect(
      localParts(new Date('2026-01-01T00:00:00Z'), 'Asia/Kathmandu')
        .offsetMinutes,
    ).toBe(345);
    expect(
      localInstant('2026-02-01', 1800, 'Asia/Shanghai').toISOString(),
    ).toBe('2026-01-31T16:30:00.000Z');
  });

  it('DST 日界保持23/25小时，并与客户端一致规范化跳跃时钟', () => {
    expect(
      localInstant('2026-03-09', 0, 'America/New_York').getTime() -
        localInstant('2026-03-08', 0, 'America/New_York').getTime(),
    ).toBe(23 * 3600000);
    expect(
      localInstant('2026-11-02', 0, 'America/New_York').getTime() -
        localInstant('2026-11-01', 0, 'America/New_York').getTime(),
    ).toBe(25 * 3600000);
    expect(
      localParts(
        localInstant('2026-03-08', 2 * 3600 + 1800, 'America/New_York'),
        'America/New_York',
      ).seconds,
    ).toBe(3 * 3600 + 1800);
  });

  it('月底、闰年和重复日历沿用自然日算法', () => {
    expect(addMonths('2024-01-31', 1)).toBe('2024-02-29');
    expect(addMonths('0001-01-31', 1)).toBe('0001-02-28');
    expect(membershipPeriodEnd('2026-01-31', 'quarter')).toBe('2026-04-30');
    expect(membershipPeriodEnd('2024-02-29', 'year')).toBe('2025-02-28');
    expect(
      todoOccursOn(
        {
          scheduledDate: new Date('2026-01-31T00:00:00Z'),
          repeatRule: 'monthly',
        },
        '2026-02-28',
      ),
    ).toBe(true);
    expect(
      todoOccursOn(
        {
          scheduledDate: new Date('2026-01-31T00:00:00Z'),
          repeatRule: 'monthly',
        },
        '2026-03-30',
      ),
    ).toBe(false);
  });

  it('笔记仅解析实际支持的格式，未知HTML和Markdown保留字面值', () => {
    expect(notePlainText('- **重点**\n1. <u>下划线</u>与==高亮==')).toBe(
      '重点\n下划线与高亮',
    );
    expect(
      notePlainText(
        '\\**字面**\n# 标题\n[链接](https://example.test)\n<b>HTML</b>',
      ),
    ).toBe('**字面**\n# 标题\n[链接](https://example.test)\n<b>HTML</b>');
    expect(notePlainText('**加粗==嵌套<u>文本</u>==**')).toBe('加粗嵌套文本');
    expect(notePlainText('  - 保留缩进\n**未闭合')).toBe(
      '  - 保留缩进\n**未闭合',
    );
  });
});
