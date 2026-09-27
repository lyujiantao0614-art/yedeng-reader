import { EpubInputError, strictUtf8, zipPathKey } from './EpubInputPolicy';

export interface ZipSource {
  size: number;
  readAt(offset: number, length: number): Promise<ArrayBuffer>;
}
export interface ZipLimits {
  archiveBytes: number;
  expandedBytes: number;
  entryBytes: number;
  entryCount: number;
  pathCharacters: number;
  compressionRatio: number;
}
export interface ZipEntry {
  name: string;
  directory: boolean;
  method: number;
  crc32: number;
  compressedBytes: number;
  expandedBytes: number;
  localOffset: number;
  dataOffset: number;
  endOffset: number;
  flags: number;
}

async function read(source: ZipSource, offset: number, length: number): Promise<DataView> {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) ||
    offset < 0 || length < 0 || offset + length > source.size) throw new EpubInputError('malformed');
  const buffer = await source.readAt(offset, length);
  if (buffer.byteLength !== length) throw new EpubInputError('malformed');
  return new DataView(buffer);
}
function nameFrom(bytes: ArrayBuffer, utf8: boolean): string {
  const input = new Uint8Array(bytes);
  if (!utf8 && input.some((value: number): boolean => value > 127)) {
    throw new EpubInputError('unsupported_encoding');
  }
  return strictUtf8(input);
}
function rejectExtra(bytes: DataView): void {
  let position = 0;
  while (position < bytes.byteLength) {
    if (position + 4 > bytes.byteLength) throw new EpubInputError('malformed');
    const id = bytes.getUint16(position, true);
    const length = bytes.getUint16(position + 2, true);
    // ZIP64, Unicode path overrides and AES would introduce a second authority.
    if (id === 1 || id === 0x7075 || id === 0x9901) throw new EpubInputError('malformed');
    position += 4 + length;
    if (position > bytes.byteLength) throw new EpubInputError('malformed');
  }
}

export function validateZipLimits(limits: ZipLimits): void {
  const values: number[] = [limits.archiveBytes, limits.expandedBytes, limits.entryBytes,
    limits.entryCount, limits.pathCharacters, limits.compressionRatio];
  for (const value of values) {
    if (!Number.isSafeInteger(value) || value <= 0) throw new EpubInputError('resource_limit');
  }
}

export async function inspectZip(source: ZipSource, limits: ZipLimits): Promise<ZipEntry[]> {
  validateZipLimits(limits);
  if (!Number.isSafeInteger(source.size) || source.size < 22) throw new EpubInputError('malformed');
  if (source.size > limits.archiveBytes) throw new EpubInputError('resource_limit');
  const tailLength = Math.min(source.size, 65557);
  const tailStart = source.size - tailLength;
  const tail = await read(source, tailStart, tailLength);
  let end = -1;
  for (let offset = tail.byteLength - 22; offset >= 0; offset--) {
    if (tail.getUint32(offset, true) === 0x06054b50 &&
      offset + 22 + tail.getUint16(offset + 20, true) === tail.byteLength) { end = offset; break; }
  }
  if (end < 0 || tail.getUint16(end + 4, true) !== 0 || tail.getUint16(end + 6, true) !== 0) {
    throw new EpubInputError('malformed');
  }
  const count = tail.getUint16(end + 10, true);
  const centralBytes = tail.getUint32(end + 12, true);
  const centralStart = tail.getUint32(end + 16, true);
  if (count === 0 || count === 65535 || count !== tail.getUint16(end + 8, true) ||
    centralStart + centralBytes !== tailStart + end) throw new EpubInputError('malformed');
  if (count > limits.entryCount) throw new EpubInputError('resource_limit');
  const entries: ZipEntry[] = [];
  const keys = new Set<string>();
  const fileKeys = new Set<string>();
  let cursor = centralStart;
  let expanded = 0;
  for (let index = 0; index < count; index++) {
    if (cursor + 46 > centralStart + centralBytes) throw new EpubInputError('malformed');
    const header = await read(source, cursor, 46);
    if (header.getUint32(0, true) !== 0x02014b50) throw new EpubInputError('malformed');
    const flags = header.getUint16(8, true);
    const method = header.getUint16(10, true);
    const compressedBytes = header.getUint32(20, true);
    const expandedBytes = header.getUint32(24, true);
    const nameLength = header.getUint16(28, true);
    const extraLength = header.getUint16(30, true);
    const commentLength = header.getUint16(32, true);
    if ((flags & 1) !== 0) throw new EpubInputError('encrypted');
    if ((flags & ~0x080e) !== 0 || (method !== 0 && method !== 8) ||
      header.getUint16(34, true) !== 0 || compressedBytes === 0xffffffff || expandedBytes === 0xffffffff ||
      ((header.getUint32(38, true) >>> 16) & 0xf000) === 0xa000) throw new EpubInputError('malformed');
    if (cursor + 46 + nameLength + extraLength + commentLength > centralStart + centralBytes) {
      throw new EpubInputError('malformed');
    }
    // A UTF-8 code unit cannot require more than four source bytes.
    if (nameLength > limits.pathCharacters * 4) throw new EpubInputError('resource_limit');
    const name = nameFrom((await read(source, cursor + 46, nameLength)).buffer as ArrayBuffer, (flags & 0x800) !== 0);
    const key = zipPathKey(name, limits.pathCharacters);
    if (keys.has(key)) throw new EpubInputError('malformed');
    keys.add(key);
    const directory = name.endsWith('/');
    if (!directory) fileKeys.add(key);
    if (directory && expandedBytes !== 0) throw new EpubInputError('malformed');
    if (method === 0 && compressedBytes !== expandedBytes) throw new EpubInputError('malformed');
    expanded += expandedBytes;
    if (expandedBytes > limits.entryBytes || expanded > limits.expandedBytes ||
      expandedBytes > Math.max(1, compressedBytes) * limits.compressionRatio) throw new EpubInputError('resource_limit');
    rejectExtra(await read(source, cursor + 46 + nameLength, extraLength));
    entries.push({ name: name, directory: directory, method: method,
      crc32: header.getUint32(16, true), compressedBytes: compressedBytes, expandedBytes: expandedBytes,
      localOffset: header.getUint32(42, true), dataOffset: 0, endOffset: 0, flags: flags });
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  if (cursor !== centralStart + centralBytes) throw new EpubInputError('malformed');
  for (const key of keys) {
    let slash = key.indexOf('/');
    while (slash >= 0) {
      if (fileKeys.has(key.substring(0, slash))) throw new EpubInputError('malformed');
      slash = key.indexOf('/', slash + 1);
    }
  }
  const ordered = entries.slice().sort((a: ZipEntry, b: ZipEntry): number => a.localOffset - b.localOffset);
  let previousEnd = 0;
  for (const entry of ordered) {
    if (entry.localOffset !== previousEnd || entry.localOffset + 30 > centralStart) throw new EpubInputError('malformed');
    const local = await read(source, entry.localOffset, 30);
    const nameLength = local.getUint16(26, true);
    const extraLength = local.getUint16(28, true);
    entry.dataOffset = entry.localOffset + 30 + nameLength + extraLength;
    if (local.getUint32(0, true) !== 0x04034b50 || local.getUint16(6, true) !== entry.flags ||
      local.getUint16(8, true) !== entry.method || entry.dataOffset + entry.compressedBytes > centralStart ||
      nameLength > limits.pathCharacters * 4) throw new EpubInputError('malformed');
    const name = nameFrom((await read(source, entry.localOffset + 30, nameLength)).buffer as ArrayBuffer, (entry.flags & 0x800) !== 0);
    if (name !== entry.name) throw new EpubInputError('malformed');
    rejectExtra(await read(source, entry.localOffset + 30 + nameLength, extraLength));
    entry.endOffset = entry.dataOffset + entry.compressedBytes;
    if ((entry.flags & 8) === 0) {
      if (local.getUint32(14, true) !== entry.crc32 || local.getUint32(18, true) !== entry.compressedBytes ||
        local.getUint32(22, true) !== entry.expandedBytes) throw new EpubInputError('malformed');
    } else {
      const first = await read(source, entry.endOffset, 4);
      const signature = first.getUint32(0, true) === 0x08074b50;
      const descriptor = await read(source, entry.endOffset + (signature ? 4 : 0), 12);
      if (descriptor.getUint32(0, true) !== entry.crc32 || descriptor.getUint32(4, true) !== entry.compressedBytes ||
        descriptor.getUint32(8, true) !== entry.expandedBytes) throw new EpubInputError('malformed');
      entry.endOffset += signature ? 16 : 12;
      if (entry.endOffset > centralStart) throw new EpubInputError('malformed');
    }
    previousEnd = entry.endOffset;
  }
  const mimeEntry = ordered[0];
  if (previousEnd !== centralStart || mimeEntry.name !== 'mimetype' || mimeEntry.method !== 0 ||
    mimeEntry.expandedBytes < 20 || mimeEntry.expandedBytes > 22) throw new EpubInputError('malformed');
  const mime = await read(source, mimeEntry.dataOffset, mimeEntry.expandedBytes);
  const mimeText = strictUtf8(new Uint8Array(mime.buffer as ArrayBuffer));
  // Some otherwise ordinary publisher archives append one text line ending to
  // the required mimetype value. Keep this compatibility exception exact: no
  // whitespace trimming and no additional bytes are accepted.
  if (mimeText !== 'application/epub+zip' && mimeText !== 'application/epub+zip\n' &&
    mimeText !== 'application/epub+zip\r\n') throw new EpubInputError('malformed');
  return entries;
}
