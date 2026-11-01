import { isIP } from 'node:net';

/// Rejects private, reserved, documentation and mapped address ranges.
export function isPublicAiAddress(address: string): boolean {
  if (isIP(address) === 4) {
    // Parse each IPv4 octet before checking reserved ranges.
    const octets = address.split('.').map(Number);
    // Inspect the first octet.
    const first = octets[0]!;
    // Inspect the second octet.
    const second = octets[1]!;
    return !(first === 0 || first === 10 || first === 127 || first >= 224 ||
      (first === 100 && second >= 64 && second <= 127) || (first === 169 && second === 254) ||
      (first === 172 && second >= 16 && second <= 31) || (first === 192 && (second === 168 || second === 0 || second === 2)) ||
      (first === 198 && (second === 18 || second === 19 || second === 51)) || (first === 203 && second === 0 && octets[2] === 113));
  }
  if (isIP(address) === 6) {
    // Restrict IPv6 to global unicast outside special-purpose ranges.
    const lower = new URL(`https://[${address}]/`).hostname.slice(1, -1).toLowerCase();
    // Normalize leading zeros before checking special-purpose ranges.
    const second = Number.parseInt(lower.split(':')[1] || '0', 16);
    return /^[23][0-9a-f]{3}:/.test(lower) && !(lower.startsWith('2001:') && (second < 0x200 || second === 0xdb8)) && !lower.startsWith('2002:') && !(lower.startsWith('3fff:') && second < 0x1000);
  }
  return false;
}
