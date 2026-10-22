import { ConfigService } from '@nestjs/config';
import { generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import type { McpConnection } from '../src/generated/prisma/client';
import { McpEditTokenService } from '../src/mcp/mcp-edit-token.service';
import { mcpHash } from '../src/mcp/mcp.service';

describe('MCP编辑凭据的签名与原始基线', () => {
  // 独立内存测试密钥，绝不读取用户部署配置。
  const keys = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    publicKeyEncoding: { type: 'spki', format: 'pem' },
  });
  // 同一持久配置用于模拟重启后的新服务实例。
  const config = new ConfigService({
    JWT_PRIVATE_KEY_BASE64: Buffer.from(keys.privateKey).toString('base64'),
    JWT_PUBLIC_KEY_BASE64: Buffer.from(keys.publicKey).toString('base64'),
  });
  // 测试不依赖数据库，只验证调用方无法伪造已读取事实。
  const service = new McpEditTokenService(config);
  // 最小连接作用域；凭据本身不代替连接授权检查。
  const connection = {
    id: randomUUID(),
    userId: randomUUID(),
  } as McpConnection;
  // 目标笔记身份不与连接身份混用。
  const record = randomUUID();
  // 已读取的正文及标签事实。
  const baseline = {
    kind: 'note' as const,
    revision: randomUUID(),
    tags: [randomUUID()],
  };

  afterEach(() => jest.restoreAllMocks());

  it('新服务实例可以读取同一签名，且不受后续基线对象修改影响', () => {
    // 编码时复制真实读取事实，外部数组后续变化不能回写已签名基线。
    const original = { ...baseline, tags: [...baseline.tags] };
    // 凭据在另一个进程实例仍可验签。
    const token = service.issue(connection, record, original);
    original.tags.push(randomUUID());
    expect(
      new McpEditTokenService(config).read(connection, record, token, 'note'),
    ).toEqual(baseline);
  });

  it('修改负载或签名不能伪造版本与标签', () => {
    // 原始签名只绑定服务器实际读取的内容。
    const token = service.issue(connection, record, baseline);
    // 拆开两段模拟外部调用方篡改。
    const [payload, signature] = token.split('.');
    // 攻击者可以看懂基线，但不能替换版本后继续使用签名。
    const altered = JSON.parse(
      Buffer.from(payload!, 'base64url').toString(),
    ) as { baseline: { revision: string } };
    altered.baseline.revision = randomUUID();
    expect(() =>
      service.read(
        connection,
        record,
        `${Buffer.from(JSON.stringify(altered)).toString('base64url')}.${signature}`,
        'note',
      ),
    ).toThrow('编辑凭据无效');
    expect(() =>
      service.read(
        connection,
        record,
        `${payload}.AA${signature!.slice(2)}`,
        'note',
      ),
    ).toThrow('编辑凭据无效');
  });

  it('不能跨归属、连接、对象和业务类型使用', () => {
    // 一份凭据只描述一个连接读到的一个对象。
    const token = service.issue(connection, record, baseline);
    expect(() =>
      service.read(
        { ...connection, userId: randomUUID() },
        record,
        token,
        'note',
      ),
    ).toThrow();
    expect(() =>
      service.read({ ...connection, id: randomUUID() }, record, token, 'note'),
    ).toThrow();
    expect(() =>
      service.read(connection, randomUUID(), token, 'note'),
    ).toThrow();
    expect(() =>
      service.read(connection, record, token, 'todoSteps'),
    ).toThrow();
  });

  it('到期边界拒绝旧凭据，错误不回显标签或令牌', () => {
    // 固定发行时刻验证边界，避免真实睡眠。
    const now = Date.now();
    jest.spyOn(Date, 'now').mockReturnValue(now);
    // 一天内可用，正好到期失效。
    const token = service.issue(connection, record, baseline);
    jest.spyOn(Date, 'now').mockReturnValue(now + 86400000 - 1);
    expect(service.read(connection, record, token, 'note')).toEqual(baseline);
    jest.spyOn(Date, 'now').mockReturnValue(now + 86400000);
    expect(() => service.read(connection, record, token, 'note')).toThrow(
      '编辑凭据无效或已过期',
    );
  });

  it('其他签名用途与访问JWT不能混用，密钥轮换安全失效', () => {
    // 正确内容也必须使用专门签名域。
    const token = service.issue(connection, record, baseline);
    // 缺少域分隔的签名不能代替编辑凭据。
    const payload = token.split('.')[0]!;
    // 用同一key直接签内容，模拟跨协议挪用。
    const wrongDomain = sign(
      'sha256',
      Buffer.from(payload),
      keys.privateKey,
    ).toString('base64url');
    expect(() =>
      service.read(connection, record, `${payload}.${wrongDomain}`, 'note'),
    ).toThrow();
    expect(() =>
      service.read(connection, record, `eyJhbGciOiJSUzI1NiJ9.${token}`, 'note'),
    ).toThrow();
    // 新key不认可旧key发行的凭据，避免无声降级校验。
    const next = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    expect(() =>
      new McpEditTokenService(
        new ConfigService({
          JWT_PUBLIC_KEY_BASE64: Buffer.from(next.publicKey).toString('base64'),
        }),
      ).read(connection, record, token, 'note'),
    ).toThrow();
  });

  it('步骤凭据保留超过新建上限的真实历史结构，且不加入完成状态', () => {
    // 旧客户端合并后可有超限结构；回读不能静默截断原始基线。
    const steps = Array.from({ length: 120 }, (_, index) => ({
      id: randomUUID(),
      name: index ? `步骤${index}` : null,
    }));
    // 原顺序是结构冲突判断的一部分。
    const token = service.issue(connection, record, {
      kind: 'todoSteps',
      structureHash: mcpHash(steps),
    });
    expect(service.read(connection, record, token, 'todoSteps')).toEqual({
      kind: 'todoSteps',
      structureHash: mcpHash(steps),
    });
    expect(() =>
      service.read(connection, record, 'a'.repeat(256001), 'todoSteps'),
    ).toThrow();
  });
});
