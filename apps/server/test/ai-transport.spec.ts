import { EventEmitter, getEventListeners } from 'node:events';
import { readFileSync } from 'node:fs';
import { createServer, request } from 'node:https';
import type { AddressInfo } from 'node:net';
import { join } from 'node:path';
import { connect, type ConnectionOptions, type TLSSocket } from 'node:tls';
import { isPublicAiAddress } from '../src/ai/ai-address';
import { resolveAiAddresses } from '../src/ai/ai-dns';
import { readAiNetworkConfig } from '../src/ai/ai-network-config';
import { openAiConnection, type AiConnection } from '../src/ai/ai-transport';

jest.mock('node:tls', () => ({ ...jest.requireActual<typeof import('node:tls')>('node:tls'), connect: jest.fn() }));
jest.mock('../src/ai/ai-dns', () => ({ resolveAiAddresses: jest.fn() }));
jest.mock('../src/ai/ai-address', () => ({ ...jest.requireActual<typeof import('../src/ai/ai-address')>('../src/ai/ai-address'), isPublicAiAddress: jest.fn() }));

/// Holds only synthetic connection outcomes, never real model addresses or credentials.
interface SocketPlan {
  /// Selects the observable transport outcome.
  outcome: 'success' | 'error' | 'hang';
  /// Marks whether a failure happened after TCP connected.
  connected?: boolean;
  /// Provides a controlled system error code.
  code?: string;
  /// Allows testing peer-address verification independently of DNS.
  peer?: string;
  /// Allows testing the explicit TLS authorization check.
  authorized?: boolean;
  /// Allows testing original-hostname certificate verification.
  certificateName?: string;
}

/// Uses a reserved synthetic hostname with a normal Responses path.
const modelUrl = new URL('https://model.example.test/prefix/responses');
/// Starts with the same bounded configuration used by production.
const config = readAiNetworkConfig({});
/// Retains the actual address policy so unit tests do not weaken SSRF coverage.
const realAddressPolicy = jest.requireActual<typeof import('../src/ai/ai-address')>('../src/ai/ai-address').isPublicAiAddress;

describe('AI preflight transport safety and failover', () => {
  /// Records synthetic TLS sockets for cleanup and identity assertions.
  let sockets: TLSSocket[];
  /// Supplies a distinct outcome for each connection attempt.
  let plans: SocketPlan[];
  /// Collects safe metadata without writing test failures to server logs.
  let observe: jest.Mock;

  beforeEach(() => {
    jest.clearAllMocks(); sockets = []; plans = []; observe = jest.fn();
    jest.mocked(isPublicAiAddress).mockImplementation(realAddressPolicy);
    jest.mocked(resolveAiAddresses).mockReset().mockResolvedValue([{ address: '8.8.8.8', family: 4 }]);
    jest.mocked(connect).mockReset().mockImplementation(((options: ConnectionOptions): TLSSocket => {
      // Missing plans represent a valid verified connection.
      const plan = plans.shift() ?? { outcome: 'success' };
      // The event fixture preserves close/error ordering but cannot open a socket.
      const socket = Object.assign(new EventEmitter(), {
        authorized: plan.authorized ?? true,
        remoteAddress: plan.peer ?? options.host,
        destroyed: false,
        getPeerCertificate: jest.fn(() => ({ subjectaltname: `DNS:${plan.certificateName ?? 'model.example.test'}` })),
        destroy: jest.fn((): EventEmitter => { if (!socket.destroyed) { socket.destroyed = true; socket.emit('close'); } return socket; }),
      });
      sockets.push(socket as unknown as TLSSocket);
      void Promise.resolve().then(() => {
        if (plan.connected || plan.outcome === 'success') socket.emit('connect');
        if (plan.outcome === 'error') socket.emit('error', Object.assign(new Error('synthetic-sensitive-network-detail'), { code: plan.code ?? 'ECONNREFUSED' }));
        if (plan.outcome === 'success') socket.emit('secureConnect');
      });
      return socket as unknown as TLSSocket;
    }) as typeof connect);
  });

  afterEach(() => { for (const socket of sockets) socket.destroy(); jest.useRealTimers(); });

  it('forwards one deadline and signal, pins the peer, and lends the verified socket exactly once', async () => {
    // One caller owns the entire connection lifetime.
    const controller = new AbortController();
    // The preflight and HTTP stages receive this same absolute deadline.
    const deadlineAt = Date.now() + 60000;
    // No HTTP client is created during preflight.
    const connection = await openAiConnection(modelUrl, { config, deadlineAt, signal: controller.signal, observe });
    expect(resolveAiAddresses).toHaveBeenCalledWith('model.example.test', controller.signal, expect.objectContaining({ config, deadlineAt, traceId: connection.traceId }));
    expect(connect).toHaveBeenCalledWith(expect.objectContaining({ host: '8.8.8.8', port: 443, servername: 'model.example.test', rejectUnauthorized: true, ALPNProtocols: ['http/1.1'] }));
    expect(connection.agent.createConnection({ host: 'model.example.test', port: 443 }, jest.fn())).toBe(sockets[0]);
    expect(() => connection.agent.createConnection({ host: 'model.example.test', port: 443 }, jest.fn())).toThrow('AI_CONNECTION_FAILED');
    expect(connect).toHaveBeenCalledTimes(1);
    expect(getEventListeners(controller.signal, 'abort')).toHaveLength(1);
    connection.dispose(); connection.dispose();
    expect(sockets[0]!.destroyed).toBe(true);
    expect(getEventListeners(controller.signal, 'abort')).toHaveLength(0);
  });

  it('validates the complete answer before applying the candidate limit', async () => {
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }, { address: '169.254.169.254', family: 4 }]);
    await expect(openAiConnection(modelUrl, { config: { ...config, maxAddresses: 1 }, deadlineAt: Date.now() + 60000, observe })).rejects.toMatchObject({ code: 'AI_PRIVATE_URL', reason: 'UNSAFE_ADDRESS', uncertain: false });
    expect(connect).not.toHaveBeenCalled();
  });

  it.each([{ address: '198.18.0.1', family: 4 }, { address: '8.8.8.8', family: 6 }, { address: '::ffff:127.0.0.1', family: 6 }])('rejects unsafe or inconsistent candidate $address/$family', async (address) => {
    jest.mocked(resolveAiAddresses).mockResolvedValue([address]);
    await expect(openAiConnection(modelUrl, { config, deadlineAt: Date.now() + 60000, observe })).rejects.toMatchObject({ code: 'AI_PRIVATE_URL', retryable: false });
    expect(connect).not.toHaveBeenCalled();
  });

  it.each([false, true])('retries a transient failure after TCP connected=%s before handing off HTTP', async (connected) => {
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }, { address: '1.1.1.1', family: 4 }]);
    plans = [{ outcome: 'error', connected, code: 'ECONNRESET' }, { outcome: 'success' }];
    // Only the successful candidate can reach the HTTP agent.
    const connection = await openAiConnection(modelUrl, { config, deadlineAt: Date.now() + 60000, observe });
    expect(sockets[0]!.destroyed).toBe(true);
    expect(connection.address).toEqual({ address: '1.1.1.1', family: 4 });
    expect(connection.agent.createConnection({ host: 'model.example.test', port: 443 }, jest.fn())).toBe(sockets[1]);
    expect(connect).toHaveBeenCalledTimes(2);
    expect(JSON.stringify(observe.mock.calls)).not.toContain('synthetic-sensitive-network-detail');
    connection.dispose();
  });

  it.each([
    { outcome: 'error', connected: true, code: 'ERR_TLS_CERT_ALTNAME_INVALID' },
    { outcome: 'success', authorized: false },
    { outcome: 'success', certificateName: 'wrong.example.test' },
  ] satisfies SocketPlan[])('does not fail over after a certificate rejection %#', async (plan) => {
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }, { address: '1.1.1.1', family: 4 }]);
    plans = [plan];
    await expect(openAiConnection(modelUrl, { config, deadlineAt: Date.now() + 60000, observe })).rejects.toMatchObject({ code: 'AI_TLS_FAILED', retryable: false });
    expect(connect).toHaveBeenCalledTimes(1);
    expect(sockets[0]!.destroyed).toBe(true);
  });

  it('rejects a peer that differs from the validated address', async () => {
    plans = [{ outcome: 'success', peer: '1.1.1.1' }];
    await expect(openAiConnection(modelUrl, { config, deadlineAt: Date.now() + 60000, observe })).rejects.toMatchObject({ code: 'AI_CONNECTION_FAILED', reason: 'PEER_ADDRESS_MISMATCH', retryable: false });
    expect(sockets[0]!.destroyed).toBe(true);
  });

  it('compares IPv6 peers canonically', async () => {
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '2606:4700:4700:0:0:0:0:1111', family: 6 }, { address: '2606:4700:4700::1111', family: 6 }]);
    plans = [{ outcome: 'success', peer: '2606:4700:4700::1111' }];
    // Equivalent textual addresses identify the same pinned peer.
    const connection = await openAiConnection(modelUrl, { config, deadlineAt: Date.now() + 60000, observe });
    expect(connect).toHaveBeenCalledTimes(1);
    connection.dispose();
  });

  it('does not retry equivalent IPv6 candidates after the first address fails', async () => {
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '2606:4700:4700:0:0:0:0:1111', family: 6 }, { address: '2606:4700:4700::1111', family: 6 }]);
    plans = [{ outcome: 'error', code: 'ECONNREFUSED' }];
    await expect(openAiConnection(modelUrl, { config, deadlineAt: Date.now() + 60000, observe })).rejects.toMatchObject({ code: 'AI_CONNECTION_FAILED', retryable: true });
    expect(connect).toHaveBeenCalledTimes(1);
  });

  it('does not open further connections after the configured address limit', async () => {
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }, { address: '1.1.1.1', family: 4 }]);
    plans = [{ outcome: 'error', code: 'ECONNREFUSED' }];
    await expect(openAiConnection(modelUrl, { config: { ...config, maxAddresses: 1 }, deadlineAt: Date.now() + 60000, observe })).rejects.toMatchObject({ code: 'AI_CONNECTION_FAILED', retryable: true });
    expect(connect).toHaveBeenCalledTimes(1);
  });

  it('bounds a hung first attempt and still tries the next candidate', async () => {
    jest.useFakeTimers({ now: 1000 });
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }, { address: '1.1.1.1', family: 4 }]);
    plans = [{ outcome: 'hang' }, { outcome: 'success' }];
    // A pending preflight has no HTTP request that could be duplicated.
    const pending = openAiConnection(modelUrl, { config: { ...config, connectAttemptTimeoutMs: 100 }, deadlineAt: 61000, observe });
    await jest.advanceTimersByTimeAsync(100);
    // The next candidate receives only the remaining shared budget.
    const connection = await pending;
    expect(connect).toHaveBeenCalledTimes(2);
    expect(sockets[0]!.destroyed).toBe(true);
    expect(connection.address.address).toBe('1.1.1.1');
    connection.dispose();
    expect(jest.getTimerCount()).toBe(0);
  });

  it.each([{ stageMs: 250, callerMs: 60000, attempts: 2 }, { stageMs: 8000, callerMs: 150, attempts: 1 }])('shares the stage and caller deadline %#', async ({ stageMs, callerMs, attempts }) => {
    jest.useFakeTimers({ now: 1000 });
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }, { address: '1.1.1.1', family: 4 }, { address: '8.8.4.4', family: 4 }]);
    plans = [{ outcome: 'hang' }, { outcome: 'hang' }, { outcome: 'hang' }];
    // Observe the rejection before advancing fake timers.
    const pending = expect(openAiConnection(modelUrl, { config: { ...config, connectTimeoutMs: stageMs, connectAttemptTimeoutMs: 200 }, deadlineAt: 1000 + callerMs, observe })).rejects.toMatchObject({ code: 'AI_CONNECTION_FAILED', reason: 'TIMEOUT', uncertain: false });
    await jest.advanceTimersByTimeAsync(Math.min(stageMs, callerMs));
    await pending;
    expect(connect).toHaveBeenCalledTimes(attempts);
    expect(sockets.every((socket) => socket.destroyed)).toBe(true);
    expect(jest.getTimerCount()).toBe(0);
  });

  it('cancels a hung attempt without late handoff or a fallback connection', async () => {
    jest.useFakeTimers({ now: 1000 });
    jest.mocked(resolveAiAddresses).mockResolvedValue([{ address: '8.8.8.8', family: 4 }, { address: '1.1.1.1', family: 4 }]);
    plans = [{ outcome: 'hang' }];
    // The owner can cancel even while TCP has not completed.
    const controller = new AbortController();
    // Install rejection handling before sending the abort event.
    const pending = expect(openAiConnection(modelUrl, { config, deadlineAt: 61000, signal: controller.signal, observe })).rejects.toMatchObject({ code: 'AI_CANCELLED', retryable: false });
    await jest.advanceTimersByTimeAsync(0);
    controller.abort();
    await pending;
    sockets[0]!.emit('secureConnect');
    sockets[0]!.emit('error', new Error('late synthetic error'));
    expect(connect).toHaveBeenCalledTimes(1);
    expect(sockets[0]!.destroyed).toBe(true);
    expect(getEventListeners(controller.signal, 'abort')).toHaveLength(0);
    expect(jest.getTimerCount()).toBe(0);
  });

  it('rejects pre-cancelled and expired calls before DNS or TCP', async () => {
    // An already aborted caller never gets a fresh network opportunity.
    const controller = new AbortController(); controller.abort();
    await expect(openAiConnection(modelUrl, { config, deadlineAt: Date.now() + 60000, signal: controller.signal, observe })).rejects.toMatchObject({ code: 'AI_CANCELLED' });
    await expect(openAiConnection(modelUrl, { config, deadlineAt: 0, observe })).rejects.toMatchObject({ reason: 'BUDGET_EXHAUSTED' });
    expect(resolveAiAddresses).not.toHaveBeenCalled();
    expect(connect).not.toHaveBeenCalled();
  });

  it('closes a selected socket on cancellation and prevents subsequent handoff', async () => {
    // Cancellation remains active after preflight returns to its provider.
    const controller = new AbortController();
    // The pending HTTP handoff uses the same owned connection.
    const connection = await openAiConnection(modelUrl, { config, deadlineAt: Date.now() + 60000, signal: controller.signal, observe });
    controller.abort();
    expect(sockets[0]!.destroyed).toBe(true);
    expect(() => connection.agent.createConnection({ host: 'model.example.test', port: 443 }, jest.fn())).toThrow('AI_CANCELLED');
    expect(getEventListeners(controller.signal, 'abort')).toHaveLength(0);
  });

  it('expires an unconsumed connection while its provider is still awaiting authorization', async () => {
    jest.useFakeTimers({ now: 1000 });
    // The provider can remain suspended without extending its network ownership.
    const controller = new AbortController();
    // No HTTP agent handoff occurs before the original deadline expires.
    const connection = await openAiConnection(modelUrl, { config, deadlineAt: 1100, signal: controller.signal, observe });
    expect(sockets[0]!.destroyed).toBe(false);
    expect(getEventListeners(controller.signal, 'abort')).toHaveLength(1);
    await jest.advanceTimersByTimeAsync(99);
    expect(sockets[0]!.destroyed).toBe(false);
    await jest.advanceTimersByTimeAsync(1);
    expect(sockets[0]!.destroyed).toBe(true);
    expect(getEventListeners(controller.signal, 'abort')).toHaveLength(0);
    expect(jest.getTimerCount()).toBe(0);
    expect(() => connection.agent.createConnection({ host: 'model.example.test', port: 443 }, jest.fn())).toThrow('AI_CONNECTION_FAILED');
    expect(connect).toHaveBeenCalledTimes(1);
    connection.dispose();
  });

  it('contains observer failures and reports only controlled metadata', async () => {
    observe.mockImplementation(() => { throw new Error('synthetic observer failure'); });
    // Logging must not prevent an otherwise valid connection.
    const connection = await openAiConnection(modelUrl, { config, deadlineAt: Date.now() + 60000, observe });
    expect(() => connection.reportHttp('success', 'HTTP_200')).not.toThrow();
    expect(observe).toHaveBeenLastCalledWith(expect.objectContaining({ traceId: connection.traceId, stage: 'http', outcome: 'success', submitted: true }));
    connection.dispose();
  });
});

describe('AI transport real loopback TLS handoff', () => {
  it('sends exactly one HTTPS POST on the TLS socket verified during preflight', async () => {
    // These committed fixtures are synthetic and trust only model.example.test.
    const certificate = readFileSync(join(__dirname, 'fixtures/ai-network/synthetic-only-cert.pem'));
    // This private key is a public test fixture and must never be used for deployment.
    const key = readFileSync(join(__dirname, 'fixtures/ai-network/synthetic-only-key.pem'));
    // The real TLS implementation retains certificate and hostname validation.
    const realTls = jest.requireActual<typeof import('node:tls')>('node:tls');
    // Track server connections to prove preflight and POST do not reconnect.
    const serverSockets: TLSSocket[] = [];
    // Keep the exact client socket returned by the real TLS handshake.
    const clientSockets: TLSSocket[] = [];
    // Only synthetic request data is sent to the loopback server.
    const received: { method?: string; body: string; path?: string; socket: unknown }[] = [];
    // The HTTPS server is bound only to loopback and has no model integration.
    const server = createServer({ key, cert: certificate }, (incoming, response) => {
      // Buffering is harmless for this fixed, tiny synthetic POST.
      const chunks: Buffer[] = [];
      incoming.on('data', (chunk: Buffer) => chunks.push(chunk));
      incoming.on('end', () => { received.push({ method: incoming.method, path: incoming.url, body: Buffer.concat(chunks).toString('utf8'), socket: incoming.socket }); response.end('synthetic-ok'); });
    });
    server.on('secureConnection', (socket) => serverSockets.push(socket));
    // Test scope is the only place where a loopback model target is allowed.
    jest.mocked(isPublicAiAddress).mockImplementation((address) => address === '127.0.0.1' || realAddressPolicy(address));
    jest.mocked(resolveAiAddresses).mockReset().mockResolvedValue([{ address: '127.0.0.1', family: 4 }]);
    jest.mocked(connect).mockReset().mockImplementation(((options: ConnectionOptions): TLSSocket => {
      // Inject only the synthetic CA; production SNI and peer verification remain active.
      const socket = realTls.connect({ ...options, ca: certificate });
      clientSockets.push(socket);
      return socket;
    }) as typeof connect);
    // Cleanup owns the preconnected socket even if assertions fail.
    let connection: AiConnection | undefined;
    try {
      await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
      // The port is allocated by the OS to avoid conflicts with user applications.
      const port = (server.address() as AddressInfo).port;
      // Hostname verification uses the synthetic SAN while the destination stays pinned.
      const url = new URL(`https://model.example.test:${port}/prefix/responses`);
      connection = await openAiConnection(url, { config, deadlineAt: Date.now() + 5000, observe: jest.fn() });
      expect(received).toHaveLength(0);
      expect(clientSockets).toHaveLength(1);
      expect(clientSockets[0]!.authorized).toBe(true);
      // Capture socket ownership without throwing from an asynchronous event listener.
      let usedSocket: unknown;
      // The actual HTTP parser runs over the socket previously verified by preflight.
      const body = await new Promise<string>((resolve, reject) => {
        // HTTPS must consume the supplied agent without another TLS connection.
        const outgoing = request(url, { method: 'POST', agent: connection!.agent, headers: { 'content-type': 'application/json' } }, (response) => {
          // Collect only the synthetic test response.
          const chunks: Buffer[] = [];
          response.on('data', (chunk: Buffer) => chunks.push(chunk));
          response.on('error', reject);
          response.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        });
        outgoing.on('error', reject);
        outgoing.on('socket', (socket) => { usedSocket = socket; });
        outgoing.end('{"synthetic":true}');
      });
      expect(body).toBe('synthetic-ok');
      expect(usedSocket).toBe(clientSockets[0]);
      expect(connect).toHaveBeenCalledTimes(1);
      expect(serverSockets).toHaveLength(1);
      expect(received).toEqual([{ method: 'POST', path: '/prefix/responses', body: '{"synthetic":true}', socket: serverSockets[0] }]);
      expect(() => connection!.agent.createConnection({ host: 'model.example.test', port }, jest.fn())).toThrow('AI_CONNECTION_FAILED');
    } finally {
      connection?.dispose();
      for (const socket of clientSockets) socket.destroy();
      for (const socket of serverSockets) socket.destroy();
      await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
      jest.mocked(isPublicAiAddress).mockImplementation(realAddressPolicy);
    }
  });
});
