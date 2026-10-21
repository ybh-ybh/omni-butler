import {
  ExecutionContext,
  INestApplication,
  ValidationPipe,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import { AuthController } from '../src/auth/auth.controller';
import { AuthService } from '../src/auth/auth.service';
import type { AuthUser } from '../src/auth/auth.types';
import { JwtAuthGuard } from '../src/auth/jwt-auth.guard';
import { JwksService } from '../src/auth/jwks.service';
import { SyncController } from '../src/sync/sync.controller';
import { SyncService } from '../src/sync/sync.service';
import { syncSchemaVersion } from '../src/sync/sync-schema';
import { SyncMigrationController } from '../src/sync/sync-migration.controller';
import { SyncMigrationService } from '../src/sync/sync-migration.service';
import { NotesController } from '../src/notes/notes.controller';
import { NotesService } from '../src/notes/notes.service';
import { AiService } from '../src/ai/ai.service';

/// 真实路由、请求头提取和DTO验证共同阻止旧客户端破坏新版数据。
describe('同步结构版本 HTTP 边界', () => {
  // 监听本机随机端口的独立应用。
  let app: INestApplication;
  // 测试请求的根地址。
  let baseUrl: string;
  // 已验证身份，仅替换身份读取而保留控制器行为。
  const user: AuthUser = {
    sub: randomUUID(),
    sid: randomUUID(),
    typ: 'access',
  };
  // 可观察的增量写入边界。
  const applyBatch = jest
    .fn()
    .mockResolvedValue({ applied: 1, ignored: 0, replayed: false });
  // 可观察的全量替换边界。
  const replace = jest.fn().mockResolvedValue({ status: 'committed' });
  // 旧客户端不能继续提交付费识别或读取会被提前插入的原文。
  const recognize = jest.fn().mockResolvedValue({ status: 'queued' });
  // 任务读取边界不能绕过同一结构门禁。
  const current = jest.fn().mockResolvedValue({ status: 'succeeded', transcript: '原文' });
  // 旧端仍可撤回已提交的授权。
  const cancel = jest.fn().mockResolvedValue({ cancelled: true });
  // 可观察的下行凭证签发边界。
  const issuePowerSyncToken = jest
    .fn()
    .mockResolvedValue({ syncSchemaVersion });
  // 预检必须可让旧客户端得到可解释的版本结果。
  const preview = jest
    .fn()
    .mockResolvedValue({
      protocolVersion: 1,
      snapshotVersion: 3,
      syncSchemaVersion,
    });
  // 升级前待确认迁移可在升级后继续查询原回执。
  const status = jest
    .fn()
    .mockResolvedValue({ status: 'committed', payloadHash: 'legacy-hash' });

  beforeAll(async () => {
    // 以生产DTO验证管道处理真实HTTP请求。
    const module = await Test.createTestingModule({
      controllers: [AuthController, SyncController, SyncMigrationController, NotesController],
      providers: [
        { provide: AuthService, useValue: { issuePowerSyncToken } },
        { provide: JwksService, useValue: {} },
        { provide: SyncService, useValue: { applyBatch } },
        { provide: NotesService, useValue: { recognize, current, cancel } },
        { provide: AiService, useValue: {} },
        {
          provide: SyncMigrationService,
          useValue: { replace, preview, status },
        },
      ],
    })
      .overrideGuard(JwtAuthGuard)
      .useValue({
        /// 为受保护路由提供固定测试主体。
        canActivate(context: ExecutionContext): boolean {
          context.switchToHttp().getRequest<{ user: AuthUser }>().user = user;
          return true;
        },
      })
      .compile();
    app = module.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );
    await app.listen(0, '127.0.0.1');
    baseUrl = await app.getUrl();
  });

  beforeEach(() => jest.clearAllMocks());
  afterAll(async () => {
    await app?.close();
  });

  /// 使用与客户端一致的JSON请求及可选协议头。
  async function post(
    path: string,
    body: object,
    version?: string,
  ): Promise<Response> {
    return fetch(`${baseUrl}${path}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(version ? { 'X-Omni-Sync-Schema': version } : {}),
      },
      body: JSON.stringify(body),
    });
  }

  /// 每个接口的最小合法负载，排除DTO错误对协议校验的干扰。
  const requests: [string, object][] = [
    [
      '/sync/operations',
      {
        clientId: randomUUID(),
        transactionId: '1',
        operations: [
          {
            op: 'PATCH',
            table: 'todo_progress_steps',
            id: randomUUID(),
            data: { is_completed: true },
          },
        ],
      },
    ],
    [
      '/sync/migrations',
      {
        syncKey: 'valid-test-sync-key',
        migrationId: randomUUID(),
        expectedOwnerId: randomUUID(),
        snapshotVersion: 3,
        operations: [],
      },
    ],
    ['/auth/powersync-token', {}],
  ];

  it.each(requests)(
    '%s 对缺失、旧版和未知新版协议头拒绝且不写入',
    async (path, body) => {
      for (const version of [undefined, ...Array.from({ length: syncSchemaVersion - 1 }, (_value, index) => String(index + 1)), String(syncSchemaVersion + 1)]) {
        // 请求协议不兼容时，响应提供准确的服务器版本。
        const response = await post(path, body, version);
        expect(response.status).toBe(409);
        expect(await response.json()).toMatchObject({
          code: 'SYNC_SCHEMA_MISMATCH',
          syncSchemaVersion,
        });
      }
      expect(applyBatch).not.toHaveBeenCalled();
      expect(replace).not.toHaveBeenCalled();
      expect(issuePowerSyncToken).not.toHaveBeenCalled();
    },
  );

  it.each(requests)(
    '%s 接受新版请求，步骤表可以通过DTO白名单',
    async (path, body) => {
      expect((await post(path, body, String(syncSchemaVersion))).status).toBe(200);
    },
  );

  it('会话与预检返回结构版本，旧回执查询不受版本门禁阻断', async () => {
    expect(await (await fetch(`${baseUrl}/auth/session`)).json()).toMatchObject(
      { sub: user.sub, syncSchemaVersion },
    );
    expect(
      await (
        await post('/sync/connection-preview', {
          syncKey: 'valid-test-sync-key',
        })
      ).json(),
    ).toMatchObject({ syncSchemaVersion, snapshotVersion: 3 });
    expect(
      await (
        await post('/sync/migrations/status', {
          syncKey: 'valid-test-sync-key',
          migrationId: randomUUID(),
        })
      ).json(),
    ).toMatchObject({ status: 'committed', payloadHash: 'legacy-hash' });
  });

  it('新版客户端必须先将旧快照转换为v3再提交', async () => {
    expect(
      (
        await post(
          '/sync/migrations',
          { ...requests[1]![1], snapshotVersion: 1 },
          String(syncSchemaVersion),
        )
      ).status,
    ).toBe(400);
    expect(replace).not.toHaveBeenCalled();
  });

  it('ASR 提交和原文读取拒绝旧端，撤回仍允许旧端执行', async () => {
    // 实际原音路由形状，不需要创建外部计费任务。
    const path = `/notes/audio/${randomUUID()}/recognitions`;
    for (const version of [undefined, '10']) {
      expect((await post(path, { operationId: randomUUID(), consent: true }, version)).status).toBe(409);
      expect((await fetch(`${baseUrl}${path}/current`, { headers: version ? { 'X-Omni-Sync-Schema': version } : {} })).status).toBe(409);
    }
    expect(recognize).not.toHaveBeenCalled(); expect(current).not.toHaveBeenCalled();
    expect((await post(path, { operationId: randomUUID(), consent: true }, String(syncSchemaVersion))).status).toBe(201);
    expect((await fetch(`${baseUrl}${path}/current`, { headers: { 'X-Omni-Sync-Schema': String(syncSchemaVersion) } })).status).toBe(200);
    expect((await fetch(`${baseUrl}${path}/current`, { method: 'DELETE', headers: { 'X-Omni-Sync-Schema': '10' } })).status).toBe(200);
    expect(cancel).toHaveBeenCalledTimes(1);
  });
});
