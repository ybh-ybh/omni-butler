import { randomInt, randomUUID } from 'node:crypto';
import { getServers, Resolver } from 'node:dns/promises';
import { request } from 'node:https';
import { isIP } from 'node:net';
import * as packet from 'dns-packet';
import { isPublicAiAddress } from './ai-address';
import { readAiNetworkConfig } from './ai-network-config';
import type { AiDohResolver, AiNetworkConfig } from './ai-network-config';
import { AiNetworkError } from './ai-network-types';
import type { AiNetworkObserver } from './ai-network-types';

/// Carries a validated address that the model connection can pin directly.
export interface AiDnsAddress {
  /// Contains the textual address without a hostname lookup.
  address: string;
  /// Identifies the Node socket address family.
  family: number;
}

/// Shares deployment policy and deadlines with the model transport.
export interface AiDnsOptions {
  /// Allows deterministic policy injection for diagnostics and tests.
  config?: AiNetworkConfig;
  /// Caps all attempts at the caller's absolute deadline.
  deadlineAt?: number;
  /// Correlates DNS and later connection diagnostics.
  traceId?: string;
  /// Receives only locally controlled network metadata.
  observe?: AiNetworkObserver;
}

/// Bounds individual DNS wire responses and prevents unbounded buffering.
const MAX_RESPONSE_BYTES = 65536;

/// Compares DNS names independent of case and a trailing root label.
function dnsName(value: string): string { return value.toLowerCase().replace(/\.$/, ''); }

/// Removes raw network text while preserving retry and cancellation facts.
function dnsFailure(error: unknown, signal?: AbortSignal): AiNetworkError {
  if (signal?.aborted) {
    // Explicit cancellation terminates every path without granting retry rights.
    if (!(signal.reason instanceof AiNetworkError) || signal.reason.code === 'AI_CANCELLED') return new AiNetworkError('AI_CANCELLED', 'dns', 'CANCELLED');
    // A deadline cannot turn an already confirmed safety refusal into a retry.
    if (error instanceof AiNetworkError && !error.retryable) return error;
    return signal.reason;
  }
  if (error instanceof AiNetworkError) return error;
  // Only recognized error codes are eligible for diagnostic output.
  const code = error && typeof error === 'object' && 'code' in error ? error.code : undefined;
  if (code === 'ENOTFOUND' || code === 'ENONAME') return new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_NOT_FOUND');
  if (typeof code === 'string' && ['ETIMEOUT', 'ETIMEDOUT', 'ESERVFAIL', 'ECONNREFUSED', 'ECONNRESET', 'ENETUNREACH', 'EHOSTUNREACH', 'EAI_AGAIN', 'EPIPE'].includes(code)) {
    return new AiNetworkError('AI_DNS_FAILED', 'dns', code, true);
  }
  if (typeof code === 'string' && ['CERT_HAS_EXPIRED', 'CERT_NOT_YET_VALID', 'DEPTH_ZERO_SELF_SIGNED_CERT', 'SELF_SIGNED_CERT_IN_CHAIN', 'ERR_TLS_CERT_ALTNAME_INVALID', 'UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY'].includes(code)) {
    return new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_TLS_CERTIFICATE');
  }
  return new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_ERROR');
}

/// Validates every answer before any resolver failover or address selection.
function validateAddresses(addresses: AiDnsAddress[]): AiDnsAddress[] {
  if (addresses.some((entry) => isIP(entry.address) !== entry.family || ![4, 6].includes(entry.family))) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_INVALID_RESPONSE');
  if (addresses.some((entry) => !isPublicAiAddress(entry.address))) throw new AiNetworkError('AI_PRIVATE_URL', 'dns', 'UNSAFE_ADDRESS');
  if (!addresses.length) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_NO_ADDRESSES');
  // Deduplication retains stable IPv4-first resolver order.
  const unique = new Map<string, AiDnsAddress>();
  for (const entry of addresses) unique.set(`${entry.family}:${entry.address}`, entry);
  return [...unique.values()];
}

/// Prioritizes unsafe or malformed family answers over concurrent transient failures.
function collectAddresses(families: Promise<AiDnsAddress[]>[]): Promise<AiDnsAddress[]> {
  return new Promise((resolve, reject) => {
    // Retain each family in deterministic order without dropping partial evidence.
    const answers: AiDnsAddress[][] = new Array<AiDnsAddress[]>(families.length);
    // A temporary failure cannot trigger fallback until the other family settles.
    let temporaryFailure: AiNetworkError | undefined;
    // Every started family must complete or be closed by the attempt deadline.
    let remaining = families.length;
    for (const [index, family] of families.entries()) {
      void family.then((addresses) => { answers[index] = addresses; }, (error: unknown) => {
        // Permanent refusals take precedence over a simultaneous network error.
        const failure = dnsFailure(error);
        if (!failure.retryable) reject(failure);
        else temporaryFailure = failure;
      }).then(() => {
        remaining--;
        if (remaining !== 0) return;
        if (temporaryFailure) { reject(temporaryFailure); return; }
        try { resolve(validateAddresses(answers.flat())); } catch (error: unknown) { reject(dnsFailure(error)); }
      });
    }
  });
}

/// Queries both families through one independent, cancellable DNS resolver.
async function systemAddresses(hostname: string, server: string, signal: AbortSignal, timeoutMs: number): Promise<AiDnsAddress[]> {
  // Per-attempt ownership prevents cancellation from affecting other requests.
  const resolver = new Resolver({ timeout: timeoutMs, tries: 1 });
  resolver.setServers([server]);
  // Cancellation closes both A and AAAA operations together.
  const cancel = (): void => { resolver.cancel(); };
  signal.addEventListener('abort', cancel, { once: true });
  try {
    if (signal.aborted) throw dnsFailure(undefined, signal);
    // A valid no-data answer is distinct from a failed DNS query.
    const familyAddresses = async (family: 4 | 6): Promise<AiDnsAddress[]> => {
      try {
        // Node resolves CNAMEs and returns all addresses for the requested family.
        const values = family === 4 ? await resolver.resolve4(hostname) : await resolver.resolve6(hostname);
        return values.length ? validateAddresses(values.map((address) => ({ address, family }))) : [];
      } catch (error: unknown) {
        if (!signal.aborted && error && typeof error === 'object' && 'code' in error && error.code === 'ENODATA') return [];
        throw dnsFailure(error, signal);
      }
    };
    return await collectAddresses([familyAddresses(4), familyAddresses(6)]);
  } finally {
    signal.removeEventListener('abort', cancel);
    resolver.cancel();
  }
}

/// Verifies a complete RFC 8484 response and its CNAME address ownership.
function decodeAddresses(body: Buffer, hostname: string, type: 'A' | 'AAAA', id: number): AiDnsAddress[] {
  // A bounded standard codec handles DNS compression and wire encoding.
  let response: packet.DecodedPacket;
  try { response = packet.decode(body); } catch { throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_INVALID_RESPONSE'); }
  // Header flags expose the standard opcode and response code numerically.
  const flags = response.flags ?? -1;
  if (packet.decode.bytes !== body.length || response.type !== 'response' || response.id !== id || response.flag_tc || ((flags >> 11) & 15) !== 0 ||
      response.questions?.length !== 1 || dnsName(response.questions[0]!.name) !== dnsName(hostname) || response.questions[0]!.type !== type || response.questions[0]!.class !== 'IN') {
    throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_INVALID_RESPONSE');
  }
  if ((flags & 15) === 2) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_SERVFAIL', true);
  if ((flags & 15) === 3) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_NOT_FOUND');
  if ((flags & 15) !== 0) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_REJECTED');
  // Conflicting CNAME ownership and cycles cannot produce usable addresses.
  const aliases = new Map<string, string>();
  for (const answer of response.answers ?? []) {
    if (answer.type === 'OPT' || answer.class !== 'IN') throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_INVALID_RESPONSE');
    if (answer.type !== 'CNAME') continue;
    // Codec output is still validated before becoming a trusted chain.
    const owner = dnsName(answer.name);
    // Each alias has exactly one nonempty target.
    const target = dnsName(answer.data);
    if (!target || (aliases.has(owner) && aliases.get(owner) !== target)) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_INVALID_RESPONSE');
    aliases.set(owner, target);
  }
  // Cap traversal independently of the response byte limit.
  const names = new Set<string>();
  // Start traversal at the exact requested name.
  let name = dnsName(hostname);
  while (true) {
    if (names.has(name) || names.size >= 16) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_INVALID_RESPONSE');
    names.add(name);
    // Advance through an explicitly returned alias only.
    const next = aliases.get(name);
    if (!next) break;
    name = next;
  }
  // Return no-data as an empty family, not an overall failed resolution.
  const addresses: AiDnsAddress[] = [];
  for (const answer of response.answers ?? []) {
    if (answer.type !== 'A' && answer.type !== 'AAAA') continue;
    // Address records must belong to the requested family and alias chain.
    const family = answer.type === 'A' ? 4 : 6;
    if (answer.type !== type || !names.has(dnsName(answer.name)) || isIP(answer.data) !== family) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_INVALID_RESPONSE');
    addresses.push({ address: answer.data, family });
  }
  return addresses.length ? validateAddresses(addresses) : [];
}

/// Sends one credential-free DNS query over a pinned, verified HTTPS connection.
function dohAddresses(hostname: string, type: 'A' | 'AAAA', resolver: AiDohResolver, bootstrap: string, signal: AbortSignal): Promise<AiDnsAddress[]> {
  // Match the response to this query even across concurrent address families.
  const id = randomInt(65536);
  // Only the model hostname is disclosed to the configured resolver.
  const body = packet.encode({ id, type: 'query', flags: packet.RECURSION_DESIRED, questions: [{ name: hostname, type, class: 'IN' }] });
  return new Promise((resolve, reject) => {
    // Each request owns its socket; no global agent may resolve or reuse another IP.
    const outgoing = request(new URL(resolver.url), {
      method: 'POST', agent: false, signal, family: isIP(bootstrap),
      headers: { accept: 'application/dns-message', 'content-type': 'application/dns-message', 'content-length': body.length },
      lookup: (_name, options, callback) => options.all ? callback(null, [{ address: bootstrap, family: isIP(bootstrap) }]) : callback(null, bootstrap, isIP(bootstrap)),
    }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        outgoing.destroy(new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_HTTP_STATUS', response.statusCode === 429 || (response.statusCode ?? 0) >= 500));
        return;
      }
      if (response.headers['content-type']?.split(';')[0]?.trim().toLowerCase() !== 'application/dns-message' ||
          (response.headers['content-encoding'] && response.headers['content-encoding'] !== 'identity')) {
        response.resume();
        outgoing.destroy(new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_INVALID_RESPONSE'));
        return;
      }
      // Every response is bounded independently of Content-Length.
      let size = 0;
      // Raw wire data stays within the per-response limit.
      const chunks: Buffer[] = [];
      response.on('data', (chunk: Buffer) => {
        size += chunk.length;
        if (size > MAX_RESPONSE_BYTES) outgoing.destroy(new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_RESPONSE_TOO_LARGE'));
        else chunks.push(chunk);
      });
      response.once('aborted', () => reject(new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_RESPONSE_ABORTED', true)));
      response.once('error', (error: unknown) => reject(dnsFailure(error, signal)));
      response.once('end', () => {
        try { resolve(decodeAddresses(Buffer.concat(chunks), hostname, type, id)); }
        catch (error: unknown) { reject(dnsFailure(error, signal)); }
      });
    });
    outgoing.once('error', (error: unknown) => reject(dnsFailure(error, signal)));
    outgoing.end(body);
  });
}

/// Applies a deadline and cancellation even if a resolver ignores its signal.
async function attemptAddresses(operation: (signal: AbortSignal) => Promise<AiDnsAddress[]>, timeoutMs: number, signal?: AbortSignal): Promise<AiDnsAddress[]> {
  // All operations belonging to this attempt share cleanup ownership.
  const controller = new AbortController();
  // Caller cancellation must never start a new resolver attempt.
  const cancel = (): void => { controller.abort(new AiNetworkError('AI_CANCELLED', 'dns', 'CANCELLED')); };
  signal?.addEventListener('abort', cancel, { once: true });
  if (signal?.aborted) cancel();
  // A timed-out attempt may use an explicit backup within the remaining budget.
  const timer = setTimeout(() => controller.abort(new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_TIMEOUT', true)), timeoutMs);
  // Promise rejection enforces the budget even for misbehaving test doubles.
  let abortHandler: (() => void) | undefined;
  try {
    if (controller.signal.aborted) throw dnsFailure(undefined, controller.signal);
    return await Promise.race([
      operation(controller.signal),
      new Promise<never>((_resolve, reject) => {
        abortHandler = (): void => { reject(dnsFailure(undefined, controller.signal)); };
        controller.signal.addEventListener('abort', abortHandler, { once: true });
        if (controller.signal.aborted) abortHandler();
      }),
    ]);
  } catch (error: unknown) {
    throw dnsFailure(error, controller.signal);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', cancel);
    if (abortHandler) controller.signal.removeEventListener('abort', abortHandler);
    controller.abort();
  }
}

/// Resolves all model addresses under explicit deployment policy and a shared deadline.
export async function resolveAiAddresses(hostname: string, signal?: AbortSignal, options: AiDnsOptions = {}): Promise<AiDnsAddress[]> {
  if (signal?.aborted) throw new AiNetworkError('AI_CANCELLED', 'dns', 'CANCELLED');
  // Literal model targets still pass the same public-address boundary.
  const family = isIP(hostname);
  if (family) return validateAddresses([{ address: hostname, family }]);
  if (!hostname || hostname.length > 253 || !/^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.?$/.test(hostname)) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_INVALID_NAME');
  // Environment configuration is server-owned and validated before network access.
  const config = options.config ?? readAiNetworkConfig();
  // A caller deadline can only shorten the configured stage budget.
  const deadlineAt = Math.min(options.deadlineAt ?? Infinity, Date.now() + config.dnsTimeoutMs);
  // A fresh identity is used when resolution runs without the model transport.
  const traceId = options.traceId ?? randomUUID();
  // Each attempt includes both address families from the same resolver.
  const attempts: { id: string; run: (signal: AbortSignal, timeoutMs: number) => Promise<AiDnsAddress[]> }[] = config.mode === 'system'
    ? (config.systemServers.length ? config.systemServers : getServers()).map((server) => ({ id: `system:${server}`, run: (attemptSignal: AbortSignal, timeoutMs: number): Promise<AiDnsAddress[]> => systemAddresses(hostname, server, attemptSignal, timeoutMs) }))
    : config.dohResolvers.flatMap((resolver) => resolver.bootstrapAddresses.map((bootstrap) => ({ id: `${resolver.id}:${bootstrap}`, run: (attemptSignal: AbortSignal): Promise<AiDnsAddress[]> => collectAddresses([dohAddresses(hostname, 'A', resolver, bootstrap, attemptSignal), dohAddresses(hostname, 'AAAA', resolver, bootstrap, attemptSignal)]) })));
  // An empty resolver list is a deployment error with no hidden public fallback.
  let lastFailure = new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_NO_RESOLVERS');
  for (const attempt of attempts) {
    if (signal?.aborted) throw new AiNetworkError('AI_CANCELLED', 'dns', 'CANCELLED');
    // Each attempt consumes the shared stage and caller budgets.
    const remainingMs = Math.floor(deadlineAt - Date.now());
    if (remainingMs < 1) { lastFailure = new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_TIMEOUT', true); break; }
    // Report elapsed time for this actual resolver attempt only.
    const startedAt = Date.now();
    try {
      // The operation may not reset its own deadline when changing families.
      const addresses = await attemptAddresses((attemptSignal) => attempt.run(attemptSignal, Math.min(config.dnsAttemptTimeoutMs, remainingMs)), Math.min(config.dnsAttemptTimeoutMs, remainingMs), signal);
      options.observe?.({ traceId, stage: 'dns', outcome: 'success', elapsedMs: Date.now() - startedAt, resolver: attempt.id, submitted: false });
      return addresses;
    } catch (error: unknown) {
      lastFailure = dnsFailure(error, signal);
      lastFailure.traceId = traceId;
      options.observe?.({ traceId, stage: 'dns', outcome: lastFailure.code === 'AI_CANCELLED' ? 'cancelled' : 'failure', elapsedMs: Date.now() - startedAt, reason: lastFailure.reason, resolver: attempt.id, submitted: false });
      if (!lastFailure.retryable) throw lastFailure;
    }
  }
  lastFailure.traceId = traceId;
  throw lastFailure;
}
