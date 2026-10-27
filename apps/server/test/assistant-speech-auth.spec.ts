import { ConfigService } from '@nestjs/config';
import { JwtService, type JwtSignOptions } from '@nestjs/jwt';
import { generateKeyPairSync } from 'node:crypto';
import type { IncomingMessage } from 'node:http';
import { JwtStrategy } from '../src/auth/jwt.strategy';
import type { PrismaService } from '../src/prisma/prisma.service';
import { AssistantSpeechAuth } from '../src/assistant/speech/assistant-speech-auth.service';

/// 使用临时测试 RSA 密钥和真实 Passport 策略，验证 upgrade 不绕过 HTTP 身份规则。
describe('AssistantSpeechAuth', () => {
  // 仅本测试进程使用的随机密钥，不读取真实部署配置。
  const keys = generateKeyPairSync('rsa', { modulusLength: 2048 });
  // 真实 JWT 签发器使用临时私钥。
  const jwt = new JwtService();
  // 固定测试设备和数据所有者。
  const actor = { sub: '11111111-1111-4111-8111-111111111111', sid: '22222222-2222-4222-8222-222222222222', typ: 'access' };
  // 数据库边界替身用于验证撤权与归属错误。
  const lookup = jest.fn();
  // 被测 upgrade 认证入口。
  const auth = new AssistantSpeechAuth();

  beforeAll((): void => {
    new JwtStrategy(new ConfigService({
      JWT_PUBLIC_KEY_BASE64: Buffer.from(keys.publicKey.export({ type: 'spki', format: 'pem' })).toString('base64'),
      JWT_ISSUER: 'speech-test',
      JWT_AUDIENCE: 'speech-client',
    }), { deviceSession: { findUnique: lookup } } as unknown as PrismaService);
  });
  beforeEach((): void => {
    lookup.mockResolvedValue({ id: actor.sid, userId: actor.sub, expiresAt: new Date(Date.now() + 60_000) });
  });

  /// 签发只在测试中有效的令牌。
  function token(payload: object = actor, options: JwtSignOptions = {}): string {
    return jwt.sign(payload, { privateKey: keys.privateKey.export({ type: 'pkcs8', format: 'pem' }), algorithm: 'RS256', issuer: 'speech-test', audience: 'speech-client', expiresIn: 60, ...options });
  }

  /// 原生 upgrade 请求只从 Authorization 头提取令牌。
  function request(value?: string): IncomingMessage {
    return { headers: value ? { authorization: `Bearer ${value}` } : {} } as IncomingMessage;
  }

  it('接受有效设备 JWT 并使用数据库中的身份', async (): Promise<void> => {
    await expect(auth.authenticate(request(token()))).resolves.toEqual(actor);
    expect(lookup).toHaveBeenCalledWith({ where: { id: actor.sid } });
  });

  it.each([{ expiresIn: -1 }, { audience: 'wrong' }, { issuer: 'wrong' }] satisfies JwtSignOptions[])('拒绝过期或错误签发范围 %j', async (options): Promise<void> => {
    await expect(auth.authenticate(request(token(actor, options)))).rejects.toThrow('设备会话已失效');
  });

  it('拒绝缺失、篡改令牌以及 PowerSync 用途令牌', async (): Promise<void> => {
    await expect(auth.authenticate(request())).rejects.toThrow();
    await expect(auth.authenticate(request(`x${token()}`))).rejects.toThrow();
    await expect(auth.authenticate(request(token({ ...actor, typ: 'powersync' })))).rejects.toThrow();
  });

  it('有效签名不能绕过设备撤销、数据库到期或不同 owner', async (): Promise<void> => {
    lookup.mockResolvedValueOnce(null);
    await expect(auth.authenticate(request(token()))).rejects.toThrow();
    lookup.mockResolvedValueOnce({ id: actor.sid, userId: actor.sub, expiresAt: new Date(0) });
    await expect(auth.authenticate(request(token()))).rejects.toThrow();
    lookup.mockResolvedValueOnce({ id: actor.sid, userId: 'other', expiresAt: new Date(Date.now() + 60_000) });
    await expect(auth.authenticate(request(token()))).rejects.toThrow();
  });
});
