# Synthetic TLS fixture

These certificate and private-key files are public, synthetic test data for
`ai-transport.spec.ts`. They are never deployment credentials.

The self-signed certificate is valid from 2020-01-01 to 2040-01-01 and contains
only the DNS SAN `model.example.test`. The test binds its server to loopback and
injects this certificate as a trusted CA only for its own TLS connection.
