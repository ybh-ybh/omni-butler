import { AiProviderError } from './ai-errors';

/// Identifies the layer that produced a bounded network diagnostic.
export type AiNetworkStage = 'dns' | 'tcp' | 'tls' | 'http';

/// Contains only safe metadata, never model credentials, URLs or payloads.
export interface AiNetworkEvent {
  /// Links diagnostics from a single model connection.
  traceId: string;
  /// Identifies the network layer.
  stage: AiNetworkStage;
  /// Names the completed operation outcome.
  outcome: 'success' | 'failure' | 'cancelled';
  /// Records elapsed wall time for this operation.
  elapsedMs: number;
  /// Contains a locally controlled reason code.
  reason?: string;
  /// Identifies the trusted configured resolver without credentials.
  resolver?: string;
  /// Identifies the validated candidate address.
  address?: string;
  /// Distinguishes preflight failures from potentially paid submissions.
  submitted?: boolean;
}

/// Receives bounded network events for logs or an explicit diagnostic run.
export type AiNetworkObserver = (event: AiNetworkEvent) => void;

/// Preserves safe failure facts across DNS, TLS and model adapters.
export class AiNetworkError extends AiProviderError {
  /// Only transient pre-submission failures may use another connection path.
  constructor(code: string, readonly stage: AiNetworkStage, readonly reason: string, readonly retryable = false) {
    super(code);
  }
}
