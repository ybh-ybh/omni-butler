import { ConflictException } from '@nestjs/common';

/// 笔记图片子记录参与同步，所有参与者必须理解附件身份和生命周期。
export const syncSchemaVersion = 5;

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
