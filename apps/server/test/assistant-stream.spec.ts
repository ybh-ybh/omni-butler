import type { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import type { Server } from 'node:http';
import { AiService } from '../src/ai/ai.service';
import { AssistantModelProvider } from '../src/ai/assistant-model.provider';
import { JwtAuthGuard } from '../src/auth/jwt-auth.guard';
import { AssistantController } from '../src/assistant/assistant.controller';
import { AssistantPresentation } from '../src/assistant/assistant-presentation.service';
import { AssistantStore } from '../src/assistant/assistant-store.service';
import { AssistantEntityEditor } from '../src/assistant/assistant-entity-editor.service';
import { AssistantMessageNotes } from '../src/assistant/assistant-message-notes.service';

/// 事件内容全部来自合成数据，HTTP 只监听本机随机端口。
interface StreamEvent {
  /// 持久游标用于断线去重。
  seq: number;
  /// 正文增量与终态事件共享同一个传输路径。
  type: string;
  /// 模拟持久事件的公开内容。
  data: Record<string, unknown>;
}

/// 保留网络拆包余量，只返回完整 SSE 数据帧。
async function* readFrames(
  response: Response,
): AsyncGenerator<Record<string, unknown>> {
  // 网络读取使用真实 fetch 流，而不是预先拼接的字符串。
  const reader = response.body!.getReader();
  // 跨网络包保留完整 UTF-8 中文。
  const decoder = new TextDecoder();
  // 未收到空行的尾部仍属于下一个网络包。
  let pending = '';
  try {
    while (true) {
      // 每次只读取当前已到达的数据，不能等待整个响应关闭。
      const chunk = await reader.read();
      if (chunk.done) return;
      pending += decoder.decode(chunk.value, { stream: true });
      // 心跳帧不作为业务事件交付。
      const frames = pending.split('\n\n');
      pending = frames.pop() ?? '';
      for (const frame of frames) {
        // 服务端每条持久事件均只有一个 data 字段。
        const data = frame.split('\n').find((line) => line.startsWith('data: '));
        if (data) yield JSON.parse(data.slice(6)) as Record<string, unknown>;
      }
    }
  } finally {
    reader.releaseLock();
  }
}

describe('助手真实 HTTP SSE 逐段发送', () => {
  // 每例测试使用独立 HTTP 应用，不连接数据库或模型供应商。
  let application: INestApplication;
  // UUID 通过真实控制器参数校验。
  const runId = randomUUID();
  // 有序持久事件在测试期间分批到达。
  let storedEvents: StreamEvent[];
  // 记录游标请求，验证恢复时不重新读取已经展示的增量。
  const events = jest.fn<Promise<StreamEvent[]>, [unknown, string, number]>();
  // 任务始终处于运行中，防止终态响应假扮流式输出。
  const run = jest.fn().mockResolvedValue({ status: 'running', requiresTakeover: false });

  beforeEach(async () => {
    storedEvents = [];
    events.mockReset();
    events.mockImplementation((_actor, _id, after) =>
      Promise.resolve(storedEvents.filter((event) => event.seq > after)),
    );
    // 注入只有本用例需要的存储边界，保留真实路由和 SSE 控制器。
    const module = await Test.createTestingModule({
      controllers: [AssistantController],
      providers: [
        { provide: AssistantStore, useValue: { events, run } },
        { provide: AiService, useValue: {} },
        { provide: AssistantModelProvider, useValue: {} },
        { provide: AssistantPresentation, useValue: {} },
        { provide: AssistantEntityEditor, useValue: {} },
        { provide: AssistantMessageNotes, useValue: {} },
      ],
    })
      .overrideGuard(JwtAuthGuard)
      .useValue({ canActivate: (): boolean => true })
      .compile();
    application = module.createNestApplication();
    await application.listen(0, '127.0.0.1');
  });

  afterEach(async () => {
    // 测试退出显式释放订阅 socket，不等待一分钟连接轮换期限。
    const server = application.getHttpServer() as Server;
    server.closeAllConnections();
    await application.close();
  });

  it('任务完成前逐段可读，带游标重连只收到后续增量', async () => {
    // 客户端中止只断开本次订阅，存储里的任务仍保持 running。
    const controller = new AbortController();
    // 有界等待保证流式回归失败时不会卡住测试进程。
    const timeout = setTimeout(() => controller.abort(), 5000);
    // 第二次订阅单独取消，模拟 Windows 自动恢复连接。
    const resumed = new AbortController();
    // 仅本机测试地址可访问，没有任何真实访问令牌。
    const endpoint = `${await application.getUrl()}/assistant/runs/${runId}/events`;
    storedEvents.push({ seq: 1, type: 'message.delta', data: { messageId: 'answer', text: '你好' } });
    try {
      // fetch 在响应头完成后返回，正文连接仍保持开启。
      const response = await fetch(endpoint, { signal: controller.signal });
      expect(response.status).toBe(200);
      expect(response.headers.get('content-type')).toBe('text/event-stream');
      expect(response.headers.get('x-accel-buffering')).toBe('no');
      // 首片段必须在第二片段写入前送到 HTTP 客户端。
      const frames = readFrames(response);
      expect((await frames.next()).value).toMatchObject({ seq: 1, runId, data: { text: '你好' } });
      storedEvents.push({ seq: 2, type: 'message.delta', data: { messageId: 'answer', text: '，正在回答' } });
      expect((await frames.next()).value).toMatchObject({ seq: 2, runId, data: { text: '，正在回答' } });
      expect(storedEvents.some((event) => event.type === 'message.completed')).toBe(false);
      controller.abort();
      await frames.return(undefined);

      storedEvents.push({ seq: 3, type: 'message.delta', data: { messageId: 'answer', text: '。' } });
      // 重连沿用最近消费序号，不能重复拼接前两段。
      const nextResponse = await fetch(`${endpoint}?after=2`, {
        signal: AbortSignal.any([resumed.signal, AbortSignal.timeout(5000)]),
      });
      // 后续流仍使用相同业务事件协议。
      const nextFrames = readFrames(nextResponse);
      expect((await nextFrames.next()).value).toMatchObject({ seq: 3, runId, data: { text: '。' } });
      expect(events).toHaveBeenCalledWith(undefined, runId, 2);
      resumed.abort();
      await nextFrames.return(undefined);
    } finally {
      clearTimeout(timeout);
      controller.abort();
      resumed.abort();
    }
  });
});
