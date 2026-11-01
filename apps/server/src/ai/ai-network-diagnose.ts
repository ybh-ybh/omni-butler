import { getServers } from 'node:dns';
import { readAiNetworkConfig } from './ai-network-config';
import type { AiNetworkConfig } from './ai-network-config';
import { AiNetworkError } from './ai-network-types';
import type { AiNetworkEvent } from './ai-network-types';
import { openAiConnection } from './ai-transport';
import { normalizeAiBaseUrl } from './ai-url';

/// Limits one explicit diagnostic invocation without adding background probes.
const MAX_TARGETS = 8;

/// Describes one no-credential DNS/TLS check, never a model generation request.
export interface AiNetworkDiagnosticTarget {
  /// Identifies the original argument without exposing invalid input text.
  index: number;
  /// Reports success only for resolution and authenticated TLS connectivity.
  ok: boolean;
  /// Exposes only a validated hostname, never its path or credentials.
  hostname?: string;
  /// Records the normalized destination port.
  port?: number;
  /// Carries the stable local failure code.
  code?: string;
  /// Links the result to bounded connection events.
  traceId?: string;
  /// Retains safe diagnostic events from the production connection component.
  events: AiNetworkEvent[];
}

/// Reports effective resolver configuration and checks without application secrets.
export interface AiNetworkDiagnosticReport {
  /// Versions the CLI JSON contract for deployment scripts.
  version: 1;
  /// Succeeds only when every requested target passes DNS and TLS validation.
  ok: boolean;
  /// Explicitly limits what a successful probe proves.
  scope: 'dns-tls-only';
  /// Contains configuration or invocation failure without the original input.
  code?: string;
  /// Shows only approved deployment network metadata.
  configuration?: {
    mode: 'system' | 'doh';
    systemDnsSource?: 'container' | 'explicit';
    systemServers?: string[];
    dohResolvers?: { id: string; hostname: string; bootstrapAddresses: string[] }[];
    dnsTimeoutMs: number;
    connectTimeoutMs: number;
  };
  /// Preserves argument order so operators can locate a failing target.
  targets: AiNetworkDiagnosticTarget[];
}

/// Projects diagnostics explicitly so future transport fields cannot leak payloads.
function copyEvent(event: AiNetworkEvent): AiNetworkEvent {
  return {
    traceId: event.traceId,
    stage: event.stage,
    outcome: event.outcome,
    elapsedMs: event.elapsedMs,
    ...(event.reason === undefined ? {} : { reason: event.reason }),
    ...(event.resolver === undefined ? {} : { resolver: event.resolver }),
    ...(event.address === undefined ? {} : { address: event.address }),
    ...(event.submitted === undefined ? {} : { submitted: event.submitted }),
  };
}

/// Reuses production DNS, address validation and TLS without sending HTTP bytes.
export async function diagnoseAiNetwork(inputs: readonly string[], source: Record<string, unknown> = process.env, signal?: AbortSignal): Promise<AiNetworkDiagnosticReport> {
  // Reject empty, excessive or oversized input before opening any connection.
  if (!inputs.length || inputs.length > MAX_TARGETS || inputs.some((value) => typeof value !== 'string' || value.length > 2048)) {
    return { version: 1, ok: false, scope: 'dns-tls-only', code: 'AI_NETWORK_ARGUMENTS_INVALID', targets: [] };
  }
  // Configuration errors must not print arbitrary environment values.
  let config: AiNetworkConfig;
  try { config = readAiNetworkConfig(source); }
  catch { return { version: 1, ok: false, scope: 'dns-tls-only', code: 'AI_NETWORK_CONFIG_INVALID', targets: [] }; }
  // Return effective resolver metadata without raw endpoint paths.
  const configuration: NonNullable<AiNetworkDiagnosticReport['configuration']> = {
    mode: config.mode,
    dnsTimeoutMs: config.dnsTimeoutMs,
    connectTimeoutMs: config.connectTimeoutMs,
    ...(config.mode === 'system'
      ? { systemDnsSource: config.systemServers.length ? 'explicit' as const : 'container' as const, systemServers: config.systemServers.length ? [...config.systemServers] : getServers() }
      : { dohResolvers: config.dohResolvers.map((resolver) => ({ id: resolver.id, hostname: new URL(resolver.url).hostname, bootstrapAddresses: [...resolver.bootstrapAddresses] })) }),
  };
  // Check targets sequentially to avoid creating an unbounded probe fan-out.
  const targets: AiNetworkDiagnosticTarget[] = [];
  for (const [index, value] of inputs.entries()) {
    // Invalid targets are identified by argument position instead of raw text.
    const target: AiNetworkDiagnosticTarget = { index, ok: false, events: [] };
    targets.push(target);
    // Validate exactly the same URL contract used by model providers.
    let url: URL;
    try { url = new URL(normalizeAiBaseUrl(value)); }
    catch { target.code = 'AI_INVALID_URL'; continue; }
    target.hostname = url.hostname;
    target.port = Number(url.port || 443);
    try {
      // Reuse the authenticated connection itself; no model request is created.
      const connection = await openAiConnection(url, {
        config,
        signal,
        deadlineAt: Date.now() + config.dnsTimeoutMs + config.connectTimeoutMs,
        observe: (event) => { target.events.push(copyEvent(event)); },
      });
      try {
        target.ok = true;
        target.traceId = connection.traceId;
      } finally { connection.dispose(); }
    } catch (error: unknown) {
      if (error instanceof AiNetworkError) {
        target.code = error.code;
        if (error.traceId) target.traceId = error.traceId;
      } else target.code = 'AI_NETWORK_DIAGNOSTIC_FAILED';
    }
    if (signal?.aborted) break;
  }
  return { version: 1, ok: targets.length === inputs.length && targets.every((target) => target.ok), scope: 'dns-tls-only', configuration, targets };
}

/// Writes one machine-readable report and closes all probes on Ctrl+C.
async function main(): Promise<void> {
  // A shared cancellation signal prevents later targets after interruption.
  const controller = new AbortController();
  // Signal handling only cancels connections and never repeats a model request.
  const cancel = (): void => { controller.abort(); };
  process.once('SIGINT', cancel);
  process.once('SIGTERM', cancel);
  try {
    // Arguments contain only explicitly requested model service base URLs.
    const report = await diagnoseAiNetwork(process.argv.slice(2), process.env, controller.signal);
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    process.exitCode = report.ok ? 0 : 1;
  } catch {
    process.stdout.write(`${JSON.stringify({ version: 1, ok: false, scope: 'dns-tls-only', code: 'AI_NETWORK_DIAGNOSTIC_FAILED', targets: [] })}\n`);
    process.exitCode = 1;
  } finally {
    process.removeListener('SIGINT', cancel);
    process.removeListener('SIGTERM', cancel);
  }
}

if (require.main === module) void main();
