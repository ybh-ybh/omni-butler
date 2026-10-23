import {
  Annotation,
  type CompiledStateGraph,
  END,
  START,
  StateGraph,
  interrupt,
} from '@langchain/langgraph';
import type { BaseCheckpointSaver } from '@langchain/langgraph-checkpoint';

/// checkpoint只保留运行指针和阶段，执行事实仍从权威数据库读取。
const graphState = Annotation.Root({
  runId: Annotation<string>(),
  route: Annotation<string>(),
});
/// 图节点通过同一执行接口恢复，避免把框架状态误作授权。
export interface AssistantGraphSteps {
  /// 每次节点运行从数据库恢复并返回下一阶段。
  step(runId: string, phase: string): Promise<string>;
  /// 确认检查仅返回暂停资料，不执行任何业务写入。
  gate(runId: string): Promise<unknown>;
}
/// 显式ReAct图将查询循环、冻结计划和确认执行分开。
export function buildAssistantGraph(
  checkpointer: BaseCheckpointSaver,
  steps: AssistantGraphSteps,
): CompiledStateGraph<
  typeof graphState.State,
  typeof graphState.Update,
  | '__start__'
  | 'dispatch'
  | 'model'
  | 'tools'
  | 'prepare'
  | 'gate'
  | 'commit'
  | 'finish',
  typeof graphState.spec,
  typeof graphState.spec
> {
  // 条件路由只允许已登记节点，不能让模型指定跳转函数。
  const routes = {
    model: 'model',
    tools: 'tools',
    prepare: 'prepare',
    gate: 'gate',
    commit: 'commit',
    finish: 'finish',
    end: END,
  } as const;
  // 每个节点只推进一个可恢复阶段。
  const node =
    (
      phase: string,
    ): ((state: typeof graphState.State) => Promise<{ route: string }>) =>
    async (state: typeof graphState.State): Promise<{ route: string }> => ({
      route: await steps.step(state.runId, phase),
    });
  // 中断前后的检查可以重复，提交节点不包含在中断节点内。
  const gate = async (
    state: typeof graphState.State,
  ): Promise<{ route: string }> => {
    // 由数据库确认事实决定是否暂停，恢复值本身不是授权。
    const pending = await steps.gate(state.runId);
    if (pending !== null) {
      interrupt(pending);
      // resume携带任意值均不算确认，必须再次读取权威事实。
      if ((await steps.gate(state.runId)) !== null)
        throw new Error('助手操作尚未获得有效确认');
    }
    return { route: 'commit' };
  };
  return new StateGraph(graphState)
    .addNode('dispatch', node('dispatch'))
    .addNode('model', node('model'))
    .addNode('tools', node('tools'))
    .addNode('prepare', node('prepare'))
    .addNode('gate', gate)
    .addNode('commit', node('commit'))
    .addNode('finish', node('finish'))
    .addEdge(START, 'dispatch')
    .addConditionalEdges('dispatch', (state) => state.route, routes)
    .addConditionalEdges('model', (state) => state.route, routes)
    .addConditionalEdges('tools', (state) => state.route, routes)
    .addConditionalEdges('prepare', (state) => state.route, routes)
    .addConditionalEdges('gate', (state) => state.route, routes)
    .addConditionalEdges('commit', (state) => state.route, routes)
    .addEdge('finish', END)
    .compile({ checkpointer });
}
