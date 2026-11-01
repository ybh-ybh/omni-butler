import { Logger } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { Agent } from 'node:https';
import { isIP } from 'node:net';
import { checkServerIdentity, connect, type TLSSocket } from 'node:tls';
import { isPublicAiAddress } from './ai-address';
import { resolveAiAddresses, type AiDnsAddress } from './ai-dns';
import { readAiNetworkConfig, type AiNetworkConfig } from './ai-network-config';
import { AiNetworkError, type AiNetworkEvent, type AiNetworkObserver } from './ai-network-types';
import { normalizeAiBaseUrl } from './ai-url';

/// Emits safe metadata only; remote errors and model input never reach this logger.
const logger = new Logger('AiNetwork');
/// Only transport failures can move to another validated address.
const transientCodes = new Set(['ETIMEDOUT', 'ECONNREFUSED', 'ECONNRESET', 'ENETUNREACH', 'EHOSTUNREACH', 'EPIPE']);

/// Carries one caller-owned deadline through resolution and every TLS attempt.
export interface AiConnectionOptions {
  /// Cancels preflight and the selected connection without starting another attempt.
  signal?: AbortSignal;
  /// Bounds all preflight work by the original model request budget.
  deadlineAt: number;
  /// Overrides process configuration for diagnostics and isolated tests.
  config?: AiNetworkConfig;
  /// Receives safe structured events instead of the normal server logger.
  observe?: AiNetworkObserver;
}

/// Owns a single verified TLS socket that can submit exactly one HTTP request.
export interface AiConnection {
  /// Supplies the existing socket without another DNS lookup or TLS handshake.
  agent: Agent;
  /// Identifies the selected, validated peer.
  address: AiDnsAddress;
  /// Correlates server diagnostics with the public failure.
  traceId: string;
  /// Closes the socket and removes cancellation listeners.
  dispose: () => void;
  /// Records HTTP completion without exposing request or response content.
  reportHttp: (outcome: AiNetworkEvent['outcome'], reason?: string, submitted?: boolean) => void;
}

/// Canonicalizes equivalent IPv6 spellings before verifying the actual peer.
function canonicalAddress(address: string): string {
  return isIP(address) === 6 ? new URL(`https://[${address}]/`).hostname : address;
}

/// Keeps instrumentation failures from changing the model request outcome.
function emitNetworkEvent(observe: AiNetworkObserver | undefined, event: AiNetworkEvent): void {
  try {
    if (observe) observe(event);
    else if (event.outcome !== 'success') logger.warn(JSON.stringify(event));
  } catch { /* Diagnostics must not change submission semantics. */ }
}

/// Opens one TLS socket without writing any HTTP headers, credentials or payload.
function connectAddress(url: URL, address: AiDnsAddress, deadlineAt: number, signal: AbortSignal | undefined, traceId: string, observe?: AiNetworkObserver): Promise<TLSSocket> {
  // Preserve certificate identity while the network destination stays pinned.
  const hostname = url.hostname.replace(/^\[|\]$/g, '');
  // Every candidate has its own bounded diagnostic duration.
  const startedAt = Date.now();
  return new Promise((resolve, reject) => {
    // No socket is created after cancellation or the absolute deadline.
    if (signal?.aborted || deadlineAt <= Date.now()) {
      reject(new AiNetworkError(signal?.aborted ? 'AI_CANCELLED' : 'AI_CONNECTION_FAILED', 'tcp', signal?.aborted ? 'CANCELLED' : 'TIMEOUT', !signal?.aborted));
      return;
    }
    // TCP completion distinguishes routing failures from TLS negotiation failures.
    let stage: 'tcp' | 'tls' = 'tcp';
    // A single settlement owns listener and socket cleanup.
    let settled = false;
    // The socket is deliberately created without an HTTP client request.
    const socket = connect({
      host: address.address, port: Number(url.port || 443),
      servername: isIP(hostname) ? undefined : hostname,
      rejectUnauthorized: true,
      checkServerIdentity: (_name, certificate) => checkServerIdentity(hostname, certificate),
      ALPNProtocols: ['http/1.1'],
    });
    // Clear every preflight resource on either success or failure.
    const cleanup = (): void => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      socket.removeListener('error', fail);
      socket.removeListener('close', closed);
    };
    // Classify only controlled error codes, never raw network error messages.
    const fail = (cause: unknown): void => {
      if (settled) return;
      settled = true;
      // Runtime error messages may contain addresses or user input and are discarded.
      const rawCode = typeof cause === 'object' && cause && 'code' in cause ? String(cause.code) : '';
      // Cancellation always wins over a simultaneous transport failure.
      const failure = signal?.aborted
        ? new AiNetworkError('AI_CANCELLED', stage, 'CANCELLED')
        : cause instanceof AiNetworkError ? cause
          : new AiNetworkError(stage === 'tls' ? 'AI_TLS_FAILED' : 'AI_CONNECTION_FAILED', stage, transientCodes.has(rawCode) ? rawCode : 'TLS_OR_CONNECTION_REJECTED', transientCodes.has(rawCode));
      cleanup();
      socket.destroy();
      emitNetworkEvent(observe, { traceId, stage: failure.stage, outcome: failure.code === 'AI_CANCELLED' ? 'cancelled' : 'failure', reason: failure.reason, elapsedMs: Date.now() - startedAt, address: address.address, submitted: false });
      reject(failure);
    };
    // Premature close cannot leave preflight pending until the caller disappears.
    const closed = (): void => fail(new AiNetworkError('AI_CONNECTION_FAILED', stage, 'CONNECTION_CLOSED', true));
    // Caller cancellation must destroy the in-flight connection immediately.
    const abort = (): void => fail(new AiNetworkError('AI_CANCELLED', stage, 'CANCELLED'));
    // The same timer includes TCP and TLS, including a peer that never finishes TLS.
    const timer = setTimeout(() => fail(new AiNetworkError('AI_CONNECTION_FAILED', stage, 'TIMEOUT', true)), Math.max(1, deadlineAt - Date.now()));
    socket.once('connect', () => { stage = 'tls'; });
    socket.once('error', fail);
    socket.once('close', closed);
    // Absorb late socket errors during the gap before the HTTP agent takes ownership.
    socket.on('error', () => {});
    socket.once('secureConnect', () => {
      if (settled) return;
      if (signal?.aborted) { abort(); return; }
      if (Date.now() >= deadlineAt) { fail(new AiNetworkError('AI_CONNECTION_FAILED', 'tls', 'TIMEOUT', true)); return; }
      // Authorization and peer checks are explicit even when Node already enforces them.
      if (!socket.authorized || checkServerIdentity(hostname, socket.getPeerCertificate())) {
        fail(new AiNetworkError('AI_TLS_FAILED', 'tls', 'CERTIFICATE_REJECTED')); return;
      }
      if (!socket.remoteAddress || canonicalAddress(socket.remoteAddress) !== canonicalAddress(address.address)) {
        fail(new AiNetworkError('AI_CONNECTION_FAILED', 'tls', 'PEER_ADDRESS_MISMATCH')); return;
      }
      settled = true;
      cleanup();
      emitNetworkEvent(observe, { traceId, stage: 'tls', outcome: 'success', elapsedMs: Date.now() - startedAt, address: address.address, submitted: false });
      resolve(socket);
    });
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
  });
}

/// Resolves and verifies every address, then selects one connection before any POST.
export async function openAiConnection(url: URL, options: AiConnectionOptions): Promise<AiConnection> {
  // Validate even callers outside the normal model adapters, including the diagnostic CLI.
  normalizeAiBaseUrl(url.toString());
  // Configuration is immutable for this complete preflight operation.
  const config = options.config ?? readAiNetworkConfig();
  // The correlation ID never incorporates user or model content.
  const traceId = randomUUID();
  // Total duration includes DNS and all candidate connections.
  const startedAt = Date.now();
  try {
    if (options.signal?.aborted) throw new AiNetworkError('AI_CANCELLED', 'dns', 'CANCELLED');
    if (options.deadlineAt <= Date.now()) throw new AiNetworkError('AI_CONNECTION_FAILED', 'dns', 'BUDGET_EXHAUSTED');
    // DNS adapters preserve complete answer validation and their own shared deadline.
    const addresses = await resolveAiAddresses(url.hostname.replace(/^\[|\]$/g, ''), options.signal, {
      config, deadlineAt: options.deadlineAt, traceId,
      observe: (event) => emitNetworkEvent(options.observe, event),
    });
    // Defense in depth also protects alternative adapters and future refactors.
    if (!addresses.length) throw new AiNetworkError('AI_DNS_FAILED', 'dns', 'NO_ADDRESSES');
    if (addresses.some((entry) => !isPublicAiAddress(entry.address) || isIP(entry.address) !== entry.family)) {
      throw new AiNetworkError('AI_PRIVATE_URL', 'dns', 'UNSAFE_ADDRESS');
    }
    // Validate the full answer before limiting the number of attempted candidates.
    const candidates = addresses.filter((entry, index) => addresses.findIndex((other) => canonicalAddress(other.address) === canonicalAddress(entry.address)) === index).slice(0, config.maxAddresses);
    // Every candidate shares the original caller budget and a bounded connection phase.
    const connectDeadline = Math.min(options.deadlineAt, Date.now() + config.connectTimeoutMs);
    // Preserve the last safe error when every permitted candidate fails.
    let lastFailure = new AiNetworkError('AI_CONNECTION_FAILED', 'tcp', 'NO_REACHABLE_ADDRESS', true);
    for (const address of candidates) {
      if (options.signal?.aborted) throw new AiNetworkError('AI_CANCELLED', 'tcp', 'CANCELLED');
      if (Date.now() >= connectDeadline) break;
      // Failed attempts never own a ClientRequest and therefore cannot submit a model call.
      let socket: TLSSocket;
      try {
        socket = await connectAddress(url, address, Math.min(connectDeadline, Date.now() + config.connectAttemptTimeoutMs), options.signal, traceId, options.observe);
      } catch (error) {
        if (!(error instanceof AiNetworkError) || !error.retryable) throw error;
        lastFailure = error;
        continue;
      }
      // Each agent is used for exactly one request and cannot borrow a global pooled socket.
      const agent = new Agent({ keepAlive: false, maxSockets: 1, maxTotalSockets: 1 });
      // Reusing the verified socket is mandatory; a second acquisition must fail closed.
      let consumed = false;
      agent.createConnection = (): TLSSocket => {
        if (consumed || socket.destroyed || options.signal?.aborted || Date.now() >= options.deadlineAt) {
          throw new AiNetworkError(options.signal?.aborted ? 'AI_CANCELLED' : 'AI_CONNECTION_FAILED', 'tls', 'CONNECTION_UNAVAILABLE');
        }
        consumed = true;
        return socket;
      };
      // Cleanup is idempotent because cancellation and provider finally blocks can race.
      const dispose = (): void => { clearTimeout(expiry); options.signal?.removeEventListener('abort', dispose); agent.destroy(); socket.destroy(); };
      // Authorization checks after preflight cannot keep this socket alive past the caller budget.
      const expiry = setTimeout(dispose, Math.max(1, options.deadlineAt - Date.now()));
      options.signal?.addEventListener('abort', dispose, { once: true });
      if (options.signal?.aborted || Date.now() >= options.deadlineAt) {
        dispose();
        throw new AiNetworkError(options.signal?.aborted ? 'AI_CANCELLED' : 'AI_CONNECTION_FAILED', 'tls', options.signal?.aborted ? 'CANCELLED' : 'BUDGET_EXHAUSTED');
      }
      return {
        agent, address, traceId, dispose,
        reportHttp: (outcome, reason, submitted = true): void => emitNetworkEvent(options.observe, { traceId, stage: 'http', outcome, reason, elapsedMs: Date.now() - startedAt, address: address.address, submitted }),
      };
    }
    throw lastFailure;
  } catch (error) {
    // Preserve structured failures, while discarding any unexpected dependency error body.
    const failure = error instanceof AiNetworkError ? error : new AiNetworkError('AI_DNS_FAILED', 'dns', 'RESOLUTION_FAILED', true);
    failure.traceId = traceId;
    emitNetworkEvent(options.observe, { traceId, stage: failure.stage, outcome: failure.code === 'AI_CANCELLED' ? 'cancelled' : 'failure', reason: failure.reason, elapsedMs: Date.now() - startedAt, submitted: false });
    throw failure;
  }
}
