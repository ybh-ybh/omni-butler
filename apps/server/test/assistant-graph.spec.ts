import { Command, MemorySaver } from '@langchain/langgraph';
import { buildAssistantGraph } from '../src/assistant/assistant-graph';

describe('助手显式ReAct循环和确认中断', () => {
  it('两个对象冻结后暂停，确认事实改变后才进入提交节点', async () => {
    // 模拟权威确认存储，resume内容本身不提供授权。
    let approved = false;
    // 所有执行阶段按顺序留下证据。
    const calls: string[] = [];
    const graph = buildAssistantGraph(new MemorySaver(), {
      step(_runId, phase): Promise<string> {
        calls.push(phase);
        return Promise.resolve(
          (
            {
              dispatch: 'model',
              model: 'prepare',
              prepare: 'gate',
              commit: 'finish',
              finish: 'end',
            } as Record<string, string>
          )[phase]!,
        );
      },
      gate(): Promise<unknown> {
        return Promise.resolve(approved ? null : { targetCount: 2 });
      },
    });
    // 测试身份仅用于内存checkpoint。
    const options = { configurable: { thread_id: 'batch-test' } };
    const paused = await graph.invoke(
      { runId: 'run', route: 'model' },
      options,
    );
    expect(
      (paused as unknown as { __interrupt__: unknown[] }).__interrupt__,
    ).toHaveLength(1);
    expect(calls).not.toContain('commit');
    // 伪造resume=true也不能替代服务端确认事实。
    await expect(
      graph.invoke(new Command({ resume: true }), options),
    ).rejects.toThrow('尚未获得有效确认');
    expect(calls).not.toContain('commit');
    approved = true;
    await graph.invoke(new Command({ resume: {} }), options);
    expect(calls.filter((phase) => phase === 'commit')).toHaveLength(1);
    expect(calls.at(-1)).toBe('finish');
  });

  it('单条计划直接完成，查询工具可在模型循环中执行', async () => {
    // 第一次模型调用查询，第二次才冻结写计划。
    let modelCalls = 0;
    const phases: string[] = [];
    const graph = buildAssistantGraph(new MemorySaver(), {
      step(_id, phase): Promise<string> {
        phases.push(phase);
        if (phase === 'model')
          return Promise.resolve(++modelCalls === 1 ? 'tools' : 'prepare');
        return Promise.resolve(
          (
            {
              dispatch: 'model',
              tools: 'model',
              prepare: 'gate',
              commit: 'finish',
              finish: 'end',
            } as Record<string, string>
          )[phase]!,
        );
      },
      gate(): Promise<unknown> {
        return Promise.resolve(null);
      },
    });
    await graph.invoke(
      { runId: 'single', route: 'model' },
      { configurable: { thread_id: 'single' } },
    );
    expect(phases).toEqual([
      'dispatch',
      'model',
      'tools',
      'model',
      'prepare',
      'commit',
      'finish',
    ]);
  });

  it('冻结失败不进入确认或提交', async () => {
    // 真实业务预演错误必须沿图传播，不能伪装完成。
    const commits = jest.fn();
    const graph = buildAssistantGraph(new MemorySaver(), {
      step(_id, phase): Promise<string> {
        if (phase === 'prepare') throw new Error('baseline conflict');
        if (phase === 'commit') commits();
        return Promise.resolve(phase === 'dispatch' ? 'model' : 'prepare');
      },
      gate(): Promise<unknown> {
        return Promise.resolve(null);
      },
    });
    await expect(
      graph.invoke(
        { runId: 'failure', route: 'model' },
        { configurable: { thread_id: 'failure' } },
      ),
    ).rejects.toThrow('baseline conflict');
    expect(commits).not.toHaveBeenCalled();
  });
});
