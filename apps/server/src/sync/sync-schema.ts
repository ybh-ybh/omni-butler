import { ConflictException } from '@nestjs/common';

/// AI 整理期间原文不得被旧客户端提前采用，所有客户端必须支持整理任务。
export const syncSchemaVersion = 11;

/// 在写入和签发下行凭证前阻止旧客户端解释新版任务。
export function requireSyncSchemaVersion(version: string | undefined): void {
  if (version !== String(syncSchemaVersion)) {
    throw new ConflictException({
      code: 'SYNC_SCHEMA_MISMATCH',
      message: '同步数据结构版本不兼容，请升级客户端和服务器后重新连接',
      syncSchemaVersion,
    });
  }
}
