import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FileZipSource } from '../services/BoundedZipExtractor';
import { inspectZip, ZipEntry } from '../services/EpubZipIndex';
import { InflateInput, InflateOutput, inflateBounded } from '../services/BoundedInflater';
import { ImportCancellation } from '../services/ImportCancellation';
import { createProductionImportPolicy } from '../services/ProductionImportPolicy';
import { zipPathKey } from '../services/EpubInputPolicy';

interface CatalogItem { path: string; type: string; }
function resourceMime(path: string, declared: string): string | undefined {
  const type = declared.toLowerCase();
  const extension = path.substring(path.lastIndexOf('.') + 1).toLowerCase();
  const aliases: Map<string, string> = new Map([
    ['css', 'text/css'], ['xhtml', 'application/xhtml+xml'], ['html', 'text/html'],
    ['ttf', 'font/ttf'], ['otf', 'font/otf'], ['woff', 'font/woff'], ['woff2', 'font/woff2'],
    ['png', 'image/png'], ['jpg', 'image/jpeg'], ['jpeg', 'image/jpeg'], ['gif', 'image/gif'],
    ['webp', 'image/webp'], ['bmp', 'image/bmp'], ['avif', 'image/avif'], ['heic', 'image/heic'], ['svg', 'image/svg+xml']
  ]);
  if (aliases.has(extension)) return aliases.get(extension);
  if (/^(image|font)\/[a-z0-9.+-]+$/.test(type) || /^application\/[a-z0-9.+-]*font[a-z0-9.+-]*$/.test(type) || ['text/css', 'text/html', 'application/xhtml+xml', 'application/vnd.ms-opentype'].includes(type)) return type;
  return undefined;
}
export interface DeliveryArchiveState { jobs: number; cacheBytes: number; cached: number; sourceOpen: boolean; }
export class DeliveryCatalogBridge {
  onRegister: (raw: string) => boolean = (): boolean => false;
  register(raw: string): boolean { return this.onRegister(raw); }
}
class ArchiveInput implements InflateInput {
  private source: FileZipSource;
  private offset: number;
  private remaining: number;
  constructor(source: FileZipSource, entry: ZipEntry) { this.source = source; this.offset = entry.dataOffset; this.remaining = entry.compressedBytes; }
  async read(maximum: number): Promise<ArrayBuffer> {
    const size = Math.min(maximum, this.remaining);
    const value = await this.source.readAt(this.offset, size);
    this.offset += value.byteLength; this.remaining -= value.byteLength; return value;
  }
}
class ArchiveOutput implements InflateOutput {
  private checksum: zlib.Checksum;
  bytes: Uint8Array;
  size: number = 0;
  crc: number = 0;
  constructor(size: number, checksum: zlib.Checksum) { this.checksum = checksum; this.bytes = new Uint8Array(size); }
  async write(value: ArrayBuffer): Promise<void> {
    if (this.size + value.byteLength > this.bytes.byteLength) throw new Error('Entry bound');
    this.crc = (await this.checksum.crc32(this.crc, value)) >>> 0;
    this.bytes.set(new Uint8Array(value), this.size); this.size += value.byteLength;
  }
}
export class ReaderArchiveDelivery {
  private path: string;
  private source?: FileZipSource;
  private entries: Map<string, ZipEntry> = new Map();
  private catalog: Map<string, string> = new Map();
  private cache: Map<string, Uint8Array> = new Map();
  private jobs: Map<string, Promise<Uint8Array>> = new Map();
  private tail: Promise<void> = Promise.resolve();
  private control: ImportCancellation = new ImportCancellation();
  private cachedBytes: number = 0;
  reads: number = 0;
  hits: number = 0;
  state(): DeliveryArchiveState { return { jobs: this.jobs.size, cacheBytes: this.cachedBytes, cached: this.cache.size, sourceOpen: this.source !== undefined }; }
  async settled(): Promise<void> { await this.tail; }
  constructor(path: string) { this.path = path; }
  async open(): Promise<void> {
    const source = await FileZipSource.open(this.path);
    if (this.control.cancelled) { source.close(); throw new Error('Closed source'); }
    this.source = source;
    try {
      const entries = await inspectZip(source, createProductionImportPolicy().zip);
      if (this.control.cancelled) throw new Error('Closed source');
      entries.forEach((entry: ZipEntry): void => { if (!entry.directory) this.entries.set(entry.name, entry); });
    } catch (_) {
      if (this.source === source) { source.close(); this.source = undefined; }
      throw new Error('Archive unavailable');
    }
  }
  bookFd(): number {
    if (this.control.cancelled) throw new Error('Closed source');
    try { return fs.openSync(this.path, fs.OpenMode.READ_ONLY).fd; }
    catch (error) { throw error instanceof Error ? error : new Error('Reader archive open failed'); }
  }
  register(raw: string): boolean {
    if (this.control.cancelled || this.catalog.size > 0 || raw.length > 1024 * 1024) return false;
    try {
      const items = JSON.parse(raw) as CatalogItem[];
      if (!Array.isArray(items) || items.length > 4096) return false;
      const next: Map<string, string> = new Map();
      for (const item of items) {
        zipPathKey(item.path, 1024);
        const mime = resourceMime(item.path, item.type);
        if (!this.entries.has(item.path) || mime === undefined) continue;
        next.set(item.path, mime);
      }
      this.catalog = next; return this.catalog.size > 0;
    } catch (_) { return false; }
  }
  mime(path: string): string | undefined { return this.catalog.get(path); }
  hasEntry(path: string): boolean { return this.entries.has(path); }
  async resource(path: string): Promise<Uint8Array> {
    if (this.control.cancelled || !this.catalog.has(path)) throw new Error('Not authorized');
    const cached = this.cache.get(path);
    if (cached !== undefined) { this.hits++; return cached; }
    const existing = this.jobs.get(path);
    if (existing !== undefined) return existing;
    // One job per ZIP entry; the production ZIP entry limit bounds the queue.
    // A smaller arbitrary queue must not reject an otherwise supported chapter.
    if (this.jobs.size >= this.entries.size) throw new Error('Request bound');
    const entry = this.entries.get(path)!;
    const type = this.catalog.get(path)!;
    const maximum = type === 'text/css' || type.includes('xml') || type === 'text/html' ? 2 * 1024 * 1024 : 8 * 1024 * 1024;
    if (entry.expandedBytes > maximum) throw new Error('Resource bound');
    const job = this.tail.then(async (): Promise<Uint8Array> => {
      if (this.control.cancelled || this.source === undefined) throw new Error('Closed source');
      const input = new ArchiveInput(this.source, entry);
      const output = new ArchiveOutput(entry.expandedBytes, await zlib.createChecksum());
      if (entry.method === 8) await inflateBounded(input, output, entry.compressedBytes, entry.expandedBytes, this.control);
      else while (output.size < entry.expandedBytes) {
        if (this.control.cancelled) throw new Error('Cancelled');
        const chunk = await input.read(65536);
        if (chunk.byteLength === 0) throw new Error('Truncated');
        await output.write(chunk);
      }
      if (this.control.cancelled || output.size !== entry.expandedBytes || output.crc !== entry.crc32) throw new Error('Invalid entry');
      this.reads++;
      while (this.cache.size > 0 && (this.cachedBytes + output.size > 16 * 1024 * 1024 || this.cache.size >= 128)) {
        const oldest = this.cache.keys().next().value as string;
        this.cachedBytes -= this.cache.get(oldest)!.byteLength; this.cache.delete(oldest);
      }
      this.cache.set(path, output.bytes); this.cachedBytes += output.size; return output.bytes;
    });
    this.jobs.set(path, job);
    this.tail = job.then((): void => {}, (): void => {});
    job.finally((): void => { this.jobs.delete(path); }).catch((): void => {});
    return job;
  }
  close(): void {
    this.control.cancelled = true; this.catalog.clear(); this.cache.clear(); this.cachedBytes = 0;
    this.tail.finally((): void => { this.source?.close(); this.source = undefined; });
  }
}
