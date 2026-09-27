import { ReaderArchiveDelivery } from './ReaderArchiveDelivery';

interface PendingSurfaceResponse { slot: number; version: number; deny: () => void; }
// Cancelling one Web slot leaves the book archive available to the other slots.
export class ReaderSurfaceResources {
  readonly base: string;
  readonly archive: ReaderArchiveDelivery;
  private versions: number[] = [0, 0, 0, 0];
  private active: boolean = true;
  private waiting: Set<PendingSurfaceResponse> = new Set();
  private work: Set<Promise<void>> = new Set();
  async drained(): Promise<void> { await Promise.all(Array.from(this.work)); }
  requests: number = 0;
  denied: number = 0;
  stale: number = 0;
  constructor(path: string, session: number) {
    this.archive = new ReaderArchiveDelivery(path);
    this.base = `https://harmony-reader-resource.invalid/s${session}/`;
  }
  prefix(slot: number): string { return this.base + slot + '/' + this.versions[slot] + '/'; }
  setVersion(slot: number, version: number): void {
    this.versions[slot] = version;
    for (const request of this.waiting) if (request.slot === slot && request.version !== version) request.deny();
  }
  close(): void { this.active = false; for (const request of this.waiting) request.deny(); this.archive.close(); }
  private response(code: number): WebResourceResponse {
    const response = new WebResourceResponse();
    response.setResponseCode(code); response.setReasonMessage(code === 200 ? 'OK' : 'Denied');
    response.setResponseHeader([{ headerKey: 'Cache-Control', headerValue: 'no-store' }, { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' }]);
    response.setResponseData(''); response.setResponseIsReady(true); return response;
  }
  intercept(slot: number, request: WebResourceRequest): WebResourceResponse {
    const url = request.getRequestUrl();
    const prefix = this.prefix(slot);
    if (!this.active || request.getRequestMethod() !== 'GET') { this.denied++; return this.response(403); }
    if (slot === 0 && url === this.base + 'book.epub') {
      const response = this.response(200); response.setResponseMimeType('application/epub+zip');
      response.setResponseData(this.archive.bookFd()); return response;
    }
    if (!url.startsWith(prefix)) { this.denied++; return this.response(403); }
    let path: string;
    try { path = decodeURIComponent(url.substring(prefix.length).split('?')[0]); } catch (_) { this.denied++; return this.response(403); }
    const mime = this.archive.mime(path);
    if (mime === undefined) { this.denied++; return this.response(403); }
    this.requests++;
    const version = this.versions[slot];
    const response = this.response(200); response.setResponseMimeType(mime); response.setResponseIsReady(false);
    let done = false;
    const pending: PendingSurfaceResponse = { slot, version, deny: (): void => {
      if (done) return;
      done = true; this.denied++; this.stale++; this.waiting.delete(pending);
      response.setResponseCode(403); response.setResponseData(''); response.setResponseIsReady(true);
    } };
    this.waiting.add(pending);
    const work = this.archive.resource(path).then(async (bytes: Uint8Array): Promise<void> => {
      if (done) return;
      if (!this.active || this.versions[slot] !== version) { pending.deny(); return; }
      done = true; this.waiting.delete(pending);
      response.setResponseData(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); response.setResponseIsReady(true);
    }).catch((): void => { pending.deny(); });
    this.work.add(work); work.finally((): void => { this.work.delete(work); });
    return response;
  }
}
