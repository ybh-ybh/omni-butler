import { ConflictException } from '@nestjs/common';

/// 笔记置顶与记录时间均为独立元数据，客户端必须保留完整同步字段。
export const syncSchemaVersion = 10;

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
