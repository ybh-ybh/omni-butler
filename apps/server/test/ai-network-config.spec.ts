import { readAiNetworkConfig } from '../src/ai/ai-network-config';

/// Uses only synthetic infrastructure endpoints and no credentials.
const resolver = { id: 'primary', url: 'https://dns.example.test/dns-query', bootstrapAddresses: ['8.8.8.8'] };

describe('AI network deployment configuration', () => {
  it('defaults to container DNS with bounded resolution and connection stages', () => {
    expect(readAiNetworkConfig({})).toEqual({ mode: 'system', systemServers: [], dohResolvers: [], dnsTimeoutMs: 5000, dnsAttemptTimeoutMs: 2000, connectTimeoutMs: 8000, connectAttemptTimeoutMs: 2000, maxAddresses: 8 });
  });

  it('allows trusted private infrastructure resolvers without opening private model targets', () => {
    expect(readAiNetworkConfig({ AI_DNS_SERVERS: '127.0.0.11, 10.0.0.2,127.0.0.11' }).systemServers).toEqual(['127.0.0.11', '10.0.0.2']);
  });

  it('requires explicit DoH configuration and preserves trusted resolver order', () => {
    expect(readAiNetworkConfig({ AI_DNS_MODE: 'doh', AI_DOH_RESOLVERS: JSON.stringify([resolver, { ...resolver, id: 'backup', bootstrapAddresses: ['1.1.1.1', '1.1.1.1'] }]) }).dohResolvers).toEqual([resolver, { ...resolver, id: 'backup', bootstrapAddresses: ['1.1.1.1'] }]);
  });

  it.each([
    { AI_DNS_MODE: 'auto' }, { AI_DNS_MODE: 'doh' }, { AI_DNS_MODE: false },
    { AI_DNS_SERVERS: 'dns.example.test' }, { AI_DNS_SERVERS: '8.8.8.8,' }, { AI_DNS_SERVERS: '0.0.0.0' }, { AI_DNS_SERVERS: '::' }, { AI_DNS_SERVERS: 12 },
    { AI_DOH_RESOLVERS: JSON.stringify([resolver]) },
    { AI_DNS_MODE: 'doh', AI_DNS_SERVERS: '10.0.0.2', AI_DOH_RESOLVERS: JSON.stringify([resolver]) },
    { AI_DNS_MODE: 'doh', AI_DOH_RESOLVERS: 'not-json' },
    { AI_DNS_TIMEOUT_MS: '0' }, { AI_DNS_TIMEOUT_MS: '1.5' }, { AI_DNS_TIMEOUT_MS: true }, { AI_DNS_TIMEOUT_MS: '99999999999999' },
    { AI_DNS_TIMEOUT_MS: '1000' }, { AI_CONNECT_TIMEOUT_MS: '1000' }, { AI_CONNECT_MAX_ADDRESSES: '33' },
  ])('rejects ambiguous or invalid deployment configuration %#', (source) => {
    expect(() => readAiNetworkConfig(source)).toThrow();
  });

  it.each([
    { url: 'http://dns.example.test/dns-query' }, { url: 'https://user:secret@dns.example.test/dns-query' },
    { url: 'https://dns.example.test/dns-query?secret=token' }, { url: 'https://dns.example.test/dns-query#secret' },
    { url: 'https://localhost/dns-query' }, { url: 'https://dns.local/dns-query' },
    { url: 'https://8.8.8.8/dns-query' }, { url: 'https://127.0.0.1/dns-query' },
    { url: 'https://[2606:4700:4700::1111]/dns-query' }, { url: 'https://[::1]/dns-query' },
    { url: 'https://2130706433/dns-query' }, { url: 'https://localhost./dns-query' },
    { id: 'private-secret/id' }, { bootstrapAddresses: [] }, { bootstrapAddresses: ['127.0.0.1'] },
    { bootstrapAddresses: ['8.8.8.8', '198.18.0.1'] }, { bootstrapAddresses: ['example.com'] }, { unknown: 'secret' },
  ])('rejects unsafe DoH configuration without echoing input %#', (override) => {
    expect(() => readAiNetworkConfig({ AI_DNS_MODE: 'doh', AI_DOH_RESOLVERS: JSON.stringify([{ ...resolver, ...override }]) })).toThrow('AI_DOH_RESOLVERS');
    try { readAiNetworkConfig({ AI_DNS_MODE: 'doh', AI_DOH_RESOLVERS: JSON.stringify([{ ...resolver, ...override }]) }); }
    catch (error: unknown) { expect(String(error)).not.toMatch(/secret|token/); }
  });

  it('rejects duplicate resolver identities', () => {
    expect(() => readAiNetworkConfig({ AI_DNS_MODE: 'doh', AI_DOH_RESOLVERS: JSON.stringify([resolver, resolver]) })).toThrow('AI_DOH_RESOLVERS');
  });
});
