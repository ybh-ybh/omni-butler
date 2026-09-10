import { createParamDecorator, ExecutionContext } from '@nestjs/common';
import type { Request } from 'express';
import type { AuthUser } from './auth.types';

/// 从通过 JWT 守卫的请求中读取内部数据所有者。
export const CurrentUser = createParamDecorator(
  (_data: unknown, context: ExecutionContext): AuthUser => {
    // 当前 HTTP 请求。
    const request = context.switchToHttp().getRequest<Request>();
    return request.user as AuthUser;
  },
);
