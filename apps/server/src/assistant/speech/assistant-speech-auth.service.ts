import { Injectable, UnauthorizedException } from '@nestjs/common';
import type { IncomingMessage, ServerResponse } from 'node:http';
import * as passport from 'passport';
import type { Request } from 'express';
import type { AuthUser } from '../../auth/auth.types';

/// upgrade 不经过 HTTP 守卫，显式复用同一 Passport JWT 策略。
@Injectable()
export class AssistantSpeechAuth {
  /// 同时校验 JWT 签名、用途、过期时间及真实设备会话。
  authenticate(request: IncomingMessage): Promise<AuthUser> {
    return new Promise<AuthUser>((resolve, reject) => {
      // 自定义回调避免 Passport 向尚未升级的 socket 写 HTTP 响应。
      const middleware: (input: Request, response: ServerResponse, next: () => void) => void = passport.authenticate('jwt', { session: false }, (error: unknown, actor: AuthUser | false | null): void => {
        if (error || !actor) reject(new UnauthorizedException('设备会话已失效'));
        else resolve(actor);
      });
      middleware(request as Request, {} as ServerResponse, (): void => {
        reject(new UnauthorizedException('设备会话已失效'));
      });
    });
  }
}
