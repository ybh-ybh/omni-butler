import { ArgumentsHost, Catch, ExceptionFilter } from '@nestjs/common';
import type { Response } from 'express';
import { ZodError } from 'zod';
import { AiProviderError } from '../ai/ai-provider';

/// 对外错误固定且脱敏，不返回校验输入、密钥或供应商原始正文。
@Catch(ZodError, AiProviderError)
export class AssistantErrorFilter implements ExceptionFilter {
  /// schema错误与模型探测错误保留稳定状态码。
  catch(error: ZodError | AiProviderError, host: ArgumentsHost): void {
    // 只访问当前HTTP响应，不写入调试正文。
    const response = host.switchToHttp().getResponse<Response>();
    response
      .status(error instanceof ZodError ? 400 : 502)
      .json({
        code:
          error instanceof ZodError ? 'ASSISTANT_INPUT_INVALID' : error.code,
        message:
          error instanceof ZodError
            ? '参数格式不正确，请检查输入'
            : '助手模型能力测试未通过，请检查配置和服务状态',
      });
  }
}
