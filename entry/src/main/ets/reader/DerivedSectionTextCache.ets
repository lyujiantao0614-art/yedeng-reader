import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { SectionText } from '../domain/SectionText';
import { ensureDirectory, removeTree } from '../utils/FileUtils';

interface CacheEnvelope { version: number; bookId: string; digest: string; payload: string; }
const ENTRY_BYTES: number = 6 * 1024 * 1024;
const BOOK_BYTES: number = 8 * 1024 * 1024;
const TOTAL_BYTES: number = 64 * 1024 * 1024;
let stageSequence: number = 0;

async function checksum(value: string): Promise<string> {
  try {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({data: new util.TextEncoder().encodeInto(value)});
    return Array.from((await md.digest()).data).map((byte: number): string => byte.toString(16).padStart(2, '0')).join('');
  } catch (_) { throw new Error('Derived checksum unavailable'); }
}

export function validSectionText(section: SectionText, index: number, href: string): boolean {
  if (!Number.isSafeInteger(index) || index < 0 || !section || section.version !== 1 || section.extractor !== 'body-text-1' || section.index !== index ||
    section.href !== href || (section.parserMode !== 'text/html' && section.parserMode !== 'application/xhtml+xml') ||
    typeof section.text !== 'string' || section.text.length > 2 * 1024 * 1024 || !Array.isArray(section.runs) ||
    section.runs.length > 20000) return false;
  let cursor = 0;
  const paths: Set<string> = new Set();
  for (const run of section.runs) {
    if (!run || run.start !== cursor || !Number.isSafeInteger(run.end) || run.end <= run.start ||
      run.end > section.text.length || !Array.isArray(run.path) || run.path.length === 0 || run.path.length > 64 ||
      !run.path.every((part: number): boolean => Number.isSafeInteger(part) && part >= 0)) return false;
    const key = JSON.stringify(run.path);
    if (paths.has(key)) return false;
    paths.add(key); cursor = run.end;
  }
  return cursor === section.text.length;
}

// Disposable app-private derived files; no record/catalogue DB is opened here.
export class DerivedSectionTextCache {
  readonly root: string;
  readonly directory: string;
  hits: number = 0;
  misses: number = 0;
  writeFailures: number = 0;
  private sourcePath: string;
  private bookId: string;
  constructor(cacheDir: string, sourcePath: string, bookId: string) {
    if (!/^[a-f0-9]{64}$/i.test(bookId)) throw new Error('Invalid derived cache identity');
    this.root = cacheDir + '/publication-text-body1-parser1-schema1';
    this.directory = this.root + '/' + bookId;
    this.sourcePath = sourcePath;
    this.bookId = bookId;
  }
  private async requireSource(): Promise<void> {
    try { if (!(await fs.stat(this.sourcePath)).isFile()) throw new Error('Source missing'); }
    catch (_) { throw new Error('Canonical source missing'); }
  }
  async read(index: number, href: string): Promise<SectionText | undefined> {
    await this.requireSource();
    const path = this.directory + '/' + index + '.json';
    try {
      const size = (await fs.stat(path)).size;
      if (size <= 0 || size > ENTRY_BYTES) throw new Error('Cache entry bound');
      const envelope = JSON.parse(await fs.readText(path)) as CacheEnvelope;
      if (envelope.version !== 1 || envelope.bookId !== this.bookId || typeof envelope.payload !== 'string' ||
        envelope.digest !== await checksum(envelope.payload)) throw new Error('Cache integrity');
      const section = JSON.parse(envelope.payload) as SectionText;
      if (!validSectionText(section, index, href)) throw new Error('Cache schema');
      this.hits++; return section;
    } catch (_) {
      this.misses++;
      try { await fs.unlink(path); } catch (_) {}
      return undefined;
    }
  }
  async write(section: SectionText, current: () => boolean): Promise<void> {
    let staging = '';
    try {
      await this.requireSource();
      if (!current() || !validSectionText(section, section.index, section.href)) return;
      const payload = JSON.stringify(section);
      const envelope: CacheEnvelope = {version: 1, bookId: this.bookId, digest: await checksum(payload), payload};
      const bytes = new util.TextEncoder().encodeInto(JSON.stringify(envelope));
      if (bytes.length > ENTRY_BYTES) return;
      await ensureDirectory(this.root);
      await this.reconcile(bytes.length);
      await ensureDirectory(this.directory);
      if (!current()) return;
      staging = this.directory + '/' + section.index + '.stage-' + (++stageSequence);
      const file = await fs.open(staging, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        if (await fs.write(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)) !== bytes.length) {
          throw new Error('Cache short write');
        }
        await fs.fsync(file.fd);
      } finally { await fs.close(file); }
      if (!current()) return;
      await this.requireSource();
      if (!current()) return;
      await fs.rename(staging, this.directory + '/' + section.index + '.json');
      staging = '';
    } catch (_) { this.writeFailures++; }
    finally { if (staging.length > 0) { try { await fs.unlink(staging); } catch (_) {} } }
  }
  private async reconcile(incoming: number): Promise<void> {
    try {
    let total = 0;
    let bookBytes = 0;
    const directories = await fs.listFile(this.root);
    for (const name of directories) {
      const directory = this.root + '/' + name;
      if (!/^[a-f0-9]{64}$/i.test(name)) { await removeTree(directory); continue; }
      for (const file of await fs.listFile(directory)) {
        const path = directory + '/' + file;
        if (!/^\d+\.json$/.test(file)) { await removeTree(path); continue; }
        const size = (await fs.stat(path)).size;
        if (size > ENTRY_BYTES) { await removeTree(path); continue; }
        total += size;
        if (directory === this.directory) bookBytes += size;
      }
    }
    if (total + incoming > TOTAL_BYTES) {
      for (const name of await fs.listFile(this.root)) await removeTree(this.root + '/' + name);
    } else if (bookBytes + incoming > BOOK_BYTES) {
      await removeTree(this.directory);
    }
    } catch (_) { throw new Error('Derived cache reconciliation unavailable'); }
  }
}
