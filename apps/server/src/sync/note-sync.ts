import { BadRequestException, ConflictException } from '@nestjs/common';
import type { Prisma } from '../generated/prisma/client';
import type { SyncOperationDto } from './dto/sync-operation.dto';
import { effectiveNoteRecordTime, validateSelectedNoteRecordTime } from './note-record-time';

/// 正式笔记正文与标签上限由在线入口和同步共同使用。
export const NOTE_MAX_BODY_LENGTH = 20000;
/// 标签数量保持现有客户端十个的口径。
export const NOTE_MAX_TAGS = 10;

/// 标签协议只接受无重复 UUID 的 JSON 文本，避免整列覆盖和非规范身份。
export function parseNoteTags(value: unknown, field: string): string[] {
  // 先检查文本类型，不让 JSON.parse 隐式转换数组或数值。
  let parsed: unknown;
  try { if (typeof value !== 'string') throw new Error('invalid'); parsed = JSON.parse(value); } catch { throw new BadRequestException(`${field} 必须为标签 UUID 的 JSON 数组文本`); }
  if (!Array.isArray(parsed) || parsed.length > NOTE_MAX_TAGS || parsed.some((tag: unknown) => typeof tag !== 'string' || !/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(tag))) throw new BadRequestException('笔记最多支持十个有效标签');
  // PostgreSQL UUID 以小写形式输出，同一身份的大小写不能成为不同标签。
  const tags = (parsed as string[]).map((tag) => tag.toLowerCase());
  if (new Set(tags).size !== tags.length) throw new BadRequestException('笔记标签不能重复');
  return tags;
}

/// SQL预检只接收无辅助字段的副本，原始基线仍参与幂等摘要及事务内合并。
export function validateNoteTagOperation(operation: SyncOperationDto): SyncOperationDto {
  if (operation.table !== 'note_entries') return operation;
  // 校验与删除均作用于副本，不能损坏后续事务合并所需原始请求。
  const data = { ...operation.data };
  if (operation.op !== 'PATCH') {
    if (data.tags_base !== undefined) throw new BadRequestException('标签编辑基线只允许用于笔记 PATCH');
    if (data.tags !== undefined) data.tags = JSON.stringify(parseNoteTags(data.tags, 'tags').sort());
    return { ...operation, data };
  }
  // 字段必须成对出现，不允许整列覆盖或孤立基线。
  if ((data.tags === undefined) !== (data.tags_base === undefined)) throw new BadRequestException('标签变更必须同时包含 tags 与 tags_base');
  if (data.tags !== undefined) {
    data.tags = JSON.stringify(parseNoteTags(data.tags, 'tags').sort());
    parseNoteTags(data.tags_base, 'tags_base');
  }
  delete data.tags_base;
  return { ...operation, data };
}

/// 正文修订只在基线匹配时采用；所有并发候选仍完整同步。
export async function normalizeNoteOperation(transaction: Prisma.TransactionClient, userId: string, operation: SyncOperationDto): Promise<SyncOperationDto> {
  if (operation.table === 'taxonomy_entries' && operation.op === 'PATCH') {
    // PATCH 可能只有旧颜色，必须以持久身份识别模块，不能影响其他模块颜色。
    const current = await transaction.taxonomyEntry.findFirst({ where: { userId, id: operation.id } });
    // 转入笔记模块时也按更新后的模块判定是否退休颜色。
    const module = operation.data?.module ?? current?.module;
    // 类型优先使用当前请求，覆盖从其他模块转入笔记标签的情况。
    const kind = operation.data?.kind ?? current?.kind;
    if (module === 'notes' && kind === 'tag' &&
        (Object.hasOwn(operation.data ?? {}, 'color_value') || operation.data?.module !== undefined || operation.data?.kind !== undefined)) {
      return { ...operation, data: { ...operation.data, color_value: null } };
    }
  }
  if (operation.table === 'note_images' && operation.op === 'PATCH' && operation.data?.note_id !== undefined) {
    // 图片子记录身份不可转移，防止离线操作把同一文件挪到其他笔记。
    const current = await transaction.noteImage.findFirst({ where: { userId, id: operation.id } });
    if (current && operation.data.note_id !== current.noteId) throw new BadRequestException('已保存图片不能改变所属笔记');
  }
  if (operation.table === 'note_versions' && operation.op === 'PATCH' && Object.keys(operation.data ?? {}).some((column) => column !== 'deleted_at')) throw new BadRequestException('正文候选版本只能切换回收站状态，正文与修订身份不可修改');
  if (operation.table === 'note_audio_segments' && operation.op === 'PATCH') {
    // 原音身份和内容摘要不可变，支持转写、排序与回收站状态同步。
    const current = await transaction.noteAudioSegment.findFirst({ where: { userId, id: operation.id } });
    if (current) {
      // 不可变元数据的同步列及实际值。
      const immutable: Record<string, unknown> = { note_id: current.noteId, duration_ms: current.durationMs, mime: current.mime, sha256: current.sha256, byte_size: current.byteSize };
      for (const [column, value] of Object.entries(immutable)) if (operation.data?.[column] !== undefined && operation.data[column] !== value) throw new BadRequestException('已保存原音不能改变内容或所属笔记');
      if (current.transcript !== null && operation.data?.transcript !== undefined && operation.data.transcript !== current.transcript) throw new BadRequestException('原始转写不可覆盖，重试结果保存在候选任务中');
    }
  }
  if (operation.table !== 'note_entries') return operation;
  // 与事务前预检共用协议验证，辅助字段在SQL构建前始终已剥除。
  const validated = validateNoteTagOperation(operation);
  if (operation.op !== 'PATCH') return validated;
  // 仅对副本进行服务端并发归一化。
  const data = { ...validated.data };
  // 标签有变更时必须同时携带编辑前基线，禁止旧整列覆盖语义。
  const incoming = data.tags === undefined ? undefined : parseNoteTags(data.tags, 'tags');
  // 基线是请求事实，不能从服务端当前行反推。
  const base = operation.data?.tags_base === undefined ? undefined : parseNoteTags(operation.data.tags_base, 'tags_base');
  // 全部正文写入必须有完整可恢复的候选事实。
  const current = await transaction.noteEntry.findFirst({ where: { userId, id: operation.id } });
  if (!current) return { ...operation, data };
  if (data.day_key !== undefined || data.record_time_seconds !== undefined || data.record_utc_offset_minutes !== undefined) {
    // PowerSync 可能省略未改变列；旧日期队列也在副本中补全，不改变原始回执摘要。
    const effective = effectiveNoteRecordTime(current);
    // 仅含 day_key 的历史队列保持其旧日期兼容语义。
    const selected = data.record_time_seconds !== undefined || data.record_utc_offset_minutes !== undefined;
    data.day_key ??= current.dayKey;
    data.record_time_seconds ??= effective.seconds;
    data.record_utc_offset_minutes ??= effective.offsetMinutes;
    if (selected) validateSelectedNoteRecordTime(data);
  }
  if (incoming && base) {
    // 只执行本次编辑相对基线的新增与移除，保留别的设备并发新增。
    const merged = new Set(parseNoteTags(current.tags, 'current.tags'));
    for (const tag of base) if (!incoming.includes(tag)) merged.delete(tag);
    for (const tag of incoming) if (!base.includes(tag)) merged.add(tag);
    if (merged.size > NOTE_MAX_TAGS) throw new BadRequestException('合并后的笔记标签不能超过十个');
    data.tags = JSON.stringify([...merged].sort());
  }
  if (data.creation_timezone !== undefined && data.creation_timezone !== current.creationTimezone) throw new BadRequestException('笔记创建时区不可修改');
  if (data.created_at !== undefined && (typeof data.created_at !== 'string' || Date.parse(data.created_at) !== current.createdAt.getTime())) throw new BadRequestException('笔记真实创建时间不可修改');
  if (data.body !== undefined || data.revision !== undefined) {
    if (typeof data.body !== 'string' || typeof data.revision !== 'string') throw new BadRequestException('正文变更必须包含 body 与 revision');
    // 重放当前相同正文属于幂等更新，不需要重复版本。
    if (data.body !== current.body || data.revision !== current.revision) {
      // 新版本必须先于正文 PATCH 上传且指向当前笔记。
      const candidate = await transaction.noteVersion.findFirst({ where: { userId, noteId: current.id, revision: data.revision } });
      if (!candidate || candidate.body !== data.body) throw new ConflictException({ code: 'NOTE_VERSION_MISSING', message: '正文更新需要先上传完整候选版本' });
      if (candidate.baseRevision !== current.revision || (current.deletedAt !== null && data.deleted_at !== null)) {
        // 基线失效不覆盖服务器正文；候选仍存在，可由用户保存新笔记。
        delete data.body; delete data.revision;
      }
    }
  }
  // 已删笔记的普通离线编辑不能覆盖回收站正文与元数据。
  if (current.deletedAt !== null && data.deleted_at === undefined) return { ...operation, data: { updated_at: current.updatedAt.toISOString() } };
  if (Object.keys(data).length === 0) data.updated_at = current.updatedAt.toISOString();
  return { ...operation, data };
}

/// 全事务最终检查总时长以及笔记标签的归属和类型。
export async function reconcileNotes(transaction: Prisma.TransactionClient, userId: string): Promise<void> {
  // 快照迁移不走单行归一化，仍以事务最终状态统一限制标签数量。
  const invalidTagCount = await transaction.$queryRaw<Array<{ id: string }>>`
    SELECT id FROM note_entries WHERE user_id=${userId}::uuid AND jsonb_array_length(tags::jsonb)>${NOTE_MAX_TAGS} LIMIT 1
  `;
  if (invalidTagCount.length) throw new BadRequestException('笔记最多支持十个标签');
  // 单篇最多 60 分钟，无法通过多设备同时添加越过限额。
  const invalidDuration = await transaction.$queryRaw<Array<{ note_id: string }>>`
    SELECT note_id FROM note_audio_segments WHERE user_id=${userId}::uuid AND deleted_at IS NULL
    GROUP BY note_id HAVING SUM(duration_ms)>3600000 LIMIT 1
  `;
  if (invalidDuration.length) throw new BadRequestException('单篇笔记录音累计不能超过 60 分钟');
  // JSON 标签必须关联同归属的笔记标签；已删除标签仍可离线保留到客户端清理。
  const invalidTag = await transaction.$queryRaw<Array<{ id: string }>>`
    SELECT note.id FROM note_entries note CROSS JOIN LATERAL jsonb_array_elements_text(note.tags::jsonb) tag(value)
    LEFT JOIN taxonomy_entries taxonomy ON taxonomy.id::text=tag.value AND taxonomy.user_id=note.user_id
    WHERE note.user_id=${userId}::uuid AND (taxonomy.id IS NULL OR taxonomy.module<>'notes' OR taxonomy.kind<>'tag') LIMIT 1
  `;
  if (invalidTag.length) throw new BadRequestException('笔记标签必须属于同一归属的笔记标签');
}
