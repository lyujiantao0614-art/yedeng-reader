import { ImportMeasurementObserver, measureImportStage } from './ImportMeasurement';
import { ImportWriteGuard } from './ImportStorageBudget';
import { BoundedInflateError, InflateControl } from './BoundedInflater';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ensureDirectory, pathExists, removeTree } from '../utils/FileUtils';
import { closeFile, openFile, readTextFile, statFile, writeFile } from '../utils/FileIoBoundary';

export type ManagedBookStoreFaultPoint =
  'stage-copy' | 'finalize-copy' | 'finalize-move' | 'delete' | 'cleanup';

export interface ManagedBookStoreFaultInjector {
  before(point: ManagedBookStoreFaultPoint): void;
}

class NoManagedBookStoreFaults implements ManagedBookStoreFaultInjector {
  before(_point: ManagedBookStoreFaultPoint): void {
  }
}

export interface PreparedManagedBook {
  epubRelativePath: string;
  coverRelativePath?: string;
}

export interface ManagedBookStoreOptions {
  rootDirectoryName?: 'books' | 'phase31-test-books' | 'phase34-test-books' | 'phase37-test-books';
}

const VALIDATION_MARKER_NAME: string = '.validation-policy';

function isValidValidationKey(value: string): boolean {
  return /^[0-9|]{1,256}$/.test(value);
}

export function isValidBookId(value: string): boolean {
  return /^[a-f0-9]{64}$/i.test(value);
}

export function isValidUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}

export function createSecureUuid(): string {
  const value = util.generateRandomUUID(true).toLowerCase();
  if (!isValidUuid(value)) throw new Error('Platform UUID generation failed');
  return value;
}

function bytesToHex(bytes: Uint8Array): string {
  let output = '';
  for (const value of bytes) output += value.toString(16).padStart(2, '0');
  return output;
}

function normalized(path: string): string {
  return path.replace(/\\/g, '/').replace(/\/+$/g, '');
}

export class ManagedBookStore {
  private booksRoot: string;
  private rootDirectoryName: string;
  private stagingRoot: string;
  private orphanRoot: string;
  private faults: ManagedBookStoreFaultInjector;

  constructor(context: common.Context,
    faults: ManagedBookStoreFaultInjector = new NoManagedBookStoreFaults(),
    options: ManagedBookStoreOptions = {}) {
    this.rootDirectoryName = options.rootDirectoryName ?? 'books';
    this.booksRoot = normalized(`${context.filesDir}/${this.rootDirectoryName}`);
    this.stagingRoot = `${this.booksRoot}/.staging`;
    this.orphanRoot = `${this.booksRoot}/.recovery/orphans`;
    this.faults = faults;
  }

  async initialize(): Promise<void> {
    await ensureDirectory(this.booksRoot);
    await ensureDirectory(this.stagingRoot);
    await ensureDirectory(`${this.booksRoot}/.recovery`);
    await ensureDirectory(this.orphanRoot);
  }

  createToken(): string {
    return createSecureUuid();
  }

  private contained(path: string): string {
    const value = normalized(path);
    if (value !== this.booksRoot && !value.startsWith(`${this.booksRoot}/`)) {
      throw new Error('Managed book path escaped its private root');
    }
    return value;
  }

  private stagePath(token: string): string {
    if (!isValidUuid(token)) throw new Error('Invalid staging token');
    return this.contained(`${this.stagingRoot}/${token}`);
  }

  private finalPath(bookId: string): string {
    if (!isValidBookId(bookId)) throw new Error('Invalid book identity');
    return this.contained(`${this.booksRoot}/${bookId}`);
  }

  private orphanPath(bookId: string): string {
    if (!isValidBookId(bookId)) throw new Error('Invalid book identity');
    return this.contained(`${this.orphanRoot}/${bookId}`);
  }

  async createStage(token: string): Promise<void> {
    await ensureDirectory(this.stagePath(token));
  }

  stagedEpubPath(token: string): string {
    return this.contained(`${this.stagePath(token)}/book.epub`);
  }

  extractedPath(token: string): string {
    return this.contained(`${this.stagePath(token)}/extracted`);
  }

  async stageAndHash(token: string, uri: string, maximumBytes?: number,
    control?: InflateControl, storage?: ImportWriteGuard): Promise<string> {
    this.faults.before('stage-copy');
    const source = await fs.open(uri, fs.OpenMode.READ_ONLY);
    let target: fs.File | undefined;
    try {
      const digest = cryptoFramework.createMd('SHA256');
      const buffer = new ArrayBuffer(256 * 1024);
      let targetOffset = 0;
      if (maximumBytes !== undefined && (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0)) {
        throw new BoundedInflateError('resource_limit');
      }
      target = await fs.open(this.stagedEpubPath(token),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      while (true) {
        if (control?.isCancelled()) throw new BoundedInflateError('cancelled');
        const count = await fs.read(source.fd, buffer);
        if (control?.isCancelled()) throw new BoundedInflateError('cancelled');
        if (maximumBytes !== undefined && targetOffset + count > maximumBytes) {
          throw new BoundedInflateError('resource_limit');
        }
        if (count <= 0) break;
        if (storage !== undefined) await storage.beforeWrite(count, 'source-copy');
        const chunk = count === buffer.byteLength ? buffer : buffer.slice(0, count);
        await digest.update({ data: new Uint8Array(chunk) });
        let offset = 0;
        while (offset < count) {
          const remaining = offset === 0 ? chunk : chunk.slice(offset);
          const written = await fs.write(target.fd, remaining,
            { offset: targetOffset + offset, length: count - offset });
          if (written <= 0) throw new Error('Managed EPUB copy could not be written');
          offset += written;
        }
        targetOffset += count;
      }
      const output = await digest.digest();
      return bytesToHex(output.data);
    } finally {
      try { fs.closeSync(source); }
      finally { if (target !== undefined) fs.closeSync(target); }
    }
  }

  async prepareFinal(token: string, bookId: string,
    coverAbsolutePath?: string, coverExtension?: string, storage?: ImportWriteGuard,
    observer?: ImportMeasurementObserver, validationKey?: string): Promise<PreparedManagedBook> {
    const finalRoot = this.finalPath(bookId);
    if (await pathExists(finalRoot)) throw new Error('Managed book destination already exists');
    const preparedRoot = this.contained(`${this.stagePath(token)}/prepared`);
    await ensureDirectory(preparedRoot);
    if (storage !== undefined) await storage.beforeWrite((await fs.stat(this.stagedEpubPath(token))).size, 'final-epub');
    this.faults.before('finalize-copy');
    await measureImportStage(observer, 'final_epub_copy', (): Promise<void> => fs.copyFile(this.stagedEpubPath(token), `${preparedRoot}/book.epub`));
    let coverRelativePath: string | undefined;
    if (coverAbsolutePath !== undefined && coverExtension !== undefined) {
      const safeExtension = /^[a-z0-9]{1,8}$/.test(coverExtension) ? coverExtension : 'img';
      if (storage !== undefined) await storage.beforeWrite((await fs.stat(coverAbsolutePath)).size, 'final-cover');
      const coverPath: string = coverAbsolutePath;
      await measureImportStage(observer, 'cover_copy', (): Promise<void> => fs.copyFile(coverPath, `${preparedRoot}/cover.${safeExtension}`));
      coverRelativePath = `${this.rootDirectoryName}/${bookId}/cover.${safeExtension}`;
    }
    if (validationKey !== undefined) {
      if (!isValidValidationKey(validationKey)) throw new Error('Invalid managed-book validation key');
      const marker = await openFile(`${preparedRoot}/${VALIDATION_MARKER_NAME}`,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try { await writeFile(marker.fd, validationKey); }
      finally { closeFile(marker); }
    }
    this.faults.before('finalize-move');
    await measureImportStage(observer, 'final_move', (): Promise<void> => fs.rename(preparedRoot, finalRoot));
    return {
      epubRelativePath: `${this.rootDirectoryName}/${bookId}/book.epub`,
      coverRelativePath: coverRelativePath
    };
  }

  async deleteStage(token: string): Promise<void> {
    this.faults.before('cleanup');
    await removeTree(this.stagePath(token));
  }

  async deleteFinal(bookId: string): Promise<void> {
    this.faults.before('delete');
    await removeTree(this.finalPath(bookId));
  }

  async hasBookFile(bookId: string): Promise<boolean> {
    return pathExists(`${this.finalPath(bookId)}/book.epub`);
  }

  async hasCurrentValidation(bookId: string, validationKey: string): Promise<boolean> {
    if (!isValidValidationKey(validationKey) || !await this.hasBookFile(bookId)) return false;
    try {
      const markerPath = `${this.finalPath(bookId)}/${VALIDATION_MARKER_NAME}`;
      const marker = await statFile(markerPath);
      if (marker.size <= 0 || marker.size > 256) return false;
      return await readTextFile(markerPath) === validationKey;
    } catch (_) {
      return false;
    }
  }

  async markValidationCurrent(bookId: string, validationKey: string): Promise<void> {
    if (!isValidValidationKey(validationKey)) throw new Error('Invalid managed-book validation key');
    const root = this.finalPath(bookId);
    if (!await this.hasBookFile(bookId)) throw new Error('Managed EPUB is missing');
    const destination = `${root}/${VALIDATION_MARKER_NAME}`;
    const marker = await openFile(destination, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try { await writeFile(marker.fd, validationKey); }
    finally { closeFile(marker); }
  }

  bookFilePath(bookId: string): string { return this.contained(this.finalPath(bookId) + '/book.epub'); }

  async bookFileSize(bookId: string): Promise<number> {
    return fs.statSync(`${this.finalPath(bookId)}/book.epub`).size;
  }

  async hasManagedRelativePath(bookId: string, relativePath: string): Promise<boolean> {
    const prefix = `${this.rootDirectoryName}/${bookId}/`;
    if (!isValidBookId(bookId) || !relativePath.startsWith(prefix)) return false;
    const suffix = relativePath.substring(prefix.length);
    if (suffix.length === 0 || suffix.includes('/') || suffix.includes('\\') || suffix === '.' || suffix === '..') {
      return false;
    }
    return pathExists(this.contained(`${this.finalPath(bookId)}/${suffix}`));
  }

  async listManagedBookIds(): Promise<string[]> {
    const entries = await fs.listFile(this.booksRoot);
    return entries.filter((entry: string): boolean => isValidBookId(entry));
  }

  async cleanupAllStaging(): Promise<number> {
    const entries = await fs.listFile(this.stagingRoot);
    let removed = 0;
    for (const entry of entries) {
      if (entry.includes('/') || entry.includes('\\') || entry === '.' || entry === '..') continue;
      this.faults.before('cleanup');
      await removeTree(this.contained(`${this.stagingRoot}/${entry}`));
      removed += 1;
    }
    return removed;
  }

  async quarantineOrphan(bookId: string): Promise<void> {
    const source = this.finalPath(bookId);
    const destination = this.orphanPath(bookId);
    if (await pathExists(destination)) throw new Error('Quarantined orphan already exists');
    await fs.rename(source, destination);
  }

  async countQuarantinedOrphans(): Promise<number> {
    const entries = await fs.listFile(this.orphanRoot);
    return entries.filter((entry: string): boolean => isValidBookId(entry)).length;
  }

  async cleanupQuarantinedOrphans(): Promise<number> {
    const entries = await fs.listFile(this.orphanRoot);
    let removed = 0;
    for (const entry of entries) {
      if (!isValidBookId(entry)) continue;
      this.faults.before('cleanup');
      await removeTree(this.orphanPath(entry));
      removed += 1;
    }
    return removed;
  }
}
