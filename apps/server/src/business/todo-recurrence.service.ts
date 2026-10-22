import {
  Injectable,
  Logger,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';
import type { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { addDays, localParts, timeZoneInput } from './business-input';
import { TodosService } from './todos.service';

/// 每轮至多处理十个归属，公平排序避免一个历史很长的归属占住队列。
const ownersPerTick = 10;
/// 每个归属一次最多推进四个系列。
const seriesPerOwner = 4;
/// 每个系列只推进一周，长时间停机通过持久断点逐轮补齐。
const daysPerSeries = 7;
/// 后台轮询间隔不依赖客户端或 MCP 查询。
const pollMilliseconds = 30000;

/// 数据库选出的可推进系列。
interface DueSeries {
  /// 客户端共用的系列身份。
  seriesId: string;
  /// 当前最早实例决定日历锚点。
  anchorDay: Date;
  /// 新系列或锚点变化时从首日检查。
  nextDay: Date;
  /// 规则实际变化后从锚点重查，不把新生成行当成新排程。
  scheduleSignature: string;
}

/// 服务启动和定时器驱动生成，查询工具始终保持只读。
@Injectable()
export class TodoRecurrenceService implements OnModuleInit, OnModuleDestroy {
  /// 只记录固定错误码，不打印连接凭据或业务正文。
  private readonly logger = new Logger(TodoRecurrenceService.name);
  /// 不阻止进程退出的定时句柄。
  private timer: ReturnType<typeof setInterval> | undefined;
  /// 单进程扫描合并，跨进程仍靠 owner 行锁串行。
  private activeTick: Promise<void> | undefined;
  /// 停服后停止领取下一个归属。
  private stopping = false;

  /// 复用领域生成规则与持久数据库。
  constructor(
    private readonly prisma: PrismaService,
    private readonly todos: TodosService,
  ) {}

  /// 启动立即恢复，无需等待有人打开待办页。
  onModuleInit(): void {
    this.schedule();
    this.timer = setInterval(() => this.schedule(), pollMilliseconds);
    this.timer.unref();
  }

  /// 等待当前有界事务结束，断点和生成记录一起提交。
  async onModuleDestroy(): Promise<void> {
    this.stopping = true;
    if (this.timer) clearInterval(this.timer);
    await this.activeTick?.catch(() => undefined);
  }

  /// 定时器失败不成为未处理拒绝，下一轮仍可继续恢复。
  private schedule(): void {
    void this.runOnce().catch(() =>
      this.logger.error('TODO_RECURRENCE_SCAN_FAILED'),
    );
  }

  /// 可独立验证的一轮调度；并发调用复用同一在途轮次。
  runOnce(): Promise<void> {
    if (this.stopping) return Promise.resolve();
    if (!this.activeTick) {
      this.activeTick = this.tick().finally(() => {
        this.activeTick = undefined;
      });
    }
    return this.activeTick;
  }

  /// 固定预算逐归属推进，单个坏系列不会阻止其他归属。
  private async tick(): Promise<void> {
    // 既有状态也参与扫描，使撤销后的状态明确变为不可执行。
    const owners = await this.prisma.$queryRaw<Array<{ userId: string }>>`
      SELECT candidates.user_id AS "userId"
      FROM (
        SELECT user_id FROM mcp_connections
        WHERE 'todos' = ANY(read_modules) AND 'todos' = ANY(write_modules)
        UNION SELECT user_id FROM todo_recurrence_states
      ) candidates
      JOIN sync_owners owners ON owners.id = candidates.user_id
      LEFT JOIN todo_recurrence_states state ON state.user_id = candidates.user_id
      ORDER BY state.checked_at ASC NULLS FIRST, candidates.user_id ASC
      LIMIT ${ownersPerTick}`;
    for (const owner of owners) {
      if (this.stopping) break;
      try {
        await this.processOwner(owner.userId);
      } catch {
        this.logger.warn('TODO_RECURRENCE_OWNER_FAILED');
        // 失败事务已回滚，不推进断点，下一轮可以继续。
        await this.prisma.todoRecurrenceState
          .upsert({
            where: { userId: owner.userId },
            create: {
              userId: owner.userId,
              status: 'error',
              reason: 'GENERATION_FAILED',
              checkedAt: new Date(),
            },
            update: {
              status: 'error',
              reason: 'GENERATION_FAILED',
              checkedAt: new Date(),
            },
          })
          .catch(() => undefined);
      }
    }
  }

  /// 与同步和 MCP 共用归属锁，授权撤销及实例生成不能交叉提交。
  private async processOwner(userId: string): Promise<void> {
    await this.prisma.$transaction(
      async (transaction) => {
        // 归属可能刚被换服清空；不存在就结束本次工作。
        const owners = await transaction.$queryRaw<Array<{ id: string }>>`
        SELECT id FROM sync_owners WHERE id = ${userId}::uuid FOR UPDATE`;
        if (!owners.length) return;
        // 时间在取得锁后确定，不能使用等待锁之前的授权有效期。
        const now = new Date();
        // 所有有效写连接均参与时区判断，不能任意挑选一个时区。
        const connections = await transaction.$queryRaw<
          Array<{ timeZone: string | null }>
        >`
        SELECT connection.time_zone AS "timeZone"
        FROM mcp_connections connection
        JOIN device_sessions session ON session.id = connection.session_id AND session.user_id = connection.user_id
        WHERE connection.user_id = ${userId}::uuid
          AND connection.revoked_at IS NULL
          AND (connection.expires_at IS NULL OR connection.expires_at > ${now})
          AND session.expires_at > ${now}
          AND 'todos' = ANY(connection.read_modules)
          AND 'todos' = ANY(connection.write_modules)
        ORDER BY connection.created_at ASC, connection.id ASC`;
        if (!connections.length) {
          await this.setState(
            transaction,
            userId,
            'blocked_authorization',
            null,
            'NO_ACTIVE_WRITE_CONNECTION',
            now,
          );
          return;
        }
        // 未配置时区的连接不能提供执行上下文；明确时区必须一致。
        const configured = connections
          .map((connection) => connection.timeZone)
          .filter((zone): zone is string => zone !== null);
        if (!configured.length) {
          await this.setState(
            transaction,
            userId,
            'blocked_timezone',
            null,
            'TIME_ZONE_REQUIRED',
            now,
          );
          return;
        }
        // IANA 别名规范化，避免 UTC 与 Etc/UTC 等同义名称产生假冲突。
        let zones: Set<string>;
        try {
          zones = new Set(
            configured.map(
              (zone) =>
                new Intl.DateTimeFormat('en', {
                  timeZone: timeZoneInput(zone),
                }).resolvedOptions().timeZone,
            ),
          );
        } catch {
          await this.setState(
            transaction,
            userId,
            'blocked_timezone',
            null,
            'INVALID_TIME_ZONE',
            now,
          );
          return;
        }
        if (zones.size !== 1) {
          await this.setState(
            transaction,
            userId,
            'blocked_timezone',
            null,
            'CONFLICTING_TIME_ZONES',
            now,
          );
          return;
        }
        // 每轮只采用当前唯一时区，不推断服务器或设备地区。
        const timeZone = [...zones][0]!;
        // 今日上界采用连接时区，未来实例交由下一日生成。
        const today = localParts(now, timeZone).day;
        // 尚未追平的系列按最近推进时间公平分配预算。
        const series = await this.dueSeries(
          transaction,
          userId,
          timeZone,
          today,
          seriesPerOwner,
        );
        for (const item of series) {
          await transaction.$executeRaw`SAVEPOINT todo_recurrence_series`;
          try {
            // 新系列或排程变化从自身锚点开始，普通实例不会重置断点。
            let day = item.nextDay.toISOString().slice(0, 10);
            for (
              let checked = 0;
              checked < daysPerSeries && day <= today;
              checked++
            ) {
              await this.todos.materializeRepeatedDay(
                transaction,
                userId,
                day,
                timeZone,
                item.seriesId,
              );
              day = addDays(day, 1);
            }
            // 实例与断点一起提交，成功后清除该系列之前的失败退避。
            const cursor = {
              anchorDay: item.anchorDay,
              nextDay: new Date(`${day}T00:00:00Z`),
              timeZone,
              scheduleSignature: item.scheduleSignature,
              errorCode: null,
              retryAfter: null,
            };
            await transaction.todoRecurrenceCursor.upsert({
              where: { userId_seriesId: { userId, seriesId: item.seriesId } },
              create: { userId, seriesId: item.seriesId, ...cursor },
              update: cursor,
            });
            await transaction.$executeRaw`RELEASE SAVEPOINT todo_recurrence_series`;
          } catch {
            // 仅撤回当前系列的部分日期，其他系列已经生成的内容仍可提交。
            await transaction.$executeRaw`ROLLBACK TO SAVEPOINT todo_recurrence_series`;
            await transaction.$executeRaw`RELEASE SAVEPOINT todo_recurrence_series`;
            // 失败不推进日期，但保存重试时间以让健康系列继续得到预算。
            const failed = {
              anchorDay: item.anchorDay,
              nextDay: item.nextDay,
              timeZone,
              scheduleSignature: item.scheduleSignature,
              errorCode: 'GENERATION_FAILED',
              retryAfter: new Date(now.getTime() + 60000),
            };
            await transaction.todoRecurrenceCursor.upsert({
              where: { userId_seriesId: { userId, seriesId: item.seriesId } },
              create: { userId, seriesId: item.seriesId, ...failed },
              update: failed,
            });
          }
        }
        // 明确区分已追平和仍有历史待生成。
        const pending = await this.dueSeries(
          transaction,
          userId,
          timeZone,
          today,
          1,
        );
        // 退避期间保留明确失败状态，不能误报所有系列已追平。
        const failures = await transaction.$queryRaw<
          Array<{ seriesId: string }>
        >`
          SELECT cursor.series_id AS "seriesId" FROM todo_recurrence_cursors cursor
          WHERE cursor.user_id = ${userId}::uuid AND cursor.error_code IS NOT NULL
            AND EXISTS (SELECT 1 FROM todo_items item
              WHERE item.user_id = cursor.user_id AND item.parent_id IS NULL AND item.repeat_rule IS NOT NULL
                AND COALESCE(item.repeat_series_id, item.id) = cursor.series_id)
          LIMIT 1`;
        await this.setState(
          transaction,
          userId,
          failures.length ? 'error' : pending.length ? 'catching_up' : 'idle',
          timeZone,
          failures.length ? 'GENERATION_FAILED' : null,
          now,
        );
      },
      { maxWait: 30000, timeout: 60000 },
    );
  }

  /// 每次查询主动发现新系列，持久断点只减少已经检查过的自然日。
  private dueSeries(
    transaction: Prisma.TransactionClient,
    userId: string,
    timeZone: string,
    today: string,
    limit: number,
  ): Promise<DueSeries[]> {
    return transaction.$queryRaw<DueSeries[]>`
      WITH versions AS (
        SELECT COALESCE(repeat_series_id, id) AS series_id, id, scheduled_date, repeat_rule,
          LAG(repeat_rule) OVER (PARTITION BY COALESCE(repeat_series_id, id) ORDER BY scheduled_date, id) AS previous_rule
        FROM todo_items
        WHERE user_id = ${userId}::uuid AND parent_id IS NULL AND repeat_rule IS NOT NULL
      ), series AS (
        SELECT series_id AS id, MIN(scheduled_date) AS anchor_day,
          MD5(STRING_AGG(CASE WHEN previous_rule IS DISTINCT FROM repeat_rule
            THEN scheduled_date::text || ':' || repeat_rule END, ',' ORDER BY scheduled_date, id)) AS schedule_signature
        FROM versions GROUP BY series_id
      )
      SELECT series.id AS "seriesId", series.anchor_day AS "anchorDay",
        CASE WHEN cursor.anchor_day = series.anchor_day AND cursor.time_zone = ${timeZone}
            AND cursor.schedule_signature = series.schedule_signature
          THEN cursor.next_day ELSE series.anchor_day END AS "nextDay",
        series.schedule_signature AS "scheduleSignature"
      FROM series
      LEFT JOIN todo_recurrence_cursors cursor ON cursor.user_id = ${userId}::uuid AND cursor.series_id = series.id
      WHERE series.anchor_day <= ${today}::date
        AND (cursor.series_id IS NULL OR cursor.anchor_day <> series.anchor_day
          OR cursor.time_zone <> ${timeZone} OR cursor.schedule_signature <> series.schedule_signature
          OR cursor.next_day <= ${today}::date)
        AND (cursor.retry_after IS NULL OR cursor.retry_after <= CURRENT_TIMESTAMP
          OR cursor.anchor_day <> series.anchor_day OR cursor.time_zone <> ${timeZone}
          OR cursor.schedule_signature <> series.schedule_signature)
      ORDER BY cursor.updated_at ASC NULLS FIRST, series.id ASC
      LIMIT ${limit}`;
  }

  /// 固定状态码便于诊断，不暴露任何连接令牌。
  private async setState(
    transaction: Prisma.TransactionClient,
    userId: string,
    status: string,
    timeZone: string | null,
    reason: string | null,
    checkedAt: Date,
  ): Promise<void> {
    // 相同归属重用一行状态，避免无限追加运行日志。
    const data = { status, timeZone, reason, checkedAt };
    await transaction.todoRecurrenceState.upsert({
      where: { userId },
      create: { userId, ...data },
      update: data,
    });
  }
}
