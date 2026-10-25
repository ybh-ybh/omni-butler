import type { INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Test } from '@nestjs/testing';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { BusinessRecycleService } from '../src/business/business-recycle.service';
import { EventsService } from '../src/business/events.service';
import { InventoryService } from '../src/business/inventory.service';
import { MembershipsService } from '../src/business/memberships.service';
import { NotesBusinessService } from '../src/business/notes-business.service';
import { QuotesService } from '../src/business/quotes.service';
import { TimeEntriesService } from '../src/business/time-entries.service';
import { TodosService } from '../src/business/todos.service';
import type { McpConnection } from '../src/generated/prisma/client';
import {
  McpCatalog,
  mcpAutoTaxonomyPolicy,
  mcpTodoCreatePolicy,
  mcpTodoDatePolicy,
  mcpModules,
  mcpRequestId,
  type McpModule,
} from '../src/mcp/mcp-catalog';
import { McpController } from '../src/mcp/mcp.controller';
import { McpEditTokenService } from '../src/mcp/mcp-edit-token.service';
import { McpReviewService } from '../src/mcp/mcp-review.service';
import { McpService, mcpHash } from '../src/mcp/mcp.service';
import { PrismaService } from '../src/prisma/prisma.service';

/// 只检查协议发布的说明，不连接数据库或执行任何业务写入。
describe('MCP 工具与参数说明的真实协议契约', () => {
  // 随机本地端口上的真实 Nest HTTP 服务。
  let app: INestApplication;
  // 拥有七模块读写权限的标准 MCP 客户端。
  let client: Client;
  // SDK 从服务端实际收到的工具 JSON Schema。
  let publishedTools: Tool[];
  // 仅内存存储的专用连接样本，绝不读取部署配置。
  const connections = new Map<string, McpConnection>();
  // 认证和能力查询仅依赖这些只读持久层入口。
  const connectionStore = {
    // 能力读取调度状态，不触发重复实例生成。
    todoRecurrenceState: {
      findUnique: jest.fn((): Promise<null> => Promise.resolve(null)),
    },
    mcpConnection: {
      findUnique: jest.fn(
        (input: { where: { id: string } }): Promise<McpConnection | null> =>
          Promise.resolve(connections.get(input.where.id) ?? null),
      ),
    },
    deviceSession: {
      findFirst: jest.fn(
        (input: {
          where: { id: string; userId: string };
        }): Promise<{ id: string } | null> => {
          // 会话仍须匹配同一连接的归属。
          const connection = [...connections.values()].find(
            (entry) =>
              entry.sessionId === input.where.id &&
              entry.userId === input.where.userId,
          );
          return Promise.resolve(
            connection ? { id: connection.sessionId } : null,
          );
        },
      ),
    },
  };

  /// 构造内存专用令牌，通过真实认证逻辑连接标准 SDK。
  async function connect(
    writeModules: McpModule[],
    readModules: McpModule[] = [...mcpModules],
  ): Promise<Client> {
    // 随机身份仅用于当前测试进程。
    const id = randomUUID();
    // 每个客户端使用独立临时令牌，不依赖用户密钥。
    const token = `omni_mcp_${id}.${randomBytes(32).toString('base64url')}`;
    connections.set(id, {
      id,
      userId: randomUUID(),
      name: '工具说明协议测试',
      tokenHash: mcpHash(token),
      sessionId: randomUUID(),
      readModules,
      writeModules,
      timeZone: 'Asia/Shanghai',
      expiresAt: null,
      revokedAt: null,
      createdAt: new Date(),
    });
    // 真实 HTTP 传输能够检测注册 Schema 丢失说明的情况。
    const sdk = new Client({ name: 'mcp-description-test', version: '1.0' });
    await sdk.connect(
      new StreamableHTTPClientTransport(new URL(`${await app.getUrl()}/mcp`), {
        requestInit: { headers: { Authorization: `Bearer ${token}` } },
      }),
    );
    return sdk;
  }

  beforeAll(async () => {
    // 编辑凭据使用本次测试专属密钥，不读取开发或部署密钥。
    const keys = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    });
    // 业务服务只注册为空对象；意外执行业务会直接失败，不能产生副作用。
    const module = await Test.createTestingModule({
      controllers: [McpController],
      providers: [
        McpCatalog,
        McpService,
        McpEditTokenService,
        {
          provide: ConfigService,
          useValue: new ConfigService({
            JWT_PRIVATE_KEY_BASE64: Buffer.from(keys.privateKey).toString(
              'base64',
            ),
            JWT_PUBLIC_KEY_BASE64: Buffer.from(keys.publicKey).toString(
              'base64',
            ),
          }),
        },
        { provide: PrismaService, useValue: connectionStore },
        ...[
          McpReviewService,
          QuotesService,
          TimeEntriesService,
          TodosService,
          InventoryService,
          MembershipsService,
          EventsService,
          NotesBusinessService,
          BusinessRecycleService,
        ].map((service) => ({ provide: service, useValue: {} })),
      ],
    }).compile();
    app = module.createNestApplication();
    await app.listen(0, '127.0.0.1');
    client = await connect([...mcpModules]);
    publishedTools = (await client.listTools()).tools;
  });

  afterAll(async () => {
    await client?.close();
    await app?.close();
  });

  /// 递归收集对象字段，包含数组元素和批量操作的所有联合分支。
  function fieldDescriptions(
    schema: unknown,
    path: string,
  ): Array<{ path: string; description: unknown }> {
    if (!schema || typeof schema !== 'object' || Array.isArray(schema))
      return [];
    // 已确认是 JSON Schema 对象，后续逐项检查而非假定字段类型。
    const node = schema as Record<string, unknown>;
    // 返回路径帮助定位实际遗漏的工具参数。
    const fields: Array<{ path: string; description: unknown }> = [];
    if (
      node.properties &&
      typeof node.properties === 'object' &&
      !Array.isArray(node.properties)
    ) {
      for (const [name, property] of Object.entries(node.properties)) {
        // 每个对象属性必须自带业务说明，内部 null 分支无需重复说明。
        const detail = property as Record<string, unknown>;
        fields.push({
          path: `${path}.${name}`,
          description: detail.description,
        });
        fields.push(...fieldDescriptions(property, `${path}.${name}`));
      }
    }
    for (const keyword of ['anyOf', 'oneOf', 'allOf']) {
      // 联合类型可能包含批量工具的独立参数结构。
      const alternatives = node[keyword];
      if (Array.isArray(alternatives))
        alternatives.forEach((alternative: unknown, index: number) => {
          fields.push(
            ...fieldDescriptions(alternative, `${path}.${keyword}[${index}]`),
          );
        });
    }
    fields.push(...fieldDescriptions(node.items, `${path}[]`));
    return fields;
  }

  it('65 个工具与 330 个顶层参数均有简短说明，嵌套步骤和批量分支不遗漏', () => {
    expect(publishedTools).toHaveLength(65);
    expect(
      publishedTools.reduce(
        (total, tool) =>
          total + Object.keys(tool.inputSchema.properties ?? {}).length,
        0,
      ),
    ).toBe(330);
    for (const tool of publishedTools) {
      expect(tool.description?.trim()).toBeTruthy();
      // 带完整路径报告缺失、占位或过长说明，避免只检查顶层数量。
      const invalid = fieldDescriptions(tool.inputSchema, tool.name).filter(
        ({ description }) =>
          typeof description !== 'string' ||
          !description.trim() ||
          description.length > 160 ||
          description.includes('源代码未配置'),
      );
      expect(invalid).toEqual([]);
    }
    // 确认递归确实经过嵌套步骤与批量各分支。
    const nested = publishedTools.flatMap((tool) =>
      fieldDescriptions(tool.inputSchema, tool.name),
    );
    expect(nested.some(({ path }) => path.includes('.steps[].name'))).toBe(
      true,
    );
    expect(
      nested.some(({ path }) =>
        /^prepare_batch\.actions\[\]\.anyOf\[\d+\]\.arguments\./.test(path),
      ),
    ).toBe(true);
  });

  it('初始化与精简能力发现发布相同自动分类规则，工具目录只由tools/list提供', async () => {
    expect(client.getServerVersion()?.version).toBe('3.0.0');
    expect(client.getInstructions()).toContain(mcpAutoTaxonomyPolicy);
    expect(client.getInstructions()).toContain(mcpTodoCreatePolicy);
    // 能力结果经过真实 JSON-RPC，而不是直接测试常量字符串。
    const result = await client.callTool({
      name: 'get_capabilities',
      arguments: {},
    });
    expect(result.isError).not.toBe(true);
    expect(result.structuredContent).toMatchObject({
      capabilityVersion: '3.0',
      timeZone: 'Asia/Shanghai',
      todoRecurrence: {
        status: 'not_checked',
        timeZone: null,
        reason: null,
        checkedAt: null,
      },
      workflow: { autoTaxonomy: mcpAutoTaxonomyPolicy, todoDefaults: mcpTodoCreatePolicy },
    });
    expect(result.structuredContent).not.toHaveProperty('tools');
    expect(result.structuredContent).not.toHaveProperty('examples');
    expect(result.structuredContent).toHaveProperty('serverTime');
    expect(result.structuredContent).toHaveProperty('limits');
  });

  it('四模块新增、分类查询与批量准备均说明选已有项，更新不附加新增推断规则', () => {
    for (const name of [
      'start_time_entry',
      'create_time_entry',
      'create_item',
      'create_membership',
      'create_note',
      'list_taxonomies',
      'prepare_batch',
    ])
      expect(
        publishedTools.find((tool) => tool.name === name)?.description,
      ).toContain(mcpAutoTaxonomyPolicy);
    for (const name of [
      'update_time_entry',
      'update_item',
      'update_membership',
      'update_note',
    ]) {
      // 更新工具存在，但不鼓励替换用户已经保存的分类标签。
      const tool = publishedTools.find((entry) => entry.name === name);
      expect(tool).toBeDefined();
      expect(tool?.description).not.toContain(mcpAutoTaxonomyPolicy);
    }
    expect(mcpAutoTaxonomyPolicy).toContain('最合适的一个已有项');
    expect(mcpAutoTaxonomyPolicy).toContain('无合适项时留空，不新建');
    expect(mcpAutoTaxonomyPolicy).toContain('明确留空时不推断');
    expect(mcpAutoTaxonomyPolicy).toContain('更新不自动重分类');
    expect(mcpAutoTaxonomyPolicy).toContain('查询失败须说明');
  });

  it('初始化与待办查询工具共用日期规则，只读连接也能获得说明', async () => {
    // 单模块只读宿主仍应收到日期含义与默认回答约束。
    const readonlyClient = await connect([], ['todos']);
    try {
      expect(readonlyClient.getInstructions()).toContain(mcpTodoDatePolicy);
      // 核对真实协议发布内容，避免只改常量却遗漏注册入口。
      const tools = (await readonlyClient.listTools()).tools;
      for (const name of ['list_todos', 'get_todo']) {
        expect(tools.find((tool) => tool.name === name)?.description).toContain(mcpTodoDatePolicy);
      }
      expect(tools.find((tool) => tool.name === 'list_todos')?.inputSchema.properties?.fromDay).toMatchObject({
        description: expect.stringContaining('按计划日期筛选'),
      });
    } finally {
      await readonlyClient.close();
    }
  });

  it('每个直接写入、批量准备和撤销工具的 requestId 保留 UUID 必填约束', () => {
    for (const tool of publishedTools.filter(
      (entry) =>
        entry.annotations?.readOnlyHint === false &&
        !['commit_action', 'cancel_action'].includes(entry.name),
    )) {
      expect(tool.inputSchema.required).toContain('requestId');
      expect(tool.inputSchema.properties?.requestId).toMatchObject({
        type: 'string',
        format: 'uuid',
        description: mcpRequestId.description,
      });
    }
  });

  it('旧重复入口不再发布，单条写入用业务名且统一入口完整保留', () => {
    // 内部路由保留的旧名称不能出现在模型工具集合。
    const hidden = [
      ...mcpModules.flatMap((module) => [
        `list_${module}_recycle_bin`,
        `restore_${module}`,
      ]),
      'get_quote_summary',
      'get_time_summary',
      'get_todo_summary',
      'get_inventory_summary',
      'get_membership_spending',
      'get_event_summary',
      'get_note_summary',
      'list_ongoing_time_entries',
      'materialize_repeated_todos',
    ];
    // 同一名称只发布一次，不允许旧prepare别名悄悄保留。
    const names = publishedTools.map((tool) => tool.name);
    expect(new Set(names).size).toBe(names.length);
    expect(names.filter((name) => name.startsWith('prepare_'))).toEqual([
      'prepare_batch',
    ]);
    for (const name of hidden) expect(names).not.toContain(name);
    for (const name of [
      'list_recycle_bin',
      'restore_record',
      'get_statistics',
      'create_time_entry',
      'create_item',
      'create_membership',
      'create_note',
    ])
      expect(names).toContain(name);
  });

  it('精简参数与编辑凭据通过实际SDK公开，废弃字段不再出现在Schema', () => {
    // 覆盖容易误用的名称字段、无效选项和拆分存储字段。
    const removed: Record<string, string[]> = {
      list_time_entries: ['timeZone', 'asOf'],
      start_time_entry: ['category'],
      create_time_entry: ['category'],
      update_time_entry: ['category'],
      finish_time_entry: ['category'],
      create_item: ['category', 'location', 'tags'],
      update_item: ['category', 'location', 'tags'],
      create_membership: ['category', 'isPermanent'],
      update_membership: ['category', 'isPermanent', 'timeZone'],
      update_todo: ['taskType'],
      create_note: ['dayKey', 'recordTimeSeconds', 'recordUtcOffsetMinutes'],
      update_note: [
        'dayKey',
        'recordTimeSeconds',
        'recordUtcOffsetMinutes',
        'expectedRevision',
        'tagsBase',
      ],
      append_note: ['expectedRevision'],
      replace_todo_steps: ['baseline'],
    };
    for (const [name, fields] of Object.entries(removed)) {
      // 查询真实发布的严格对象Schema，保证旧参数会被拒绝。
      const schema = publishedTools.find(
        (tool) => tool.name === name,
      )?.inputSchema;
      expect(schema).toBeDefined();
      expect(schema?.additionalProperties).toBe(false);
      for (const field of fields)
        expect(schema?.properties).not.toHaveProperty(field);
    }
    for (const name of ['update_note', 'append_note', 'replace_todo_steps']) {
      // 编辑凭据必须是读取时获得的不透明非空文字。
      const schema = publishedTools.find(
        (tool) => tool.name === name,
      )?.inputSchema;
      expect(schema?.required).toContain('editToken');
      expect(schema?.properties?.editToken).toMatchObject({
        type: 'string',
        minLength: 1,
      });
    }
    for (const name of ['create_note', 'update_note']) {
      expect(
        publishedTools.find((tool) => tool.name === name)?.inputSchema
          .properties?.recordedAt,
      ).toMatchObject({ type: 'string', format: 'date-time' });
    }
    // 进行中查询不需要人为构造窗口，状态值仍是固定枚举。
    const timeSchema = publishedTools.find(
      (tool) => tool.name === 'list_time_entries',
    )?.inputSchema;
    expect(timeSchema?.required ?? []).not.toContain('from');
    expect(timeSchema?.required ?? []).not.toContain('to');
    expect(timeSchema?.properties?.status).toMatchObject({
      enum: ['ongoing', 'finished', 'all'],
    });
    // 新建仍可以选择任务类型，不能因精简更新字段丢失创建能力。
    expect(
      publishedTools.find((tool) => tool.name === 'create_todo')?.inputSchema
        .properties,
    ).toHaveProperty('taskType');
    // 真实外部MCP只要求任务名称和协议请求身份，不再迫使宿主追问日期。
    const createTodo = publishedTools.find((tool) => tool.name === 'create_todo');
    expect(createTodo?.inputSchema.required).toEqual(['title', 'requestId']);
    expect(createTodo?.description).toContain(mcpTodoCreatePolicy);
  });

  it('单模块连接的统一入口、分类和批量分支均不枚举未授权模块', async () => {
    // 单模块写权限独立于前面的全权限连接。
    const noteClient = await connect(['notes'], ['notes']);
    try {
      // 协议返回的Schema必须已经按当前连接收窄。
      const tools = (await noteClient.listTools()).tools;
      for (const name of [
        'list_recycle_bin',
        'restore_record',
        'get_statistics',
        'list_taxonomies',
      ]) {
        expect(
          tools.find((tool) => tool.name === name)?.inputSchema.properties
            ?.module,
        ).toMatchObject({ enum: ['notes'] });
      }
      // 总结的模块选择也只能使用当前可读模块。
      const review = tools.find((tool) => tool.name === 'get_review_context');
      expect(review?.inputSchema.properties?.modules).toMatchObject({
        items: { enum: ['notes'] },
      });
      // 批量联合分支可准确审查名称和恢复模块，不能夹带任意工具名。
      const batch = tools.find((tool) => tool.name === 'prepare_batch');
      // 联合分支保持真实字段结构，逐项检查写入模块边界。
      const actions = batch?.inputSchema.properties?.actions as {
        items: {
          anyOf: Array<{
            properties: {
              tool: { const: string };
              arguments: { properties: Record<string, unknown> };
            };
          }>;
        };
      };
      expect(
        actions.items.anyOf
          .map((branch) => branch.properties.tool.const)
          .sort(),
      ).toEqual([
        'append_note',
        'create_note',
        'delete_note',
        'restore_record',
        'update_note',
      ]);
      expect(
        actions.items.anyOf.find(
          (branch) => branch.properties.tool.const === 'restore_record',
        )?.properties.arguments.properties.module,
      ).toMatchObject({ enum: ['notes'] });
      expect(tools.some((tool) => tool.name === 'create_item')).toBe(false);
      // 猜测被隐藏或未授权工具名也无法绕过实际注册边界。
      const denied = await noteClient.callTool({
        name: 'list_inventory',
        arguments: {},
      });
      expect(denied.isError).toBe(true);
    } finally {
      await noteClient.close();
    }
  });

  it('只读连接仍只公开查询工具，自动分类说明不扩大写权限', async () => {
    // 独立只读连接保留分类查询，不能获得直接写入、准备或执行工具。
    const readonlyClient = await connect([]);
    try {
      // 从第二个真实 SDK 会话读取实际可见工具。
      const tools = (await readonlyClient.listTools()).tools;
      expect(tools.some((tool) => tool.name === 'list_taxonomies')).toBe(true);
      expect(
        tools.every((tool) => tool.annotations?.readOnlyHint === true),
      ).toBe(true);
      expect(
        tools.some(
          (tool) =>
            tool.name.startsWith('prepare_') ||
            [
              'restore_record',
              'commit_action',
              'cancel_action',
              'undo_action',
            ].includes(tool.name),
        ),
      ).toBe(false);
      // 能力发现同样按连接权限过滤，不引用拥有写权限的另一会话。
      const result = await readonlyClient.callTool({
        name: 'get_capabilities',
        arguments: {},
      });
      expect(result.isError).not.toBe(true);
      expect(result.structuredContent).toMatchObject({
        modules: mcpModules.map((module) => ({
          module,
          read: true,
          write: false,
        })),
      });
    } finally {
      await readonlyClient.close();
    }
  });
});
