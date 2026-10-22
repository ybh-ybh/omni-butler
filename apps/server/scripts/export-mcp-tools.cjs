// 文件与路径接口用于生成可重复校验的工具文档。
const fs = require('node:fs');
// 基于脚本位置定位仓库，允许从任意工作目录运行。
const path = require('node:path');
// 服务端依赖与源码根目录。
const serverRoot = path.resolve(__dirname, '..');
require('reflect-metadata');
require('ts-node').register({
  transpileOnly: true,
  project: path.join(serverRoot, 'tsconfig.json'),
});
// Zod转换器保留实际参数约束。
const { z } = require('zod');
// 与MCP注册共用工具说明和请求身份定义。
const { McpCatalog, mcpModules, mcpRequestId, mcpDirectDescription } = require(
  path.join(serverRoot, 'src/mcp/mcp-catalog.ts'),
);
// 只读取目录元数据，不创建应用、连接数据库或调用业务方法。
const catalog = new McpCatalog({}, {}, {}, {}, {}, {}, {}, {});
// 完整权限只用于列出所有可能的工具，不授予真实连接权限。
const tools = [
  ...catalog.controls([...mcpModules], [...mcpModules]),
  ...catalog.visible([...mcpModules], [...mcpModules]).map((tool) => ({
    name: tool.name,
    description: tool.write ? mcpDirectDescription(tool) : tool.description,
    schema: tool.write
      ? tool.schema.extend({ requestId: mcpRequestId })
      : tool.schema,
  })),
];

// 真实字段必须有文字说明；类型分支不伪装成额外业务参数。
function verifyDescriptions(schema, fieldPath) {
  // 逐个检查普通及嵌套对象字段。
  for (const [name, property] of Object.entries(schema.properties || {})) {
    if (!property.description?.trim()) {
      throw new Error(`参数缺少描述：${fieldPath}.${name}`);
    }
    verifyDescriptions(property, `${fieldPath}.${name}`);
  }
  if (schema.items) verifyDescriptions(schema.items, `${fieldPath}[]`);
  // 批量工具包含每个写工具的参数分支，不能遗漏。
  for (const key of ['anyOf', 'oneOf', 'allOf', 'prefixItems']) {
    (schema[key] || []).forEach((branch, index) =>
      verifyDescriptions(branch, `${fieldPath}.${key}[${index}]`),
    );
  }
}

// 保留用户要求的三个顶层字段，参数同时携带真实类型与必填约束。
const documented = tools.map((tool) => {
  // 内联Schema可独立查看，不依赖外部引用。
  const schema = z.toJSONSchema(tool.schema, {
    target: 'draft-7',
    reused: 'inline',
  });
  verifyDescriptions(schema, tool.name);
  return {
    name: tool.name,
    description: tool.description,
    parameters: Object.entries(schema.properties || {}).map(
      ([name, field]) => ({
        name,
        description: field.description,
        required: (schema.required || []).includes(name),
        schema: field,
      }),
    ),
  };
});
// 用户指定的工具文档路径。
const target = path.resolve(serverRoot, '../../spec/mcp-tools.json');
// 稳定格式支持CI检查和提交差异审阅。
const content = `${JSON.stringify(documented, null, 2)}\n`;
if (process.argv.includes('--check')) {
  if (!fs.existsSync(target) || fs.readFileSync(target, 'utf8') !== content) {
    throw new Error('MCP工具文档已过期，请运行 npm run export:mcp-tools');
  }
} else {
  fs.writeFileSync(target, content, 'utf8');
}
console.log(
  `MCP文档${process.argv.includes('--check') ? '校验' : '导出'}完成：${documented.length}个工具，${target}`,
);
