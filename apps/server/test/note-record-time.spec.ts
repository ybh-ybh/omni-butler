import { BadRequestException } from '@nestjs/common';
import type { Prisma } from '../src/generated/prisma/client';
import type { SyncOperationDto } from '../src/sync/dto/sync-operation.dto';
import { effectiveNoteRecordTime, validateSelectedNoteRecordTime } from '../src/sync/note-record-time';
import { normalizeNoteOperation } from '../src/sync/note-sync';
import { SyncSqlBuilder } from '../src/sync/sync-sql.builder';

/// 验证记录时间协议、历史默认与独立差量不会改变正文事实。
describe('笔记记录时间', () => {
  // 白名单边界同时用于增量与完整快照。
  const builder = new SyncSqlBuilder();
  // 具有非零秒数的创建事实，偏移跨日时只取当天时分秒。
  const createdAt = new Date('2026-10-18T23:12:34.567Z');

  it.each([
    ['CST|+08:00', 7 * 3600 + 12 * 60 + 34, 480],
    ['NPT|+05:45', 4 * 3600 + 57 * 60 + 34, 345],
    ['PDT|-07:00', 16 * 3600 + 12 * 60 + 34, -420],
    ['legacy:unknown', 23 * 3600 + 12 * 60 + 34, 0],
    ['legacy:unknown|+14:01', 23 * 3600 + 12 * 60 + 34, 0],
    ['broken|+00:99', 23 * 3600 + 12 * 60 + 34, 0],
  ])('旧记录从 %s 稳定推导，不受运行环境时区影响', (creationTimezone, seconds, offsetMinutes) => {
    expect(effectiveNoteRecordTime({ createdAt, creationTimezone })).toEqual({ seconds, offsetMinutes });
  });

  it('已选择的记录时间完全独立于创建事实', () => {
    expect(effectiveNoteRecordTime({ createdAt, creationTimezone: 'CST|+08:00', recordTimeSeconds: 1, recordUtcOffsetMinutes: -300 })).toEqual({ seconds: 1, offsetMinutes: -300 });
  });

  it.each([
    { day_key: '2026-02-30', record_time_seconds: 1, record_utc_offset_minutes: 0 },
    { day_key: '2026-02-28', record_time_seconds: -1, record_utc_offset_minutes: 0 },
    { day_key: '2026-02-28', record_time_seconds: 86400, record_utc_offset_minutes: 0 },
    { day_key: '2026-02-28', record_time_seconds: 1.1, record_utc_offset_minutes: 0 },
    { day_key: '2026-02-28', record_time_seconds: 0, record_utc_offset_minutes: 841 },
    { day_key: '2026-02-28', record_time_seconds: 0, record_utc_offset_minutes: -841 },
    { day_key: '2026-02-28', record_time_seconds: null, record_utc_offset_minutes: null },
  ])('拒绝越界或显式清空 PATCH %j', (data) => {
    expect(() => builder.build({ op: 'PATCH', table: 'note_entries', id: 'note', data }, 'owner')).toThrow(BadRequestException);
  });

  it('合法整组 PATCH 只改记录时间，不写真实创建时间或正文', () => {
    // 每个时间组在单条 SQL 中写入，不可能与其他设备拼接字段。
    const statement = builder.build({ op: 'PATCH', table: 'note_entries', id: 'note', data: { day_key: '2024-02-29', record_time_seconds: 86399, record_utc_offset_minutes: -840 } }, 'owner');
    expect(statement.sql).toContain('"day_key" = $3, "record_time_seconds" = $4, "record_utc_offset_minutes" = $5');
    expect(statement.sql).not.toMatch(/body|revision|created_at|creation_timezone/);
    expect(statement.values).toEqual(['note', 'owner', '2024-02-29', 86399, -840]);
  });

  it('旧 PUT、整组空值和未来历史快照可继续导入', () => {
    for (const data of [{ day_key: '2999-12-31' }, { day_key: '2999-12-31', record_time_seconds: null, record_utc_offset_minutes: null }, { day_key: '1960-01-01', record_time_seconds: 0, record_utc_offset_minutes: 840 }]) {
      expect(() => builder.build({ op: 'PUT', table: 'note_entries', id: 'note', data }, 'owner')).not.toThrow();
    }
  });

  it('1970 自然日下限、当前秒和固定偏移共同约束主动选择', () => {
    // 固定当前时刻使边界不依赖测试执行时间。
    const now = Date.parse('2026-10-19T08:30:45.000Z');
    expect(() => validateSelectedNoteRecordTime({ day_key: '1970-01-01', record_time_seconds: 0, record_utc_offset_minutes: 840 }, now)).not.toThrow();
    expect(() => validateSelectedNoteRecordTime({ day_key: '1969-12-31', record_time_seconds: 86399, record_utc_offset_minutes: -840 }, now)).toThrow(BadRequestException);
    expect(() => validateSelectedNoteRecordTime({ day_key: '2026-10-19', record_time_seconds: 16 * 3600 + 30 * 60 + 45, record_utc_offset_minutes: 480 }, now)).not.toThrow();
    expect(() => validateSelectedNoteRecordTime({ day_key: '2026-10-19', record_time_seconds: 16 * 3600 + 30 * 60 + 46, record_utc_offset_minutes: 480 }, now)).toThrow(BadRequestException);
  });

  it.each([false, true])('旧日期差量补全当前有效时间，已显式设置=%s，不改变原请求', async (explicit) => {
    // 旧队列不能把当前设备后来修改的时分秒重置成创建时间。
    const transaction = { noteEntry: { findFirst: jest.fn().mockResolvedValue({ createdAt, creationTimezone: 'CST|+08:00', recordTimeSeconds: explicit ? 12 : null, recordUtcOffsetMinutes: explicit ? -60 : null, deletedAt: null }) } } as unknown as Prisma.TransactionClient;
    // 冻结原请求作为幂等摘要证据。
    const operation: SyncOperationDto = Object.freeze({ op: 'PATCH', table: 'note_entries', id: 'note', data: Object.freeze({ day_key: '2024-02-29' }) });
    expect((await normalizeNoteOperation(transaction, 'owner', operation)).data).toEqual({ day_key: '2024-02-29', record_time_seconds: explicit ? 12 : 25954, record_utc_offset_minutes: explicit ? -60 : 480 });
    expect(operation.data).toEqual({ day_key: '2024-02-29' });
  });

  it('主动修改无需正文候选，未来选择拒绝，普通正文差量保留当前记录时间', async () => {
    // 不提供正文版本查询，确保日期变更不创建也不读取正文候选。
    const transaction = { noteEntry: { findFirst: jest.fn().mockResolvedValue({ id: 'note', dayKey: '2020-01-01', createdAt, creationTimezone: 'UTC|+00:00', recordTimeSeconds: 12, recordUtcOffsetMinutes: 0, deletedAt: null }) } } as unknown as Prisma.TransactionClient;
    // 主动日期与时分秒必须完整提交。
    const operation: SyncOperationDto = { op: 'PATCH', table: 'note_entries', id: 'note', data: { day_key: '2020-01-01', record_time_seconds: 1, record_utc_offset_minutes: 480 } };
    expect(await normalizeNoteOperation(transaction, 'owner', operation)).toEqual(operation);
    await expect(normalizeNoteOperation(transaction, 'owner', { ...operation, data: { ...operation.data, day_key: '2999-01-01' } })).rejects.toBeInstanceOf(BadRequestException);
    expect((await normalizeNoteOperation(transaction, 'owner', { ...operation, data: { updated_at: createdAt.toISOString() } })).data).toEqual({ updated_at: createdAt.toISOString() });
  });

  it('PowerSync 仅改变秒数或偏移时补全当前时间组，并保护真实创建时间', async () => {
    // 部分字段差量从当前有效记录组补全，统一在归属锁事务中应用。
    const transaction = { noteEntry: { findFirst: jest.fn().mockResolvedValue({ dayKey: '2020-01-01', createdAt, creationTimezone: 'UTC|+00:00', recordTimeSeconds: 12, recordUtcOffsetMinutes: 0, deletedAt: null }) } } as unknown as Prisma.TransactionClient;
    for (const data of [{ record_time_seconds: 13 }, { record_utc_offset_minutes: 60 }]) {
      // 原负载与结构预检均允许数据库捕获到的部分列。
      const operation: SyncOperationDto = { op: 'PATCH', table: 'note_entries', id: 'note', data };
      expect(() => builder.build(operation, 'owner')).not.toThrow();
      expect((await normalizeNoteOperation(transaction, 'owner', operation)).data).toEqual({ day_key: '2020-01-01', record_time_seconds: 12, record_utc_offset_minutes: 0, ...data });
    }
    await expect(normalizeNoteOperation(transaction, 'owner', { op: 'PATCH', table: 'note_entries', id: 'note', data: { created_at: '2000-01-01T00:00:00Z' } })).rejects.toBeInstanceOf(BadRequestException);
  });
});
