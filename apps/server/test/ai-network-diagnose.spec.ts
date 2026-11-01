import { getServers } from 'node:dns';
import { Agent } from 'node:https';
import { diagnoseAiNetwork } from '../src/ai/ai-network-diagnose';
import { AiNetworkError } from '../src/ai/ai-network-types';
import { openAiConnection } from '../src/ai/ai-transport';

jest.mock('node:dns', () => ({ getServers: jest.fn() }));
jest.mock('../src/ai/ai-transport', () => ({ openAiConnection: jest.fn() }));

describe('AI network diagnostic CLI contract', () => {
  // Every connection is synthetic and cannot send real credentials or HTTP data.
  const dispose = jest.fn();
  // HTTP reporting must never be invoked by a DNS/TLS-only diagnostic.
  const reportHttp = jest.fn();
  // This unused HTTP agent has no sockets and never performs a network request.
  const agent = new Agent({ keepAlive: false });

  beforeEach(() => {
    jest.clearAllMocks();
    jest.mocked(getServers).mockReturnValue(['127.0.0.11']);
    jest.mocked(openAiConnection).mockImplementation((_url, options) => {
      options.observe?.({ traceId: 'synthetic-trace', stage: 'tls', outcome: 'success', elapsedMs: 12, address: '8.8.8.8', submitted: false });
      return Promise.resolve({ traceId: 'synthetic-trace', dispose, reportHttp, agent, address: { address: '8.8.8.8', family: 4 } });
    });
  });

  it('reports effective container DNS and closes a successful TLS-only connection', async () => {
    // A custom prefix must not appear in the diagnostic output.
    const result = await diagnoseAiNetwork(['https://model.example.test/private-prefix'], {});
    expect(result).toMatchObject({ ok: true, scope: 'dns-tls-only', configuration: { mode: 'system', systemDnsSource: 'container', systemServers: ['127.0.0.11'] } });
    expect(result.targets).toEqual([{ index: 0, ok: true, hostname: 'model.example.test', port: 443, traceId: 'synthetic-trace', events: [{ traceId: 'synthetic-trace', stage: 'tls', outcome: 'success', elapsedMs: 12, address: '8.8.8.8', submitted: false }] }]);
    expect(dispose).toHaveBeenCalledTimes(1);
    expect(reportHttp).not.toHaveBeenCalled();
    expect(JSON.stringify(result)).not.toContain('private-prefix');
    expect(jest.mocked(openAiConnection).mock.calls[0]?.[1]).toMatchObject({ config: { mode: 'system' }, deadlineAt: expect.any(Number), observe: expect.any(Function) });
  });

  it('rejects credentials, queries and private targets before opening a connection', async () => {
    // All sensitive strings are synthetic regression markers.
    const result = await diagnoseAiNetwork(['https://user:synthetic-secret@model.example.test', 'https://model.example.test/?key=synthetic-secret', 'https://127.0.0.1'], {});
    expect(result.ok).toBe(false);
    expect(result.targets.every((target) => target.code === 'AI_INVALID_URL')).toBe(true);
    expect(openAiConnection).not.toHaveBeenCalled();
    expect(JSON.stringify(result)).not.toContain('synthetic-secret');
    expect(JSON.stringify(result.targets)).not.toContain('127.0.0.1');
  });

  it('redacts malformed configuration and opens no connection', async () => {
    // A secret-like invalid value must not be included in configuration errors.
    const result = await diagnoseAiNetwork(['https://model.example.test'], { AI_DNS_MODE: 'synthetic-secret' });
    expect(result).toEqual({ version: 1, ok: false, scope: 'dns-tls-only', code: 'AI_NETWORK_CONFIG_INVALID', targets: [] });
    expect(openAiConnection).not.toHaveBeenCalled();
  });

  it('reports explicit system resolvers without changing container discovery', async () => {
    // Private infrastructure DNS is administrator-owned, unlike model targets.
    const result = await diagnoseAiNetwork(['https://model.example.test'], { AI_DNS_SERVERS: '10.0.0.2,10.0.0.3' });
    expect(result.configuration).toMatchObject({ mode: 'system', systemDnsSource: 'explicit', systemServers: ['10.0.0.2', '10.0.0.3'] });
    expect(getServers).not.toHaveBeenCalled();
  });

  it('projects only resolver identity and bootstrap IPs for DoH', async () => {
    // Resolver paths are intentionally excluded even after validation.
    const result = await diagnoseAiNetwork(['https://model.example.test'], { AI_DNS_MODE: 'doh', AI_DOH_RESOLVERS: JSON.stringify([{ id: 'test-resolver', url: 'https://resolver.example.test/private-path', bootstrapAddresses: ['8.8.8.8'] }]) });
    expect(result.configuration).toMatchObject({ mode: 'doh', dohResolvers: [{ id: 'test-resolver', hostname: 'resolver.example.test', bootstrapAddresses: ['8.8.8.8'] }] });
    expect(JSON.stringify(result)).not.toContain('private-path');
    expect(getServers).not.toHaveBeenCalled();
  });

  it('keeps safe failure facts and never exposes an arbitrary exception message', async () => {
    // The production error class carries only stable codes and diagnostic identity.
    const failure = new AiNetworkError('AI_DNS_FAILED', 'dns', 'DNS_TIMEOUT', true);
    failure.traceId = 'failed-trace';
    jest.mocked(openAiConnection).mockRejectedValueOnce(failure).mockRejectedValueOnce(new Error('synthetic-secret'));
    // Each failed target remains independently identifiable by its argument index.
    const result = await diagnoseAiNetwork(['https://first.example.test', 'https://second.example.test'], {});
    expect(result.targets).toEqual([
      { index: 0, ok: false, hostname: 'first.example.test', port: 443, code: 'AI_DNS_FAILED', traceId: 'failed-trace', events: [] },
      { index: 1, ok: false, hostname: 'second.example.test', port: 443, code: 'AI_NETWORK_DIAGNOSTIC_FAILED', events: [] },
    ]);
    expect(JSON.stringify(result)).not.toContain('synthetic-secret');
  });

  it('forwards cancellation and does not start the next target', async () => {
    // Cancellation belongs to this diagnostic invocation only.
    const controller = new AbortController();
    jest.mocked(openAiConnection).mockImplementationOnce(() => {
      controller.abort();
      return Promise.reject(new AiNetworkError('AI_CANCELLED', 'dns', 'CANCELLED'));
    });
    // The second target must remain untouched after cancellation.
    const result = await diagnoseAiNetwork(['https://first.example.test', 'https://second.example.test'], {}, controller.signal);
    expect(result.ok).toBe(false);
    expect(result.targets).toHaveLength(1);
    expect(openAiConnection).toHaveBeenCalledTimes(1);
    expect(jest.mocked(openAiConnection).mock.calls[0]?.[1].signal).toBe(controller.signal);
  });

  it.each([{ inputs: [] }, { inputs: Array.from({ length: 9 }, () => 'https://model.example.test') }, { inputs: ['x'.repeat(2049)] }])('rejects an unbounded or empty invocation %#', async ({ inputs }) => {
    expect(await diagnoseAiNetwork(inputs, {})).toMatchObject({ ok: false, code: 'AI_NETWORK_ARGUMENTS_INVALID', targets: [] });
    expect(openAiConnection).not.toHaveBeenCalled();
  });
});
