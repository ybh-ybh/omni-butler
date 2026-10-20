import {
  BadRequestException,
  ConflictException,
  Injectable,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthUser } from '../auth/auth.types';
import type { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  NOTE_MAX_BODY_LENGTH,
  NOTE_MAX_TAGS,
  parseNoteTags,
  reconcileNotes,
} from '../sync/note-sync';
import { validateSelectedNoteRecordTime } from '../sync/note-record-time';
import { businessRead, businessWrite, requireActive } from './business-access';
import {
  booleanInput,
  dayInput,
  idsInput,
  integerInput,
  localInstant,
  localParts,
  objectInput,
  pageInput,
  pageResult,
  rangeInput,
  textInput,
  timeZoneInput,
  uuidInput,
} from './business-input';

/// 受限 Markdown 的配对结束标记，跳过被转义的位置。
function findClosing(source: string, marker: string, start: number): number {
  // 逐个寻找尚未转义的候选。
  let candidate = source.indexOf(marker, start);
  while (candidate >= 0) {
    // 连续反斜杠的奇偶决定是否转义。
    let slashes = 0;
    for (
      let index = candidate - 1;
      index >= 0 && source[index] === '\\';
      index -= 1
    )
      slashes += 1;
    if (slashes % 2 === 0) return candidate;
    candidate = source.indexOf(marker, candidate + 1);
  }
  return -1;
}

/// 与客户端相同，仅识别加粗、下划线、高亮与零缩进列表。
export function notePlainText(source: string): string {
  // 本方言不解析链接、HTML 或普通 Markdown 标题，未知语法保留字面值。
  const inline = (text: string, active: Set<string>): string => {
    // 输出保留用户空格和换行。
    let result = '';
    for (let index = 0; index < text.length; ) {
      if (
        text[index] === '\\' &&
        index + 1 < text.length &&
        '\\*=<-.'.includes(text[index + 1]!)
      ) {
        result += text[index + 1];
        index += 2;
        continue;
      }
      // 每种样式最多嵌套一次，递归深度固定有界。
      const marker =
        text.startsWith('**', index) && !active.has('bold')
          ? ['**', '**', 'bold']
          : text.startsWith('<u>', index) && !active.has('underline')
            ? ['<u>', '</u>', 'underline']
            : text.startsWith('==', index) && !active.has('highlight')
              ? ['==', '==', 'highlight']
              : null;
      // 空配对和不完整标记保持原文。
      const closing = marker
        ? findClosing(text, marker[1]!, index + marker[0]!.length)
        : -1;
      if (marker && closing > index + marker[0]!.length) {
        result += inline(
          text.slice(index + marker[0]!.length, closing),
          new Set([...active, marker[2]!]),
        );
        index = closing + marker[1]!.length;
      } else {
        result += text[index];
        index += 1;
      }
    }
    return result;
  };
  return source
    .split('\n')
    .map((line) => inline(line.replace(/^(?:- |[0-9]+\. )/, ''), new Set()))
    .join('\n');
}

/// 正文不 trim，保留用户实际空白及受限 Markdown。
function bodyInput(value: unknown): string {
  if (typeof value !== 'string' || value.length > NOTE_MAX_BODY_LENGTH)
    throw new BadRequestException('笔记正文必须为不超过 20,000 字的文本');
  return value;
}

/// 正文、修订及标签作为正式业务能力，和音频/ASR 服务分工。
@Injectable()
export class NotesBusinessService {
  /// 使用共享数据库，不接管录音或本机草稿。
  constructor(private readonly prisma: PrismaService) {}

  /// 有界正式笔记搜索，返回预览而不把整库正文交给工具。
  list(actor: AuthUser, value: unknown = {}): Promise<Prisma.JsonValue> {
    // 仅提供已存在的笔记筛选语义。
    const input = objectInput(value, [
      'query',
      'fromDay',
      'toDay',
      'tagIds',
      'excludeTagIds',
      'withoutTags',
      'isPinned',
      'hasAudio',
      'hasImages',
      'limit',
      'offset',
    ]);
    // 文字搜索不做隐式值转换。
    const query =
      textInput(input.query, 'query', 200, true)?.toLowerCase() ?? '';
    // 记录自然日为左闭右开范围。
    const fromDay =
      input.fromDay === undefined
        ? undefined
        : dayInput(input.fromDay, 'fromDay');
    // 与创建日期无关。
    const toDay =
      input.toDay === undefined ? undefined : dayInput(input.toDay, 'toDay');
    if (fromDay && toDay && toDay <= fromDay)
      throw new BadRequestException('笔记日期范围必须为正');
    // 包含与排除标签分别表达。
    const included =
      input.tagIds === undefined
        ? []
        : idsInput(input.tagIds, 'tagIds', NOTE_MAX_TAGS);
    // 非有效标签不能用于匹配。
    const excluded =
      input.excludeTagIds === undefined
        ? []
        : idsInput(input.excludeTagIds, 'excludeTagIds', NOTE_MAX_TAGS);
    // 独立布尔筛选。
    const withoutTags =
      input.withoutTags === undefined
        ? false
        : booleanInput(input.withoutTags, 'withoutTags');
    // 元数据筛选不隐式更改笔记。
    const isPinned =
      input.isPinned === undefined
        ? undefined
        : booleanInput(input.isPinned, 'isPinned');
    // 附件标记对正式关联判断。
    const hasAudio =
      input.hasAudio === undefined
        ? undefined
        : booleanInput(input.hasAudio, 'hasAudio');
    // 草稿图片不会进入查询。
    const hasImages =
      input.hasImages === undefined
        ? undefined
        : booleanInput(input.hasImages, 'hasImages');
    // 实际返回仍受分页限制。
    const page = pageInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      // 标签名字仅来自同归属仍有效的笔记标签。
      const tags = await transaction.taxonomyEntry.findMany({
        where: {
          userId: actor.sub,
          module: 'notes',
          kind: 'tag',
          deletedAt: null,
        },
        select: { id: true, name: true },
      });
      // 为方言文字搜索保持准确性，先按元数据限制范围。
      const rows = await transaction.noteEntry.findMany({
        where: {
          userId: actor.sub,
          deletedAt: null,
          isPinned,
          dayKey: { gte: fromDay, lt: toDay },
        },
        include: {
          audioSegments: {
            where: { deletedAt: null },
            select: { transcript: true },
          },
          images: { where: { deletedAt: null }, select: { id: true } },
        },
        orderBy: [
          { isPinned: 'desc' },
          { dayKey: 'desc' },
          { recordTimeSeconds: 'desc' },
          { id: 'desc' },
        ],
      });
      // 有效标签映射排除已删除标签残留。
      const names = new Map(tags.map((tag) => [tag.id, tag.name]));
      // 搜索结果不包含完整音频转写或大段正文。
      const selected = rows
        .filter((row) => {
          // 标签 JSON 在已有同步规则中已验证。
          const ids = parseNoteTags(row.tags, 'tags').filter((id) =>
            names.has(id),
          );
          if (
            (withoutTags && ids.length) ||
            included.some((id) => !ids.includes(id)) ||
            excluded.some((id) => ids.includes(id))
          )
            return false;
          if (
            (hasAudio !== undefined &&
              !!row.audioSegments.length !== hasAudio) ||
            (hasImages !== undefined && !!row.images.length !== hasImages)
          )
            return false;
          return (
            !query ||
            [
              notePlainText(row.body),
              ...ids.map((id) => names.get(id)!),
              ...row.audioSegments.map((segment) => segment.transcript ?? ''),
            ]
              .join('\n')
              .toLowerCase()
              .includes(query)
          );
        })
        .slice(page.skip, page.skip + page.take + 1)
        .map((row) => ({
          id: row.id,
          dayKey: row.dayKey,
          recordTimeSeconds: row.recordTimeSeconds,
          recordUtcOffsetMinutes: row.recordUtcOffsetMinutes,
          isPinned: row.isPinned,
          tags: parseNoteTags(row.tags, 'tags').filter((id) => names.has(id)),
          revision: row.revision,
          bodyPreview: notePlainText(row.body).slice(0, 400),
          hasAudio: !!row.audioSegments.length,
          hasImages: !!row.images.length,
        }));
      return pageResult(selected, page);
    });
  }

  /// 详情仅返回正式笔记和已发布附件事实。
  get(actor: AuthUser, id: string): Promise<Prisma.JsonValue> {
    uuidInput(id);
    return businessRead(this.prisma, actor, async (transaction) =>
      requireActive(
        await transaction.noteEntry.findFirst({
          where: { id, userId: actor.sub },
          include: {
            audioSegments: {
              where: { deletedAt: null },
              orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
            },
            images: {
              where: { deletedAt: null },
              orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
            },
          },
        }),
      ),
    );
  }

  /// 新建文字笔记，同时建立首份不可变正文版本。
  create(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 创建事实由服务器固定，不允许模型伪造 createdAt。
    const input = objectInput(value, [
      'operationId',
      'body',
      'timeZone',
      'tags',
      'isPinned',
      'dayKey',
      'recordTimeSeconds',
      'recordUtcOffsetMinutes',
    ]);
    // 普通新建文字入口不接受空白无附件笔记。
    const body = bodyInput(input.body);
    if (!body.trim()) throw new BadRequestException('文字笔记不能为空');
    // 创建时区来自明确的业务上下文。
    const timeZone = timeZoneInput(input.timeZone);
    // 标签使用与同步相同的 UUID/数量验证。
    const tags =
      input.tags === undefined
        ? []
        : parseNoteTags(
            JSON.stringify(idsInput(input.tags, 'tags', NOTE_MAX_TAGS)),
            'tags',
          );
    // 置顶不产生额外正文版本。
    const isPinned =
      input.isPinned === undefined
        ? false
        : booleanInput(input.isPinned, 'isPinned');
    return businessWrite(
      this.prisma,
      actor,
      'notes.create',
      input,
      async (transaction) => {
        await this.validateTags(transaction, actor.sub, tags);
        // 首次执行的真实创建时间。
        const now = new Date();
        // 当前日历与固定偏移组成创建事实。
        const local = localParts(now, timeZone);
        // 可选记录时间必须成组且在允许范围内。
        const recordTime = this.recordTime(input) ?? {
          dayKey: local.day,
          recordTimeSeconds: local.seconds,
          recordUtcOffsetMinutes: local.offsetMinutes,
        };
        // 创建偏移字符串与客户端旧记录兜底规则一致。
        const offset = `${local.offsetMinutes < 0 ? '-' : '+'}${String(Math.floor(Math.abs(local.offsetMinutes) / 60)).padStart(2, '0')}:${String(Math.abs(local.offsetMinutes) % 60).padStart(2, '0')}`;
        // 新笔记身份和首个修订身份各自独立。
        const id = randomUUID(),
          revision = randomUUID();
        // 正式正文与初始候选在同一事务提交。
        const note = await transaction.noteEntry.create({
          data: {
            id,
            userId: actor.sub,
            body,
            revision,
            ...recordTime,
            isPinned,
            tags: JSON.stringify(tags.sort()),
            creationTimezone: `${timeZone}|${offset}`,
            createdAt: now,
            updatedAt: now,
          },
        });
        await transaction.noteVersion.create({
          data: {
            id: revision,
            userId: actor.sub,
            noteId: id,
            body,
            revision,
            baseRevision: revision,
            createdAt: now,
          },
        });
        return { status: 'saved', note };
      },
    );
  }

  /// 编辑正文、标签或元数据，正文冲突保留候选且不覆盖当前版。
  update(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 标签修改携带基线，不能提交未追踪的整列覆盖。
    const input = objectInput(value, [
      'operationId',
      'id',
      'body',
      'expectedRevision',
      'tags',
      'tagsBase',
      'isPinned',
      'dayKey',
      'recordTimeSeconds',
      'recordUtcOffsetMinutes',
    ]);
    return this.write(actor, input, false);
  }

  /// 追加属于一次原子正文修改，重试不会再次追加。
  append(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 必须明确基线及要追加的原始文字。
    const input = objectInput(value, [
      'operationId',
      'id',
      'text',
      'expectedRevision',
    ]);
    bodyInput(input.text);
    return this.write(actor, input, true);
  }

  /// 两种正文写入共用修订与冲突处理，不新增版本框架。
  private write(
    actor: AuthUser,
    input: Record<string, unknown>,
    appending: boolean,
  ): Promise<Prisma.JsonValue> {
    // 当前笔记目标。
    const id = uuidInput(input.id);
    // 正文写入才要求正文基线。
    const expected =
      appending || input.body !== undefined
        ? uuidInput(input.expectedRevision, 'expectedRevision')
        : null;
    // 元数据时间独立于正文修订，但必须作为整体选择。
    const recordTime = this.recordTime(input);
    // 标签输入与基线成对出现。
    if ((input.tags === undefined) !== (input.tagsBase === undefined))
      throw new BadRequestException('标签修改必须携带 tags 与 tagsBase');
    // 标签相对变化保留其他设备新增。
    const incomingTags =
      input.tags === undefined
        ? null
        : idsInput(input.tags, 'tags', NOTE_MAX_TAGS);
    // 基线不能从当前数据库反推。
    const baseTags =
      input.tagsBase === undefined
        ? null
        : idsInput(input.tagsBase, 'tagsBase', NOTE_MAX_TAGS);
    // 非正文置顶单独校验。
    const isPinned =
      input.isPinned === undefined
        ? undefined
        : booleanInput(input.isPinned, 'isPinned');
    if (!appending && input.body !== undefined) bodyInput(input.body);
    return businessWrite(
      this.prisma,
      actor,
      appending ? 'notes.append' : 'notes.update',
      input,
      async (transaction) => {
        // 删除优先：先确认仍为正式笔记，再处理版本。
        const current = requireActive(
          await transaction.noteEntry.findFirst({
            where: { id, userId: actor.sub },
          }),
        );
        // 追加冲突候选应基于请求真正看到的旧版，而不是伪称基于当前正文。
        const base =
          appending && expected !== current.revision
            ? await transaction.noteVersion.findFirst({
                where: {
                  userId: actor.sub,
                  noteId: id,
                  revision: expected!,
                  deletedAt: null,
                },
              })
            : null;
        if (appending && expected !== current.revision && !base)
          throw new ConflictException({
            code: 'NOTE_BASE_MISSING',
            message: '追加基线已不存在，请重新读取笔记',
          });
        // 缺省正文仅代表元数据修改。
        const body = appending
          ? bodyInput(
              `${base?.body ?? current.body}${(base?.body ?? current.body) ? '\n\n' : ''}${input.text as string}`,
            )
          : input.body === undefined
            ? current.body
            : bodyInput(input.body);
        // 新正文首先持久为不可变候选。
        const revision =
          body === current.body ? current.revision : randomUUID();
        if (revision !== current.revision) {
          await transaction.noteVersion.create({
            data: {
              id: revision,
              userId: actor.sub,
              noteId: id,
              body,
              revision,
              baseRevision: expected!,
              createdAt: new Date(),
            },
          });
          if (expected !== current.revision)
            return {
              status: 'conflict',
              note: current,
              candidateRevision: revision,
            };
        }
        // 标签做相对基线集合增删，数量与合法性统一验证。
        const tags = new Set(parseNoteTags(current.tags, 'current.tags'));
        if (incomingTags && baseTags) {
          // 列表不展示已删标签，编辑时同步移除这些失效残留，避免用户无法修改。
          const active = await transaction.taxonomyEntry.findMany({
            where: {
              userId: actor.sub,
              id: { in: [...tags] },
              module: 'notes',
              kind: 'tag',
              deletedAt: null,
            },
            select: { id: true },
          });
          // 只有已存失效引用自动移除，新请求的非法标签仍明确拒绝。
          const activeIds = new Set(active.map((tag) => tag.id));
          for (const tag of tags) if (!activeIds.has(tag)) tags.delete(tag);
          for (const tag of baseTags)
            if (!incomingTags.includes(tag)) tags.delete(tag);
          for (const tag of incomingTags)
            if (!baseTags.includes(tag)) tags.add(tag);
          if (tags.size > NOTE_MAX_TAGS)
            throw new BadRequestException('合并后超过十个笔记标签');
          await this.validateTags(transaction, actor.sub, [...tags]);
        }
        // 候选存在且基线匹配才提交正文；元数据缺省保持。
        const note = await transaction.noteEntry.update({
          where: { id },
          data: {
            ...(revision !== current.revision ? { body, revision } : {}),
            ...(recordTime ?? {}),
            ...(isPinned === undefined ? {} : { isPinned }),
            ...(incomingTags ? { tags: JSON.stringify([...tags].sort()) } : {}),
          },
        });
        await reconcileNotes(transaction, actor.sub);
        return { status: 'saved', note };
      },
    );
  }

  /// 同归属有效笔记标签才可从新工具入口绑定。
  private async validateTags(
    transaction: Prisma.TransactionClient,
    userId: string,
    tags: string[],
  ): Promise<void> {
    if (
      tags.length !==
      (await transaction.taxonomyEntry.count({
        where: {
          userId,
          id: { in: tags },
          module: 'notes',
          kind: 'tag',
          deletedAt: null,
        },
      }))
    )
      throw new ConflictException('笔记标签已失效或归属不匹配');
  }

  /// 与现有同步共用记录时间范围校验。
  private recordTime(input: Record<string, unknown>): {
    dayKey: string;
    recordTimeSeconds: number;
    recordUtcOffsetMinutes: number;
  } | null {
    if (
      input.dayKey === undefined &&
      input.recordTimeSeconds === undefined &&
      input.recordUtcOffsetMinutes === undefined
    )
      return null;
    // 明确日期和日内时钟整体保存。
    const dayKey = dayInput(input.dayKey, 'dayKey');
    // 不能让省略字段被当成零点。
    const recordTimeSeconds = integerInput(
      input.recordTimeSeconds,
      'recordTimeSeconds',
      0,
      86399,
    );
    // 固定偏移与记录日的实际含义绑定。
    const recordUtcOffsetMinutes = integerInput(
      input.recordUtcOffsetMinutes,
      'recordUtcOffsetMinutes',
      -840,
      840,
    );
    validateSelectedNoteRecordTime({
      day_key: dayKey,
      record_time_seconds: recordTimeSeconds,
      record_utc_offset_minutes: recordUtcOffsetMinutes,
    });
    return { dayKey, recordTimeSeconds, recordUtcOffsetMinutes };
  }

  /// 不可变正文历史有界读取，选择历史后仍需正常写入生成新修订。
  versions(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 历史仅属于具体有效笔记。
    const input = objectInput(value, ['id', 'limit', 'offset']);
    // 已保存笔记身份。
    const id = uuidInput(input.id);
    // 页上限限制输出正文数量。
    const page = pageInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      requireActive(
        await transaction.noteEntry.findFirst({
          where: { id, userId: actor.sub },
        }),
      );
      return pageResult(
        await transaction.noteVersion.findMany({
          where: { userId: actor.sub, noteId: id, deletedAt: null },
          orderBy: [{ createdAt: 'desc' }, { id: 'asc' }],
          skip: page.skip,
          take: page.take + 1,
        }),
        page,
      );
    });
  }

  /// 本体、历史与附件同批软删除，原音和图片仍走已有回收机制。
  trash(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 普通删除不允许客户端传入复活字段。
    const input = objectInput(value, ['operationId', 'id']);
    // 父笔记身份。
    const id = uuidInput(input.id);
    return businessWrite(
      this.prisma,
      actor,
      'notes.trash',
      input,
      async (transaction) => {
        requireActive(
          await transaction.noteEntry.findFirst({
            where: { userId: actor.sub, id },
          }),
        );
        // 与客户端已有恢复语义对应的统一时间。
        const deletedAt = new Date();
        await transaction.noteVersion.updateMany({
          where: { userId: actor.sub, noteId: id },
          data: { deletedAt },
        });
        await transaction.noteAudioSegment.updateMany({
          where: { userId: actor.sub, noteId: id },
          data: { deletedAt },
        });
        await transaction.noteImage.updateMany({
          where: { userId: actor.sub, noteId: id },
          data: { deletedAt },
        });
        return transaction.noteEntry.update({
          where: { id },
          data: { deletedAt },
        });
      },
    );
  }

  /// 正式笔记按记录自然日统计，与客户端的方言可见字口径一致。
  statistics(actor: AuthUser, value: unknown): Promise<Prisma.JsonValue> {
    // 周/月作为同一种范围查询。
    const input = objectInput(value, ['from', 'to', 'timeZone', 'asOf']);
    // 显式范围和地区口径。
    const range = rangeInput(input);
    return businessRead(this.prisma, actor, async (transaction) => {
      // 日期列取原始业务日，不改为 createdAt。
      const rows = await transaction.noteEntry.findMany({
        where: {
          userId: actor.sub,
          deletedAt: null,
          dayKey: {
            gte: localParts(range.from, range.timeZone).day,
            lte: localParts(range.to, range.timeZone).day,
          },
        },
        select: { id: true, dayKey: true, body: true },
      });
      // 日历记录以该地区自然日起点判断任意时间窗口归属。
      const selected = rows.filter((row) => {
        // 业务记录日与真实创建时刻分别保留。
        const at = localInstant(row.dayKey, 0, range.timeZone);
        return at >= range.from && at < range.to;
      });
      // 使用 Unicode 字素，emoji 不按 UTF-16 码元拆开计算。
      const segmenter = new Intl.Segmenter('zh-CN', {
        granularity: 'grapheme',
      });
      return {
        ...range,
        count: selected.length,
        words: selected.reduce(
          (sum, row) =>
            sum + [...segmenter.segment(notePlainText(row.body))].length,
          0,
        ),
        days: new Set(selected.map((row) => row.dayKey)).size,
        complete: true,
        sourceIds: selected.slice(0, 200).map((row) => row.id),
        sourcesTruncated: selected.length > 200,
        basis: 'recordDay',
      };
    });
  }
}
