import { generateKeyPairSync } from 'node:crypto';

// 生成用于 API 与 PowerSync 的 RSA 密钥对。
const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 3072,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

// 输出可直接复制进服务器环境变量的 Base64 文本。
console.log(`JWT_PRIVATE_KEY_BASE64=${Buffer.from(privateKey).toString('base64')}`);
console.log(`JWT_PUBLIC_KEY_BASE64=${Buffer.from(publicKey).toString('base64')}`);
