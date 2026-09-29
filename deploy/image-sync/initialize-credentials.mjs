import { randomBytes } from 'node:crypto';
import { chmodSync, chownSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';

// 凭证卷只允许 API 与 MinIO 的非 root 用户读取。
const directory = '/credentials';
// JSON 是唯一持久凭证来源，两个文本文件可随时从中恢复。
const filename = `${directory}/credentials.json`;
mkdirSync(directory, { recursive: true, mode: 0o700 });
// 首次生成高熵随机凭证，重启不得更换已有对象存储身份。
const credentials = existsSync(filename)
  ? JSON.parse(readFileSync(filename, 'utf8'))
  : { accessKeyId: randomBytes(20).toString('hex'), secretAccessKey: randomBytes(32).toString('hex') };
if (!/^[a-f0-9]{40}$/.test(credentials.accessKeyId) || !/^[a-f0-9]{64}$/.test(credentials.secretAccessKey)) {
  throw new Error('图片存储凭证损坏，请恢复凭证卷备份；不会自动更换密钥。');
}
// 原子替换文件，使初始化中断后可以安全继续。
function persist(name, content) {
  // 临时文件位于同一卷，rename 保证单文件原子可见。
  const temporary = `${name}.tmp`;
  writeFileSync(temporary, content, { mode: 0o600 });
  chmodSync(temporary, 0o600);
  chownSync(temporary, 1000, 1000);
  renameSync(temporary, name);
}
if (!existsSync(filename)) persist(filename, JSON.stringify(credentials));
persist(`${directory}/access-key`, credentials.accessKeyId);
persist(`${directory}/secret-key`, credentials.secretAccessKey);
chmodSync(filename, 0o600);
chownSync(filename, 1000, 1000);
chmodSync(directory, 0o700);
chownSync(directory, 1000, 1000);
