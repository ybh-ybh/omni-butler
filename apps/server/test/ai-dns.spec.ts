import { EventEmitter } from 'node:events';
import { getServers, Resolver } from 'node:dns/promises';
import type { ClientRequest, IncomingMessage, RequestOptions } from 'node:http';
import { request } from 'node:https';
import * as packet from 'dns-packet';
import { resolveAiAddresses } from '../src/ai/ai-dns';
import { readAiNetworkConfig } from '../src/ai/ai-network-config';
import type { AiNetworkConfig } from '../src/ai/ai-network-config';
import type { AiNetworkEvent } from '../src/ai/ai-network-types';

jest.mock('node:https', () => ({ request: jest.fn() }));
jest.mock('node:dns/promises', () => ({ getServers: jest.fn(), Resolver: jest.fn() }));

/// Uses only isolated fake resolvers and synthetic model hostnames.
const hostname = 'model.example.test';
/// Defines deterministic DoH bootstrap identities for fault injection.
const dohConfig: AiNetworkConfig = readAiNetworkConfig({ AI_DNS_MODE: 'doh', AI_DOH_RESOLVERS: JSON.stringify([
  { id: 'primary', url: 'https://dns-one.example.test/dns-query', bootstrapAddresses: ['8.8.8.8'] },
  { id: 'backup', url: 'https://dns-two.example.test/dns-query', bootstrapAddresses: ['1.1.1.1'] },
]) });

/// Builds a fresh standard DNS wire response matching the observed query.
function wireResponse(query: packet.DecodedPacket, answers?: packet.Answer[], flags = packet.RECURSION_AVAILABLE): Buffer {
  return packet.encode({ id: query.id, type: 'response', flags, questions: query.questions, answers: answers ?? (query.questions![0]!.type === 'A' ? [{ name: hostname, type: 'A', data: '8.8.4.4', ttl: 60 }] : []) });
}

describe('deployment-aware DNS resolution', () => {
  /// Tracks actual independent resolver instances and their cancellation.
  let instances: { server: string; cancel: jest.Mock }[];
  /// Supplies independent family and resolver outcomes.
  let systemAnswer: (server: string, family: number) => Promise<string[]>;
  /// Tracks the exact DNS-only HTTPS requests.
  let calls: { url: URL; options: RequestOptions; query?: packet.DecodedPacket; closed: boolean }[];
  /// Supplies bounded wire replies or injected connection failures.
  let dohAnswer: (url: URL, query: packet.DecodedPacket) => Buffer | Error | null;
  /// Allows transport-level response faults without changing DNS bodies.
  let status: number;
  /// Defaults to the RFC 8484 response media type.
  let contentType: string;

  beforeEach(() => {
    jest.clearAllMocks(); instances = []; calls = []; status = 200; contentType = 'application/dns-message';
    jest.mocked(getServers).mockReturnValue(['127.0.0.11']);
    systemAnswer = (_server, family): Promise<string[]> => Promise.resolve(family === 4 ? ['8.8.4.4'] : []);
    jest.mocked(Resolver).mockImplementation(() => {
      // Only methods exercised by the real adapter are replaced.
      const instance = { server: '', cancel: jest.fn(), setServers: (servers: string[]): void => { instance.server = servers[0]!; }, resolve4: (): Promise<string[]> => systemAnswer(instance.server, 4), resolve6: (): Promise<string[]> => systemAnswer(instance.server, 6) };
      instances.push(instance);
      return instance as unknown as Resolver;
    });
    dohAnswer = (_url, query): Buffer => wireResponse(query);
    jest.mocked(request).mockImplementation(((url: URL, options: RequestOptions, callback: (response: IncomingMessage) => void): ClientRequest => {
      // Preserve abort ownership and emit the lifecycle used by Node HTTPS.
      const call = { url, options, closed: false, query: undefined as packet.DecodedPacket | undefined };
      calls.push(call);
      // The request never opens an actual socket.
      const outgoing = new EventEmitter() as ClientRequest;
      outgoing.destroy = ((error?: Error): ClientRequest => {
        if (!call.closed) { call.closed = true; if (error) outgoing.emit('error', error); outgoing.emit('close'); }
        return outgoing;
      }) as ClientRequest['destroy'];
      // Signal listeners must not remain after request completion.
      const abort = (): void => { outgoing.destroy(new Error('synthetic abort')); };
      options.signal?.addEventListener('abort', abort, { once: true });
      outgoing.once('close', () => options.signal?.removeEventListener('abort', abort));
      outgoing.end = ((body: Buffer): ClientRequest => {
        call.query = packet.decode(body);
        // Fault fixtures are evaluated from real encoded DNS queries.
        const result = dohAnswer(url, call.query);
        if (result === null) return outgoing;
        queueMicrotask(() => {
          if (call.closed) return;
          if (result instanceof Error) { outgoing.destroy(result); return; }
          // The response models only standard Node stream events.
          const response = new EventEmitter() as IncomingMessage;
          response.statusCode = status; response.headers = { 'content-type': contentType }; response.resume = jest.fn().mockReturnValue(response);
          callback(response);
          if (!call.closed) { response.emit('data', result); if (!call.closed) response.emit('end'); outgoing.destroy(); }
        });
        return outgoing;
      }) as ClientRequest['end'];
      return outgoing;
    }) as typeof request);
  });

  afterEach(() => { jest.useRealTimers(); });

  it('defaults to container DNS, retrieves both families and avoids public DoH dependencies', async () => {
    expect(await resolveAiAddresses(hostname, undefined, { config: readAiNetworkConfig({}) })).toEqual([{ address: '8.8.4.4', family: 4 }]);
    expect(instances).toHaveLength(1); expect(instances[0]!.server).toBe('127.0.0.11'); expect(instances[0]!.cancel).toHaveBeenCalled();
    expect(request).not.toHaveBeenCalled();
  });

  it('permits valid AAAA NODATA while preserving all A addresses', async () => {
    systemAnswer = (_server, family): Promise<string[]> => family === 4 ? Promise.resolve(['8.8.4.4', '1.1.1.1']) : Promise.reject(Object.assign(new Error('no record'), { code: 'ENODATA' }));
    expect(await resolveAiAddresses(hostname)).toEqual([{ address: '8.8.4.4', family: 4 }, { address: '1.1.1.1', family: 4 }]);
  });

  it('switches complete family groups to an explicitly configured backup after a transient failure', async () => {
    systemAnswer = (server, family): Promise<string[]> => server === '10.0.0.1' ? Promise.reject(Object.assign(new Error('sensitive details'), { code: 'ESERVFAIL' })) : Promise.resolve(family === 4 ? ['1.1.1.1'] : []);
    // Safe events identify each configured infrastructure resolver.
    const events: AiNetworkEvent[] = [];
    expect(await resolveAiAddresses(hostname, undefined, { config: readAiNetworkConfig({ AI_DNS_SERVERS: '10.0.0.1,10.0.0.2' }), observe: (event): void => { events.push(event); }, traceId: 'test-trace' })).toEqual([{ address: '1.1.1.1', family: 4 }]);
    expect(instances.map((instance) => instance.server)).toEqual(['10.0.0.1', '10.0.0.2']);
    expect(events.map((event) => event.outcome)).toEqual(['failure', 'success']); expect(JSON.stringify(events)).not.toContain('sensitive details');
  });

  it.each(['127.0.0.1', '198.18.0.1', '169.254.169.254', '10.0.0.1'])('rejects mixed unsafe answers %s without using a backup', async (address) => {
    systemAnswer = (_server, family): Promise<string[]> => Promise.resolve(family === 4 ? ['8.8.8.8', address] : []);
    await expect(resolveAiAddresses(hostname, undefined, { config: readAiNetworkConfig({ AI_DNS_SERVERS: '10.0.0.1,10.0.0.2' }) })).rejects.toMatchObject({ code: 'AI_PRIVATE_URL', reason: 'UNSAFE_ADDRESS', retryable: false });
    expect(instances).toHaveLength(1); expect(request).not.toHaveBeenCalled();
  });

  it('rejects an unsafe A result even when AAAA never completes', async () => {
    systemAnswer = (_server, family): Promise<string[]> => family === 4 ? Promise.resolve(['127.0.0.1']) : new Promise(() => {});
    await expect(resolveAiAddresses(hostname)).rejects.toMatchObject({ code: 'AI_PRIVATE_URL' });
    expect(instances[0]!.cancel).toHaveBeenCalled();
  });

  it('does not let a temporary A failure hide an unsafe AAAA response', async () => {
    systemAnswer = (_server, family): Promise<string[]> => family === 4 ? Promise.reject(Object.assign(new Error('temporary'), { code: 'ESERVFAIL' })) : Promise.resolve(['::1']);
    await expect(resolveAiAddresses(hostname, undefined, { config: readAiNetworkConfig({ AI_DNS_SERVERS: '10.0.0.1,10.0.0.2' }) })).rejects.toMatchObject({ code: 'AI_PRIVATE_URL' });
    expect(instances).toHaveLength(1);
  });

  it('does not let a temporary AAAA failure hide an unsafe delayed A response', async () => {
    systemAnswer = (_server, family): Promise<string[]> => family === 6 ? Promise.reject(Object.assign(new Error('temporary'), { code: 'ESERVFAIL' })) : Promise.resolve().then(() => ['127.0.0.1']);
    await expect(resolveAiAddresses(hostname, undefined, { config: readAiNetworkConfig({ AI_DNS_SERVERS: '10.0.0.1,10.0.0.2' }) })).rejects.toMatchObject({ code: 'AI_PRIVATE_URL', retryable: false });
    expect(instances).toHaveLength(1);
  });

  it('distinguishes NXDOMAIN from NODATA and does not hide it using another resolver', async () => {
    systemAnswer = (): Promise<string[]> => Promise.reject(Object.assign(new Error('not found'), { code: 'ENOTFOUND' }));
    await expect(resolveAiAddresses(hostname, undefined, { config: readAiNetworkConfig({ AI_DNS_SERVERS: '10.0.0.1,10.0.0.2' }) })).rejects.toMatchObject({ reason: 'DNS_NOT_FOUND' });
    expect(instances).toHaveLength(1);
  });

  it('does not convert a timed-out AAAA query into empty data and respects the total deadline', async () => {
    jest.useFakeTimers();
    systemAnswer = (_server, family): Promise<string[]> => family === 4 ? Promise.resolve(['8.8.8.8']) : new Promise(() => {});
    // Both resolver attempts must fit one shared three-second budget.
    const pending = expect(resolveAiAddresses(hostname, undefined, { config: readAiNetworkConfig({ AI_DNS_SERVERS: '10.0.0.1,10.0.0.2', AI_DNS_TIMEOUT_MS: 3000 }) })).rejects.toMatchObject({ code: 'AI_DNS_FAILED', reason: 'DNS_TIMEOUT' });
    await jest.advanceTimersByTimeAsync(3000); await pending;
    expect(instances).toHaveLength(2); expect(instances.every((instance) => instance.cancel.mock.calls.length > 0)).toBe(true); expect(jest.getTimerCount()).toBe(0);
  });

  it('cancels its own resolver and does not start the backup', async () => {
    jest.useFakeTimers(); systemAnswer = (): Promise<string[]> => new Promise(() => {});
    // Caller cancellation is distinct from infrastructure failure.
    const controller = new AbortController();
    // Attach rejection observers before cancellation.
    const pending = expect(resolveAiAddresses(hostname, controller.signal, { config: readAiNetworkConfig({ AI_DNS_SERVERS: '10.0.0.1,10.0.0.2' }) })).rejects.toMatchObject({ code: 'AI_CANCELLED', retryable: false });
    controller.abort(); await pending;
    expect(instances).toHaveLength(1); expect(instances[0]!.cancel).toHaveBeenCalled(); expect(jest.getTimerCount()).toBe(0);
  });

  it('honors a shorter caller deadline without creating a fresh resolver budget', async () => {
    jest.useFakeTimers(); systemAnswer = (): Promise<string[]> => new Promise(() => {});
    // The caller has only fifty milliseconds left.
    const pending = expect(resolveAiAddresses(hostname, undefined, { deadlineAt: Date.now() + 50 })).rejects.toMatchObject({ reason: 'DNS_TIMEOUT' });
    await jest.advanceTimersByTimeAsync(50); await pending; expect(jest.getTimerCount()).toBe(0);
  });

  it('does not cancel another concurrent caller sharing the same hostname', async () => {
    // Each family can be completed independently after one caller cancels.
    const releases: (() => void)[] = [];
    systemAnswer = (_server, family): Promise<string[]> => new Promise((resolve) => { releases.push(() => resolve(family === 4 ? ['8.8.8.8'] : [])); });
    // Only the first logical resolution is cancelled.
    const controller = new AbortController();
    // Observe both calls before exercising cancellation.
    const first = expect(resolveAiAddresses(hostname, controller.signal)).rejects.toMatchObject({ code: 'AI_CANCELLED' });
    // The second call must retain its own live resolver.
    const second = resolveAiAddresses(hostname);
    controller.abort(); await first;
    expect(instances[0]!.cancel).toHaveBeenCalled(); expect(instances[1]!.cancel).not.toHaveBeenCalled();
    releases[2]!(); releases[3]!();
    await expect(second).resolves.toEqual([{ address: '8.8.8.8', family: 4 }]);
  });

  it('validates IP literals without querying any resolver', async () => {
    expect(await resolveAiAddresses('8.8.8.8')).toEqual([{ address: '8.8.8.8', family: 4 }]);
    await expect(resolveAiAddresses('127.0.0.1')).rejects.toMatchObject({ code: 'AI_PRIVATE_URL' });
    expect(Resolver).not.toHaveBeenCalled(); expect(request).not.toHaveBeenCalled();
  });

  it('uses standard DoH wire format with pinned bootstrap IP and no model credentials', async () => {
    expect(await resolveAiAddresses(hostname, undefined, { config: dohConfig })).toEqual([{ address: '8.8.4.4', family: 4 }]);
    expect(Resolver).not.toHaveBeenCalled(); expect(getServers).not.toHaveBeenCalled(); expect(calls).toHaveLength(2);
    for (const call of calls) {
      expect(call.options).toMatchObject({ method: 'POST', agent: false, headers: { accept: 'application/dns-message', 'content-type': 'application/dns-message' } });
      expect(call.options.headers).not.toHaveProperty('authorization'); expect(call.options).not.toHaveProperty('rejectUnauthorized', false);
      expect(call.query?.questions?.[0]?.name).toBe(hostname);
      // The resolver hostname is never delegated to system DNS.
      const lookup = jest.fn(); call.options.lookup!('dns-one.example.test', { all: true }, lookup);
      expect(lookup).toHaveBeenCalledWith(null, [{ address: '8.8.8.8', family: 4 }]);
    }
  });

  it('uses the same deployment resolver for all model domains', async () => {
    dohAnswer = (_url, query): Buffer => wireResponse(query, query.questions![0]!.type === 'A' ? [{ name: query.questions![0]!.name, type: 'A', data: '8.8.4.4' }] : []);
    await resolveAiAddresses('open.bigmodel.cn', undefined, { config: dohConfig });
    await resolveAiAddresses('api.deepseek.com', undefined, { config: dohConfig });
    expect(calls.every((call) => call.url.hostname === 'dns-one.example.test')).toBe(true);
  });

  it('supports valid CNAME chains and retains every related address', async () => {
    dohAnswer = (_url, query): Buffer => wireResponse(query, query.questions![0]!.type === 'A' ? [
      { name: hostname, type: 'CNAME', data: 'cdn.example.test', ttl: 20 },
      { name: 'cdn.example.test', type: 'A', data: '8.8.4.4', ttl: 30 },
      { name: 'cdn.example.test', type: 'A', data: '1.1.1.1', ttl: 30 },
    ] : []);
    expect(await resolveAiAddresses(hostname, undefined, { config: dohConfig })).toHaveLength(2);
  });

  it('uses an explicit DoH backup for temporary network failure without system fallback', async () => {
    dohAnswer = (url, query): Buffer | Error => url.hostname === 'dns-one.example.test' ? Object.assign(new Error('private connection detail'), { code: 'ECONNRESET' }) : wireResponse(query);
    expect(await resolveAiAddresses(hostname, undefined, { config: dohConfig })).toHaveLength(1);
    expect(calls.map((call) => call.url.hostname)).toEqual(['dns-one.example.test', 'dns-one.example.test', 'dns-two.example.test', 'dns-two.example.test']);
    expect(Resolver).not.toHaveBeenCalled();
  });

  it('closes a blackholed primary DoH attempt before starting the usable backup', async () => {
    jest.useFakeTimers();
    dohAnswer = (url, query): Buffer | null => url.hostname === 'dns-one.example.test' ? null : wireResponse(query);
    // Backup queries receive only the remaining total budget.
    const pending = resolveAiAddresses(hostname, undefined, { config: dohConfig });
    await jest.advanceTimersByTimeAsync(2000);
    await expect(pending).resolves.toEqual([{ address: '8.8.4.4', family: 4 }]);
    expect(calls).toHaveLength(4); expect(calls.every((call) => call.closed)).toBe(true); expect(jest.getTimerCount()).toBe(0);
  });

  it('does not conceal invalid resolver certificates by switching providers', async () => {
    dohAnswer = (): Error => Object.assign(new Error('sensitive certificate details'), { code: 'ERR_TLS_CERT_ALTNAME_INVALID' });
    await expect(resolveAiAddresses(hostname, undefined, { config: dohConfig })).rejects.toMatchObject({ reason: 'DNS_TLS_CERTIFICATE', retryable: false });
    expect(calls).toHaveLength(2); expect(getServers).not.toHaveBeenCalled();
  });

  it('prioritizes an unsafe DoH answer over a temporary failure of the other family', async () => {
    dohAnswer = (_url, query): Buffer | Error => query.questions![0]!.type === 'A'
      ? Object.assign(new Error('temporary'), { code: 'ECONNRESET' })
      : wireResponse(query, [{ name: hostname, type: 'AAAA', data: '::1' }]);
    await expect(resolveAiAddresses(hostname, undefined, { config: dohConfig })).rejects.toMatchObject({ code: 'AI_PRIVATE_URL', retryable: false });
    expect(calls).toHaveLength(2);
  });

  it.each(['malformed', 'wrong-id', 'wrong-question', 'truncated', 'unrelated-address', 'alias-loop', 'trailing-bytes', 'private-address', 'oversized'])('fails closed on %s and does not try another DoH resolver', async (scenario) => {
    dohAnswer = (_url, query): Buffer => {
      if (scenario === 'malformed') return Buffer.from([0]);
      if (scenario === 'oversized') return Buffer.alloc(65537);
      if (scenario === 'wrong-id') return wireResponse({ ...query, id: (query.id! + 1) % 65536 });
      if (scenario === 'wrong-question') return wireResponse({ ...query, questions: [{ name: 'other.example.test', type: 'A' }] });
      if (scenario === 'truncated') return wireResponse(query, [], packet.TRUNCATED_RESPONSE);
      if (scenario === 'trailing-bytes') return Buffer.concat([wireResponse(query), Buffer.from([0])]);
      if (query.questions![0]!.type !== 'A') return wireResponse(query);
      if (scenario === 'alias-loop') return wireResponse(query, [{ name: hostname, type: 'CNAME', data: hostname }]);
      return wireResponse(query, [{ name: scenario === 'unrelated-address' ? 'other.example.test' : hostname, type: 'A', data: scenario === 'private-address' ? '127.0.0.1' : '8.8.4.4' }]);
    };
    await expect(resolveAiAddresses(hostname, undefined, { config: dohConfig })).rejects.toMatchObject({ retryable: false });
    expect(calls).toHaveLength(2); expect(Resolver).not.toHaveBeenCalled();
  });

  it.each([302, 401])('does not redirect or reinterpret HTTP %s as a valid DNS response', async (httpStatus) => {
    status = httpStatus;
    await expect(resolveAiAddresses(hostname, undefined, { config: dohConfig })).rejects.toMatchObject({ reason: 'DNS_HTTP_STATUS', retryable: false });
    expect(calls).toHaveLength(2);
  });

  it('rejects JSON responses rather than assuming a provider-specific schema', async () => {
    contentType = 'application/dns-json';
    await expect(resolveAiAddresses(hostname, undefined, { config: dohConfig })).rejects.toMatchObject({ reason: 'DNS_INVALID_RESPONSE' });
  });

  it('stops both DoH family requests on cancellation and never uses a backup', async () => {
    jest.useFakeTimers(); dohAnswer = (): null => null;
    // Cancellation must remain distinct from a resolver failure.
    const controller = new AbortController();
    // Observe rejection before sending the abort signal.
    const pending = expect(resolveAiAddresses(hostname, controller.signal, { config: dohConfig })).rejects.toMatchObject({ code: 'AI_CANCELLED' });
    controller.abort(); await pending;
    expect(calls).toHaveLength(2); expect(calls.every((call) => call.closed)).toBe(true); expect(jest.getTimerCount()).toBe(0);
  });
});
