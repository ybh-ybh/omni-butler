import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { resolve, sep } from 'node:path';
import { randomUUID } from 'node:crypto';
import { NoteAudioStore } from '../../src/notes/note-audio-store';

/// 仅供显式隔离测试注入，生产模块不导入磁盘实现。
export class DiskTestNoteAudioStore extends NoteAudioStore {
  /// 本测试独占的临时目录。
  constructor(private readonly directory: string) { super(); }
  /// 验证测试对象键且禁止路径越界。
  private path(key: string): string {
    if (!/^[a-f0-9-]{36}\/[a-f0-9-]{36}\/[a-f0-9]{64}$/.test(key)) throw new Error('非法测试原音键');
    // 解析后的独立测试目录。
    const root = resolve(this.directory);
    // 真实测试文件目标。
    const target = resolve(root, key);
    if (!target.startsWith(`${root}${sep}`)) throw new Error('测试原音路径越界');
    return target;
  }
  /// 原子写入测试真实字节，不模拟数据库和文件一致性。
  async put(key: string, bytes: Buffer): Promise<void> {
    // 校验后的最终文件。
    const target = this.path(key);
    // 唯一临时文件防止部分写入。
    const temporary = `${target}.${randomUUID()}.tmp`;
    await mkdir(resolve(target, '..'), { recursive: true });
    try { await writeFile(temporary, bytes, { flag: 'wx' }); await rename(temporary, target); }
    finally { await rm(temporary, { force: true }); }
  }
  /// 测试仍读取磁盘上的实际字节。
  async get(key: string): Promise<Buffer> { return readFile(this.path(key)); }
  /// 模拟真实幂等对象删除。
  async delete(key: string): Promise<void> { await rm(this.path(key), { force: true }); }
}
