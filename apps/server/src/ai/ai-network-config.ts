import { isIP } from 'node:net';
import { isPublicAiAddress } from './ai-address';

/// Describes one explicitly trusted RFC 8484 resolver.
export interface AiDohResolver {
  /// Identifies this resolver in safe diagnostics.
  id: string;
  /// Preserves the resolver hostname for TLS verification.
  url: string;
  /// Avoids resolving the resolver through an implicit network path.
  bootstrapAddresses: string[];
}

/// Defines deployment-owned DNS and pre-submission connection budgets.
export interface AiNetworkConfig {
  /// Selects one resolver protocol without implicit cross-mode fallback.
  mode: 'system' | 'doh';
  /// Uses container DNS when empty, or these explicit infrastructure IPs.
  systemServers: string[];
  /// Lists trusted DoH resolvers in failover order.
  dohResolvers: AiDohResolver[];
  /// Bounds the entire resolution stage.
  dnsTimeoutMs: number;
  /// Bounds one resolver or bootstrap attempt.
  dnsAttemptTimeoutMs: number;
  /// Bounds all model TCP and TLS connection attempts.
  connectTimeoutMs: number;
  /// Bounds an individual model connection attempt.
  connectAttemptTimeoutMs: number;
  /// Limits model address attempts without skipping validation of other answers.
  maxAddresses: number;
}

/// Reads a bounded integer without accepting coercion or revealing input.
function integerSetting(source: Record<string, unknown>, key: string, fallback: number, max: number): number {
  // Empty Compose substitutions mean the documented default.
  const value = source[key];
  if (value === undefined || value === '') return fallback;
  if ((typeof value !== 'string' || !/^[1-9]\d*$/.test(value)) && typeof value !== 'number') throw new Error(`${key} 必须为正整数`);
  // Reject overflow and fractional values before constructing timers.
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > max) throw new Error(`${key} 超出允许范围`);
  return parsed;
}

/// Parses deployment JSON without carrying untrusted object fields forward.
function dohSettings(value: unknown): AiDohResolver[] {
  if (value === undefined || value === '') return [];
  // Bound configuration input even when it originated outside process.env.
  let entries: unknown;
  if (typeof value !== 'string' || value.length > 16384) throw new Error('AI_DOH_RESOLVERS 必须为有界 JSON 数组');
  try { entries = JSON.parse(value); } catch { throw new Error('AI_DOH_RESOLVERS 必须为合法 JSON 数组'); }
  if (!Array.isArray(entries) || entries.length > 4) throw new Error('AI_DOH_RESOLVERS 最多允许四个解析器');
  // Duplicate IDs would make diagnostics ambiguous.
  const ids = new Set<string>();
  return entries.map((entry: unknown): AiDohResolver => {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) throw new Error('AI_DOH_RESOLVERS 包含非法解析器');
    // Only these three administrator-owned fields are accepted.
    const record = entry as Record<string, unknown>;
    if (Object.keys(record).some((key) => !['id', 'url', 'bootstrapAddresses'].includes(key)) ||
        typeof record.id !== 'string' || !/^[a-z][a-z0-9_-]{0,31}$/.test(record.id) || ids.has(record.id) ||
        typeof record.url !== 'string' || record.url.length > 2048 || !/^https:\/\/[^/?#\\@\s]+(?:\/[^?#\\\s]*)?$/.test(record.url)) {
      throw new Error('AI_DOH_RESOLVERS 包含非法名称或 HTTPS 地址');
    }
    // URL parsing must not introduce credentials, queries or fragments.
    let url: URL;
    try { url = new URL(record.url); } catch { throw new Error('AI_DOH_RESOLVERS 包含非法 HTTPS 地址'); }
    // IP URLs bypass Node's lookup callback and therefore the configured bootstrap.
    const hostname = url.hostname.replace(/^\[|\]$/g, '').replace(/\.$/, '');
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash ||
        isIP(hostname) || hostname === 'localhost' || hostname.endsWith('.localhost') || hostname.endsWith('.local')) {
      throw new Error('AI_DOH_RESOLVERS 必须使用无凭据的 HTTPS 域名地址，IP 仅放入 bootstrapAddresses');
    }
    if (!Array.isArray(record.bootstrapAddresses) || !record.bootstrapAddresses.length || record.bootstrapAddresses.length > 4 ||
        record.bootstrapAddresses.some((address: unknown) => typeof address !== 'string' || !isPublicAiAddress(address))) {
      throw new Error('AI_DOH_RESOLVERS 必须提供一至四个公网引导 IP');
    }
    ids.add(record.id);
    return { id: record.id, url: url.toString(), bootstrapAddresses: [...new Set(record.bootstrapAddresses as string[])] };
  });
}

/// Validates network configuration before any request or startup side effect.
export function readAiNetworkConfig(source: Record<string, unknown> = process.env): AiNetworkConfig {
  // Production follows the DNS supplied by the container or VPC by default.
  const mode = source.AI_DNS_MODE === undefined || source.AI_DNS_MODE === '' ? 'system' : source.AI_DNS_MODE;
  if (mode !== 'system' && mode !== 'doh') throw new Error('AI_DNS_MODE 必须为 system 或 doh');
  // Infrastructure resolvers may intentionally use private or loopback IPs.
  const serversValue = source.AI_DNS_SERVERS ?? '';
  if (typeof serversValue !== 'string' || serversValue.length > 1024) throw new Error('AI_DNS_SERVERS 必须为逗号分隔的 DNS IP');
  // Preserve configured order while removing duplicate IPs.
  const systemServers = serversValue ? [...new Set(serversValue.split(',').map((value) => value.trim()))] : [];
  if (systemServers.length > 4 || systemServers.some((address) => !isIP(address) || address === '0.0.0.0' || address === '::')) throw new Error('AI_DNS_SERVERS 必须为一至四个 DNS IP');
  // DoH endpoints are explicit configuration, never inferred from model names.
  const dohResolvers = dohSettings(source.AI_DOH_RESOLVERS);
  if (mode === 'doh' && (!dohResolvers.length || systemServers.length)) throw new Error('doh 模式必须配置 AI_DOH_RESOLVERS 并清空 AI_DNS_SERVERS');
  if (mode === 'system' && dohResolvers.length) throw new Error('system 模式不能配置 AI_DOH_RESOLVERS');
  // All timers have finite startup-validated limits.
  const dnsTimeoutMs = integerSetting(source, 'AI_DNS_TIMEOUT_MS', 5000, 30000);
  // A single resolver cannot receive a fresh whole-operation budget.
  const dnsAttemptTimeoutMs = integerSetting(source, 'AI_DNS_ATTEMPT_TIMEOUT_MS', 2000, 30000);
  // Model connection attempts share their own bounded stage budget.
  const connectTimeoutMs = integerSetting(source, 'AI_CONNECT_TIMEOUT_MS', 8000, 60000);
  // Individual model attempts must fit the stage deadline.
  const connectAttemptTimeoutMs = integerSetting(source, 'AI_CONNECT_ATTEMPT_TIMEOUT_MS', 2000, 60000);
  // Address validation still covers the complete answer before this limit applies.
  const maxAddresses = integerSetting(source, 'AI_CONNECT_MAX_ADDRESSES', 8, 32);
  if (dnsAttemptTimeoutMs > dnsTimeoutMs || connectAttemptTimeoutMs > connectTimeoutMs) throw new Error('AI 单次网络超时不能超过对应总超时');
  return { mode, systemServers, dohResolvers, dnsTimeoutMs, dnsAttemptTimeoutMs, connectTimeoutMs, connectAttemptTimeoutMs, maxAddresses };
}
