import { zlib } from '@kit.BasicServicesKit';
import { ImportMeasurementObserver, measureImportStage } from './ImportMeasurement';
import { ImportWriteGuard } from './ImportStorageBudget';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ensureDirectory, parentPath, pathExists, removeTree } from '../utils/FileUtils';
import { closeFile, openFile, readFile, statFile, writeFile } from '../utils/FileIoBoundary';
import { BoundedInflateError, InflateControl, InflateInput, InflateOutput, inflateBounded } from './BoundedInflater';
import { EpubInputError } from './EpubInputPolicy';
import { inspectZip, ZipEntry, ZipLimits, ZipSource } from './EpubZipIndex';

export class FileZipSource implements ZipSource {
  size: number;
  private file: fs.File;
  constructor(file: fs.File, size: number) { this.file = file; this.size = size; }
  static async open(path: string): Promise<FileZipSource> {
    const file = await openFile(path, fs.OpenMode.READ_ONLY);
    try { return new FileZipSource(file, (await statFile(file.fd)).size); }
    catch (_) { closeFile(file); throw new Error('archive-stat-failed'); }
  }
  async readAt(offset: number, length: number): Promise<ArrayBuffer> {
    const buffer = new ArrayBuffer(length);
    let read = 0;
    while (read < length) {
      const remaining = new ArrayBuffer(length - read);
      const count = await readFile(this.file.fd, remaining, { offset: offset + read, length: length - read });
      if (count <= 0) throw new EpubInputError('malformed');
      new Uint8Array(buffer).set(new Uint8Array(remaining, 0, count), read);
      read += count;
    }
    return buffer;
  }
  close(): void { closeFile(this.file); }
}
class EntryInput implements InflateInput {
  private source: ZipSource;
  private offset: number;
  private remaining: number;
  constructor(source: ZipSource, entry: ZipEntry) {
    this.source = source; this.offset = entry.dataOffset; this.remaining = entry.compressedBytes;
  }
  async read(maximumBytes: number): Promise<ArrayBuffer> {
    const size = Math.min(maximumBytes, this.remaining);
    const bytes = await this.source.readAt(this.offset, size);
    this.offset += bytes.byteLength; this.remaining -= bytes.byteLength;
    return bytes;
  }
}
class EntryOutput implements InflateOutput {
  size: number = 0;
  crc: number = 0;
  private file?: fs.File;
  private storage?: ImportWriteGuard;
  private checksum: zlib.Checksum;
  constructor(checksum: zlib.Checksum, file?: fs.File, storage?: ImportWriteGuard) {
    this.checksum = checksum; this.file = file; this.storage = storage;
  }
  async write(bytes: ArrayBuffer): Promise<void> {
    this.crc = (await this.checksum.crc32(this.crc, bytes)) >>> 0;
    if (this.file !== undefined) {
      if (this.storage !== undefined) await this.storage.beforeWrite(bytes.byteLength, 'extraction');
      let offset = 0;
      while (offset < bytes.byteLength) {
        const written = await writeFile(this.file.fd, bytes.slice(offset),
          { offset: this.size + offset, length: bytes.byteLength - offset });
        if (written <= 0) throw new Error('archive-write-failed');
        offset += written;
      }
    }
    this.size += bytes.byteLength;
  }
}
function check(control: InflateControl): void {
  if (control.isCancelled()) throw new BoundedInflateError('cancelled');
}
async function createParents(root: string, destination: string): Promise<void> {
  const relative = destination.substring(root.length + 1);
  let directory = root;
  const parts = relative.split('/');
  for (let index = 0; index < parts.length - 1; index++) {
    directory += '/' + parts[index]; await ensureDirectory(directory);
  }
}

// Owns a newly created extraction directory only. Source and existing library
// content are never removed. Preflight finishes before any archive entry writes.
export async function extractBoundedZip(source: ZipSource, root: string,
  limits: ZipLimits, control: InflateControl, storage?: ImportWriteGuard, observer?: ImportMeasurementObserver): Promise<ZipEntry[]> {
  check(control);
  const entries = await measureImportStage(observer, 'archive_preflight', (): Promise<ZipEntry[]> => inspectZip(source, limits));
  check(control);
  return measureImportStage(observer, 'extraction', async (): Promise<ZipEntry[]> => {
  if (await pathExists(root)) throw new Error('extraction-root-already-exists');
  await ensureDirectory(parentPath(root));
  await fs.mkdir(root);
  try {
    const checksum = await zlib.createChecksum();
    let total = 0;
    for (const entry of entries) {
      check(control);
      const destination = `${root}/${entry.name}`;
      await createParents(root, destination);
      let file: fs.File | undefined;
      try {
        if (!entry.directory) file = await openFile(destination, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        const sink = new EntryOutput(checksum, file, storage);
        const input = new EntryInput(source, entry);
        const maximum = Math.min(entry.expandedBytes, limits.entryBytes, limits.expandedBytes - total,
          Math.max(1, entry.compressedBytes) * limits.compressionRatio);
        if (entry.method === 8) {
          await inflateBounded(input, sink, entry.compressedBytes, maximum, control);
        } else {
          let remaining = entry.compressedBytes;
          while (remaining > 0) {
            check(control);
            const bytes = await input.read(Math.min(65536, remaining));
            if (bytes.byteLength === 0 || bytes.byteLength > remaining) throw new EpubInputError('malformed');
            check(control);
            await sink.write(bytes);
            remaining -= bytes.byteLength;
          }
        }
        check(control);
        if (sink.size !== entry.expandedBytes || sink.crc !== entry.crc32) {
          throw new EpubInputError('malformed');
        }
        total += sink.size;
        if (entry.directory) await ensureDirectory(destination.substring(0, destination.length - 1));
      } finally {
        if (file !== undefined) closeFile(file);
      }
    }
    return entries;
  } catch (error) {
    try { await removeTree(root); }
    catch (_) { throw new Error('extraction-cleanup-pending'); }
    if (error instanceof Error) throw error;
    throw new Error('extraction-io-error');
  }
  });
}
