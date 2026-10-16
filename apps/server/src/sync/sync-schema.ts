import { ConflictException } from '@nestjs/common';

/// 笔记标签图标参与同步，所有参与者必须保留完整 Unicode 字符串。
export const syncSchemaVersion = 7;

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
