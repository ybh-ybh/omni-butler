import {
  ExecutionContext,
  INestApplication,
  ValidationPipe,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { createHash, randomUUID } from 'node:crypto';
import type { AuthUser } from '../src/auth/auth.types';
import { JwtAuthGuard } from '../src/auth/jwt-auth.guard';
import { ImagesController } from '../src/images/images.controller';
import { ImagesService } from '../src/images/images.service';

/// 通过真实 HTTP multipart 解析器验证上传边界，避免只测服务方法漏掉拦截器行为。
describe('ImagesController multipart HTTP', () => {
  // 独立监听 loopback 随机端口的测试应用。
  let app: INestApplication;
  // 应用分配的真实请求地址。
  let baseUrl: string;
  // 固定有效的测试会话主体，鉴权逻辑由独立认证测试覆盖。
  const user: AuthUser = {
    sub: randomUUID(),
    sid: randomUUID(),
    typ: 'access',
  };
  // 可观察的领域层边界，HTTP 解析成功才允许进入。
  const upload = jest.fn().mockResolvedValue({ status: 'applied', image: {} });
  // 本次测试的业务身份。
  const businessId = randomUUID();
  // 用于验证 multipart 原始字节未变的文件内容。
  const bytes = new Uint8Array([137, 80, 78, 71]);

  beforeAll(async () => {
    // 保留真实控制器、拦截器与全局 DTO 校验，仅替换认证和领域层。
    const module = await Test.createTestingModule({
      controllers: [ImagesController],
      providers: [{ provide: ImagesService, useValue: { upload } }],
    })
      .overrideGuard(JwtAuthGuard)
      .useValue({
        canActivate(context: ExecutionContext): boolean {
          context.switchToHttp().getRequest<{ user: AuthUser }>().user = user;
          return true;
        },
      })
      .compile();
    app = module.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );
    await app.listen(0, '127.0.0.1');
    baseUrl = await app.getUrl();
  });

  beforeEach(() => {
    upload.mockClear();
  });
  afterAll(async () => {
    await app?.close();
  });

  /// 创建与客户端一致的五字段加一文件请求。
  function form(withFile = true): FormData {
    // 合法 multipart 表单。
    const data = new FormData();
    data.set('operationId', randomUUID());
    data.set('attachmentId', randomUUID());
    data.set('expectedRevision', '');
    data.set('onlyIfMissing', 'true');
    data.set('sha256', createHash('sha256').update(bytes).digest('hex'));
    if (withFile)
      data.set('file', new Blob([bytes], { type: 'image/png' }), 'image.png');
    return data;
  }

  /// 请求实际 HTTP 入口，不直接绕过 multipart 拦截器。
  async function send(body: FormData): Promise<Response> {
    return fetch(`${baseUrl}/images/inventoryImage/${businessId}`, {
      method: 'PUT',
      body,
    });
  }

  it('五字段加单文件成功进入服务，空expectedRevision保持为空串', async () => {
    // 正好符合协议数量上限的表单。
    const data = form();
    // 真实解析后的响应。
    const response = await send(data);
    expect(response.status).toBe(200);
    expect(upload).toHaveBeenCalledWith(
      user,
      'inventoryImage',
      businessId,
      expect.objectContaining({
        operationId: data.get('operationId'),
        expectedRevision: '',
        onlyIfMissing: 'true',
      }),
      Buffer.from(bytes),
    );
  });

  it('第六个字段被拒绝且不执行上传', async () => {
    // 超出协议的额外字段。
    const data = form();
    data.set('extra', 'unexpected');
    expect((await send(data)).status).toBe(400);
    expect(upload).not.toHaveBeenCalled();
  });

  it('第二个文件被拒绝且不执行上传', async () => {
    // 两个文件即使同名也不能绕过单文件限制。
    const data = form();
    data.append('file', new Blob([bytes], { type: 'image/png' }), 'second.png');
    expect((await send(data)).status).toBe(400);
    expect(upload).not.toHaveBeenCalled();
  });

  it('缺少文件时返回400', async () => {
    expect((await send(form(false))).status).toBe(400);
    expect(upload).not.toHaveBeenCalled();
  });

  it('multipart解析后继续校验DTO字段，拒绝无效操作ID', async () => {
    // 数量合法但语义无效的输入。
    const data = form();
    data.set('operationId', 'not-a-uuid');
    expect((await send(data)).status).toBe(400);
    expect(upload).not.toHaveBeenCalled();
  });
});
