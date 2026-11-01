import { BadRequestException } from '@nestjs/common';
import { isIP } from 'node:net';
import { isPublicAiAddress } from './ai-address';

/// Normalizes a public Responses base URL without dropping custom prefixes.
export function normalizeAiBaseUrl(input: string): string {
  try {
    // Reject credentials, queries, fragments and ambiguous backslashes.
    const url = new URL(input.trim());
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || input.includes('\\')) throw new Error('invalid');
    if (/\/chat\/completions(?:\/|$)/i.test(decodeURIComponent(url.pathname))) throw new Error('invalid');
    url.pathname = url.pathname.replace(/\/+$/, '').replace(/\/responses$/i, '').replace(/\/+$/, '');
    if (!url.hostname || url.hostname.toLowerCase() === 'localhost' || url.hostname.endsWith('.localhost') || url.hostname.endsWith('.local')) throw new Error('invalid');
    if (isIP(url.hostname.replace(/^\[|\]$/g, '')) && !isPublicAiAddress(url.hostname.replace(/^\[|\]$/g, ''))) throw new Error('invalid');
    return url.toString().replace(/\/$/, '');
  } catch {
    throw new BadRequestException({ code: 'AI_INVALID_URL', message: '请填写无凭据、查询参数和片段的公网 HTTPS Responses API 基址，不支持 Chat Completions 地址' });
  }
}
