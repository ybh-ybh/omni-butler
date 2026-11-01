/// Exposes stable provider codes without retaining credentials or remote bodies.
export class AiProviderError extends Error {
  /// Correlates a safe public failure with structured server diagnostics.
  traceId?: string;

  /// Unknown submission must never trigger an automatic paid replay.
  constructor(readonly code: string, readonly uncertain = false) { super(code); }
}
