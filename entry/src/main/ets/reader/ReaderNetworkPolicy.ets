export type ReaderRequestDecision = 'local-book' | 'block-network' | 'allow-local';

export const LOCAL_EPUB_REQUEST_URL: string = 'https://harmony-reader.local/book.epub';

export function isNetworkUrl(value: string): boolean {
  return /^(https?|wss?|ftp):/i.test(value.trim());
}

export function classifyReaderRequest(method: string, requestUrl: string): ReaderRequestDecision {
  if (method.toUpperCase() === 'GET' && requestUrl === LOCAL_EPUB_REQUEST_URL) {
    return 'local-book';
  }
  if (isNetworkUrl(requestUrl)) return 'block-network';
  return 'allow-local';
}

export function shouldBlockReaderNavigation(requestUrl: string): boolean {
  return isNetworkUrl(requestUrl);
}

export function validatedExternalLinkHost(userInfo?: string, host?: string): string {
  const safeUserInfo = typeof userInfo === 'string' ? userInfo : '';
  const safeHost = typeof host === 'string' ? host : '';
  if (safeUserInfo.length > 0 || safeHost.length === 0 || safeHost.length > 253) return '';
  return safeHost;
}
