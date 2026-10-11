import type { Prisma } from '../src/generated/prisma/client';
import { normalizeNoteOperation } from '../src/sync/note-sync';
import type { SyncOperationDto } from '../src/sync/dto/sync-operation.dto';

/// 单行协议验证补充真实HTTP用例，直接冻结输入防止辅助字段破坏回执摘要。
describe('笔记标签归一化', () => {
  it('仅修改副本并规范排序UUID，保留原始请求的tags_base', async () => {
    // 三个稳定身份用于明确本地增删与服务器新增。
    const ids = ['00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002', 'abcdef00-0000-4000-8000-000000000003'];
    // 编辑基线有第一个标签，当前服务器已增加第二个标签。
    const transaction = { noteEntry: { findFirst: jest.fn().mockResolvedValue({ id: 'note', tags: JSON.stringify(ids.slice(0, 2)), deletedAt: null }) } } as unknown as Prisma.TransactionClient;
    // 本次操作移除第一个并新增第三个；输入冻结使任何原地删除立即失败。
    const operation: SyncOperationDto = Object.freeze({ op: 'PATCH', table: 'note_entries', id: 'note', data: Object.freeze({ tags: JSON.stringify([ids[2]!.toUpperCase()]), tags_base: JSON.stringify([ids[0]]) }) });
    // 归一化前完整请求证据。
    const original = JSON.stringify(operation);
    // 实际输出只含数据库列。
    const result = await normalizeNoteOperation(transaction, 'owner', operation);
    expect(result.data).toEqual({ tags: JSON.stringify(ids.slice(1)) });
    expect(JSON.stringify(operation)).toBe(original);
    expect(result).not.toBe(operation); expect(result.data).not.toBe(operation.data);
  });
  it('不存在目标也验证并剥除辅助字段，由外层报告缺失目标', async () => {
    // 保留外层已有SYNC_RECORD_MISSING行为，辅助字段不能落入SQL白名单。
    const transaction = { noteEntry: { findFirst: jest.fn().mockResolvedValue(null) } } as unknown as Prisma.TransactionClient;
    expect((await normalizeNoteOperation(transaction, 'owner', { op: 'PATCH', table: 'note_entries', id: 'note', data: { tags: '[]', tags_base: '[]' } })).data).toEqual({ tags: '[]' });
    await expect(normalizeNoteOperation(transaction, 'owner', { op: 'PATCH', table: 'note_entries', id: 'note', data: { tags: '[]' } })).rejects.toMatchObject({ status: 400 });
  });
});
