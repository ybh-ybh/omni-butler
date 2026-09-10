import { Injectable } from '@nestjs/common';
import { AuthGuard } from '@nestjs/passport';

/// 验证 Bearer Access Token 的守卫。
@Injectable()
export class JwtAuthGuard extends AuthGuard('jwt') {}
