import { assistantInstructions, assistantPromptPolicy, assistantStageInstructions } from '../src/assistant/assistant-prompts';
import { mcpTodoCreatePolicy, mcpTodoDatePolicy } from '../src/mcp/mcp-catalog';

describe('知序提示词的阶段与交付约束', () => {
  it('新增任务复用工具默认规则，只追问无法确定的必要信息', () => {
    expect(assistantPromptPolicy).toContain(mcpTodoCreatePolicy);
    expect(assistantPromptPolicy).toContain('用户给出任务名称即可创建');
    expect(assistantPromptPolicy).toContain('不把完善信息当作执行前提');
    expect(assistantPromptPolicy).toContain('默认值不替代授权');
    expect(assistantPromptPolicy).toContain('更新时省略字段保留原值');
    expect(assistantPromptPolicy).toContain('未指定时不设置截止/提醒、不拆分、不重复');
    expect(assistantPromptPolicy).toContain('重名必须先澄清');
  });
  it.each(['supported', 'unsupported', 'unknown'] as const)('每轮以任务快照中的图片能力%s为准，不沿用历史自述', (imageInput) => {
    // 固定同一时间与阶段，单独验证能力声明的分支。
    const instructions = assistantInstructions(new Date('2026-10-24T06:00:00Z'), 'Asia/Shanghai', 'answer', imageInput);
    expect(instructions).toContain(imageInput === 'supported' ? '本次模型配置已开启图片输入' : '本次模型配置未声明支持图片输入');
    expect(instructions).toContain('chunks或matches为空只表示没有提取或匹配到文字');
    expect(instructions).toContain('不能沿用历史回答中的能力自述');
    if (imageInput !== 'supported') expect(instructions).not.toContain('本次模型配置已开启图片输入');
  });

  it('固定规则不混入环境，最终回答独立完整并区分两种日期', () => {
    // 同一规则可在不同时间和时区复用，环境单独位于末尾。
    const first = assistantInstructions(new Date('2026-10-24T06:00:00Z'), 'Asia/Shanghai', 'answer');
    // 后续请求的时间变化不会改写固定身份或授权规则。
    const second = assistantInstructions(new Date('2026-10-25T06:00:00Z'), 'UTC', 'answer');
    expect(first.startsWith(assistantPromptPolicy)).toBe(true);
    expect(second.startsWith(assistantPromptPolicy)).toBe(true);
    expect(assistantPromptPolicy).not.toContain('2026-10');
    expect(first).toContain('业务时区Asia/Shanghai');
    expect(second).toContain('业务时区UTC');
    expect(assistantPromptPolicy).toContain(mcpTodoDatePolicy);
    expect(assistantPromptPolicy).toContain('不主动展示、比较或评论计划日期');
    expect(assistantPromptPolicy).toContain('除非用户明确提及计划日期、要求按日期筛选或安排');
    expect(assistantPromptPolicy).toContain('只有实际截止日期已过且未完成时才能判断逾期');
    expect(assistantPromptPolicy).toContain('仅计划日期已过不能称为“逾期”');
    expect(assistantPromptPolicy).toContain('来源卡仅提供打开记录的入口，不能代替答案');
    expect(assistantPromptPolicy).toContain('普通查询不展示内部字段');
    expect(assistantPromptPolicy).toContain('附件回答引用实际已读的文件名');
  });

  it('正常收尾明确草稿尚未展示，不强制输出覆盖或推测声明', () => {
    // 最终输出身份来自服务端阶段，而不是同轮模型已写过的正文。
    const stage = assistantStageInstructions('answer');
    expect(stage).toContain('尚未向用户展示');
    expect(stage).toContain('必须重新给出用户所问的具体结果');
    expect(stage).toContain('若有效查询无结果');
    expect(stage).not.toContain('预算已到上限');
    expect(stage).not.toContain('明确覆盖范围及推测');
  });

  it('预算耗尽和业务提交的提示分别忠于已读事实与实际回执', () => {
    // 预算耗尽仍须交付主体，不能只生成限制声明。
    const limited = assistantStageInstructions('limitedAnswer');
    // 写入结果不复用只读草稿的交付假设。
    const committed = assistantStageInstructions('committedAnswer');
    expect(limited).toContain('列出真实已读结果，再简短说明');
    expect(limited).toContain('尚未向用户展示');
    expect(committed).toContain('服务器实际执行回执');
    expect(committed).toContain('部分成功或冲突');
    expect(committed).not.toContain('查询预算已到上限');
    expect(committed).not.toContain('尚未向用户展示');
    expect(assistantStageInstructions('query')).not.toContain('本次是用户将看到的完整答复');
  });
});
