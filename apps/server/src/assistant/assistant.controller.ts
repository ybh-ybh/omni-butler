import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  Put,
  Query,
  Res,
  UseFilters,
  UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import { z } from 'zod';
import { CurrentUser } from '../auth/current-user.decorator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import type { AuthUser } from '../auth/auth.types';
import { AiService } from '../ai/ai.service';
import { AssistantModelProvider } from '../ai/assistant-model.provider';
import { AssistantStore } from './assistant-store.service';
import { AssistantErrorFilter } from './assistant-error.filter';
import { AssistantPresentation } from './assistant-presentation.service';
import { AssistantEntityEditor } from './assistant-entity-editor.service';
import { AssistantMessageNotes, type SavedAssistantNote } from './assistant-message-notes.service';

/// 仅设备JWT入口能确认助手计划，不复用外部MCP Bearer授权。
@Controller('assistant')
@UseGuards(JwtAuthGuard)
@UseFilters(AssistantErrorFilter)
export class AssistantController {
  /// 后端状态与模型测试分别通过明确依赖调用。
  constructor(
    private readonly store: AssistantStore,
    private readonly ai: AiService,
    private readonly model: AssistantModelProvider,
    private readonly presentation: AssistantPresentation,
    private readonly entityEditor: AssistantEntityEditor,
    private readonly messageNotes: AssistantMessageNotes,
  ) {}
  /// 两端共享助手设置。
  @Get('settings') settings(@CurrentUser() actor: AuthUser): Promise<unknown> {
    return this.store.settings(actor);
  }
  /// 设置使用独立修订号。
  @Put('settings') updateSettings(
    @CurrentUser() actor: AuthUser,
    @Body() body: unknown,
  ): Promise<unknown> {
    return this.store.updateSettings(actor, body);
  }
  /// 固定文本工具探测不发送业务数据。
  @Post('test') async test(
    @CurrentUser() actor: AuthUser,
    @Body() body: unknown,
  ): Promise<unknown> {
    // 这里只接受同owner保存配置的身份。
    const input = z.strictObject({ profileId: z.uuid(), vision: z.boolean().optional() }).parse(body);
    await this.store.authorized(actor, () => Promise.resolve(undefined));
    // 兼容旧客户端的vision字段，但不再发送图片探测或修改多模态声明。
    const profile = await this.ai.captureAssistantProfile(actor.sub, input.profileId);
    return this.model.testCapability(actor.sub, profile);
  }
  /// 获取最近会话。
  @Get('conversations') conversations(
    @CurrentUser() actor: AuthUser,
    @Query('cursor') cursor?: string,
    @Query('query') query?: string,
  ): Promise<unknown> {
    return this.store.conversations(actor, cursor, query);
  }
  /// 建立空会话，不启动模型。
  @Post('conversations') create(
    @CurrentUser() actor: AuthUser,
    @Body() body: unknown,
  ): Promise<unknown> {
    return this.store.createConversation(actor, body);
  }
  /// 重命名和置顶只改变会话展示信息。
  @Patch('conversations/:id') rename(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ): Promise<unknown> {
    return this.store.rename(actor, id, body);
  }
  /// 删除会话不删除已创建业务记录。
  @Delete('conversations/:id') remove(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<unknown> {
    return this.store.removeConversation(actor, id);
  }
  /// 消息按稳定游标分页。
  @Get('conversations/:id/messages') messages(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Query('before') before?: string,
    @Query('cursor') cursor?: string,
  ): Promise<unknown> {
    return this.store.messages(actor, id, before ?? cursor);
  }
  /// 发送先持久化身份，后台worker独立于HTTP存活。
  @Post('conversations/:id/messages') send(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ): Promise<unknown> {
    return this.store.send(actor, id, body);
  }
  /// 人工保存已完成回答，直接复用笔记业务服务。
  @Post('messages/:id/note') saveMessageNote(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ): Promise<SavedAssistantNote> {
    return this.messageNotes.save(actor, id, body);
  }
  /// 查询真实执行状态。
  @Get('runs/:id') run(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<unknown> {
    return this.store.run(actor, id);
  }
  /// 停止不能撤销已经完成的提交。
  @Post('runs/:id/stop') stop(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<unknown> {
    return this.store.stop(actor, id);
  }
  /// 未知付费调用只允许显式重试。
  @Post('runs/:id/retry') retry(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<unknown> {
    return this.store.retry(actor, id);
  }
  /// 接管更换设备会话与租约，保留动作身份。
  @Post('runs/:id/takeover') takeover(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<unknown> {
    return this.store.retry(actor, id, true);
  }
  /// 单条新增十分钟内准备软删除补偿，实际提交仍经过运行门禁。
  @Post('runs/:id/undo') undo(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<unknown> {
    return this.store.undo(actor, id);
  }
  /// 显示冻结的预览。
  @Get('plans/:id') plan(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<unknown> {
    return this.store.plan(actor, id);
  }
  /// 确认和取消都绑定计划摘要。
  @Post('plans/:id/decision') decision(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ): Promise<unknown> {
    return this.store.decision(actor, id, body);
  }
  /// 获取可编辑的显式记忆。
  @Get('memories') memories(
    @CurrentUser() actor: AuthUser,
    @Query('cursor') cursor?: string,
  ): Promise<unknown> {
    return this.store.memories(actor, cursor);
  }
  /// 服务器快照按固定模块及真实ID读取，不接受自由链接。
  @Get('entities/:module/:id') entity(
    @CurrentUser() actor: AuthUser,
    @Param('module') module: string,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<unknown> {
    return this.presentation.entity(actor, module, id);
  }
  /// 人工编辑基于当前版本直接保存，重复请求复用原回执。
  @Patch('entities/:module/:id') updateEntity(
    @CurrentUser() actor: AuthUser,
    @Param('module') module: string,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ): Promise<unknown> {
    return this.entityEditor.update(actor, module, id, body);
  }
  /// 人工新增不依赖模型理解授权。
  @Post('memories') createMemory(
    @CurrentUser() actor: AuthUser,
    @Body() body: unknown,
  ): Promise<unknown> {
    return this.store.saveMemory(actor, body);
  }
  /// 编辑要求原版本。
  @Patch('memories/:id') updateMemory(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ): Promise<unknown> {
    return this.store.saveMemory(actor, body, id);
  }
  /// 清空覆盖来源和派生缓存。
  @Delete('memories') clearMemories(
    @CurrentUser() actor: AuthUser,
  ): Promise<unknown> {
    return this.store.deleteMemory(actor);
  }
  /// 删除单条使后续上下文失效。
  @Delete('memories/:id') deleteMemory(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
  ): Promise<unknown> {
    return this.store.deleteMemory(actor, id);
  }
  /// SSE可按序号续接，断开订阅不停止任务。
  @Get('runs/:id/events') async events(
    @CurrentUser() actor: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Query('after') after: string | undefined,
    @Res() response: Response,
  ): Promise<void> {
    // 游标不接受负数或无界整数。
    let cursor = z.coerce
      .number()
      .int()
      .min(0)
      .max(2147483647)
      .parse(after ?? 0);
    await this.store.run(actor, id);
    response.setHeader('Content-Type', 'text/event-stream');
    response.setHeader('Cache-Control', 'no-cache, no-transform');
    response.setHeader('X-Accel-Buffering', 'no');
    response.flushHeaders();
    // 连接最长一分钟，客户端带游标重连，避免永久占用旧JWT。
    const deadline = Date.now() + 60000;
    try {
      while (!response.destroyed && Date.now() < deadline) {
        // 每批重新检查设备会话，换服和撤权后不继续输出。
        const events = (await this.store.events(actor, id, cursor)) as Array<{
          seq: number;
          type: string;
          data: unknown;
        }>;
        // 控制能力是当前订阅设备的视图，不能沿用worker原设备的事件投影。
        const view = (await this.store.run(actor, id)) as {
          requiresTakeover?: boolean;
        };
        for (const event of events) {
          // 事件业务事实保持不变，仅按当前设备投影接管状态。
          const data = event.data as Record<string, unknown>;
          const projected =
            data?.run && typeof data.run === 'object'
              ? {
                  ...event,
                  data: {
                    ...data,
                    run: {
                      ...data.run,
                      requiresTakeover: !!view.requiresTakeover,
                    },
                  },
                }
              : event;
          response.write(
            `id: ${event.seq}\ndata: ${JSON.stringify({ ...projected, runId: id })}\n\n`,
          );
          cursor = event.seq;
        }
        response.write(': heartbeat\n\n');
        // 异步短轮询只影响本订阅，不阻塞运行器。
        await new Promise<void>((resolve) => {
          const timer = setTimeout(resolve, 500);
          timer.unref();
        });
      }
    } catch {
      if (!response.destroyed)
        response.write(
          `event: error\ndata: ${JSON.stringify({ code: 'ASSISTANT_STREAM_CLOSED', message: '连接已失效，请重新连接' })}\n\n`,
        );
    } finally {
      response.end();
    }
  }
}
