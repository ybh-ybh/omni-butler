import { BadRequestException, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { z } from 'zod';
import type { McpConnection } from '../generated/prisma/client';

/// 凭据只封装真实读取基线，不包含授权、正文或任意数据库操作。
const baselineSchema = z.discriminatedUnion('kind', [
  z.strictObject({
    kind: z.literal('note'),
    revision: z.uuid(),
    tags: z.array(z.uuid()).max(10),
  }),
  z.strictObject({
    kind: z.literal('todoSteps'),
    structureHash: z.string().regex(/^[0-9a-f]{64}$/),
  }),
]);
/// 两种编辑入口只能消费对应类型的原始基线。
export type McpEditBaseline = z.infer<typeof baselineSchema>;
/// 连接与对象身份签入凭据，不能跨归属、跨连接或跨对象使用。
const payloadSchema = z.strictObject({
  version: z.literal(1),
  owner: z.uuid(),
  connection: z.uuid(),
  record: z.uuid(),
  expiresAt: z.number().int(),
  baseline: baselineSchema,
});
/// 与访问JWT隔离的签名域，不能把编辑凭据当作认证令牌。
const signatureDomain = 'omni-mcp-edit-v1:';

/// 使用持久RSA密钥签名，进程重启不丢失编辑基线，客户端无法伪造。
@Injectable()
export class McpEditTokenService {
  /// 复用认证密钥的签名能力，独立格式与域不授予任何访问权限。
  constructor(private readonly config: ConfigService) {}

  /// 将同一次详情读取返回的事实封装为有界有效期凭据。
  issue(
    connection: McpConnection,
    record: string,
    baseline: McpEditBaseline,
  ): string {
    // 一天后须重新读取；已经准备的动作独立遵循十分钟有效期。
    const payload = payloadSchema.parse({
      version: 1,
      owner: connection.userId,
      connection: connection.id,
      record,
      expiresAt: Date.now() + 86400000,
      baseline,
    });
    // 固定编码保留原始基线，不在提交时用最新数据库状态替换。
    const encoded = Buffer.from(JSON.stringify(payload)).toString('base64url');
    // 密钥只从既有服务配置读取，不返回任何密钥内容。
    const key = createPrivateKey(
      Buffer.from(
        this.config.getOrThrow<string>('JWT_PRIVATE_KEY_BASE64'),
        'base64',
      ),
    );
    // 独立签名域阻止其他用途的签名被挪用。
    const signature = sign(
      'sha256',
      Buffer.from(signatureDomain + encoded),
      key,
    );
    return `${encoded}.${signature.toString('base64url')}`;
  }

  /// 验签并核对作用域，错误时不回显基线或凭据。
  read(
    connection: McpConnection,
    record: string,
    token: string,
    kind: McpEditBaseline['kind'],
  ): McpEditBaseline {
    try {
      // 受HTTP正文上限约束，先限制字符与段数再解码。
      const parts =
        token.length <= 256000 &&
        /^([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(token);
      if (!parts) throw new Error('format');
      // 服务公钥可跨进程验证，轮换后旧凭据安全失效。
      const key = createPublicKey(
        Buffer.from(
          this.config.getOrThrow<string>('JWT_PUBLIC_KEY_BASE64'),
          'base64',
        ),
      );
      if (
        !verify(
          'sha256',
          Buffer.from(signatureDomain + parts[1]),
          key,
          Buffer.from(parts[2]!, 'base64url'),
        )
      )
        throw new Error('signature');
      // 只接受已签名的已知结构，不反序列化自由操作。
      const payload = payloadSchema.parse(
        JSON.parse(Buffer.from(parts[1]!, 'base64url').toString('utf8')),
      );
      if (
        payload.owner !== connection.userId ||
        payload.connection !== connection.id ||
        payload.record !== record ||
        payload.baseline.kind !== kind ||
        payload.expiresAt <= Date.now()
      )
        throw new Error('scope');
      return payload.baseline;
    } catch {
      throw new BadRequestException(
        '编辑凭据无效或已过期，请重新读取目标；存在冲突时须先核对变更',
      );
    }
  }
}
