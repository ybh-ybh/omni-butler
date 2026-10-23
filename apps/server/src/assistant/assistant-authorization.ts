/// 工具动作类别由服务器固定，不能由资料或模型改写。
type WriteKind = 'create' | 'update' | 'delete' | 'restore';
/// 仅当前顶层要求建立写入边界；无法识别时先澄清。
const verbs: Record<WriteKind, string> = {
  create:
    '新增|添加|新建|创建|补记|记一笔|(?:^|[，。！？;\\n])\\s*(?:请|帮我|替我|给我|麻烦你)?\\s*记录|加入|收录|保存|写.{0,12}笔记',
  update:
    '修改|更新|改为|改成|调整|编辑|追加|搬家|移动|改名|重命名|启用|禁用|置顶|取消置顶|安排|延期|标记|设置|完成|续费|打卡|关闭|结束|开始|启动|暂停|勾选|归档|取消归档',
  delete: '删除|移除|丢弃|作废|清空|回收',
  restore: '恢复|还原',
};
/// 明确提到模块时不允许模型越过该模块写入其他业务。
const moduleWords: Record<string, RegExp> = {
  quotes: /名言|日签/u,
  time: /时间记录|计时|补记|\d{1,2}[点时:].{0,20}(?:到|至|[-—])|时间段/u,
  todos: /待办|任务|进度/u,
  inventory: /物品|配件|搬家/u,
  memberships: /会员|续费|订阅|账期/u,
  events: /事件|周期事务|打卡/u,
  notes: /笔记/u,
};
/// 排除引号或粘贴资料中的动词，资料不构成新的写授权。
function commandText(request: string): string {
  // “以下资料/原文”之后只作为资料；单独命令需放在引用之前。
  const top =
    request.split(
      /(?:以下(?:是)?(?:资料|原文|正文|内容)|笔记原文)\s*[:：]|```/u,
    )[0] ?? '';
  return (
    top
      .replace(/「[^」]*」|“[^”]*”|"[^"\n]*"/gu, '')
      // 查询条件中的状态形容词不能当作动作动词。
      .replace(
        /(?:已(?:经)?|未|待)完成|已删除|已恢复|已归档|已暂停|已结束/gu,
        '',
      )
      .replace(
        new RegExp(
          `(?:不要|别|不用|无需|不必|不需要|不想)(?:再|帮我)?(?:${Object.values(verbs).join('|')})`,
          'gu',
        ),
        '',
      )
  );
}
/// 无明确业务写指令时不把写函数交给模型，检索注入不能扩展范围。
export function assistantWriteAllowed(
  request: string,
  name: string,
  module?: string,
): boolean {
  // 输入只来自持久用户要求，不能传入工具正文。
  const command = commandText(request);
  // “记住某种做法”描述偏好，不等于现在执行其中提到的业务动作。
  if (
    /^(?:请|帮我|麻烦你|请你|我希望你|我想让你)?\s*(?:记住|记下|记着)|^(?:please\s+)?remember\b/iu.test(
      command.trim(),
    )
  )
    return false;
  const kind: WriteKind = name.startsWith('restore_')
    ? 'restore'
    : name.startsWith('delete_') || name.startsWith('remove_')
      ? 'delete'
      : name.startsWith('create_') || name.startsWith('add_')
        ? 'create'
        : 'update';
  // 查询目标可能含“置顶/续费/新增”等名称，只有另起明确动作才开放写入。
  if (
    /^(?:(?:请|帮我|麻烦你|请你|给我)\s*)?(?:查询|查看|查找|看看|看一下|检索|搜索|分析|总结|统计|列出|显示|告诉我|找出|找一下)/u.test(
      command.trim(),
    ) &&
    !new RegExp(
      `(?:并(?:且)?|然后|再|顺便|最后|同时|[，。;\\n])\\s*(?:请|帮我)?\\s*(?:${verbs[kind]})`,
      'u',
    ).test(command)
  )
    return false;
  // 用户改成只读任务时，之前累计的写入要求全部失效。
  const latest = request.split('用户补充或修订：').at(-1) ?? request;
  if (
    /(?:只(?:想|要|需(?:要)?)?|仅(?:仅)?)(?:查询|查看|检索|搜索|分析|总结|统计|列出|显示)|(?:先|改成|改为)(?:只)?(?:查询|查看|检索|搜索|分析|总结|统计)/u.test(
      latest,
    )
  )
    return false;
  // 修订明确撤回某类写入后，旧指令不能继续授予该类动作权限。
  if (
    new RegExp(
      `(?:不要|别|不用|无需|不必|不需要|不想|不)(?:再|帮我)?(?:${verbs[kind]})`,
      'u',
    ).test(request)
  )
    return false;
  if (!new RegExp(verbs[kind], 'u').test(command)) return false;
  // 取消自动续费是更新，不能因“取消”推导为删除。
  const modules = Object.entries(moduleWords)
    .filter(([, pattern]) => pattern.test(command))
    .map(([key]) => key);
  return !module || !modules.length || modules.includes(module);
}
