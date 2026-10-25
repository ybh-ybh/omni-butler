import { request } from 'node:https';
import { isIP } from 'node:net';

/// 已解析的单个地址，连接时继续固定到这个地址。
export interface AiDnsAddress {
  /// 解析得到的 IP 文本。
  address: string;
  /// Node HTTPS 使用的地址族。
  family: number;
}

/// Cloudflare 官方 DoH 端点；固定引导 IP 避免解析器域名也被 Fake-IP 接管。
const DOH_ENDPOINT = 'https://cloudflare-dns.com/dns-query';
/// 官方解析器的公网 IPv4，TLS 仍按端点域名验证证书。
const DOH_BOOTSTRAP_IP = '1.1.1.1';
/// 智谱国内官方域名用国内解析器，避免海外调度节点在当前网络握手失败。
const ZHIPU_DOH_ENDPOINT = 'https://dns.alidns.com/resolve';
/// 国内解析器同样固定官方引导 IP，保留域名的 TLS 证书验证。
const ZHIPU_DOH_BOOTSTRAP_IP = '223.5.5.5';
/// A 与 AAAA 查询共用的总时限。
const DNS_TIMEOUT_MS = 5000;
/// DNS 响应只允许有限大小，防止无界缓冲。
const MAX_RESPONSE_BYTES = 65536;

/// 将 DNS JSON 名称统一为无末尾根点的小写文本。
function dnsName(value: string): string {
  return value.toLowerCase().replace(/\.$/, '');
}

/// 校验问题、别名链和地址族，不接受截断、无关或损坏的应答。
function parseAddresses(body: string, hostname: string, type: number): AiDnsAddress[] {
  // 外部 JSON 仅在逐字段检查后使用。
  const result = JSON.parse(body) as {
    Status?: unknown;
    TC?: unknown;
    Question?: { name?: unknown; type?: unknown }[] | { name?: unknown; type?: unknown };
    Answer?: { name?: unknown; type?: unknown; data?: unknown }[];
  } | null;
  // Cloudflare 返回问题数组，AliDNS 返回单对象；两者均须恰有一个匹配问题。
  const questions = Array.isArray(result?.Question) ? result.Question : result?.Question ? [result.Question] : [];
  if (!result || result.Status !== 0 || result.TC !== false ||
      questions.length !== 1 ||
      typeof questions[0]?.name !== 'string' ||
      dnsName(questions[0].name) !== dnsName(hostname) ||
      questions[0].type !== type ||
      (result.Answer !== undefined && !Array.isArray(result.Answer))) {
    throw new Error('AI_DNS_FAILED');
  }
  // 只采用查询名称及其 CNAME 链所属的地址。
  const answers = result.Answer ?? [];
  // 同一名称不能返回互相冲突的别名。
  const aliases = new Map<string, string>();
  for (const answer of answers) {
    if (!answer || typeof answer.name !== 'string' || typeof answer.type !== 'number' || typeof answer.data !== 'string') throw new Error('AI_DNS_FAILED');
    if (answer.type === 5) {
      // 规范化当前别名的拥有者。
      const owner = dnsName(answer.name);
      // CNAME 目标同样不允许为空。
      const target = dnsName(answer.data);
      if (!target || (aliases.has(owner) && aliases.get(owner) !== target)) throw new Error('AI_DNS_FAILED');
      aliases.set(owner, target);
    }
  }
  // 限制别名深度并拒绝循环，避免异常应答阻塞解析。
  const names = new Set<string>();
  // 沿本次问题的别名链查找最终名称。
  let name = dnsName(hostname);
  while (true) {
    if (names.has(name) || names.size >= 16) throw new Error('AI_DNS_FAILED');
    names.add(name);
    // 当前名称指向的下一层别名。
    const next = aliases.get(name);
    if (!next) break;
    name = next;
  }
  // 保留全部相关地址，交由调用方统一拒绝任何内网或保留网段。
  const addresses: AiDnsAddress[] = [];
  for (const answer of answers) {
    if (answer.type !== 1 && answer.type !== 28) continue;
    // 上述检查保证所有地址拥有者与数据均为字符串。
    const address = answer.data as string;
    // DNS 类型必须与文本地址族一致。
    const family = answer.type === 1 ? 4 : 6;
    if (answer.type !== type || !names.has(dnsName(answer.name as string)) || isIP(address) !== family) throw new Error('AI_DNS_FAILED');
    addresses.push({ address, family });
  }
  return addresses;
}

/// 单次只读 DoH 查询不携带模型凭据、路径或正文，也不跟随重定向。
function queryAddresses(hostname: string, type: number, signal: AbortSignal): Promise<AiDnsAddress[]> {
  // 仅匹配智谱官方域名，不按供应商名称信任用户填写的任意域名。
  const zhipu = dnsName(hostname) === 'open.bigmodel.cn';
  // DNS 查询参数由 URL API 编码，不能注入其他查询。
  const url = new URL(zhipu ? ZHIPU_DOH_ENDPOINT : DOH_ENDPOINT);
  // 解析器引导地址由服务端固定，不接受外部输入。
  const bootstrapIp = zhipu ? ZHIPU_DOH_BOOTSTRAP_IP : DOH_BOOTSTRAP_IP;
  url.searchParams.set('name', hostname);
  url.searchParams.set('type', String(type));
  return new Promise((resolve, reject) => {
    // 禁止复用全局连接池，保证引导地址、SNI 与证书校验一致。
    const outgoing = request(url, {
      method: 'GET',
      headers: { accept: 'application/dns-json' },
      agent: false,
      signal,
      family: 4,
      lookup: (_name, options, callback) => options.all
        ? callback(null, [{ address: bootstrapIp, family: 4 }])
        : callback(null, bootstrapIp, 4),
    }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        outgoing.destroy(new Error('AI_DNS_FAILED'));
        return;
      }
      // 累计响应字节数，持续滴流仍受共享总时限限制。
      let size = 0;
      // 应答仅在有界内存中保留。
      const chunks: Buffer[] = [];
      response.on('data', (chunk: Buffer) => {
        size += chunk.length;
        if (size > MAX_RESPONSE_BYTES) outgoing.destroy(new Error('AI_DNS_FAILED'));
        else chunks.push(chunk);
      });
      response.once('aborted', () => reject(new Error('AI_DNS_FAILED')));
      response.once('error', () => reject(new Error('AI_DNS_FAILED')));
      response.once('end', () => {
        try { resolve(parseAddresses(Buffer.concat(chunks).toString('utf8'), hostname, type)); }
        catch { reject(new Error('AI_DNS_FAILED')); }
      });
    });
    outgoing.once('error', () => reject(new Error('AI_DNS_FAILED')));
    outgoing.end();
  });
}

/// AI 域名独立使用 DoH，地址字面量原样交给既有公网校验，不回退系统 DNS。
export async function resolveAiAddresses(hostname: string, signal?: AbortSignal): Promise<AiDnsAddress[]> {
  // 已明确的 IP 无需向第三方解析器发送查询。
  const family = isIP(hostname);
  if (family) return [{ address: hostname, family }];
  // 两种地址查询共享取消和失败清理，任何不完整结果都不能放行模型请求。
  const controller = new AbortController();
  // 总时限涵盖 TLS 握手、响应头和响应体。
  const deadline = setTimeout(() => controller.abort(), DNS_TIMEOUT_MS);
  // 上层撤回同样中止解析阶段，避免等到模型请求才响应。
  const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
  try {
    // A 排在前面，优先沿用 Docker 环境可用的 IPv4 连接。
    const answers = await Promise.all([queryAddresses(hostname, 1, combined), queryAddresses(hostname, 28, combined)]);
    // 任一地址族成功为空合法，但两个地址族都为空属于解析失败。
    const addresses = answers.flat();
    if (!addresses.length) throw new Error('AI_DNS_FAILED');
    return addresses;
  } finally {
    clearTimeout(deadline);
    controller.abort();
  }
}
